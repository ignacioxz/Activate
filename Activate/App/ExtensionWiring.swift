import Foundation

// Dueño: agente "extension". Cableado de A1 extensión lumbar, en las manos:
// `HandheldExtensionVerifier` ← `HandheldBodySource` (la misma `ARSession` de la sentadilla: cara por
// TrueDepth + pose del teléfono con la cámara trasera; nunca se muestra la imagen). En simulador (y con
// `replay`) se reproducen fixtures sintéticas que respetan el desafío de la sesión → nivel `simulated`.

@MainActor
enum ExtensionWiring {
    /// Velocidad del replay (1 = tiempo real, visible en pantalla).
    nonisolated static let replaySpeed: Double = 1

    /// Registra el builder de `.extensionLumbar` (`VerifierWiring` ya delega en este mismo builder).
    /// Llamar después de `VerifierWiring.register`.
    static func register(hub: SensorHub, store: AppStore) {
        ActivityRunnerFactory.register(.extensionLumbar, builder(hub: hub, store: store))
    }

    /// Builder expuesto para tests. `seed` nil = una por sesión.
    static func builder(hub: SensorHub, store: AppStore, seed: UInt64? = nil,
                        speed: Double = replaySpeed) -> ActivityRunnerFactory.Builder {
        { assignment, demo, replay in
            makeRunner(assignment: assignment, demo: demo, replay: replay || SquatWiring.forcesReplay, hub: hub,
                       seed: seed ?? UInt64.random(in: 1...UInt64.max), speed: speed,
                       telemetry: store.data.demo.enabled)
        }
    }

    /// Runner real (verificador + fuente en las manos, o replay de fixtures).
    static func makeRunner(assignment: ActivityAssignment, demo: Bool, replay: Bool, hub: SensorHub?,
                           seed: UInt64, speed: Double = replaySpeed, telemetry: Bool = false) -> any ActivityRunning {
        let spec = VerificationSpec.standard(for: .extensionLumbar, target: assignment.target, demo: demo)
        let challenge = HoldChallenge(seed: seed, target: spec.target, copy: .backExtension)
        let verifier = HandheldExtensionVerifier(spec: spec, challenge: challenge)
        if replay {
            let samples = HandheldExtensionSynth.replay(target: spec.target, challengeRep: challenge.repNumber, seed: seed)
            return ActivityRunner(assignment: assignment, verifier: verifier, source: ReplaySource(samples: samples, speed: speed))
        }
        return ActivityRunner(assignment: assignment, verifier: verifier,
                              source: HandheldBodySource(hub: hub, publishesTelemetry: telemetry))
    }
}
