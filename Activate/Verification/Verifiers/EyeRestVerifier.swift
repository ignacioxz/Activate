import Foundation

// Dueño: agente "face". Máquina de estados pura para A9 "Pestañeo completo".
// Sin imports de ARKit: se alimenta de `FaceSample` (fuente en vivo o replay de fixtures).

/// A9: parpadeos **completos** hasta la meta.
/// Cierre bilateral `min(blinkL, blinkR) ≥ closedThreshold`, reapertura `max ≤ openThreshold`, duración
/// 50-500 ms; los parciales (pico ≥ partialThreshold) se cuentan aparte. La actividad termina al llegar
/// a la meta de parpadeos completos (sin fase de mirar lejos).
nonisolated struct EyeRestVerifier: ActivityVerifier {
    typealias Sample = FaceSample

    nonisolated enum Phase: String, Sendable, Codable { case blinks, done }

    // MARK: Constantes (valores iniciales; se calibran en el iPhone)

    /// Cierre bilateral mínimo (coeficiente `eyeBlink` de ARKit, 0-1) para que el parpadeo sea completo.
    static let closedThreshold: Float = 0.8
    /// Por debajo de esto los dos ojos se consideran abiertos (reapertura).
    static let openThreshold: Float = 0.3
    /// Pico mínimo para contar un parpadeo parcial (clínicamente relevante frente a pantallas).
    static let partialThreshold: Float = 0.5
    static let minBlinkSeconds: Double = 0.05
    static let maxBlinkSeconds: Double = 0.5

    static let cueBlink = Cue(text: "Pestañee fuerte", symbol: "eye")
    static let anomalyStatic = "static"
    static let blockedReason = "Mire al teléfono"
    static let hintBlink = "Cierre bien los ojos"
    static let hintDone = "Ojos listos"

    // MARK: Estado

    let kind: ActivityKind = .ojos
    let spec: VerificationSpec
    private(set) var progress: VerifierProgress
    private(set) var phase: Phase = .blinks
    private(set) var completeBlinks = 0
    private(set) var partialBlinks = 0
    private(set) var anomalies: [Anomaly] = []

    var isCompleted: Bool { phase == .done }

    private var liveness = FaceLivenessMonitor()
    private var t0: Double = 0
    private var started = false
    private var completedAt: Double?
    // Detector de parpadeo.
    private var closureStart: Double?
    private var closurePeak: Float = 0

    init(spec: VerificationSpec) {
        self.spec = spec
        progress = VerifierProgress(target: spec.target, gate: .calibrating, hint: Self.hintBlink)
    }

    // MARK: ActivityVerifier

    mutating func start(at t: Double) {
        t0 = t
        started = false
        liveness.start(at: t)
        progress = VerifierProgress(target: spec.target, gate: .calibrating, hint: Self.hintBlink)
    }

    mutating func ingest(_ sample: FaceSample, at t: Double) -> [VerifierEvent] {
        var events: [VerifierEvent] = []
        progress.elapsed = t - t0

        for change in liveness.observe(sample, at: t) {
            switch change {
            case .blocked:
                progress.gate = .blocked(reason: Self.blockedReason)
                events.append(.gate(progress.gate))
            case .recovered:
                progress.gate = .ready
                events.append(.gate(.ready))
            case .staticDetected:
                events.append(record(Anomaly(kind: Self.anomalyStatic, severity: .hard, at: t - t0,
                                             detail: "Sin movimiento facial \(Int(FaceLivenessMonitor.staticSeconds)) s")))
            }
        }

        guard sample.isTracked else {
            closureStart = nil
            return events
        }
        guard phase == .blinks else { return events }

        if !started {
            started = true
            progress.gate = .ready
            events.append(.gate(.ready))
            events.append(.cue(Self.cueBlink))
        }
        events += detectBlink(sample, at: t)
        if completeBlinks >= spec.target {
            phase = .done
            completedAt = t
            progress.hint = Self.hintDone
            events.append(.completed)
        }
        return events
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        progress.elapsed = t - t0
        let blinkMinutes = max(((completedAt ?? t) - t0), 1e-3) / 60
        return ActivityOutcome(
            kind: kind,
            target: spec.target,
            achieved: completeBlinks,
            completed: phase == .done,
            durationSeconds: max(0, t - t0),
            metrics: .eyes(completeBlinks: completeBlinks, partialBlinks: partialBlinks,
                           blinksPerMinute: Double(completeBlinks) / blinkMinutes,
                           farGazeSeconds: 0),
            anomalies: anomalies,
            reason: reason
        )
    }

    // MARK: Parpadeo

    private mutating func detectBlink(_ sample: FaceSample, at t: Double) -> [VerifierEvent] {
        let closure = min(sample.blinkL, sample.blinkR)
        let opening = max(sample.blinkL, sample.blinkR)
        guard let start = closureStart else {
            if opening > Self.openThreshold {
                closureStart = t
                closurePeak = closure
            }
            return []
        }
        closurePeak = max(closurePeak, closure)
        guard opening <= Self.openThreshold else { return [] }
        closureStart = nil
        let duration = t - start
        guard duration >= Self.minBlinkSeconds, duration <= Self.maxBlinkSeconds else { return [] }
        if closurePeak >= Self.closedThreshold {
            completeBlinks += 1
            progress.count = completeBlinks
            return [.rep(completeBlinks), .progress(progress.fraction)]
        }
        if closurePeak >= Self.partialThreshold {
            partialBlinks += 1
        }
        return []
    }

    private mutating func record(_ anomaly: Anomaly) -> VerifierEvent {
        anomalies.append(anomaly)
        return .anomaly(anomaly)
    }
}
