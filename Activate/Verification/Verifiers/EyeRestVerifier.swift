import Foundation
import simd

// Dueño: agente "face". Máquina de estados pura para A9 "Mira lejos y pestañea".
// Sin imports de ARKit: se alimenta de `FaceSample` (fuente en vivo o replay de fixtures).

/// A9 en dos fases.
/// - Fase A, parpadeos **completos**: cierre bilateral `min(blinkL, blinkR) ≥ closedThreshold`, reapertura
///   `max ≤ openThreshold`, duración 50-500 ms; los parciales (pico ≥ partialThreshold) se cuentan aparte.
/// - Fase B, descanso visual: 2 s de calibración mirando la pantalla (θ₀ = ángulo entre la mirada y la
///   dirección a la cámara, en el espacio de la cara) y después se acumula descanso mientras θ ≥ θ₀ + 12°,
///   ojos abiertos, cara detectada y cabeza no agachada, con 1 s de gracia. Meta 20 s reales (8 s en demo).
///   No se usa la longitud de `lookAtPoint` (escala no documentada): solo su dirección.
nonisolated struct EyeRestVerifier: ActivityVerifier {
    typealias Sample = FaceSample

    nonisolated enum Phase: String, Sendable, Codable { case blinks, gazeCalibration, gaze, done }

    // MARK: Constantes (valores iniciales; se calibran en el iPhone)

    /// Cierre bilateral mínimo (coeficiente `eyeBlink` de ARKit, 0-1) para que el parpadeo sea completo.
    static let closedThreshold: Float = 0.8
    /// Por debajo de esto los dos ojos se consideran abiertos (reapertura).
    static let openThreshold: Float = 0.3
    /// Pico mínimo para contar un parpadeo parcial (clínicamente relevante frente a pantallas).
    static let partialThreshold: Float = 0.5
    static let minBlinkSeconds: Double = 0.05
    static let maxBlinkSeconds: Double = 0.5
    static let gazeCalibrationSeconds: Double = 2
    static let minGazeCalibrationSamples = 10
    /// Descanso = mirada desviada al menos esto respecto de la calibración mirando la pantalla.
    static let farGazeDeltaDegrees: Double = 12
    /// Pitch relativo mínimo: más abajo que esto es "cabeza agachada" (mirando al suelo, no lejos).
    static let minRelativePitchDegrees: Double = -20
    /// Pérdidas de la condición más cortas que esto siguen acumulando.
    static let graceSeconds: Double = 1
    static let farGazeGoalSeconds: Double = 20
    static let farGazeGoalDemoSeconds: Double = 8
    /// Huecos entre muestras mayores que esto no acumulan (pérdida de frames).
    static let maxSampleGapSeconds: Double = 0.2

    static let cueBlink = Cue(text: "Pestañee fuerte", symbol: "eye")
    static let cueLookAtScreen = Cue(text: "Mire la pantalla", symbol: "iphone")
    static let cueLookFar = Cue(text: "Ahora mire lejos", symbol: "binoculars")
    static let anomalyStatic = "static"
    static let blockedReasonBlinks = "Mire al teléfono"
    static let blockedReasonGaze = "Cara frente al teléfono"
    static let hintBlink = "Cierre bien los ojos"
    static let hintCalibrating = "Mire la pantalla"
    static let hintFar = "Mire lejos"
    static let hintDone = "Ojos listos"

    // MARK: Estado

    let kind: ActivityKind = .ojos
    let spec: VerificationSpec
    private(set) var progress: VerifierProgress
    private(set) var phase: Phase = .blinks
    private(set) var completeBlinks = 0
    private(set) var partialBlinks = 0
    private(set) var farGazeSeconds: Double = 0
    private(set) var anomalies: [Anomaly] = []

    var farGazeGoal: Double { spec.demo ? Self.farGazeGoalDemoSeconds : Self.farGazeGoalSeconds }
    var isCompleted: Bool { phase == .done }

    private var liveness = FaceLivenessMonitor()
    private var t0: Double = 0
    private var started = false
    private var blinkPhaseEndedAt: Double?
    // Detector de parpadeo.
    private var closureStart: Double?
    private var closurePeak: Float = 0
    // Calibración de mirada.
    private var calibrationStart: Double?
    private var thetaSum: Double = 0
    private var pitchSum: Double = 0
    private var calibrationCount = 0
    private var theta0: Double = 0
    private var neutralPitch: Double = 0
    // Acumulación de descanso.
    private var previousT: Double?
    private var lapseSince: Double?
    private var lastReportedSecond = -1

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
                let reason = phase == .blinks ? Self.blockedReasonBlinks : Self.blockedReasonGaze
                progress.gate = .blocked(reason: reason)
                events.append(.gate(progress.gate))
            case .recovered:
                if phase != .gazeCalibration {
                    progress.gate = .ready
                    events.append(.gate(.ready))
                }
            case .staticDetected:
                events.append(record(Anomaly(kind: Self.anomalyStatic, severity: .hard, at: t - t0,
                                             detail: "Sin movimiento facial \(Int(FaceLivenessMonitor.staticSeconds)) s")))
            }
        }

        guard sample.isTracked else {
            closureStart = nil
            previousT = nil
            return events
        }

        switch phase {
        case .blinks:
            if !started {
                started = true
                progress.gate = .ready
                events.append(.gate(.ready))
                events.append(.cue(Self.cueBlink))
            }
            events += detectBlink(sample, at: t)
            if completeBlinks >= spec.target {
                blinkPhaseEndedAt = t
                phase = .gazeCalibration
                calibrationStart = nil
                progress.gate = .calibrating
                progress.hint = Self.hintCalibrating
                events.append(.gate(.calibrating))
                events.append(.cue(Self.cueLookAtScreen))
            }
        case .gazeCalibration:
            events += calibrateGaze(sample, at: t)
        case .gaze:
            events += accumulateGaze(sample, at: t)
        case .done:
            break
        }
        return events
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        progress.elapsed = t - t0
        let blinkMinutes = max(((blinkPhaseEndedAt ?? t) - t0), 1e-3) / 60
        return ActivityOutcome(
            kind: kind,
            target: spec.target,
            achieved: completeBlinks,
            completed: phase == .done,
            durationSeconds: max(0, t - t0),
            metrics: .eyes(completeBlinks: completeBlinks, partialBlinks: partialBlinks,
                           blinksPerMinute: Double(completeBlinks) / blinkMinutes,
                           farGazeSeconds: farGazeSeconds),
            anomalies: anomalies,
            reason: reason
        )
    }

    // MARK: Fase A

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
            return [.rep(completeBlinks), .progress(overallFraction)]
        }
        if closurePeak >= Self.partialThreshold {
            partialBlinks += 1
        }
        return []
    }

    // MARK: Fase B

    /// Ángulo (grados) entre la dirección de la mirada y la dirección a la cámara, ambas en el espacio de la cara.
    static func gazeAngleDegrees(lookAt: SIMD3<Float>, cameraInFace: SIMD3<Float>) -> Double? {
        let a = simd_length(lookAt)
        let b = simd_length(cameraInFace)
        guard a > 1e-4, b > 1e-4 else { return nil }
        let c = simd_dot(lookAt, cameraInFace) / (a * b)
        return Double(acos(max(-1, min(1, c)))) * 180 / .pi
    }

    private static func eyesOpen(_ sample: FaceSample) -> Bool { max(sample.blinkL, sample.blinkR) < Self.openThreshold }

    private mutating func calibrateGaze(_ sample: FaceSample, at t: Double) -> [VerifierEvent] {
        if calibrationStart == nil { calibrationStart = t }
        guard Self.eyesOpen(sample), let theta = Self.gazeAngleDegrees(lookAt: sample.lookAt, cameraInFace: sample.cameraInFace) else {
            return []
        }
        thetaSum += theta
        pitchSum += sample.pitch
        calibrationCount += 1
        guard t - (calibrationStart ?? t) >= Self.gazeCalibrationSeconds,
              calibrationCount >= Self.minGazeCalibrationSamples else { return [] }
        theta0 = thetaSum / Double(calibrationCount)
        neutralPitch = pitchSum / Double(calibrationCount)
        phase = .gaze
        previousT = nil
        lapseSince = nil
        progress.gate = .ready
        progress.hint = farHint
        return [.gate(.ready), .cue(Self.cueLookFar)]
    }

    private mutating func accumulateGaze(_ sample: FaceSample, at t: Double) -> [VerifierEvent] {
        defer { previousT = t }
        guard let prev = previousT, t > prev else { return [] }
        let dt = t - prev
        guard dt <= Self.maxSampleGapSeconds else { return [] }

        let theta = Self.gazeAngleDegrees(lookAt: sample.lookAt, cameraInFace: sample.cameraInFace) ?? 0
        let headUp = wrappedDegrees(sample.pitch - neutralPitch) > Self.minRelativePitchDegrees
        let far = theta >= theta0 + Self.farGazeDeltaDegrees && Self.eyesOpen(sample) && headUp

        var counts = far
        if far {
            lapseSince = nil
        } else {
            if lapseSince == nil { lapseSince = t }
            counts = t - (lapseSince ?? t) <= Self.graceSeconds
        }
        guard counts else {
            progress.hint = farHint
            return []
        }
        farGazeSeconds += dt
        var events: [VerifierEvent] = []
        let second = Int(farGazeSeconds)
        if second != lastReportedSecond {
            lastReportedSecond = second
            progress.hint = farHint
            events.append(.progress(overallFraction))
        }
        if farGazeSeconds >= farGazeGoal {
            phase = .done
            progress.hint = Self.hintDone
            events.append(.progress(1))
            events.append(.completed)
        }
        return events
    }

    private var farHint: String {
        let remaining = max(0, Int((farGazeGoal - farGazeSeconds).rounded(.up)))
        return "\(Self.hintFar) · \(remaining) s"
    }

    /// Mitad parpadeos, mitad descanso visual.
    private var overallFraction: Double {
        let blinks = spec.target > 0 ? min(1, Double(completeBlinks) / Double(spec.target)) : 1
        let gaze = min(1, farGazeSeconds / max(farGazeGoal, 1e-3))
        return (blinks + gaze) / 2
    }

    private mutating func record(_ anomaly: Anomaly) -> VerifierEvent {
        anomalies.append(anomaly)
        return .anomaly(anomaly)
    }
}
