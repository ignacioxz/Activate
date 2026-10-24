import Foundation

// Dueño: agente "sit-to-stand". Máquina de estados pura para "Pararse y sentarse" (A4) con el teléfono en
// el BOLSILLO DELANTERO DEL PANTALÓN. Sin cara, sin cámara, sin apuntar. Reemplaza al verificador en las
// manos (`SitToStandVerifier`, que queda solo como código antiguo sin uso).
//
// Calibrado con una grabación real del iPhone (23-10-2026, 70 s, bolsillo delantero, 13 transiciones):
// - El muslo GIRA ≈ 50-58° en cada transición (sentado ≈ horizontal, de pie ≈ vertical) y el ángulo entre
//   dos posturas quietas es nítido. Es el detector principal (decisión del usuario, a la vista de los datos).
//   No se asume ningún eje del teléfono: la orientación en el bolsillo cambia (en la grabación, sentado
//   dejaba el eje largo vertical) y solo se usa el ángulo entre vectores gravedad.
// - CoreMotion entrega `userAcceleration` en el MISMO sentido que la aceleración física medida en el
//   teléfono: userAccel·ĝ (ĝ = gravedad, hacia abajo) es POSITIVA al bajar. Arriba = −(userAccel·ĝ)
//   (igual que en la sentadilla en las manos).
// - Integrada de meseta a meseta (con corrección lineal de la velocidad), la distancia vertical del bolsillo
//   da 7-10 cm por transición con el signo correcto y velocidades pico de 0,15-0,22 m/s: corrobora el giro
//   (idea del usuario) y es lo que separa un giro del teléfono con la mano (sin cuerpo) de una transición.
// - En el bolsillo en reposo |userAccel| ≈ 0,02-0,05 g y el giróscopo ≈ 0,1-0,2 rad/s: la quietud se define
//   por el ángulo estable (≤ 3° de la media en 0,3 s) con límites holgados, no por quietud perfecta.
// - El barómetro llega (≈ 1 Hz) pero en el bolsillo deriva decenas de cm y no ve 25 cm: solo corrobora.
//
// Política de conteo:
// - Meseta: 0,3 s con la gravedad dentro de 3° de su media, |userAccel| RMS < 0,06 g y giro RMS < 0,3 rad/s.
// - Postura: la primera meseta con el bolsillo tapado calibra la referencia. Una meseta a ≥ 35° de la
//   postura actual es una TRANSICIÓN (histéresis: a ≤ 17° es la misma postura y corre el ancla; entre 17° y
//   35° es parcial y no cuenta ni mueve el ancla).
// - Transición válida: ventana ancla → nueva meseta de 0,3-8 s; desplazamiento vertical ≥ 5 cm en el
//   sentido correcto (baja al ir a sentado, sube al ir a de pie; qué postura es "sentado" lo vota el propio
//   desplazamiento, ponderado, sin ejes fijos); velocidad pico 0,08-2,5 m/s; sin sacudida dentro. Si el
//   desplazamiento no acompaña (< 5 cm o al revés) → "soloGiro".
// - Rep = un ciclo completo (sentado → de pie → sentado o al revés): dos transiciones válidas seguidas,
//   separadas por ≤ 20 s, contado una vez. Sin pasos (≥ 4 en el ciclo → no cuenta), bolsillo tapado en
//   ≥ 60 % del ciclo. Fuera del bolsillo (≥ 1 s destapado) se bloquea y al volver se recalibra la postura.
// - Nivel: `full` si el barómetro corrobora ≥ 50 % de las reps; si el barómetro falta o no es concluyente
//   (no contradice en ≥ 50 %), `full` si giro y desplazamiento coinciden en ≥ 50 % de las reps; si no, o si
//   el teléfono no informa proximidad, `reduced` (vía `SourceLevelLimiting`).
//
// Residuales conocidos (documentados, no se sobre-ingenian): una sentadilla con el muslo girando también
// cuenta, y girar el teléfono 50° con la mano mientras se lo sube o baja ≥ 5 cm con el sensor tapado lo imita.

// MARK: - Muestra de dominio

/// Una lectura de deviceMotion (50 Hz) del teléfono en el bolsillo, más barómetro, podómetro y proximidad.
nonisolated struct PocketSitStandSample: Sendable, Codable, Hashable, TimedSample {
    /// Segundos desde el inicio de la actividad.
    var t: Double
    /// `CMDeviceMotion.userAcceleration` (g, marco del teléfono; mismo sentido que la aceleración física).
    var userAccel: SIMD3<Double>
    /// `CMDeviceMotion.gravity` (g, marco del teléfono, apunta hacia abajo). Detector principal: giro del muslo.
    var gravity: SIMD3<Double>
    /// `CMDeviceMotion.rotationRate` (rad/s). Solo para decidir quietud.
    var rotationRate: SIMD3<Double>
    /// Altura relativa del barómetro (m), SOLO si llegó una lectura nueva desde la muestra anterior.
    var altitude: Double? = nil
    /// Pasos acumulados del podómetro desde el inicio, si hay.
    var steps: Int? = nil
    /// Sensor de proximidad tapado (en el bolsillo). nil = el teléfono no informa proximidad.
    var proximityCovered: Bool? = nil
}

// MARK: - Copy (usted, frases cortas)

nonisolated enum PocketSitStandCopy {
    static let pocket = "Guarde el teléfono en el bolsillo delantero del pantalón"
    static let holdStill = "Quieto un segundo"
    static let go = "Párese y vuelva a sentarse"
    static let done = "Listo"
    static let outOfPocket = "Guarde el teléfono en el bolsillo"
    static let calibrated = "Listo. Párese y siéntese a su ritmo"
    static let partial = "Párese del todo y siéntese del todo"
    static let tooFast = "Más lento"
    static let tooSlow = "A su ritmo, sin detenerse a medio camino"
    static let jerky = "Muévase parejo, sin balancear la pierna"
    static let noPlateau = "Siéntese del todo antes de volver a pararse"
    static let walking = "Quédese frente a la silla"
    static let shaking = "No sacuda el teléfono"
}

/// Nombres de anomalía (las lee `StatsAnomalyCopy` por palabras clave).
nonisolated enum PocketSitStandAnomaly {
    static let shaking = "pocketShaking"
    static let walking = "pocketWalking"
    static let notInPocket = "notInPocket"
}

// MARK: - Diagnóstico por intento

/// Una transición medida (de una postura quieta a la otra).
nonisolated struct PocketStroke: Sendable, Hashable, Codable {
    /// Δaltura del bolsillo (m, + = sube), integrada de meseta a meseta.
    var displacement: Double
    /// Fin de la meseta de partida y comienzo de la meseta de llegada.
    var startT: Double
    var endT: Double
    /// Velocidad vertical pico (m/s, valor absoluto).
    var peakSpeed: Double
    /// Ángulo (°) entre el vector gravedad de la postura de partida y el de la llegada.
    var rotationDeg: Double
    /// Paridad de la postura de llegada (0 = la de la calibración).
    var toParity: Int
    /// La postura de llegada es "sentado" según el voto del desplazamiento; nil = aún sin votos.
    var toSeated: Bool?
    /// Fracción de muestras con el sensor de proximidad tapado; nil si el teléfono no informa.
    var proximityFraction: Double?
    /// Hubo una sacudida dentro de la transición.
    var shaky: Bool = false
    /// Pasos acumulados al empezar, si hay podómetro.
    var stepsAtStart: Int?

    var seconds: Double { max(0, endT - startT) }
    var isUp: Bool { displacement > 0 }
    /// Giro y desplazamiento coinciden: ≥ 35° y ≥ 5 cm en el sentido de la postura de llegada.
    var motionAgrees: Bool {
        guard let toSeated, rotationDeg >= PocketSitStandVerifier.K.transitionDeg else { return false }
        return displacement * (toSeated ? -1 : 1) >= PocketSitStandVerifier.K.minStroke
    }
}

nonisolated struct PocketSitStandAttempt: Sendable, Hashable, CustomStringConvertible {
    var index: Int
    var at: Double
    var counted: Bool
    var rejection: String?
    var first: PocketStroke
    var second: PocketStroke?
    /// Δ barómetro en cada transición (m), si hubo lecturas.
    var baroDelta: Double?
    var baroDeltaSecond: Double?
    var baroCorroborated: Bool
    /// Fracción tapada del ciclo completo.
    var cycleProximity: Double?
    var stepsInCycle: Int?

    var description: String {
        func cm(_ v: Double) -> String { String(format: "%+.0fcm", v * 100) }
        func s(_ v: Double) -> String { String(format: "%.2fs", v) }
        func stroke(_ k: PocketStroke) -> String {
            let prox = k.proximityFraction.map { String(format: "%.2f", $0) } ?? "?"
            let to = k.toSeated.map { $0 ? "sentado" : "de_pie" } ?? "?"
            return "giro=\(String(format: "%.0f°", k.rotationDeg)) desp=\(cm(k.displacement)) v=\(String(format: "%.2f", k.peakSpeed))m/s \(s(k.startT))-\(s(k.endT)) (\(s(k.seconds))) a=\(to) prox=\(prox)\(k.shaky ? " sacudida" : "")"
        }
        var line = "#\(index) t=\(s(at)) \(counted ? "contada" : "rechazada(\(rejection ?? "?"))") 1:[\(stroke(first))]"
        if let second { line += " 2:[\(stroke(second))]" }
        line += " baro=\(baroDelta.map(cm) ?? "?")/\(baroDeltaSecond.map(cm) ?? "?")\(baroCorroborated ? "(ok)" : "")"
        line += " prox_ciclo=\(cycleProximity.map { String(format: "%.2f", $0) } ?? "?") pasos=\(stepsInCycle.map(String.init) ?? "?")"
        return line
    }
}

// MARK: - Verificador

nonisolated struct PocketSitStandVerifier: ActivityVerifier, SourceLevelLimiting, AttemptDiagnosticsProviding {
    typealias Sample = PocketSitStandSample

    nonisolated enum K {
        static let standardGravity = 9.80665
        /// Medido en el iPhone: userAccel·ĝ > 0 al BAJAR el bolsillo. Arriba = −(userAccel·ĝ).
        static let upSign: Double = -1
        // Mesetas (postura quieta).
        static let plateauSeconds = 0.3
        static let plateauToleranceDeg = 3.0
        /// Una meseta larga que se aleja más que esto de su inicio se parte (giro lento).
        static let plateauSplitDeg = 6.0
        static let stillAccelG = 0.06
        static let stillRotation = 0.3
        // Posturas y transiciones.
        static let transitionDeg = 35.0
        static let anchorDeg = 17.0
        static let postureBlend = 0.2
        static let integrationMargin = 0.25
        static let minStroke = 0.05
        static let maxStroke = 0.80
        static let minStrokeSeconds = 0.3
        static let maxStrokeSeconds = 8.0
        static let minPeakSpeed = 0.08
        static let maxPeakSpeed = 2.5
        static let maxVote = 0.3
        static let maxDt = 0.1
        // Ciclo.
        static let maxCycleGapSeconds = 20.0
        static let walkingSteps = 4
        static let minCycleProximity = 0.6
        static let bufferSeconds = 40.0
        // Bolsillo.
        static let uncoveredBlockSeconds = 1.0
        static let recoverCoveredSeconds = 0.5
        // Sacudidas: RMS |userAccel| en 1 s y cruces de la vertical.
        static let shakeWindow = 1.0
        static let shakeAccelG = 0.3
        static let shakeCrossingG = 0.15
        static let shakeMinCrossings = 5
        // Barómetro.
        static let baroMinDelta = 0.08
        static let baroBaseWindow = 2.0
        static let baroLag = 1.0
        static let fullMinFraction = 0.5
    }

    nonisolated enum Phase: String, Sendable, Hashable { case calibrating, ready, done }

    private nonisolated struct Frame: Sendable {
        var t: Double
        var aUp: Double
        var accel2: Double
        var rot2: Double
        var gravity: SIMD3<Double>
        var proximity: Bool?
    }

    private nonisolated struct Posture: Sendable {
        var gravity: SIMD3<Double>
        /// Fin de la última meseta de esta postura (≤ 17°): inicio de la próxima transición.
        var anchorEnd: Double
        var parity: Int
    }

    private nonisolated struct CountedRep: Sendable {
        var first: PocketStroke
        var second: PocketStroke
        var baroCorroborated: Bool
        var baroContradicted: Bool
        var motionAgrees: Bool { first.motionAgrees && second.motionAgrees }
    }

    let kind: ActivityKind
    let spec: VerificationSpec
    private(set) var progress: VerifierProgress
    private(set) var diagnostics: [PocketSitStandAttempt] = []
    private(set) var anomalies: [Anomaly] = []
    private(set) var phase: Phase = .calibrating

    private var t0 = 0.0
    private var started = false
    private var frames: [Frame] = []
    // Meseta en curso.
    private var inPlateau = false
    private var plateauRef = SIMD3<Double>(0, 0, 0)
    private var plateauAttached = false
    // Postura y voto de "sentado".
    private var posture: Posture?
    private var seatedVote = 0.0
    private var pending: PocketStroke?
    private var lastAngle = 0.0
    // Señales de apoyo.
    private var steps: Int?
    private var proximityKnown = false
    private var uncoveredSince: Double?
    private var coveredSince: Double?
    private var blocked = false
    private var shakeAnomalyAt: Double?
    private var walkAnomalyLogged = false
    private var pocketAnomalyLogged = false
    private var baro: [(t: Double, h: Double)] = []
    private var reps: [CountedRep] = []

    init(spec: VerificationSpec, kind: ActivityKind = .pararseSentarse) {
        self.spec = spec
        self.kind = kind
        progress = VerifierProgress(target: spec.target, gate: .calibrating, hint: PocketSitStandCopy.pocket)
    }

    // MARK: Ciclo de vida

    mutating func start(at t: Double) {
        self = PocketSitStandVerifier(spec: spec, kind: kind)
        started = true
        t0 = t
    }

    mutating func ingest(_ s: PocketSitStandSample, at t: Double) -> [VerifierEvent] {
        if !started { start(at: t) }
        var events: [VerifierEvent] = []
        progress.elapsed = max(0, t - t0)
        guard phase != .done else { return events }

        if let h = s.altitude { baro.append((t, h)) }
        if let n = s.steps { steps = n }
        if s.proximityCovered != nil { proximityKnown = true }

        frames.append(Self.frame(s, t: t))
        if let first = frames.first, first.t < t - K.bufferSeconds {
            frames.removeFirst(frames.prefix { $0.t < t - K.bufferSeconds }.count)
        }
        detectShake(at: t, &events)
        updatePocketGate(s.proximityCovered, at: t, &events)
        trackPlateau(at: t, &events)

        progress.hint = currentHint()
        progress.debug = String(format: "giro=%.0f° postura=%@ reps=%d", lastAngle,
                                posture.map { $0.parity == 0 ? "A" : "B" } ?? "?", progress.count)
        return events
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        progress.elapsed = max(0, t - t0)
        let durations = reps.map { $0.second.endT - $0.first.startT }
        let mean = durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count)
        let maxRise = reps.map { max(abs($0.first.displacement), abs($0.second.displacement)) }.max()
        return ActivityOutcome(kind: kind,
                               target: spec.target,
                               achieved: progress.count,
                               completed: progress.count >= spec.target,
                               durationSeconds: max(0, t - t0),
                               metrics: .reps(count: progress.count, minDescentRatio: maxRise, meanRepSeconds: mean),
                               anomalies: anomalies,
                               reason: reason)
    }

    // MARK: Nivel

    /// `full` si el barómetro corrobora ≥ 50 % de las reps; si falta o no es concluyente (no contradice en
    /// ≥ 50 %), `full` si giro y desplazamiento coinciden en ≥ 50 %. Sin proximidad → `reduced`.
    func limitedSourceLevel(_ declared: SourceLevel) -> SourceLevel {
        guard declared == .live, !reps.isEmpty else { return declared }
        if !proximityKnown { return .fallback }
        let n = Double(reps.count)
        if Double(reps.filter(\.baroCorroborated).count) / n >= K.fullMinFraction { return declared }
        let contradicted = Double(reps.filter(\.baroContradicted).count) / n
        let agreed = Double(reps.filter(\.motionAgrees).count) / n
        if contradicted < K.fullMinFraction && agreed >= K.fullMinFraction { return declared }
        return .fallback
    }

    // MARK: Diagnóstico

    var attemptCount: Int { diagnostics.count }
    func attemptLine(_ index: Int) -> String { String(describing: diagnostics[index]) }

    // MARK: Muestras

    private static func frame(_ s: PocketSitStandSample, t: Double) -> Frame {
        let gLen = (s.gravity * s.gravity).sum().squareRoot()
        let down = gLen > 0.1 ? s.gravity / gLen : SIMD3<Double>(0, -1, 0)
        let along = (s.userAccel * down).sum()
        return Frame(t: t,
                     aUp: K.upSign * along * K.standardGravity,
                     accel2: (s.userAccel * s.userAccel).sum(),
                     rot2: (s.rotationRate * s.rotationRate).sum(),
                     gravity: down,
                     proximity: s.proximityCovered)
    }

    private static func normalized(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let n = (v * v).sum().squareRoot()
        return n > 1e-9 ? v / n : v
    }

    private static func angleDeg(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(min(1, max(-1, (a * b).sum()))) * 180 / .pi
    }

    // MARK: Mesetas

    /// Ventana de los últimos 0,3 s: estable si la gravedad queda a ≤ 3° de su media y la aceleración y el
    /// giro son de bolsillo en reposo. Devuelve la gravedad media y el inicio de la ventana.
    private func stableWindow(now: Double) -> (gravity: SIMD3<Double>, start: Double)? {
        guard let oldest = frames.first, now - oldest.t >= K.plateauSeconds * 0.9 else { return nil }
        var sum = SIMD3<Double>(0, 0, 0)
        var accel = 0.0, rot = 0.0, n = 0
        var start = now
        for f in frames.reversed() {
            guard f.t >= now - K.plateauSeconds else { break }
            sum += f.gravity
            accel += f.accel2
            rot += f.rot2
            n += 1
            start = f.t
        }
        guard n >= 5 else { return nil }
        let count = Double(n)
        guard (accel / count).squareRoot() < K.stillAccelG, (rot / count).squareRoot() < K.stillRotation else { return nil }
        let mean = Self.normalized(sum)
        let minCos = cos(K.plateauToleranceDeg * .pi / 180)
        for f in frames.reversed() {
            guard f.t >= start else { break }
            if (f.gravity * mean).sum() < minCos { return nil }
        }
        return (mean, start)
    }

    private mutating func trackPlateau(at t: Double, _ events: inout [VerifierEvent]) {
        guard let window = stableWindow(now: t) else {
            inPlateau = false
            return
        }
        if posture != nil { lastAngle = Self.angleDeg(window.gravity, posture!.gravity) }
        if inPlateau, Self.angleDeg(window.gravity, plateauRef) <= K.plateauSplitDeg {
            if plateauAttached, posture != nil { posture!.anchorEnd = t }
            return
        }
        inPlateau = true
        plateauRef = window.gravity
        plateauAttached = false
        onNewPlateau(gravity: window.gravity, start: window.start, now: t, &events)
    }

    private func coveredNow() -> Bool {
        guard proximityKnown else { return true }
        return frames.last?.proximity ?? false
    }

    private mutating func onNewPlateau(gravity g: SIMD3<Double>, start: Double, now: Double, _ events: inout [VerifierEvent]) {
        guard !blocked, coveredNow() else { return }
        if phase == .calibrating {
            phase = .ready
            posture = Posture(gravity: g, anchorEnd: now, parity: 0)
            plateauAttached = true
            progress.gate = .ready
            events.append(.gate(.ready))
            events.append(.cue(Cue(text: PocketSitStandCopy.calibrated, symbol: "checkmark.circle")))
            return
        }
        guard var current = posture else {
            // Vuelve al bolsillo: se recalibra la postura y el voto (la orientación puede haber cambiado).
            posture = Posture(gravity: g, anchorEnd: now, parity: 0)
            seatedVote = 0
            pending = nil
            plateauAttached = true
            return
        }
        let angle = Self.angleDeg(g, current.gravity)
        lastAngle = angle
        if angle <= K.anchorDeg {
            current.gravity = Self.normalized(current.gravity * (1 - K.postureBlend) + g * K.postureBlend)
            current.anchorEnd = now
            posture = current
            plateauAttached = true
        } else if angle >= K.transitionDeg {
            let stroke = measure(from: current.anchorEnd, to: start, rotation: angle, toParity: 1 - current.parity)
            posture = Posture(gravity: g, anchorEnd: now, parity: 1 - current.parity)
            plateauAttached = true
            handle(stroke, &events)
        }
        // Entre 17° y 35°: postura parcial; no cuenta ni mueve el ancla.
    }

    // MARK: Transición: desplazamiento de meseta a meseta

    /// Integra la aceleración vertical en [a − 0,25 s, b + 0,25 s] con la velocidad corregida linealmente
    /// (v = 0 en ambas mesetas: quita el sesgo sin exigir quietud perfecta) y vota qué postura es "sentado".
    private mutating func measure(from a: Double, to b: Double, rotation: Double, toParity: Int) -> PocketStroke {
        let lo = a - K.integrationMargin, hi = b + K.integrationMargin
        let window = frames.filter { $0.t >= lo && $0.t <= hi }
        var displacement = 0.0, peak = 0.0
        if window.count >= 3 {
            var v = 0.0
            var velocities: [Double] = [0]
            for i in 1..<window.count {
                let dt = min(K.maxDt, max(0, window[i].t - window[i - 1].t))
                v += 0.5 * (window[i].aUp + window[i - 1].aUp) * dt
                velocities.append(v)
            }
            let t0w = window[0].t
            let span = max(1e-3, window[window.count - 1].t - t0w)
            let vEnd = v
            for i in 1..<window.count {
                let dt = min(K.maxDt, max(0, window[i].t - window[i - 1].t))
                let corrected = velocities[i] - vEnd * (window[i].t - t0w) / span
                displacement += corrected * dt
                peak = max(peak, abs(corrected))
            }
        }
        let inside = window.filter { $0.t >= a && $0.t <= b }
        let known = inside.filter { $0.proximity != nil }
        let proximity = known.isEmpty ? nil : Double(known.filter { $0.proximity == true }.count) / Double(known.count)
        // Voto: bajar hacia la postura de llegada = esa postura es "sentado".
        if abs(displacement) >= K.minStroke {
            let towardsB = toParity == 1 ? 1.0 : -1.0
            seatedVote += towardsB * (displacement < 0 ? 1 : -1) * min(abs(displacement), K.maxVote)
        }
        let toSeated: Bool? = seatedVote == 0 ? nil : ((seatedVote > 0) == (toParity == 1))
        return PocketStroke(displacement: displacement, startT: a, endT: b, peakSpeed: peak, rotationDeg: rotation,
                            toParity: toParity, toSeated: toSeated, proximityFraction: proximity,
                            shaky: Self.isShaky(inside), stepsAtStart: steps)
    }

    private static func isShaky(_ window: [Frame]) -> Bool {
        guard window.count >= 10 else { return false }
        let rms = (window.reduce(0) { $0 + $1.accel2 } / Double(window.count)).squareRoot()
        guard rms >= K.shakeAccelG else { return false }
        return crossings(window) >= K.shakeMinCrossings
    }

    private static func crossings(_ window: [Frame]) -> Int {
        var crossings = 0
        var sign = 0
        let threshold = K.shakeCrossingG * K.standardGravity
        for f in window {
            let s = f.aUp > threshold ? 1 : (f.aUp < -threshold ? -1 : 0)
            if s != 0 && s != sign {
                if sign != 0 { crossings += 1 }
                sign = s
            }
        }
        return crossings
    }

    // MARK: Ciclo → rep

    private func strokeRejection(_ k: PocketStroke) -> (reason: String, cue: String)? {
        if k.shaky { return ("shaking", PocketSitStandCopy.shaking) }
        if k.seconds > K.maxStrokeSeconds { return ("tooSlow", PocketSitStandCopy.tooSlow) }
        if k.seconds < K.minStrokeSeconds { return ("tooFast", PocketSitStandCopy.tooFast) }
        if abs(k.displacement) > K.maxStroke { return ("tooLarge", PocketSitStandCopy.jerky) }
        if !k.motionAgrees { return ("soloGiro", PocketSitStandCopy.partial) }
        if k.peakSpeed < K.minPeakSpeed { return ("tooSlow", PocketSitStandCopy.tooSlow) }
        if k.peakSpeed > K.maxPeakSpeed { return ("tooFast", PocketSitStandCopy.tooFast) }
        return nil
    }

    private mutating func handle(_ k: PocketStroke, _ events: inout [VerifierEvent]) {
        let at = k.endT - t0
        if let rejection = strokeRejection(k) {
            pending = nil
            reject(first: k, second: nil, reason: rejection.reason, cue: rejection.cue, at: at, &events)
            return
        }
        guard let first = pending, first.toParity != k.toParity, k.startT - first.endT <= K.maxCycleGapSeconds else {
            pending = k
            return
        }
        pending = nil
        let stepsInCycle: Int? = {
            guard let s0 = first.stepsAtStart, let now = steps else { return nil }
            return now - s0
        }()
        let cycleProximity = proximityFraction(from: first.startT, to: k.endT)
        if let stepsInCycle, stepsInCycle >= K.walkingSteps {
            if !walkAnomalyLogged {
                walkAnomalyLogged = true
                anomalies.append(Anomaly(kind: PocketSitStandAnomaly.walking, severity: .soft, at: at, detail: "\(stepsInCycle) pasos en un ciclo"))
            }
            reject(first: first, second: k, reason: "walking", cue: PocketSitStandCopy.walking, at: at,
                   cycleProximity: cycleProximity, stepsInCycle: stepsInCycle, &events)
            return
        }
        if let cycleProximity, cycleProximity < K.minCycleProximity {
            reject(first: first, second: k, reason: "notInPocket", cue: PocketSitStandCopy.outOfPocket, at: at,
                   cycleProximity: cycleProximity, stepsInCycle: stepsInCycle, &events)
            return
        }
        let b1 = baroDelta(first), b2 = baroDelta(k)
        let corroborated = baroVerdict(first, b1) == 1 || baroVerdict(k, b2) == 1
        let contradicted = !corroborated && (baroVerdict(first, b1) == -1 || baroVerdict(k, b2) == -1)
        reps.append(CountedRep(first: first, second: k, baroCorroborated: corroborated, baroContradicted: contradicted))
        progress.count += 1
        diagnostics.append(PocketSitStandAttempt(index: diagnostics.count + 1, at: at, counted: true, rejection: nil,
                                                 first: first, second: k, baroDelta: b1, baroDeltaSecond: b2,
                                                 baroCorroborated: corroborated, cycleProximity: cycleProximity,
                                                 stepsInCycle: stepsInCycle))
        events.append(.rep(progress.count))
        if progress.count >= spec.target {
            phase = .done
            progress.hint = PocketSitStandCopy.done
            events.append(.completed)
        }
    }

    private mutating func reject(first: PocketStroke, second: PocketStroke?, reason: String, cue: String, at: Double,
                                 cycleProximity: Double? = nil, stepsInCycle: Int? = nil, _ events: inout [VerifierEvent]) {
        diagnostics.append(PocketSitStandAttempt(index: diagnostics.count + 1, at: at, counted: false, rejection: reason,
                                                 first: first, second: second, baroDelta: baroDelta(first),
                                                 baroDeltaSecond: second.flatMap(baroDelta), baroCorroborated: false,
                                                 cycleProximity: cycleProximity, stepsInCycle: stepsInCycle))
        events.append(.cue(Cue(text: cue, symbol: "info.circle")))
    }

    private func proximityFraction(from a: Double, to b: Double) -> Double? {
        var known = 0, covered = 0
        for f in frames where f.t >= a && f.t <= b {
            guard let p = f.proximity else { continue }
            known += 1
            if p { covered += 1 }
        }
        return known > 0 ? Double(covered) / Double(known) : nil
    }

    // MARK: Barómetro

    /// Δ altura barométrica en la transición: mediana en [inicio − 2 s, inicio + 0,3 s] contra mediana en
    /// [fin − 0,2 s, fin + 1 s] (el barómetro llega con retardo). nil si falta alguna de las dos ventanas.
    private func baroDelta(_ k: PocketStroke) -> Double? {
        let before = baro.filter { $0.t >= k.startT - K.baroBaseWindow && $0.t <= k.startT + 0.3 }.map(\.h)
        let after = baro.filter { $0.t >= k.endT - 0.2 && $0.t <= k.endT + K.baroLag }.map(\.h)
        guard let b = Self.median(before.isEmpty ? baro.last(where: { $0.t < k.startT }).map { [$0.h] } ?? [] : before),
              let a = Self.median(after) else { return nil }
        return a - b
    }

    /// 1 = el barómetro ve ≥ 8 cm en el sentido de la transición; −1 = ≥ 8 cm al revés; 0 = no concluye.
    private func baroVerdict(_ k: PocketStroke, _ delta: Double?) -> Int {
        guard let delta, let toSeated = k.toSeated else { return 0 }
        let along = delta * (toSeated ? -1 : 1)
        if along >= K.baroMinDelta { return 1 }
        if along <= -K.baroMinDelta { return -1 }
        return 0
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: Bolsillo y sacudidas

    private mutating func updatePocketGate(_ covered: Bool?, at t: Double, _ events: inout [VerifierEvent]) {
        guard let covered else { return }
        if covered {
            uncoveredSince = nil
            coveredSince = coveredSince ?? t
        } else {
            coveredSince = nil
            uncoveredSince = uncoveredSince ?? t
        }
        if !blocked, let since = uncoveredSince, t - since >= K.uncoveredBlockSeconds, phase == .ready {
            blocked = true
            pending = nil
            posture = nil
            progress.gate = .blocked(reason: PocketSitStandCopy.outOfPocket)
            events.append(.gate(progress.gate))
            if !pocketAnomalyLogged {
                pocketAnomalyLogged = true
                anomalies.append(Anomaly(kind: PocketSitStandAnomaly.notInPocket, severity: .soft, at: t - t0,
                                         detail: "El teléfono salió del bolsillo"))
            }
        } else if blocked, let since = coveredSince, t - since >= K.recoverCoveredSeconds {
            blocked = false
            progress.gate = .ready
            events.append(.gate(.ready))
        }
    }

    /// Aviso y anomalía de sacudida (meter o sacar el teléfono del bolsillo también la dispara; eso está bien).
    /// El rechazo de una transición sacudida se decide dentro de su propia ventana (`isShaky`).
    private mutating func detectShake(at t: Double, _ events: inout [VerifierEvent]) {
        var recent: [Frame] = []
        for f in frames.reversed() {
            guard f.t >= t - K.shakeWindow else { break }
            recent.append(f)
        }
        guard Self.isShaky(recent.reversed()) else { return }
        pending = nil
        if shakeAnomalyAt.map({ t - $0 >= 30 }) ?? true {
            shakeAnomalyAt = t
            anomalies.append(Anomaly(kind: PocketSitStandAnomaly.shaking, severity: .soft, at: t - t0, detail: nil))
            events.append(.cue(Cue(text: PocketSitStandCopy.shaking, symbol: "exclamationmark.triangle")))
        }
    }

    private func currentHint() -> String {
        switch phase {
        case .done: return PocketSitStandCopy.done
        case .calibrating:
            if proximityKnown && !(frames.last?.proximity ?? false) { return PocketSitStandCopy.pocket }
            return PocketSitStandCopy.holdStill
        case .ready:
            return blocked ? PocketSitStandCopy.outOfPocket : PocketSitStandCopy.go
        }
    }
}

// MARK: - Sintetizador (tests y replay del simulador)

/// Cinemática del muslo con el teléfono en el bolsillo: transiciones sentado ↔ de pie con perfil de jerk
/// mínimo (Δaltura vertical, avance horizontal y giro del muslo), orientación del teléfono al azar en el
/// bolsillo, ruido del acelerómetro y del giróscopo, y barómetro con ruido. Determinista por semilla.
nonisolated struct PocketSitStandSynth: Sendable {
    nonisolated struct Options: Sendable, Hashable {
        var hz: Double = 50
        var rise: Double = 0.30
        var forward: Double = 0.15
        var thighRotationDeg: Double = 70
        var accelNoiseG: Double = 0.003
        var gyroNoise: Double = 0.01
        var baroHz: Double = 1
        var baroNoise: Double = 0.03
        var baroAvailable = true
        var proximity: Bool? = true
    }

    private(set) var samples: [PocketSitStandSample] = []
    let options: Options
    private var rng: FaceChallengeRNG
    private var t = 0.0
    /// Altura del bolsillo (m, 0 = sentado), avance (m) y giro del muslo (rad, 0 = sentado/horizontal).
    private var height = 0.0
    private var forwardPos = 0.0
    private var thigh = 0.0
    private var nextBaroAt = 0.0
    /// Rotación fija del teléfono dentro del bolsillo (marco muslo → marco teléfono).
    private let pocket: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)

    init(seed: UInt64, options: Options = Options()) {
        self.options = options
        rng = FaceChallengeRNG(seed: seed)
        let yaw = Double(rng.next() % 360) * .pi / 180
        let roll = Double(rng.next() % 360) * .pi / 180
        // Base ortonormal al azar: rota (x, y, z) por yaw en z y roll en x.
        func rot(_ v: SIMD3<Double>) -> SIMD3<Double> {
            let a = SIMD3(v.x * cos(yaw) - v.y * sin(yaw), v.x * sin(yaw) + v.y * cos(yaw), v.z)
            return SIMD3(a.x, a.y * cos(roll) - a.z * sin(roll), a.y * sin(roll) + a.z * cos(roll))
        }
        pocket = (rot(SIMD3(1, 0, 0)), rot(SIMD3(0, 1, 0)), rot(SIMD3(0, 0, 1)))
    }

    private mutating func gaussian() -> Double {
        let u1 = max(1e-9, Double(rng.next() % 1_000_000) / 1_000_000)
        let u2 = Double(rng.next() % 1_000_000) / 1_000_000
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// Mundo (x adelante, y lateral, z arriba) → teléfono, según el giro del muslo y la orientación en el bolsillo.
    private func toPhone(_ w: SIMD3<Double>) -> SIMD3<Double> {
        // Muslo: gira `thigh` alrededor del eje lateral (y).
        let c = cos(thigh), s = sin(thigh)
        let m = SIMD3(w.x * c - w.z * s, w.y, w.x * s + w.z * c)
        return SIMD3((m * pocket.0).sum(), (m * pocket.1).sum(), (m * pocket.2).sum())
    }

    private mutating func emit(accelUp: Double, accelForward: Double, thighRate: Double) {
        let dt = 1 / options.hz
        // CoreMotion (medido en el iPhone): userAcceleration va en el sentido de la aceleración física (g);
        // gravity apunta hacia abajo. Así userAccel·ĝ > 0 al bajar, como en el bolsillo real.
        let kin = SIMD3(accelForward, 0, accelUp) / PocketSitStandVerifier.K.standardGravity
        var user = toPhone(kin)
        user += SIMD3(gaussian(), gaussian(), gaussian()) * options.accelNoiseG
        let gravity = toPhone(SIMD3(0, 0, -1))
        var rate = toPhone(SIMD3(0, thighRate, 0))
        rate += SIMD3(gaussian(), gaussian(), gaussian()) * options.gyroNoise
        var altitude: Double?
        if options.baroAvailable, t >= nextBaroAt {
            nextBaroAt = t + 1 / options.baroHz
            altitude = height + gaussian() * options.baroNoise
        }
        samples.append(PocketSitStandSample(t: t, userAccel: user, gravity: gravity, rotationRate: rate,
                                            altitude: altitude, steps: 0, proximityCovered: options.proximity))
        t += dt
    }

    mutating func hold(_ seconds: Double) {
        for _ in 0..<Int((seconds * options.hz).rounded()) { emit(accelUp: 0, accelForward: 0, thighRate: 0) }
    }

    /// Transición de jerk mínimo: Δaltura `dh`, avance `dx` y giro del muslo `dTheta` (rad) en `seconds`.
    mutating func move(seconds: Double, dh: Double, dx: Double, dTheta: Double) {
        let n = max(2, Int((seconds * options.hz).rounded()))
        let T = seconds
        for i in 0..<n {
            let tau = Double(i) / Double(n)
            let acc = (60 * tau - 180 * tau * tau + 120 * tau * tau * tau) / (T * T)
            let vel = (30 * tau * tau - 60 * tau * tau * tau + 30 * tau * tau * tau * tau) / T
            emit(accelUp: dh * acc, accelForward: dx * acc, thighRate: dTheta * vel)
            let pos = 10 * pow(tau, 3) - 15 * pow(tau, 4) + 6 * pow(tau, 5)
            let next = Double(i + 1) / Double(n)
            let posNext = 10 * pow(next, 3) - 15 * pow(next, 4) + 6 * pow(next, 5)
            height += dh * (posNext - pos)
            forwardPos += dx * (posNext - pos)
            thigh += dTheta * (posNext - pos)
        }
    }

    mutating func standUp(seconds: Double) {
        move(seconds: seconds, dh: options.rise, dx: options.forward, dTheta: options.thighRotationDeg * .pi / 180)
    }

    mutating func sitDown(seconds: Double) {
        move(seconds: seconds, dh: -options.rise, dx: -options.forward, dTheta: -options.thighRotationDeg * .pi / 180)
    }

    /// Serie honesta que parte sentada: `count` ciclos con duraciones algo variables.
    mutating func series(count: Int, startStanding: Bool = false) {
        hold(1.5)
        for _ in 0..<count {
            let up = 1.2 + Double(rng.next() % 100) / 100
            let down = 1.2 + Double(rng.next() % 100) / 100
            let seatedPause = 0.8 + Double(rng.next() % 60) / 100
            let standPause = 0.3 + Double(rng.next() % 60) / 100
            if startStanding {
                sitDown(seconds: down); hold(seatedPause)
                standUp(seconds: up); hold(standPause)
            } else {
                standUp(seconds: up); hold(standPause)
                sitDown(seconds: down); hold(seatedPause)
            }
        }
        hold(1)
    }

    /// Replay del simulador: una serie con una rep de margen sobre la meta.
    static func completing(_ verifier: PocketSitStandVerifier, seed: UInt64 = 11) -> [PocketSitStandSample] {
        var synth = PocketSitStandSynth(seed: seed)
        synth.series(count: verifier.spec.target + 1)
        return synth.samples
    }
}
