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

    // MARK: Builders

    @MainActor
    @Test func cadaBuilderEntregaUnRunnerRealQueReproduceComoSimulado() async {
        let store = AppStore(inMemory: true)
        let hub = SensorHub()
        for kind in [ActivityKind.pasos, .sentadilla, .extensionLumbar, .cuello, .ojos] {
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
