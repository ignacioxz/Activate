import Foundation

// Cableado de A4 "Pararse y sentarse": `SitToStandVerifier` ← la MISMA fuente en vivo de la sentadilla en
// las manos (`HandheldSquatSource`: ARKit cara + mundo, altímetro y podómetro), con cada
// `HandheldSquatSample` traducido a `SitStandSample`. El teléfono va en las dos manos frente al pecho y la
// imagen de la cámara nunca se muestra; no hay modo "Apoyado". En simulador (y con `replay`) se reproduce
// `SitStandSynth.completing`, que sigue el desafío de la sesión, por el mismo verificador → nivel `simulated`.

@MainActor
enum SitStandWiring {
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

    /// Registra el builder de `.pararseSentarse` (el mismo que entrega `VerifierWiring.builder`).
    static func register(hub: SensorHub, store: AppStore) {
        ActivityRunnerFactory.register(.pararseSentarse, builder(hub: hub, store: store))
    }

    /// Builder expuesto para tests. `seed` nil = una semilla por sesión (elige el desafío).
    static func builder(hub: SensorHub?, store: AppStore, seed: UInt64? = nil,
                        speed: Double = replaySpeed) -> ActivityRunnerFactory.Builder {
        { assignment, demo, replay in
            let spec = VerificationSpec.standard(for: .pararseSentarse, target: assignment.target, demo: demo)
            let verifier = SitToStandVerifier(spec: spec, kind: .pararseSentarse,
                                              seed: seed ?? UInt64.random(in: .min ... .max))
            if replay || forcesReplay {
                let source = ReplaySource(samples: SitStandSynth.completing(verifier), speed: speed)
                return ActivityRunner(assignment: assignment, verifier: verifier, source: source)
            }
            return ActivityRunner(assignment: assignment, verifier: verifier, source: HandheldSitStandSource(hub: hub))
        }
    }
}

// MARK: - Fuente en vivo

/// `SampleSource` de pararse y sentarse: arranca una `HandheldSquatSource` (su propia ARSession de cara +
/// mundo, más CoreMotion del `SensorHub`) y traduce cada muestra. El nivel es el de esa fuente: `.live` con
/// seguimiento del mundo sostenido, `.fallback` si el equipo no lo soporta o se perdió la mayor parte de la serie.
final class HandheldSitStandSource: SampleSource {
    typealias Sample = SitStandSample

    let handheld: HandheldSquatSource

    private var continuation: AsyncStream<SitStandSample>.Continuation?
    private var forwarder: Task<Void, Never>?
    private var generation = 0

    init(hub: SensorHub?) {
        handheld = HandheldSquatSource(hub: hub)
    }

    var level: SourceLevel { handheld.level }

    func start() throws -> AsyncStream<SitStandSample> {
        stop()
        let inner = try handheld.start()
        let (stream, continuation) = AsyncStream.makeStream(of: SitStandSample.self,
                                                            bufferingPolicy: .bufferingNewest(HandheldSquatSource.bufferedSamples))
        self.continuation = continuation
        generation += 1
        let gen = generation
        forwarder = Task.detached {
            for await sample in inner { continuation.yield(SitStandSample(handheld: sample)) }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.generation == gen { self.stop() }
            }
        }
        return stream
    }

    func stop() {
        guard continuation != nil || forwarder != nil else { return }
        generation += 1
        forwarder?.cancel()
        forwarder = nil
        handheld.stop()
        let pending = continuation
        continuation = nil
        pending?.finish()
    }
}

// MARK: - Traducción de muestras

nonisolated extension SitStandSample {
    /// Una muestra por `ARFrame` de la sentadilla en las manos: mismos campos uno a uno (posición y actitud
    /// del teléfono, cara en el mundo y en el espacio del teléfono, energía de blendShapes, seguimiento del
    /// mundo, altímetro, podómetro y relieve TrueDepth). `userAccelRMS`, `verticalAccel` y `headPitchDeg`
    /// no los usa este verificador.
    init(handheld s: HandheldSquatSample) {
        self.init(t: s.t,
                  phonePos: s.phonePos,
                  phonePitchDeg: s.phonePitchDeg,
                  phoneRollDeg: s.phoneRollDeg,
                  faceTracked: s.faceTracked,
                  facePos: s.facePos,
                  faceInPhone: s.faceInPhone,
                  shapeEnergy: s.shapeEnergy,
                  worldTrackingNormal: s.worldTrackingNormal,
                  altitude: s.altitude,
                  steps: s.steps,
                  faceRelief: s.faceRelief)
    }
}
