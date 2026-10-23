import Foundation

// Dueño: paquete "stroop-breath".
//
// Máquina de estados pura de la respiración diafragmática (A8 "Respira con la guata").
//
// Patrón: tras `leadInSeconds` de preparación, ciclos de `inhaleSeconds` (tomar aire) +
// `exhaleSeconds` (soltar el aire), anclados en el `t` de `start(at:)`. La vista anima el mismo
// patrón con `BreathVerifier.phase(at:)` sobre el reloj de `ScreenSource` y envía
// `.touchDown(t:)` / `.touchUp(t:)` mientras la persona mantiene el dedo apoyado.
//
// Un ciclo cuenta si el dedo estuvo apoyado ≥ `minHoldInExhaleSeconds` dentro de su ventana de
// exhalación y ≤ `maxHoldInInhaleSeconds` dentro de su inhalación (mantener el dedo siempre
// apretado no cuenta: hay que soltarlo al tomar aire). Los ciclos siguen hasta llegar a la meta
// (el runner corta por `maxDurationSeconds`). Se evalúa en cada `.touchUp` y en `finish`.
//
// Es verificación débil por naturaleza (`ActivityKind.weakByNature`): la política la baja a
// `reduced`; aquí no hay anomalías.
nonisolated struct BreathVerifier: ActivityVerifier {
    typealias Sample = ScreenSample

    // MARK: - Constantes nombradas (valores iniciales)

    static let leadInSeconds: Double = 2
    static let inhaleSeconds: Double = 4
    static let exhaleSeconds: Double = 6
    static var cycleSeconds: Double { inhaleSeconds + exhaleSeconds }
    static let minHoldInExhaleSeconds: Double = 5
    static let maxHoldInInhaleSeconds: Double = 2

    /// Fase del patrón para una marca de tiempo (la vista la usa para animar).
    nonisolated struct Phase: Sendable, Equatable {
        var cycle: Int
        var inhaling: Bool
        /// 0-1 dentro de la fase actual.
        var fraction: Double
        var leadIn: Bool
    }

    /// Fase del patrón en `elapsed` segundos desde el inicio (misma aritmética que el verificador).
    static func phase(at elapsed: Double) -> Phase {
        guard elapsed >= leadInSeconds else {
            return Phase(cycle: 0, inhaling: true, fraction: max(0, elapsed / leadInSeconds), leadIn: true)
        }
        let e = elapsed - leadInSeconds
        let cycle = Int(e / cycleSeconds)
        let within = e - Double(cycle) * cycleSeconds
        if within < inhaleSeconds {
            return Phase(cycle: cycle, inhaling: true, fraction: within / inhaleSeconds, leadIn: false)
        }
        return Phase(cycle: cycle, inhaling: false, fraction: (within - inhaleSeconds) / exhaleSeconds, leadIn: false)
    }

    // MARK: - Estado

    let kind: ActivityKind = .respiracion
    let spec: VerificationSpec
    private(set) var progress: VerifierProgress

    private var startT: Double = 0
    private var pressStart: Double? = nil
    private var exhaleHold: [Int: Double] = [:]
    private var inhaleHold: [Int: Double] = [:]
    private var counted: Set<Int> = []
    private var done = false

    init(spec: VerificationSpec) {
        self.spec = spec
        progress = VerifierProgress(target: spec.target, gate: .calibrating, hint: "Mantenga el dedo al soltar el aire")
    }

    var cycles: Int { counted.count }

    // MARK: - ActivityVerifier

    mutating func start(at t: Double) {
        startT = t
        progress.gate = .ready
        progress.hint = "Mantenga el dedo al soltar el aire"
        progress.elapsed = 0
    }

    mutating func ingest(_ sample: ScreenSample, at t: Double) -> [VerifierEvent] {
        progress.elapsed = max(0, t - startT)
        guard !done else { return [] }
        switch sample {
        case .touchDown(let ts):
            if pressStart == nil { pressStart = ts }
            return []
        case .touchUp(let ts):
            if let s = pressStart {
                pressStart = nil
                accumulate(from: s, to: ts)
            }
            return evaluate(at: t)
        default:
            return []
        }
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        if let s = pressStart {
            pressStart = nil
            accumulate(from: s, to: t)
            _ = evaluate(at: t)
        }
        done = true
        let completed = cycles >= spec.target && (reason == .completed || reason == .timeout)
        progress.count = cycles
        progress.hint = completed ? "Listo." : "Faltaron ciclos"
        return ActivityOutcome(kind: kind, target: spec.target, achieved: cycles, completed: completed,
                               durationSeconds: max(0, t - startT), metrics: .breath(cycles: cycles),
                               anomalies: [], reason: reason)
    }

    // MARK: - Privado

    /// Reparte un intervalo de dedo apoyado [s, e] entre las ventanas de inhalación/exhalación que toca.
    private mutating func accumulate(from s: Double, to e: Double) {
        guard e > s else { return }
        let origin = startT + Self.leadInSeconds
        let firstCycle = max(0, Int((s - origin) / Self.cycleSeconds))
        let lastCycle = max(0, Int((e - origin) / Self.cycleSeconds))
        guard lastCycle >= firstCycle else { return }
        for k in firstCycle...lastCycle {
            let inhaleStart = origin + Double(k) * Self.cycleSeconds
            let exhaleStart = inhaleStart + Self.inhaleSeconds
            let exhaleEnd = inhaleStart + Self.cycleSeconds
            let inhale = Self.overlap(s, e, inhaleStart, exhaleStart)
            let exhale = Self.overlap(s, e, exhaleStart, exhaleEnd)
            if inhale > 0 { inhaleHold[k, default: 0] += inhale }
            if exhale > 0 { exhaleHold[k, default: 0] += exhale }
        }
    }

    private static func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0, min(a1, b1) - max(a0, b0))
    }

    private mutating func evaluate(at t: Double) -> [VerifierEvent] {
        var events: [VerifierEvent] = []
        for k in exhaleHold.keys.sorted() where !counted.contains(k) {
            let exhale = exhaleHold[k] ?? 0
            let inhale = inhaleHold[k] ?? 0
            if exhale >= Self.minHoldInExhaleSeconds && inhale <= Self.maxHoldInInhaleSeconds {
                counted.insert(k)
                progress.count = cycles
                events.append(.rep(cycles))
            }
        }
        if !events.isEmpty { events.append(.progress(progress.fraction)) }
        if cycles >= spec.target {
            done = true
            progress.hint = "Listo."
            events.append(.completed)
        }
        return events
    }
}
