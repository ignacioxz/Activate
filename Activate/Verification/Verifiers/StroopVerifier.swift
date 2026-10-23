import Foundation

// Dueño: paquete "stroop-breath".
//
// Máquina de estados pura del test de Stroop (A10 "Reflejos 60"). Sin imports de UI ni sensores.
//
// PROTOCOLO CON LA VISTA (el runner es genérico y solo expone `VerifierProgress` y `Cue`):
//
// 1. Tras `start(at:)` el verificador queda esperando. La vista muestra su pantalla de inicio y, cuando
//    la persona toca EMPEZAR, envía `.touchUp(t:)` (señal de "listo"; también vale `.touchDown`).
//    Ahí arranca la caja de tiempo del test.
// 2. El verificador responde con un `Cue` de ensayo con este formato:
//        text   = "PALABRA|tinta|índice|isiMs"      p. ej. "ROJO|verde|3|850"
//        symbol = StroopCue.symbol ("paintpalette")
//    PALABRA en mayúsculas (ROJO / VERDE / AZUL / AMARILLO) es lo que se escribe en pantalla;
//    `tinta` en minúsculas es el color con que se pinta; `índice` es el ensayo (0-based) e `isiMs`
//    los milisegundos de pantalla en blanco antes de mostrarlo. `StroopCue(cue:)` lo parsea.
//    Un `Cue` sin "|" es texto para mostrar tal cual.
// 3. La vista espera `isiMs`, muestra el estímulo y envía `.stroopShown(trialIndex:atMs:)`.
//    Al tocar un color envía `.stroopAnswer(trialIndex:answer:atMs:)` con `answer` 0..3
//    (índice de `StroopVerifier.colorNames`) o `StroopVerifier.noResponse` (-1) si pasaron
//    `lapseMs` sin respuesta. Los `atMs` los mide la vista con `ScreenSource.elapsedMs`.
// 4. Tras cada respuesta llega el `Cue` del siguiente ensayo o `.completed` (meta de ensayos o
//    caja de 60 s cumplida). El runner llama entonces a `finish(at:reason:)`.
//
// Reglas (constantes abajo; se calibran en dispositivo): RT = answeredAtMs − shownAtMs;
// < 150 ms anticipación (inválido); > 2000 ms o sin respuesta = lapso (inválido); > 1000 ms lento
// (válido, se cuenta). Test confiable si ≥ `minValidTrials` válidos y precisión ≥ 0,7; si no,
// `completed = false` ("test no confiable", sin anomalía). Aporreo = misma tecla ≥ 6 seguidas o
// precisión global ≤ 0,35 → anomalía hard "buttonMashing" (la política lo baja a `suspicious`).

/// Ensayo codificado en un `Cue` (ver protocolo arriba).
nonisolated struct StroopCue: Sendable, Hashable {
    static let symbol = "paintpalette"
    static let separator: Character = "|"

    var index: Int
    var word: Int
    var ink: Int
    var isiMs: Int

    init(index: Int, word: Int, ink: Int, isiMs: Int) {
        self.index = index
        self.word = word
        self.ink = ink
        self.isiMs = isiMs
    }

    init(trial: StroopTrial) {
        self.init(index: trial.index, word: trial.word, ink: trial.ink, isiMs: trial.isiMs)
    }

    /// `nil` si el cue no es un ensayo (texto plano).
    init?(cue: Cue) {
        let parts = cue.text.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              let word = StroopVerifier.colorNames.firstIndex(of: parts[0]),
              let ink = StroopVerifier.colorNames.firstIndex(of: parts[1].uppercased()),
              let index = Int(parts[2]),
              let isi = Int(parts[3]) else { return nil }
        self.init(index: index, word: word, ink: ink, isiMs: isi)
    }

    /// Palabra que se escribe (mayúsculas).
    var wordText: String { StroopVerifier.colorNames[word] }
    /// Nombre del color de la tinta (minúsculas).
    var inkText: String { StroopVerifier.colorNames[ink].lowercased() }

    var cue: Cue {
        Cue(text: [wordText, inkText, String(index), String(isiMs)].joined(separator: String(Self.separator)),
            symbol: Self.symbol)
    }
}

nonisolated struct StroopVerifier: ActivityVerifier {
    typealias Sample = ScreenSample

    // MARK: - Constantes nombradas (valores iniciales)

    /// Orden fijo: el índice es el valor de `answer`, `StroopTrial.word` y `StroopTrial.ink`.
    static let colorNames = ["ROJO", "VERDE", "AZUL", "AMARILLO"]
    static var colorCount: Int { colorNames.count }
    /// Caja fija del test (se recorta a `spec.maxDurationSeconds` si fuera menor).
    static let windowSeconds: Double = 60
    static let incongruentFraction = 0.5
    static let isiRangeMs = 500...1500
    /// La secuencia nunca repite la misma tinta más de 2 veces seguidas (evita falsos "aporreo").
    static let maxSameInkRun = 2
    static let anticipationMs = 150
    static let slowMs = 1000
    static let lapseMs = 2000
    /// Valor de `answer` cuando la vista agota `lapseMs` sin respuesta.
    static let noResponse = -1
    /// Valor de `StroopTrial.shownAtMs` mientras el ensayo no se ha mostrado (el contrato no es opcional).
    static let notShown = -1
    static let minValidTrials = 20
    /// En demo (meta 20) un solo lapso no debe invalidar el test.
    static let demoMinValidTrials = 16
    static let minAccuracy = 0.7
    static let mashingRunLength = 6
    static let mashingAccuracy = 0.35
    /// Ensayos respondidos antes de evaluar la precisión de aporreo.
    static let mashingMinTrials = 10
    static let anomalyButtonMashing = "buttonMashing"

    nonisolated enum Phase: Sendable, Equatable { case idle, waitingReady, running, done }

    // MARK: - Estado

    let kind: ActivityKind = .stroop
    let spec: VerificationSpec
    /// Semilla del RNG; viaja en `ActivityMetrics.stroop(seed:)` para reproducir la secuencia.
    let seed: UInt64
    private(set) var progress: VerifierProgress
    private(set) var trials: [StroopTrial]
    private(set) var phase: Phase = .idle
    /// Ensayo pendiente (índice en `trials`).
    private(set) var current = 0

    private var startT: Double = 0
    private var testStartT: Double = 0
    private var validCount = 0
    private var answeredCount = 0
    private var correctAll = 0
    private var lastKey: Int? = nil
    private var sameKeyRun = 0
    private var anomalies: [Anomaly] = []
    private var mashingFlagged = false

    init(spec: VerificationSpec, seed: UInt64? = nil) {
        self.spec = spec
        let s = seed ?? UInt64.random(in: UInt64.min...UInt64.max)
        self.seed = s
        progress = VerifierProgress(target: spec.target, gate: .calibrating, hint: "Toque para empezar")
        trials = Self.makeSequence(count: spec.target, seed: s)
    }

    /// Mínimo de ensayos válidos para que el test sea confiable.
    var requiredValidTrials: Int {
        min(spec.target, spec.demo ? Self.demoMinValidTrials : Self.minValidTrials)
    }

    /// Caja de tiempo efectiva del test.
    var window: Double { min(Self.windowSeconds, spec.maxDurationSeconds) }

    /// `Cue` del ensayo pendiente (la vista lo recibe por el runner; esto es para tests y depuración).
    var currentCue: Cue? {
        guard phase == .running, current < trials.count else { return nil }
        return StroopCue(trial: trials[current]).cue
    }

    // MARK: - Secuencia reproducible

    /// 50 % incongruentes (mezclados), 4 colores, ISI uniforme 0,5-1,5 s, sin más de 2 tintas iguales seguidas.
    static func makeSequence(count: Int, seed: UInt64) -> [StroopTrial] {
        guard count > 0 else { return [] }
        var rng = SplitMix64(seed: seed)
        let incongruentCount = Int((Double(count) * incongruentFraction).rounded(.down))
        var incongruentFlags = (0..<count).map { $0 < incongruentCount }
        incongruentFlags.shuffle(using: &rng)

        var trials: [StroopTrial] = []
        trials.reserveCapacity(count)
        for i in 0..<count {
            var ink: Int
            repeat {
                ink = Int.random(in: 0..<colorCount, using: &rng)
            } while trailingRun(of: ink, in: trials) >= maxSameInkRun
            let word: Int
            if incongruentFlags[i] {
                var w: Int
                repeat { w = Int.random(in: 0..<colorCount, using: &rng) } while w == ink
                word = w
            } else {
                word = ink
            }
            let isi = Int.random(in: isiRangeMs, using: &rng)
            trials.append(StroopTrial(index: i, word: word, ink: ink, congruent: !incongruentFlags[i],
                                      isiMs: isi, shownAtMs: notShown, answeredAtMs: nil, answer: nil))
        }
        return trials
    }

    private static func trailingRun(of ink: Int, in trials: [StroopTrial]) -> Int {
        var run = 0
        for t in trials.reversed() {
            guard t.ink == ink else { break }
            run += 1
        }
        return run
    }

    // MARK: - ActivityVerifier

    mutating func start(at t: Double) {
        startT = t
        testStartT = t
        phase = .waitingReady
        progress.gate = .ready
        progress.hint = "Toque para empezar"
        progress.elapsed = 0
    }

    mutating func ingest(_ sample: ScreenSample, at t: Double) -> [VerifierEvent] {
        progress.elapsed = max(0, t - startT)
        switch phase {
        case .idle, .done:
            return []
        case .waitingReady:
            switch sample {
            case .touchDown, .touchUp:
                return beginTest(at: t)
            default:
                return []
            }
        case .running:
            switch sample {
            case .stroopShown(let index, let atMs):
                guard index == current, index < trials.count, trials[index].shownAtMs == Self.notShown else { return [] }
                trials[index].shownAtMs = max(0, atMs)
                return []
            case .stroopAnswer(let index, let answer, let atMs):
                return record(answer: answer, atMs: atMs, index: index, at: t)
            default:
                return []
            }
        }
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        phase = .done
        let stats = StroopStats(trials: trials)
        if !mashingFlagged, stats.answered >= Self.mashingMinTrials, stats.overallAccuracy <= Self.mashingAccuracy {
            flagMashing(at: t, detail: "precisión \(Int((stats.overallAccuracy * 100).rounded())) %")
        }
        let reliable = stats.valid >= requiredValidTrials && stats.accuracy >= Self.minAccuracy
        let completed = reliable && (reason == .completed || reason == .timeout)
        progress.count = stats.valid
        progress.hint = reliable ? "Listo." : "Test no confiable"
        return ActivityOutcome(kind: kind, target: spec.target, achieved: stats.valid, completed: completed,
                               durationSeconds: max(0, t - startT), metrics: stats.metrics(seed: seed),
                               anomalies: anomalies, reason: reason)
    }

    // MARK: - Privado

    private mutating func beginTest(at t: Double) -> [VerifierEvent] {
        phase = .running
        testStartT = t
        current = 0
        progress.hint = "Toque el color de la tinta"
        guard let cue = currentCue else {
            phase = .done
            return [.completed]
        }
        return [.cue(cue), .progress(0)]
    }

    private mutating func record(answer: Int, atMs: Int, index: Int, at t: Double) -> [VerifierEvent] {
        guard index == current, index < trials.count,
              trials[index].shownAtMs != Self.notShown,
              trials[index].answeredAtMs == nil else { return [] }
        let shownAtMs = trials[index].shownAtMs
        trials[index].answeredAtMs = atMs
        trials[index].answer = answer

        var events: [VerifierEvent] = []
        let rt = atMs - shownAtMs
        let isLapse = answer == Self.noResponse || rt > Self.lapseMs
        let isAnticipation = !isLapse && rt < Self.anticipationMs
        if !isLapse && !isAnticipation {
            validCount += 1
            progress.count = validCount
            events.append(.rep(validCount))
        }
        events.append(.progress(progress.fraction))

        // Aporreo: misma tecla seguida o precisión global muy baja.
        answeredCount += 1
        if answer == trials[index].ink { correctAll += 1 }
        if answer == Self.noResponse {
            lastKey = nil
            sameKeyRun = 0
        } else if answer == lastKey {
            sameKeyRun += 1
        } else {
            lastKey = answer
            sameKeyRun = 1
        }
        if !mashingFlagged {
            let lowAccuracy = answeredCount >= Self.mashingMinTrials
                && Double(correctAll) / Double(answeredCount) <= Self.mashingAccuracy
            if sameKeyRun >= Self.mashingRunLength {
                events.append(.anomaly(flagMashing(at: t, detail: "misma tecla \(sameKeyRun) veces")))
            } else if lowAccuracy {
                events.append(.anomaly(flagMashing(at: t, detail: "precisión \(Int((Double(correctAll) / Double(answeredCount) * 100).rounded())) %")))
            }
        }

        current += 1
        let elapsedInTest = t - testStartT
        if current >= trials.count || elapsedInTest >= window {
            phase = .done
            progress.hint = "Listo."
            events.append(.completed)
        } else if let cue = currentCue {
            events.append(.cue(cue))
        }
        return events
    }

    @discardableResult
    private mutating func flagMashing(at t: Double, detail: String) -> Anomaly {
        mashingFlagged = true
        let a = Anomaly(kind: Self.anomalyButtonMashing, severity: .hard, at: max(0, t - startT), detail: detail)
        anomalies.append(a)
        return a
    }
}

// MARK: - Estadísticas

/// Resumen de una lista de ensayos (puro; lo usan `finish` y los tests).
nonisolated struct StroopStats: Sendable, Equatable {
    var answered = 0
    var valid = 0
    var correctValid = 0
    var correctAll = 0
    var anticipations = 0
    var lapses = 0
    var slow = 0
    var congruentRTs: [Int] = []
    var incongruentRTs: [Int] = []

    init(trials: [StroopTrial]) {
        for trial in trials {
            guard trial.shownAtMs != StroopVerifier.notShown, let answeredAt = trial.answeredAtMs, let key = trial.answer else { continue }
            answered += 1
            let rt = answeredAt - trial.shownAtMs
            let correct = key == trial.ink
            if correct { correctAll += 1 }
            if key == StroopVerifier.noResponse || rt > StroopVerifier.lapseMs {
                lapses += 1
                continue
            }
            if rt < StroopVerifier.anticipationMs {
                anticipations += 1
                continue
            }
            valid += 1
            if rt > StroopVerifier.slowMs { slow += 1 }
            if correct {
                correctValid += 1
                if trial.congruent { congruentRTs.append(rt) } else { incongruentRTs.append(rt) }
            }
        }
    }

    /// Precisión sobre ensayos válidos (criterio de test confiable).
    var accuracy: Double { valid > 0 ? Double(correctValid) / Double(valid) : 0 }
    /// Precisión sobre todo lo respondido (criterio de aporreo).
    var overallAccuracy: Double { answered > 0 ? Double(correctAll) / Double(answered) : 0 }

    var medianRTms: Int { Self.median(congruentRTs + incongruentRTs) }
    var medianCongruentRTms: Int { Self.median(congruentRTs) }
    var medianIncongruentRTms: Int { Self.median(incongruentRTs) }
    /// Efecto Stroop (ms): incongruente − congruente; `nil` si falta una condición.
    var stroopEffectMs: Int? {
        guard !congruentRTs.isEmpty, !incongruentRTs.isEmpty else { return nil }
        return medianIncongruentRTms - medianCongruentRTms
    }

    func metrics(seed: UInt64) -> ActivityMetrics {
        .stroop(trials: answered, valid: valid, accuracy: accuracy, medianRTms: medianRTms,
                medianCongruentRTms: medianCongruentRTms, medianIncongruentRTms: medianIncongruentRTms,
                anticipations: anticipations, lapses: lapses, seed: seed)
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

nonisolated extension ActivityMetrics {
    /// Efecto Stroop en ms (mediana incongruente − mediana congruente); `nil` si no es Stroop o falta una condición.
    var stroopEffectMs: Int? {
        guard case .stroop(_, _, _, _, let congruent, let incongruent, _, _, _) = self,
              congruent > 0, incongruent > 0 else { return nil }
        return incongruent - congruent
    }
}

// MARK: - RNG sembrado

/// SplitMix64: determinista, suficiente para barajar una secuencia reproducible por semilla.
nonisolated struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
