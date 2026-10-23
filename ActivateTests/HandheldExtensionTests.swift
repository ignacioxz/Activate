import Testing
import Foundation
import simd
@testable import Activate

// Extensión lumbar con el teléfono en las manos: muestras sintéticas a 60 Hz (ruido de VIO ±1,5 mm, cabeceo
// ±0,4°, IMU, blendShapes) de `HandheldExtensionSynth`, que gira de verdad el tronco (o solo las muñecas)
// alrededor del eje X. Cada caso de trampa reproduce lo que vería ARKit.

private typealias Synth = HandheldExtensionSynth
private typealias K = HandheldExtensionTuning

private func run(_ v: inout HandheldExtensionVerifier, _ samples: [HandheldSquatSample]) -> [VerifierEvent] {
    v.start(at: 0)
    var events: [VerifierEvent] = []
    for s in samples { events += v.ingest(s, at: s.t) }
    return events
}

private func finish(_ v: inout HandheldExtensionVerifier, _ samples: [HandheldSquatSample],
                    reason: FinishReason = .timeout) -> ActivityOutcome {
    v.finish(at: samples.last?.t ?? 0, reason: reason)
}

private func hardKinds(_ outcome: ActivityOutcome) -> [String] {
    outcome.anomalies.filter { $0.severity == .hard }.map(\.kind)
}

private func anomalies(_ outcome: ActivityOutcome, _ kind: String) -> [Anomaly] {
    outcome.anomalies.filter { $0.kind == kind }
}

/// Fuente que declara `.live` y entrega muestras sintéticas: prueba que el runner aplica el nivel que limita
/// el verificador de la extensión (en la app solo `HandheldSquatSource` declara `.live`).
@MainActor
private final class LiveDeclaredExtensionReplay: SampleSource {
    typealias Sample = HandheldSquatSample
    let samples: [HandheldSquatSample]
    var level: SourceLevel { .live }

    init(samples: [HandheldSquatSample]) { self.samples = samples }

    func start() throws -> AsyncStream<HandheldSquatSample> {
        let samples = samples
        return AsyncStream { continuation in
            for s in samples { continuation.yield(s) }
            continuation.finish()
        }
    }

    func stop() {}
}

/// Estadística de la fuente tal como la arma `HandheldSquatRelay` (frames con cara desde que el mundo arrancó).
private func sourceStats(_ samples: [HandheldSquatSample]) -> HandheldSquatSourcePolicy.Stats {
    var stats = HandheldSquatSourcePolicy.Stats()
    for s in samples {
        if s.worldTrackingNormal { stats.everNormal = true }
        if stats.everNormal, s.faceTracked {
            stats.countedFrames += 1
            if s.worldTrackingNormal { stats.normalFrames += 1 }
        }
    }
    return stats
}

struct HandheldExtensionTests {
    // MARK: Física de la señal

    @Test func inclinarseHaciaAtrasBajaElCabeceoDeLaFuente() {
        // La fuente en vivo calcula el cabeceo desde la gravedad de CoreMotion. Con el teléfono fijo al pecho,
        // inclinar el tronco 20° hacia atrás lleva el borde superior hacia la persona: la pantalla mira más
        // hacia abajo y el cabeceo ("pantalla hacia arriba > 0") BAJA 20°.
        let upright = HandheldSquatRelay.attitude(gravity: Synth.deviceGravity(backRotationDegrees: 0))
        let back = HandheldSquatRelay.attitude(gravity: Synth.deviceGravity(backRotationDegrees: 20))
        let forward = HandheldSquatRelay.attitude(gravity: Synth.deviceGravity(backRotationDegrees: -20))
        #expect(abs(upright.pitch) < 0.001)
        #expect(abs(back.pitch - -20) < 0.001)
        #expect(abs(forward.pitch - 20) < 0.001)
        // La señal de la rep (referencia − cabeceo) es positiva al ir hacia atrás.
        #expect(AngleMath.delta(upright.pitch, back.pitch) > K.enterTiltDegrees)
        // El sintetizador sigue la misma convención: en el punto más atrás el cabeceo bajó lo inclinado.
        var options = Synth.Options()
        options.pitchNoise = 0
        let samples = Synth.samples(reps: [Synth.Rep(tilt: 20, holdSeconds: 1)], options: options)
        let deepest = samples.map(\.phonePitchDeg).min() ?? 0
        #expect(abs(deepest - (Synth.standingPitch - 20)) < 0.01)
    }

    @Test func enUnaExtensionRealLaCaraAcompanaAlTelefono() {
        // Cuerpo rígido: la cara en el espacio del teléfono casi no cambia y la cara se va hacia atrás.
        var options = Synth.Options()
        options.positionNoise = 0
        options.pitchNoise = 0
        let real = Synth.samples(reps: [Synth.Rep(tilt: 14, holdSeconds: 1)], options: options)
        let wrists = Synth.samples(reps: [Synth.Rep(tilt: 14, holdSeconds: 1, style: .wristsOnly)], options: options)
        let fip0 = real[0].faceInPhone
        let realChange = real.map { simd_length($0.faceInPhone - fip0) }.max() ?? 0
        let wristChange = wrists.map { simd_length($0.faceInPhone - fip0) }.max() ?? 0
        let realBack = real.map { Double($0.facePos.z - real[0].facePos.z) }.max() ?? 0
        let wristBack = wrists.map { Double($0.facePos.z - wrists[0].facePos.z) }.max() ?? 0
        #expect(Double(realChange) < K.faceGeometryMaxChange / 2)
        #expect(Double(wristChange) > K.faceGeometryMaxChange)
        #expect(realBack > 0.08)
        #expect(abs(wristBack) < 0.001)
    }

    // MARK: Extensiones reales

    @Test(arguments: [UInt64(1), 7, 42, 2024])
    func diezExtensionesRealesCuentanConFull(seed: UInt64) {
        let challenge = HoldChallenge(seed: seed, target: 10, copy: .backExtension)
        var v = HandheldExtensionVerifier(target: 10, challenge: challenge)
        var options = Synth.Options()
        options.seed = seed
        let samples = Synth.samples(reps: Synth.extensionReps(count: 10, holdAtRep: challenge.repNumber), options: options)
        let events = run(&v, samples)
        let outcome = finish(&v, samples, reason: .completed)

        #expect(events.contains(.gate(.ready)))
        #expect(events.contains(.cue(HoldChallengeCopy.backExtension.cue)))
        #expect(events.contains(.cue(HoldChallengeCopy.backExtension.doneCue)))
        #expect(events.contains(.rep(10)))
        #expect(events.contains(.completed))
        #expect(outcome.kind == .extensionLumbar)
        #expect(outcome.achieved == 10 && outcome.completed)
        #expect(hardKinds(outcome).isEmpty, "seed \(seed): \(outcome.anomalies)")
        #expect(v.challenge.passed)
        #expect(v.mode == .world)
        #expect(v.diagnostics.allSatisfy { $0.rejection == nil }, "\(v.diagnostics.map { ($0.rejection as Any, $0.geometryChange, $0.directionChange, $0.faceBackward as Any) })")
        #expect(v.diagnostics.allSatisfy { ($0.faceBackward ?? 0) >= K.faceMinBackward })
        #expect(v.diagnostics.allSatisfy { $0.geometryChange < K.faceGeometryMaxChange })
        if case let .reps(count, _, meanRep) = outcome.metrics {
            #expect(count == 10)
            #expect((meanRep ?? 0) >= K.minRepSeconds)
        } else {
            Issue.record("métricas de reps esperadas")
        }
        #expect((v.minPeakTilt ?? 0) >= K.enterTiltDegrees)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .extensionLumbar) == .full)
    }

    @Test func extensionCortaYLentaDeUnOperadorConDolorSiCuenta() {
        // Marco con dolor: 13-15° y 4 s por rep (2 s hacia atrás, 2 s de vuelta); cumple el desafío en la 3ª.
        let tilts = [13.0, 14.5, 13.5, 15.0, 13.0]
        let challenge = HoldChallenge(repNumber: 3, copy: .backExtension)
        let reps = tilts.enumerated().map { i, tilt in
            Synth.Rep(tilt: tilt, backSeconds: 2.0 + 0.1 * Double(i % 2), holdSeconds: (i + 1) == 3 ? 2.2 : 0.3,
                      returnSeconds: 2.0 - 0.1 * Double(i % 3), restSeconds: 1.2 + 0.2 * Double(i % 2))
        }
        var v = HandheldExtensionVerifier(target: 5, challenge: challenge)
        let samples = Synth.samples(reps: reps)
        let events = run(&v, samples)
        let outcome = finish(&v, samples, reason: .completed)

        #expect(events.contains(.completed))
        #expect(outcome.achieved == 5, "\(v.diagnostics.map { ($0.peakTilt, $0.seconds, $0.rejection as Any) })")
        #expect(hardKinds(outcome).isEmpty)
        #expect(v.challenge.passed)
        #expect(v.repSeconds.allSatisfy { $0 >= 2.5 }, "\(v.repSeconds)")
        #expect((v.minPeakTilt ?? 0) >= K.enterTiltDegrees)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .extensionLumbar) == .full)
    }

    @Test func extensionQueNoLlegaALaMetaPideUnPocoMasSinDolor() {
        let reps = (0..<3).map { _ in Synth.Rep(tilt: 9) }
        var v = HandheldExtensionVerifier(target: 5)
        let samples = Synth.samples(reps: reps)
        let events = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        #expect(events.contains(.cue(Cue(text: HandheldExtensionCopy.moreBack, symbol: "arrow.uturn.backward"))))
        #expect(hardKinds(outcome).isEmpty)
    }

    // MARK: Trampas

    @Test func girarSoloLasMunecasNoCuentaYEsWristsOnly() {
        var v = HandheldExtensionVerifier(target: 10)
        let samples = Synth.samples(reps: Synth.extensionReps(count: 5, style: .wristsOnly))
        let events = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        let wrists = anomalies(outcome, HandheldExtensionAnomaly.wristsOnly)
        #expect(wrists.count == 5)
        #expect(wrists.map(\.severity) == [.soft, .soft, .hard, .soft, .soft])
        #expect(events.contains(.cue(Cue(text: HandheldExtensionCopy.wholeTrunk, symbol: "figure.flexibility"))))
        #expect(v.diagnostics.allSatisfy { $0.rejection == .wristsOnly })
        #expect(v.diagnostics.allSatisfy { ($0.faceBackward ?? 1) < K.faceMinBackward })
        #expect(v.diagnostics.allSatisfy { $0.geometryChange > K.faceGeometryMaxChange })
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .extensionLumbar) == .suspicious)
    }

    @Test func munecasConElTelefonoCercaDeLaCaraTambienSeDetectan() {
        // Teléfono a ~25 cm: el giro de muñeca casi no cambia la distancia, pero la cara no se va hacia atrás.
        var options = Synth.Options()
        options.phone = SIMD3(0, 1.38, 0.20)
        var v = HandheldExtensionVerifier(target: 5)
        let samples = Synth.samples(reps: Synth.extensionReps(count: 3, style: .wristsOnly), options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        #expect(v.diagnostics.count == 3)
        #expect(v.diagnostics.allSatisfy { $0.rejection == .wristsOnly })
        #expect(v.diagnostics.allSatisfy { ($0.faceBackward ?? 1) < K.faceMinBackward })
    }

    @Test func dosGirosDeMunecaNoBastanParaHard() {
        var v = HandheldExtensionVerifier(target: 10)
        let samples = Synth.samples(reps: Synth.extensionReps(count: 2, style: .wristsOnly) + Synth.extensionReps(count: 3))
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 3)
        #expect(anomalies(outcome, HandheldExtensionAnomaly.wristsOnly).map(\.severity) == [.soft, .soft])
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func sentadillaNoCuentaComoExtension() {
        // Una sentadilla real inclina la pantalla hacia arriba: ni siquiera abre una rep.
        var v = HandheldExtensionVerifier(target: 5)
        let squats = Synth.samples(reps: Synth.extensionReps(count: 4, style: .squat))
        _ = run(&v, squats)
        #expect(finish(&v, squats).achieved == 0)
        #expect(v.diagnostics.isEmpty)

        // Agacharse girando además el teléfono hacia atrás con las muñecas: el teléfono bajó → notExtension.
        var tilted = HandheldExtensionVerifier(target: 5)
        let samples = Synth.samples(reps: Synth.extensionReps(count: 4, style: .squatTilt))
        let events = run(&tilted, samples)
        let outcome = finish(&tilted, samples)
        #expect(outcome.achieved == 0)
        let notExtension = anomalies(outcome, HandheldExtensionAnomaly.notExtension)
        #expect(notExtension.count == 4 && notExtension.allSatisfy { $0.severity == .soft })
        #expect(tilted.diagnostics.allSatisfy { $0.rejection == .notExtension })
        #expect(tilted.diagnostics.allSatisfy { ($0.phoneDescent ?? 0) > K.maxPhoneDescent })
        #expect(events.contains(.cue(Cue(text: HandheldExtensionCopy.noSquat, symbol: "figure.flexibility"))))
    }

    @Test func inclinarseHaciaAdelanteNoCuenta() {
        var v = HandheldExtensionVerifier(target: 5)
        let samples = Synth.samples(reps: Synth.extensionReps(count: 4, style: .flexion))
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func fotoPegadaAlTelefonoEsStatic() {
        var options = Synth.Options()
        options.shapeEnergy = 0
        var v = HandheldExtensionVerifier(target: 10)
        let samples = Synth.samples(reps: Synth.extensionReps(count: 6, style: .photo), options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(hardKinds(outcome) == [HandheldExtensionAnomaly.staticFace])
        #expect(outcome.achieved == 0)
        #expect(!v.diagnostics.isEmpty)
        #expect(v.diagnostics.allSatisfy { $0.rejection == .notLive })
        #expect(!v.isLive)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .extensionLumbar) == .suspicious)
    }

    @Test func noSeguirElDesafioEsHoldChallengeFailed() {
        let challenge = HoldChallenge(repNumber: 4, copy: .backExtension)
        var v = HandheldExtensionVerifier(target: 10, challenge: challenge)
        // Diez extensiones "grabadas": ninguna se queda atrás cuando se pide.
        let samples = Synth.samples(reps: Synth.extensionReps(count: 10, holdAtRep: nil))
        let events = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(events.contains(.cue(HoldChallengeCopy.backExtension.cue)))
        #expect(events.contains(.cue(HoldChallengeCopy.backExtension.missedCue)))
        #expect(hardKinds(outcome) == [HandheldExtensionAnomaly.holdChallengeFailed])
        #expect(anomalies(outcome, HandheldExtensionAnomaly.holdChallengeFailed).first?.detail == HoldChallengeCopy.backExtension.failureDetail)
        #expect(outcome.achieved == 8)
        #expect(v.challenge.failures == HoldChallenge.maxFailures)
        #expect(!v.challenge.passed)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .extensionLumbar) == .suspicious)
    }

    @Test func elDesafioDeLaExtensionDiceAtrasAunqueLlegueConTextoDeSentadilla() {
        // El builder podría pasar un desafío con el texto por defecto: el verificador lo fuerza a "atrás".
        let v = HandheldExtensionVerifier(target: 5, challenge: HoldChallenge(repNumber: 2))
        #expect(v.challenge.copy == .backExtension)
        #expect(v.challenge.repNumber == 2)
        #expect(HoldChallengeCopy.allCueTexts.contains("Quédese atrás 2 segundos"))
        #expect(HoldChallengeCopy.allCueTexts.contains(SquatHoldChallenge.cue.text))
    }

    @Test func sacudirElTelefonoEsShaking() {
        var options = Synth.Options()
        options.shakeAmplitude = 0.05
        options.trailSeconds = 4
        var v = HandheldExtensionVerifier(target: 5)
        let samples = Synth.samples(reps: [], options: options)
        let events = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(hardKinds(outcome) == [HandheldExtensionAnomaly.shaking])
        #expect(outcome.achieved == 0)
        #expect(events.contains(.cue(Cue(text: HandheldExtensionCopy.noShake, symbol: "iphone.radiowaves.left.and.right"))))
    }

    @Test func caminarNoCuenta() {
        var options = Synth.Options()
        options.walkSpeed = 1.2
        options.stepsPerSecond = 1.8
        options.trailSeconds = 10
        var v = HandheldExtensionVerifier(target: 5)
        let samples = Synth.samples(reps: [], options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        let walking = anomalies(outcome, HandheldExtensionAnomaly.walking)
        #expect(walking.count == 1 && walking.first?.severity == .soft)
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func ritmoDeMetronomoEsTooRegular() {
        let reps = (0..<8).map { _ in Synth.Rep(tilt: 20, backSeconds: 1.1, holdSeconds: 0.3, returnSeconds: 1.1, restSeconds: 0.8) }
        var options = Synth.Options()
        options.positionNoise = 0.0005
        options.pitchNoise = 0.1
        var v = HandheldExtensionVerifier(target: 10)
        let samples = Synth.samples(reps: reps, options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 8)
        #expect(hardKinds(outcome) == [HandheldExtensionAnomaly.tooRegular])
    }

    // MARK: Respaldo sin seguimiento del mundo

    @Test func respaldoSinSeguimientoDelMundoCuentaConNivelReducido() {
        var options = Synth.Options()
        options.world = false
        options.leadInSeconds = 4.5
        var v = HandheldExtensionVerifier(target: 6)
        let samples = Synth.samples(reps: Synth.extensionReps(count: 6), options: options)
        let events = run(&v, samples)
        let outcome = finish(&v, samples, reason: .completed)

        #expect(v.mode == .inertial)
        #expect(events.contains(.completed))
        #expect(outcome.achieved == 6, "\(v.diagnostics.map { ($0.peakTilt, $0.rejection as Any) })")
        #expect(v.inertialReps == 6)
        #expect(hardKinds(outcome).isEmpty)
        #expect(anomalies(outcome, HandheldExtensionAnomaly.inertialFallback).count == 1)
        let stats = HandheldSquatSourcePolicy.Stats(everNormal: false, normalFrames: 0, countedFrames: samples.count)
        let level = HandheldSquatSourcePolicy.level(worldTrackingSupported: true, stats: stats)
        #expect(level == .fallback)
        #expect(VerificationPolicy.level(for: outcome, source: level, kind: .extensionLumbar) == .reduced)
    }

    @Test func repsConElRespaldoBajanElNivelDeLaFuente() {
        var v = HandheldExtensionVerifier(target: 10)
        #expect(v.limitedSourceLevel(.live) == .live)
        var options = Synth.Options()
        options.world = false
        options.leadInSeconds = 4.5
        let samples = Synth.samples(reps: Synth.extensionReps(count: 2), options: options)
        _ = run(&v, samples)
        #expect(v.inertialReps == 2)
        #expect(v.limitedSourceLevel(.live) == .fallback)
        #expect(v.limitedSourceLevel(.replay) == .replay)
        #expect(v.limitedSourceLevel(.fallback) == .fallback)
    }

    @Test func extensionesTapandoLaCamaraSoloEnLasRepsQuedanReduced() {
        // La política es por reps, no por frames: extensiones reales medidas con el respaldo IMU (la cámara
        // trasera tapada justo en cada rep) cuentan, pero el nivel baja a reduced aunque más del 80 % de los
        // frames tuviera el seguimiento del mundo normal y la fuente se declare `.live`.
        var reps: [Synth.Rep] = []
        for i in 0..<5 {
            let k = Double(i % 3)
            let back: Double = 1.1 + 0.1 * Double(i % 2)
            let ret: Double = 1.1 + 0.1 * k
            let rest: Double = 30 + 0.7 * k
            reps.append(Synth.Rep(tilt: 19 + k, backSeconds: back, holdSeconds: 0.3, returnSeconds: ret, restSeconds: rest))
        }
        var options = Synth.Options()
        options.leadInSeconds = 30
        let seen = Synth.samples(reps: reps, options: options)
        options.world = false
        let covered = Synth.samples(reps: reps, options: options)
        // Mismo ruido en las dos series: se tapa desde 2,6 s antes de cada rep hasta 0,2 s después.
        var windows: [ClosedRange<Double>] = []
        var cursor = options.leadInSeconds
        for r in reps {
            let moving: Double = r.backSeconds + r.holdSeconds + r.returnSeconds
            windows.append((cursor - 2.6)...(cursor + moving + 0.2))
            cursor += moving + r.restSeconds
        }
        var samples: [HandheldSquatSample] = []
        for i in seen.indices {
            let t: Double = seen[i].t
            let isCovered: Bool = windows.contains(where: { (w: ClosedRange<Double>) -> Bool in w.contains(t) })
            samples.append(isCovered ? covered[i] : seen[i])
        }

        var v = HandheldExtensionVerifier(target: 5)
        _ = run(&v, samples)
        let outcome = finish(&v, samples, reason: .completed)

        let diag: [String] = v.diagnostics.map { "\($0.mode) \($0.peakTilt) \(String(describing: $0.rejection))" }
        #expect(outcome.achieved == 5, "\(diag)")
        #expect(v.inertialReps == 5)
        #expect(hardKinds(outcome).isEmpty, "\(outcome.anomalies)")
        let stats = sourceStats(samples)
        let fraction = Double(stats.normalFrames) / Double(max(1, stats.countedFrames))
        #expect(fraction >= HandheldSquatSourcePolicy.minWorldFraction, "fracción normal \(fraction)")
        let declared = HandheldSquatSourcePolicy.level(worldTrackingSupported: true, stats: stats)
        #expect(declared == .live)
        #expect(v.limitedSourceLevel(declared) == .fallback)
        let limited: SourceLevel = v.limitedSourceLevel(declared)
        let level: VerificationLevel = VerificationPolicy.level(for: outcome, source: limited, kind: .extensionLumbar)
        #expect(level != .full)
        #expect(level == .reduced)
    }

    @MainActor
    @Test func elRunnerAplicaElNivelLimitadoPorElVerificador() async {
        // Fuente "en vivo" que en realidad entrega extensiones sin seguimiento del mundo: el runner baja a reduced.
        var options = Synth.Options()
        options.world = false
        options.leadInSeconds = 4.5
        let samples = Synth.samples(reps: Synth.extensionReps(count: 3), options: options)
        let runner = ActivityRunner(assignment: Recipes.assignment(.extensionLumbar, demo: true),
                                    verifier: HandheldExtensionVerifier(target: 3),
                                    source: LiveDeclaredExtensionReplay(samples: samples))
        runner.start()
        for _ in 0..<400 where runner.outcome == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(runner.outcome?.achieved == 3)
        #expect(runner.level == .reduced)
    }

    @Test func respaldoTambienRechazaLasMunecas() {
        // Sin mundo no se ve la cara irse hacia atrás, pero la cara se mueve en el encuadre del teléfono.
        var options = Synth.Options()
        options.world = false
        options.leadInSeconds = 4.5
        var v = HandheldExtensionVerifier(target: 5)
        let samples = Synth.samples(reps: Synth.extensionReps(count: 3, style: .wristsOnly), options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        #expect(anomalies(outcome, HandheldExtensionAnomaly.wristsOnly).count == 3)
        #expect(v.diagnostics.allSatisfy { $0.mode == .inertial && $0.faceBackward == nil })
    }

    // MARK: Gate

    @Test func caraPerdidaBloqueaYVuelveACalibrar() {
        var v = HandheldExtensionVerifier(target: 5)
        var options = Synth.Options()
        options.leadInSeconds = 6
        var samples = Synth.samples(reps: Synth.extensionReps(count: 2), options: options)
        for i in samples.indices where samples[i].t >= 2.0 && samples[i].t < 4.0 {
            samples[i].faceTracked = false
        }
        let events = run(&v, samples)

        #expect(events.contains(.gate(.blocked(reason: HandheldExtensionCopy.keepFace))))
        #expect(events.filter { $0 == .gate(.ready) }.count == 2)
        #expect(v.progress.count == 2)
        #expect(v.progress.gate == .ready)
    }

    @Test func sinCaraNoCalibra() {
        var v = HandheldExtensionVerifier(target: 5)
        var samples = Synth.samples(reps: [], options: Synth.Options())
        for i in samples.indices { samples[i].faceTracked = false }
        let events = run(&v, samples)

        #expect(!events.contains(.gate(.ready)))
        #expect(v.progress.gate == .calibrating)
        #expect(v.progress.hint == HandheldExtensionCopy.takePhone)
        #expect(v.reference == nil)
    }

    @Test(arguments: [-6.0, 8.0])
    func cambiarElAgarreNoDejaPegadoElConteo(pitchOffset: Double) {
        // A los 2,5 s cambia cómo sostiene el teléfono (la pantalla queda `pitchOffset`° más arriba o más
        // abajo) y lo deja así: el verificador vuelve a calibrar de pie y las extensiones siguientes cuentan.
        var options = Synth.Options()
        options.leadInSeconds = 13
        var samples = Synth.samples(reps: Synth.extensionReps(count: 5), options: options)
        for i in samples.indices where samples[i].t >= 2.5 { samples[i].phonePitchDeg += pitchOffset }
        var v = HandheldExtensionVerifier(target: 5)
        let events = run(&v, samples)
        let outcome = finish(&v, samples, reason: .completed)

        #expect(events.filter { $0 == .gate(.ready) }.count == 2)
        #expect(outcome.achieved == 5, "\(v.diagnostics.map { ($0.peakTilt, $0.rejection as Any) })")
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func lineaDeDepuracionMuestraInclinacionYCara() {
        var v = HandheldExtensionVerifier(target: 5)
        let samples = Synth.samples(reps: [Synth.Rep(tilt: 20, holdSeconds: 1.0)])
        var deepest = ""
        v.start(at: 0)
        for s in samples {
            _ = v.ingest(s, at: s.t)
            if v.tilt > 18 { deepest = v.progress.debug ?? "" }
        }
        #expect(deepest.hasPrefix("Inclinación"), "\(deepest)")
        #expect(deepest.contains("cm atrás") && deepest.contains("mundo"))
    }

    // MARK: Integración con el runner, el cableado y el flujo de pausa

    @MainActor
    @Test func builderDeReplayCompletaComoSimulado() async {
        let store = AppStore(inMemory: true)
        let builder = ExtensionWiring.builder(hub: SensorHub(), store: store, seed: 9, speed: .infinity)
        let assignment = Recipes.assignment(.extensionLumbar, demo: true)
        let runner = builder(assignment, true, true)
        #expect(runner.isHandheldReplay)
        #expect(runner.isHandheldRunner)
        runner.start()
        for _ in 0..<400 where runner.outcome == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(runner.outcome?.completed == true)
        #expect(runner.level == .simulated)
        #expect(runner.verifiedResult?.level == .simulated)
        #expect(runner.verifiedResult?.kind == .extensionLumbar)
        #expect(runner.verifiedResult?.anomalies.contains { $0.severity == .hard } == false)
    }

    @MainActor
    @Test func elCableadoGenericoDelegaEnLosEjerciciosEnLasManos() {
        let store = AppStore(inMemory: true)
        let hub = SensorHub()
        for kind in [ActivityKind.sentadilla, .extensionLumbar] {
            let runner = VerifierWiring.builder(for: kind, sensors: hub, store: store)(Recipes.assignment(kind, demo: true), true, true)
            #expect(runner.isHandheldRunner, "\(kind) debe usar el runner en las manos")
            #expect(HandheldActivityView.handles(kind))
        }
        #expect(!HandheldActivityView.handles(.cuello) && !HandheldActivityView.handles(.ojos))
        #expect(HandheldActivityView.instructions(for: .extensionLumbar) == ActivityKind.extensionLumbar.instructions)
    }

    @MainActor
    @Test func saltarEntregaResultadoConTestigo() {
        let store = AppStore(inMemory: true)
        let builder = ExtensionWiring.builder(hub: SensorHub(), store: store, seed: 3, speed: 1)
        let runner = builder(Recipes.assignment(.extensionLumbar, demo: true), true, true)
        runner.start()
        runner.stop(reason: .skipped)
        #expect(runner.outcome?.reason == .skipped)
        #expect(runner.verifiedResult?.skipped == true)
    }

    @Test func sentadillaYExtensionUsanLaCamaraDeCaraSinRelevo() {
        // ARKit sin vista: el mismo bloque que cuello y pestañeo; no hay AVCaptureSession ni relevo de cámara.
        #expect(ActivityKind.sentadilla.sensorBlock == .face)
        #expect(ActivityKind.extensionLumbar.sensorBlock == .face)
        #expect(PauseCoordinator.usesCamera(.sentadilla) && PauseCoordinator.usesCamera(.extensionLumbar))
        let route = Recipes.base(.campamento5, demo: false).activities
        #expect(SensorBlockPlanner.cameraHandoffs(route).isEmpty)
        #expect(ActivityKind.extensionLumbar.placement == "Teléfono en las dos manos, frente al pecho")
        #expect(ActivityKind.extensionLumbar.gatingCopy == ["Tome el teléfono frente al pecho y mírelo.", "Quieto un segundo.", "Inclínese hacia atrás."])
        #expect(ActivityKind.extensionLumbar.instructions == HandheldExtensionCopy.instructions)
        #expect(HandheldExtensionCopy.instructions.contains("hasta donde no duela"))
    }

    @MainActor
    @Test func laFilaDelPlanDiceEnLasDosManosParaLosEjerciciosEnLasManos() {
        // La extensión es `.face` como cuello y ojos, pero la fila del plan no debe decir "en la mano" (selfie).
        for kind in [ActivityKind.sentadilla, .pararseSentarse, .extensionLumbar] {
            #expect(PlanRow.placement(for: kind) == "Teléfono en las dos manos, frente al pecho", "\(kind)")
            #expect(PlanRow.placementSymbol(for: kind) == "iphone", "\(kind)")
        }
        #expect(PlanRow.placement(for: .extensionLumbar) == ActivityKind.sentadilla.placement)
        #expect(PlanRow.placement(for: .cuello) == PlanRow.placement(for: SensorBlock.face))
        #expect(PlanRow.placementSymbol(for: .ojos) == PlanRow.placementSymbol(for: SensorBlock.face))
    }

    @MainActor
    @Test func rutaCompletaPasaDeUnEjercicioAOtroSinEsperarLaCamara() {
        let store = AppStore(inMemory: true)
        store.mutate { $0.profile.consentGiven = true }
        let c = PauseCoordinator(moment: .campamento, store: store, game: GameStore(store: store), coach: CoachService())
        c.submitCheckIn(answers: [false, false, false, false, false, false], zones: [.lumbar], moment: .campamento)
        #expect(c.plan.map(\.kind) == ActivityKind.sessionOrder)
        c.startActivities()
        for i in 0..<c.plan.count {
            // Sin relevo de cámara: cada actividad tiene su runner apenas termina la anterior.
            #expect(c.stage == .activity(i))
            #expect(c.runner != nil, "actividad \(i) sin runner")
            c.skipCurrent()
        }
        #expect(c.stage == .postCheck)
    }
}
