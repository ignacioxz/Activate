import Foundation

// Dueño: agente "steps". Máquina de estados pura de la actividad A2 "Camina" (sin imports de CoreMotion).
//
// El logro se acredita solo con `PedometerSample.steps` (numberOfSteps del coprocesador, no editable por
// el usuario). Entre callbacks (~3 s) la barra avanza de forma predictiva con la cadencia, sin tocar `count`.
//
// Tres gates baratos, evaluados al terminar; `suspicious` (anomalía hard) solo si fallan 2 de 3:
//   1. fracción de tiempo con walking/running y confianza ≥ media (tras 5 s de gracia) ≥ 0,6
//   2. cadencia media mientras suben pasos entre 0,8 y 3,0 pasos/s (la marcha corta con dolor es válida)
//   3. RMS de |userAccel| en ventanas de 2 s ≤ 0,7 g (se toleran picos aislados: guardar el teléfono)
// Además: `stationary` con confianza alta > 10 s mientras suben los pasos = hard de inmediato.

nonisolated struct PedometerVerifier: ActivityVerifier {
    typealias Sample = StepSample

    /// Umbrales iniciales; se calibran en el iPhone.
    nonisolated enum Tuning {
        /// Segundos iniciales sin evaluar la clasificación de actividad (el clasificador tarda en reaccionar).
        static let graceSeconds = 5.0
        /// Confianza mínima de `ActivitySample` para contar como caminando (0 low, 1 medium, 2 high).
        static let walkingMinConfidence = 1
        static let highConfidence = 2
        static let walkingFractionMin = 0.6
        static let cadenceMin = 0.8
        static let cadenceMax = 3.0
        /// Pasos mínimos para que el gate de cadencia sea evaluable.
        static let cadenceMinSteps = 10
        static let rmsWindowSeconds = 2.0
        /// Tope de RMS de |userAccel| (g) por ventana.
        static let rmsMaxG = 0.7
        /// Ventanas sobre el tope para que falle el gate (≥ 6 s de movimiento violento).
        static let rmsViolationWindowsForFail = 3
        /// Muestras mínimas para cerrar una ventana (evita ventanas con 1-2 muestras).
        static let rmsMinSamplesPerWindow = 10
        /// `stationary` con confianza alta durante más de esto, con pasos subiendo, es hard.
        static let stationaryHardSeconds = 10.0
        static let gatesFailedForSuspicious = 2
        /// Cadencia nominal mientras el podómetro no informa (predicción y ETA).
        static let nominalCadence = 1.5
        /// La predicción no se extiende más allá de esto desde el último callback.
        static let predictiveHorizonSeconds = 5.0
        static let predictiveUpdateInterval = 0.25
        /// Hitos con señal háptica (los dispara la UI al recibir el `.cue`).
        static let milestones = [100, 200]
    }

    nonisolated enum Copy {
        static let start = "Guarde el teléfono. Camine. No lo bloquee."
        static let keepGoing = "Meta lista. Siga un poco más."
        static let calm = "Camine con calma."
        static let done = "Meta cumplida."
        static func milestone(_ n: Int) -> String { "\(n) pasos. Va bien." }
    }

    nonisolated enum AnomalyKind {
        static let stationaryWhileCounting = "stationaryWhileCounting"
        static let walkingFractionLow = "walkingFractionLow"
        static let cadenceOutOfRange = "cadenceOutOfRange"
        static let accelRMSHigh = "accelRMSHigh"
        static let stepGatesFailed = "stepGatesFailed"
    }

    let kind: ActivityKind = .pasos
    let spec: VerificationSpec
    private(set) var progress: VerifierProgress

    // Línea de tiempo
    private var started = false
    private var startT = 0.0
    private var lastT = 0.0

    // Pasos (coprocesador)
    private var steps = 0
    private var lastPedometerT: Double?
    private var lastPedometerSteps = 0
    private var reportedCadence: Double?
    private var steppingSeconds = 0.0
    private var steppingSteps = 0
    private var lastPredictedFraction = 0.0
    private var lastPredictionT = -Double.infinity
    private var completedEmitted = false
    private var keepGoingCued = false
    private var milestonesCued: Set<Int> = []

    // Clasificación de actividad
    private var activitySamples = 0
    private var walkingNow = false
    private var stationaryHighNow = false
    private var walkingSeconds = 0.0
    private var observedSeconds = 0.0
    private var stationaryRunStart: Double?
    private var stepsAtStationaryStart = 0
    private var stationaryHardEmitted = false

    // RMS de |userAccel|
    private var windowStart: Double?
    private var windowSumSq = 0.0
    private var windowCount = 0
    private var rmsWindows = 0
    private var rmsViolations = 0
    private var rmsPeak = 0.0
    private var calmCued = false

    private var anomalies: [Anomaly] = []

    init(spec: VerificationSpec) {
        self.spec = spec
        progress = VerifierProgress(count: 0, target: spec.target, gate: .calibrating, hint: Copy.start)
    }

    // MARK: ActivityVerifier

    mutating func start(at t: Double) {
        started = true
        startT = t
        lastT = t
        progress = VerifierProgress(count: 0, target: spec.target, gate: .ready, hint: Copy.start, elapsed: 0)
    }

    mutating func ingest(_ sample: StepSample, at t: Double) -> [VerifierEvent] {
        guard started else { return [] }
        let t = max(t, lastT)
        advanceClocks(to: t)
        var events: [VerifierEvent] = []
        switch sample {
        case .pedometer(let p): ingestPedometer(p, at: t, into: &events)
        case .motion(let m): ingestMotion(m, at: t, into: &events)
        case .activity(let a): ingestActivity(a, at: t, into: &events)
        }
        lastT = t
        progress.elapsed = t - startT
        checkStationaryWhileCounting(at: t, into: &events)
        checkCompletion(at: t, into: &events)
        return events
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        let t = max(t, lastT)
        if started { advanceClocks(to: t); lastT = t }
        let elapsed = started ? t - startT : 0
        progress.elapsed = elapsed
        closeWindow()

        let walkingFraction: Double? = observedSeconds > 0 ? walkingSeconds / observedSeconds : nil
        let meanCadence: Double? = (steppingSteps >= Tuning.cadenceMinSteps && steppingSeconds > 0) ? Double(steppingSteps) / steppingSeconds : nil

        var failing: [String] = []
        if let f = walkingFraction, f < Tuning.walkingFractionMin {
            failing.append(AnomalyKind.walkingFractionLow)
            anomalies.append(Anomaly(kind: AnomalyKind.walkingFractionLow, severity: .soft, at: elapsed,
                                     detail: "Caminando \(Int((f * 100).rounded())) % del tiempo"))
        }
        if let c = meanCadence, c < Tuning.cadenceMin || c > Tuning.cadenceMax {
            failing.append(AnomalyKind.cadenceOutOfRange)
            anomalies.append(Anomaly(kind: AnomalyKind.cadenceOutOfRange, severity: .soft, at: elapsed,
                                     detail: String(format: "%.2f pasos/s", c)))
        }
        if rmsWindows > 0, rmsViolations >= Tuning.rmsViolationWindowsForFail {
            failing.append(AnomalyKind.accelRMSHigh)
            anomalies.append(Anomaly(kind: AnomalyKind.accelRMSHigh, severity: .soft, at: elapsed,
                                     detail: String(format: "%d ventanas sobre %.1f g, pico %.2f g", rmsViolations, Tuning.rmsMaxG, rmsPeak)))
        }
        if failing.count >= Tuning.gatesFailedForSuspicious {
            anomalies.append(Anomaly(kind: AnomalyKind.stepGatesFailed, severity: .hard, at: elapsed,
                                     detail: failing.joined(separator: ", ")))
        }

        let reachedTarget = steps >= spec.target && elapsed >= spec.minDurationSeconds
        let completed = reachedTarget && reason != .skipped
        progress.hint = completed ? Copy.done : progress.hint
        return ActivityOutcome(
            kind: kind,
            target: spec.target,
            achieved: steps,
            completed: completed,
            durationSeconds: elapsed,
            metrics: .steps(count: steps, meanCadence: meanCadence, walkingFraction: walkingFraction, rmsPeak: rmsWindows > 0 ? rmsPeak : nil),
            anomalies: anomalies,
            reason: reason)
    }

    // MARK: Pasos

    private mutating func ingestPedometer(_ p: PedometerSample, at t: Double, into events: inout [VerifierEvent]) {
        reportedCadence = p.cadence
        let newSteps = max(steps, p.steps)
        let delta = newSteps - lastPedometerSteps
        if let prevT = lastPedometerT, delta > 0 {
            let dt = t - prevT
            if dt > 0 {
                steppingSeconds += dt
                steppingSteps += delta
            }
        }
        lastPedometerT = t
        lastPedometerSteps = newSteps
        if newSteps > steps {
            steps = newSteps
            progress.count = steps
            events.append(.rep(steps))
            for m in Tuning.milestones where steps >= m && m < spec.target && !milestonesCued.contains(m) {
                milestonesCued.insert(m)
                events.append(.cue(Cue(text: Copy.milestone(m), symbol: "figure.walk")))
            }
        }
        lastPredictedFraction = progress.fraction
        lastPredictionT = t
        events.append(.progress(lastPredictedFraction))
    }

    /// Barra predictiva: pasos reales + cadencia × tiempo desde el último callback (acotado).
    private mutating func predictProgress(at t: Double, into events: inout [VerifierEvent]) {
        guard spec.target > 0, steps < spec.target, t - lastPredictionT >= Tuning.predictiveUpdateInterval else { return }
        let since = min(t - (lastPedometerT ?? t), Tuning.predictiveHorizonSeconds)
        let cadence = reportedCadence ?? (steppingSeconds > 0 ? Double(steppingSteps) / steppingSeconds : 0)
        guard since > 0, cadence > 0 else { return }
        let predicted = min(1, (Double(steps) + cadence * since) / Double(spec.target))
        lastPredictionT = t
        if predicted > lastPredictedFraction + 0.005 {
            lastPredictedFraction = predicted
            events.append(.progress(predicted))
        }
    }

    // MARK: Movimiento (RMS de |userAccel| en ventanas de 2 s)

    private mutating func ingestMotion(_ m: MotionSample, at t: Double, into events: inout [VerifierEvent]) {
        if windowStart == nil { windowStart = t }
        if let ws = windowStart, t - ws >= Tuning.rmsWindowSeconds {
            let exceeded = closeWindow()
            windowStart = t
            if exceeded, !calmCued {
                calmCued = true
                events.append(.cue(Cue(text: Copy.calm, symbol: "hand.raised")))
            }
        }
        let a = m.userAccel
        windowSumSq += a.x * a.x + a.y * a.y + a.z * a.z
        windowCount += 1
        predictProgress(at: t, into: &events)
    }

    /// Cierra la ventana actual. Devuelve `true` si superó el tope.
    @discardableResult
    private mutating func closeWindow() -> Bool {
        defer { windowSumSq = 0; windowCount = 0; windowStart = nil }
        guard windowCount >= Tuning.rmsMinSamplesPerWindow else { return false }
        let rms = (windowSumSq / Double(windowCount)).squareRoot()
        rmsWindows += 1
        rmsPeak = max(rmsPeak, rms)
        if rms > Tuning.rmsMaxG {
            rmsViolations += 1
            return true
        }
        return false
    }

    // MARK: Clasificación de actividad

    private mutating func ingestActivity(_ a: ActivitySample, at t: Double, into events: inout [VerifierEvent]) {
        activitySamples += 1
        walkingNow = (a.walking || a.running) && a.confidence >= Tuning.walkingMinConfidence
        let stationaryHigh = a.stationary && !a.walking && !a.running && a.confidence >= Tuning.highConfidence
        if stationaryHigh != stationaryHighNow {
            stationaryHighNow = stationaryHigh
            stationaryRunStart = stationaryHigh ? t : nil
            stepsAtStationaryStart = steps
        }
    }

    /// Acumula tiempo caminando / observado con el estado vigente entre `lastT` y `t`.
    private mutating func advanceClocks(to t: Double) {
        guard activitySamples > 0 else { return }
        let from = max(lastT, startT + Tuning.graceSeconds)
        let dt = t - from
        guard dt > 0 else { return }
        observedSeconds += dt
        if walkingNow { walkingSeconds += dt }
    }

    private mutating func checkStationaryWhileCounting(at t: Double, into events: inout [VerifierEvent]) {
        guard !stationaryHardEmitted, stationaryHighNow, let runStart = stationaryRunStart else { return }
        guard t - runStart > Tuning.stationaryHardSeconds, steps > stepsAtStationaryStart else { return }
        stationaryHardEmitted = true
        let anomaly = Anomaly(kind: AnomalyKind.stationaryWhileCounting, severity: .hard, at: t - startT,
                              detail: "Teléfono quieto \(Int(t - runStart)) s mientras subían los pasos")
        anomalies.append(anomaly)
        events.append(.anomaly(anomaly))
    }

    // MARK: Cierre

    /// `.completed` se emite una sola vez; después se sigue contando hasta `finish`.
    private mutating func checkCompletion(at t: Double, into events: inout [VerifierEvent]) {
        guard !completedEmitted, steps >= spec.target else { return }
        if t - startT >= spec.minDurationSeconds {
            completedEmitted = true
            progress.hint = Copy.done
            events.append(.progress(1))
            events.append(.completed)
        } else if !keepGoingCued {
            keepGoingCued = true
            progress.hint = Copy.keepGoing
            events.append(.cue(Cue(text: Copy.keepGoing, symbol: "figure.walk.motion")))
        }
    }
}
