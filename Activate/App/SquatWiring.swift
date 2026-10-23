import Foundation

// Dueño: agente "squats". Cableado de A3 sentadilla parcial, SOLO en las manos:
// `HandheldSquatVerifier` ← `HandheldBodySource` (ARKit cara + mundo, sin mostrar la cámara).
// El modo "Apoyado" (cámara de cuerpo entero con preview) se retiró: ningún ejercicio muestra la imagen de
// la cámara en el iPhone. En simulador (y con `replay`) se reproducen fixtures sintéticas que respetan el
// desafío de la sesión → nivel `simulated`.

@MainActor
enum SquatWiring {
    /// Velocidad del replay (1 = tiempo real, visible en pantalla).
    nonisolated static let replaySpeed: Double = 1

    /// En simulador no hay ARKit: siempre replay.
    static var forcesReplay: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Registra el builder de `.sentadilla` (`VerifierWiring` ya delega en este mismo builder).
    static func register(hub: SensorHub, store: AppStore) {
        ActivityRunnerFactory.register(.sentadilla, builder(hub: hub, store: store))
    }

    /// Builder expuesto para tests. `seed` nil = una por sesión.
    static func builder(hub: SensorHub, store: AppStore, seed: UInt64? = nil,
                        speed: Double = replaySpeed) -> ActivityRunnerFactory.Builder {
        { assignment, demo, replay in
            makeRunner(assignment: assignment, demo: demo, replay: replay || forcesReplay, hub: hub,
                       seed: seed ?? UInt64.random(in: 1...UInt64.max), speed: speed,
                       telemetry: store.data.demo.enabled)
        }
    }

    /// Runner real (verificador + fuente en las manos, o replay de fixtures).
    static func makeRunner(assignment: ActivityAssignment, demo: Bool, replay: Bool, hub: SensorHub?,
                           seed: UInt64, speed: Double = replaySpeed, telemetry: Bool = false) -> any ActivityRunning {
        let spec = VerificationSpec.standard(for: .sentadilla, target: assignment.target, demo: demo)
        let challenge = HoldChallenge(seed: seed, target: spec.target)
        let verifier = HandheldSquatVerifier(spec: spec, challenge: challenge)
        if replay {
            let samples = HandheldSquatSynth.replay(target: spec.target, challengeRep: challenge.repNumber, seed: seed)
            return ActivityRunner(assignment: assignment, verifier: verifier, source: ReplaySource(samples: samples, speed: speed))
        }
        return ActivityRunner(assignment: assignment, verifier: verifier,
                              source: HandheldBodySource(hub: hub, publishesTelemetry: telemetry))
    }
}

// MARK: - Acceso desde la vista (sentadilla y extensión lumbar en las manos)

extension ActivityRunning {
    /// Última muestra de ARKit (≈ 10 Hz) para la depuración de la demo (solo con la fuente en vivo).
    var handheldTelemetry: HandheldSquatSample? {
        (self as? ActivityRunner<HandheldSquatVerifier, HandheldBodySource>)?.source.telemetry
            ?? (self as? ActivityRunner<HandheldExtensionVerifier, HandheldBodySource>)?.source.telemetry
    }

    /// Runner de un ejercicio en las manos que reproduce fixtures (simulador / tests).
    var isHandheldReplay: Bool {
        self is ActivityRunner<HandheldSquatVerifier, ReplaySource<HandheldSquatSample>>
            || self is ActivityRunner<HandheldExtensionVerifier, ReplaySource<HandheldSquatSample>>
    }

    /// Runner de un ejercicio en las manos (fuente en vivo o replay): lo muestra `HandheldActivityView`.
    var isHandheldRunner: Bool {
        isHandheldReplay
            || self is ActivityRunner<HandheldSquatVerifier, HandheldBodySource>
            || self is ActivityRunner<HandheldExtensionVerifier, HandheldBodySource>
    }
}
