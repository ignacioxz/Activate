import Testing
import Foundation
import simd
@testable import Activate

// Sentadilla con el teléfono en las manos: muestras sintéticas realistas a 60 Hz (ruido de VIO ±1,5 mm,
// IMU, blendShapes) de `HandheldSquatSynth`. Cada caso de trampa reproduce lo que vería ARKit.

private typealias Synth = HandheldSquatSynth

private func run(_ v: inout HandheldSquatVerifier, _ samples: [HandheldSquatSample]) -> [VerifierEvent] {
    v.start(at: 0)
    var events: [VerifierEvent] = []
    for s in samples { events += v.ingest(s, at: s.t) }
    return events
}

private func finish(_ v: inout HandheldSquatVerifier, _ samples: [HandheldSquatSample], reason: FinishReason = .timeout) -> ActivityOutcome {
    v.finish(at: samples.last?.t ?? 0, reason: reason)
}

private func hardKinds(_ outcome: ActivityOutcome) -> [String] {
    outcome.anomalies.filter { $0.severity == .hard }.map(\.kind)
}

private func anomalies(_ outcome: ActivityOutcome, _ kind: String) -> [Anomaly] {
    outcome.anomalies.filter { $0.kind == kind }
}

struct HandheldSquatTests {
    // MARK: Sentadillas reales

    @Test(arguments: [UInt64(1), 7, 42, 2024])
    func diezSentadillasRealesEnLasManosCuentanConFull(seed: UInt64) {
        let challenge = SquatHoldChallenge(seed: seed, target: 10)
        var v = HandheldSquatVerifier(target: 10, challenge: challenge)
        var options = Synth.Options()
        options.seed = seed
        let samples = Synth.samples(reps: Synth.squatReps(count: 10, holdAtRep: challenge.repNumber), options: options)
        let events = run(&v, samples)
        let outcome = finish(&v, samples, reason: .completed)

        #expect(events.contains(.gate(.ready)))
        #expect(events.contains(.cue(SquatHoldChallenge.cue)))
        #expect(events.contains(.cue(SquatHoldChallenge.doneCue)))
        #expect(events.contains(.rep(10)))
        #expect(events.contains(.completed))
        #expect(outcome.achieved == 10 && outcome.completed)
        #expect(hardKinds(outcome).isEmpty, "seed \(seed): \(outcome.anomalies)")
        #expect(v.challenge.passed)
        #expect(v.mode == .world)
        #expect(v.diagnostics.allSatisfy { $0.rejection == nil }, "\(v.diagnostics.compactMap(\.rejection))")
        if case let .reps(count, ratio, meanRep) = outcome.metrics {
            #expect(count == 10)
            #expect((ratio ?? 0) >= HandheldSquatTuning.enterDescent / HandheldSquatTuning.descentRatioReferenceMeters * 0.95)
            #expect((meanRep ?? 0) >= HandheldSquatTuning.minRepSeconds)
        } else {
            Issue.record("métricas de reps esperadas")
        }
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .full)
    }

    @Test func sentadillaLentaYCortaDeUnOperadorConDolorSiCuenta() {
        // 18-22 cm, 4 s por rep (2 bajando, 2 subiendo), con una pausa corta abajo.
        let depths = [0.19, 0.21, 0.20, 0.22, 0.19]
        let challenge = SquatHoldChallenge(repNumber: 3)
        let reps = depths.enumerated().map { i, d in
            Synth.Rep(depth: d, downSeconds: 2.0 + 0.1 * Double(i % 2), holdSeconds: (i + 1) == 3 ? 2.2 : 0.3,
                      upSeconds: 2.0 - 0.1 * Double(i % 3), restSeconds: 1.0 + 0.2 * Double(i % 2))
        }
        var v = HandheldSquatVerifier(target: 5, challenge: challenge)
        let samples = Synth.samples(reps: reps)
        let events = run(&v, samples)
        let outcome = finish(&v, samples, reason: .completed)

        #expect(events.contains(.completed))
        #expect(outcome.achieved == 5)
        #expect(hardKinds(outcome).isEmpty)
        // La rep se mide desde que el teléfono baja 3 cm hasta que vuelve a 6 cm de la altura de pie.
        #expect(v.repSeconds.allSatisfy { $0 >= 2.5 }, "\(v.repSeconds)")
        #expect((v.minPeakDescent ?? 0) >= HandheldSquatTuning.enterDescent)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .full)
    }

    // MARK: Trampas

    @Test func telefonoBajadoSoloConLosBrazosNoCuentaYEsArmsOnly() {
        var v = HandheldSquatVerifier(target: 10)
        let samples = Synth.samples(reps: Synth.squatReps(count: 5, style: .armsOnly))
        let events = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        let arms = anomalies(outcome, HandheldSquatAnomaly.armsOnly)
        #expect(arms.count == 5)
        #expect(arms.map(\.severity) == [.soft, .soft, .hard, .soft, .soft])
        #expect(events.contains(.cue(Cue(text: HandheldSquatCopy.useLegs, symbol: "figure.cross.training"))))
        #expect(v.diagnostics.allSatisfy { $0.rejection == .armsOnly })
        #expect(v.diagnostics.allSatisfy { ($0.faceDescentAtPeak ?? 1) < 0.05 })
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .suspicious)
    }

    @Test func dosBrazadasNoBastanParaHard() {
        var v = HandheldSquatVerifier(target: 10)
        let samples = Synth.samples(reps: Synth.squatReps(count: 2, style: .armsOnly) + Synth.squatReps(count: 3))
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 3)
        #expect(anomalies(outcome, HandheldSquatAnomaly.armsOnly).map(\.severity) == [.soft, .soft])
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func inclinarseDeCinturaNoCuentaYEsTorsoBend() {
        var v = HandheldSquatVerifier(target: 10)
        let samples = Synth.samples(reps: Synth.squatReps(count: 4, style: .torsoBend))
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        #expect(anomalies(outcome, HandheldSquatAnomaly.torsoBend).count == 4)
        #expect(anomalies(outcome, HandheldSquatAnomaly.armsOnly).isEmpty)
        #expect(v.diagnostics.allSatisfy { $0.rejection == .torsoBend })
        #expect(v.diagnostics.allSatisfy { $0.pitchDelta > HandheldSquatTuning.torsoMaxPitchDelta })
        #expect(v.diagnostics.allSatisfy { ($0.forwardExcess ?? 0) > HandheldSquatTuning.torsoForwardSlack })
    }

    @Test func fotoPegadaAlTelefonoEsStatic() {
        var options = Synth.Options()
        options.shapeEnergy = 0
        var v = HandheldSquatVerifier(target: 10)
        let samples = Synth.samples(reps: Synth.squatReps(count: 6, style: .photo), options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(hardKinds(outcome) == [HandheldSquatAnomaly.staticFace])
        #expect(outcome.achieved == 0)
        #expect(v.diagnostics.allSatisfy { $0.rejection == .notLive })
        #expect(!v.isLive)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .suspicious)
    }

    @Test func videoQueNoSigueLaConsignaDePausaEsHoldChallengeFailed() {
        let challenge = SquatHoldChallenge(repNumber: 4)
        var v = HandheldSquatVerifier(target: 10, challenge: challenge)
        // Diez sentadillas "grabadas": ninguna se queda abajo cuando se pide.
        let samples = Synth.samples(reps: Synth.squatReps(count: 10, holdAtRep: nil))
        let events = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(events.contains(.cue(SquatHoldChallenge.cue)))
        #expect(events.contains(.cue(SquatHoldChallenge.missedCue)))
        #expect(hardKinds(outcome) == [HandheldSquatAnomaly.holdChallengeFailed])
        #expect(outcome.achieved == 8)
        #expect(v.challenge.failures == SquatHoldChallenge.maxFailures)
        #expect(!v.challenge.passed)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .suspicious)
    }

    @Test func fallarElDesafioUnaVezYCumplirloDespuesSiCuenta() {
        let challenge = SquatHoldChallenge(repNumber: 2)
        var v = HandheldSquatVerifier(target: 5, challenge: challenge)
        // Rep 2 sin pausa (falla), la siguiente con pausa (cumple): 5 reps contadas de 6 hechas.
        var reps = Synth.squatReps(count: 6, holdAtRep: 3)
        reps[1].holdSeconds = 0.2
        let samples = Synth.samples(reps: reps)
        _ = run(&v, samples)
        let outcome = finish(&v, samples, reason: .completed)

        #expect(outcome.achieved == 5)
        #expect(v.challenge.failures == 1 && v.challenge.passed)
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func sacudirElTelefonoEsShaking() {
        var options = Synth.Options()
        options.shakeAmplitude = 0.05
        options.trailSeconds = 4
        var v = HandheldSquatVerifier(target: 5)
        let samples = Synth.samples(reps: [], options: options)
        let events = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(hardKinds(outcome) == [HandheldSquatAnomaly.shaking])
        #expect(outcome.achieved == 0)
        #expect(events.contains(.cue(Cue(text: HandheldSquatCopy.noShake, symbol: "iphone.radiowaves.left.and.right"))))
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .suspicious)
    }

    @Test func caminarNoCuenta() {
        var options = Synth.Options()
        options.walkSpeed = 1.2
        options.stepsPerSecond = 1.8
        options.trailSeconds = 10
        var v = HandheldSquatVerifier(target: 5)
        let samples = Synth.samples(reps: [], options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        let walking = anomalies(outcome, HandheldSquatAnomaly.walking)
        #expect(walking.count == 1 && walking.first?.severity == .soft)
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func bajarYCaminarConElTelefonoNoCuenta() {
        // Sentadillas "en movimiento": el teléfono avanza 60 cm durante cada bajada.
        var options = Synth.Options()
        options.walkSpeed = 0.35
        var v = HandheldSquatVerifier(target: 5)
        let samples = Synth.samples(reps: Synth.squatReps(count: 4), options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        #expect(v.diagnostics.allSatisfy { $0.rejection == .moved })
    }

    @Test func mediasSentadillasNoCuentanYPidenBajarMas() {
        let reps = (0..<4).map { _ in Synth.Rep(depth: 0.13) }
        var v = HandheldSquatVerifier(target: 5)
        let samples = Synth.samples(reps: reps)
        let events = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        #expect(events.contains(.cue(Cue(text: HandheldSquatCopy.lower, symbol: "arrow.down"))))
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func ritmoDeMetronomoEsTooRegular() {
        let reps = (0..<8).map { _ in Synth.Rep(depth: 0.23, downSeconds: 1.1, holdSeconds: 0.2, upSeconds: 1.1, restSeconds: 0.8) }
        var options = Synth.Options()
        options.positionNoise = 0.0005
        var v = HandheldSquatVerifier(target: 10)
        let samples = Synth.samples(reps: reps, options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 8)
        #expect(hardKinds(outcome) == [HandheldSquatAnomaly.tooRegular])
    }

    // MARK: Respaldo sin seguimiento del mundo

    @Test func respaldoSinSeguimientoDelMundoCuentaConNivelReducido() {
        var options = Synth.Options()
        options.world = false
        options.leadInSeconds = 4.5
        options.accelBias = 0.015
        var v = HandheldSquatVerifier(target: 6)
        let samples = Synth.samples(reps: Synth.squatReps(count: 6), options: options)
        let events = run(&v, samples)
        let outcome = finish(&v, samples, reason: .completed)

        #expect(v.mode == .inertial)
        #expect(events.contains(.completed))
        #expect(outcome.achieved == 6, "\(v.diagnostics.map { ($0.phoneDescent, $0.rejection as Any) })")
        #expect(v.inertialReps == 6)
        #expect(hardKinds(outcome).isEmpty)
        #expect(anomalies(outcome, HandheldSquatAnomaly.inertialFallback).count == 1)
        let stats = HandheldSquatSourcePolicy.Stats(everNormal: false, normalFrames: 0, countedFrames: samples.count)
        let level = HandheldSquatSourcePolicy.level(worldTrackingSupported: true, stats: stats)
        #expect(level == .fallback)
        #expect(VerificationPolicy.level(for: outcome, source: level, kind: .sentadilla) == .reduced)
    }

    @Test func respaldoTambienRechazaLosBrazos() {
        var options = Synth.Options()
        options.world = false
        options.leadInSeconds = 4.5
        var v = HandheldSquatVerifier(target: 5)
        let samples = Synth.samples(reps: Synth.squatReps(count: 3, style: .armsOnly), options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        #expect(anomalies(outcome, HandheldSquatAnomaly.armsOnly).count == 3)
    }

    @Test func politicaDelNivelDeLaFuente() {
        typealias P = HandheldSquatSourcePolicy
        #expect(P.level(worldTrackingSupported: false, stats: .init(everNormal: true, normalFrames: 600, countedFrames: 600)) == .fallback)
        #expect(P.level(worldTrackingSupported: true, stats: .init(everNormal: true, normalFrames: 590, countedFrames: 600)) == .live)
        #expect(P.level(worldTrackingSupported: true, stats: .init(everNormal: true, normalFrames: 300, countedFrames: 600)) == .fallback)
        #expect(P.level(worldTrackingSupported: true, stats: .init(everNormal: true, normalFrames: 10, countedFrames: 20)) == .live)
    }

    // MARK: Gate

    @Test func caraPerdidaBloqueaYVuelveACalibrar() {
        let challenge = SquatHoldChallenge.none
        var v = HandheldSquatVerifier(target: 5, challenge: challenge)
        var options = Synth.Options()
        options.leadInSeconds = 6
        var samples = Synth.samples(reps: Synth.squatReps(count: 2), options: options)
        for i in samples.indices where samples[i].t >= 2.0 && samples[i].t < 4.0 {
            samples[i].faceTracked = false
        }
        let events = run(&v, samples)

        #expect(events.contains(.gate(.blocked(reason: HandheldSquatCopy.keepFace))))
        #expect(events.filter { $0 == .gate(.ready) }.count == 2)
        #expect(v.progress.count == 2)
        #expect(v.progress.gate == .ready)
    }

    @Test func sinCaraNoCalibra() {
        var v = HandheldSquatVerifier(target: 5)
        var samples = Synth.samples(reps: [], options: Synth.Options())
        for i in samples.indices { samples[i].faceTracked = false }
        let events = run(&v, samples)

        #expect(!events.contains(.gate(.ready)))
        #expect(v.progress.gate == .calibrating)
        #expect(v.progress.hint == HandheldSquatCopy.takePhone)
        #expect(v.reference == nil)
    }

    @Test func telefonoPegadoALaCaraNoCalibra() {
        var v = HandheldSquatVerifier(target: 5)
        var samples = Synth.samples(reps: [], options: Synth.Options())
        for i in samples.indices { samples[i].faceInPhone = SIMD3<Float>(0, 0.05, 0.08) }
        _ = run(&v, samples)

        #expect(v.progress.gate == .calibrating)
        #expect(v.progress.hint == HandheldSquatCopy.tooClose)
    }

    // MARK: Desafío y barómetro

    @Test func desafioDeterministaYDentroDeLaSerie() {
        for seed in [UInt64(1), 2, 3, 99, 12345] {
            let a = SquatHoldChallenge.repNumber(seed: seed, target: 10)
            #expect(a == SquatHoldChallenge.repNumber(seed: seed, target: 10))
            #expect((2...6).contains(a))
            #expect((2...4).contains(SquatHoldChallenge.repNumber(seed: seed, target: 5)))
            #expect(SquatHoldChallenge.repNumber(seed: seed, target: 3) == 2)
        }
        #expect(SquatHoldChallenge.repNumber(seed: 1, target: 1) == 1)
        #expect(!SquatHoldChallenge.none.isEnabled)
        let spread = Set((1...40).map { SquatHoldChallenge.repNumber(seed: UInt64($0), target: 10) })
        #expect(spread.count >= 3)
    }

    @Test func escaleraOAscensorDejaBarometerTrendSoft() {
        var options = Synth.Options()
        options.altitudeTrendPerSecond = 0.25
        options.trailSeconds = 12
        var v = HandheldSquatVerifier(target: 5)
        let samples = Synth.samples(reps: [], options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        let trend = anomalies(outcome, HandheldSquatAnomaly.barometerTrend)
        #expect(trend.count == 1 && trend.first?.severity == .soft)
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func barometroSigueLasRepsSinTendencia() {
        var v = HandheldSquatVerifier(target: 10)
        var options = Synth.Options()
        options.altitudeNoise = 0.02
        let samples = Synth.samples(reps: Synth.squatReps(count: 10), options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(anomalies(outcome, HandheldSquatAnomaly.barometerTrend).isEmpty)
        #expect((v.barometer.correlation ?? 0) > 0.3)
    }

    // MARK: Integración con el runner y el cableado

    @MainActor
    @Test func builderDeReplayCompletaComoSimulado() async {
        let store = AppStore(inMemory: true)
        let builder = SquatWiring.builder(hub: SensorHub(), store: store, seed: 9, speed: .infinity)
        let assignment = Recipes.assignment(.sentadilla, demo: true)
        let runner = builder(assignment, true, true)
        #expect(runner.isHandheldReplay)
        #expect(runner.isHandheldRunner)
        runner.start()
        for _ in 0..<400 where runner.outcome == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(runner.outcome?.completed == true, "la sentadilla debe completar en replay")
        #expect(runner.level == .simulated)
        #expect(runner.verifiedResult?.level == .simulated)
        #expect(runner.verifiedResult?.kind == .sentadilla)
    }

    @MainActor
    @Test func sentadillaYExtensionEnVivoSoloUsanLaFuenteEnLasManos() {
        // Sin modo "Apoyado": la fuente en vivo es la ARSession sin vista (nunca una cámara con preview).
        let squat = SquatWiring.makeRunner(assignment: Recipes.assignment(.sentadilla, demo: true), demo: true,
                                           replay: false, hub: nil, seed: 3)
        let ext = ExtensionWiring.makeRunner(assignment: Recipes.assignment(.extensionLumbar, demo: true), demo: true,
                                             replay: false, hub: nil, seed: 3)
        #expect(squat is ActivityRunner<HandheldSquatVerifier, HandheldBodySource>)
        #expect(ext is ActivityRunner<HandheldExtensionVerifier, HandheldBodySource>)
        #expect(squat.isHandheldRunner && !squat.isHandheldReplay)
        #expect(ext.isHandheldRunner && !ext.isHandheldReplay)
        #expect(squat.handheldTelemetry == nil && ext.handheldTelemetry == nil)
    }

    @MainActor
    @Test func saltarEntregaResultadoConTestigo() {
        let store = AppStore(inMemory: true)
        let builder = SquatWiring.builder(hub: SensorHub(), store: store, seed: 3, speed: 1)
        let runner = builder(Recipes.assignment(.sentadilla, demo: true), true, true)
        runner.start()
        runner.stop(reason: .skipped)
        #expect(runner.outcome?.reason == .skipped)
        #expect(runner.verifiedResult?.skipped == true)
    }

    @Test func colacionLlevaSentadillaDespuesDeLosPasosYRelevoNo() {
        for demo in [false, true] {
            #expect(Recipes.base(.colacion3, demo: demo).kinds.prefix(2) == [.pasos, .sentadilla])
            #expect(!Recipes.base(.relevo60, demo: demo).kinds.contains(.sentadilla))
            #expect(Recipes.base(.campamento5, demo: demo).kinds.contains(.sentadilla))
        }
    }
}
