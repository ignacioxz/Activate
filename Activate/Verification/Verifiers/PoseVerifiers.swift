import Foundation

// Dueño: agente "pose". Máquinas de estado puras para las actividades de cámara de cuerpo
// (A3 sentadilla parcial, A1 extensión lumbar de pie). Sin imports de Vision/AVFoundation:
// consumen `PoseSample` (Vision ya convertido en `CameraPoseSource`) y corren igual con fixtures.

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
}

/// Nombres de anomalía que producen estos verificadores.
nonisolated enum PoseAnomaly {
    static let lowFps = "lowFps"
    static let staticImage = "static"
    static let tooRegular = "tooRegular"
    static let phoneMoved = "phoneMoved"
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
        if lh != nil, seen(.leftKnee) != nil, let a = seen(.leftAnkle) { ankles.append(a.y) }
        if rh != nil, seen(.rightKnee) != nil, let a = seen(.rightAnkle) { ankles.append(a.y) }
        ankleY = ankles.isEmpty ? nil : ankles.reduce(0, +) / Double(ankles.count)

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
    var shoulderDx0: Double?
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
        mutating func reset() { self = CalibrationWindow() }
        mutating func add(_ f: PoseFrame) {
            guard let hip = f.hip, let neck = f.neck, let height = f.height else { return }
            n += 1
            hipX += hip.x; hipY += hip.y; neckY += neck.y; h += height
            if let s = f.shoulders { nShoulders += 1; shoulderDx += s.x - hip.x }
        }
        var calibration: PoseCalibration? {
            guard n > 0 else { return nil }
            let d = Double(n)
            return PoseCalibration(hipX0: hipX / d, hipY0: hipY / d, neckY0: neckY / d, h0: h / d,
                                   shoulderDx0: nShoulders > 0 ? shoulderDx / Double(nShoulders) : nil)
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
            if let from = pendingJumpFrom {
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

    /// `signal(frame, calibration)` devuelve la señal cruda del ejercicio (nil = no medible en este frame).
    mutating func ingest(_ sample: PoseSample, at t: Double,
                         signal: (PoseFrame, PoseCalibration, Bool) -> Double?) -> [VerifierEvent] {
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

    func outcome(kind: ActivityKind, at t: Double, reason: FinishReason) -> ActivityOutcome {
        let all = (core.anomalies + repAnomalies).sorted { $0.at < $1.at }
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

// MARK: - A3 Sentadilla parcial

/// Señal = descenso vertical de la cadera normalizado por la estatura en el frame.
/// Media sentadilla (descenso máximo < `squatEnter`) no cuenta.
nonisolated struct SquatVerifier: ActivityVerifier {
    typealias Sample = PoseSample

    let kind: ActivityKind = .sentadilla
    let spec: VerificationSpec
    private var engine: PoseRepEngine

    var progress: VerifierProgress { engine.progress }
    var calibration: PoseCalibration? { engine.core.calibration }

    init(spec: VerificationSpec) {
        self.spec = spec
        engine = PoseRepEngine(target: spec.target, readyHint: PoseCopy.squatHint,
                               enter: PoseThresholds.squatEnter, exit: PoseThresholds.squatExit)
    }

    init(target: Int? = nil, demo: Bool = false) {
        self.init(spec: .standard(for: .sentadilla, target: target, demo: demo))
    }

    mutating func start(at t: Double) { engine.start(at: t) }

    mutating func ingest(_ sample: PoseSample, at t: Double) -> [VerifierEvent] {
        engine.ingest(sample, at: t) { frame, cal, _ in
            guard let hip = frame.hip, cal.h0 > 0 else { return nil }
            return (cal.hipY0 - hip.y) / cal.h0
        }
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        engine.outcome(kind: kind, at: t, reason: reason)
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
