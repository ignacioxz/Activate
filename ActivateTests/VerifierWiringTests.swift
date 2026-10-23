import Testing
import Foundation
@testable import Activate

/// Cableado de la fábrica: cada fixture de replay lleva a su verificador hasta `.completed`, y cada
/// builder entrega un runner real (no el provisional) con nivel `simulated` cuando reproduce.
struct VerifierWiringTests {
    private func events<V: ActivityVerifier>(_ verifier: inout V, _ samples: [V.Sample]) -> [VerifierEvent] where V.Sample: TimedSample {
        verifier.start(at: 0)
        var out: [VerifierEvent] = []
        for s in samples { out += verifier.ingest(s, at: s.t) }
        return out
    }

    // MARK: Fixtures puras

    @Test(arguments: [false, true])
    func marchaSinteticaCompletaPasos(demo: Bool) {
        let spec = VerificationSpec.standard(for: .pasos, demo: demo)
        var v = PedometerVerifier(spec: spec)
        let ev = events(&v, ReplayFixtures.walk(spec: spec))
        #expect(ev.contains(.completed))
        let outcome = v.finish(at: ReplayFixtures.walk(spec: spec).last?.t ?? 0, reason: .completed)
        #expect(outcome.completed && outcome.achieved >= spec.target)
        #expect(!outcome.anomalies.contains { $0.severity == .hard })
    }

    @Test(arguments: [false, true])
    func sentadillasSinteticasCompletan(demo: Bool) {
        let spec = VerificationSpec.standard(for: .sentadilla, demo: demo)
        var v = SquatVerifier(spec: spec)
        let samples = ReplayFixtures.squats(spec: spec)
        let ev = events(&v, samples)
        #expect(ev.contains(.completed))
        let outcome = v.finish(at: samples.last?.t ?? 0, reason: .completed)
        #expect(outcome.completed && outcome.achieved >= spec.target)
        #expect(!outcome.anomalies.contains { $0.severity == .hard })
    }

    @Test(arguments: [false, true])
    func extensionesSinteticasCompletan(demo: Bool) {
        let spec = VerificationSpec.standard(for: .extensionLumbar, demo: demo)
        var v = ExtensionVerifier(spec: spec)
        let samples = ReplayFixtures.extensions(spec: spec)
        let ev = events(&v, samples)
        #expect(ev.contains(.completed))
        let outcome = v.finish(at: samples.last?.t ?? 0, reason: .completed)
        #expect(outcome.completed && outcome.achieved >= spec.target)
        #expect(!outcome.anomalies.contains { $0.severity == .hard })
    }

    @Test(arguments: [UInt64(1), 7, 42, 2024])
    func cuelloSinteticoSigueElPlanDeConsignas(seed: UInt64) {
        for demo in [false, true] {
            let spec = VerificationSpec.standard(for: .cuello, demo: demo)
            var v = NeckVerifier(spec: spec, seed: seed)
            let samples = ReplayFixtures.neck(plan: v.plan)
            let ev = events(&v, samples)
            #expect(ev.contains(.completed), "semilla \(seed) demo=\(demo)")
            let outcome = v.finish(at: samples.last?.t ?? 0, reason: .completed)
            #expect(outcome.completed && outcome.achieved == spec.target)
            // Movimientos limpios: sin desajustes, saltos ni ejes invertidos.
            #expect(outcome.anomalies.isEmpty, "semilla \(seed) demo=\(demo): \(outcome.anomalies)")
            #expect(samples.last.map { $0.t < spec.maxDurationSeconds } == true)
            #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .cuello) == .full)
        }
    }

    @Test(arguments: [false, true])
    func ojosSinteticosParpadeanHastaLaMeta(demo: Bool) {
        let spec = VerificationSpec.standard(for: .ojos, demo: demo)
        var v = EyeRestVerifier(spec: spec)
        let samples = ReplayFixtures.eyes(verifier: v)
        let ev = events(&v, samples)
        #expect(ev.contains(.completed))
        let outcome = v.finish(at: samples.last?.t ?? 0, reason: .completed)
        #expect(outcome.completed && outcome.achieved >= spec.target)
        if case .eyes(_, _, _, let far) = outcome.metrics { #expect(far == 0) }
        #expect(samples.last.map { $0.t < spec.maxDurationSeconds } == true)
    }

    @Test(arguments: [false, true])
    func pararseYSentarseSinteticoCompleta(demo: Bool) {
        let spec = VerificationSpec.standard(for: .pararseSentarse, demo: demo)
        #expect(spec.target == (demo ? 4 : 8))
        var v = SitToStandVerifier(spec: spec, kind: .pararseSentarse, seed: 5)
        let samples = SitStandSynth.completing(v)
        let ev = events(&v, samples)
        #expect(ev.contains(.completed))
        let outcome = v.finish(at: samples.last?.t ?? 0, reason: .completed)
        #expect(outcome.kind == .pararseSentarse)
        #expect(outcome.completed && outcome.achieved >= spec.target)
        #expect(!outcome.anomalies.contains { $0.severity == .hard })
        #expect(samples.last.map { $0.t < spec.maxDurationSeconds } == true)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .pararseSentarse) == .full)
    }

    /// La fuente en vivo es la de la sentadilla en las manos: cada campo pasa uno a uno.
    @Test func muestraDeLaSentadillaEnLasManosSeTraduceUnoAUno() {
        let handheld = HandheldSquatSample(t: 1.5, phonePos: SIMD3(0.1, 1.2, -0.3), phonePitchDeg: 12, phoneRollDeg: -3,
                                           faceTracked: true, facePos: SIMD3(0.1, 1.5, -0.1), faceInPhone: SIMD3(0, 0.05, 0.35),
                                           shapeEnergy: 0.02, worldTrackingNormal: true, altitude: 0.4, userAccelRMS: 0.1,
                                           verticalAccel: 0.2, steps: 3, headPitchDeg: -10, faceRelief: 0.011)
        let expected = SitStandSample(t: 1.5, phonePos: SIMD3(0.1, 1.2, -0.3), phonePitchDeg: 12, phoneRollDeg: -3,
                                      faceTracked: true, facePos: SIMD3(0.1, 1.5, -0.1), faceInPhone: SIMD3(0, 0.05, 0.35),
                                      shapeEnergy: 0.02, worldTrackingNormal: true, altitude: 0.4, steps: 3, faceRelief: 0.011)
        #expect(SitStandSample(handheld: handheld) == expected)
        // Sin altímetro, podómetro ni profundidad quedan nil (no se inventan).
        var bare = handheld
        bare.altitude = nil
        bare.steps = nil
        bare.faceRelief = nil
        let mapped = SitStandSample(handheld: bare)
        #expect(mapped.altitude == nil && mapped.steps == nil && mapped.faceRelief == nil)
    }

    // MARK: Builders

    @MainActor
    @Test func pararseYSentarseUsaLaFuenteEnLasManosSinCamaraEnPantalla() async {
        let store = AppStore(inMemory: true)
        let assignment = Recipes.assignment(.pararseSentarse, demo: true)
        let replay = SitStandWiring.builder(hub: SensorHub(), store: store, seed: 7, speed: .infinity)(assignment, true, true)
        #expect(replay is ActivityRunner<SitToStandVerifier, ReplaySource<SitStandSample>>)
        replay.start()
        for _ in 0..<400 where replay.outcome == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(replay.outcome?.completed == true)
        #expect(replay.outcome?.kind == .pararseSentarse)
        #expect(replay.level == .simulated)
        // En vivo: la ARSession de la sentadilla en las manos (bloque `face`); nunca un preview de cámara ni un
        // modo "Apoyado". La muestra `SitToStandActivityView`, no la vista de sentadilla / extensión.
        let live = SitStandWiring.builder(hub: SensorHub(), store: store, seed: 7)(assignment, true, false)
        if SitStandWiring.forcesReplay {
            #expect(live is ActivityRunner<SitToStandVerifier, ReplaySource<SitStandSample>>)
        } else {
            #expect(live is ActivityRunner<SitToStandVerifier, HandheldSitStandSource>)
        }
        #expect(!live.isHandheldRunner)
        #expect(!HandheldActivityView.handles(.pararseSentarse))
        #expect(ActivityKind.pararseSentarse.sensorBlock == .face)
        #expect(ActivityKind.pararseSentarse.sensorBlock == ActivityKind.sentadilla.sensorBlock)
        #expect(ActivityKind.pararseSentarse.placement == "Teléfono en las dos manos, frente al pecho")
    }

    @MainActor
    @Test func cadaBuilderEntregaUnRunnerRealQueReproduceComoSimulado() async {
        let store = AppStore(inMemory: true)
        let hub = SensorHub()
        for kind in [ActivityKind.pasos, .pararseSentarse, .sentadilla, .extensionLumbar, .cuello, .ojos] {
            let assignment = Recipes.assignment(kind, demo: true)
            let builder = VerifierWiring.builder(for: kind, sensors: hub, store: store, speed: .infinity)
            let runner = builder(assignment, true, true)
            #expect(!(runner is PlaceholderRunner))
            runner.start()
            for _ in 0..<400 where runner.outcome == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(runner.outcome?.completed == true, "\(kind) debe completar en replay")
            #expect(runner.level == .simulated, "\(kind) reproducido es simulated")
            #expect(runner.verifiedResult?.level == .simulated)
        }
    }

    @MainActor
    @Test func stroopYRespiracionCompartenLaFuenteDePantalla() {
        let store = AppStore(inMemory: true)
        let hub = SensorHub()
        for kind in [ActivityKind.stroop, .respiracion] {
            let assignment = Recipes.assignment(kind, demo: true)
            let replay = VerifierWiring.builder(for: kind, sensors: hub, store: store)(assignment, true, true)
            #expect(replay.screenSource != nil)
            #expect(replay.screenSource?.level == .replay)
            #expect(!replay.isHandheldRunner)
            let live = VerifierWiring.builder(for: kind, sensors: hub, store: store)(assignment, true, false)
            #expect(live.screenSource?.level == (VerifierWiring.forcesReplay ? .replay : .live))
        }
    }
}
