import Foundation

// Dueño: agente "face". Máquina de estados pura para A5 "Cuello: sí, no, quizás".
// Sin imports de ARKit: se alimenta de `FaceSample` (fuente en vivo o replay de fixtures).
// Convención de signos (la fija `FaceSource` y se verifica en dispositivo):
//   yaw  > 0 = gira hacia SU izquierda · pitch > 0 = mira arriba · roll > 0 = oreja derecha al hombro derecho.

// MARK: - Utilidades compartidas con EyeRestVerifier

/// Generador determinista (SplitMix64): la secuencia de consignas es reproducible por semilla.
nonisolated struct FaceChallengeRNG: RandomNumberGenerator, Sendable {
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

/// Vigila que haya una cara viva frente al teléfono.
/// - `isTracked == false` durante más de `lostSeconds` → gate bloqueado.
/// - `shapeEnergy` ≈ 0 durante `staticSeconds` con la cara detectada → anomalía `static` (hard): foto o pantalla congelada.
nonisolated struct FaceLivenessMonitor: Sendable {
    static let lostSeconds: Double = 2
    static let staticSeconds: Double = 2
    /// Suma de |Δ| de 8 blendShapes por debajo de esto = imagen sin vida (se calibra en dispositivo).
    static let staticEnergyThreshold: Float = 0.002

    nonisolated enum Change: Sendable, Equatable { case blocked, recovered, staticDetected }

    private(set) var isBlocked = false
    private var lastTrackedAt: Double = 0
    private var staticSince: Double?
    private var staticReported = false
    private var sawTrackedSample = false

    mutating func start(at t: Double) {
        isBlocked = false
        lastTrackedAt = t
        staticSince = nil
        staticReported = false
        sawTrackedSample = false
    }

    /// Devuelve los cambios de estado; el verificador los traduce a eventos.
    mutating func observe(_ sample: FaceSample, at t: Double) -> [Change] {
        var changes: [Change] = []
        if sample.isTracked {
            if isBlocked {
                isBlocked = false
                changes.append(.recovered)
            }
            lastTrackedAt = t
            // La primera muestra trae energía 0 por construcción (no hay muestra anterior): se ignora.
            if sawTrackedSample {
                if sample.shapeEnergy < Self.staticEnergyThreshold {
                    if let since = staticSince {
                        if !staticReported, t - since >= Self.staticSeconds {
                            staticReported = true
                            changes.append(.staticDetected)
                        }
                    } else {
                        staticSince = t
                    }
                } else {
                    staticSince = nil
                    staticReported = false
                }
            }
            sawTrackedSample = true
        } else {
            staticSince = nil
            if !isBlocked, t - lastTrackedAt > Self.lostSeconds {
                isBlocked = true
                changes.append(.blocked)
            }
        }
        return changes
    }
}

/// Diferencia angular normalizada a −180…180.
nonisolated func wrappedDegrees(_ degrees: Double) -> Double {
    var d = degrees.truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}

// MARK: - Verificador de cuello

/// A5. Calibra el neutro 0,5 s y después **el ejercicio es el challenge**: consignas en orden aleatorio
/// (semilla por sesión) con retardo aleatorio tras volver al centro; una rep solo cuenta si el pico
/// coincide con la consigna vigente.
nonisolated struct NeckVerifier: ActivityVerifier {
    typealias Sample = FaceSample

    nonisolated enum Axis: String, Sendable, Codable { case rotation, flexion, tilt }

    nonisolated enum Direction: String, CaseIterable, Sendable, Codable {
        case left, right, up, down, tiltLeft, tiltRight

        var axis: Axis {
            switch self {
            case .left, .right: .rotation
            case .up, .down: .flexion
            case .tiltLeft, .tiltRight: .tilt
            }
        }

        var threshold: Double {
            switch axis {
            case .rotation: NeckVerifier.yawThreshold
            case .flexion: NeckVerifier.pitchThreshold
            case .tilt: NeckVerifier.rollThreshold
            }
        }

        var cue: Cue {
            switch self {
            case .left: Cue(text: "Gire a la izquierda", symbol: "arrow.left")
            case .right: Cue(text: "Gire a la derecha", symbol: "arrow.right")
            case .up: Cue(text: "Mire hacia arriba", symbol: "arrow.up")
            case .down: Cue(text: "Mire hacia abajo", symbol: "arrow.down")
            case .tiltLeft: Cue(text: "Oreja al hombro izquierdo", symbol: "arrow.down.left")
            case .tiltRight: Cue(text: "Oreja al hombro derecho", symbol: "arrow.down.right")
            }
        }

        var shortName: String {
            switch self {
            case .left: "izquierda"
            case .right: "derecha"
            case .up: "arriba"
            case .down: "abajo"
            case .tiltLeft: "oreja izquierda"
            case .tiltRight: "oreja derecha"
            }
        }

        /// Ángulo "a favor" de la dirección (positivo cuando la cabeza va hacia ella), en grados relativos al neutro.
        func value(yaw: Double, pitch: Double, roll: Double) -> Double {
            switch self {
            case .left: yaw
            case .right: -yaw
            case .up: pitch
            case .down: -pitch
            case .tiltRight: roll
            case .tiltLeft: -roll
            }
        }

        /// Inversa de `value`: la pose (relativa al neutro) que corresponde a `magnitude` grados en esta dirección.
        func pose(_ magnitude: Double) -> (yaw: Double, pitch: Double, roll: Double) {
            switch self {
            case .left: (magnitude, 0, 0)
            case .right: (-magnitude, 0, 0)
            case .up: (0, magnitude, 0)
            case .down: (0, -magnitude, 0)
            case .tiltRight: (0, 0, magnitude)
            case .tiltLeft: (0, 0, -magnitude)
            }
        }
    }

    // MARK: Constantes (valores iniciales; se calibran en el iPhone)

    static let calibrationSeconds: Double = 0.5
    static let minCalibrationSamples = 5
    /// Rotación, flexión/extensión e inclinación mínimas para una rep (≈ 70 % de los rangos normativos).
    static let yawThreshold: Double = 45
    static let pitchThreshold: Double = 25
    static let rollThreshold: Double = 20
    /// Banda de "centro": hay que volver aquí entre reps y antes de cada consigna.
    static let neutralYawBand: Double = 15
    static let neutralPitchBand: Double = 10
    static let neutralRollBand: Double = 8
    /// Retardo aleatorio entre volver al centro y la siguiente consigna.
    static let cueDelayRange: ClosedRange<Double> = 0.8...2.5
    /// Si no hay movimiento, se repite la consigna vigente cada tanto.
    static let cueReminderSeconds: Double = 5
    /// Por encima de esto el salto no es humano (corte de vídeo, pérdida de seguimiento): se descarta el pico.
    static let maxAngularVelocityDegPerSec: Double = 240
    /// Al tercer movimiento que no coincide con la consigna, la anomalía pasa a `hard`.
    static let mismatchHardCount = 3

    static let anomalyCueMismatch = "cueMismatch"
    static let anomalyTrackingJump = "trackingJump"
    static let anomalyStatic = "static"
    static let blockedReason = "Mire al teléfono"
    static let hintCalibrating = "Quieto, mirando al teléfono"
    static let hintWait = "Espere la señal"
    static let hintReturn = "Vuelva al centro"
    static let hintDone = "Cuello listo"

    // MARK: Estado

    let kind: ActivityKind = .cuello
    let spec: VerificationSpec
    let seed: UInt64
    private(set) var progress: VerifierProgress
    /// Secuencia de consignas (una por rep esperada).
    private(set) var plan: [Direction]
    /// Consigna vigente (nil mientras se espera el retardo o tras una rep).
    private(set) var currentCue: Direction?
    private(set) var anomalies: [Anomaly] = []
    private(set) var isCompleted = false

    private var rng: FaceChallengeRNG
    private var liveness = FaceLivenessMonitor()
    private var t0: Double = 0
    private var calibrated = false
    private var calibrationSum = (yaw: 0.0, pitch: 0.0, roll: 0.0)
    private var calibrationCount = 0
    private var neutral = (yaw: 0.0, pitch: 0.0, roll: 0.0)
    private var previous: (t: Double, yaw: Double, pitch: Double, roll: Double)?
    private var planIndex = 0
    private var cueDueAt: Double?
    private var cueIssuedAt: Double = 0
    private var inExcursion = false
    private var excursionDiscarded = false
    private var excursionResolved = false
    private var jumpReported = false
    private var count = 0
    private var rotations = 0
    private var flexions = 0
    private var tilts = 0
    private var cueMatches = 0
    private var cueMismatches = 0
    private var maxYaw: Double = 0
    private var maxPitch: Double = 0
    private var maxRoll: Double = 0

    init(spec: VerificationSpec, seed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)) {
        self.spec = spec
        self.seed = seed
        var generator = FaceChallengeRNG(seed: seed)
        plan = Self.makePlan(target: spec.target, using: &generator)
        rng = generator
        progress = VerifierProgress(target: spec.target, gate: .calibrating, hint: Self.hintCalibrating)
    }

    /// Reparte la meta entre rotación, flexión e inclinación, alterna lados y baraja con la semilla.
    static func makePlan(target: Int, using rng: inout FaceChallengeRNG) -> [Direction] {
        guard target > 0 else { return [] }
        let base = target / 3
        let extra = target % 3
        let counts = [base + (extra > 0 ? 1 : 0), base + (extra > 1 ? 1 : 0), base]
        let pairs: [(Direction, Direction)] = [(.left, .right), (.up, .down), (.tiltLeft, .tiltRight)]
        var plan: [Direction] = []
        for (i, pair) in pairs.enumerated() {
            var first = Bool.random(using: &rng)
            for _ in 0..<counts[i] {
                plan.append(first ? pair.0 : pair.1)
                first.toggle()
            }
        }
        plan.shuffle(using: &rng)
        // Evita dos consignas idénticas seguidas cuando se puede.
        if plan.count > 1 {
            for i in 1..<plan.count where plan[i] == plan[i - 1] {
                if let j = ((i + 1)..<plan.count).first(where: { plan[$0] != plan[i] }) {
                    plan.swapAt(i, j)
                }
            }
        }
        return plan
    }

    // MARK: ActivityVerifier

    mutating func start(at t: Double) {
        t0 = t
        liveness.start(at: t)
        progress = VerifierProgress(target: spec.target, gate: .calibrating, hint: Self.hintCalibrating)
    }

    mutating func ingest(_ sample: FaceSample, at t: Double) -> [VerifierEvent] {
        var events: [VerifierEvent] = []
        progress.elapsed = t - t0

        for change in liveness.observe(sample, at: t) {
            switch change {
            case .blocked:
                progress.gate = .blocked(reason: Self.blockedReason)
                events.append(.gate(progress.gate))
                // Se pierde la consigna: al volver, hay que pasar por el centro y esperar otra.
                currentCue = nil
                cueDueAt = nil
                previous = nil
            case .recovered:
                if calibrated {
                    progress.gate = .ready
                    progress.hint = Self.hintWait
                    events.append(.gate(.ready))
                }
            case .staticDetected:
                events.append(record(Anomaly(kind: Self.anomalyStatic, severity: .hard, at: t - t0,
                                             detail: "Sin movimiento facial \(Int(FaceLivenessMonitor.staticSeconds)) s")))
            }
        }

        guard sample.isTracked else {
            previous = nil
            return events
        }
        guard !isCompleted else { return events }

        if !calibrated {
            calibrationSum.yaw += sample.yaw
            calibrationSum.pitch += sample.pitch
            calibrationSum.roll += sample.roll
            calibrationCount += 1
            if t - t0 >= Self.calibrationSeconds, calibrationCount >= Self.minCalibrationSamples {
                let n = Double(calibrationCount)
                neutral = (calibrationSum.yaw / n, calibrationSum.pitch / n, calibrationSum.roll / n)
                calibrated = true
                progress.gate = .ready
                progress.hint = Self.hintWait
                events.append(.gate(.ready))
                scheduleCue(after: t)
            }
            return events
        }

        let relYaw = wrappedDegrees(sample.yaw - neutral.yaw)
        let relPitch = wrappedDegrees(sample.pitch - neutral.pitch)
        let relRoll = wrappedDegrees(sample.roll - neutral.roll)

        if let previous, t > previous.t {
            let dt = t - previous.t
            let step = max(abs(wrappedDegrees(sample.yaw - previous.yaw)),
                           abs(wrappedDegrees(sample.pitch - previous.pitch)),
                           abs(wrappedDegrees(sample.roll - previous.roll)))
            if step / dt > Self.maxAngularVelocityDegPerSec {
                excursionDiscarded = true
                if !jumpReported {
                    jumpReported = true
                    events.append(record(Anomaly(kind: Self.anomalyTrackingJump, severity: .soft, at: t - t0,
                                                 detail: "\(Int(step / dt))°/s")))
                }
            }
        }
        previous = (t, sample.yaw, sample.pitch, sample.roll)

        let inNeutral = abs(relYaw) <= Self.neutralYawBand
            && abs(relPitch) <= Self.neutralPitchBand
            && abs(relRoll) <= Self.neutralRollBand

        if inNeutral {
            if inExcursion {
                inExcursion = false
                if currentCue == nil { scheduleCue(after: t) }
            }
            excursionDiscarded = false
            excursionResolved = false
            jumpReported = false
            if let cue = currentCue {
                if t - cueIssuedAt >= Self.cueReminderSeconds {
                    cueIssuedAt = t
                    events.append(.cue(cue.cue))
                }
            } else if let due = cueDueAt, t >= due, planIndex < plan.count {
                let cue = plan[planIndex]
                currentCue = cue
                cueDueAt = nil
                cueIssuedAt = t
                progress.hint = cue.cue.text
                events.append(.cue(cue.cue))
            }
            return events
        }

        if !inExcursion {
            inExcursion = true
            cueDueAt = nil // la consigna pendiente se pospone hasta volver al centro
        }
        guard !excursionDiscarded, !excursionResolved else { return events }

        maxYaw = max(maxYaw, abs(relYaw))
        maxPitch = max(maxPitch, abs(relPitch))
        maxRoll = max(maxRoll, abs(relRoll))

        let reached = Direction.allCases
            .map { ($0, $0.value(yaw: relYaw, pitch: relPitch, roll: relRoll) / $0.threshold) }
            .filter { $0.1 >= 1 }
            .max { $0.1 < $1.1 }?.0
        guard let reached else { return events }
        excursionResolved = true
        guard let cue = currentCue else { return events } // movimiento sin consigna: no cuenta

        if reached == cue {
            count += 1
            cueMatches += 1
            planIndex += 1
            switch cue.axis {
            case .rotation: rotations += 1
            case .flexion: flexions += 1
            case .tilt: tilts += 1
            }
            currentCue = nil
            progress.count = count
            progress.hint = Self.hintReturn
            events.append(.rep(count))
            events.append(.progress(progress.fraction))
            if count >= spec.target {
                isCompleted = true
                progress.hint = Self.hintDone
                events.append(.completed)
            }
        } else {
            cueMismatches += 1
            let severity: Anomaly.Severity = cueMismatches >= Self.mismatchHardCount ? .hard : .soft
            events.append(record(Anomaly(kind: Self.anomalyCueMismatch, severity: severity, at: t - t0,
                                         detail: "esperaba \(cue.shortName), hizo \(reached.shortName)")))
            currentCue = nil // se vuelve a pedir la misma consigna tras volver al centro
            progress.hint = Self.hintReturn
        }
        return events
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        progress.elapsed = t - t0
        return ActivityOutcome(
            kind: kind,
            target: spec.target,
            achieved: count,
            completed: isCompleted,
            durationSeconds: max(0, t - t0),
            metrics: .neck(rotations: rotations, flexions: flexions, tilts: tilts,
                           maxYaw: maxYaw, maxPitch: maxPitch, maxRoll: maxRoll,
                           cueMatches: cueMatches, cueMismatches: cueMismatches),
            anomalies: anomalies,
            reason: reason
        )
    }

    // MARK: Privado

    private mutating func scheduleCue(after t: Double) {
        guard !isCompleted, planIndex < plan.count else { return }
        cueDueAt = t + Double.random(in: Self.cueDelayRange, using: &rng)
    }

    private mutating func record(_ anomaly: Anomaly) -> VerifierEvent {
        anomalies.append(anomaly)
        return .anomaly(anomaly)
    }
}
