import AVFoundation
import Foundation
import Observation

// Dueño: agente "squats". Cableado de A3 sentadilla parcial con dos modos:
// - "En las manos" (por defecto): `HandheldSquatVerifier` ← `HandheldSquatSource` (ARKit cara + mundo).
// - "Apoyado" (teléfono a ~2 m): `SupportedSquatVerifier` ← `SupportedSquatSource` (cámara + deviceMotion).
// El modo se recuerda en UserDefaults y se puede cambiar en la vista antes de la primera rep: por eso el
// builder entrega un `SquatRunner`, que envuelve un `ActivityRunner` real y lo reemplaza al cambiar de modo
// (soltando la cámara antes de abrir la otra). En simulador (y con `replay`) ambos modos reproducen
// fixtures sintéticas que respetan el desafío de la sesión → nivel `simulated`.

/// Modo de la sentadilla.
nonisolated enum SquatMode: String, CaseIterable, Sendable, Codable, Identifiable {
    case handheld
    case supported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .handheld: "En las manos"
        case .supported: "Apoyado"
        }
    }

    /// Instrucción de 1-2 frases.
    var instructions: String {
        switch self {
        case .handheld: HandheldSquatCopy.instructions
        case .supported: "Apoye el teléfono a 2 metros, con todo el cuerpo en pantalla. Doble las rodillas como si se sentara y vuelva a subir."
        }
    }

    var symbol: String {
        switch self {
        case .handheld: "iphone"
        case .supported: "iphone.gen3.badge.play"
        }
    }
}

@MainActor
enum SquatWiring {
    /// Clave de UserDefaults del modo elegido.
    static let modeDefaultsKey = "activate.squat.mode"
    /// Espera entre soltar una cámara y abrir la otra al cambiar de modo (ARSession ↔ AVCaptureSession).
    static let modeSwitchHandoffSeconds: Double = 1.0
    /// Velocidad del replay (1 = tiempo real, visible en pantalla).
    nonisolated static let replaySpeed: Double = 1

    /// En simulador no hay ARKit ni cámara: siempre replay.
    static var forcesReplay: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Una sola `AVCaptureSession` para el modo apoyado (se reutiliza entre pausas).
    private static var sharedCamera: CameraPoseSource?

    private static func cameraSource() -> CameraPoseSource {
        if let sharedCamera { return sharedCamera }
        let source = CameraPoseSource()
        sharedCamera = source
        return source
    }

    static func storedMode(_ defaults: UserDefaults = .standard) -> SquatMode {
        defaults.string(forKey: modeDefaultsKey).flatMap(SquatMode.init(rawValue:)) ?? .handheld
    }

    static func store(_ mode: SquatMode, _ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeDefaultsKey)
    }

    /// Registra el builder de `.sentadilla`. Llamar DESPUÉS de `VerifierWiring.register` (lo reemplaza).
    static func register(hub: SensorHub, store: AppStore) {
        ActivityRunnerFactory.register(.sentadilla, builder(hub: hub, store: store))
    }

    /// Builder expuesto para tests. `mode` nil = el recordado; `seed` nil = una por sesión.
    static func builder(hub: SensorHub, store: AppStore, mode: SquatMode? = nil, seed: UInt64? = nil,
                        speed: Double = replaySpeed, defaults: UserDefaults = .standard) -> ActivityRunnerFactory.Builder {
        { assignment, demo, replay in
            let useReplay = replay || forcesReplay
            let sessionSeed = seed ?? UInt64.random(in: 1...UInt64.max)
            let telemetry = store.data.demo.enabled
            return SquatRunner(assignment: assignment, mode: mode ?? storedMode(defaults)) { mode in
                makeRunner(mode: mode, assignment: assignment, demo: demo, replay: useReplay, hub: hub,
                           seed: sessionSeed, speed: speed, telemetry: telemetry)
            }
        }
    }

    /// Runner real (verificador + fuente) de un modo.
    static func makeRunner(mode: SquatMode, assignment: ActivityAssignment, demo: Bool, replay: Bool,
                           hub: SensorHub?, seed: UInt64, speed: Double = replaySpeed,
                           telemetry: Bool = false) -> any ActivityRunning {
        let spec = VerificationSpec.standard(for: .sentadilla, target: assignment.target, demo: demo)
        let challenge = SquatHoldChallenge(seed: seed, target: spec.target)
        switch mode {
        case .handheld:
            let verifier = HandheldSquatVerifier(spec: spec, challenge: challenge)
            if replay {
                let samples = HandheldSquatSynth.replay(target: spec.target, challengeRep: challenge.repNumber, seed: seed)
                return ActivityRunner(assignment: assignment, verifier: verifier, source: ReplaySource(samples: samples, speed: speed))
            }
            return ActivityRunner(assignment: assignment, verifier: verifier,
                                  source: HandheldSquatSource(hub: hub, publishesTelemetry: telemetry))
        case .supported:
            let verifier = SupportedSquatVerifier(spec: spec, challenge: challenge)
            if replay {
                let samples = SupportedSquatFixtures.replay(target: spec.target, challengeRep: challenge.repNumber, seed: seed)
                return ActivityRunner(assignment: assignment, verifier: verifier, source: ReplaySource(samples: samples, speed: speed))
            }
            return ActivityRunner(assignment: assignment, verifier: verifier,
                                  source: SupportedSquatSource(camera: cameraSource(), hub: hub))
        }
    }
}

// MARK: - Runner con cambio de modo

/// Envuelve el `ActivityRunner` del modo vigente. Todo lo que publica (progreso, consigna, outcome,
/// nivel y el `ActivityResult` con testigo) es el del runner interno: este tipo no fabrica resultados.
/// Antes de la primera rep se puede cambiar de modo: detiene el interno (suelta la cámara), espera el
/// relevo y arranca uno nuevo del otro modo.
@Observable
final class SquatRunner: ActivityRunning, VerifiedResultProviding {
    typealias Factory = @MainActor (SquatMode) -> any ActivityRunning

    static let switchingHint = "Preparando la cámara…"

    let assignment: ActivityAssignment
    private(set) var mode: SquatMode
    private(set) var inner: any ActivityRunning
    private(set) var isSwitching = false
    /// Cambia con cada runner interno nuevo.
    private(set) var generation = 0

    @ObservationIgnored private let factory: Factory
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var switchTask: Task<Void, Never>?

    init(assignment: ActivityAssignment, mode: SquatMode, factory: @escaping Factory) {
        self.assignment = assignment
        self.mode = mode
        self.factory = factory
        inner = factory(mode)
    }

    // MARK: ActivityRunning (reenvío)

    var progress: VerifierProgress {
        if isSwitching {
            return VerifierProgress(count: 0, target: assignment.target, gate: .calibrating, hint: Self.switchingHint)
        }
        return inner.progress
    }

    var cue: Cue? { isSwitching ? nil : inner.cue }
    var lastRepAt: Double? { inner.lastRepAt }
    var outcome: ActivityOutcome? { inner.outcome }
    var level: VerificationLevel? { inner.level }
    var isRunning: Bool { isSwitching || inner.isRunning }
    var result: ActivityResult? { inner.verifiedResult }

    /// Se puede cambiar de modo mientras no haya reps contadas ni resultado.
    var canSwitchMode: Bool { inner.outcome == nil && inner.progress.count == 0 }

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        if !isSwitching { inner.start() }
    }

    func stop(reason: FinishReason) {
        switchTask?.cancel()
        switchTask = nil
        isSwitching = false
        inner.stop(reason: reason)
    }

    /// Cambia de modo (antes de la primera rep): suelta la cámara, espera el relevo y arranca el otro.
    func switchMode(_ newMode: SquatMode) {
        guard newMode != mode, canSwitchMode else { return }
        let old = inner
        mode = newMode
        old.stop(reason: .userStopped)
        inner = factory(newMode)
        generation += 1
        switchTask?.cancel()
        guard wantsRunning else { return }
        isSwitching = true
        switchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SquatWiring.modeSwitchHandoffSeconds))
            guard let self, !Task.isCancelled, self.isSwitching else { return }
            self.isSwitching = false
            self.inner.start()
        }
    }

    // MARK: Acceso para la vista

    /// Sesión de la cámara frontal para el fondo de la tarjeta (modo apoyado en vivo).
    var captureSession: AVCaptureSession? {
        (inner as? ActivityRunner<SupportedSquatVerifier, SupportedSquatSource>)?.source.captureSession
    }

    /// Última muestra de ARKit (≈ 10 Hz) para la depuración de la demo (modo en las manos en vivo).
    var handheldTelemetry: HandheldSquatSample? {
        (inner as? ActivityRunner<HandheldSquatVerifier, HandheldSquatSource>)?.source.telemetry
    }

    /// El modo reproduce fixtures (simulador / tests).
    var isReplay: Bool {
        (inner as? ActivityRunner<HandheldSquatVerifier, ReplaySource<HandheldSquatSample>>) != nil
            || (inner as? ActivityRunner<SupportedSquatVerifier, ReplaySource<SupportedSquatSample>>) != nil
    }
}

extension ActivityRunning {
    /// Runner de la sentadilla con modos (para que el flujo de pausa muestre `SquatActivityView`).
    var squatRunner: SquatRunner? { self as? SquatRunner }
}
