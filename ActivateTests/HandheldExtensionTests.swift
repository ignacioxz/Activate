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
        // No quedarse atrás no cuenta esas reps, pero nunca marca sospechosa una pausa honesta (dato real: el
        // usuario aguantó 0,5-1,2 s y la pausa quedaba "suspicious").
        #expect(hardKinds(outcome).isEmpty)
        #expect(anomalies(outcome, HandheldExtensionAnomaly.holdChallengeFailed).first?.severity == .soft)
        #expect(anomalies(outcome, HandheldExtensionAnomaly.holdChallengeFailed).first?.detail == HoldChallengeCopy.backExtension.failureDetail)
        #expect(outcome.achieved == 8)
        #expect(v.challenge.failures == HoldChallenge.maxFailures)
        #expect(!v.challenge.passed)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .extensionLumbar) == .full)
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
        // Pararse y sentarse va en el bolsillo (PocketSitStandVerifier): ya no es un ejercicio en las manos.
        #expect(PlanRow.placement(for: .pararseSentarse) == "Teléfono en el bolsillo delantero del pantalón")
        for kind in [ActivityKind.sentadilla, .extensionLumbar] {
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

// MARK: - Red team (regresión)
//
// Ataques y falsos negativos que encontró el red team de la extensión lumbar en las manos, ahora como
// regresión. Cada caso arma una secuencia sintética a 60 Hz con cinemática de cuerpo rígido (teléfono,
// cabeza, giro lumbar, muñecas, cuello, brazos) y el mismo modelo de ruido que `HandheldExtensionSynth`
// (VIO ±1,5 mm, cabeceo ±0,4°, cabeceo de la cara ±1°, IMU, blendShapes), y la pasa por el verificador real.
// Una trampa no suma reps (o no queda `full`) y una extensión legítima cuenta sin anomalías hard.
// Cada corrida imprime "RT|<caso>|…" con lo medido (útil para calibrar en el iPhone).

// MARK: - Cinemática

private struct RTPose {
    var phone: SIMD3<Double>
    /// Giro del teléfono hacia atrás respecto de la postura de pie (°): la pantalla mira más hacia abajo.
    var rotation: Double
    var face: SIMD3<Double>
    /// Giro de la cabeza hacia atrás en el mundo (°). La muestra lleva el cabeceo de la cara respecto del
    /// teléfono: `standingFaceRelPitch + headPitch − rotation`.
    var headPitch: Double = 0
}

private struct RTRep {
    var tilt: Double
    var back: Double
    var hold: Double
    var ret: Double
    var rest: Double
}

/// Agenda de reps tras un lead-in de pie quieto.
private struct RTSchedule {
    let reps: [RTRep]
    let starts: [Double]
    let end: Double

    init(reps: [RTRep], leadIn: Double = 1.8, trail: Double = 1.0) {
        self.reps = reps
        var cursor = leadIn
        var starts: [Double] = []
        for r in reps {
            starts.append(cursor)
            cursor += r.back + r.hold + r.ret + r.rest
        }
        self.starts = starts
        self.end = cursor + trail
    }

    /// (índice de la rep, avance 0…1…0, grados) o nil si está de pie.
    func angle(at t: Double) -> (index: Int, x: Double, degrees: Double)? {
        guard let i = starts.lastIndex(where: { $0 <= t }) else { return nil }
        let r = reps[i]
        let local = t - starts[i]
        let x: Double
        if local < r.back {
            x = HandheldSquatSynth.minJerk(local / r.back)
        } else if local < r.back + r.hold {
            x = 1
        } else if local < r.back + r.hold + r.ret {
            x = 1 - HandheldSquatSynth.minJerk((local - r.back - r.hold) / r.ret)
        } else {
            return nil
        }
        return (i, x, r.tilt * x)
    }

    /// `count` reps humanas (tiempos variados) alrededor de `tilt` (°).
    static func human(count: Int, tilt: Double, spread: Double = 1.0) -> [RTRep] {
        let jitter = [0.0, 0.6, -0.4, 1.0, 0.2, -0.2, 0.8, 0.1, 0.5, -0.3, 0.9, 0.3]
        return (0..<count).map { i in
            let k = i % Synth.backVariation.count
            return RTRep(tilt: tilt + spread * jitter[i % jitter.count], back: Synth.backVariation[k], hold: 0.3,
                         ret: Synth.returnVariation[k], rest: Synth.restVariation[k] + 0.2)
        }
    }
}

private enum Body {
    static let phone0 = Synth.standingPhone
    static let face0 = Synth.standingFace
    /// Giro lumbar (el mismo del sintetizador).
    static let lumbar = Synth.pivot
    static let wrist = phone0 + Synth.wristOffset
    /// Giro efectivo del cuello: 12 cm bajo el centro de la cabeza y 4 cm detrás.
    static let neck = face0 + SIMD3(0, -0.12, 0.04)
    static let standing = RTPose(phone: phone0, rotation: 0, face: face0)

    static func rotate(_ v: SIMD3<Double>, about c: SIMD3<Double>, _ degrees: Double) -> SIMD3<Double> {
        c + Synth.rotateBack(v - c, degrees: degrees)
    }

    /// Extensión real: tronco rígido alrededor de la zona lumbar. `separation` (m): los brazos se relajan y el
    /// teléfono se aleja del pecho (y baja la mitad); `neckDeg`: además mira un poco hacia arriba (< 0: la
    /// cabeza se queda más derecha que el tronco); `pelvisForward` (m): empuja la cadera hacia adelante.
    static func trunk(_ degrees: Double, x: Double, separation: Double = 0, neckDeg: Double = 0,
                      pelvisForward: Double = 0) -> RTPose {
        let nod = neckDeg != 0 ? 0 : 0.012
        var p = RTPose(phone: rotate(phone0, about: lumbar, degrees), rotation: degrees,
                       face: rotate(face0, about: lumbar, degrees) + SIMD3(0, -nod, nod * 0.5) * x,
                       headPitch: degrees + neckDeg * x)
        let forward = Synth.rotateBack(SIMD3(0, 0, -1), degrees: degrees)
        let down = Synth.rotateBack(SIMD3(0, -1, 0), degrees: degrees)
        p.phone += (forward + 0.5 * down) * separation * x
        if neckDeg != 0 {
            p.face = rotate(p.face, about: rotate(neck, about: lumbar, degrees), neckDeg * x)
        }
        p.phone.z -= pelvisForward * x
        p.face.z -= pelvisForward * x
        return p
    }

    /// Solo las muñecas giran el teléfono.
    static func wrists(_ degrees: Double, phone: SIMD3<Double> = phone0) -> RTPose {
        RTPose(phone: rotate(phone, about: phone + Synth.wristOffset, degrees), rotation: degrees, face: face0)
    }

    /// Cabeza hacia atrás (extensión de cuello `degrees`) y mentón adentro (`tuck` m hacia atrás).
    static func head(_ degrees: Double, tuck: Double = 0) -> SIMD3<Double> {
        rotate(face0, about: neck, degrees) + SIMD3(0, 0, tuck)
    }

    /// Los brazos suben el teléfono en un arco alrededor de la cara, siempre apuntándola (como subirlo a la
    /// altura de los ojos): la cara no se mueve en el encuadre.
    static func orbit(_ degrees: Double) -> RTPose {
        RTPose(phone: rotate(phone0, about: face0, degrees), rotation: degrees, face: face0)
    }

    /// Cabeza atrás `degrees` y los brazos llevan el teléfono con ella (fijo respecto de la cara): el conjunto
    /// gira alrededor del cuello, sin mover el tronco. `pullBack` (m): los brazos además lo acercan al cuerpo.
    static func neckRig(_ degrees: Double, pullBack: Double = 0, x: Double = 1) -> RTPose {
        var p = RTPose(phone: rotate(phone0, about: neck, degrees), rotation: degrees, face: rotate(face0, about: neck, degrees),
                       headPitch: degrees)
        p.phone.z += pullBack * x
        return p
    }

    /// Teléfono y cara (video o maniquí) fijos entre sí, el conjunto girado con las muñecas.
    static func rig(_ degrees: Double) -> RTPose {
        RTPose(phone: rotate(phone0, about: wrist, degrees), rotation: degrees, face: rotate(face0, about: wrist, degrees),
               headPitch: degrees)
    }
}

// MARK: - Render a muestras

private struct RTOptions {
    var seed: UInt64 = 1
    var fps = 60.0
    var positionNoise = 0.0015
    var pitchNoise = 0.4
    var shapeEnergy: Float = 0.02
    var accelNoise = 0.04
    var headPitchNoise = 1.0
    /// Seguimiento del mundo `.normal` en `t`.
    var world: (Double) -> Bool = { _ in true }
    var faceTracked: (Double) -> Bool = { _ in true }
    var steps: ((Double) -> Int)? = nil
    /// RMS de userAccel (sacudidas, caminar) en `t`; nil = el que da la cinemática.
    var extraRMS: ((Double) -> Double?)? = nil
}

private func render(duration: Double, options: RTOptions = RTOptions(), pose: (Double) -> RTPose) -> [HandheldSquatSample] {
    var rng = FixtureRandom(seed: options.seed)
    var headRng = FixtureRandom(seed: options.seed &+ 0x5EED)
    let dt = 1 / options.fps
    let frames = Int((duration / dt).rounded(.up))
    var drift = SIMD3<Double>(repeating: 0)
    var out: [HandheldSquatSample] = []
    out.reserveCapacity(frames + 1)
    for i in 0...frames {
        let t = Double(i) * dt
        let p = pose(t)
        let n = options.positionNoise
        func jitter(_ v: SIMD3<Double>) -> SIMD3<Double> { v + SIMD3(rng.symmetric(n), rng.symmetric(n), rng.symmetric(n)) }
        let normal = options.world(t)
        // Con el mundo limitado ARKit sigue con la IMU y deriva; la cara en el encuadre (TrueDepth) sigue bien.
        if normal {
            drift = .zero
        } else {
            drift += SIMD3(rng.symmetric(0.002), rng.symmetric(0.002), rng.symmetric(0.002))
        }
        let faceInPhone = jitter(Synth.rotateBack(p.face - p.phone, degrees: -p.rotation))
        let accel = (pose(t + dt).phone.y - 2 * p.phone.y + pose(t - dt).phone.y) / (dt * dt)
        let g = 9.80665
        let rms = options.extraRMS?(t) ?? (0.02 * 0.02 + (accel / g) * (accel / g)).squareRoot()
        let tracked = options.faceTracked(t)
        out.append(HandheldSquatSample(
            t: t,
            phonePos: SIMD3<Float>(jitter(p.phone) + drift),
            phonePitchDeg: Synth.standingPitch - p.rotation + rng.symmetric(options.pitchNoise),
            phoneRollDeg: rng.symmetric(0.5),
            faceTracked: tracked,
            facePos: tracked ? SIMD3<Float>(jitter(p.face) + drift) : .zero,
            faceInPhone: tracked ? SIMD3<Float>(faceInPhone) : .zero,
            shapeEnergy: tracked ? max(0, options.shapeEnergy * Float(0.5 + rng.unit())) : 0,
            worldTrackingNormal: normal,
            altitude: nil,
            userAccelRMS: rms,
            verticalAccel: accel + rng.symmetric(options.accelNoise),
            steps: options.steps?(t),
            faceRelPitchDeg: tracked ? Synth.standingFaceRelPitch + p.headPitch - p.rotation + headRng.symmetric(options.headPitchNoise) : nil))
    }
    return out
}

private func render(_ schedule: RTSchedule, options: RTOptions = RTOptions(),
                    pose: @escaping (_ degrees: Double, _ x: Double) -> RTPose) -> [HandheldSquatSample] {
    render(duration: schedule.end, options: options) { t in
        guard let a = schedule.angle(at: t) else { return pose(0, 0) }
        return pose(a.degrees, a.x)
    }
}

// MARK: - Ejecución

private struct RTRun {
    var verifier: HandheldExtensionVerifier
    var events: [VerifierEvent]
    var outcome: ActivityOutcome
    var level: VerificationLevel

    var achieved: Int { outcome.achieved }
    var hard: [String] { outcome.anomalies.filter { $0.severity == .hard }.map(\.kind) }
    var rejections: [String] { verifier.diagnostics.map { $0.rejection?.rawValue ?? "OK" } }

    var summary: String {
        let diag = verifier.diagnostics.map { d in
            String(format: "[%@ %.1f° %.1fs geo%.1fcm dir%.1f° back%@ tel%@ cab%@ %@]", d.mode == .world ? "W" : "I", d.peakTilt, d.seconds,
                   d.geometryChange * 100, d.directionChange, d.faceBackward.map { String(format: "%.1fcm", $0 * 100) } ?? "-",
                   d.phoneBackward.map { String(format: "%.1fcm", $0 * 100) } ?? "-",
                   d.headTurn.map { String(format: "%+.0f°", $0) } ?? "-", d.rejection?.rawValue ?? "OK")
        }.joined(separator: " ")
        let anomalies = outcome.anomalies.map { "\($0.kind)/\($0.severity == .hard ? "H" : "s")" }.joined(separator: ",")
        let ready = events.filter { $0 == .gate(.ready) }.count
        return "achieved=\(achieved)/\(outcome.target) level=\(level) mode=\(verifier.mode == .world ? "world" : "inertial") ready×\(ready) anomalies=[\(anomalies)] \(diag)"
    }
}

private func play(_ samples: [HandheldSquatSample], target: Int, challenge: HoldChallenge = .none,
                  source: SourceLevel? = nil, name: String) -> RTRun {
    var v = HandheldExtensionVerifier(target: target, challenge: challenge)
    v.start(at: 0)
    var events: [VerifierEvent] = []
    for s in samples { events += v.ingest(s, at: s.t) }
    let outcome = v.finish(at: samples.last?.t ?? 0, reason: .timeout)
    let level = VerificationPolicy.level(for: outcome, source: source ?? sourceLevel(samples), kind: .extensionLumbar)
    let run = RTRun(verifier: v, events: events, outcome: outcome, level: level)
    print("RT|\(name)|\(run.summary)")
    return run
}

/// Nivel que reportaría `HandheldSquatRelay` (frames con cara desde que el mundo llegó a normal).
private func sourceLevel(_ samples: [HandheldSquatSample]) -> SourceLevel {
    var stats = HandheldSquatSourcePolicy.Stats()
    for s in samples {
        if s.worldTrackingNormal { stats.everNormal = true }
        if stats.everNormal, s.faceTracked {
            stats.countedFrames += 1
            if s.worldTrackingNormal { stats.normalFrames += 1 }
        }
    }
    return HandheldSquatSourcePolicy.level(worldTrackingSupported: true, stats: stats)
}

/// Coeficiente de variación y desviación (s) de los intervalos entre reps contadas.
private func rhythm(_ run: RTRun) -> (cv: Double, sd: Double) {
    let ts = run.verifier.diagnostics.filter { $0.rejection == nil }.map(\.at)
    let iv = zip(ts.dropFirst(), ts).map { $0 - $1 }
    guard iv.count >= 2 else { return (1, 1) }
    let mean = iv.reduce(0, +) / Double(iv.count)
    let sd = (iv.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(iv.count)).squareRoot()
    return (sd / mean, sd)
}

// MARK: - Escenarios

private enum Scenario {
    /// Cabeza atrás `neck`° + muñecas `wrist`° + los brazos suben el teléfono `raise` m (+ mentón adentro).
    static func headBackWrists(neck: Double, wrist: Double, raise: Double = 0, tuck: Double = 0,
                               pullBack: Double = 0, count: Int = 10) -> [HandheldSquatSample] {
        render(RTSchedule(reps: RTSchedule.human(count: count, tilt: wrist, spread: 0.4))) { deg, x in
            var p = Body.wrists(deg)
            p.phone.y += raise * x
            p.phone.z += pullBack * x
            p.face = Body.head(neck * x, tuck: tuck * x)
            p.headPitch = neck * x
            return p
        }
    }

    /// Sube el teléfono a los ojos (arco alrededor de la cara) y mete el mentón `tuck` m.
    static func orbitTuck(_ tuck: Double, count: Int = 10, options: RTOptions = RTOptions(), leadIn: Double = 1.8) -> [HandheldSquatSample] {
        render(RTSchedule(reps: RTSchedule.human(count: count, tilt: 14, spread: 0.5), leadIn: leadIn), options: options) { deg, x in
            var p = Body.orbit(deg)
            p.face = Body.head(0, tuck: tuck * x)
            return p
        }
    }

    static func videoRig(count: Int = 10) -> [HandheldSquatSample] {
        render(RTSchedule(reps: RTSchedule.human(count: count, tilt: 16))) { deg, _ in Body.rig(deg) }
    }

    static func extensionReal(count: Int = 8, tilt: Double = 18, separation: Double = 0, neckDeg: Double = 0,
                              pelvisForward: Double = 0, options: RTOptions = RTOptions(), leadIn: Double = 1.8) -> [HandheldSquatSample] {
        render(RTSchedule(reps: RTSchedule.human(count: count, tilt: tilt), leadIn: leadIn), options: options) { deg, x in
            Body.trunk(deg, x: x, separation: separation, neckDeg: neckDeg, pelvisForward: pelvisForward)
        }
    }

    /// Opciones con la cámara trasera tapada (o sin luz) toda la serie.
    static var covered: RTOptions {
        var options = RTOptions()
        options.world = { _ in false }
        return options
    }

    /// Operador con dolor: 12,8-15°, 2,4-3 s de ida y de vuelta, tiempos humanos al azar (±12 % por fase).
    static func slowPain(seed: UInt64, count: Int = 10) -> [HandheldSquatSample] {
        var rng = FixtureRandom(seed: seed)
        let reps = (0..<count).map { _ in
            RTRep(tilt: 12.8 + rng.unit() * 2.2, back: 2.7 * (0.88 + 0.24 * rng.unit()), hold: 0.5 * (0.6 + 0.8 * rng.unit()),
                  ret: 2.7 * (0.88 + 0.24 * rng.unit()), rest: 1.5 * (0.8 + 0.4 * rng.unit()))
        }
        var options = RTOptions()
        options.seed = seed
        return render(RTSchedule(reps: reps), options: options) { deg, x in Body.trunk(deg, x: x) }
    }
}


// MARK: - Tests

@Suite("Red team: extensión lumbar en las manos")
struct RedTeamExtensionTests {

    // MARK: Ataques que el verificador ya frenaba

    @Test func ataqueMunecasBarrido() {
        // Girar solo el teléfono con las muñecas: 12,5-18°, con el teléfono a 25, 39 y 63 cm de la cara.
        let phones: [(String, SIMD3<Double>)] = [("cerca", SIMD3(0, 1.38, 0.20)), ("normal", Body.phone0), ("lejos", SIMD3(0, 1.10, -0.05))]
        var total = 0
        for (label, phone) in phones {
            for tilt in [12.5, 14.0, 18.0] {
                let samples = render(RTSchedule(reps: RTSchedule.human(count: 4, tilt: tilt))) { deg, _ in
                    Body.wrists(deg, phone: phone)
                }
                let run = play(samples, target: 10, name: "munecas-\(label)-\(tilt)")
                total += run.achieved
                #expect(run.level == .suspicious, "\(label) \(tilt)°: la firma de las muñecas debe llegar a hard")
            }
        }
        #expect(total == 0)
    }

    @Test func ataqueSoloCabezaAtras() {
        // La cabeza va 35° atrás mirando el teléfono, que se queda quieto: no hay inclinación del teléfono.
        let samples = render(RTSchedule(reps: RTSchedule.human(count: 5, tilt: 35))) { deg, _ in
            RTPose(phone: Body.phone0, rotation: 0, face: Body.head(deg), headPitch: deg)
        }
        #expect(play(samples, target: 10, name: "solo-cabeza").achieved == 0)
    }

    @Test func ataqueSubirElTelefonoSinMoverLaCara() {
        let samples = render(RTSchedule(reps: RTSchedule.human(count: 6, tilt: 14))) { deg, _ in Body.orbit(deg) }
        let run = play(samples, target: 10, name: "orbita")
        #expect(run.achieved == 0)
        #expect(run.rejections.allSatisfy { $0 == "wristsOnly" })
    }

    @Test func ataqueBrazosAtrasAcercandoElTelefono() {
        // Tira el teléfono 12 cm hacia la cara mientras lo inclina y mete el mentón 4 cm.
        let toFace = simd_normalize(Body.face0 - Body.phone0)
        let samples = render(RTSchedule(reps: RTSchedule.human(count: 6, tilt: 15))) { deg, x in
            var p = Body.wrists(deg)
            p.phone += toFace * 0.12 * x
            p.face = Body.head(0, tuck: 0.04 * x)
            return p
        }
        #expect(play(samples, target: 10, name: "brazos-atras").achieved == 0)
    }

    @Test func ataqueFotoPegadaAlTelefono() {
        var options = RTOptions()
        options.shapeEnergy = 0.0003
        let samples = render(RTSchedule(reps: RTSchedule.human(count: 6, tilt: 16)), options: options) { deg, _ in Body.rig(deg) }
        let run = play(samples, target: 10, name: "foto-pegada")
        #expect(run.achieved == 0)
        #expect(run.level == .suspicious)
    }

    @Test func ataqueBambolearElTelefono() {
        // Cabeceo ±15° a 1,3 Hz alrededor del propio teléfono: casi sin aceleración lineal.
        let samples = render(duration: 14) { t in
            guard t >= 2 else { return Body.standing }
            let deg = 15 * (0.5 - 0.5 * cos(2 * .pi * 1.3 * (t - 2)))
            return RTPose(phone: Body.phone0, rotation: deg, face: Body.face0)
        }
        #expect(play(samples, target: 10, name: "bamboleo").achieved == 0)
    }

    @Test func ataqueSacudirFuerte() {
        var options = RTOptions()
        options.extraRMS = { t in t >= 2 ? 1.2 : nil }
        let schedule = RTSchedule(reps: RTSchedule.human(count: 5, tilt: 16))
        let samples = render(duration: schedule.end, options: options) { t in
            var p = schedule.angle(at: t).map { Body.trunk($0.degrees, x: $0.x) } ?? Body.standing
            if t >= 2 { p.phone.y += 0.03 * sin(2 * .pi * 6 * t) }
            return p
        }
        let run = play(samples, target: 10, name: "sacudir")
        #expect(run.achieved == 0)
        #expect(run.level == .suspicious)
    }

    @Test func ataqueSentadillas() {
        // Sentadilla real (la pantalla se inclina hacia arriba) y media sentadilla de 9 cm girando el teléfono.
        let schedule = RTSchedule(reps: RTSchedule.human(count: 5, tilt: 14))
        let squats = render(schedule) { _, x in
            var p = Body.standing
            p.phone.y -= 0.22 * x
            p.face.y -= 0.21 * x
            p.rotation = -8 * x
            return p
        }
        let half = render(schedule) { deg, x in
            var p = Body.wrists(deg)
            p.phone.y -= 0.09 * x
            p.face.y -= 0.09 * x
            return p
        }
        #expect(play(squats, target: 10, name: "sentadilla").achieved == 0)
        #expect(play(half, target: 10, name: "media-sentadilla+munecas").achieved == 0)
    }

    @Test func ataqueCaminar() {
        // Caminar con el teléfono frente al pecho: balanceo de cabeceo ±5° y avance de 1,1 m/s.
        var options = RTOptions()
        options.steps = { t in t >= 2 ? Int(1.8 * (t - 2)) : 0 }
        options.extraRMS = { t in t >= 2 ? 0.25 : nil }
        let samples = render(duration: 20, options: options) { t in
            guard t >= 2 else { return Body.standing }
            let w = t - 2
            var p = RTPose(phone: Body.phone0, rotation: 5 * sin(2 * .pi * 0.9 * w), face: Body.face0)
            let step = SIMD3<Double>(0, 0.025 * sin(2 * .pi * 1.8 * w), -1.1 * w)
            p.phone += step
            p.face += step
            return p
        }
        let run = play(samples, target: 10, name: "caminar")
        #expect(run.achieved == 0)
        #expect(run.outcome.anomalies.contains { $0.kind == HandheldExtensionAnomaly.walking })
    }

    @Test func ataqueRitmoDeMetronomo() {
        // Un motor mece un maniquí con cara viva y ritmo exacto, girando todo el tronco: tooRegular (hard).
        let reps = (0..<10).map { _ in RTRep(tilt: 16, back: 1.0, hold: 0.3, ret: 1.0, rest: 0.9) }
        var options = RTOptions()
        options.positionNoise = 0.0005
        let samples = render(RTSchedule(reps: reps), options: options) { deg, x in Body.trunk(deg, x: x) }
        let run = play(samples, target: 10, name: "metronomo")
        #expect(run.level == .suspicious)
        #expect(run.hard.contains(HandheldExtensionAnomaly.tooRegular))
        // El mismo motor meciendo solo el teléfono con una cara pegada ya no suma: el teléfono no va atrás.
        let rig = render(RTSchedule(reps: reps), options: options) { deg, _ in Body.rig(deg) }
        #expect(play(rig, target: 10, name: "metronomo-pegado").achieved == 0)
    }

    // MARK: Ataques cerrados por el endurecimiento

    @Test(arguments: [(30.0, 13.5, 0.03, 0.0, 0.0), (30.0, 13.5, 0.04, 0.0, 0.0), (25.0, 13.5, 0.03, 0.02, 0.0),
                      (20.0, 14.0, 0.04, 0.02, 0.0), (35.0, 13.5, 0.02, 0.02, 0.025)])
    func ataqueCabezaAtrasMunecasYSubirUnPoco(neck: Double, wrist: Double, raise: Double, tuck: Double, pullBack: Double) {
        // Sin mover el tronco: echa la cabeza atrás mirando el teléfono, lo gira con las muñecas y lo sube unos
        // centímetros. El teléfono casi no va hacia atrás (≤ 0,06 m/rad) → wristsOnly. El último caso además lo
        // tira 2,5 cm hacia el cuerpo (mímica completa): pasa lo del teléfono, pero la cabeza giró 21° más que
        // el teléfono → headOnly.
        let samples = Scenario.headBackWrists(neck: neck, wrist: wrist, raise: raise, tuck: tuck, pullBack: pullBack)
        let run = play(samples, target: 10, name: "cabeza\(neck)+munecas\(wrist)+sube\(raise)+menton\(tuck)+tira\(pullBack)")
        #expect(run.achieved == 0, "ATAQUE PASA: \(run.achieved) reps a \(run.level)")
        let expected: Set<String> = pullBack > 0 ? ["headOnly"] : ["wristsOnly"]
        #expect(Set(run.rejections) == expected, "\(run.rejections)")
    }

    @Test(arguments: [(30.0, 13.0), (35.0, 13.5)])
    func ataqueCabezaAtrasMasMunecas(neck: Double, wrist: Double) {
        let run = play(Scenario.headBackWrists(neck: neck, wrist: wrist), target: 10, name: "cabeza\(neck)+munecas\(wrist)")
        #expect(run.achieved == 0, "ATAQUE CUENTA \(run.achieved) reps (nivel \(run.level))")
        let short = run.verifier.diagnostics.allSatisfy { d in
            (d.phoneBackward ?? 1) < K.phoneMinBackPerRadian * d.peakTilt * .pi / 180
        }
        #expect(short, "el teléfono debió quedarse corto hacia atrás")
    }

    @Test(arguments: [0.035, 0.05])
    func ataqueSubirElTelefonoMasMentonAdentro(tuck: Double) {
        // Sube el teléfono a los ojos (arco alrededor de la cara) y mete el mentón: el teléfono va ADELANTE.
        let run = play(Scenario.orbitTuck(tuck), target: 10, name: "orbita+menton\(tuck)")
        #expect(run.achieved == 0, "ATAQUE PASA: \(run.achieved) reps a \(run.level)")
        #expect(run.verifier.diagnostics.allSatisfy { ($0.phoneBackward ?? 0) < 0 })
    }

    @Test func ataqueVideoDeCaraPegadoAlTelefono() {
        // Cara "viva" (video, maniquí con ojos que se mueven) fija al teléfono, el conjunto girado con las
        // muñecas: el teléfono retrocede 1,4-1,7 cm con 16-17° (< 0,07 m/rad).
        let run = play(Scenario.videoRig(), target: 10, name: "video-pegado")
        #expect(run.achieved == 0, "ATAQUE PASA: \(run.achieved) reps a \(run.level)")
    }

    @Test func ataqueTaparLaCamaraTraseraTodoElRato() {
        // Dedo sobre la cámara trasera + subir el teléfono a los ojos: sin el mundo, la cabeza no giró con el
        // teléfono (cabeceo de la cara respecto del teléfono = −inclinación).
        let samples = Scenario.orbitTuck(0, options: Scenario.covered, leadIn: 4.5)
        let run = play(samples, target: 10, name: "tapada-orbita")
        #expect(run.achieved == 0, "ATAQUE PASA: \(run.achieved) reps a \(run.level)")
        #expect(run.verifier.diagnostics.allSatisfy { $0.mode == .inertial && ($0.headRatio ?? 0) < -K.headMinTurnRatio })
    }

    @Test func ataqueTaparLaCamaraSoloDuranteCadaRep() {
        // Tapa la cámara trasera solo en cada rep falsa y la destapa de pie el resto: el 80 % de los frames
        // queda con mundo normal y la fuente sigue `.live`. Cada rep se mide con el respaldo (cabeza quieta →
        // rechazada) y, si alguna contara, `inertialFallback` limita el nivel a reduced.
        var reps: [RTRep] = []
        var starts: [Double] = []
        var covered: [(Double, Double)] = []
        let waits = [16.0, 17.5, 15.5, 18.0, 16.5, 17.0, 15.8, 17.8, 16.2, 17.2]
        var cursor = 2.5
        for i in 0..<10 {
            let r = RTRep(tilt: 14 + 0.3 * Double(i % 3), back: 0.9, hold: 0.2, ret: 0.9, rest: 0)
            let start = cursor + 1.8
            reps.append(r)
            starts.append(start)
            covered.append((cursor, start + r.back + r.hold + r.ret + 0.3))
            cursor = start + r.back + r.hold + r.ret + waits[i]
        }
        let end = cursor
        var options = RTOptions()
        options.world = { t in !covered.contains { t >= $0.0 && t < $0.1 } }
        let samples = render(duration: end, options: options) { t in
            guard let i = starts.lastIndex(where: { $0 <= t }) else { return Body.standing }
            let r = reps[i]
            let local = t - starts[i]
            let x: Double
            if local < r.back {
                x = HandheldSquatSynth.minJerk(local / r.back)
            } else if local < r.back + r.hold {
                x = 1
            } else {
                x = 1 - HandheldSquatSynth.minJerk((local - r.back - r.hold) / r.ret)
            }
            return Body.orbit(r.tilt * x)
        }
        let run = play(samples, target: 10, name: "tapar-solo-en-rep(\(Int(end)) s)")
        #expect(end < VerificationSpec.standard(for: .extensionLumbar).maxDurationSeconds)
        #expect(sourceLevel(samples) == .live)
        #expect(run.achieved == 0, "ATAQUE PASA: \(run.achieved) reps a \(run.level)")
        #expect(run.verifier.diagnostics.allSatisfy { $0.mode == .inertial })
    }

    @Test func unaRepContadaConElRespaldoLimitaElNivelAReduced() {
        // Arreglo C: aunque la fuente quede `.live`, una rep contada sin el mundo deja la serie en reduced
        // (extensión y sentadilla). Sin esa anomalía sigue full.
        for kind in [ActivityKind.extensionLumbar, .sentadilla] {
            var outcome = ActivityOutcome(kind: kind, target: 10, achieved: 10, completed: true, durationSeconds: 60,
                                          metrics: .reps(count: 10, minDescentRatio: nil, meanRepSeconds: 2),
                                          anomalies: [], reason: .completed)
            #expect(VerificationPolicy.level(for: outcome, source: .live, kind: kind) == .full)
            outcome.anomalies = [Anomaly(kind: HandheldSquatAnomaly.inertialFallback, severity: .soft, at: 10, detail: "")]
            #expect(VerificationPolicy.level(for: outcome, source: .live, kind: kind) == .reduced)
            outcome.anomalies.append(Anomaly(kind: RegularityDetector.anomalyKind, severity: .hard, at: 20, detail: ""))
            #expect(VerificationPolicy.level(for: outcome, source: .live, kind: kind) == .suspicious)
        }
    }

    // MARK: Residuales documentados (no se cierran con lo que mide el teléfono)

    @Test func residualMimicaElaboradaConElMundo() {
        // Cuatro movimientos a la vez y sincronizados con cada rep: cuello 20° atrás + mentón 3,5 cm adentro +
        // muñecas 13° + los brazos suben el teléfono 2 cm y lo tiran 2 cm hacia el cuerpo. El teléfono va 3,3 cm
        // atrás, la cara 7,8 cm, la cabeza gira 6° más que el teléfono y la cara cambia < 6 cm en el encuadre:
        // con estos datos es indistinguible de una extensión corta con la cadera adelante.
        let run = play(Scenario.headBackWrists(neck: 20, wrist: 13, raise: 0.02, tuck: 0.035, pullBack: 0.02, count: 6),
                       target: 10, name: "residual-mimica")
        withKnownIssue("Mímica elaborada de cuello + mentón + muñecas + brazos: pasa con el mundo") {
            #expect(run.achieved == 0)
        }
    }

    @Test func residualCabezaYTelefonoJuntosSinElMundo() {
        // Cámara trasera tapada: echar la cabeza atrás y llevar el teléfono con ella (fijo respecto de la cara)
        // se ve igual que una extensión real desde el cabeceo y TrueDepth. Con el mundo se frena (el teléfono va
        // adelante); sin él cuenta, pero solo reduced (arreglo C).
        let pose: (Double, Double) -> RTPose = { deg, x in Body.neckRig(deg, x: x) }
        let world = play(render(RTSchedule(reps: RTSchedule.human(count: 6, tilt: 16)), pose: pose), target: 10, name: "residual-cuello-mundo")
        #expect(world.achieved == 0)
        let covered = play(render(RTSchedule(reps: RTSchedule.human(count: 6, tilt: 16), leadIn: 4.5), options: Scenario.covered, pose: pose),
                           target: 10, name: "residual-cuello-tapada")
        #expect(covered.level != .full)
        withKnownIssue("Sin el mundo, cabeza y teléfono girando juntos alrededor del cuello cuentan (reduced)") {
            #expect(covered.achieved == 0)
        }
    }

    // MARK: Falsos negativos cerrados

    @Test func legitimoConDolorLentoYCorto() {
        // 12,8-15°, 2,4-3 s por lado, tiempos humanos: σ 0,2-0,3 s en 7,5 s ya no es tooRegular (σ < 0,12 s).
        for seed in [UInt64(1), 2, 3, 4, 5] {
            let run = play(Scenario.slowPain(seed: seed), target: 10, name: "FN-dolor-lento-\(seed)")
            let r = rhythm(run)
            print("RT|FN-dolor-lento-\(seed)-ritmo|cv=\(String(format: "%.3f", r.cv)) sd=\(String(format: "%.2f", r.sd)) s")
            #expect(run.achieved == 10, "FALSO NEGATIVO: \(run.rejections)")
            #expect(run.level == .full, "seed \(seed): \(run.hard)")
        }
    }

    @Test func legitimoConDolorQueSostieneAtras() {
        // Como enseña el kine (y como pide el propio desafío): 3 s hacia atrás, 2,5 s sostenido, 3 s de vuelta.
        let reps = (0..<6).map { i in
            RTRep(tilt: 13.5 + 0.4 * Double(i % 3), back: 3.0, hold: 2.5 + 0.1 * Double(i % 2), ret: 3.0, rest: 1.5 + 0.2 * Double(i % 3))
        }
        let samples = render(RTSchedule(reps: reps)) { deg, x in Body.trunk(deg, x: x) }
        let run = play(samples, target: 6, name: "FN-dolor-sostiene")
        #expect(run.achieved == 6, "FALSO NEGATIVO: \(run.rejections)")
        #expect(run.level == .full)
    }

    @Test(arguments: [(0.05, 0.0), (0.04, 8.0)])
    func legitimoBrazosQueSeSeparanDelPecho(separation: Double, neckDeg: Double) {
        // Al inclinarse los brazos se relajan: el teléfono se aleja `separation` m del pecho (y baja la mitad) y
        // la cabeza mira `neckDeg`° más arriba. Alejarse del encuadre tiene margen (12 cm).
        let samples = Scenario.extensionReal(tilt: 17, separation: separation, neckDeg: neckDeg)
        let run = play(samples, target: 8, name: "FN-brazos-separan-\(separation)-cuello\(neckDeg)")
        #expect(run.achieved >= 7, "FALSO NEGATIVO: \(run.rejections)")
        #expect(run.hard.isEmpty, "FALSO NEGATIVO con anomalía hard: \(run.hard)")
        #expect(run.level == .full)
    }

    @Test(arguments: [(2.1, 0.7), (3.0, 0.6), (4.0, 0.6)])
    func legitimoPocaLuz(period: Double, off: Double) {
        // Poca luz: el mundo (cámara trasera) se cae `off` s cada `period` s, con más ruido de VIO y caídas de
        // 2 frames de la cara; TrueDepth (infrarrojo) sigue la cara y deviceMotion da el cabeceo. No se
        // recalibra: las reps sin mundo se miden con el respaldo y la serie queda reduced.
        var options = RTOptions()
        options.positionNoise = 0.004
        options.world = { t in t < 2.5 || (t - 2.5).truncatingRemainder(dividingBy: period) < period - off }
        options.faceTracked = { t in Int(t * 60) % 97 > 1 }
        let run = play(Scenario.extensionReal(options: options), target: 8, name: "FN-poca-luz-\(period)-\(off)")
        #expect(run.achieved >= 7, "FALSO NEGATIVO: \(run.achieved)/8, \(run.rejections)")
        #expect(run.hard.isEmpty)
        // Cortes del mundo más breves que `worldLossToFallbackSeconds` (1,2 s, compartido con la sentadilla) se
        // miden con el mundo y quedan `full`; si la rep se midió con el respaldo, `reduced`. Nunca sospechosa.
        #expect(run.level == .reduced || run.level == .full)
        #expect(run.events.filter { $0 == .gate(.ready) }.count == 1, "no debe recalibrar por cada caída del mundo")
        #expect(run.verifier.progress.hint != HandheldExtensionCopy.uncoverCamera)
    }

    @Test func legitimoMundoLimitadoUnosInstantes() {
        // El mundo se limita 0,7 s justo atrás en la 2ª y la 5ª rep (de 8): la rep se mide con lo que alcanzó
        // a ver el mundo y no se recalibra.
        let schedule = RTSchedule(reps: RTSchedule.human(count: 8, tilt: 18))
        let glitches = [1, 4].map { i -> (Double, Double) in
            let s = schedule.starts[i] + schedule.reps[i].back * 0.8
            return (s, s + 0.7)
        }
        var options = RTOptions()
        options.world = { t in !glitches.contains { t >= $0.0 && t < $0.1 } }
        let samples = render(schedule, options: options) { deg, x in Body.trunk(deg, x: x) }
        let run = play(samples, target: 8, name: "FN-mundo-limitado")
        #expect(run.achieved >= 7, "FALSO NEGATIVO: \(run.achieved)/8")
        #expect(run.events.filter { $0 == .gate(.ready) }.count == 1)
        #expect(run.level == .full)
    }

    @Test func legitimoEmpujandoLaCaderaAdelante() {
        // Extensión de pie clásica: la pelvis se va 6 cm adelante mientras el tronco se inclina (el teléfono
        // retrocede 0,085 m/rad, sobre el mínimo de 0,07).
        let run = play(Scenario.extensionReal(tilt: 16, pelvisForward: 0.06), target: 8, name: "FN-cadera-adelante")
        #expect(run.achieved == 8, "FALSO NEGATIVO: \(run.rejections)")
        #expect(run.level == .full)
    }

    @Test(arguments: [-8.0, -12.0, -18.0])
    func legitimoConLaCabezaMasDerechaQueElTronco(neckDeg: Double) {
        // Deja la cabeza más derecha que el tronco (hasta del todo a 18°): con el mundo cuenta igual.
        let run = play(Scenario.extensionReal(tilt: 16, neckDeg: neckDeg), target: 8, name: "legit-cabeza-derecha\(neckDeg)")
        #expect(run.achieved == 8, "\(run.rejections)")
        #expect(run.level == .full)
        // Sin el mundo cuenta hasta −0,7 × inclinación; más allá no suma, pero nunca deja una anomalía hard.
        let covered = play(Scenario.extensionReal(tilt: 16, neckDeg: neckDeg, options: Scenario.covered, leadIn: 4.5),
                           target: 8, name: "legit-cabeza-derecha-tapada\(neckDeg)")
        if -neckDeg / 16 < K.headMinTurnRatio - 0.05 { #expect(covered.achieved == 8, "\(covered.rejections)") }
        #expect(covered.hard.isEmpty, "\(covered.hard)")
    }

    @Test(arguments: [12.0, 15.0])
    func legitimoMirandoUnPocoHaciaArriba(neckDeg: Double) {
        // Mira hasta 15° más arriba que el teléfono al inclinarse: cuenta con y sin el mundo.
        let run = play(Scenario.extensionReal(tilt: 16, neckDeg: neckDeg), target: 8, name: "legit-mira-arriba\(neckDeg)")
        #expect(run.achieved == 8, "\(run.rejections)")
        let covered = play(Scenario.extensionReal(tilt: 16, neckDeg: neckDeg, options: Scenario.covered, leadIn: 4.5),
                           target: 8, name: "legit-mira-arriba-tapada\(neckDeg)")
        #expect(covered.achieved == 8, "\(covered.rejections)")
    }

    @Test func caderaMuyAdelanteNoCuentaPeroNoQuedaHard() {
        // Riesgo conocido del arreglo A: empujar la cadera 10 cm adelante con 16° deja el teléfono casi quieto
        // en el mundo. No suma, pero recibe "Lleve el pecho hacia atrás…" y ninguna anomalía hard.
        let run = play(Scenario.extensionReal(tilt: 16, pelvisForward: 0.10), target: 8, name: "riesgo-cadera-10cm")
        #expect(run.hard.isEmpty, "\(run.hard)")
        #expect(run.events.contains(.cue(Cue(text: HandheldExtensionCopy.chestBack, symbol: "figure.flexibility"))))
        withKnownIssue("Cadera 10 cm adelante con 16°: el teléfono retrocede < 0,07 m/rad") {
            #expect(run.achieved >= 7)
        }
    }

    // MARK: Piezas del endurecimiento

    @Test func cabeceoDeLaCaraRespectoDelTelefonoNoCambiaConElTronco() {
        // La fuente suma la elevación de la mirada (eje +z de ARFaceAnchor en el mundo) y el cabeceo del
        // teléfono (gravedad de CoreMotion). Si cabeza y teléfono giran juntos no cambia; si solo gira el
        // teléfono, baja lo mismo que el teléfono.
        func face(_ degrees: Double) -> simd_float4x4 {
            let a = 50.0 * .pi / 180
            let z = Synth.rotateBack(SIMD3(0, -sin(a), -cos(a)), degrees: degrees)
            let y = Synth.rotateBack(SIMD3(0, cos(a), -sin(a)), degrees: degrees)
            let x = simd_cross(y, z)
            return simd_float4x4(SIMD4<Float>(SIMD3<Float>(x), 0), SIMD4<Float>(SIMD3<Float>(y), 0),
                                 SIMD4<Float>(SIMD3<Float>(z), 0), SIMD4<Float>(0, 1.58, 0.36, 1))
        }
        func phonePitch(_ degrees: Double) -> Double {
            HandheldSquatRelay.attitude(gravity: Synth.deviceGravity(backRotationDegrees: degrees)).pitch
        }
        #expect(abs(HandheldSquatRelay.faceElevation(face(0)) - -50) < 0.01)
        #expect(abs(HandheldSquatRelay.faceElevation(face(20)) - -30) < 0.01, "mirar más arriba sube la elevación")
        let standing = HandheldSquatRelay.faceElevation(face(0)) + phonePitch(0)
        for deg in [8.0, 14.0, 20.0] {
            let trunk = HandheldSquatRelay.faceElevation(face(deg)) + phonePitch(deg)
            let wrists = HandheldSquatRelay.faceElevation(face(0)) + phonePitch(deg)
            #expect(abs(trunk - standing) < 0.01)
            #expect(abs((wrists - standing) - -deg) < 0.01)
        }
    }

    @Test func regularidadConRepsLentasExigeSigmaBaja() {
        // Intervalos de 7,5 s con σ ≈ 0,2 s: CV 2,7 % (< 4 %) pero no es un metrónomo. Con σ 0,02 s sí.
        let human = [7.3, 7.7, 7.5, 7.2, 7.8, 7.4, 7.6, 7.5]
        let motor = [7.50, 7.52, 7.49, 7.51, 7.50, 7.48, 7.51, 7.50]
        func fires(_ intervals: [Double], _ detector: RegularityDetector) -> Bool {
            var d = detector
            var t = 0.0
            var fired = false
            _ = d.recordRep(at: t)
            for dt in intervals {
                t += dt
                if d.recordRep(at: t) != nil { fired = true }
            }
            return fired
        }
        #expect(fires(human, RegularityDetector()), "sin σ, la regla del CV lo marcaría")
        #expect(!fires(human, RegularityDetector(maxStandardDeviation: K.regularityMaxSigmaSeconds)))
        #expect(fires(motor, RegularityDetector(maxStandardDeviation: K.regularityMaxSigmaSeconds)))
    }

    @Test func umbralesPorRadianSeparanAtaquesDeLegitimos() {
        // Con el giro lumbar el TELÉFONO también se va hacia atrás (≥ 0,07 m por radián de inclinación) y la
        // CARA bastante más (≥ 0,30 m/rad). Con las muñecas, la cabeza o los brazos el pivote queda en las
        // muñecas o en la cara: el teléfono no retrocede. Mide en el punto más atrás, sin el verificador.

        /// Por rep: (inclinación °, teléfono atrás m, cara atrás m) en el punto más atrás, respecto de la postura
        /// de pie del primer segundo y medio (todos los escenarios vuelven a ella entre reps).
        func peaks(_ samples: [HandheldSquatSample]) -> [(tilt: Double, phoneBack: Double, faceBack: Double)] {
            let still = samples.filter { $0.t < 1.5 }
            let n = Double(still.count)
            let pitch0 = still.map(\.phonePitchDeg).reduce(0, +) / n
            let p0 = still.map { HandheldExtensionVerifier.d3($0.phonePos) }.reduce(.zero, +) / n
            let f0 = still.map { HandheldExtensionVerifier.d3($0.facePos) }.reduce(.zero, +) / n
            let back = simd_normalize(SIMD2(f0.x - p0.x, f0.z - p0.z))
            var out: [(Double, Double, Double)] = []
            var i = 0
            while i < samples.count {
                guard pitch0 - samples[i].phonePitchDeg > 6 else { i += 1; continue }
                var j = i
                while j < samples.count, pitch0 - samples[j].phonePitchDeg > 3 { j += 1 }
                guard let peak = samples[i..<j].min(by: { $0.phonePitchDeg < $1.phonePitchDeg }) else { break }
                let dp = HandheldExtensionVerifier.d3(peak.phonePos) - p0
                let df = HandheldExtensionVerifier.d3(peak.facePos) - f0
                out.append((pitch0 - peak.phonePitchDeg, simd_dot(SIMD2(dp.x, dp.z), back), simd_dot(SIMD2(df.x, df.z), back)))
                i = j + 30
            }
            return out
        }
        func accepted(_ p: (tilt: Double, phoneBack: Double, faceBack: Double)) -> Bool {
            let rad = p.tilt * .pi / 180
            return p.phoneBack >= K.phoneMinBackPerRadian * rad && p.faceBack >= K.faceMinBackPerRadian * rad
        }

        let legit: [(String, [HandheldSquatSample])] = [
            ("normal", Scenario.extensionReal()),
            ("dolor-lento", Scenario.slowPain(seed: 1)),
            ("brazos-5cm", Scenario.extensionReal(tilt: 17, separation: 0.05)),
            ("brazos-4cm+cuello8", Scenario.extensionReal(tilt: 17, separation: 0.04, neckDeg: 8)),
            ("cadera-6cm", Scenario.extensionReal(tilt: 16, pelvisForward: 0.06)),
            ("corta-12.5", Scenario.extensionReal(tilt: 12.5)),
        ]
        let attacks: [(String, [HandheldSquatSample])] = [
            ("cabeza30+munecas+sube3", Scenario.headBackWrists(neck: 30, wrist: 13.5, raise: 0.03)),
            ("cabeza20+munecas+sube4+menton2", Scenario.headBackWrists(neck: 20, wrist: 14, raise: 0.04, tuck: 0.02)),
            ("cabeza35+munecas", Scenario.headBackWrists(neck: 35, wrist: 13.5)),
            ("orbita+menton5", Scenario.orbitTuck(0.05)),
            ("video-pegado", Scenario.videoRig()),
        ]
        for (name, samples) in legit {
            let ps = peaks(samples)
            print("RT|umbral-legit-\(name)|" + ps.map { String(format: "%.1f° tel%.1fcm cara%.1fcm", $0.tilt, $0.phoneBack * 100, $0.faceBack * 100) }.joined(separator: " · "))
            #expect(!ps.isEmpty)
            #expect(ps.allSatisfy(accepted), "el umbral rechazaría a un legítimo: \(name)")
        }
        for (name, samples) in attacks {
            let ps = peaks(samples)
            print("RT|umbral-ataque-\(name)|" + ps.map { String(format: "%.1f° tel%.1fcm cara%.1fcm", $0.tilt, $0.phoneBack * 100, $0.faceBack * 100) }.joined(separator: " · "))
            #expect(!ps.isEmpty)
            #expect(!ps.contains(where: accepted), "el umbral dejaría pasar: \(name)")
        }
    }

    // MARK: Nunca mostrar la cámara

    @Test func ningunaVistaMuestraLaImagenDeLaCamara() throws {
        // Revisa el código de la app (en el simulador el proceso de tests puede leer el repo): ninguna capa de
        // vista previa, vista de ARKit/RealityKit ni imagen capturada llega a la pantalla.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Activate")
        let banned = ["AVCaptureVideoPreviewLayer", "ARSCNView", "ARSKView", "ARView(", "RealityView", "capturedImage",
                      "UIImagePickerController", "AVCaptureSession(", "CameraPreviewView"]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            Issue.record("No se pudo leer \(root.path)")
            return
        }
        var hits: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                for b in banned where code.contains(b) { hits.append("\(url.lastPathComponent):\(n + 1) \(b)") }
            }
        }
        print("RT|camara|scanned=\(scanned) hits=\(hits)")
        #expect(scanned > 50)
        #expect(hits.isEmpty, "\(hits)")
    }
}

// MARK: - La cara sale del encuadre en la zona atrás (dato real: la cabeza mira hacia arriba al inclinarse)

extension RedTeamExtensionTests {
    /// Encuadre que pierde la cara cuando el teléfono pasa de `limit`° de inclinación.
    private static func faceLostBeyond(_ limit: Double, _ schedule: RTSchedule) -> RTOptions {
        var options = RTOptions()
        options.faceTracked = { t in (schedule.angle(at: t)?.degrees ?? 0) < limit }
        return options
    }

    @Test(arguments: [20.0, 25.0, 35.0])
    func legitimoMirandoArribaPierdeLaCaraAtras(tilt: Double) {
        let schedule = RTSchedule(reps: RTSchedule.human(count: 8, tilt: tilt))
        let samples = render(schedule, options: Self.faceLostBeyond(14, schedule)) { deg, x in
            Body.trunk(deg, x: x, neckDeg: 20)
        }
        let run = play(samples, target: 8, name: "FN-cara-fuera-atras-\(tilt)")
        #expect(run.achieved >= 7, "FALSO NEGATIVO: \(run.summary)")
        #expect(run.hard.isEmpty, "\(run.hard)")
    }

    @Test(arguments: [20.0, 30.0, 40.0])
    func ataqueMunecasConLaCaraFueraDelEncuadre(tilt: Double) {
        let schedule = RTSchedule(reps: RTSchedule.human(count: 8, tilt: tilt))
        let samples = render(schedule, options: Self.faceLostBeyond(14, schedule)) { deg, _ in Body.wrists(deg) }
        let run = play(samples, target: 8, name: "RT-munecas-cara-fuera-\(tilt)")
        #expect(run.achieved == 0, "\(run.summary)")
    }

    @Test(arguments: [(25.0, 30.0), (30.0, 40.0)])
    func ataqueCabezaAtrasMasMunecasConLaCaraFuera(wrist: Double, neck: Double) {
        let schedule = RTSchedule(reps: RTSchedule.human(count: 8, tilt: wrist))
        let samples = render(schedule, options: Self.faceLostBeyond(14, schedule)) { deg, x in
            var p = Body.wrists(deg)
            p.face = Body.head(neck * x)
            p.headPitch = neck * x
            return p
        }
        let run = play(samples, target: 8, name: "RT-cabeza-munecas-cara-fuera-\(wrist)-\(neck)")
        #expect(run.achieved == 0, "\(run.summary)")
    }

    @Test func ataqueCabezaYTelefonoJuntosConLaCaraFuera() {
        // El conjunto cara-teléfono gira alrededor del cuello (sin tronco): el teléfono va adelante en el mundo.
        let schedule = RTSchedule(reps: RTSchedule.human(count: 8, tilt: 25))
        let samples = render(schedule, options: Self.faceLostBeyond(14, schedule)) { deg, x in Body.neckRig(deg, x: x) }
        let run = play(samples, target: 8, name: "RT-cuello-telefono-cara-fuera")
        #expect(run.achieved == 0, "\(run.summary)")
    }
}
