import Foundation
import simd

// Dueño: agente "extension". A1 extensión lumbar de pie con el teléfono EN LAS MANOS.
//
// Marco sostiene el iPhone con las dos manos frente al pecho, pantalla hacia él, y se inclina hacia atrás
// con todo el tronco (extensión de columna, manos y teléfono fijos respecto del pecho) y vuelve derecho.
// Usa la misma fuente que la sentadilla (`HandheldBodySource`: ARKit cara por TrueDepth + pose 6DOF del
// teléfono con la cámara trasera + IMU, sin mostrar ninguna imagen). Esta máquina de estados es pura (sin
// ARKit/CoreMotion) y se prueba con muestras sintéticas a 60 Hz.
//
// Física de la rep: el tronco gira hacia atrás alrededor de la zona lumbar y arrastra al teléfono y a la
// cabeza como un cuerpo rígido. El borde superior del teléfono se va hacia atrás (hacia la persona), así que
// la pantalla queda mirando MÁS HACIA ABAJO: el cabeceo de la muestra ("pantalla hacia arriba > 0") BAJA.
// Señal de la rep: `inclinación = cabeceo de referencia − cabeceo` (grados, > 0 al ir hacia atrás).
//
// Por qué no se puede falsear con el teléfono en la mano:
// - Rep = el teléfono se inclina ≥ 12° hacia atrás sobre la referencia de pie y vuelve a < 4° (0,8-6 s).
// - Anti-muñecas: en una extensión real cara y teléfono giran JUNTOS. La cara en el espacio del teléfono
//   cambia < 6 cm (y su dirección < 10°) y la cara en el mundo se va ≥ 3 cm hacia atrás (dirección
//   teléfono → cara de la referencia). Girar el teléfono con las muñecas deja la cara quieta en el mundo y
//   la mueve en el encuadre → `wristsOnly` (soft; hard la 3ª vez).
// - No es una sentadilla: si el teléfono baja > 10 cm durante la rep → `notExtension` (soft).
// - Persona viva: micro-expresiones (`shapeEnergy`); una foto o máscara → `static` (hard). Cara perdida
//   > 1,5 s → gate "Mantenga la cara en la pantalla".
// - Desafío: en una rep al azar aparece "Quédese atrás 2 segundos"; fallarlo 2 veces → `holdChallengeFailed`.
// - Sacudidas, ritmo de metrónomo y caminar → anomalías, como en la sentadilla.
// - Sin seguimiento del mundo (cámara trasera tapada, equipo sin soporte): respaldo con el cabeceo
//   (deviceMotion) + la cara quieta en el encuadre. Si alguna rep se contó con el respaldo, el nivel baja a
//   `reduced` aunque la fuente declare `.live` (`SourceLevelLimiting`): tapar la cámara solo en las reps no
//   deja `full`.
// Seguridad: con dolor lumbar alto las reglas (`SafetyRules`) excluyen la extensión. La instrucción dice
// "hasta donde no duela" y el umbral es bajo a propósito: una extensión corta (13-15°) y lenta cuenta.

// MARK: - Umbrales (constantes nombradas; se calibran en el iPhone con la línea de depuración de la demo)

nonisolated enum HandheldExtensionTuning {
    private typealias Squat = HandheldSquatTuning

    // Calibración de pie
    /// Segundos de pie, quieto y con la cara visible para fijar la referencia.
    static let calibrationSeconds = Squat.calibrationSeconds
    /// Quieto = el cabeceo no varía más que esto (°) y el teléfono no se desplaza (mismos límites que la sentadilla).
    static let calibrationMaxPitchRange = 4.0
    static let calibrationMaxPhoneRangeY = Squat.calibrationMaxPhoneRangeY
    static let calibrationMaxPhoneDriftXZ = Squat.calibrationMaxPhoneDriftXZ
    static let calibrationMaxVerticalAccel = Squat.calibrationMaxVerticalAccel
    static let calibrationMaxAccelRMS = Squat.calibrationMaxAccelRMS
    /// Si el seguimiento del mundo nunca llega a `.normal` en este tiempo, se usa el respaldo.
    static let initialWorldGraceSeconds = Squat.initialWorldGraceSeconds

    // Señal y repetición
    /// Suavizado exponencial por muestra (≈ 60 Hz).
    static let emaAlpha = Squat.emaAlpha
    /// La rep cuenta cuando el teléfono se inclina ≥ 12° hacia atrás y vuelve a < 4° de la referencia.
    static let enterTiltDegrees = 12.0
    static let exitTiltDegrees = 4.0
    /// La ventana de la rep se abre cuando la inclinación pasa de esto (°).
    static let windowStartTiltDegrees = 3.0
    /// Duración de la rep completa (desde que empieza a inclinarse hasta que vuelve).
    static let minRepSeconds = 0.8
    static let maxRepSeconds = 6.0
    /// Margen extra antes de abortar una rep que no vuelve (s).
    static let abortGraceSeconds = 2.0
    /// La referencia de pie se adapta lento entre reps (deriva del mundo, cambio de postura), solo cerca de
    /// ella (|inclinación| ≤ `windowStartTiltDegrees`): inclinarse hacia adelante no la arrastra.
    static let referenceTimeConstant = 3.0
    /// Pantalla más arriba que la referencia (adelante, otro agarre) sostenida más de esto → recalibrar de pie.
    static let referenceResetSeconds = 4.0
    /// "Atrás" (para medir la cara en el mundo): fracción de `enterTiltDegrees`.
    static let backZoneFraction = 0.75
    /// Una inclinación que no llega a la meta pero pasa de esto recibe "Un poco más atrás, si no duele".
    static let shallowCueTiltDegrees = 7.0

    // Anti-muñecas (cara y teléfono giran juntos)
    /// Cambio máximo de la cara en el espacio del teléfono (m).
    static let faceGeometryMaxChange = 0.06
    /// Cambio máximo de la dirección de la cara vista desde el teléfono (°): con las muñecas gira lo mismo
    /// que el teléfono; con el tronco no cambia (cuerpo rígido).
    static let faceDirectionMaxChangeDegrees = 10.0
    /// La cara debe irse al menos esto hacia atrás en el mundo (m, horizontal).
    static let faceMinBackward = 0.03
    /// Separación horizontal teléfono-cara mínima para definir "hacia atrás"; si no, cuenta cualquier dirección.
    static let backwardBaselineMin = 0.05
    /// La 3ª vez que inclina solo con las muñecas la anomalía pasa a hard.
    static let wristsOnlyHardAt = 3

    // No es una extensión
    /// El teléfono no debe bajar más que esto durante la rep (m): eso es agacharse.
    static let maxPhoneDescent = 0.10
    /// Máximo de anomalías `notExtension` registradas (todas soft).
    static let notExtensionMaxRecorded = 5

    // Persona viva (mismos umbrales que la sentadilla)
    static let liveFaceMinEnergy = Squat.liveFaceMinEnergy
    static let staticWindowSeconds = Squat.staticWindowSeconds
    static let staticMinSamples = Squat.staticMinSamples
    static let faceLostBlockSeconds = Squat.faceLostBlockSeconds
    static let minTrackedFraction = Squat.minTrackedFraction
    static let faceDistanceMin = Squat.faceDistanceMin
    static let faceDistanceMax = Squat.faceDistanceMax

    // Desafío "Quédese atrás 2 segundos"
    /// "Atrás" para el desafío (°): bajo la meta, así una extensión corta también puede cumplirlo.
    static let holdMinTiltDegrees = 8.0
    /// Quedarse atrás = la inclinación varía a lo sumo esto (°, máx − mín) durante la pausa.
    static let holdBandDegrees = 3.0
    /// Tiempo extra permitido a la rep del desafío.
    static let holdExtraSeconds = 4.0

    // Sacudidas, caminar, desplazamiento
    static let shakingAccelRMS = Squat.shakingAccelRMS
    static let shakingSustainSeconds = Squat.shakingSustainSeconds
    static let walkingSteps = Squat.walkingSteps
    /// El teléfono no debe recorrer más que esto en horizontal durante una rep (m).
    static let maxRepHorizontalTravel = 0.35

    // Seguimiento del mundo
    static let worldLossToFallbackSeconds = Squat.worldLossToFallbackSeconds
    static let worldRecoverSeconds = Squat.worldRecoverSeconds
    static let maxPhoneJumpPerFrame = Squat.maxPhoneJumpPerFrame
    static let worldJumpDebounceSeconds = Squat.worldJumpDebounceSeconds
    static let maxIntegrationStep = Squat.maxIntegrationStep

    /// Cada cuánto se rehace la línea de depuración (s).
    static let debugIntervalSeconds = 0.1
}

/// Copy en vivo (usted, frases cortas).
nonisolated enum HandheldExtensionCopy {
    static let instructions = "Tome el teléfono con las dos manos frente al pecho y mírelo. Inclínese hacia atrás con todo el tronco, hasta donde no duela, y vuelva."
    static let takePhone = HandheldSquatCopy.takePhone
    static let holdStill = HandheldSquatCopy.holdStill
    static let ready = "Inclínese hacia atrás."
    static let keepFace = HandheldSquatCopy.keepFace
    static let tooClose = HandheldSquatCopy.tooClose
    static let tooFar = HandheldSquatCopy.tooFar
    static let moreBack = "Un poco más atrás, si no duele."
    static let slower = HandheldSquatCopy.slower
    static let quicker = "Vuelva sin quedarse tanto atrás."
    static let comeBack = "Vuelva derecho."
    static let wholeTrunk = "Con todo el tronco, no con las muñecas."
    static let noSquat = "No se agache: inclínese hacia atrás."
    static let stayInPlace = HandheldSquatCopy.stayInPlace
    static let noShake = HandheldSquatCopy.noShake
    static let uncoverCamera = HandheldSquatCopy.uncoverCamera
    static let lookAtScreen = HandheldSquatCopy.lookAtScreen
}

/// Nombres de anomalía de este verificador.
nonisolated enum HandheldExtensionAnomaly {
    static let wristsOnly = "wristsOnly"
    static let notExtension = "notExtension"
    static let staticFace = HandheldSquatAnomaly.staticFace
    static let holdChallengeFailed = HoldChallenge.anomalyKind
    static let shaking = HandheldSquatAnomaly.shaking
    static let tooRegular = RegularityDetector.anomalyKind
    static let walking = HandheldSquatAnomaly.walking
    static let inertialFallback = HandheldSquatAnomaly.inertialFallback
    static let worldJump = HandheldSquatAnomaly.worldJump
}

// MARK: - Verificador

nonisolated struct HandheldExtensionVerifier: ActivityVerifier, SourceLevelLimiting {
    typealias Sample = HandheldSquatSample
    private typealias K = HandheldExtensionTuning
    private typealias Copy = HandheldExtensionCopy

    /// `world`: el mundo (VIO) mide la cara y el teléfono; `inertial`: respaldo con cabeceo + encuadre.
    typealias Mode = HandheldSquatVerifier.Mode

    nonisolated enum Rejection: String, Sendable, Hashable, Codable {
        case tooFast, tooSlow, shaking, moved, faceMissing, notLive, faceDistance, notExtension, wristsOnly, holdMissed
    }

    /// Lo medido en una rep (tests y calibración en el dispositivo).
    nonisolated struct RepDiagnostics: Sendable, Hashable {
        var at: Double
        var mode: Mode
        var seconds: Double
        var peakTilt: Double
        var geometryChange: Double
        var directionChange: Double
        var faceBackward: Double?
        var phoneDescent: Double?
        var horizontalTravel: Double?
        var holdSeconds: Double
        var meanEnergy: Double
        var trackedFraction: Double
        var meanFaceDistance: Double?
        var challengeArmed: Bool
        var rejection: Rejection?
    }

    /// Postura de pie de referencia.
    nonisolated struct Reference: Sendable, Hashable {
        var pitch: Double
        var phone: SIMD3<Double>
        var face: SIMD3<Double>
        var faceInPhone: SIMD3<Double>

        var phoneXZ: SIMD2<Double> { SIMD2(phone.x, phone.z) }
        var faceXZ: SIMD2<Double> { SIMD2(face.x, face.z) }

        /// "Hacia atrás" en horizontal: del teléfono a la cara (la cara está detrás del teléfono).
        /// nil si casi no hay separación horizontal (dirección indefinida).
        var backward: SIMD2<Double>? {
            let d = faceXZ - phoneXZ
            let length = simd_length(d)
            return length >= HandheldExtensionTuning.backwardBaselineMin ? d / length : nil
        }
    }

    private nonisolated struct CalibrationPoint: Sendable, Hashable {
        var t: Double
        var phone: SIMD3<Double>
        var face: SIMD3<Double>
        var faceInPhone: SIMD3<Double>
        var pitch: Double
        var accel: Double
        var rms: Double?
    }

    private nonisolated struct RepWindow: Sendable, Hashable {
        var start: Double
        var challengeArmed: Bool
        var mode: Mode
        var entered = false
        var peakTilt = 0.0
        var maxGeometryChange = 0.0
        var maxDirectionChange = 0.0
        var maxFaceBackward: Double?
        var maxPhoneDescent: Double?
        var maxHorizontalTravel: Double?
        var hold = PlateauTimer(band: HandheldExtensionTuning.holdBandDegrees, floor: HandheldExtensionTuning.holdMinTiltDegrees)
        var holdDoneAnnounced = false
        var energySum = 0.0
        var energyCount = 0
        var samples = 0
        var trackedSamples = 0
        var distanceSum = 0.0
        var distanceCount = 0
        var shaking = false
        var backSamples = 0
        var backFaceSamples = 0
    }

    let kind: ActivityKind = .extensionLumbar
    let spec: VerificationSpec
    private(set) var progress: VerifierProgress
    private(set) var challenge: HoldChallenge
    private(set) var mode: Mode = .world
    private(set) var reference: Reference?
    private(set) var count = 0
    private(set) var anomalies: [Anomaly] = []
    private(set) var diagnostics: [RepDiagnostics] = []
    private(set) var repPeaks: [Double] = []
    private(set) var repSeconds: [Double] = []
    private(set) var inertialReps = 0
    /// Inclinación suavizada más reciente (°), para la depuración.
    private(set) var tilt = 0.0

    private var startT: Double?
    private var lastT: Double?
    private var lastSample: HandheldSquatSample?
    private var everReady = false
    private var completedEmitted = false
    private var reps = RepMachine(enterThreshold: K.enterTiltDegrees, exitThreshold: K.exitTiltDegrees,
                                  minRepSeconds: 0, maxRepSeconds: 3600)
    private var tiltSmooth = ExponentialSmoother(alpha: K.emaAlpha)
    private var faceSmooth = VectorSmoother(alpha: K.emaAlpha)
    private var fipSmooth = VectorSmoother(alpha: K.emaAlpha)
    private var calibration: [CalibrationPoint] = []
    private var window: RepWindow?
    private var regularity = RegularityDetector()

    private var faceLostSince: Double?
    private var worldEverNormal = false
    private var worldBadSince: Double?
    private var worldGoodSince: Double?
    private var lastWorldJumpAt: Double?
    private var energyWindow: [(t: Double, e: Double)] = []
    private var energySum = 0.0
    private var staticReported = false
    private var shakingSince: Double?
    private var shakingReported = false
    private var walkingReported = false
    private var inertialReported = false
    private var wristsOnlyCount = 0
    private var notExtensionCount = 0
    private var lastDebugAt: Double?
    /// Desde cuándo la pantalla está más arriba que la referencia (fuera de una rep).
    private var forwardOffsetSince: Double?

    /// - Parameter challenge: desafío de la sesión; se fuerza el texto de la extensión ("Quédese atrás").
    init(spec: VerificationSpec, challenge: HoldChallenge = .none) {
        self.spec = spec
        self.challenge = HoldChallenge(repNumber: challenge.repNumber, copy: .backExtension)
        progress = VerifierProgress(target: spec.target, hint: Copy.takePhone)
    }

    init(target: Int? = nil, demo: Bool = false, challenge: HoldChallenge = .none) {
        self.init(spec: .standard(for: .extensionLumbar, target: target, demo: demo), challenge: challenge)
    }

    // MARK: Lecturas

    var isLive: Bool { !staticReported }
    var minPeakTilt: Double? { repPeaks.min() }
    var meanRepSeconds: Double? { repSeconds.isEmpty ? nil : repSeconds.reduce(0, +) / Double(repSeconds.count) }

    /// Si alguna rep se midió con el respaldo IMU (sin seguimiento del mundo), la fuente no puede quedar
    /// `.live` aunque el resto de la serie lo fuera: tapar la cámara trasera solo en las reps baja a reduced.
    func limitedSourceLevel(_ declared: SourceLevel) -> SourceLevel {
        declared == .live && inertialReps > 0 ? .fallback : declared
    }

    // MARK: ActivityVerifier

    mutating func start(at t: Double) {
        self = HandheldExtensionVerifier(spec: spec, challenge: challenge.restarted)
        startT = t
    }

    mutating func ingest(_ s: HandheldSquatSample, at t: Double) -> [VerifierEvent] {
        var events: [VerifierEvent] = []
        if startT == nil { startT = t }
        let dt = lastT.map { min(K.maxIntegrationStep, max(0, t - $0)) } ?? 0
        lastT = t

        detectShaking(s, t, &events)
        detectWalking(s, t, &events)
        trackLiveness(s, t, &events)
        updateMode(s, t, &events)
        if s.faceTracked {
            faceSmooth.update(Self.d3(s.facePos))
            fipSmooth.update(Self.d3(s.faceInPhone))
        }
        detectWorldJump(s, t, &events)
        updateFaceGate(s, t, &events)

        switch progress.gate {
        case .calibrating: calibrate(s, t, &events)
        case .ready: track(s, t, dt, &events)
        case .blocked: break
        }

        updateDebug(s, t)
        progress.count = count
        progress.elapsed = max(0, t - (startT ?? t))
        lastSample = s
        return events
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        ActivityOutcome(
            kind: kind,
            target: progress.target,
            achieved: count,
            completed: count >= progress.target,
            durationSeconds: max(0, t - (startT ?? t)),
            metrics: .reps(count: count, minDescentRatio: nil, meanRepSeconds: meanRepSeconds),
            anomalies: anomalies.sorted { $0.at < $1.at },
            reason: reason)
    }

    // MARK: Gate

    private mutating func setGate(_ gate: GateState, _ events: inout [VerifierEvent]) {
        guard progress.gate != gate else { return }
        progress.gate = gate
        events.append(.gate(gate))
    }

    private mutating func abortRep() {
        window = nil
        reps.reset()
        tiltSmooth.reset()
    }

    /// Vuelve a calibrar de pie sin perder el conteo.
    private mutating func recalibrate(hint: String, _ events: inout [VerifierEvent]) {
        abortRep()
        forwardOffsetSince = nil
        calibration = []
        setGate(.calibrating, &events)
        progress.hint = hint
    }

    private mutating func updateFaceGate(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        if s.faceTracked {
            faceLostSince = nil
            if case .blocked(let reason) = progress.gate, reason == Copy.keepFace {
                recalibrate(hint: Copy.holdStill, &events)
            }
            return
        }
        if faceLostSince == nil { faceLostSince = t }
        let lost = t - (faceLostSince ?? t)
        switch progress.gate {
        case .ready where lost >= K.faceLostBlockSeconds:
            abortRep()
            setGate(.blocked(reason: Copy.keepFace), &events)
            progress.hint = Copy.keepFace
        case .calibrating:
            calibration = []
            progress.hint = everReady ? Copy.keepFace : Copy.takePhone
        default:
            break
        }
    }

    // MARK: Mundo ↔ respaldo

    private mutating func updateMode(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        if s.worldTrackingNormal {
            worldEverNormal = true
            worldBadSince = nil
            if worldGoodSince == nil { worldGoodSince = t }
        } else {
            worldGoodSince = nil
            if worldBadSince == nil { worldBadSince = t }
        }
        switch mode {
        case .world:
            let bad = t - (worldBadSince ?? t)
            let lostAfterNormal = worldEverNormal && worldBadSince != nil && bad >= K.worldLossToFallbackSeconds
            let neverStarted = !worldEverNormal && t - (startT ?? t) >= K.initialWorldGraceSeconds
            guard lostAfterNormal || neverStarted else { return }
            mode = .inertial
            switchedMode(&events)
        case .inertial:
            guard let good = worldGoodSince, t - good >= K.worldRecoverSeconds else { return }
            mode = .world
            switchedMode(&events)
        }
    }

    private mutating func switchedMode(_ events: inout [VerifierEvent]) {
        if progress.gate == .ready {
            recalibrate(hint: mode == .inertial ? Copy.uncoverCamera : Copy.holdStill, &events)
        } else {
            calibration = []
        }
    }

    private mutating func detectWorldJump(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        guard mode == .world, s.worldTrackingNormal, let last = lastSample, last.worldTrackingNormal else { return }
        let jump = simd_distance(Self.d3(s.phonePos), Self.d3(last.phonePos))
        guard jump > K.maxPhoneJumpPerFrame else { return }
        if progress.gate == .ready {
            if lastWorldJumpAt.map({ t - $0 >= K.worldJumpDebounceSeconds }) ?? true {
                lastWorldJumpAt = t
                record(Anomaly(kind: HandheldExtensionAnomaly.worldJump, severity: .soft, at: t,
                               detail: String(format: "El seguimiento saltó %.0f cm", jump * 100)), &events)
            }
            recalibrate(hint: Copy.holdStill, &events)
        } else {
            calibration = []
        }
    }

    // MARK: Calibración de pie

    private func faceDistance(_ s: HandheldSquatSample) -> Double { Double(simd_length(s.faceInPhone)) }

    private mutating func calibrate(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        guard s.faceTracked else { return }
        let distance = faceDistance(s)
        if distance < K.faceDistanceMin || distance > K.faceDistanceMax {
            calibration = []
            progress.hint = distance < K.faceDistanceMin ? Copy.tooClose : Copy.tooFar
            return
        }
        switch mode {
        case .world:
            guard s.worldTrackingNormal else {
                calibration = []
                return
            }
        case .inertial:
            guard s.verticalAccel != nil else {
                calibration = []
                progress.hint = Copy.uncoverCamera
                return
            }
        }
        calibration.append(CalibrationPoint(t: t, phone: Self.d3(s.phonePos), face: Self.d3(s.facePos),
                                            faceInPhone: Self.d3(s.faceInPhone), pitch: s.phonePitchDeg,
                                            accel: s.verticalAccel ?? 0, rms: s.userAccelRMS))
        while calibration.count > 1, calibration[1].t <= t - K.calibrationSeconds {
            calibration.removeFirst()
        }
        progress.hint = Copy.holdStill
        guard let first = calibration.first, t - first.t >= K.calibrationSeconds * 0.95, isStill(calibration) else { return }

        let n = Double(calibration.count)
        let zero = SIMD3<Double>(repeating: 0)
        reference = Reference(pitch: calibration.map(\.pitch).reduce(0, +) / n,
                              phone: calibration.map(\.phone).reduce(zero, +) / n,
                              face: calibration.map(\.face).reduce(zero, +) / n,
                              faceInPhone: calibration.map(\.faceInPhone).reduce(zero, +) / n)
        calibration = []
        abortRep()
        everReady = true
        setGate(.ready, &events)
        progress.hint = Copy.ready
        events.append(.cue(Cue(text: Copy.ready, symbol: "figure.flexibility")))
        announceChallengeIfNeeded(&events)
    }

    private func isStill(_ points: [CalibrationPoint]) -> Bool {
        let pitches = points.map(\.pitch)
        guard let pMin = pitches.min(), let pMax = pitches.max(), pMax - pMin <= K.calibrationMaxPitchRange else { return false }
        switch mode {
        case .world:
            let ys = points.map(\.phone.y)
            guard let yMin = ys.min(), let yMax = ys.max(), yMax - yMin <= K.calibrationMaxPhoneRangeY else { return false }
            let mean = points.map(\.phone).reduce(SIMD3<Double>(repeating: 0), +) / Double(points.count)
            return points.allSatisfy { simd_length(SIMD2($0.phone.x - mean.x, $0.phone.z - mean.z)) <= K.calibrationMaxPhoneDriftXZ }
        case .inertial:
            guard points.allSatisfy({ abs($0.accel) <= K.calibrationMaxVerticalAccel }) else { return false }
            return points.allSatisfy { ($0.rms ?? 0) <= K.calibrationMaxAccelRMS }
        }
    }

    // MARK: Conteo

    private mutating func track(_ s: HandheldSquatSample, _ t: Double, _ dt: Double, _ events: inout [VerifierEvent]) {
        guard var ref = reference else { return }
        // En modo mundo una muestra sin seguimiento normal no aporta (el respaldo entra a los 0,5 s).
        if mode == .world, !s.worldTrackingNormal { return }
        let world = mode == .world
        tilt = tiltSmooth.update(AngleMath.delta(ref.pitch, s.phonePitchDeg))
        let face = faceSmooth.value
        let fip = fipSmooth.value

        if window == nil {
            if tilt > K.windowStartTiltDegrees {
                forwardOffsetSince = nil
                window = RepWindow(start: t, challengeArmed: challenge.isArmed(nextRep: count + 1), mode: mode)
            } else if tilt < -K.windowStartTiltDegrees {
                // Hacia adelante (o el agarre cambió): no se adapta; si se sostiene, se vuelve a calibrar de pie.
                if forwardOffsetSince == nil { forwardOffsetSince = t }
                if t - (forwardOffsetSince ?? t) >= K.referenceResetSeconds {
                    forwardOffsetSince = nil
                    recalibrate(hint: Copy.holdStill, &events)
                }
                return
            } else {
                forwardOffsetSince = nil
                adaptReference(&ref, s, face: face, fip: fip, dt: dt)
                reference = ref
                return
            }
        }
        guard var w = window else { return }

        w.samples += 1
        if s.faceTracked {
            w.trackedSamples += 1
            w.energySum += Double(s.shapeEnergy)
            w.energyCount += 1
            w.distanceSum += faceDistance(s)
            w.distanceCount += 1
            if let fip {
                w.maxGeometryChange = max(w.maxGeometryChange, simd_length(fip - ref.faceInPhone))
                w.maxDirectionChange = max(w.maxDirectionChange, Self.angleDegrees(fip, ref.faceInPhone))
            }
        }
        if let rms = s.userAccelRMS, rms >= K.shakingAccelRMS { w.shaking = true }
        if world {
            let phone = Self.d3(s.phonePos)
            w.maxPhoneDescent = max(w.maxPhoneDescent ?? 0, ref.phone.y - phone.y)
            w.maxHorizontalTravel = max(w.maxHorizontalTravel ?? 0, simd_length(SIMD2(phone.x, phone.z) - ref.phoneXZ))
        }
        w.peakTilt = max(w.peakTilt, tilt)
        if tilt >= K.backZoneFraction * K.enterTiltDegrees {
            w.backSamples += 1
            if s.faceTracked { w.backFaceSamples += 1 }
            if world, s.faceTracked, let face {
                let backward = Self.faceBackward(face, ref)
                w.maxFaceBackward = max(w.maxFaceBackward ?? backward, backward)
            }
        }
        w.hold.add(tilt, at: t)
        if w.challengeArmed, !w.holdDoneAnnounced, w.hold.best >= HoldChallenge.requiredSeconds {
            w.holdDoneAnnounced = true
            events.append(.cue(challenge.copy.doneCue))
        }

        switch reps.update(tilt, at: t) {
        case .entered:
            w.entered = true
        case .rep:
            window = w
            closeWindow(at: t, &events)
            return
        case .rejected:
            window = nil
            reps.reset()
            return
        case .idle:
            if !w.entered, tilt <= K.windowStartTiltDegrees * 0.5 {
                if w.peakTilt >= K.shallowCueTiltDegrees {
                    events.append(.cue(Cue(text: Copy.moreBack, symbol: "arrow.uturn.backward")))
                }
                window = nil
                return
            }
            let limit = K.maxRepSeconds + (w.challengeArmed ? K.holdExtraSeconds : 0) + K.abortGraceSeconds
            if t - w.start > limit {
                // Atrás demasiado rato (o de pie con otra postura): se descarta sin contar y se vuelve a
                // calibrar de pie, para no quedar pegado a una referencia vieja.
                if w.entered { events.append(.cue(Cue(text: Copy.comeBack, symbol: "figure.stand"))) }
                recalibrate(hint: w.entered ? Copy.comeBack : Copy.holdStill, &events)
                return
            }
        }
        window = w
    }

    private mutating func adaptReference(_ ref: inout Reference, _ s: HandheldSquatSample, face: SIMD3<Double>?,
                                         fip: SIMD3<Double>?, dt: Double) {
        let k = min(1, dt / K.referenceTimeConstant)
        guard k > 0 else { return }
        if mode == .world, s.worldTrackingNormal {
            ref.phone += k * (Self.d3(s.phonePos) - ref.phone)
            if s.faceTracked, let face { ref.face += k * (face - ref.face) }
        }
        if s.faceTracked, let fip { ref.faceInPhone += k * (fip - ref.faceInPhone) }
        ref.pitch += k * AngleMath.delta(s.phonePitchDeg, ref.pitch)
    }

    /// La señal volvió: evalúa la ventana y cuenta o rechaza.
    private mutating func closeWindow(at t: Double, _ events: inout [VerifierEvent]) {
        guard let w = window else { return }
        window = nil
        reps.reset()
        let seconds = t - w.start
        let tracked = w.samples > 0 ? Double(w.trackedSamples) / Double(w.samples) : 0
        let energy = w.energyCount > 0 ? w.energySum / Double(w.energyCount) : 0
        let distance = w.distanceCount > 0 ? w.distanceSum / Double(w.distanceCount) : nil
        let maxSeconds = K.maxRepSeconds + (w.challengeArmed ? K.holdExtraSeconds : 0)
        let faceStayedInFrame = w.maxGeometryChange <= K.faceGeometryMaxChange
            && w.maxDirectionChange <= K.faceDirectionMaxChangeDegrees
        let faceWentBack = w.mode != .world || (w.maxFaceBackward ?? 0) >= K.faceMinBackward

        var rejection: Rejection?
        if w.shaking {
            rejection = .shaking
        } else if let travel = w.maxHorizontalTravel, travel > K.maxRepHorizontalTravel {
            rejection = .moved
        } else if tracked < K.minTrackedFraction || (w.backSamples > 0 && w.backFaceSamples == 0) {
            rejection = .faceMissing
        } else if energy < K.liveFaceMinEnergy {
            rejection = .notLive
        } else if let distance, distance < K.faceDistanceMin || distance > K.faceDistanceMax {
            rejection = .faceDistance
        } else if (w.maxPhoneDescent ?? 0) > K.maxPhoneDescent {
            rejection = .notExtension
        } else if !faceStayedInFrame || !faceWentBack {
            rejection = .wristsOnly
        } else if seconds < K.minRepSeconds {
            rejection = .tooFast
        } else if seconds > maxSeconds {
            rejection = .tooSlow
        } else if w.challengeArmed, w.hold.best < HoldChallenge.requiredSeconds {
            rejection = .holdMissed
        }

        diagnostics.append(RepDiagnostics(
            at: t, mode: w.mode, seconds: seconds, peakTilt: w.peakTilt, geometryChange: w.maxGeometryChange,
            directionChange: w.maxDirectionChange, faceBackward: w.maxFaceBackward, phoneDescent: w.maxPhoneDescent,
            horizontalTravel: w.maxHorizontalTravel, holdSeconds: w.hold.best, meanEnergy: energy,
            trackedFraction: tracked, meanFaceDistance: distance, challengeArmed: w.challengeArmed, rejection: rejection))

        guard let rejection else {
            countRep(w, seconds: seconds, at: t, &events)
            return
        }
        reject(rejection, w, at: t, &events)
    }

    private mutating func countRep(_ w: RepWindow, seconds: Double, at t: Double, _ events: inout [VerifierEvent]) {
        count += 1
        repPeaks.append(w.peakTilt)
        repSeconds.append(seconds)
        if w.challengeArmed { challenge.pass() }
        if w.mode == .inertial {
            inertialReps += 1
            if !inertialReported {
                inertialReported = true
                record(Anomaly(kind: HandheldExtensionAnomaly.inertialFallback, severity: .soft, at: t,
                               detail: "Contado con el cabeceo del teléfono: sin seguimiento del mundo"), &events)
            }
        }
        events.append(.rep(count))
        events.append(.progress(min(1, Double(count) / Double(max(1, progress.target)))))
        if let a = regularity.recordRep(at: t) { record(a, &events) }
        progress.count = count
        if count >= progress.target {
            if !completedEmitted {
                completedEmitted = true
                events.append(.completed)
            }
            return
        }
        progress.hint = Copy.ready
        announceChallengeIfNeeded(&events)
    }

    private mutating func reject(_ rejection: Rejection, _ w: RepWindow, at t: Double, _ events: inout [VerifierEvent]) {
        switch rejection {
        case .wristsOnly:
            wristsOnlyCount += 1
            let severity: Anomaly.Severity = wristsOnlyCount == K.wristsOnlyHardAt ? .hard : .soft
            let back = (w.maxFaceBackward ?? 0) * 100
            record(Anomaly(kind: HandheldExtensionAnomaly.wristsOnly, severity: severity, at: t,
                           detail: String(format: "Inclinó el teléfono %.0f° y la cara no acompañó (%.0f cm atrás, %.0f cm en el encuadre)",
                                          w.peakTilt, back, w.maxGeometryChange * 100)), &events)
            events.append(.cue(Cue(text: Copy.wholeTrunk, symbol: "figure.flexibility")))
        case .notExtension:
            notExtensionCount += 1
            if notExtensionCount <= K.notExtensionMaxRecorded {
                record(Anomaly(kind: HandheldExtensionAnomaly.notExtension, severity: .soft, at: t,
                               detail: String(format: "El teléfono bajó %.0f cm: se agachó", (w.maxPhoneDescent ?? 0) * 100)), &events)
            }
            events.append(.cue(Cue(text: Copy.noSquat, symbol: "figure.flexibility")))
        case .holdMissed:
            if let a = challenge.fail(at: t) { record(a, &events) }
            announceChallengeIfNeeded(&events)
        case .shaking:
            events.append(.cue(Cue(text: Copy.noShake, symbol: "iphone.radiowaves.left.and.right")))
        case .moved:
            events.append(.cue(Cue(text: Copy.stayInPlace, symbol: "figure.stand")))
        case .faceMissing:
            events.append(.cue(Cue(text: Copy.keepFace, symbol: "face.dashed")))
        case .notLive:
            events.append(.cue(Cue(text: Copy.lookAtScreen, symbol: "face.smiling")))
        case .faceDistance:
            let close = (w.distanceCount > 0 ? w.distanceSum / Double(w.distanceCount) : 0) < K.faceDistanceMin
            events.append(.cue(Cue(text: close ? Copy.tooClose : Copy.tooFar, symbol: "iphone")))
        case .tooFast:
            events.append(.cue(Cue(text: Copy.slower, symbol: "tortoise")))
        case .tooSlow:
            events.append(.cue(Cue(text: Copy.quicker, symbol: "figure.stand")))
        }
    }

    private mutating func announceChallengeIfNeeded(_ events: inout [VerifierEvent]) {
        guard progress.gate == .ready, let cue = challenge.announcement(nextRep: count + 1) else { return }
        events.append(.cue(cue))
        progress.hint = cue.text
    }

    private mutating func record(_ a: Anomaly, _ events: inout [VerifierEvent]) {
        anomalies.append(a)
        events.append(.anomaly(a))
    }

    // MARK: Anomalías de fondo

    private mutating func detectShaking(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        guard let rms = s.userAccelRMS, rms >= K.shakingAccelRMS else {
            shakingSince = nil
            return
        }
        if shakingSince == nil { shakingSince = t }
        guard !shakingReported, t - (shakingSince ?? t) >= K.shakingSustainSeconds else { return }
        shakingReported = true
        record(Anomaly(kind: HandheldExtensionAnomaly.shaking, severity: .hard, at: t,
                       detail: String(format: "Sacudida de %.1f g", rms)), &events)
        events.append(.cue(Cue(text: Copy.noShake, symbol: "iphone.radiowaves.left.and.right")))
        if window != nil { abortRep() }
    }

    private mutating func detectWalking(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        guard !walkingReported, let steps = s.steps, steps >= K.walkingSteps else { return }
        walkingReported = true
        record(Anomaly(kind: HandheldExtensionAnomaly.walking, severity: .soft, at: t,
                       detail: "\(steps) pasos durante la serie"), &events)
        events.append(.cue(Cue(text: Copy.stayInPlace, symbol: "figure.stand")))
    }

    /// Persona viva: media de `shapeEnergy` en los últimos 2 s con la cara seguida.
    private mutating func trackLiveness(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        guard s.faceTracked else { return }
        let e = Double(s.shapeEnergy)
        energyWindow.append((t, e))
        energySum += e
        while let first = energyWindow.first, first.t < t - K.staticWindowSeconds {
            energySum -= first.e
            energyWindow.removeFirst()
        }
        guard !staticReported, energyWindow.count >= K.staticMinSamples,
              let first = energyWindow.first, t - first.t >= K.staticWindowSeconds * 0.95 else { return }
        let mean = energySum / Double(energyWindow.count)
        guard mean < K.liveFaceMinEnergy else { return }
        staticReported = true
        record(Anomaly(kind: HandheldExtensionAnomaly.staticFace, severity: .hard, at: t,
                       detail: "Cara sin micro-movimiento: foto o máscara"), &events)
        events.append(.cue(Cue(text: Copy.lookAtScreen, symbol: "face.smiling")))
    }

    // MARK: Depuración (la vista la muestra solo en modo demo)

    private mutating func updateDebug(_ s: HandheldSquatSample, _ t: Double) {
        if let last = lastDebugAt, t - last < K.debugIntervalSeconds { return }
        lastDebugAt = t
        let source = mode == .world ? "mundo" : "respaldo"
        guard progress.gate == .ready, let ref = reference else {
            progress.debug = String(format: "Cabeceo %.0f° · %@", s.phonePitchDeg, source)
            return
        }
        let geometry = fipSmooth.value.map { simd_length($0 - ref.faceInPhone) * 100 } ?? 0
        let direction = fipSmooth.value.map { Self.angleDegrees($0, ref.faceInPhone) } ?? 0
        if mode == .world, let face = faceSmooth.value {
            progress.debug = String(format: "Inclinación %.0f° · cara %.0f cm atrás · encuadre %.0f cm %.0f° · %@",
                                    tilt, Self.faceBackward(face, ref) * 100, geometry, direction, source)
        } else {
            progress.debug = String(format: "Inclinación %.0f° · encuadre %.0f cm %.0f° · %@", tilt, geometry, direction, source)
        }
    }

    // MARK: Utilidades

    static func d3(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }

    /// Cuánto se fue la cara hacia atrás en horizontal respecto de la referencia (m, + atrás).
    static func faceBackward(_ face: SIMD3<Double>, _ ref: Reference) -> Double {
        let moved = SIMD2(face.x, face.z) - ref.faceXZ
        guard let backward = ref.backward else { return simd_length(moved) }
        return simd_dot(moved, backward)
    }

    /// Ángulo entre dos vectores (°); 0 si alguno es nulo.
    static func angleDegrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let la = simd_length(a), lb = simd_length(b)
        guard la > 0, lb > 0 else { return 0 }
        return acos(max(-1, min(1, simd_dot(a, b) / (la * lb)))) * 180 / .pi
    }
}

// MARK: - Muestras sintéticas (replay en simulador y tests)

/// Generador determinista de extensiones con el teléfono en las manos (≈ 60 Hz, ruido de VIO, IMU y
/// blendShapes). Mundo: Y arriba; la persona mira hacia −Z; el giro lumbar es alrededor del eje X por
/// `pivot`. El cabeceo y la cara en el espacio del teléfono se derivan del giro real del teléfono, con la
/// misma convención que `HandheldSquatRelay.attitude(gravity:)` (pantalla hacia arriba > 0).
nonisolated enum HandheldExtensionSynth {
    nonisolated enum Style: String, Sendable, Hashable, Codable {
        /// Extensión real: el tronco gira hacia atrás y arrastra teléfono y cabeza (cuerpo rígido).
        case backExtension
        /// Solo las muñecas giran el teléfono hacia atrás; la cara queda quieta en el mundo.
        case wristsOnly
        /// Sentadilla: teléfono y cara bajan; la pantalla se inclina un poco hacia arriba.
        case squat
        /// Sentadilla girando además el teléfono hacia atrás con las muñecas.
        case squatTilt
        /// Inclinarse hacia adelante (flexión): la pantalla mira hacia arriba y la cara se adelanta.
        case flexion
        /// Foto pegada al teléfono: el conjunto gira con las muñecas, sin micro-expresiones.
        case photo
    }

    nonisolated struct Rep: Sendable, Hashable {
        /// Inclinación máxima (°) del tronco (o de las muñecas).
        var tilt = 20.0
        var backSeconds = 1.0
        var holdSeconds = 0.3
        var returnSeconds = 1.0
        var restSeconds = 0.9
        var style: Style = .backExtension
        /// Descenso de la sentadilla (m), solo `.squat` / `.squatTilt`.
        var depth = 0.22

        init(tilt: Double = 20.0, backSeconds: Double = 1.0, holdSeconds: Double = 0.3, returnSeconds: Double = 1.0,
             restSeconds: Double = 0.9, style: Style = .backExtension, depth: Double = 0.22) {
            self.tilt = tilt
            self.backSeconds = backSeconds
            self.holdSeconds = holdSeconds
            self.returnSeconds = returnSeconds
            self.restSeconds = restSeconds
            self.style = style
            self.depth = depth
        }
    }

    nonisolated struct Options: Sendable, Hashable {
        var fps = 60.0
        var seed: UInt64 = 1
        var leadInSeconds = 1.8
        var trailSeconds = 1.0
        /// `false` = seguimiento del mundo limitado (cámara trasera tapada): posiciones sin sentido.
        var world = true
        /// Posición del teléfono de pie (m); por defecto `standingPhone`.
        var phone = HandheldExtensionSynth.standingPhone
        var positionNoise = 0.0015
        var pitchNoise = 0.4
        var shapeEnergy: Float = 0.02
        /// Cabeceo que la cabeza agrega sobre el tronco en el punto más atrás (m de la cara, realista).
        var headNod = 0.012
        var includeMotion = true
        var accelNoise = 0.04
        /// Caminar después del lead-in.
        var walkSpeed = 0.0
        var stepsPerSecond = 0.0
        var walkBobAmplitude = 0.025
        /// Sacudir el teléfono después del lead-in.
        var shakeAmplitude = 0.0
        var shakeHz = 6.0
        var shakeRMS = 1.2

        init() {}
    }

    /// Giro lumbar (m): detrás del pecho, a la altura de la cintura.
    static let pivot = SIMD3<Double>(0, 1.00, 0.42)
    static let standingPhone = SIMD3<Double>(0, 1.27, 0.12)
    static let standingFace = SIMD3<Double>(0, 1.58, 0.36)
    /// Cabeceo de pie: pantalla algo inclinada hacia arriba, hacia la cara.
    static let standingPitch = 35.0
    /// Las muñecas giran el teléfono alrededor de un punto un poco más abajo y más cerca del cuerpo.
    static let wristOffset = SIMD3<Double>(0, -0.05, 0.03)
    static let squatFaceRatio = 0.97
    static let squatScreenUpDegrees = 8.0

    /// Gira `v` alrededor del eje X "hacia atrás" (+Y → +Z) en grados.
    static func rotateBack(_ v: SIMD3<Double>, degrees: Double) -> SIMD3<Double> {
        let a = degrees * .pi / 180
        let c = cos(a), s = sin(a)
        return SIMD3(v.x, v.y * c - v.z * s, v.y * s + v.z * c)
    }

    /// Gravedad (g) en ejes del teléfono (x derecha, y arriba, z hacia la persona) para un teléfono
    /// vertical girado `degrees` hacia atrás: la convención de CoreMotion que lee la fuente en vivo.
    static func deviceGravity(backRotationDegrees degrees: Double) -> SIMD3<Double> {
        let y = rotateBack(SIMD3(0, 1, 0), degrees: degrees)
        let z = rotateBack(SIMD3(0, 0, 1), degrees: degrees)
        let g = SIMD3<Double>(0, -1, 0)
        return SIMD3(0, simd_dot(g, y), simd_dot(g, z))
    }

    nonisolated private struct Segment {
        var start: Double
        var rep: Rep
        var end: Double { start + rep.backSeconds + rep.holdSeconds + rep.returnSeconds }
    }

    nonisolated private struct Pose {
        var phone: SIMD3<Double>
        var face: SIMD3<Double>
        /// Giro del teléfono hacia atrás respecto de la postura de pie (°).
        var phoneRotation: Double
        var style: Style
    }

    /// Serie de reps (con su descanso) tras `leadInSeconds` de pie quieto.
    static func samples(reps: [Rep], options: Options = Options()) -> [HandheldSquatSample] {
        var rng = FixtureRandom(seed: options.seed)
        var segments: [Segment] = []
        var cursor = options.leadInSeconds
        for rep in reps {
            segments.append(Segment(start: cursor, rep: rep))
            cursor += rep.backSeconds + rep.holdSeconds + rep.returnSeconds + rep.restSeconds
        }
        let total = cursor + options.trailSeconds
        let dt = 1 / max(1, options.fps)
        let frames = Int((total / dt).rounded(.up))
        let phone0 = options.phone
        let face0 = standingFace
        let wrist = phone0 + wristOffset

        /// Pose sin ruido en `t` (para derivar la aceleración por diferencias finitas).
        func pose(at t: Double) -> Pose {
            var x = 0.0
            var rep = Rep()
            var active = false
            if let seg = segments.last(where: { $0.start <= t }), t < seg.end {
                active = true
                rep = seg.rep
                let local = t - seg.start
                if local < rep.backSeconds {
                    x = HandheldSquatSynth.minJerk(local / rep.backSeconds)
                } else if local < rep.backSeconds + rep.holdSeconds {
                    x = 1
                } else {
                    x = 1 - HandheldSquatSynth.minJerk((local - rep.backSeconds - rep.holdSeconds) / rep.returnSeconds)
                }
            }
            let style = active ? rep.style : .backExtension
            let theta = rep.tilt * x
            var p = Pose(phone: phone0, face: face0, phoneRotation: 0, style: style)
            switch style {
            case .backExtension:
                p.phone = pivot + rotateBack(phone0 - pivot, degrees: theta)
                p.face = pivot + rotateBack(face0 - pivot, degrees: theta) + SIMD3(0, -options.headNod, options.headNod * 0.5) * x
                p.phoneRotation = theta
            case .wristsOnly:
                p.phone = wrist + rotateBack(phone0 - wrist, degrees: theta)
                p.phoneRotation = theta
            case .squat, .squatTilt:
                let drop = rep.depth * x
                p.phone.y -= drop
                p.phone.z -= 0.02 * x
                p.face.y -= drop * squatFaceRatio
                p.face.z -= 0.04 * x
                p.phoneRotation = style == .squat ? -squatScreenUpDegrees * x : theta
            case .flexion:
                p.phone = pivot + rotateBack(phone0 - pivot, degrees: -theta)
                p.face = pivot + rotateBack(face0 - pivot, degrees: -theta)
                p.phoneRotation = -theta
            case .photo:
                p.phone = wrist + rotateBack(phone0 - wrist, degrees: theta)
                p.face = wrist + rotateBack(face0 - wrist, degrees: theta)
                p.phoneRotation = theta
            }
            if options.walkSpeed > 0, t >= options.leadInSeconds {
                let w = t - options.leadInSeconds
                let bob = options.walkBobAmplitude * sin(2 * .pi * options.stepsPerSecond * w)
                p.phone.z -= options.walkSpeed * w
                p.face.z -= options.walkSpeed * w
                p.phone.y += bob
                p.face.y += bob
            }
            if options.shakeAmplitude > 0, t >= options.leadInSeconds {
                let s = sin(2 * .pi * options.shakeHz * (t - options.leadInSeconds))
                p.phone.y += options.shakeAmplitude * s
                p.phone.x += options.shakeAmplitude * 0.6 * s
            }
            return p
        }

        var out: [HandheldSquatSample] = []
        out.reserveCapacity(frames + 1)
        for i in 0...frames {
            let t = Double(i) * dt
            let p = pose(at: t)
            let n = options.positionNoise
            func jitter(_ v: SIMD3<Double>) -> SIMD3<Double> {
                v + SIMD3(rng.symmetric(n), rng.symmetric(n), rng.symmetric(n))
            }
            // La cara vista desde el teléfono: deshacer el giro del teléfono.
            let faceInPhone = jitter(rotateBack(p.face - p.phone, degrees: -p.phoneRotation))
            let phoneWorld = options.world ? jitter(p.phone) : SIMD3(rng.symmetric(0.3), rng.symmetric(0.3), rng.symmetric(0.3))
            let faceWorld = options.world ? jitter(p.face) : SIMD3(0, 0, -0.45) + SIMD3(rng.symmetric(n), rng.symmetric(n), rng.symmetric(n))
            let energy = p.style == .photo ? Float(rng.unit() * 0.0004) : max(0, options.shapeEnergy * Float(0.5 + rng.unit()))

            var rms: Double? = nil
            var vertical: Double? = nil
            if options.includeMotion {
                let accel = (pose(at: t + dt).phone.y - 2 * p.phone.y + pose(at: t - dt).phone.y) / (dt * dt)
                vertical = accel + rng.symmetric(options.accelNoise)
                let shaking = options.shakeAmplitude > 0 && t >= options.leadInSeconds
                let walking = options.walkSpeed > 0 && t >= options.leadInSeconds
                let base = walking ? 0.25 : 0.02
                rms = shaking ? options.shakeRMS + rng.symmetric(0.1) : (base * base + (accel / 9.80665) * (accel / 9.80665)).squareRoot()
            }
            var steps: Int? = nil
            if options.stepsPerSecond > 0 {
                steps = t >= options.leadInSeconds ? Int(options.stepsPerSecond * (t - options.leadInSeconds)) : 0
            }

            out.append(HandheldSquatSample(
                t: t,
                phonePos: SIMD3<Float>(phoneWorld),
                phonePitchDeg: standingPitch - p.phoneRotation + rng.symmetric(options.pitchNoise),
                phoneRollDeg: rng.symmetric(0.5),
                faceTracked: true,
                facePos: SIMD3<Float>(faceWorld),
                faceInPhone: SIMD3<Float>(faceInPhone),
                shapeEnergy: energy,
                worldTrackingNormal: options.world,
                altitude: nil,
                userAccelRMS: rms,
                verticalAccel: vertical,
                steps: steps))
        }
        return out
    }

    /// Variaciones (una persona no es un metrónomo).
    static let tiltVariation = [19.0, 22.0, 18.0, 24.0, 20.0, 21.0, 17.0, 23.0, 20.0, 19.0, 22.0, 18.0]
    static let backVariation = [1.1, 1.3, 1.0, 1.4, 1.2, 1.05, 1.35, 1.15, 1.25, 1.0, 1.3, 1.2]
    static let returnVariation = [1.0, 1.2, 1.1, 1.3, 0.95, 1.15, 1.25, 1.05, 1.2, 1.1, 1.0, 1.3]
    static let restVariation = [0.8, 1.1, 0.9, 1.3, 0.7, 1.0, 1.2, 0.85, 1.05, 0.95, 1.15, 0.75]

    /// `count` reps variadas; la rep `holdAtRep` (1-based) se queda atrás 2,2 s.
    static func extensionReps(count: Int, holdAtRep: Int? = nil, style: Style = .backExtension) -> [Rep] {
        (0..<max(0, count)).map { i in
            let k = i % tiltVariation.count
            return Rep(tilt: tiltVariation[k], backSeconds: backVariation[k],
                       holdSeconds: (i + 1) == holdAtRep ? 2.2 : 0.3,
                       returnSeconds: returnVariation[k], restSeconds: restVariation[k], style: style)
        }
    }

    /// Serie completa para el replay del simulador: la meta con el desafío respetado.
    static func replay(target: Int, challengeRep: Int, seed: UInt64 = 13) -> [HandheldSquatSample] {
        var options = Options()
        options.seed = seed
        return samples(reps: extensionReps(count: target, holdAtRep: challengeRep), options: options)
    }
}
