import Foundation
import Observation

// Dueño: agente "runtime".
//
// `ActivityRunner` es el único puente entre una fuente de muestras (`SampleSource`) y una máquina de
// estados pura (`ActivityVerifier`). Corre en MainActor: itera el `AsyncStream` de la fuente, llama a
// `verifier.ingest(_:at:)` por muestra, publica progreso/cue/eventos para la UI, vigila el tiempo
// máximo con `ContinuousClock`, y al terminar convierte el `ActivityOutcome` en `ActivityResult`
// con el nivel que decide `VerificationPolicy`.
//
// Garantía estructural: `ActivityResult(outcome:level:witness:)` exige un `Verified`, cuyo `init`
// es `fileprivate` aquí. Ningún otro archivo (ni el Coach, ni la UI, ni los tests) puede fabricar un
// resultado a partir de un outcome: todo resultado pasó por un runner con una fuente real o de replay.

// MARK: - Testigo

/// Prueba de que un resultado salió de `ActivityRunner`. Solo este archivo puede crearlo.
nonisolated struct Verified: Sendable {
    fileprivate init() {}
}

extension ActivityResult {
    /// Única vía de `ActivityOutcome` → `ActivityResult`. `skipped` se deriva de `outcome.reason`.
    nonisolated init(outcome: ActivityOutcome, level: VerificationLevel, witness: Verified) {
        _ = witness
        self.init(kind: outcome.kind,
                  target: outcome.target,
                  achieved: outcome.achieved,
                  durationSeconds: outcome.durationSeconds,
                  completed: outcome.completed,
                  level: level,
                  metrics: outcome.metrics,
                  anomalies: outcome.anomalies,
                  skipped: outcome.reason == .skipped)
    }
}

// MARK: - Nivel de la fuente limitado por el verificador

/// Un verificador puede BAJAR (nunca subir) el nivel que declaró la fuente cuando sabe que parte de la
/// serie se midió peor que lo declarado (p. ej. la sentadilla en las manos que contó reps con el respaldo
/// IMU porque la cámara trasera estuvo tapada). El runner lo aplica antes de `VerificationPolicy`.
nonisolated protocol SourceLevelLimiting {
    func limitedSourceLevel(_ declared: SourceLevel) -> SourceLevel
}

// MARK: - ActivityRunner

/// Runner genérico: un verificador (struct) + una fuente de muestras del mismo tipo.
///
/// Ciclo de vida: `start()` → (muestras → `ingest`) → `.completed` | `stop(reason:)` | timeout |
/// fin del stream → `finish` → `outcome`, `level`, `result`. Un runner se usa una sola vez.
///
/// Tiempo: cada muestra que conforma `TimedSample` (o `timeOf`) aporta su propio `t`, así un fixture
/// reproducido a 10× conserva sus tiempos; si no, se usa el `ContinuousClock` del runner. El timeout
/// se detecta por ambos relojes: el `t` de la última muestra y el reloj de pared (fuente muda).
@Observable
@MainActor
final class ActivityRunner<V: ActivityVerifier, S: SampleSource>: ActivityRunning where V.Sample == S.Sample {
    /// Período del latido que actualiza `progress.elapsed` y vigila el timeout entre muestras.
    static var heartbeatMilliseconds: Int { 250 }
    /// Cuántos eventos recientes se conservan para la UI (háptica, depuración).
    static var recentEventsLimit: Int { 64 }

    let assignment: ActivityAssignment
    private(set) var progress: VerifierProgress
    private(set) var cue: Cue? = nil
    private(set) var lastRepAt: Double? = nil
    private(set) var outcome: ActivityOutcome? = nil
    private(set) var level: VerificationLevel? = nil
    private(set) var isRunning = false

    /// Resultado listo para guardar en la sesión (solo cuando hay `outcome`).
    private(set) var result: ActivityResult? = nil
    /// Anomalías vistas en vivo (la lista definitiva viene en `outcome.anomalies`).
    private(set) var anomalies: [Anomaly] = []
    /// Últimos eventos del verificador, del más antiguo al más nuevo.
    private(set) var recentEvents: [VerifierEvent] = []
    /// Fracción 0-1 publicada por eventos `.progress` (actividades por tiempo, p. ej. mirar lejos 20 s).
    private(set) var timedFraction: Double = 0
    /// Segundos desde `start()` según el reloj de pared del runner.
    private(set) var elapsedSeconds: Double = 0
    /// Error al arrancar la fuente (sensor no disponible, permiso denegado, cámara ocupada).
    private(set) var startError: VerificationError? = nil
    /// Cuántas muestras pasaron por el verificador.
    private(set) var sampleCount: Int = 0

    /// Gancho para la UI (tick háptico por rep, sonido al completar). Se llama en MainActor.
    @ObservationIgnored var onEvent: ((VerifierEvent) -> Void)? = nil

    var spec: VerificationSpec { verifier.spec }
    var sourceLevel: SourceLevel { source.level }
    var isFinished: Bool { outcome != nil }

    @ObservationIgnored private var verifier: V
    /// Fuente de muestras. Visible para que el flujo de pausa comparta la misma instancia con la vista
    /// (p. ej. `ScreenSource` de Stroop/respiración, telemetría de depuración de `HandheldBodySource`).
    @ObservationIgnored let source: S
    @ObservationIgnored private let timeOf: ((S.Sample) -> Double)?
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var startInstant: ContinuousClock.Instant? = nil
    @ObservationIgnored private var streamTask: Task<Void, Never>? = nil
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>? = nil
    @ObservationIgnored private var verifierStarted = false
    @ObservationIgnored private var lastSampleT: Double = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Grabación de diagnóstico (solo DEBUG y fuente en vivo).
    @ObservationIgnored private var recording: SampleRecording? = nil
    @ObservationIgnored private var loggedAttempts = 0

    /// - Parameters:
    ///   - assignment: actividad y meta.
    ///   - verifier: máquina de estados ya configurada con su `VerificationSpec`.
    ///   - source: fuente de muestras del mismo tipo que el verificador.
    ///   - timeOf: extrae el `t` de una muestra; por defecto usa `TimedSample` y, si no conforma, el reloj del runner.
    init(assignment: ActivityAssignment, verifier: V, source: S, timeOf: ((S.Sample) -> Double)? = nil) {
        self.assignment = assignment
        self.verifier = verifier
        self.source = source
        self.timeOf = timeOf
        self.progress = verifier.progress
    }

    // MARK: Ciclo de vida

    func start() {
        guard !isRunning, outcome == nil, startInstant == nil else { return }
        startInstant = clock.now
        startVerifierIfNeeded()
        isRunning = true
        startError = nil

        let stream: AsyncStream<S.Sample>
        do {
            stream = try source.start()
        } catch {
            isRunning = false
            startError = (error as? VerificationError) ?? .sensorUnavailable(String(describing: error))
            progress.gate = .blocked(reason: Self.blockedReason(for: startError))
            cue = Cue(text: "No pude usar el sensor.", symbol: "exclamationmark.triangle")
            Diagnostics.log("runner \(assignment.kind.rawValue) no arrancó: \(String(describing: startError))")
            return
        }
        Diagnostics.log("runner \(assignment.kind.rawValue) arranca fuente=\(source.level.rawValue) meta=\(assignment.target)")
        // Toda fuente real (en vivo o de respaldo, p. ej. la sentadilla antes de que el mundo quede estable).
        if source.level != .replay {
            recording = SampleRecording(kindID: assignment.kind.rawValue, target: assignment.target)
        }

        streamTask = Task { [weak self] in
            for await sample in stream {
                guard let self, !Task.isCancelled, self.outcome == nil else { break }
                self.ingest(sample)
            }
            guard let self, !Task.isCancelled else { return }
            self.sourceEnded()
        }

        let clock = self.clock
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .milliseconds(Self.heartbeatMilliseconds))
                guard !Task.isCancelled, let self, self.outcome == nil else { return }
                self.heartbeat()
            }
        }
    }

    func stop(reason: FinishReason) {
        guard outcome == nil else { return }
        startVerifierIfNeeded()
        finish(reason: reason, at: currentT())
    }

    /// Espera a que el runner tenga `outcome` (tests, coordinador).
    func waitUntilFinished() async {
        if outcome != nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    // MARK: Interno

    private func startVerifierIfNeeded() {
        guard !verifierStarted else { return }
        verifierStarted = true
        verifier.start(at: 0)
        syncProgress(at: 0)
    }

    private var wallElapsed: Double {
        guard let startInstant else { return 0 }
        return durationSeconds(startInstant.duration(to: clock.now))
    }

    /// Mejor estimación del "ahora" del verificador: la última muestra o el reloj de pared, lo mayor.
    private func currentT() -> Double {
        max(lastSampleT, wallElapsed)
    }

    private func ingest(_ sample: S.Sample) {
        guard outcome == nil else { return }
        let t = timeOf?(sample) ?? (sample as? any TimedSample)?.t ?? wallElapsed
        lastSampleT = max(lastSampleT, t)
        sampleCount += 1
        recording?.sample(sample, t: t)

        let events = verifier.ingest(sample, at: t)
        syncProgress(at: t)
        if let recording, let attempts = verifier as? any AttemptDiagnosticsProviding, attempts.attemptCount > loggedAttempts {
            for i in loggedAttempts..<attempts.attemptCount { recording.event("intento " + attempts.attemptLine(i), t: t) }
            loggedAttempts = attempts.attemptCount
        }

        var completed = false
        for event in events {
            record(event, at: t)
            if case .completed = event { completed = true }
        }
        if completed {
            finish(reason: .completed, at: t)
        } else if t >= spec.maxDurationSeconds {
            finish(reason: .timeout, at: t)
        }
    }

    private func record(_ event: VerifierEvent, at t: Double) {
        switch event {
        case .rep: lastRepAt = t
        case .progress(let fraction): timedFraction = min(1, max(0, fraction))
        case .gate(let gate): progress.gate = gate
        case .cue(let c): cue = c
        case .anomaly(let a): anomalies.append(a)
        case .completed: break
        }
        if let recording {
            if case .progress = event {} else { recording.event(String(describing: event), t: t) }
        }
        recentEvents.append(event)
        if recentEvents.count > Self.recentEventsLimit {
            recentEvents.removeFirst(recentEvents.count - Self.recentEventsLimit)
        }
        onEvent?(event)
    }

    private func heartbeat() {
        guard outcome == nil else { return }
        let now = currentT()
        elapsedSeconds = wallElapsed
        progress.elapsed = max(progress.elapsed, now)
        if wallElapsed >= spec.maxDurationSeconds {
            finish(reason: .timeout, at: now)
        }
    }

    /// El stream terminó sin `.completed` ni `stop()`: la fuente se agotó (fixture corto, sensor caído).
    private func sourceEnded() {
        guard outcome == nil else { return }
        finish(reason: .timeout, at: currentT())
    }

    private func syncProgress(at t: Double) {
        var p = verifier.progress
        p.elapsed = max(p.elapsed, t)
        progress = p
        elapsedSeconds = wallElapsed
    }

    private func finish(reason: FinishReason, at t: Double) {
        guard outcome == nil else { return }
        isRunning = false
        streamTask?.cancel()
        streamTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if startInstant != nil { source.stop() }

        let out = verifier.finish(at: t, reason: reason)
        let declared = source.level
        // Solo puede bajar `.live` a `.fallback`; `.fallback` y `.replay` quedan como los declaró la fuente.
        let limited = (verifier as? any SourceLevelLimiting)?.limitedSourceLevel(declared) ?? declared
        let effective = declared == .live && limited == .fallback ? .fallback : declared
        let lvl = VerificationPolicy.level(for: out, source: effective, kind: assignment.kind)
        syncProgress(at: t)
        if reason == .timeout, !out.completed {
            cue = Cue(text: "Se acabó el tiempo.", symbol: "clock")
        }
        outcome = out
        level = lvl
        result = ActivityResult(outcome: out, level: lvl, witness: Verified())
        let summary = "fin \(assignment.kind.rawValue) motivo=\(reason) logrado=\(out.achieved)/\(assignment.target) completo=\(out.completed) nivel=\(lvl) muestras=\(sampleCount) anomalías=\(out.anomalies.map { "\($0.kind)" }.joined(separator: ","))"
        Diagnostics.log("runner " + summary)
        recording?.close(summary, t: t)
        recording = nil

        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }

    private static func blockedReason(for error: VerificationError?) -> String {
        switch error {
        case .some(.cameraBusy): "Cámara ocupada"
        case .some(.permissionDenied): "Sin permiso del sensor"
        case .some(.sensorUnavailable), .none: "Sensor no disponible"
        }
    }
}

// MARK: - Resultado con testigo

/// Lo implementan los runners que producen un `ActivityResult` con testigo (`ActivityRunner`, `PlaceholderRunner`).
@MainActor
protocol VerifiedResultProviding: AnyObject {
    var result: ActivityResult? { get }
}

extension ActivityRunner: VerifiedResultProviding {}

extension ActivityRunning {
    /// Resultado listo para la sesión; `nil` hasta que el runner tenga `outcome`.
    /// Es la única vía por la que el flujo de pausa obtiene un `ActivityResult`.
    var verifiedResult: ActivityResult? {
        (self as? any VerifiedResultProviding)?.result
    }
}

/// Segundos de un `Duration` (sin extensión pública para no chocar con otros paquetes).
private func durationSeconds(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
}

// MARK: - Fábrica

/// Fábrica que arma verificador + fuente para una asignación.
///
/// Cableado final (lo hace la integración en `ActivateApp`, registrando un builder por `kind`;
/// este archivo no importa sensores ni verificadores de otros paquetes). Ejemplo:
///
///     ActivityRunnerFactory.register(.sentadilla) { assignment, demo, replay in
///         let spec = VerificationSpec.standard(for: .sentadilla, target: assignment.target, demo: demo)
///         let verifier = HandheldSquatVerifier(spec: spec)
///         if replay {
///             let source = ReplaySource(samples: HandheldSquatSynth.replay(target: spec.target, challengeRep: 0), speed: 1)
///             return ActivityRunner(assignment: assignment, verifier: verifier, source: source)
///         }
///         return ActivityRunner(assignment: assignment, verifier: verifier, source: HandheldBodySource(hub: hub))
///     }
///
/// Por kind (fuente en vivo / fixture de replay):
/// - `.pasos` (A2): `PedometerVerifier` ← `SensorHub` (StepSample: podómetro + movimiento + actividad) / `FixtureSynth.walk(steps:)`.
/// - `.sentadilla` (A3): `HandheldSquatVerifier` ← `HandheldBodySource` (ARKit cara + mundo, en las manos) / `HandheldSquatSynth`.
/// - `.pararseSentarse` (A4): `PocketSitStandVerifier` ← `PocketSitStandSource` (teléfono en el bolsillo:
///   deviceMotion, altímetro, podómetro y proximidad) / `PocketSitStandSynth.completing(_:)`.
/// - `.extensionLumbar` (A1): `HandheldExtensionVerifier` ← la misma `HandheldBodySource` / `HandheldExtensionSynth`.
/// - `.cuello` (A5): `NeckVerifier` (challenge aleatorio con semilla) ← `FaceSource` (FaceSample) / `FixtureSynth.neckSequence(_:)`.
/// - `.ojos` (A9): `EyeRestVerifier` ← la misma `FaceSource` / `FixtureSynth.blinks(count:)` + `gaze(seconds:awayDegrees:)`.
/// - `.respiracion` (A8): `BreathVerifier` ← fuente de pantalla (ScreenSample touchDown/touchUp) / `ReplaySource<ScreenSample>`.
/// - `.stroop` (A10): `StroopVerifier` ← fuente de pantalla (ScreenSample stroopShown/stroopAnswer) / `ReplaySource<ScreenSample>`.
///
/// `replay` se fuerza en Simulator (`#if targetEnvironment(simulator)`) y en tests; el runner marca
/// todo lo reproducido como `simulated`. Ninguna fuente muestra la imagen de la cámara; dos `ARSession` no
/// corren a la vez: el runner hace `stop()` de su fuente al terminar, antes del `start()` del siguiente.
@MainActor
enum ActivityRunnerFactory {
    typealias Builder = @MainActor (_ assignment: ActivityAssignment, _ demo: Bool, _ replay: Bool) -> any ActivityRunning

    /// Builders registrados por tipo de actividad (los inscribe la integración al arrancar la app).
    private(set) static var builders: [ActivityKind: Builder] = [:]

    static func register(_ kind: ActivityKind, _ builder: @escaping Builder) {
        builders[kind] = builder
    }

    static func unregister(_ kind: ActivityKind) {
        builders[kind] = nil
    }

    static func unregisterAll() {
        builders = [:]
    }

    /// `demo` acorta metas; `replay` fuerza fixtures (simulador o tests).
    /// Sin builder registrado devuelve `PlaceholderRunner` (no verifica nada, nivel `simulated`).
    static func make(assignment: ActivityAssignment, demo: Bool, replay: Bool = false) -> any ActivityRunning {
        if let builder = builders[assignment.kind] {
            return builder(assignment, demo, replay)
        }
        return PlaceholderRunner(assignment: assignment)
    }

    /// Atajo para armar un runner de replay con cualquier verificador y una lista de muestras.
    static func replayRunner<V: ActivityVerifier>(assignment: ActivityAssignment, verifier: V, samples: [V.Sample], speed: Double = 1) -> ActivityRunner<V, ReplaySource<V.Sample>> where V.Sample: TimedSample {
        ActivityRunner(assignment: assignment, verifier: verifier, source: ReplaySource(samples: samples, speed: speed))
    }
}

/// Runner provisional que no verifica nada (queda como fallback cuando un kind no tiene builder).
@Observable
final class PlaceholderRunner: ActivityRunning, VerifiedResultProviding {
    let assignment: ActivityAssignment
    var progress: VerifierProgress
    var cue: Cue? = Cue(text: "Verificador en construcción")
    var lastRepAt: Double? = nil
    var outcome: ActivityOutcome? = nil
    var level: VerificationLevel? = nil
    var isRunning = false
    private(set) var result: ActivityResult? = nil

    init(assignment: ActivityAssignment) {
        self.assignment = assignment
        progress = VerifierProgress(target: assignment.target, gate: .blocked(reason: "Sin verificador"))
    }

    func start() { isRunning = true }
    func stop(reason: FinishReason) {
        guard outcome == nil else { return }
        isRunning = false
        let out = ActivityOutcome(kind: assignment.kind, target: assignment.target, achieved: 0, completed: false,
                                  durationSeconds: 0, metrics: .none, anomalies: [], reason: reason)
        outcome = out
        level = .simulated
        result = ActivityResult(outcome: out, level: .simulated, witness: Verified())
    }
}
