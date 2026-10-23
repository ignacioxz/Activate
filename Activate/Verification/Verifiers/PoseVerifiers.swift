import Foundation
import simd

// Dueño: agente "pose" (sentadilla endurecida: agente "squats"). Máquinas de estado puras para las
// actividades de cámara de cuerpo (A3 sentadilla parcial en modo "Apoyado", A1 extensión lumbar de pie).
// Sin imports de Vision/AVFoundation/CoreMotion: consumen `PoseSample` (Vision ya convertido en
// `CameraPoseSource`) y `MotionSample` (SensorHub) y corren igual con fixtures.
//
// Sentadilla apoyada, anti-trampa:
// - Rodillas que se doblan de verdad: en el cuadro el muslo se acorta (la cadera baja más que la rodilla),
//   los tobillos no se mueven y el torso no se pliega (inclinarse de cintura no cuenta).
// - Teléfono inmóvil: con deviceMotion, si el teléfono se mueve mientras una rep está por contar
//   (alguien lo sube y baja para simular la sentadilla) → `phoneHandheld` (hard).
// - El mismo desafío "Quédese abajo 2 segundos" que el modo en las manos (`SquatHoldChallenge`).

// MARK: - Umbrales (valores iniciales; se calibran en el iPhone)

nonisolated enum PoseThresholds {
    /// Confianza mínima por articulación para considerarla "vista".
    static let minJointConfidence: Float = 0.5
    /// Confianza mínima para medir micro-movimiento frame a frame.
    static let motionJointConfidence: Float = 0.3
    /// Altura mínima del cuerpo (cuello → tobillo) como fracción del frame.
    static let minBodyHeight = 0.33
    /// Segundos seguidos con cuerpo entero antes de calibrar de pie.
    static let gatingSeconds = 1.0
    /// Segundos seguidos sin cuerpo entero antes de bloquear (tolera un frame perdido).
    static let gateLossGraceSeconds = 0.3

    /// Sentadilla: descenso de cadera (fracción de h0) para entrar y salir de la rep.
    static let squatEnter = 0.12
    static let squatExit = 0.04
    /// Rodillas de verdad: en el fondo el muslo (cadera − rodilla, vertical) se acorta al menos esta
    /// fracción del descenso de la cadera (si baja todo el cuerpo igual, se movió la cámara o la persona).
    static let squatThighMinRatio = 0.4
    /// Torso que no se pliega: (cuello − cadera) se acorta a lo sumo esta fracción del descenso + margen.
    static let squatTorsoMaxFoldRatio = 0.5
    static let squatTorsoFoldSlack = 0.03
    /// Tobillos quietos (fracción de h0).
    static let squatAnkleMaxMove = 0.04
    /// "Abajo" para el desafío de la pausa (fracción de h0).
    static let squatHoldMinDescent = 0.09
    /// Quedarse abajo = la cadera varía a lo sumo esto (fracción de h0, máx − mín) durante la pausa.
    static let squatHoldBand = 0.03
    /// Máximo de anomalías `torsoBend` registradas.
    static let squatTorsoBendMaxRecorded = 5

    /// Extensión: desplazamiento horizontal hombros-cadera (fracción del frame) o subida del cuello (fracción de h0).
    static let extensionShoulderShift = 0.06
    static let extensionNeckRise = 0.03
    /// La rep de extensión termina cuando la señal normalizada vuelve bajo esta fracción.
    static let extensionExit = 0.35
    /// La cadera debe estar "quieta" para que empiece una extensión (fracción de h0).
    static let extensionHipStill = 0.06

    static let minRepSeconds = 0.6
    static let maxRepSeconds = 6.0
    /// Suavizado exponencial de la señal (por frame, ~30 fps).
    static let emaAlpha = 0.35

    static let lowFps = 12.0
    static let lowFpsSustainedSeconds = 2.0
    /// Imagen estática: micro-movimiento máximo por frame (fracción del frame) y duración.
    static let staticMotionEpsilon = 0.002
    static let staticSeconds = 3.0
    /// Serie demasiado regular: coeficiente de variación de intervalos con al menos estas reps.
    static let tooRegularMinReps = 6
    static let tooRegularCV = 0.04
    /// Encuadre que salta: el cuello se mueve más que esto (fracción del frame) entre dos frames.
    static let phoneMovedNeckJump = 0.15
    /// Separación mínima entre dos anomalías `phoneMoved`.
    static let phoneMovedDebounceSeconds = 1.0
}

/// Copy en vivo de la actividad de cámara (usted, frases cortas).
nonisolated enum PoseCopy {
    static let placePhone = "Apoye el teléfono. Aléjese."
    static let holdStill = "Quieto un segundo."
    static let fullBody = "Lo veo entero."
    static let partialBody = "Lo veo a medias. Aléjese."
    static let noBody = "No lo veo. Párese al frente."
    static let squatHint = "Baje y suba."
    static let extensionHint = "Estírese hacia atrás."
    static let slower = "Más lento."
    static let comeBackUp = "Vuelva arriba."
    static let phoneMoved = "Se movió el teléfono."
    static let keepMoving = "Muévase un poco."
    static let bendKnees = "Doble las rodillas, espalda derecha."
    static let stayInPlace = "Quédese en su lugar."
    static let leavePhone = "Deje el teléfono apoyado."
}

/// Nombres de anomalía que producen estos verificadores.
nonisolated enum PoseAnomaly {
    static let lowFps = "lowFps"
    static let staticImage = "static"
    static let tooRegular = "tooRegular"
    static let phoneMoved = "phoneMoved"
    static let phoneHandheld = "phoneHandheld"
    static let torsoBend = "torsoBend"
}

// MARK: - Geometría de un frame

nonisolated struct PosePoint: Sendable, Hashable {
    var x: Double
    var y: Double

    func distance(to other: PosePoint) -> Double {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }

    static func mid(_ a: PosePoint, _ b: PosePoint) -> PosePoint { PosePoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
}

/// Lectura simplificada de una `PoseSample`: lo que necesitan las máquinas de estado.
nonisolated struct PoseFrame: Sendable {
    var t: Double
    var fps: Double
    var neck: PosePoint?
    var hip: PosePoint?
    var shoulders: PosePoint?
    var ankleY: Double?
    /// Altura media de las rodillas vistas (con su cadera).
    var kneeY: Double?
    /// |neck.y − ankle.y| cuando hay cuello y una pierna entera.
    var height: Double?
    /// Cuerpo entero en cuadro: cadera/rodilla/tobillo de una pierna, cuello y altura ≥ mínimo.
    var fullBody: Bool
    /// Alguna articulación con confianza mínima.
    var anyJoint: Bool
    /// Máximo |Δ| de una articulación respecto del frame anterior (nil si no es comparable).
    var motion: Double?

    init(sample: PoseSample, at t: Double, previous: [JointKey: JointPoint]?) {
        self.t = t
        fps = sample.fps
        let minC = PoseThresholds.minJointConfidence
        func seen(_ k: JointKey) -> PosePoint? {
            guard let j = sample.joints[k], j.confidence >= minC else { return nil }
            return PosePoint(x: j.x, y: j.y)
        }
        anyJoint = sample.joints.values.contains { $0.confidence >= minC }

        let ls = seen(.leftShoulder), rs = seen(.rightShoulder)
        switch (ls, rs) {
        case let (l?, r?): shoulders = PosePoint.mid(l, r)
        case let (l?, nil): shoulders = l
        case let (nil, r?): shoulders = r
        default: shoulders = nil
        }
        neck = seen(.neck) ?? shoulders

        let lh = seen(.leftHip), rh = seen(.rightHip)
        if let root = seen(.root) {
            hip = root
        } else {
            switch (lh, rh) {
            case let (l?, r?): hip = PosePoint.mid(l, r)
            case let (l?, nil): hip = l
            case let (nil, r?): hip = r
            default: hip = nil
            }
        }

        var ankles: [Double] = []
        var knees: [Double] = []
        if lh != nil, let k = seen(.leftKnee) {
            knees.append(k.y)
            if let a = seen(.leftAnkle) { ankles.append(a.y) }
        }
        if rh != nil, let k = seen(.rightKnee) {
            knees.append(k.y)
            if let a = seen(.rightAnkle) { ankles.append(a.y) }
        }
        ankleY = ankles.isEmpty ? nil : ankles.reduce(0, +) / Double(ankles.count)
        kneeY = knees.isEmpty ? nil : knees.reduce(0, +) / Double(knees.count)

        if let neck, let ankleY {
            height = abs(neck.y - ankleY)
        } else {
            height = nil
        }
        fullBody = neck != nil && hip != nil && (height ?? 0) >= PoseThresholds.minBodyHeight

        if let previous {
            var maxMove: Double? = nil
            let mc = PoseThresholds.motionJointConfidence
            for (k, j) in sample.joints where j.confidence >= mc {
                guard let p = previous[k], p.confidence >= mc else { continue }
                let d = abs(j.x - p.x) + abs(j.y - p.y)
                maxMove = max(maxMove ?? 0, d)
            }
            motion = maxMove
        } else {
            motion = nil
        }
    }
}

/// Postura de pie de referencia (medias de la ventana de gating).
nonisolated struct PoseCalibration: Sendable, Equatable {
    var hipX0: Double
    var hipY0: Double
    var neckY0: Double
    /// Altura del cuerpo en el frame (cuello → tobillo).
    var h0: Double
    /// Desplazamiento horizontal hombros − cadera de pie (nil si no se vieron hombros).
    var shoulderDx0: Double? = nil
    /// Rodillas y tobillos de pie (nil si no se vieron).
    var kneeY0: Double? = nil
    var ankleY0: Double? = nil
}

// MARK: - Núcleo compartido: gating, calibración y anomalías de cámara

/// Lógica común de las actividades de cámara: encuadre, calibración de pie, fps, imagen estática,
/// teléfono que se mueve. Cada verificador suma encima su señal y su contador de reps.
nonisolated struct PoseCore: Sendable {
    private(set) var gate: GateState = .calibrating
    private(set) var calibration: PoseCalibration?
    private(set) var anomalies: [Anomaly] = []
    /// Nombre de la actividad para el hint cuando el gate está listo.
    var readyHint: String

    private var previousJoints: [JointKey: JointPoint]?
    private var okSince: Double?
    private var lossSince: Double?
    private var window = CalibrationWindow()
    private var lowFpsSince: Double?
    private var lowFpsReported = false
    private var staticSince: Double?
    private var staticReported = false
    private var lastNeck: PosePoint?
    private var pendingJumpFrom: PosePoint?
    private var lastPhoneMovedAt: Double?

    nonisolated struct CalibrationWindow: Sendable {
        var n = 0
        var hipX = 0.0, hipY = 0.0, neckY = 0.0, h = 0.0
        var nShoulders = 0
        var shoulderDx = 0.0
        var nKnees = 0, kneeY = 0.0
        var nAnkles = 0, ankleY = 0.0
        mutating func reset() { self = CalibrationWindow() }
        mutating func add(_ f: PoseFrame) {
            guard let hip = f.hip, let neck = f.neck, let height = f.height else { return }
            n += 1
            hipX += hip.x; hipY += hip.y; neckY += neck.y; h += height
            if let s = f.shoulders { nShoulders += 1; shoulderDx += s.x - hip.x }
            if let k = f.kneeY { nKnees += 1; kneeY += k }
            if let a = f.ankleY { nAnkles += 1; ankleY += a }
        }
        var calibration: PoseCalibration? {
            guard n > 0 else { return nil }
            let d = Double(n)
            return PoseCalibration(hipX0: hipX / d, hipY0: hipY / d, neckY0: neckY / d, h0: h / d,
                                   shoulderDx0: nShoulders > 0 ? shoulderDx / Double(nShoulders) : nil,
                                   kneeY0: nKnees > 0 ? kneeY / Double(nKnees) : nil,
                                   ankleY0: nAnkles > 0 ? ankleY / Double(nAnkles) : nil)
        }
    }

    /// Qué pasó en este frame, para que el verificador decida qué hacer con su señal.
    nonisolated struct Step: Sendable {
        var frame: PoseFrame
        var events: [VerifierEvent] = []
        /// El gate acaba de pasar a `ready` (calibración nueva): reiniciar señal y rep en curso.
        var recalibrated = false
        /// El gate dejó de estar listo (bloqueo o recalibración): abortar la rep en curso.
        var lostTracking = false
        /// Hay calibración, el gate está listo y el frame trae cuerpo entero: se puede medir.
        var trackable: Bool
    }

    init(readyHint: String) {
        self.readyHint = readyHint
    }

    var isReady: Bool { gate == .ready }

    var hint: String {
        switch gate {
        case .calibrating: okSince == nil ? PoseCopy.placePhone : PoseCopy.holdStill
        case .ready: readyHint
        case .blocked(let reason): reason
        }
    }

    mutating func start() {
        self = PoseCore(readyHint: readyHint)
    }

    mutating func ingest(_ sample: PoseSample, at t: Double) -> Step {
        let frame = PoseFrame(sample: sample, at: t, previous: previousJoints)
        previousJoints = sample.joints
        var step = Step(frame: frame, trackable: false)

        detectPhoneMoved(frame, &step)
        updateGate(frame, &step)
        detectLowFps(frame, &step)
        detectStatic(frame, &step)

        step.trackable = gate == .ready && calibration != nil && frame.fullBody
        return step
    }

    // MARK: Gate

    private mutating func updateGate(_ f: PoseFrame, _ step: inout Step) {
        if f.fullBody {
            lossSince = nil
            if okSince == nil {
                okSince = f.t
                window.reset()
                if gate == .calibrating { step.events.append(.cue(Cue(text: PoseCopy.holdStill, symbol: "figure.stand"))) }
            }
            if gate != .ready {
                window.add(f)
                if f.t - (okSince ?? f.t) >= PoseThresholds.gatingSeconds, let cal = window.calibration {
                    calibration = cal
                    gate = .ready
                    step.recalibrated = true
                    step.events.append(.gate(.ready))
                    step.events.append(.cue(Cue(text: PoseCopy.fullBody, symbol: "checkmark.circle.fill")))
                }
            }
        } else {
            okSince = nil
            window.reset()
            if lossSince == nil { lossSince = f.t }
            let reason = f.anyJoint ? PoseCopy.partialBody : PoseCopy.noBody
            switch gate {
            case .ready:
                if f.t - (lossSince ?? f.t) >= PoseThresholds.gateLossGraceSeconds {
                    gate = .blocked(reason: reason)
                    step.lostTracking = true
                    step.events.append(.gate(gate))
                }
            case .blocked(let current) where current != reason:
                gate = .blocked(reason: reason)
                step.events.append(.gate(gate))
            default:
                break
            }
        }
    }

    /// Vuelve a calibrar sin perder el conteo (teléfono movido).
    private mutating func invalidateCalibration(_ step: inout Step) {
        okSince = nil
        window.reset()
        if gate == .ready { step.lostTracking = true }
        gate = .calibrating
        step.events.append(.gate(.calibrating))
        step.events.append(.cue(Cue(text: PoseCopy.phoneMoved, symbol: "iphone.gen3.radiowaves.left.and.right")))
    }

    // MARK: Anomalías

    private mutating func detectPhoneMoved(_ f: PoseFrame, _ step: inout Step) {
        guard let neck = f.neck else {
            // Sin cuello no se puede confirmar ni descartar; si había un salto pendiente se da por confirmado.
            if pendingJumpFrom != nil {
                pendingJumpFrom = nil
                reportPhoneMoved(at: f.t, step: &step)
            }
            return
        }
        defer { lastNeck = neck }
        if let from = pendingJumpFrom {
            pendingJumpFrom = nil
            if neck.distance(to: from) > PoseThresholds.phoneMovedNeckJump {
                reportPhoneMoved(at: f.t, step: &step)
            }
            return
        }
        if let last = lastNeck, neck.distance(to: last) > PoseThresholds.phoneMovedNeckJump {
            pendingJumpFrom = last
        }
    }

    private mutating func reportPhoneMoved(at t: Double, step: inout Step) {
        guard gate == .ready else {
            // Mientras se acomoda el teléfono los saltos son normales: solo reinicia la ventana.
            okSince = nil
            window.reset()
            return
        }
        if let last = lastPhoneMovedAt, t - last < PoseThresholds.phoneMovedDebounceSeconds { return }
        lastPhoneMovedAt = t
        let a = Anomaly(kind: PoseAnomaly.phoneMoved, severity: .soft, at: t, detail: "El encuadre saltó")
        anomalies.append(a)
        step.events.append(.anomaly(a))
        invalidateCalibration(&step)
    }

    private mutating func detectLowFps(_ f: PoseFrame, _ step: inout Step) {
        guard f.fps > 0 else { return }
        if f.fps < PoseThresholds.lowFps {
            if lowFpsSince == nil { lowFpsSince = f.t }
            if !lowFpsReported, f.t - (lowFpsSince ?? f.t) >= PoseThresholds.lowFpsSustainedSeconds {
                lowFpsReported = true
                let a = Anomaly(kind: PoseAnomaly.lowFps, severity: .soft, at: f.t,
                                detail: String(format: "%.0f fps", f.fps))
                anomalies.append(a)
                step.events.append(.anomaly(a))
            }
        } else {
            lowFpsSince = nil
        }
    }

    private mutating func detectStatic(_ f: PoseFrame, _ step: inout Step) {
        guard f.fullBody, let motion = f.motion, motion < PoseThresholds.staticMotionEpsilon else {
            staticSince = nil
            staticReported = false
            return
        }
        if staticSince == nil { staticSince = f.t }
        if !staticReported, f.t - (staticSince ?? f.t) > PoseThresholds.staticSeconds {
            staticReported = true
            let a = Anomaly(kind: PoseAnomaly.staticImage, severity: .hard, at: f.t, detail: "Imagen sin micro-movimiento")
            anomalies.append(a)
            step.events.append(.anomaly(a))
            step.events.append(.cue(Cue(text: PoseCopy.keepMoving, symbol: "figure.walk.motion")))
        }
    }
}

// MARK: - Contador de reps (entrar / salir con histéresis, duración mínima y máxima)

nonisolated struct RepCounter: Sendable {
    nonisolated enum Outcome: Sendable, Equatable {
        case none
        case entered
        case counted(Int)
        case tooFast
        case tooSlow
    }

    let enter: Double
    let exit: Double
    let minRep: Double
    let maxRep: Double

    private(set) var count = 0
    private(set) var inRep = false
    private(set) var repStart = 0.0
    private(set) var peak = 0.0
    private(set) var completedAt: [Double] = []
    private(set) var peaks: [Double] = []
    private(set) var durations: [Double] = []
    private var tooSlowNotified = false

    init(enter: Double, exit: Double,
         minRep: Double = PoseThresholds.minRepSeconds, maxRep: Double = PoseThresholds.maxRepSeconds) {
        self.enter = enter
        self.exit = exit
        self.minRep = minRep
        self.maxRep = maxRep
    }

    /// Anula la última rep contada (la rechazó una regla del verificador después de contarla).
    mutating func revokeLast() {
        guard count > 0 else { return }
        count -= 1
        if !completedAt.isEmpty { completedAt.removeLast() }
        if !peaks.isEmpty { peaks.removeLast() }
        if !durations.isEmpty { durations.removeLast() }
    }

    /// Aborta la rep en curso (se perdió el encuadre); conserva el conteo.
    mutating func abortRep() {
        inRep = false
        peak = 0
        tooSlowNotified = false
    }

    mutating func ingest(signal s: Double, at t: Double) -> Outcome {
        if !inRep {
            guard s >= enter else { return .none }
            inRep = true
            repStart = t
            peak = s
            tooSlowNotified = false
            return .entered
        }
        peak = max(peak, s)
        let elapsed = t - repStart
        if s <= exit {
            inRep = false
            if elapsed < minRep { return .tooFast }
            if elapsed > maxRep { return .tooSlow }
            count += 1
            completedAt.append(t)
            peaks.append(peak)
            durations.append(elapsed)
            return .counted(count)
        }
        if elapsed > maxRep, !tooSlowNotified {
            tooSlowNotified = true
            return .tooSlow
        }
        return .none
    }

    /// Coeficiente de variación de los intervalos entre reps (nil con menos de 3 reps).
    var intervalCV: Double? {
        guard completedAt.count >= 3 else { return nil }
        var intervals: [Double] = []
        for i in 1..<completedAt.count { intervals.append(completedAt[i] - completedAt[i - 1]) }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        guard mean > 0 else { return nil }
        let variance = intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(intervals.count)
        return variance.squareRoot() / mean
    }

    var minPeak: Double? { peaks.min() }
    var meanDuration: Double? { durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count) }
}

// MARK: - Motor compartido de verificador de reps por cámara

/// Une `PoseCore` + `RepCounter` + señal; `SquatVerifier` y `ExtensionVerifier` solo definen la señal.
nonisolated struct PoseRepEngine: Sendable {
    var core: PoseCore
    var reps: RepCounter
    private(set) var progress: VerifierProgress
    private(set) var ema: Double?
    private(set) var startT: Double?
    private(set) var completedEmitted = false
    private(set) var tooRegularReported = false
    private(set) var repAnomalies: [Anomaly] = []

    init(target: Int, readyHint: String, enter: Double, exit: Double) {
        core = PoseCore(readyHint: readyHint)
        reps = RepCounter(enter: enter, exit: exit)
        progress = VerifierProgress(target: target, hint: PoseCopy.placePhone)
    }

    mutating func start(at t: Double) {
        let target = progress.target
        let hint = core.readyHint
        self = PoseRepEngine(target: target, readyHint: hint, enter: reps.enter, exit: reps.exit)
        startT = t
        progress.hint = core.hint
    }

    /// `signal(frame, calibration, inRep)` devuelve la señal cruda del ejercicio (nil = no medible en este frame).
    /// `veto(t)` se consulta al completar una rep: `nil` la cuenta; si devuelve eventos, la rep se anula
    /// y se emiten esos eventos (consigna, anomalía).
    mutating func ingest(_ sample: PoseSample, at t: Double,
                         signal: (PoseFrame, PoseCalibration, Bool) -> Double?,
                         veto: ((Double) -> [VerifierEvent]?)? = nil) -> [VerifierEvent] {
        if startT == nil { startT = t }
        let step = core.ingest(sample, at: t)
        var events = step.events

        if step.lostTracking || step.recalibrated {
            reps.abortRep()
            ema = nil
        }

        if step.trackable, let cal = core.calibration, let raw = signal(step.frame, cal, reps.inRep) {
            let smoothed: Double
            if let previous = ema {
                smoothed = previous + PoseThresholds.emaAlpha * (raw - previous)
            } else {
                smoothed = raw
            }
            ema = smoothed
            switch reps.ingest(signal: smoothed, at: t) {
            case .none, .entered:
                break
            case .counted(let n):
                if let rejection = veto?(t) {
                    reps.revokeLast()
                    events.append(contentsOf: rejection)
                    break
                }
                events.append(.rep(n))
                events.append(.progress(min(1, Double(n) / Double(max(1, progress.target)))))
                checkRegularity(at: t, &events)
                if n >= progress.target, !completedEmitted {
                    completedEmitted = true
                    events.append(.completed)
                }
            case .tooFast:
                events.append(.cue(Cue(text: PoseCopy.slower, symbol: "tortoise")))
            case .tooSlow:
                events.append(.cue(Cue(text: PoseCopy.comeBackUp, symbol: "arrow.up")))
            }
        }

        progress.count = reps.count
        progress.gate = core.gate
        progress.hint = core.hint
        progress.elapsed = t - (startT ?? t)
        return events
    }

    private mutating func checkRegularity(at t: Double, _ events: inout [VerifierEvent]) {
        guard !tooRegularReported, reps.count >= PoseThresholds.tooRegularMinReps,
              let cv = reps.intervalCV, cv < PoseThresholds.tooRegularCV else { return }
        tooRegularReported = true
        let a = Anomaly(kind: PoseAnomaly.tooRegular, severity: .hard, at: t,
                        detail: String(format: "CV %.3f", cv))
        repAnomalies.append(a)
        events.append(.anomaly(a))
    }

    func outcome(kind: ActivityKind, at t: Double, reason: FinishReason, extra: [Anomaly] = []) -> ActivityOutcome {
        let all = (core.anomalies + repAnomalies + extra).sorted { $0.at < $1.at }
        return ActivityOutcome(
            kind: kind,
            target: progress.target,
            achieved: reps.count,
            completed: reps.count >= progress.target,
            durationSeconds: max(0, t - (startT ?? t)),
            metrics: .reps(count: reps.count, minDescentRatio: reps.minPeak, meanRepSeconds: reps.meanDuration),
            anomalies: all,
            reason: reason)
    }
}

// MARK: - A3 Sentadilla parcial (modo "Apoyado")

/// Lo medido en una rep de cámara: el fondo (frame de máximo descenso de la cadera), los tobillos,
/// la pausa abajo y si el teléfono se movió.
nonisolated struct SquatPoseWindow: Sendable, Hashable {
    var peakDescent = 0.0
    /// Acortamiento del muslo y del torso en el frame de máximo descenso (fracción de h0).
    var thighShortAtPeak: Double?
    var torsoShortAtPeak: Double?
    var ankleMoveMax = 0.0
    var hold = PlateauTimer(band: PoseThresholds.squatHoldBand, floor: PoseThresholds.squatHoldMinDescent)
    var holdBest: Double { hold.best }
    /// deviceMotion vio el teléfono moverse durante la rep.
    var phoneMoved = false

    mutating func observe(_ frame: PoseFrame, _ cal: PoseCalibration, descent: Double, at t: Double) {
        if descent > peakDescent {
            peakDescent = descent
            if let hip = frame.hip, let knee = frame.kneeY, let knee0 = cal.kneeY0 {
                let thigh0 = cal.hipY0 - knee0
                thighShortAtPeak = (thigh0 - (hip.y - knee)) / cal.h0
            }
            if let hip = frame.hip, let neck = frame.neck {
                let torso0 = cal.neckY0 - cal.hipY0
                torsoShortAtPeak = (torso0 - (neck.y - hip.y)) / cal.h0
            }
        }
        if let ankle = frame.ankleY, let ankle0 = cal.ankleY0 {
            ankleMoveMax = max(ankleMoveMax, abs(ankle - ankle0) / cal.h0)
        }
        hold.add(descent, at: t)
    }
}

/// Teléfono apoyado de verdad: deviceMotion casi sin rotación ni aceleración y gravedad fija.
nonisolated struct PhoneStillnessMonitor: Sendable, Hashable {
    /// Umbrales: un teléfono sobre la mesa queda muy por debajo; en la mano (temblor) o moviéndolo, por encima.
    static let maxRotationRate = 0.35
    static let maxUserAccel = 0.06
    /// El movimiento debe sostenerse esto (un golpe a la mesa no basta).
    static let sustainSeconds = 0.25
    /// Inclinación máxima respecto de la gravedad de referencia (°).
    static let maxTiltDegrees = 4.0
    /// La referencia de gravedad se re-ancla tras este tiempo quieto.
    static let rebaseStillSeconds = 1.0

    private(set) var isMoving = false
    private var movingSince: Double?
    private var stillSince: Double?
    private var gravityRef: SIMD3<Double>?

    /// Devuelve si el teléfono se está moviendo (sostenido) tras esta muestra.
    @discardableResult
    mutating func ingest(_ m: MotionSample, at t: Double) -> Bool {
        let g = m.gravity
        var tilted = false
        if let ref = gravityRef, simd_length(ref) > 0, simd_length(g) > 0 {
            let c = max(-1, min(1, simd_dot(ref, g) / (simd_length(ref) * simd_length(g))))
            tilted = acos(c) * 180 / .pi > Self.maxTiltDegrees
        } else {
            gravityRef = g
        }
        let agitated = simd_length(m.rotationRate) > Self.maxRotationRate || simd_length(m.userAccel) > Self.maxUserAccel
        if agitated || tilted {
            stillSince = nil
            if movingSince == nil { movingSince = t }
            isMoving = t - (movingSince ?? t) >= Self.sustainSeconds
        } else {
            movingSince = nil
            isMoving = false
            if stillSince == nil { stillSince = t }
            if let still = stillSince, t - still >= Self.rebaseStillSeconds { gravityRef = g }
        }
        return isMoving
    }
}

/// Señal = descenso vertical de la cadera normalizado por la estatura en el frame.
/// Media sentadilla (descenso máximo < `squatEnter`) no cuenta; tampoco la que no dobla rodillas,
/// la que mueve los pies, la que pliega el torso, ni la que ocurre con el teléfono en la mano.
nonisolated struct SquatVerifier: ActivityVerifier {
    typealias Sample = PoseSample

    nonisolated enum Rejection: String, Sendable, Hashable, Codable {
        case phoneHandheld, feetMoved, kneesStraight, torsoBend, holdMissed
    }

    let kind: ActivityKind = .sentadilla
    let spec: VerificationSpec
    private var engine: PoseRepEngine
    private(set) var challenge: SquatHoldChallenge
    private(set) var extraAnomalies: [Anomaly] = []
    private(set) var rejections: [Rejection] = []
    private var window = SquatPoseWindow()
    private var stillness = PhoneStillnessMonitor()
    private var phoneHandheldReported = false
    private var movingCueShown = false
    private var torsoBendCount = 0

    var progress: VerifierProgress { engine.progress }
    var calibration: PoseCalibration? { engine.core.calibration }

    /// `challenge = .none` conserva el comportamiento sin desafío (cableado heredado y fixtures simples).
    init(spec: VerificationSpec, challenge: SquatHoldChallenge = .none) {
        self.spec = spec
        self.challenge = challenge
        engine = PoseRepEngine(target: spec.target, readyHint: PoseCopy.squatHint,
                               enter: PoseThresholds.squatEnter, exit: PoseThresholds.squatExit)
    }

    init(target: Int? = nil, demo: Bool = false, challenge: SquatHoldChallenge = .none) {
        self.init(spec: .standard(for: .sentadilla, target: target, demo: demo), challenge: challenge)
    }

    mutating func start(at t: Double) {
        engine.start(at: t)
        challenge = SquatHoldChallenge(repNumber: challenge.repNumber)
        extraAnomalies = []
        rejections = []
        window = SquatPoseWindow()
        stillness = PhoneStillnessMonitor()
        phoneHandheldReported = false
        movingCueShown = false
        torsoBendCount = 0
    }

    mutating func ingest(_ sample: PoseSample, at t: Double) -> [VerifierEvent] {
        var w = window
        var rejection: Rejection?
        let armed = challenge.isArmed(nextRep: engine.reps.count + 1)
        var events = engine.ingest(sample, at: t, signal: { frame, cal, inRep in
            guard let hip = frame.hip, cal.h0 > 0 else { return nil }
            let descent = (cal.hipY0 - hip.y) / cal.h0
            if inRep {
                w.observe(frame, cal, descent: descent, at: t)
            } else {
                w = SquatPoseWindow()
            }
            return descent
        }, veto: { _ in
            rejection = Self.evaluate(w, armed: armed)
            return rejection == nil ? nil : []
        })
        window = engine.reps.inRep ? w : SquatPoseWindow()
        let counted = events.contains { event in
            if case .rep = event { return true }
            return false
        }
        if counted, armed { challenge.pass() }
        if let rejection { handle(rejection, at: t, &events) }
        announceChallengeIfNeeded(&events)
        return events
    }

    /// deviceMotion del teléfono (solo en el modo apoyado con `SupportedSquatSource`).
    mutating func ingest(motion m: MotionSample, at t: Double) -> [VerifierEvent] {
        let moving = stillness.ingest(m, at: t)
        guard moving else {
            movingCueShown = false
            return []
        }
        if engine.reps.inRep {
            window.phoneMoved = true
        } else if !movingCueShown, engine.core.isReady {
            movingCueShown = true
            return [.cue(Cue(text: PoseCopy.leavePhone, symbol: "iphone"))]
        }
        return []
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        engine.outcome(kind: kind, at: t, reason: reason, extra: extraAnomalies)
    }

    /// Reglas del fondo de la rep (puras).
    static func evaluate(_ w: SquatPoseWindow, armed: Bool) -> Rejection? {
        if w.phoneMoved { return .phoneHandheld }
        if w.ankleMoveMax > PoseThresholds.squatAnkleMaxMove { return .feetMoved }
        if let thigh = w.thighShortAtPeak, thigh < PoseThresholds.squatThighMinRatio * w.peakDescent { return .kneesStraight }
        if let torso = w.torsoShortAtPeak,
           torso > PoseThresholds.squatTorsoMaxFoldRatio * w.peakDescent + PoseThresholds.squatTorsoFoldSlack {
            return .torsoBend
        }
        if armed, w.holdBest < SquatHoldChallenge.requiredSeconds { return .holdMissed }
        return nil
    }

    private mutating func handle(_ rejection: Rejection, at t: Double, _ events: inout [VerifierEvent]) {
        rejections.append(rejection)
        switch rejection {
        case .phoneHandheld:
            if !phoneHandheldReported {
                phoneHandheldReported = true
                record(Anomaly(kind: PoseAnomaly.phoneHandheld, severity: .hard, at: t,
                               detail: "El teléfono se movió mientras contaba: debía estar apoyado"), &events)
            }
            events.append(.cue(Cue(text: PoseCopy.leavePhone, symbol: "iphone")))
        case .feetMoved:
            events.append(.cue(Cue(text: PoseCopy.stayInPlace, symbol: "figure.stand")))
        case .kneesStraight:
            events.append(.cue(Cue(text: PoseCopy.bendKnees, symbol: "figure.cross.training")))
        case .torsoBend:
            torsoBendCount += 1
            if torsoBendCount <= PoseThresholds.squatTorsoBendMaxRecorded {
                record(Anomaly(kind: PoseAnomaly.torsoBend, severity: .soft, at: t,
                               detail: "Se inclinó de cintura sin doblar las rodillas"), &events)
            }
            events.append(.cue(Cue(text: PoseCopy.bendKnees, symbol: "figure.cross.training")))
        case .holdMissed:
            if let a = challenge.fail(at: t) { record(a, &events) }
        }
    }

    private mutating func announceChallengeIfNeeded(_ events: inout [VerifierEvent]) {
        guard engine.core.isReady, engine.reps.count < engine.progress.target,
              let cue = challenge.announcement(nextRep: engine.reps.count + 1) else { return }
        events.append(.cue(cue))
    }

    private mutating func record(_ a: Anomaly, _ events: inout [VerifierEvent]) {
        extraAnomalies.append(a)
        events.append(.anomaly(a))
    }
}

/// Muestra combinada del modo apoyado: pose de la cámara frontal + deviceMotion del teléfono.
nonisolated enum SupportedSquatSample: Sendable, Codable, Hashable, TimedSample {
    case pose(PoseSample)
    case motion(MotionSample)

    var t: Double {
        switch self {
        case .pose(let p): p.t
        case .motion(let m): m.t
        }
    }
}

/// Sentadilla "Apoyado frente a mí": `SquatVerifier` endurecido + teléfono inmóvil por deviceMotion.
nonisolated struct SupportedSquatVerifier: ActivityVerifier {
    typealias Sample = SupportedSquatSample

    private(set) var inner: SquatVerifier

    var kind: ActivityKind { inner.kind }
    var spec: VerificationSpec { inner.spec }
    var progress: VerifierProgress { inner.progress }
    var challenge: SquatHoldChallenge { inner.challenge }

    init(spec: VerificationSpec, challenge: SquatHoldChallenge = .none) {
        inner = SquatVerifier(spec: spec, challenge: challenge)
    }

    mutating func start(at t: Double) { inner.start(at: t) }

    mutating func ingest(_ sample: SupportedSquatSample, at t: Double) -> [VerifierEvent] {
        switch sample {
        case .pose(let p): inner.ingest(p, at: t)
        case .motion(let m): inner.ingest(motion: m, at: t)
        }
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        inner.finish(at: t, reason: reason)
    }
}

/// Fixtures del modo apoyado para el replay del simulador: sentadillas con la pausa del desafío
/// (pose a 30 fps) + teléfono quieto sobre la mesa (deviceMotion a 50 Hz).
nonisolated enum SupportedSquatFixtures {
    static let poseFps = 30.0
    static let motionHz = 50.0
    static let leadInSeconds = 2.0
    static let trailSeconds = 1.5

    static func replay(target: Int, challengeRep: Int, seed: UInt64 = 5) -> [SupportedSquatSample] {
        var rng = FixtureRandom(seed: seed)
        typealias S = FixtureSynth.Skeleton
        let depth = 0.18 * S.height
        var reps: [(start: Double, down: Double, hold: Double, up: Double)] = []
        var cursor = leadInSeconds
        for i in 0..<max(0, target) {
            let down = 1.0 + rng.symmetric(0.15)
            let hold = (i + 1) == challengeRep ? 2.2 : 0.2
            let up = 1.0 + rng.symmetric(0.15)
            reps.append((cursor, down, hold, up))
            cursor += down + hold + up + 0.7 + rng.symmetric(0.2)
        }
        let total = cursor + trailSeconds
        var out: [SupportedSquatSample] = []
        let frames = Int((total * poseFps).rounded(.up))
        for i in 0...frames {
            let t = Double(i) / poseFps
            var x = 0.0
            if let r = reps.last(where: { $0.start <= t }) {
                let local = t - r.start
                if local < r.down {
                    x = HandheldSquatSynth.minJerk(local / r.down)
                } else if local < r.down + r.hold {
                    x = 1
                } else if local < r.down + r.hold + r.up {
                    x = 1 - HandheldSquatSynth.minJerk((local - r.down - r.hold) / r.up)
                }
            }
            let d = depth * x
            let cx = S.centerX
            func joint(_ px: Double, _ py: Double) -> JointPoint {
                JointPoint(x: px + rng.symmetric(0.002), y: py + rng.symmetric(0.002), confidence: 0.9)
            }
            let knee = S.kneeHalfWidth + d * 0.3
            let joints: [JointKey: JointPoint] = [
                .nose: joint(cx, S.noseY - d), .neck: joint(cx, S.neckY - d),
                .leftShoulder: joint(cx - S.shoulderHalfWidth, S.shoulderY - d),
                .rightShoulder: joint(cx + S.shoulderHalfWidth, S.shoulderY - d),
                .root: joint(cx, S.hipY - d), .leftHip: joint(cx - S.hipHalfWidth, S.hipY - d),
                .rightHip: joint(cx + S.hipHalfWidth, S.hipY - d),
                .leftKnee: joint(cx - knee, S.kneeY - d * 0.45), .rightKnee: joint(cx + knee, S.kneeY - d * 0.45),
                .leftAnkle: joint(cx - S.ankleHalfWidth, S.ankleY), .rightAnkle: joint(cx + S.ankleHalfWidth, S.ankleY),
            ]
            out.append(.pose(PoseSample(t: t, joints: joints, fps: poseFps)))
        }
        let motionFrames = Int((total * motionHz).rounded(.up))
        for i in 0...motionFrames {
            let t = Double(i) / motionHz
            out.append(.motion(MotionSample(
                t: t,
                userAccel: SIMD3(rng.symmetric(0.004), rng.symmetric(0.004), rng.symmetric(0.004)),
                gravity: SIMD3(0, -0.98, -0.2),
                rotationRate: SIMD3(rng.symmetric(0.01), rng.symmetric(0.01), rng.symmetric(0.01)))))
        }
        return out.sorted { $0.t < $1.t }
    }
}

// MARK: - A1 Extensión lumbar de pie

/// Señal normalizada (1 = umbral): hombros que se desplazan respecto de la cadera (vista lateral)
/// o cuello que sube con la cadera quieta (vista frontal); la rep termina al volver.
nonisolated struct ExtensionVerifier: ActivityVerifier {
    typealias Sample = PoseSample

    let kind: ActivityKind = .extensionLumbar
    let spec: VerificationSpec
    private var engine: PoseRepEngine

    var progress: VerifierProgress { engine.progress }
    var calibration: PoseCalibration? { engine.core.calibration }

    init(spec: VerificationSpec) {
        self.spec = spec
        engine = PoseRepEngine(target: spec.target, readyHint: PoseCopy.extensionHint,
                               enter: 1.0, exit: PoseThresholds.extensionExit)
    }

    init(target: Int? = nil, demo: Bool = false) {
        self.init(spec: .standard(for: .extensionLumbar, target: target, demo: demo))
    }

    mutating func start(at t: Double) { engine.start(at: t) }

    mutating func ingest(_ sample: PoseSample, at t: Double) -> [VerifierEvent] {
        engine.ingest(sample, at: t) { frame, cal, inRep in
            guard let hip = frame.hip, cal.h0 > 0 else { return nil }
            let hipStill = abs(hip.y - cal.hipY0) <= PoseThresholds.extensionHipStill * cal.h0
            // La extensión parte con la cadera quieta (si la cadera baja es otra cosa: sentadilla, bisagra).
            if !inRep, !hipStill { return 0 }
            var score = 0.0
            if let shoulders = frame.shoulders, let dx0 = cal.shoulderDx0 {
                let dx = (shoulders.x - hip.x) - dx0
                score = max(score, abs(dx) / PoseThresholds.extensionShoulderShift)
            }
            if let neck = frame.neck {
                let rise = (neck.y - cal.neckY0) / cal.h0
                score = max(score, rise / PoseThresholds.extensionNeckRise)
            }
            return score
        }
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        engine.outcome(kind: kind, at: t, reason: reason)
    }
}
