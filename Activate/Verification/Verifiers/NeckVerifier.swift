import Foundation
import simd

// Dueño: agente "face". Máquina de estados pura para A5 "Cuello: sí, no, quizás".
// Sin imports de ARKit: se alimenta de `FaceSample` (fuente en vivo o replay de fixtures).
// Convención de signos (la fija `HeadPose` / `FaceSampleMath` y la corrige el verificador si el
// dispositivo la invierte en algún eje):
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

// MARK: - Pose de la cabeza (matemática pura)

/// Ángulos de Tait-Bryan de la cabeza y su matriz. Fuente única de la convención:
/// `R = Ry(yaw) · Rx(−pitch) · Rz(roll)` en el sistema de la cara de ARKit
/// (+X = izquierda de la propia cara, +Y = arriba, +Z = sale de la cara por la nariz hacia la cámara).
/// - yaw > 0: la nariz (+Z) gira hacia +X → la persona gira hacia SU izquierda.
/// - pitch > 0: la nariz sube → mira arriba.
/// - roll > 0: el eje +X (lado izquierdo de la cara) sube → oreja derecha al hombro derecho.
nonisolated enum HeadPose {
    static let degreesPerRadian = 180 / Double.pi

    /// Matriz de rotación de unos ángulos en grados.
    static func matrix(yaw: Double, pitch: Double, roll: Double) -> simd_double3x3 {
        let y = yaw / degreesPerRadian, p = -pitch / degreesPerRadian, r = roll / degreesPerRadian
        let ry = simd_double3x3(columns: (SIMD3(cos(y), 0, -sin(y)), SIMD3(0, 1, 0), SIMD3(sin(y), 0, cos(y))))
        let rx = simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cos(p), sin(p)), SIMD3(0, -sin(p), cos(p))))
        let rz = simd_double3x3(columns: (SIMD3(cos(r), sin(r), 0), SIMD3(-sin(r), cos(r), 0), SIMD3(0, 0, 1)))
        return ry * rx * rz
    }

    /// Inversa de `matrix`: con `z` = columna 2 (nariz) → yaw = atan2(z.x, z.z), pitch = asin(z.y);
    /// roll = atan2(x.y, y.y). Exacta mientras |pitch| < 90°.
    static func angles(from m: simd_double3x3) -> (yaw: Double, pitch: Double, roll: Double) {
        let x = m.columns.0, y = m.columns.1, z = m.columns.2
        let yaw = atan2(z.x, z.z)
        let pitch = asin(max(-1, min(1, z.y)))
        let roll = atan2(x.y, y.y)
        return (yaw * degreesPerRadian, pitch * degreesPerRadian, roll * degreesPerRadian)
    }

    /// Rotación de `current` expresada en el sistema de la cabeza en `neutral` (movimiento anatómico):
    /// si el operador mira el teléfono con la cabeza gacha, girar "no" sigue siendo yaw puro.
    static func relative(current: (yaw: Double, pitch: Double, roll: Double),
                         to neutral: (yaw: Double, pitch: Double, roll: Double)) -> (yaw: Double, pitch: Double, roll: Double) {
        let c = matrix(yaw: current.yaw, pitch: current.pitch, roll: current.roll)
        let n = matrix(yaw: neutral.yaw, pitch: neutral.pitch, roll: neutral.roll)
        return angles(from: n.transpose * c)
    }
}

// MARK: - Verificador de cuello

/// A5. **El ejercicio es el challenge**: consignas en orden aleatorio (semilla por sesión); una rep solo
/// cuenta si el movimiento coincide con la consigna vigente. Pensado para un operador de 52 años con el
/// teléfono en la mano:
/// - Calibra el neutro solo con la cabeza quieta (velocidad < 20°/s sostenida 0,8 s); si se mueve, la cuenta se reinicia.
/// - Primera consigna apenas calibra; las siguientes, apenas vuelve al centro (pausa ≤ 0,4 s).
/// - Umbrales moderados (giro 28°, arriba/abajo 18°, inclinación 14°) medidos respecto de la cabeza neutra.
/// - "Centro" se evalúa solo en el eje de la consigna recién cumplida (< 40 % de su umbral).
/// - El neutro se re-centra lento (EMA) mientras la cabeza está quieta y cerca del centro: absorbe la deriva.
/// - Si el dispositivo invierte el signo de un eje, se corrige solo tras 2 intentos seguidos al lado opuesto.
nonisolated struct NeckVerifier: ActivityVerifier {
    typealias Sample = FaceSample

    nonisolated enum Axis: String, Sendable, Codable, CaseIterable {
        case rotation, flexion, tilt

        /// Etiqueta corta para el texto de depuración.
        var label: String {
            switch self {
            case .rotation: "giro"
            case .flexion: "arriba"
            case .tilt: "incl"
            }
        }

        /// Dirección positiva y negativa del eje.
        var directions: (positive: Direction, negative: Direction) {
            switch self {
            case .rotation: (.left, .right)
            case .flexion: (.up, .down)
            case .tilt: (.tiltRight, .tiltLeft)
            }
        }

        /// Umbral más chico del eje (centro y re-centrado).
        var minThreshold: Double { min(directions.positive.threshold, directions.negative.threshold) }

        /// Dirección del eje que alcanzó su umbral, si alguna.
        func reached(_ a: Angles) -> Direction? {
            let (p, n) = directions
            if p.value(a) >= p.threshold { return p }
            if n.value(a) >= n.threshold { return n }
            return nil
        }
    }

    /// Ángulos por eje (grados). `yaw` ↔ rotación, `pitch` ↔ flexión, `roll` ↔ inclinación.
    nonisolated struct Angles: Sendable, Equatable {
        var yaw: Double = 0
        var pitch: Double = 0
        var roll: Double = 0

        subscript(axis: Axis) -> Double {
            get {
                switch axis {
                case .rotation: yaw
                case .flexion: pitch
                case .tilt: roll
                }
            }
            set {
                switch axis {
                case .rotation: yaw = newValue
                case .flexion: pitch = newValue
                case .tilt: roll = newValue
                }
            }
        }

        init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
            self.yaw = yaw
            self.pitch = pitch
            self.roll = roll
        }

        init(_ t: (yaw: Double, pitch: Double, roll: Double)) {
            self.init(yaw: t.yaw, pitch: t.pitch, roll: t.roll)
        }

        var tuple: (yaw: Double, pitch: Double, roll: Double) { (yaw, pitch, roll) }
        var maxMagnitude: Double { max(abs(yaw), abs(pitch), abs(roll)) }
    }

    nonisolated enum Direction: String, CaseIterable, Sendable, Codable {
        case left, right, up, down, tiltLeft, tiltRight

        var axis: Axis {
            switch self {
            case .left, .right: .rotation
            case .up, .down: .flexion
            case .tiltLeft, .tiltRight: .tilt
            }
        }

        /// +1 si la dirección aumenta el ángulo del eje (izquierda, arriba, oreja derecha); −1 si lo disminuye.
        var sign: Double {
            switch self {
            case .left, .up, .tiltRight: 1
            case .right, .down, .tiltLeft: -1
            }
        }

        var opposite: Direction {
            switch self {
            case .left: .right
            case .right: .left
            case .up: .down
            case .down: .up
            case .tiltLeft: .tiltRight
            case .tiltRight: .tiltLeft
            }
        }

        var threshold: Double {
            switch self {
            case .left, .right: NeckVerifier.turnThreshold
            case .up: NeckVerifier.upThreshold
            case .down: NeckVerifier.downThreshold
            case .tiltLeft, .tiltRight: NeckVerifier.tiltThreshold
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
            value(Angles(yaw: yaw, pitch: pitch, roll: roll))
        }

        func value(_ a: Angles) -> Double { sign * a[axis] }

        /// Inversa de `value`: la pose (relativa al neutro) que corresponde a `magnitude` grados en esta dirección.
        func pose(_ magnitude: Double) -> (yaw: Double, pitch: Double, roll: Double) {
            var a = Angles()
            a[axis] = sign * magnitude
            return a.tuple
        }
    }

    nonisolated enum Phase: Sendable, Equatable {
        /// Esperando 0,8 s de cabeza quieta para fijar el neutro.
        case calibrating
        /// Consigna vigente: se espera el movimiento.
        case cue(Direction)
        /// Movimiento hecho (o hacia el lado opuesto): se espera la vuelta al centro en ese eje.
        case returning(Direction)
        /// Pausa corta antes de la siguiente consigna.
        case pausing(until: Double)
        case done
    }

    // MARK: Constantes (se ajustan en el iPhone; el texto de depuración del modo demo ayuda)

    /// Cabeza quieta: velocidad angular máxima y tiempo sostenido para calibrar.
    static let calibrationMaxVelocity: Double = 20
    static let calibrationStableSeconds: Double = 0.8
    static let minCalibrationSamples = 8
    /// Si en este tiempo no logra quedarse quieto (vibración, pulso), se acepta una velocidad algo mayor.
    static let calibrationRelaxAfterSeconds: Double = 6
    static let calibrationRelaxedMaxVelocity: Double = 35
    /// Suavizado exponencial de los ángulos (constante de tiempo) y ventana para estimar la velocidad.
    static let smoothingSeconds: Double = 0.06
    static let velocityWindowSeconds: Double = 0.25
    static let minVelocitySpanSeconds: Double = 0.12
    /// Umbrales por dirección (grados respecto de la cabeza neutra).
    static let turnThreshold: Double = 28
    static let upThreshold: Double = 18
    static let downThreshold: Double = 18
    static let tiltThreshold: Double = 14
    /// "Centro" = el eje de la consigna recién cumplida bajo este % de su umbral.
    static let returnFraction: Double = 0.4
    /// Si se queda quieto un rato sin llegar del todo al centro (bajo este %), se acepta y se re-centra ese eje.
    static let returnSettleFraction: Double = 0.7
    static let returnSettleSeconds: Double = 1.2
    /// Tras una consigna, el eje debe pasar bajo este % antes de que un pico cuente (no vale llegar ya girado).
    static let armFraction: Double = 0.6
    /// Desajuste: otro eje llega a su umbral mientras el eje pedido está bajo este %.
    static let mismatchCueAxisFraction: Double = 0.3
    /// Pausa entre volver al centro y la siguiente consigna.
    static let cuePauseRange: ClosedRange<Double> = 0.15...0.4
    /// Si no hay movimiento, se repite la consigna vigente cada tanto.
    static let cueReminderSeconds: Double = 6
    /// Re-centrado lento del neutro (constante de tiempo de la EMA) mientras la cabeza está quieta y en el centro.
    static let recenterSeconds: Double = 3
    /// Salto no humano entre muestras (corte de vídeo, pérdida de seguimiento): se descarta el intento.
    static let maxAngularVelocityDegPerSec: Double = 240
    static let minJumpDegrees: Double = 8
    /// Desajustes para que la anomalía pase a `hard` (solo si no hubo ningún acierto).
    static let mismatchHardCount = 5
    /// Intentos seguidos al lado opuesto del mismo eje para invertir su signo.
    static let oppositeHitsToFlip = 2

    static let anomalyCueMismatch = "cueMismatch"
    static let anomalyTrackingJump = "trackingJump"
    static let anomalyStatic = "static"
    static let anomalyAxisFlipped = "axisFlipped"
    static let blockedReason = "Mire al teléfono"
    static let hintCalibrating = "Quieto, mirando al teléfono"
    static let hintReturn = "Vuelva al centro"
    static let hintDone = "Cuello listo"
    /// Consigna de vuelta al centro (la UI la muestra en gris, con la barra vaciándose).
    static let cueReturn = Cue(text: hintReturn, symbol: "scope")

    // MARK: Estado

    let kind: ActivityKind = .cuello
    let spec: VerificationSpec
    let seed: UInt64
    private(set) var progress: VerifierProgress
    /// Secuencia de consignas (una por rep esperada).
    private(set) var plan: [Direction]
    private(set) var phase: Phase = .calibrating
    private(set) var anomalies: [Anomaly] = []
    /// Signo aplicado a cada eje (−1 si se autocorrigió por estar invertido en el dispositivo).
    private(set) var axisSigns = Angles(yaw: 1, pitch: 1, roll: 1)
    /// Ángulos absolutos (suavizados) de la cabeza neutra.
    private(set) var neutral = Angles()

    /// Consigna vigente (nil mientras calibra, vuelve al centro o en la pausa).
    var currentCue: Direction? {
        if case .cue(let d) = phase { return d }
        return nil
    }
    var isCalibrated: Bool { phase != .calibrating }
    var isCompleted: Bool { phase == .done }

    private var rng: FaceChallengeRNG
    private var liveness = FaceLivenessMonitor()
    private var t0: Double = 0
    // Señal.
    private var previousRaw: (t: Double, angles: Angles)?
    private var smooth: Angles?
    private var lastSmoothT: Double?
    private var history: [(t: Double, angles: Angles)] = []
    // Calibración.
    private var stableSince: Double?
    private var calibrationAnchor = Angles()
    private var calibrationSum = Angles()
    private var calibrationCount = 0
    // Consignas.
    private var planIndex = 0
    private var cueIssuedAt: Double = 0
    private var armed = false
    private var jumpReported = false
    private var settleSince: Double?
    private var oppositeHits: [Axis: Int] = [:]
    private var mismatchActive: Set<Axis> = []
    // Métricas.
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
                progress.live = nil
                events.append(.gate(progress.gate))
                armed = false
            case .recovered:
                progress.gate = isCalibrated ? .ready : .calibrating
                events.append(.gate(progress.gate))
                if case .cue(let d) = phase {
                    cueIssuedAt = t
                    events.append(.cue(d.cue))
                }
            case .staticDetected:
                events.append(record(Anomaly(kind: Self.anomalyStatic, severity: .hard, at: t - t0,
                                             detail: "Sin movimiento facial \(Int(FaceLivenessMonitor.staticSeconds)) s")))
            }
        }

        guard sample.isTracked else {
            resetSignal()
            if !isCalibrated { stableSince = nil }
            return events
        }
        guard !isCompleted else { return events }

        let raw = Angles(yaw: sample.yaw, pitch: sample.pitch, roll: sample.roll)
        let jumped = detectJump(raw, at: t)
        let dt = updateSmoothing(raw, at: t, reset: jumped)
        let velocity = axisVelocity()

        guard isCalibrated else {
            events += calibrate(raw, velocity: velocity, jumped: jumped, at: t)
            return events
        }

        let headRel = headRelativeAngles()
        let rel = Angles(yaw: axisSigns.yaw * headRel.yaw, pitch: axisSigns.pitch * headRel.pitch,
                         roll: axisSigns.roll * headRel.roll)
        maxYaw = max(maxYaw, abs(rel.yaw))
        maxPitch = max(maxPitch, abs(rel.pitch))
        maxRoll = max(maxRoll, abs(rel.roll))
        recenter(headRel: headRel, velocity: velocity, dt: dt)

        switch phase {
        case .cue(let d):
            events += evaluateCue(d, rel: rel, jumped: jumped, at: t)
        case .returning(let d):
            events += evaluateReturn(d, rel: rel, headRel: headRel, velocity: velocity, at: t)
        case .pausing(let until):
            progress.live = 0
            if t >= until { events += issueCue(at: t) }
        case .calibrating, .done:
            break
        }

        // Un desajuste se reporta una vez por salida del eje: vuelve a armarse al volver al centro.
        for axis in mismatchActive where abs(rel[axis]) < Self.returnFraction * axis.minThreshold {
            mismatchActive.remove(axis)
        }
        progress.debug = debugText(rel)
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

    // MARK: Señal

    private mutating func resetSignal() {
        previousRaw = nil
        smooth = nil
        lastSmoothT = nil
        history.removeAll(keepingCapacity: true)
        settleSince = nil
    }

    /// Salto no humano respecto de la muestra cruda anterior.
    private mutating func detectJump(_ raw: Angles, at t: Double) -> Bool {
        defer { previousRaw = (t, raw) }
        guard let prev = previousRaw, t > prev.t else { return false }
        let step = Axis.allCases.map { abs(wrappedDegrees(raw[$0] - prev.angles[$0])) }.max() ?? 0
        return step >= Self.minJumpDegrees && step / (t - prev.t) > Self.maxAngularVelocityDegPerSec
    }

    /// EMA de los ángulos absolutos; devuelve el Δt usado (0 si se reinició).
    private mutating func updateSmoothing(_ raw: Angles, at t: Double, reset: Bool) -> Double {
        defer { lastSmoothT = t }
        guard !reset, var s = smooth, let last = lastSmoothT, t > last else {
            smooth = raw
            history = [(t, raw)]
            return 0
        }
        let dt = min(t - last, Self.velocityWindowSeconds)
        let alpha = 1 - exp(-dt / Self.smoothingSeconds)
        for axis in Axis.allCases {
            s[axis] = wrappedDegrees(s[axis] + alpha * wrappedDegrees(raw[axis] - s[axis]))
        }
        smooth = s
        history.append((t, s))
        while history.count > 2, history[1].t <= t - Self.velocityWindowSeconds {
            history.removeFirst()
        }
        return dt
    }

    /// Velocidad angular por eje (°/s) sobre la ventana; nil mientras no hay suficiente historia.
    private func axisVelocity() -> Angles? {
        guard let first = history.first, let last = history.last else { return nil }
        let span = last.t - first.t
        guard span >= Self.minVelocitySpanSeconds else { return nil }
        var v = Angles()
        for axis in Axis.allCases {
            v[axis] = abs(wrappedDegrees(last.angles[axis] - first.angles[axis])) / span
        }
        return v
    }

    /// Ángulos (suavizados) relativos al neutro en el sistema de la cabeza, sin corrección de signo.
    private func headRelativeAngles() -> Angles {
        guard let smooth else { return Angles() }
        return Angles(HeadPose.relative(current: smooth.tuple, to: neutral.tuple))
    }

    /// Mueve el neutro con una rotación chica expresada en el sistema de la cabeza (no en ejes del mundo:
    /// con la cabeza gacha, un giro en el mundo también cambia pitch y roll, y eso no es deriva).
    private mutating func shiftNeutral(by delta: Angles) {
        let m = HeadPose.matrix(yaw: neutral.yaw, pitch: neutral.pitch, roll: neutral.roll)
            * HeadPose.matrix(yaw: delta.yaw, pitch: delta.pitch, roll: delta.roll)
        neutral = Angles(HeadPose.angles(from: m))
    }

    // MARK: Calibración

    private mutating func calibrate(_ raw: Angles, velocity: Angles?, jumped: Bool, at t: Double) -> [VerifierEvent] {
        progress.live = nil
        guard !jumped, let velocity else {
            if jumped { stableSince = nil }
            progress.debug = "calibrando"
            return []
        }
        let speed = velocity.maxMagnitude
        progress.debug = "calibrando · \(Int(speed.rounded()))°/s"
        let limit = t - t0 >= Self.calibrationRelaxAfterSeconds ? Self.calibrationRelaxedMaxVelocity : Self.calibrationMaxVelocity
        guard speed < limit else {
            stableSince = nil
            progress.hint = Self.hintCalibrating
            return []
        }
        if stableSince == nil {
            stableSince = t
            calibrationAnchor = raw
            calibrationSum = Angles()
            calibrationCount = 0
        }
        for axis in Axis.allCases {
            calibrationSum[axis] += wrappedDegrees(raw[axis] - calibrationAnchor[axis])
        }
        calibrationCount += 1
        guard let since = stableSince, t - since >= Self.calibrationStableSeconds,
              calibrationCount >= Self.minCalibrationSamples else { return [] }

        let n = Double(calibrationCount)
        for axis in Axis.allCases {
            neutral[axis] = wrappedDegrees(calibrationAnchor[axis] + calibrationSum[axis] / n)
        }
        progress.gate = .ready
        var events: [VerifierEvent] = [.gate(.ready)]
        events += issueCue(at: t)
        return events
    }

    /// Re-centrado lento por eje: solo con ese eje quieto y cerca del centro (absorbe deriva de postura y del teléfono).
    private mutating func recenter(headRel: Angles, velocity: Angles?, dt: Double) {
        guard dt > 0, let velocity else { return }
        let alpha = 1 - exp(-dt / Self.recenterSeconds)
        var delta = Angles()
        for axis in Axis.allCases
        where abs(headRel[axis]) < Self.returnFraction * axis.minThreshold && velocity[axis] < Self.calibrationMaxVelocity {
            delta[axis] = alpha * headRel[axis]
        }
        if delta != Angles() { shiftNeutral(by: delta) }
    }

    // MARK: Consignas

    private mutating func issueCue(at t: Double) -> [VerifierEvent] {
        guard planIndex < plan.count else {
            // Meta 0: no hay nada que pedir.
            phase = .done
            progress.hint = Self.hintDone
            return [.completed]
        }
        let d = plan[planIndex]
        phase = .cue(d)
        armed = false
        jumpReported = false
        settleSince = nil
        cueIssuedAt = t
        progress.hint = d.cue.text
        progress.live = 0
        return [.cue(d.cue)]
    }

    private mutating func evaluateCue(_ d: Direction, rel: Angles, jumped: Bool, at t: Double) -> [VerifierEvent] {
        var events: [VerifierEvent] = []
        let value = d.value(rel)
        progress.live = min(1, max(0, value / d.threshold))

        if jumped {
            // El intento en curso no vale: hay que volver a bajar del umbral de armado.
            armed = false
            if !jumpReported {
                jumpReported = true
                events.append(record(Anomaly(kind: Self.anomalyTrackingJump, severity: .soft, at: t - t0,
                                             detail: "salto > \(Int(Self.maxAngularVelocityDegPerSec))°/s")))
            }
            return events
        }
        if !armed, value / d.threshold < Self.armFraction { armed = true }

        // Otro eje llega a su umbral mientras el pedido casi no se mueve: no cuenta ni bloquea.
        if abs(rel[d.axis]) / d.threshold < Self.mismatchCueAxisFraction {
            for axis in Axis.allCases where axis != d.axis && !mismatchActive.contains(axis) {
                guard let other = axis.reached(rel) else { continue }
                mismatchActive.insert(axis)
                cueMismatches += 1
                let severity: Anomaly.Severity = cueMismatches >= Self.mismatchHardCount && cueMatches == 0 ? .hard : .soft
                events.append(record(Anomaly(kind: Self.anomalyCueMismatch, severity: severity, at: t - t0,
                                             detail: "esperaba \(d.shortName), hizo \(other.shortName)")))
            }
        }
        guard armed else { return events }

        if value >= d.threshold {
            events += countRep(d, at: t)
        } else if d.opposite.value(rel) >= d.opposite.threshold {
            let hits = (oppositeHits[d.axis] ?? 0) + 1
            if hits >= Self.oppositeHitsToFlip {
                // Dos veces seguidas exactamente al revés en este eje: el signo del dispositivo está invertido.
                oppositeHits[d.axis] = 0
                axisSigns[d.axis] *= -1
                events.append(record(Anomaly(kind: Self.anomalyAxisFlipped, severity: .soft, at: t - t0,
                                             detail: "\(d.axis.label) invertido")))
                events += countRep(d, at: t)
            } else {
                oppositeHits[d.axis] = hits
                phase = .returning(d)
                settleSince = nil
                progress.hint = Self.hintReturn
                events.append(.cue(Self.cueReturn))
            }
        } else if t - cueIssuedAt >= Self.cueReminderSeconds {
            cueIssuedAt = t
            events.append(.cue(d.cue))
        }
        return events
    }

    private mutating func countRep(_ d: Direction, at t: Double) -> [VerifierEvent] {
        count += 1
        cueMatches += 1
        planIndex += 1
        oppositeHits[d.axis] = 0
        switch d.axis {
        case .rotation: rotations += 1
        case .flexion: flexions += 1
        case .tilt: tilts += 1
        }
        progress.count = count
        progress.live = 1
        var events: [VerifierEvent] = [.rep(count), .progress(progress.fraction)]
        if count >= spec.target {
            phase = .done
            progress.hint = Self.hintDone
            events.append(.completed)
        } else {
            phase = .returning(d)
            settleSince = nil
            progress.hint = Self.hintReturn
            events.append(.cue(Self.cueReturn))
        }
        return events
    }

    /// Vuelta al centro solo en el eje del movimiento recién hecho.
    private mutating func evaluateReturn(_ d: Direction, rel: Angles, headRel: Angles, velocity: Angles?,
                                         at t: Double) -> [VerifierEvent] {
        let fraction = abs(rel[d.axis]) / d.threshold
        progress.live = min(1, fraction)
        var returned = fraction < Self.returnFraction
        if !returned, fraction < Self.returnSettleFraction, let velocity, velocity[d.axis] < Self.calibrationMaxVelocity {
            // Quieto casi en el centro: su postura cambió. Se acepta y se re-centra ese eje.
            if let since = settleSince {
                if t - since >= Self.returnSettleSeconds {
                    var delta = Angles()
                    delta[d.axis] = headRel[d.axis]
                    shiftNeutral(by: delta)
                    returned = true
                }
            } else {
                settleSince = t
            }
        } else if !returned {
            settleSince = nil
        }
        guard returned else { return [] }
        settleSince = nil
        phase = .pausing(until: t + Double.random(in: Self.cuePauseRange, using: &rng))
        progress.live = 0
        return []
    }

    // MARK: Privado

    private func debugText(_ rel: Angles) -> String {
        func deg(_ v: Double) -> String { "\(Int(v.rounded()))°" }
        var text = "giro \(deg(rel.yaw)) · arriba \(deg(rel.pitch)) · incl \(deg(rel.roll))"
        let flipped = Axis.allCases.filter { axisSigns[$0] < 0 }.map(\.label)
        if !flipped.isEmpty { text += " · inv \(flipped.joined(separator: ","))" }
        return text
    }

    private mutating func record(_ anomaly: Anomaly) -> VerifierEvent {
        anomalies.append(anomaly)
        return .anomaly(anomaly)
    }
}
