import Foundation

// Cableado de A4 "Pararse y sentarse" con el teléfono en el bolsillo delantero del pantalón:
// `PocketSitStandVerifier` ← `PocketSitStandSource` (deviceMotion, altímetro y podómetro del `SensorHub`,
// más el sensor de proximidad). Sin cámara ni cara: va en el bloque de sensores de la caminata, así el orden
// caminata → pararse y sentarse → sentadilla no espera relevo de cámara. En simulador (y con `replay`) se
// reproduce `PocketSitStandSynth.completing`, por el mismo verificador → nivel `simulated`.

@MainActor
enum SitStandWiring {
    /// Velocidad del replay (1 = tiempo real, visible en pantalla).
    nonisolated static let replaySpeed: Double = 1

    /// En simulador no hay deviceMotion ni barómetro reales: siempre replay.
    static var forcesReplay: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Registra el builder de `.pararseSentarse` (el mismo que entrega `VerifierWiring.builder`).
    static func register(hub: SensorHub, store: AppStore) {
        ActivityRunnerFactory.register(.pararseSentarse, builder(hub: hub, store: store))
    }

    /// Builder expuesto para tests. `seed` elige la orientación del teléfono en el replay.
    static func builder(hub: SensorHub?, store: AppStore, seed: UInt64? = nil,
                        speed: Double = replaySpeed) -> ActivityRunnerFactory.Builder {
        { assignment, demo, replay in
            let spec = VerificationSpec.standard(for: .pararseSentarse, target: assignment.target, demo: demo)
            let verifier = PocketSitStandVerifier(spec: spec, kind: .pararseSentarse)
            if replay || forcesReplay {
                let samples = PocketSitStandSynth.completing(verifier, seed: seed ?? UInt64.random(in: .min ... .max))
                return ActivityRunner(assignment: assignment, verifier: verifier, source: ReplaySource(samples: samples, speed: speed))
            }
            return ActivityRunner(assignment: assignment, verifier: verifier, source: PocketSitStandSource(hub: hub))
        }
    }
}
