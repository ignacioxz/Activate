import Testing
import Foundation
import simd
@testable import Activate

// Sentadilla con el teléfono en las manos: muestras sintéticas realistas a 60 Hz (ruido de VIO ±1,5 mm,
// IMU, blendShapes, cabeceo de la cabeza, relieve TrueDepth) de `HandheldSquatSynth`. Cada caso de trampa
// reproduce lo que vería ARKit. Al final, `HandheldSquatAttackTests`: la regresión del red team (modelo
// físico del cuerpo en lazo cerrado con la consigna), con cada ataque cerrado y cada caso legítimo contando.

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

/// Fuente que declara `.live` y entrega muestras sintéticas: prueba que el runner aplica el nivel que limita
/// el verificador (en la app solo `HandheldSquatSource` declara `.live`).
@MainActor
private final class LiveDeclaredReplay: SampleSource {
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
        // La rep se mide desde que el cuerpo empieza a bajar hasta que teléfono y cara vuelven a 7 cm de la altura de pie.
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
        // La bisagra sintética adelanta la cara el doble de lo que baja: la frena el avance de la cara.
        #expect(v.diagnostics.allSatisfy { ($0.forwardExcess ?? 0) > 0 })
        // Con el tronco permitido hasta 50°, los 40° de cabeceo de esta bisagra ya no bastan por sí solos.
        withKnownIssue("Aceptado: umbral relajado por pedido del usuario (teléfono y cabeza hasta 50°): una bisagra de 40° ya no se detecta por el cabeceo") {
            #expect(v.diagnostics.allSatisfy { $0.pitchDelta > HandheldSquatTuning.torsoMaxPitchDelta })
            #expect(v.diagnostics.allSatisfy { ($0.headPitchDelta ?? 0) > HandheldSquatTuning.headMaxPitchDelta })
        }
    }

    @Test func caraPlanaEnLaTrueDepthNoCuentaYALaTerceraEsHard() {
        // Video de una cara (energía de blendShapes viva) en una pantalla pegada al teléfono: la TrueDepth ve
        // un plano. Las reps no cuentan; la 3ª rechazada deja `flatFace` hard.
        var v = HandheldSquatVerifier(target: 10)
        var samples = Synth.samples(reps: Synth.squatReps(count: 5))
        for i in samples.indices where samples[i].faceRelief != nil { samples[i].faceRelief = 0.0015 }
        let events = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        #expect(v.faceLooksFlat)
        #expect(v.diagnostics.allSatisfy { $0.rejection == .flatFace })
        #expect(anomalies(outcome, HandheldSquatAnomaly.flatFace).map(\.severity) == [.soft, .soft, .hard])
        #expect(events.contains(.cue(Cue(text: HandheldSquatCopy.lookAtScreen, symbol: "face.smiling"))))
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .suspicious)
    }

    @Test func sinProfundidadElRelieveNoDecide() {
        var options = Synth.Options()
        options.relief = false
        var v = HandheldSquatVerifier(target: 5)
        let samples = Synth.samples(reps: Synth.squatReps(count: 5), options: options)
        _ = run(&v, samples)
        let outcome = finish(&v, samples, reason: .completed)

        #expect(outcome.achieved == 5)
        #expect(!v.faceLooksFlat)
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func relieveDeUnaCaraYDeUnPlanoEnElMapaDeProfundidad() {
        // Mapa 640×480 (como la TrueDepth). Cara a 40 cm: casquete que se curva 4 cm hacia los bordes y nariz
        // que sobresale 2,5 cm; el fondo a 1,6 m queda fuera de rango. Plano: pantalla a 30 cm inclinada 25°.
        let w = 640, h = 480
        var rng = FixtureRandom(seed: 3)
        var face = [Float](repeating: 1.6, count: w * h)
        var plane = [Float](repeating: .nan, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let u = Double(x - w / 2) / 150, v = Double(y - h / 2) / 190
                let r2 = u * u + v * v
                let noise = Float(rng.symmetric(0.0015))
                if r2 <= 1 {
                    let nose = 0.025 * exp(-(u * u + v * v) / 0.02)
                    face[y * w + x] = Float(0.40 + 0.04 * r2 - nose) + noise
                }
                plane[y * w + x] = Float(0.30 + 0.30 * tan(25 * Double.pi / 180) * Double(x - w / 2) / Double(w)) + noise
            }
        }
        let faceRelief = FaceReliefEstimator.relief(width: w, height: h) { x, y in face[y * w + x] }
        let planeRelief = FaceReliefEstimator.relief(width: w, height: h) { x, y in plane[y * w + x] }
        let empty = FaceReliefEstimator.relief(width: w, height: h) { _, _ in .nan }
        #expect((faceRelief ?? 0) > Float(HandheldSquatTuning.flatFaceMaxRelief) * 1.5, "cara \(faceRelief ?? -1)")
        #expect((planeRelief ?? 1) < Float(HandheldSquatTuning.flatFaceMaxRelief) * 0.75, "plano \(planeRelief ?? -1)")
        #expect(empty == nil)
    }

    @Test func cabezaMuyAgachadaNoCalibraYPidePararseDerecho() {
        // Sentado y doblado: la cabeza mira 80° abajo, fuera del margen de calibración (70°, antes 55°). Con
        // −70° el caso quedaba justo en el umbral y solo el ruido decidía.
        var options = Synth.Options()
        options.headPitch = -80
        var v = HandheldSquatVerifier(target: 5)
        let samples = Synth.samples(reps: Synth.squatReps(count: 2), options: options)
        let events = run(&v, samples)

        #expect(!events.contains(.gate(.ready)))
        #expect(v.reference == nil)
        #expect(v.progress.hint == HandheldSquatCopy.standUp)
    }

    @Test func repsConElRespaldoBajanElNivelDeLaFuente() {
        var v = HandheldSquatVerifier(target: 10)
        #expect(v.limitedSourceLevel(.live) == .live)
        var options = Synth.Options()
        options.world = false
        options.leadInSeconds = 4.5
        let samples = Synth.samples(reps: Synth.squatReps(count: 2), options: options)
        _ = run(&v, samples)
        #expect(v.inertialReps == 2)
        #expect(v.limitedSourceLevel(.live) == .fallback)
        #expect(v.limitedSourceLevel(.replay) == .replay)
        #expect(v.limitedSourceLevel(.fallback) == .fallback)
    }

    @MainActor
    @Test func elRunnerAplicaElNivelLimitadoPorElVerificador() async {
        // Fuente "en vivo" que en realidad entrega reps sin seguimiento del mundo: el runner baja a reduced.
        var options = Synth.Options()
        options.world = false
        options.leadInSeconds = 4.5
        let samples = Synth.samples(reps: Synth.squatReps(count: 3), options: options)
        let runner = ActivityRunner(assignment: Recipes.assignment(.sentadilla, demo: true),
                                    verifier: HandheldSquatVerifier(target: 3),
                                    source: LiveDeclaredReplay(samples: samples))
        runner.start()
        for _ in 0..<400 where runner.outcome == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(runner.outcome?.achieved == 3)
        #expect(runner.level == .reduced)
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
        // Diez sentadillas "grabadas": ninguna se queda abajo cuando se pide. Sin otra señal de trampa el desafío
        // fallado no vuelve sospechosa la pausa (una persona que no lo logró no es un video), pero nunca llega a
        // full: el verificador baja la fuente a `.fallback` (reduced).
        let samples = Synth.samples(reps: Synth.squatReps(count: 10, holdAtRep: nil))
        let events = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(events.contains(.cue(SquatHoldChallenge.cue)))
        #expect(events.contains(.cue(SquatHoldChallenge.missedCue)))
        #expect(hardKinds(outcome).isEmpty, "\(outcome.anomalies)")
        #expect(anomalies(outcome, HandheldSquatAnomaly.holdChallengeFailed).map(\.severity) == [.soft])
        #expect(outcome.achieved == 8)
        #expect(v.challenge.failures == SquatHoldChallenge.maxFailures)
        #expect(!v.challenge.passed && v.challenge.isFinished && v.challengeFailed)
        #expect(v.limitedSourceLevel(.live) == .fallback)
        #expect(VerificationPolicy.level(for: outcome, source: v.limitedSourceLevel(.live), kind: .sentadilla) == .reduced)
    }

    @Test func desafioFalladoConOtraSenalDeTrampaEsHard() {
        // Un montaje que primero baja el teléfono con los brazos (armsOnly) y después pasa "sentadillas grabadas"
        // que nunca se quedan abajo: el desafío fallado más otra señal de trampa sí deja la pausa sospechosa.
        let challenge = SquatHoldChallenge(repNumber: 4)
        var v = HandheldSquatVerifier(target: 10, challenge: challenge)
        var reps = Synth.squatReps(count: 10, holdAtRep: nil)
        reps.insert(Synth.Rep(depth: 0.22, downSeconds: 1.1, holdSeconds: 0.3, upSeconds: 1.1, restSeconds: 1.0,
                              style: .armsOnly), at: 0)
        let samples = Synth.samples(reps: reps)
        _ = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(anomalies(outcome, HandheldSquatAnomaly.armsOnly).map(\.severity) == [.soft])
        #expect(hardKinds(outcome) == [HandheldSquatAnomaly.holdChallengeFailed])
        #expect(outcome.achieved == 8)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .suspicious)
    }

    @Test func unoODosFallosDelDesafioNuncaSonHard() {
        // Pedido del usuario: una pausa honesta no queda sospechosa por fallar el desafío una o dos veces. Un fallo y
        // después la pausa: full. Dos fallos: el desafío se cierra soft, las reps siguientes cuentan y el nivel queda
        // en reduced (nunca suspicious).
        for misses in [1, 2] {
            let challenge = SquatHoldChallenge(repNumber: 2)
            var v = HandheldSquatVerifier(target: 5, challenge: challenge)
            var reps = Synth.squatReps(count: 5 + misses, holdAtRep: 2 + misses)
            for i in 1..<(1 + misses) { reps[i].holdSeconds = 0.2 }
            let samples = Synth.samples(reps: reps)
            let events = run(&v, samples)
            let outcome = finish(&v, samples, reason: .completed)
            let level = VerificationPolicy.level(for: outcome, source: v.limitedSourceLevel(.live), kind: .sentadilla)

            #expect(outcome.achieved == 5, "fallos \(misses)")
            #expect(v.challenge.failures == misses)
            #expect(hardKinds(outcome).isEmpty, "fallos \(misses): \(outcome.anomalies)")
            #expect(events.filter { $0 == .cue(SquatHoldChallenge.missedCue) }.count == 1)
            if misses == 1 {
                #expect(v.challenge.passed)
                #expect(level == .full)
            } else {
                #expect(!v.challenge.passed && v.challenge.isFinished)
                #expect(anomalies(outcome, HandheldSquatAnomaly.holdChallengeFailed).map(\.severity) == [.soft])
                #expect(level == .reduced)
            }
        }
    }

    @Test func elDesafioSeVuelveAAnunciarTrasRecalibrar() {
        // Datos reales: tras perder la cara y recalibrar, el desafío seguía armado sin consigna en pantalla
        // (47 s y 9 intentos) y el siguiente intento contó como fallo. Ahora se vuelve a anunciar y, mientras esté
        // armado, la consigna queda en `progress.hint` con la barra en `progress.live`.
        let challenge = SquatHoldChallenge(repNumber: 2)
        var v = HandheldSquatVerifier(target: 3, challenge: challenge)
        var reps = Synth.squatReps(count: 3, holdAtRep: 2)
        reps[0].restSeconds = 6
        var samples = Synth.samples(reps: reps)
        // Tras la 1ª rep (termina ≈ 4,2 s) pierde la cara 2 s: bloqueo y recalibración.
        for i in samples.indices where samples[i].t >= 4.6 && samples[i].t < 6.6 { samples[i].faceTracked = false }
        v.start(at: 0)
        var events: [VerifierEvent] = []
        var liveWhileArmedReady: [Double?] = []
        for s in samples {
            events += v.ingest(s, at: s.t)
            if v.progress.gate == .ready, v.challenge.isArmed(nextRep: v.progress.count + 1) {
                liveWhileArmedReady.append(v.progress.live)
                #expect(SquatHoldChallenge.cueTexts.contains(v.progress.hint), "t=\(s.t) hint=\(v.progress.hint)")
            }
        }
        let outcome = finish(&v, samples, reason: .completed)

        #expect(events.contains(.gate(.blocked(reason: HandheldSquatCopy.keepFace))))
        #expect(events.filter { $0 == .cue(SquatHoldChallenge.cue) }.count == 2)
        #expect(!liveWhileArmedReady.isEmpty && liveWhileArmedReady.allSatisfy { $0 != nil })
        #expect(outcome.achieved == 3 && v.challenge.passed)
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func laBarraDelDesafioSeLlenaDuranteLaPausa() {
        let challenge = SquatHoldChallenge(repNumber: 2)
        var v = HandheldSquatVerifier(target: 3, challenge: challenge)
        let samples = Synth.samples(reps: Synth.squatReps(count: 3, holdAtRep: 2))
        v.start(at: 0)
        var trace: [(t: Double, live: Double?)] = []
        var doneAt: Double?
        for s in samples {
            let events = v.ingest(s, at: s.t)
            trace.append((s.t, v.progress.live))
            if doneAt == nil, events.contains(.cue(SquatHoldChallenge.doneCue)) { doneAt = s.t }
        }
        let lives = trace.compactMap(\.live)

        // Sin desafío armado (1ª rep y después de cumplirlo) no hay barra.
        #expect(trace.prefix(while: { $0.t < 3.0 }).allSatisfy { $0.live == nil })
        #expect(trace.contains { $0.live != nil } && trace.last?.live == nil)
        // Arranca vacía, sube durante la pausa y se llena justo con "Ya. Suba.".
        #expect(lives.first == 0)
        #expect(lives.max() == 1)
        if let doneAt, let full = trace.first(where: { ($0.live ?? 0) >= 1 }) {
            #expect(abs(full.t - doneAt) < 0.05)
        } else {
            Issue.record("sin \"Ya. Suba.\"")
        }
        #expect(v.challenge.passed)
    }

    @Test func elDesafioFuncionaConLaSentadillaMasCortaQueCuenta() {
        // Marco hace sentadillas cortas y lentas: el "abajo" del desafío es la zona del fondo de la meta del cuerpo
        // (no 12 cm fijos), así la sentadilla más corta que cuenta también cumple la pausa.
        #expect(HandheldSquatTuning.holdMinDescent < HandheldSquatTuning.enterDescent)
        let depth = HandheldSquatTuning.enterDescent + 0.02
        let challenge = SquatHoldChallenge(repNumber: 3)
        var reps: [Synth.Rep] = []
        for i in 0..<5 {
            let k = Double(i % 3)
            let hold = i == 2 ? 2.2 : 0.3
            reps.append(Synth.Rep(depth: depth + 0.005 * k, downSeconds: 1.6 + 0.15 * k, holdSeconds: hold,
                                  upSeconds: 1.7 - 0.1 * Double(i % 2), restSeconds: 1.2 + 0.2 * k))
        }
        var v = HandheldSquatVerifier(target: 5, challenge: challenge)
        let samples = Synth.samples(reps: reps)
        let events = run(&v, samples)
        let outcome = finish(&v, samples, reason: .completed)
        let summary: [String] = v.diagnostics.map { d in "\(d.rejection?.rawValue ?? "OK") \(d.holdSeconds)" }

        #expect(events.contains(.cue(SquatHoldChallenge.doneCue)))
        #expect(v.challenge.passed && v.challenge.failures == 0, "\(summary)")
        #expect(outcome.achieved == 5)
        #expect(hardKinds(outcome).isEmpty)
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
        // Bajo el piso de diseño (≈ 10 cm): 7 cm no cuentan y piden bajar un poco más.
        let reps = (0..<4).map { _ in Synth.Rep(depth: 0.07) }
        var v = HandheldSquatVerifier(target: 5)
        let samples = Synth.samples(reps: reps)
        let events = run(&v, samples)
        let outcome = finish(&v, samples)

        #expect(outcome.achieved == 0)
        #expect(events.contains(.cue(Cue(text: HandheldSquatCopy.lower, symbol: "arrow.down"))))
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func sentadillasDe10a90CmCuentan() {
        // Pedido del usuario ("amplía el rango de los 15 cm"): desde ≈ 10 cm hasta sentadillas profundas de 80-90 cm
        // de teléfono, lentas o rápidas.
        for (depth, down, up) in [(0.10, 2.0, 2.0), (0.12, 3.0, 3.5), (0.30, 1.2, 1.2), (0.60, 0.6, 0.7), (0.85, 0.55, 0.6)] {
            let reps = (0..<5).map { i in Synth.Rep(depth: depth, downSeconds: down + 0.05 * Double(i), holdSeconds: 0.2,
                                                    upSeconds: up - 0.04 * Double(i), restSeconds: 0.8 + 0.2 * Double(i % 3)) }
            var v = HandheldSquatVerifier(target: 5)
            let samples = Synth.samples(reps: reps)
            _ = run(&v, samples)
            let outcome = finish(&v, samples, reason: .completed)
            #expect(outcome.achieved == 5, "\(depth) m: \(v.diagnostics.compactMap(\.rejection))")
            #expect(hardKinds(outcome).isEmpty, "\(depth) m: \(outcome.anomalies)")
            #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .full)
        }
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

    @Test func todaRutaLlevaSentadillaDespuesDeLosPasos() {
        for demo in [false, true] {
            // Pararse y sentarse va entre los pasos y la sentadilla (mismo bloque en las manos), en todo momento.
            #expect(Recipes.base(.colacion3, demo: demo).kinds.prefix(3) == [.pasos, .pararseSentarse, .sentadilla])
            for moment in Moment.allCases {
                #expect(Recipes.base(moment.recipe, demo: demo).kinds.prefix(3) == [.pasos, .pararseSentarse, .sentadilla],
                        "\(moment)")
            }
        }
    }
}

// MARK: - Red team: modelo físico del cuerpo (regresión)
//
// Cada caso arma una secuencia sintética a 60 Hz con un modelo físico simple del cuerpo: cadera que baja
// y se va atrás, tronco rígido que se inclina sobre la cadera (la cara, la cabeza y, si los brazos van
// rígidos, el teléfono giran con él), brazos que pueden bajar / alejar / girar el teléfono, y un montaje
// "pegado" (foto o segundo teléfono frente a la cámara frontal). `faceInPhone` se calcula como en ARKit: la
// cara en el marco del teléfono, que rota con su cabeceo. Ruido: VIO ±1,5 mm, cara ±2 mm, cabeceo del
// teléfono ±0,4°, de la cabeza ±1°, aceleración vertical ±0,04 m/s² (derivada segunda de la trayectoria
// real), blendShapes y relieve TrueDepth (≈ 15 Hz). Lazo cerrado: antes de cada rep el "operador" mira la
// consigna y, si el desafío está armado, se queda abajo 2,2 s (un tramposo también la lee).
// Las líneas "RT|" del log resumen lo medido en cada caso (sirven para calibrar en el iPhone).

// MARK: - Modelo del cuerpo

private enum RTArms {
    /// El teléfono va fijo al tronco (antebrazos pegados al pecho): gira con la inclinación.
    case rigid
    /// El teléfono sigue a la cabeza (se mantiene donde se lo ve): no gira con el tronco.
    case headLocked
    /// Mezcla: 0 = sigue a la cabeza, 1 = rígido con el tronco.
    case blend(Double)
}

private struct RTOut {
    var phone: SIMD3<Double>
    var face: SIMD3<Double>
    var pitch: Double
    var faceTracked = true
    /// Media de `shapeEnergy` (cada frame × 0,5…1,5). nil = cara viva (0,02).
    var energy: Double? = nil
    var world = true
    var steps: Int? = nil
    /// Aceleración vertical que el IMU siente y el cuerpo no explica (ascensor).
    var extraVerticalAccel = 0.0
    var altitudeOffset = 0.0
    /// Cabeceo de la cabeza respecto de la gravedad (°, negativo = mira hacia abajo).
    var headPitch: Double? = nil
    /// Relieve TrueDepth de la cara (m): una cara real ≈ 1 cm, foto o pantalla ≈ 1,5 mm; nil = sin
    /// profundidad (sol directo, vidrio).
    var relief: Double? = 0.010
}

/// Mundo: Y arriba; la persona mira hacia −Z. Teléfono frente al pecho, cara 35 cm más arriba y 38 cm
/// más atrás; la cadera 60 cm bajo la cara.
private struct RTBody {
    var hip0 = SIMD3<Double>(0, 0.95, 0.42)
    var face0 = SIMD3<Double>(0, 1.55, 0.38)
    var phone0 = SIMD3<Double>(0, 1.20, 0)
    /// Cabeceo del teléfono de pie (pantalla hacia arriba > 0): apunta a la cara.
    var basePitch = 40.0
    /// Cabeceo de la cabeza de pie mirando el teléfono frente al pecho (°).
    var baseHeadPitch = -28.0

    static let standing = RTBody()
    /// Sentado en una silla: cadera a 50 cm del suelo.
    static let seated = RTBody(hip0: SIMD3(0, 0.50, 0.42), face0: SIMD3(0, 1.12, 0.38),
                               phone0: SIMD3(0, 0.80, 0.02), basePitch: 40)

    struct Posture {
        var hipDrop = 0.0
        var hipBack = 0.0
        /// Inclinación del tronco hacia adelante (°).
        var lean = 0.0
        var arms: RTArms = .headLocked
        /// El teléfono baja respecto de donde lo dejaría el tronco/cabeza (m).
        var armSag = 0.0
        /// El teléfono se aleja hacia adelante (m).
        var armReach = 0.0
        /// Cabeceo extra del teléfono por la muñeca (°).
        var wrist = 0.0
        /// La cara baja por flexión de cuello (m) y avanza la mitad.
        var nod = 0.0
        /// 0 = la cabeza gira con el tronco (lo natural); 1 = el cuello la mantiene derecha.
        var headComp = 0.0
        /// Traslación de todo el cuerpo (escalón, solera).
        var shift = SIMD3<Double>(repeating: 0)
    }

    /// Rotación "hacia adelante" (hacia −Z) de un vector anclado en la cadera.
    static func forward(_ v: SIMD3<Double>, _ degrees: Double) -> SIMD3<Double> {
        let a = degrees * .pi / 180
        return SIMD3(v.x, v.y * cos(a) + v.z * sin(a), -v.y * sin(a) + v.z * cos(a))
    }

    func pose(_ p: Posture) -> RTOut {
        let hip = hip0 + SIMD3(0, -p.hipDrop, p.hipBack) + p.shift
        var face = hip + Self.forward(face0 - hip0, p.lean)
        var phone: SIMD3<Double>
        var pitch: Double
        switch p.arms {
        case .rigid:
            phone = hip + Self.forward(phone0 - hip0, p.lean)
            pitch = basePitch + p.lean
        case .headLocked:
            phone = face - (face0 - phone0)
            pitch = basePitch
        case .blend(let k):
            let rigid = hip + Self.forward(phone0 - hip0, p.lean)
            let locked = face - (face0 - phone0)
            phone = locked + k * (rigid - locked)
            pitch = basePitch + k * p.lean
        }
        pitch += p.wrist
        phone += SIMD3(0, -p.armSag, -p.armReach)
        face += SIMD3(0, -p.nod, -0.5 * p.nod)
        var out = RTOut(phone: phone, face: face, pitch: pitch)
        // La cabeza gira con el tronco (salvo que el cuello compense) y cabecea al agachar la cara (radio ≈ 12 cm).
        out.headPitch = baseHeadPitch - p.lean * (1 - p.headComp) - p.nod / 0.12 * 180 / .pi
        return out
    }
}

/// Cara en el espacio de la cámara frontal de ARKit (`camera⁻¹ · face`, espejado, como lo graba el iPhone 17 Pro
/// Max): x hacia el borde inferior del teléfono, y hacia la derecha de la pantalla, z hacia adentro (la cara queda
/// en −z), con el teléfono cabeceado `pitch` grados (pantalla hacia arriba > 0) y sin giro.
private func rtFaceInPhone(face: SIMD3<Double>, phone: SIMD3<Double>, pitch: Double) -> SIMD3<Double> {
    let v = face - phone
    let a = pitch * .pi / 180
    // Borde superior del teléfono en el mundo (0, cos a, −sin a); normal de la pantalla (0, sin a, cos a).
    return SIMD3(-(v.y * cos(a) - v.z * sin(a)), v.x, -(v.y * sin(a) + v.z * cos(a)))
}

/// Montaje pegado (foto o segundo teléfono) a `distance` m frente a la cámara frontal: la "cara" va a lo
/// largo de la normal de la pantalla y se mueve rígida con el teléfono.
private func rtGluedFace(phone: SIMD3<Double>, pitch: Double, distance: Double = 0.30) -> SIMD3<Double> {
    let a = pitch * .pi / 180
    return phone + SIMD3(0, distance * sin(a), distance * cos(a))
}

// MARK: - Simulación en lazo cerrado

private struct RTRep {
    var down = 1.2
    var hold = 0.25
    var up = 1.1
    var rest = 1.0
}

private struct RTFrame {
    var t: Double
    /// 0 arriba … 1 abajo (perfil de mínimo jerk).
    var x = 0.0
    var rep: Int? = nil
    var holding = false
    /// Segundos desde el inicio de la rep en curso.
    var local = 0.0
    var down = 0.0
    /// Duración de la pausa abajo de esta rep.
    var hold = 0.0
    /// Segundos que lleva (o llevó) la pausa abajo en esta rep.
    var holdElapsed = 0.0
    /// Reps terminadas.
    var done = 0
    var untilNext: Double? = nil
    var sinceLastRep: Double? = nil
}

private struct RTScenario {
    var name: String
    var seed: UInt64 = 1
    var fps = 60.0
    var leadIn = 2.0
    var trail = 1.5
    var repCount = 10
    var target = 10
    var challengeRep = 3
    var holdWhenArmed = 2.2
    var maxSeconds = 240.0
    var accelBias = 0.0
    var positionNoise = 0.0015
    var faceNoise = 0.002
    var worldTrackingSupported = true
    /// Con el mundo en `limited`, ARKit sigue entregando poses (con deriva). false = basura (tapada).
    var limitedKeepsPoses = false
    var timing: (Int) -> RTRep = RTScenario.human
    var body: (RTFrame) -> RTOut

    /// Duraciones variadas de una persona (no es un metrónomo).
    static func human(_ i: Int) -> RTRep {
        let k = i % HandheldSquatSynth.downVariation.count
        return RTRep(down: HandheldSquatSynth.downVariation[k], hold: 0.25,
                     up: HandheldSquatSynth.upVariation[k], rest: HandheldSquatSynth.restVariation[k])
    }

    /// Descenso de cadera variado (19-24 cm).
    static func depth(_ i: Int) -> Double {
        HandheldSquatSynth.depthVariation[i % HandheldSquatSynth.depthVariation.count] - 0.02
    }
}

private struct RTResult {
    var verifier: HandheldSquatVerifier
    var outcome: ActivityOutcome
    var events: [VerifierEvent]
    var samples: [HandheldSquatSample]
    var sourceLevel: SourceLevel
    var level: VerificationLevel
    var normalFraction: Double

    var achieved: Int { outcome.achieved }
    var hard: [String] { outcome.anomalies.filter { $0.severity == .hard }.map(\.kind) }
    var soft: [String] { outcome.anomalies.filter { $0.severity == .soft }.map(\.kind) }
    var rejections: [String] { verifier.diagnostics.compactMap { $0.rejection?.rawValue } }

    func diag() -> String {
        verifier.diagnostics.map { d in
            String(format: "[%@ ph%.0f body%.0f fa%@ gap%.1f geo%.1f pit%.0f head%@ fwd%@ back%@ hold%.1f e%.4f flat%.1f s%.1f]",
                   d.rejection?.rawValue ?? "OK", d.phoneDescent * 100, d.bodyDescent * 100,
                   d.maxFaceDescent.map { String(format: "%.0f", $0 * 100) } ?? "-",
                   d.maxGap * 100, d.geometryChange * 100, d.pitchDelta,
                   d.headPitchDelta.map { String(format: "%.0f", $0) } ?? "-",
                   d.forwardExcess.map { String(format: "%.1f", $0 * 100) } ?? "-",
                   d.backwardShift.map { String(format: "%.1f", $0 * 100) } ?? "-",
                   d.holdSeconds, d.meanEnergy, d.flatFraction, d.seconds)
        }.joined(separator: " ")
    }
}

@discardableResult
private func simulate(_ sc: RTScenario) -> RTResult {
    var rng = FixtureRandom(seed: sc.seed &* 7919 &+ 17)
    var v = HandheldSquatVerifier(target: sc.target, challenge: SquatHoldChallenge(repNumber: sc.challengeRep))
    v.start(at: 0)
    let dt = 1 / sc.fps
    let g = 9.80665
    var events: [VerifierEvent] = []
    var samples: [HandheldSquatSample] = []
    var started = 0
    var current: (start: Double, rep: RTRep, index: Int)?
    var nextStart = sc.leadIn
    var lastEnd: Double?
    var endT: Double?
    var history: [SIMD3<Double>] = []
    var rmsWindow: [(t: Double, m2: Double)] = []
    var altitude: Double?
    var nextAltitudeAt = 0.0
    var i = 0

    func jitter(_ p: SIMD3<Double>, _ n: Double, _ rng: inout FixtureRandom) -> SIMD3<Double> {
        p + SIMD3(rng.symmetric(n), rng.symmetric(n), rng.symmetric(n))
    }

    while true {
        let t = Double(i) * dt
        if let endT, t > endT { break }
        if t > sc.maxSeconds { break }

        // El operador lee la consigna antes de empezar cada rep.
        if current == nil, started < sc.repCount, t >= nextStart {
            var rep = sc.timing(started)
            if v.challenge.isArmed(nextRep: v.progress.count + 1) { rep.hold = max(rep.hold, sc.holdWhenArmed) }
            current = (t, rep, started)
            started += 1
        }
        var frame = RTFrame(t: t)
        if let c = current {
            let local = t - c.start
            let r = c.rep
            frame.rep = c.index
            frame.local = local
            frame.down = r.down
            frame.hold = r.hold
            if local < r.down {
                frame.x = HandheldSquatSynth.minJerk(local / r.down)
            } else if local < r.down + r.hold {
                frame.x = 1
                frame.holding = true
                frame.holdElapsed = local - r.down
            } else if local < r.down + r.hold + r.up {
                frame.x = 1 - HandheldSquatSynth.minJerk((local - r.down - r.hold) / r.up)
                frame.holdElapsed = r.hold
            } else {
                frame.rep = nil
                current = nil
                lastEnd = t
                nextStart = t + r.rest
            }
        }
        frame.done = started - (current == nil ? 0 : 1)
        if current == nil {
            if started < sc.repCount { frame.untilNext = nextStart - t }
            frame.sinceLastRep = lastEnd.map { t - $0 }
            if started >= sc.repCount, endT == nil { endT = max(t, sc.leadIn) + sc.trail }
        }

        let o = sc.body(frame)

        // IMU: derivada segunda de la trayectoria real del teléfono (+ lo que el cuerpo no explica).
        history.append(o.phone)
        if history.count > 3 { history.removeFirst() }
        var a = SIMD3<Double>(repeating: 0)
        if history.count == 3 { a = (history[2] - 2 * history[1] + history[0]) / (dt * dt) }
        a.y += o.extraVerticalAccel
        rmsWindow.append((t, simd_length_squared(a) / (g * g)))
        while let first = rmsWindow.first, first.t < t - 0.5 { rmsWindow.removeFirst() }
        let meanSquare = rmsWindow.reduce(0) { $0 + $1.m2 } / Double(rmsWindow.count)
        let rms = (0.02 * 0.02 + meanSquare).squareRoot()
        let vertical = a.y + sc.accelBias + rng.symmetric(0.04)

        if t >= nextAltitudeAt {
            nextAltitudeAt = t + 1
            altitude = (o.phone.y - 1.2) + o.altitudeOffset + rng.symmetric(0.05)
        }

        let tracked = o.faceTracked
        // La TrueDepth entrega profundidad ≈ 15 Hz (1 de cada 4 frames).
        let relief: Float? = tracked && i % 4 == 0 ? o.relief.map { Float($0 * (0.7 + 0.6 * rng.unit())) } : nil
        let head: Double? = tracked ? o.headPitch.map { $0 + rng.symmetric(1.0) } : nil
        let posesValid = o.world || sc.limitedKeepsPoses
        let phonePos = posesValid ? jitter(o.phone, sc.positionNoise, &rng)
                                  : SIMD3(rng.symmetric(0.3), rng.symmetric(0.3), rng.symmetric(0.3))
        let facePos: SIMD3<Double>
        let fip: SIMD3<Double>
        let energy: Float
        if tracked {
            facePos = posesValid ? jitter(o.face, sc.faceNoise, &rng) : jitter(SIMD3(0, 0, -0.45), sc.faceNoise, &rng)
            fip = jitter(rtFaceInPhone(face: o.face, phone: o.phone, pitch: o.pitch), sc.faceNoise, &rng)
            energy = Float((o.energy ?? 0.02) * (0.5 + rng.unit()))
        } else {
            facePos = .zero
            fip = .zero
            energy = 0
        }
        let s = HandheldSquatSample(
            t: t,
            phonePos: SIMD3<Float>(phonePos),
            phonePitchDeg: o.pitch + rng.symmetric(0.4),
            phoneRollDeg: rng.symmetric(0.5),
            faceTracked: tracked,
            facePos: SIMD3<Float>(facePos),
            faceInPhone: SIMD3<Float>(fip),
            shapeEnergy: energy,
            worldTrackingNormal: o.world,
            altitude: altitude,
            userAccelRMS: rms,
            verticalAccel: vertical,
            steps: o.steps,
            headPitchDeg: head,
            faceRelief: relief)
        events += v.ingest(s, at: t)
        samples.append(s)
        i += 1
    }

    let lastT = samples.last?.t ?? 0
    let outcome = v.finish(at: lastT, reason: v.progress.count >= sc.target ? .completed : .timeout)
    // Estadística de la fuente tal como la arma `HandheldSquatRelay`.
    var stats = HandheldSquatSourcePolicy.Stats()
    for s in samples {
        if s.worldTrackingNormal { stats.everNormal = true }
        if stats.everNormal, s.faceTracked {
            stats.countedFrames += 1
            if s.worldTrackingNormal { stats.normalFrames += 1 }
        }
    }
    // Igual que `ActivityRunner`: el verificador solo puede bajar `.live` a `.fallback` (reps con el respaldo IMU).
    let declared = HandheldSquatSourcePolicy.level(worldTrackingSupported: sc.worldTrackingSupported, stats: stats)
    let source: SourceLevel = declared == .live && v.limitedSourceLevel(declared) == .fallback ? .fallback : declared
    let level = VerificationPolicy.level(for: outcome, source: source, kind: .sentadilla)
    let fraction = stats.countedFrames > 0 ? Double(stats.normalFrames) / Double(stats.countedFrames) : 0
    let result = RTResult(verifier: v, outcome: outcome, events: events, samples: samples, sourceLevel: source,
                          level: level, normalFraction: fraction)
    print("RT| \(sc.name) | achieved=\(result.achieved)/\(sc.repCount) target=\(sc.target) level=\(level) source=\(source) "
          + "hard=\(result.hard) soft=\(result.soft) mode=\(v.mode) gate=\(v.progress.gate) | \(result.diag())")
    return result
}

// MARK: - Escenarios base

/// Sentadilla real: la cadera baja 19-24 cm y se va atrás, el tronco se inclina `lean`° al fondo.
private func realSquat(lean: Double = 8, arms: RTArms = .headLocked, body: RTBody = .standing,
                       tweak: @escaping (RTFrame, inout RTBody.Posture) -> Void = { _, _ in }) -> (RTFrame) -> RTOut {
    { f in
        var p = RTBody.Posture()
        p.arms = arms
        let d = RTScenario.depth(f.rep ?? 0)
        p.hipDrop = d * f.x
        p.hipBack = 0.08 * f.x
        p.lean = lean * f.x
        tweak(f, &p)
        return body.pose(p)
    }
}

/// Montaje pegado (sin doblar rodillas): el tramposo baja con los brazos el teléfono y, 30 cm frente a la
/// cámara frontal, una foto o un segundo teléfono con un video de una cara. `relief` = lo que ve la
/// TrueDepth (un plano ≈ 1,5 mm; nil = sin profundidad, p. ej. vidrio que no devuelve el patrón).
private func gluedRig(name: String, energy: Double, relief: Double? = 0.0015) -> RTScenario {
    RTScenario(name: name, body: { f in
        let drop = RTScenario.depth(f.rep ?? 0) + 0.01
        let pitch = 10 + 2.5 * sin(f.t * 1.7)
        let phone = SIMD3<Double>(0.01 * sin(f.t * 0.9), 1.20 - drop * f.x, -0.02 * f.x)
        var o = RTOut(phone: phone, face: rtGluedFace(phone: phone, pitch: pitch), pitch: pitch)
        o.energy = energy
        o.relief = relief
        // La "cara" mira de vuelta a la cámara frontal: su cabeceo es el opuesto al del teléfono.
        o.headPitch = -pitch
        return o
    })
}

/// Bisagra de cintura con rodillas casi rectas (tipo peso muerto rumano), teléfono frente a la cara.
private func hinge(lean: Double = 45, knees: Double = 0.02, hipBack: Double = 0.10, headComp: Double = 0,
                   world: Bool = true) -> (RTFrame) -> RTOut {
    { f in
        var p = RTBody.Posture()
        p.lean = lean * f.x
        p.hipDrop = knees * f.x
        p.hipBack = hipBack * f.x
        p.headComp = headComp
        var o = RTBody.standing.pose(p)
        o.world = world
        return o
    }
}

// MARK: - Ataques y casos legítimos (regresión del red team)

/// Cada caso es una secuencia sintética a 60 Hz de un modelo físico del cuerpo (ver arriba) en lazo
/// cerrado con la consigna. Ataque = no cuenta (o no llega a `full`); caso legítimo = cuenta. Lo que sigue
/// abierto va en `withKnownIssue` con la razón (y está en el informe de endurecimiento).
struct HandheldSquatAttackTests {

    // MARK: Control (valida el modelo)

    @Test func control_sentadillaRealConTelefonoFrenteALaCaraCuentaFull() {
        let r = simulate(RTScenario(name: "control real headLocked lean8", body: realSquat()))
        #expect(r.achieved == 10)
        #expect(r.hard.isEmpty)
        #expect(r.level == .full)
    }

    @Test func control_sentadillaRealConBrazosRigidosYPocaInclinacionCuenta() {
        let r = simulate(RTScenario(name: "control real rigid lean6", body: realSquat(lean: 6, arms: .rigid)))
        #expect(r.achieved == 10)
        #expect(r.level == .full)
    }

    // MARK: Brazos

    @Test func ataque_soloBrazosConCabeceoDeCuello() {
        // De pie, sin doblar rodillas: baja el teléfono 20 cm con los brazos, inclina la muñeca para seguir
        // viéndolo y agacha la cabeza (la cara baja 3 cm).
        let r = simulate(RTScenario(name: "A1 brazos + cuello", body: { f in
            var p = RTBody.Posture()
            p.armSag = 0.20 * f.x
            p.wrist = 12 * f.x
            p.nod = 0.03 * f.x
            return RTBody.standing.pose(p)
        }))
        #expect(r.achieved == 0)
        #expect(r.hard.contains(HandheldSquatAnomaly.armsOnly))
    }

    @Test func ataque_mediaSentadilla5cmRapidaMasBrazos() {
        let r = simulate(RTScenario(name: "A3 5cm + brazos rapido",
                                    timing: { i in RTRep(down: 0.45 + 0.05 * Double(i % 3), hold: 0.05,
                                                         up: 0.45 + 0.04 * Double(i % 2), rest: 0.25 + 0.05 * Double(i % 4)) },
                                    body: { f in
            var p = RTBody.Posture()
            p.hipDrop = 0.05 * f.x
            p.armSag = 0.14 * f.x
            return RTBody.standing.pose(p)
        }))
        #expect(r.achieved == 0)
    }

    @Test func ataque_cuartoDeSentadilla11cmMasBrazos() {
        // La meta del cuerpo es 9 cm (sentadillas desde 10 cm, pedido del usuario): una sentadilla de 11 cm con los
        // brazos bajando 7,5 cm más cuenta, porque la cara de verdad bajó 11 cm. El ataque es el cuarto de sentadilla
        // de 6-6,5 cm (la cara baja ≈ 7 cm) más los brazos: se cuenta con el cuerpo, no llega y pide bajar más.
        let r = simulate(RTScenario(name: "A3b 6.5cm + brazos 7.5", body: { f in
            var p = RTBody.Posture()
            p.hipDrop = (0.06 + 0.005 * Double((f.rep ?? 0) % 2)) * f.x
            p.lean = 4 * f.x
            p.armSag = 0.075 * f.x
            return RTBody.standing.pose(p)
        }))
        #expect(r.achieved == 0)
        #expect(r.events.contains(.cue(Cue(text: HandheldSquatCopy.lower, symbol: "arrow.down"))))
    }

    @Test func ataque_oscilarEnUnCuartoDeSentadilla() {
        // Con la meta baja (9 cm), quedarse en un cuarto de sentadilla y oscilar entre 6,5 y 11 cm cruza la meta y
        // vuelve bajo los 7 cm: el recorrido de cada "rep" (≤ 5 cm) no llega a los 8 cm mínimos. Solo la primera
        // bajada desde de pie (0 → 10,5 cm) es una media sentadilla de verdad y puede contar.
        let r = simulate(RTScenario(name: "A3e oscilar 6.5-11cm", leadIn: 4.0,
                                    timing: { i in RTRep(down: 0.7 + 0.08 * Double(i % 3), hold: 0.15,
                                                         up: 0.7 + 0.06 * Double(i % 2), rest: 0.3 + 0.1 * Double(i % 3)) },
                                    body: { f in
            var p = RTBody.Posture()
            guard f.t >= 2.0 else { return RTBody.standing.pose(p) }
            let enter = HandheldSquatSynth.minJerk((f.t - 2.0) / 1.5)
            p.hipDrop = 0.06 * enter + 0.045 * f.x
            return RTBody.standing.pose(p)
        }))
        #expect(r.achieved <= 1)
        #expect(r.rejections.filter { $0 == HandheldSquatVerifier.Rejection.shallow.rawValue }.count >= 8, "\(r.rejections)")
    }

    @Test func ataque_isometricoMasBombeoDeBrazos() {
        // Se calibra de pie, baja a un cuarto de sentadilla (cara a 11,5 cm) y se QUEDA ahí: solo los brazos
        // bombean el teléfono entre 4,5 y 19 cm bajo la referencia. El cuerpo no llega a la meta ni vuelve.
        let squatDrop = 0.115
        let r = simulate(RTScenario(name: "A3c isometrico + bombeo", leadIn: 4.0,
                                    timing: { i in RTRep(down: 0.55 + 0.07 * Double(i % 3), hold: 0.1,
                                                         up: 0.5 + 0.08 * Double(i % 4), rest: 0.25 + 0.1 * Double(i % 3)) },
                                    body: { f in
            var p = RTBody.Posture()
            if f.t < 2.0 {
                return RTBody.standing.pose(p)
            }
            let enter = HandheldSquatSynth.minJerk((f.t - 2.0) / 1.5)
            p.hipDrop = squatDrop * enter
            p.lean = 4 * enter
            p.armSag = -0.07 * enter + 0.14 * f.x
            return RTBody.standing.pose(p)
        }))
        #expect(r.achieved == 0)
    }

    @Test func ataque_minisentadillasAbajoMasBombeoDeBrazos() {
        // Variante: abajo hace mini-sentadillas de 6 cm (la cara va de 12 a 19 cm) y los brazos completan el
        // recorrido del teléfono. Para salir de la rep la CARA también debe volver arriba: no cuenta.
        let r = simulate(RTScenario(name: "A3d minisentadillas abajo + brazos", leadIn: 4.0,
                                    timing: { i in RTRep(down: 0.7 + 0.08 * Double(i % 3), hold: 0.15,
                                                         up: 0.7 + 0.06 * Double(i % 2), rest: 0.3 + 0.1 * Double(i % 3)) },
                                    body: { f in
            var p = RTBody.Posture()
            guard f.t >= 2.0 else { return RTBody.standing.pose(p) }
            let enter = HandheldSquatSynth.minJerk((f.t - 2.0) / 1.5)
            p.hipDrop = 0.12 * enter + 0.07 * f.x
            p.armSag = -0.08 * enter + 0.14 * f.x
            return RTBody.standing.pose(p)
        }))
        #expect(r.achieved == 0)
    }

    // MARK: Inclinarse / sentarse

    @Test func ataque_bisagraRodillasRectasBrazosRigidos() {
        let r = simulate(RTScenario(name: "A2 bisagra rigida", body: { f in
            var p = RTBody.Posture()
            p.arms = .rigid
            p.lean = 45 * f.x
            p.hipBack = 0.15 * f.x
            return RTBody.standing.pose(p)
        }))
        #expect(r.achieved == 0)
    }

    @Test func ataque_bisagraConCaderaAtrasYTelefonoFrenteALaCara() {
        // Tronco a 45°, rodillas casi rectas, cadera atrás 14-22 cm, el teléfono sigue a la cara. Lo frenan el
        // cabeceo de la cabeza (gira con el tronco) y el avance de la cara respecto de lo que baja.
        var table: [String] = []
        var worst = 0
        for knees in [0.02, 0.04] {
            for back in [0.14, 0.18, 0.22] {
                let r = simulate(RTScenario(name: "A2b bisagra RDL knees=\(knees) back=\(back)",
                                            body: hinge(knees: knees, hipBack: back)))
                table.append("rodillas \(Int(knees * 100)) cm, cadera atrás \(Int(back * 100)) cm → \(r.achieved) \(r.level)")
                worst = max(worst, r.achieved)
            }
        }
        print("RT| A2b tabla: \(table)")
        // Con 45° la cabeza cabecea 44-45° (< 50°) y, con la cadera ≥ 18 cm atrás, la cara avanza menos que lo que
        // permite lo que baja. Lo frena la bisagra (`HingeModel`): girar el tronco 45° sobre la cadera explica ≈ 19 cm
        // de los 22-24 cm que baja la cara; las rodillas aportan 2-4 cm (< 40 %).
        #expect(worst == 0)
        // Con el cuello compensando (la cabeza gira 27° mientras el tronco gira 45°) y la cadera 22 cm atrás, la cara
        // baja 22 cm y avanza 19: la misma trayectoria de cara y cabeza que una sentadilla de 15 cm con el tronco a 25°.
        let neck = simulate(RTScenario(name: "A2c bisagra con cuello compensando", body: hinge(hipBack: 0.22, headComp: 0.4)))
        withKnownIssue("Residuo físicamente indistinguible: bisagra de 45° con el cuello compensando = sentadilla corta e inclinada (sin ver las piernas)") {
            #expect(neck.achieved == 0)
        }
        // Bisagra marcada (tronco a 60°, la cabeza gira con él): el cabeceo pasa los 50° y no cuenta.
        var marked: [String] = []
        var markedWorst = 0
        for knees in [0.02, 0.04] {
            for back in [0.14, 0.18, 0.22] {
                let r = simulate(RTScenario(name: "A2e bisagra marcada 60° knees=\(knees) back=\(back)",
                                            body: hinge(lean: 60, knees: knees, hipBack: back)))
                marked.append("rodillas \(Int(knees * 100)) cm, cadera atrás \(Int(back * 100)) cm → \(r.achieved) \(r.level)")
                markedWorst = max(markedWorst, r.achieved)
                #expect(r.rejections.allSatisfy { $0 == HandheldSquatVerifier.Rejection.torsoBend.rawValue })
            }
        }
        print("RT| A2e tabla: \(marked)")
        #expect(markedWorst == 0)
    }

    @Test func limite_bisagraExtremaConCaderaMuyAtrasYCuelloCompensando() {
        // Residual documentado: cadera 30 cm atrás (el arco de la cara queda casi vertical) Y el cuello
        // extendido para mantener la cabeza derecha. Sin ver las rodillas no hay cómo separarlo.
        let r = simulate(RTScenario(name: "A2d bisagra extrema", body: hinge(hipBack: 0.30, headComp: 0.4)))
        withKnownIssue("Residuo físicamente indistinguible: bisagra con cadera 30 cm atrás y cuello compensando, la cabeza baja casi vertical como en una sentadilla") {
            #expect(r.achieved == 0)
        }
    }

    @Test func ataque_sentadoPartiendoErguido() {
        let r = simulate(RTScenario(name: "A9a sentado erguido → 45°", body: { f in
            var p = RTBody.Posture()
            p.lean = 45 * f.x
            return RTBody.seated.pose(p)
        }))
        #expect(r.achieved == 0)
    }

    @Test func ataque_sentadoPartiendoInclinadoYBalanceandoElTronco() {
        // Ataque real de la cabina: sentado, calibra ya inclinado 40° y balancea el tronco a 66°. Con la cabeza girando
        // con el tronco mira 68° abajo: fuera del margen de calibración (60°; real de pie −23..+11°, con lentes −45°),
        // no calibra y pide pararse derecho.
        let r = simulate(RTScenario(name: "A9b sentado 40°→66°", body: { f in
            var p = RTBody.Posture()
            p.lean = 40 + 26 * f.x
            return RTBody.seated.pose(p)
        }))
        #expect(r.achieved == 0)
        #expect(r.verifier.reference == nil)
        #expect(r.verifier.progress.hint == HandheldSquatCopy.standUp)
        // Sentado más doblado (45°, la cabeza mira 73° abajo): no calibra ("Párese derecho y mire el teléfono").
        let marked = simulate(RTScenario(name: "A9b2 sentado 45°→71°", body: { f in
            var p = RTBody.Posture()
            p.lean = 45 + 26 * f.x
            return RTBody.seated.pose(p)
        }))
        #expect(marked.achieved == 0)
        #expect(marked.verifier.reference == nil)
        #expect(marked.verifier.progress.hint == HandheldSquatCopy.standUp)
    }

    @Test func ataque_calibraDePieYDespuesSeSientaABalancearse() {
        // Calibra de pie y se sienta: la referencia no se re-ancla sentado y doblado (cabeza muy abajo), así
        // que la serie queda abajo sin volver y no cuenta nada.
        func sitting(_ lean: Double) -> (RTFrame) -> RTOut {
            { f in
                var p = RTBody.Posture()
                guard f.t >= 2.5 else { return RTBody.standing.pose(p) }
                let sit = HandheldSquatSynth.minJerk((f.t - 2.5) / 1.5)
                p.lean = (lean + 26 * f.x) * sit
                let seated = RTBody.seated.pose(p)
                let standing = RTBody.standing.pose(p)
                var o = seated
                o.phone = standing.phone + (seated.phone - standing.phone) * sit
                o.face = standing.face + (seated.face - standing.face) * sit
                return o
            }
        }
        // Sentarse baja la cara 45-50 cm y la adelanta ≈ 20 cm: no es "otro lugar de pie" (la escalera y la solera la
        // adelantan más de lo que la bajan) y la cabeza mira 20-40° más abajo que al calibrar: no se re-ancla y el
        // balanceo no cuenta.
        for lean in [20.0, 30, 40] {
            let r = simulate(RTScenario(name: "A9e de pie → sentado \(Int(lean))°→\(Int(lean) + 26)°", leadIn: 6, body: sitting(lean)))
            #expect(r.achieved == 0, "\(lean)°")
            #expect(r.verifier.reanchorCount == 0, "\(lean)°")
        }
        // Sentado más doblado (45°, cabeza a 73°): no se re-ancla y no cuenta nada.
        let marked = simulate(RTScenario(name: "A9e2 de pie → sentado 45°→71°", leadIn: 6, body: sitting(45)))
        #expect(marked.achieved == 0)
        #expect(marked.verifier.reanchorCount == 0)
    }

    @Test func limite_sentadoInclinadoConElCuelloExtendido() {
        // Residual documentado: el mismo balanceo sentado, pero extendiendo el cuello para calibrar con la
        // cabeza "derecha" (−40°) y mantenerla así: el arco de 40° a 66° baja la cara más de lo que la adelanta.
        let r = simulate(RTScenario(name: "A9f sentado con cuello extendido", body: { f in
            var p = RTBody.Posture()
            p.lean = 40 + 26 * f.x
            p.headComp = 0.7
            return RTBody.seated.pose(p)
        }))
        withKnownIssue("Residuo físicamente indistinguible: sentado ya inclinado con el cuello extendido (la cabeza gira 8° mientras el tronco gira 26°), sin ver las piernas el arco es el de una sentadilla corta") {
            #expect(r.achieved == 0)
        }
    }

    // MARK: Cara falsa pegada al teléfono

    @Test func ataque_fotoImpresaPegada() {
        let r = simulate(gluedRig(name: "A4a foto pegada", energy: 0.0002))
        #expect(r.achieved == 0)
        #expect(r.hard.contains(HandheldSquatAnomaly.staticFace))
    }

    @Test func ataque_fotoPegadaConRuidoDeBlendShapesDeARKit() {
        // Si ARKit sigue la foto, sus blendShapes tiemblan (energía 0,0035 > umbral): la TrueDepth ve un plano.
        let r = simulate(gluedRig(name: "A4b foto con jitter 0.0035", energy: 0.0035))
        #expect(r.achieved == 0)
        #expect(r.hard.contains(HandheldSquatAnomaly.flatFace))
        #expect(r.level == .suspicious)
    }

    @Test func ataque_videoDeUnaCaraEnOtroTelefonoPegado() {
        let r = simulate(gluedRig(name: "A4c video pegado", energy: 0.015))
        #expect(r.achieved == 0)
        #expect(r.level != .full)
        #expect(r.rejections.allSatisfy { $0 == HandheldSquatVerifier.Rejection.flatFace.rawValue })
    }

    @Test func limite_videoPegadoSinProfundidadUtilizable() {
        // Residual documentado: si la TrueDepth no devuelve profundidad (vidrio que no refleja el patrón, sol
        // directo), el relieve no decide y el montaje con video pasa. Pendiente medirlo en el iPhone.
        let r = simulate(gluedRig(name: "A4d video pegado sin profundidad", energy: 0.015, relief: nil))
        withKnownIssue("Sin mapa de profundidad no hay prueba de relieve: el video pegado cuenta si alguien lo pausa cuando aparece \"Quédese abajo\"") {
            #expect(r.achieved == 0)
        }
        // Un video que corre solo no sigue la consigna: falla el desafío y nunca llega a full (queda en reduced).
        var unattended = gluedRig(name: "A4e video pegado sin profundidad que no sigue la consigna", energy: 0.015, relief: nil)
        unattended.holdWhenArmed = 0.02
        let alone = simulate(unattended)
        #expect(alone.verifier.challengeFailed)
        #expect(alone.level != .full, "\(alone.level)")
    }

    @Test func ataque_sacudirElMontajeConVideo() {
        let r = simulate(RTScenario(name: "A5 sacudir montaje",
                                    timing: { i in RTRep(down: 0.3 + 0.03 * Double(i % 3), hold: 0.02,
                                                         up: 0.3 + 0.02 * Double(i % 2), rest: 0.08) },
                                    body: { f in
            let phone = SIMD3<Double>(0, 1.20 - 0.24 * f.x, 0)
            var o = RTOut(phone: phone, face: rtGluedFace(phone: phone, pitch: 10), pitch: 10)
            o.energy = 0.015
            o.headPitch = -10
            return o
        }))
        #expect(r.achieved == 0)
        #expect(r.level == .suspicious)
    }

    @Test func limite_ritmoLentoSinPausaCumpleElDesafio() {
        // Residual documentado: un movimiento lento y continuo pasa por el fondo más de 1,5 s dentro de 3 cm
        // y cumple "Quédese abajo 2 segundos". Endurecerlo castiga al operador que se hunde despacio en la
        // pausa (ver fp_pausaDelDesafioConHundimientoLento). El montaje con video lo frena el relieve.
        var sc = RTScenario(name: "A11 lento sin pausa",
                            timing: { i in RTRep(down: 2.6 + 0.25 * Double(i % 3), hold: 0.2,
                                                 up: 2.7 + 0.2 * Double(i % 2), rest: 0.8 + 0.4 * Double(i % 3)) },
                            body: realSquat())
        sc.holdWhenArmed = 0.2
        let r = simulate(sc)
        withKnownIssue("El desafío mide permanencia en una banda: un paso lento por el fondo cuenta como pausa") {
            #expect(r.verifier.challenge.passed == false)
        }
    }

    // MARK: Escalón, escalera, ascensor, cámara trasera tapada

    @Test func ataque_bajarYSubirUnEscalonHaciaAtras() {
        // Parado en un escalón de 20 cm: baja de espaldas al piso y vuelve a subir. La cara se va hacia atrás
        // (lejos del teléfono): una sentadilla no hace eso → `moved`.
        func step(back: Double, name: String) -> RTResult {
            simulate(RTScenario(name: name,
                                timing: { i in RTRep(down: 0.9 + 0.1 * Double(i % 3), hold: 0.4,
                                                     up: 1.0 + 0.1 * Double(i % 2), rest: 1.0 + 0.2 * Double(i % 3)) },
                                body: { f in
                var p = RTBody.Posture()
                let bob = 0.012 * sin(2 * .pi * f.x)
                p.shift = SIMD3(0, -0.20 * f.x + bob, back * f.x)
                var o = RTBody.standing.pose(p)
                o.steps = 4 * f.done + (f.rep != nil && f.x > 0.5 ? 2 : 0)
                return o
            }))
        }
        // Medido desde el ancla de la rep (no desde la calibración), la cara puede irse ≤ 12 cm atrás (real ≤ 6 cm):
        // un escalón de 18 cm hacia atrás es `moved`.
        let r = step(back: 0.18, name: "A7 escalon atras 18cm")
        #expect(r.achieved == 0)
        #expect(r.rejections.allSatisfy { $0 == HandheldSquatVerifier.Rejection.moved.rawValue }, "\(r.rejections)")
        // Escalón con huella real (la cara se va 24 cm atrás): sigue siendo `moved`.
        let deep = step(back: 0.24, name: "A7d escalon atras 24cm")
        #expect(deep.achieved == 0)
        #expect(deep.rejections.allSatisfy { $0 == HandheldSquatVerifier.Rejection.moved.rawValue })
    }

    @Test func ataque_bajarDeLadoUnEscalon() {
        // Variante: baja el escalón de lado (20 cm abajo, 25 cm a la derecha).
        let r = simulate(RTScenario(name: "A7c escalon de lado",
                                    timing: { i in RTRep(down: 0.9 + 0.1 * Double(i % 3), hold: 0.4,
                                                         up: 1.0 + 0.1 * Double(i % 2), rest: 1.0 + 0.2 * Double(i % 3)) },
                                    body: { f in
            var p = RTBody.Posture()
            p.shift = SIMD3(0.25 * f.x, -0.20 * f.x, 0)
            return RTBody.standing.pose(p)
        }))
        #expect(r.achieved == 0)
    }

    @Test func ataque_caminarConElTelefonoFrenteALaCara() {
        let r = simulate(RTScenario(name: "A6 caminar", leadIn: 0, trail: 14, repCount: 0, body: { f in
            var p = RTBody.Posture()
            let w = max(0, f.t - 2)
            p.shift = SIMD3(0, 0.025 * sin(2 * .pi * 1.8 * w), -1.2 * w)
            var o = RTBody.standing.pose(p)
            o.steps = Int(1.8 * w)
            return o
        }))
        #expect(r.achieved == 0)
        #expect(r.soft.contains(HandheldSquatAnomaly.walking))
    }

    @Test func legitimo_bajarUnTramoDeEscaleraYDespuesHacerSentadillas() {
        // Baja 8 escalones (17 cm de alto, 28 cm de huella) y después hace sentadillas reales. La escalera no
        // cuenta; al quedar quieto abajo, en otro lugar, la referencia se re-ancla y las sentadillas cuentan.
        let stairsEnd = 2.5 + 8 * 0.65
        let r = simulate(RTScenario(name: "A7b bajar escalera", leadIn: 9, body: { f in
            let k = min(8, max(0, (f.t - 2.5) / 0.65))
            let step = floor(k) + HandheldSquatSynth.minJerk(k - floor(k))
            var o = realSquat(tweak: { _, p in p.shift = SIMD3(0, -0.17 * step, -0.28 * step) })(f)
            o.steps = Int(k)
            o.altitudeOffset = -0.17 * step
            return o
        }))
        #expect(r.verifier.diagnostics.filter { $0.at <= stairsEnd + 0.5 && $0.rejection == nil }.isEmpty,
                "bajar la escalera no cuenta reps")
        #expect(r.achieved >= 9)
        #expect(r.verifier.reanchorCount >= 1)
    }

    @Test func ataque_ascensorConCamaraTraseraTapada() {
        // De pie y quieto en un ascensor, con la cámara trasera tapada (respaldo IMU): baja un piso y sube uno.
        func elevator(_ t: Double, start: Double, dir: Double) -> Double {
            let peak = 1.2, pulse = 1.6, cruise = 2.5
            let u = t - start
            if u >= 0, u < pulse { return dir * peak * pow(sin(.pi * u / pulse), 2) }
            if u >= pulse + cruise, u < 2 * pulse + cruise { return -dir * peak * pow(sin(.pi * (u - pulse - cruise) / pulse), 2) }
            return 0
        }
        let r = simulate(RTScenario(name: "A8 ascensor tapado", leadIn: 0, trail: 45, repCount: 0, body: { f in
            var o = RTBody.standing.pose(RTBody.Posture())
            o.world = false
            o.extraVerticalAccel = elevator(f.t, start: 10, dir: -1) + elevator(f.t, start: 28, dir: 1)
            o.altitudeOffset = -3.9 * min(1, max(0, (f.t - 10) / 5.7)) + 3.9 * min(1, max(0, (f.t - 28) / 5.7))
            return o
        }))
        #expect(r.achieved == 0)
        #expect(r.level != .full)
    }

    @Test func ataque_bisagraConCamaraTraseraTapada() {
        // En el respaldo IMU no hay avance de la cara en el mundo, pero la cabeza cabecea con el tronco (44-45°,
        // < 50°) y la cara baja con el teléfono (TrueDepth + gravedad): la bisagra explica el descenso → no cuenta.
        let r = simulate(RTScenario(name: "A9c bisagra respaldo IMU", leadIn: 5, body: hinge(world: false)))
        #expect(r.achieved == 0)
        #expect(r.rejections.allSatisfy { $0 == HandheldSquatVerifier.Rejection.torsoBend.rawValue }, "\(r.rejections)")
        #expect(r.level != .full)
        // Bisagra marcada (60°): el cabeceo de la cabeza la frena también en el respaldo.
        let marked = simulate(RTScenario(name: "A9c2 bisagra marcada 60° respaldo IMU", leadIn: 5, body: hinge(lean: 60, world: false)))
        #expect(marked.achieved == 0)
        #expect(marked.level != .full)
    }

    @Test func ataque_bisagraTapandoLaCamaraSoloEnLasReps() {
        // Tapa la cámara trasera antes de cada rep (respaldo IMU), hace la bisagra y destapa; entre reps se
        // queda quieto con el mundo normal (≥ 80 % de los frames "normal").
        func covering(_ lean: Double, name: String) -> RTResult {
            simulate(RTScenario(name: name, leadIn: 24, repCount: 5, target: 5,
                                timing: { i in RTRep(down: 1.3 + 0.1 * Double(i % 3), hold: 0.3,
                                                     up: 1.2 + 0.1 * Double(i % 2), rest: 24 + 0.7 * Double(i % 3)) },
                                body: { f in
                var o = hinge(lean: lean)(f)
                let coveredBefore = (f.untilNext ?? .infinity) <= 1.8
                let coveredAfter = (f.sinceLastRep ?? .infinity) < 0.2
                o.world = !(f.rep != nil || coveredBefore || coveredAfter)
                return o
            }))
        }
        let r = covering(45, name: "A9d bisagra tapando solo en reps")
        #expect(r.achieved == 0)
        #expect(r.level != .full || r.achieved < 5)
        // Bisagra marcada (60°): no cuenta.
        let marked = covering(60, name: "A9d2 bisagra marcada 60° tapando solo en reps")
        #expect(marked.achieved == 0)
        #expect(marked.level != .full || marked.achieved < 5)
    }

    @Test func legitimo_sentadillasTapandoLaCamaraSoloEnLasRepsQuedanReduced() {
        // La política es por reps, no por frames: sentadillas reales medidas con el respaldo IMU (la cámara
        // tapada justo en cada rep) cuentan, pero el nivel baja a reduced aunque el 80 % de los frames fuera normal.
        let r = simulate(RTScenario(name: "A9g sentadillas tapando solo en reps", leadIn: 30, repCount: 5, target: 5,
                                    timing: { i in RTRep(down: 1.3 + 0.1 * Double(i % 3), hold: 0.3,
                                                         up: 1.2 + 0.1 * Double(i % 2), rest: 32 + 0.7 * Double(i % 3)) },
                                    body: { f in
            var o = realSquat()(f)
            let coveredBefore = (f.untilNext ?? .infinity) <= 2.6
            let coveredAfter = (f.sinceLastRep ?? .infinity) < 0.2
            o.world = !(f.rep != nil || coveredBefore || coveredAfter)
            return o
        }))
        #expect(r.verifier.inertialReps > 0)
        #expect(r.normalFraction >= HandheldSquatSourcePolicy.minWorldFraction)
        #expect(r.sourceLevel == .fallback)
        #expect(r.level != .full)
    }

    // MARK: Límite aceptado

    @Test func limite_otraPersonaHaceLasSentadillas() {
        // La verificación es de movimiento, no de identidad: otra persona que hace sentadillas reales cuenta.
        let r = simulate(RTScenario(name: "A10 otra persona", seed: 5, body: realSquat(lean: 10)))
        #expect(r.achieved == 10, "límite aceptado y documentado")
        #expect(r.level == .full)
    }

    // MARK: Falsos positivos (operador real)

    @Test func fp_sentadillaRealConTroncoInclinadoYBrazosRigidos() {
        // Antebrazos pegados al pecho: al inclinar el tronco el teléfono baja MÁS que la cara. Se cuenta con el
        // cuerpo, así que la rotación rígida del tronco ya no parece "brazos".
        var worst = 10
        var table: [String] = []
        for lean in [8.0, 10, 12, 14, 15, 18, 22] {
            let r = simulate(RTScenario(name: "FP1 rigid lean=\(lean)", body: realSquat(lean: lean, arms: .rigid)))
            table.append("\(Int(lean))° → \(r.achieved) \(r.level)")
            worst = min(worst, r.hard.isEmpty ? r.achieved : 0)
        }
        for lean in [12.0, 15, 18, 22, 26] {
            let r = simulate(RTScenario(name: "FP1 mitad lean=\(lean)", body: realSquat(lean: lean, arms: .blend(0.5))))
            table.append("mitad \(Int(lean))° → \(r.achieved) \(r.level)")
            worst = min(worst, r.hard.isEmpty ? r.achieved : 0)
        }
        print("RT| FP1 tabla: \(table)")
        #expect(worst >= 9)
    }

    @Test func fp_caraPerdidaMedioSegundoAlBajar() {
        // ARKit pierde la cara 0,3-0,6 s a mitad de la bajada en reps alternas: los suavizados se reinician al
        // recuperarla (sin brecha falsa).
        for (from, to) in [(0.40, 0.60), (0.35, 0.70), (0.25, 0.75)] {
            let r = simulate(RTScenario(name: "FP2 cara perdida tau \(from)-\(to)", body: { f in
                var o = realSquat()(f)
                if let rep = f.rep, rep % 2 == 1, f.down > 0 {
                    let tau = f.local / f.down
                    if tau > from, tau < to { o.faceTracked = false }
                }
                return o
            }))
            #expect(r.achieved >= 9, "pérdida tau \(from)-\(to)")
            #expect(r.hard.isEmpty)
        }
    }

    @Test func fp_brazosCansados() {
        // En el fondo el teléfono cae hasta 6 cm respecto de la cara, se aleja 4 cm y la muñeca lo cabecea 8°.
        for (sag, reach, wrist) in [(0.03, 0.02, 4.0), (0.05, 0.04, 6.0), (0.06, 0.04, 8.0)] {
            let r = simulate(RTScenario(name: "FP3 cansados sag=\(sag) reach=\(reach) wrist=\(wrist)", body: realSquat(tweak: { f, p in
                p.armSag = sag * f.x
                p.armReach = reach * f.x
                p.wrist = wrist * f.x
            })))
            #expect(r.achieved >= 9, "sag \(sag) wrist \(wrist)")
            #expect(r.hard.isEmpty)
        }
    }

    @Test func fp_pausaDelDesafioConHundimientoLento() {
        // En la pausa pedida el operador se hunde despacio y oscila ±0,6 cm, o sube antes.
        var results: [String: RTResult] = [:]
        for (sink, hold) in [(0.012, 2.2), (0.016, 2.2), (0.025, 2.2), (0.0, 1.6), (0.0, 1.0)] {
            let key = "sink=\(sink) hold=\(hold)"
            var sc = RTScenario(name: "FP4 \(key)", body: realSquat(tweak: { f, p in
                guard f.holdElapsed > 0, f.hold > 0 else { return }
                p.hipDrop += sink * f.holdElapsed * f.x
                let cycles = (f.hold * 1.2).rounded()
                if f.holding, cycles >= 1 { p.hipDrop += 0.006 * sin(2 * .pi * cycles * f.holdElapsed / f.hold) }
            }))
            sc.holdWhenArmed = hold
            results[key] = simulate(sc)
        }
        #expect(results["sink=0.016 hold=2.2"]?.hard.isEmpty == true)
        #expect(results["sink=0.0 hold=1.6"]?.hard.isEmpty == true)
    }

    @Test func fp_quedaUnPocoMasBajoYDescansaEntreReps() {
        // Con dolor lumbar no extiende del todo: tras la 1ª rep queda 4,5 cm más abajo. Reps lentas (2 s + 2 s) y
        // 2,5 s de descanso: la rep se mide desde que empieza a bajar, no desde que se abrió la ventana.
        let base = 0.045
        let r = simulate(RTScenario(name: "FP5 queda 4.5cm abajo",
                                    timing: { i in RTRep(down: 2.0 + 0.1 * Double(i % 3), hold: 0.3,
                                                         up: 2.0 - 0.1 * Double(i % 2), rest: 2.5 + 0.2 * Double(i % 3)) },
                                    body: { f in
            var p = RTBody.Posture()
            let d = RTScenario.depth(f.rep ?? 0)
            let rep = f.rep ?? f.done
            let low = rep >= 1 || f.done >= 1 || (f.rep == 0 && f.holdElapsed > 0)
            let b = low ? base : 0
            p.hipDrop = b + (d - b) * f.x
            p.hipBack = 0.08 * f.x
            p.lean = 8 * f.x
            return RTBody.standing.pose(p)
        }))
        #expect(r.achieved >= 9)
        #expect(r.hard.isEmpty)
    }

    @Test func fp_bajaDeLaSoleraDespuesDeCalibrar() {
        // Calibra sobre la solera del paradero (15 cm) y se baja a la calzada (30 cm adelante): quieto en otro
        // lugar, la referencia se re-ancla.
        let r = simulate(RTScenario(name: "FP5b solera", leadIn: 5, body: { f in
            let step = HandheldSquatSynth.minJerk((f.t - 2.5) / 1.0)
            return realSquat(tweak: { _, p in p.shift = SIMD3(0, -0.15 * step, -0.30 * step) })(f)
        }))
        #expect(r.achieved >= 9)
        #expect(r.verifier.reanchorCount >= 1)
    }

    @Test func fp_pocaLuzSeguimientoIntermitente() {
        // Poca luz o pared lisa: el mundo pasa a limited 0,6 s cada 3,5 s. Las pérdidas cortas congelan la rep
        // sin cambiar al respaldo ni recalibrar.
        var sc = RTScenario(name: "FP6 VIO limited 0.6s/3.5s", body: { f in
            var o = realSquat()(f)
            if f.t > 3, f.t.truncatingRemainder(dividingBy: 3.5) > 2.9 { o.world = false }
            return o
        })
        sc.limitedKeepsPoses = true
        let r = simulate(sc)
        var mild = RTScenario(name: "FP6b VIO limited 0.4s/5s", body: { f in
            var o = realSquat()(f)
            if f.t > 3, f.t.truncatingRemainder(dividingBy: 5) > 4.6 { o.world = false }
            return o
        })
        mild.limitedKeepsPoses = true
        let r2 = simulate(mild)
        #expect(r2.achieved >= 9)
        #expect(r.achieved >= 8)
        #expect(r.hard.isEmpty)
    }

    @Test func fp_mirandoDeReojo() {
        let r = simulate(RTScenario(name: "FP7 de reojo", body: { f in
            var o = realSquat()(f)
            if f.t > 2.5, f.t.truncatingRemainder(dividingBy: 0.75) < 0.15 { o.faceTracked = false }
            return o
        }))
        #expect(r.achieved >= 9)
        #expect(r.hard.isEmpty)
    }

    @Test func fp_sinProfundidadTrueDepthSigueContando() {
        // Sol directo o lentes: sin mapa de profundidad el relieve no decide nada (no castiga).
        let r = simulate(RTScenario(name: "FP9 sin profundidad", body: { f in
            var o = realSquat()(f)
            o.relief = nil
            return o
        }))
        #expect(r.achieved == 10)
        #expect(r.level == .full)
    }

    @Test func fp_cabezaMirandoMasAbajoAlCalibrar() {
        // Lentes de lectura: mira el teléfono con la cabeza 45° abajo (dentro del margen de calibración).
        let r = simulate(RTScenario(name: "FP10 cabeza -45", body: { f in
            var o = realSquat()(f)
            o.headPitch = o.headPitch.map { $0 - 17 }
            return o
        }))
        #expect(r.achieved == 10)
        #expect(r.level == .full)
    }

    @Test func fp_sentadillaConTroncoInclinado35a45Grados() {
        // Pedido del usuario: el operador real no mantiene la espalda muy derecha; inclina el tronco 35-45°. Con
        // el teléfono frente a la cara, con los antebrazos pegados al pecho (el teléfono cabecea con el tronco)
        // o a medias, cuenta con nivel full.
        var table: [String] = []
        var lost: [String] = []
        for lean in [35.0, 40, 45] {
            for (label, arms) in [("cara", RTArms.headLocked), ("rigido", .rigid), ("mitad", .blend(0.5))] {
                let r = simulate(RTScenario(name: "FP11 tronco \(Int(lean))° \(label)", body: realSquat(lean: lean, arms: arms)))
                table.append("\(Int(lean))° \(label) → \(r.achieved) \(r.level) reanclajes \(r.verifier.reanchorCount)")
                #expect(r.verifier.reanchorCount == 0, "tronco \(lean)° \(label)")
                #expect(r.achieved >= 9, "tronco \(lean)° \(label): \(r.rejections)")
                #expect(r.hard.isEmpty)
                #expect(r.level == .full)
                #expect(r.verifier.challenge.passed)
                if r.achieved < 10 { lost.append("\(Int(lean))° \(label)") }
            }
        }
        print("RT| FP11 tabla: \(table)")
        // Con 35-40° la pausa de 2,2 s del desafío deja la cara quieta 25-30 cm adelante y la cabeza a −63/−68°: antes
        // la referencia se re-anclaba en el fondo y esa rep se perdía. Ahora la pausa del desafío (o quedarse quieto en
        // el fondo con la geometría de una sentadilla) nunca re-ancla, y la postura nueva debe cabecear como la de pie
        // calibrada (± 20°): cuentan las 10, sin re-anclajes.
        #expect(lost.isEmpty, "\(lost)")
    }

    @Test func fp_telefonoSeMueve8a10cmRespectoDeLaCara() {
        // Pedido del usuario: al bajar, el teléfono se mueve 8-10 cm respecto de la cara (cae, se aleja, se acerca
        // al pecho o se corre de lado). En el mundo se cuenta con el cuerpo (la cara baja): cuenta, también con
        // el tronco inclinado 40°.
        let moves: [(name: String, sag: Double, reach: Double, side: Double, wrist: Double)] = [
            ("cae 10", 0.10, 0, 0, 8), ("se aleja 10", 0, 0.10, 0, 0), ("al pecho 8", 0, -0.08, 0, 0),
            ("de lado 9", 0, 0, 0.09, 0), ("cae 8 y se aleja 8", 0.08, 0.08, 0, 6),
        ]
        for m in moves {
            for lean in [8.0, 40] {
                let r = simulate(RTScenario(name: "FP12 \(m.name) lean=\(Int(lean))", body: { f in
                    var o = realSquat(lean: lean, tweak: { f, p in
                        p.armSag = m.sag * f.x
                        p.armReach = m.reach * f.x
                        p.wrist = m.wrist * f.x
                    })(f)
                    o.phone.x += m.side * f.x
                    return o
                }))
                #expect(r.achieved >= 9, "\(m.name) tronco \(lean)°: \(r.rejections)")
                #expect(r.hard.isEmpty)
                #expect(r.level == .full)
            }
        }
        // Con la cámara trasera tapada (respaldo IMU) la cara se mide con la TrueDepth proyectada sobre la gravedad:
        // el teléfono baja 8 cm más que la cara y eso no es "solo brazos" (la cara bajó con el cuerpo). Cuenta en reduced.
        let covered = simulate(RTScenario(name: "FP12b respaldo cae 8 y se aleja 8", leadIn: 5, body: { f in
            var o = realSquat(tweak: { f, p in
                p.armSag = 0.08 * f.x
                p.armReach = 0.08 * f.x
            })(f)
            o.world = false
            return o
        }))
        #expect(covered.achieved >= 9, "\(covered.rejections)")
        #expect(covered.hard.isEmpty)
        #expect(covered.level == .reduced)
    }

    @Test func fp_calibraConLasManosInquietas() {
        // Pedido del usuario: no exigir el teléfono inmóvil. De pie el teléfono sube y baja ±2 cm, se corre ±3 cm
        // y cabecea ±4° (con los márgenes anteriores, 3 cm de rango, no calibraba). Calibra y las reps cuentan.
        let r = simulate(RTScenario(name: "FP13 manos inquietas", leadIn: 3, body: { f in
            var o = realSquat()(f)
            o.phone += SIMD3(0.03 * sin(2 * .pi * 0.4 * f.t), 0.02 * sin(2 * .pi * 0.7 * f.t), 0)
            o.pitch += 4 * sin(2 * .pi * 0.5 * f.t)
            return o
        }))
        #expect(r.events.contains(.gate(.ready)))
        #expect(r.achieved >= 9, "\(r.rejections)")
        #expect(r.hard.isEmpty)
        #expect(r.level == .full)
    }

    // MARK: Huecos cerrados: brazos con la cámara tapada, cabina, sacudidas, teléfono volteado

    @Test func ataque_soloBrazosConLaCamaraTraseraTapada() {
        // Respaldo IMU (cámara trasera tapada): antes solo se miraba la distancia cara-teléfono (≤ 15 cm), así que
        // bajar el teléfono 14-19 cm, o en arco hacia el cuerpo, contaba 3-10/10 en reduced. Ahora la cara se mide
        // con la TrueDepth proyectada sobre la gravedad: el teléfono baja y la cara SUBE sobre él → no entra.
        let cases: [(name: String, hip: Double, sag: Double, reach: Double, wrist: Double)] = [
            ("recto 14", 0, 0.14, 0, 10), ("recto 17", 0, 0.17, 0, 12), ("recto 19", 0, 0.19, 0, 12),
            ("arco al cuerpo 15", 0, 0.15, -0.25, 33), ("arco al cuerpo 12", 0, 0.12, -0.15, 25),
            ("rodillas 4,5 + brazos 10,5", 0.045, 0.105, 0, 8), ("rodillas 5 + arco 11", 0.05, 0.11, -0.15, 22),
        ]
        var table: [String] = []
        for c in cases {
            let r = simulate(RTScenario(name: "H1 brazos tapada \(c.name)", leadIn: 5, body: { f in
                var p = RTBody.Posture()
                p.hipDrop = c.hip * f.x
                p.armSag = c.sag * f.x
                p.armReach = c.reach * f.x
                p.wrist = c.wrist * f.x
                var o = RTBody.standing.pose(p)
                o.world = false
                return o
            }))
            table.append("\(c.name) → \(r.achieved) \(r.level) \(r.rejections)")
            #expect(r.verifier.mode == .inertial)
            #expect(r.achieved == 0, "\(c.name): \(r.rejections)")
        }
        print("RT| H1 tabla: \(table)")
        // Bajar solo con los brazos la meta completa deja `armsOnly` (hard a la 3ª), igual que con el mundo.
        let straight = simulate(RTScenario(name: "H1b brazos tapada 19 cm x5", leadIn: 5, repCount: 5, body: { f in
            var p = RTBody.Posture()
            p.armSag = 0.19 * f.x
            p.wrist = 12 * f.x
            var o = RTBody.standing.pose(p)
            o.world = false
            return o
        }))
        #expect(straight.achieved == 0)
        #expect(straight.hard.contains(HandheldSquatAnomaly.armsOnly))
        #expect(straight.level == .suspicious)
    }

    @Test func ataque_quedarseAbajoYBombearConLaCamaraTapada() {
        // Las variantes A3c/A3d con la cámara tapada: calibra de pie, baja a un cuarto de sentadilla y se queda; solo
        // los brazos (y mini-sentadillas de 7 cm) bombean el teléfono. En el respaldo la salida de la rep es más
        // tolerante con los brazos, pero la cara debe volver casi arriba: aquí queda a ≥ 11 cm.
        func pumping(_ name: String, squat: Double, mini: Double, arms: Double, lift: Double) -> RTResult {
            simulate(RTScenario(name: name, leadIn: 8.5,
                                timing: { i in RTRep(down: 0.6 + 0.07 * Double(i % 3), hold: 0.12,
                                                     up: 0.55 + 0.08 * Double(i % 4), rest: 0.3 + 0.1 * Double(i % 3)) },
                                body: { f in
                var p = RTBody.Posture()
                var o: RTOut
                if f.t < 5.5 {
                    o = RTBody.standing.pose(p)
                } else {
                    let enter = HandheldSquatSynth.minJerk((f.t - 5.5) / 1.5)
                    p.hipDrop = squat * enter + mini * f.x
                    p.lean = 4 * enter
                    p.armSag = -lift * enter + arms * f.x
                    o = RTBody.standing.pose(p)
                }
                o.world = false
                return o
            }))
        }
        let iso = pumping("H1c isométrico + bombeo tapada", squat: 0.115, mini: 0, arms: 0.14, lift: 0.07)
        let mini = pumping("H1d minisentadillas abajo + bombeo tapada", squat: 0.12, mini: 0.07, arms: 0.14, lift: 0.08)
        #expect(iso.verifier.mode == .inertial && mini.verifier.mode == .inertial)
        #expect(iso.achieved == 0, "\(iso.rejections)")
        #expect(mini.achieved == 0, "\(mini.rejections)")
    }

    @Test func legitimo_sentadillasConLaCamaraTapadaYTroncoInclinadoCuentanReduced() {
        // La otra cara del respaldo: sentadillas reales con la cámara tapada, con el teléfono frente a la cara o con
        // los antebrazos pegados al pecho (el teléfono baja más que la cara), cuentan en reduced.
        var lenses = RTBody.standing
        lenses.baseHeadPitch = -45
        let cases: [(String, Double, RTArms, RTBody, Double?)] = [
            ("cara 8°", 8, .headLocked, .standing, nil), ("rígido 20°", 20, .rigid, .standing, nil),
            ("mitad 35°", 35, .blend(0.5), .standing, nil), ("lentes, cadera 15, tronco 25°", 25, .headLocked, lenses, 0.15),
        ]
        for (label, lean, arms, body, hip) in cases {
            let r = simulate(RTScenario(name: "H2 tapada \(label)", leadIn: 5, body: { f in
                var o = realSquat(lean: lean, arms: arms, body: body, tweak: { f, p in
                    if let hip { p.hipDrop = hip * f.x }
                })(f)
                o.world = false
                return o
            }))
            #expect(r.achieved >= 9, "\(label): \(r.rejections)")
            #expect(r.hard.isEmpty)
            #expect(r.level == .reduced)
        }
    }

    @Test func ataque_sentadoEnLaCabinaMeciendoseDesdeVariasInclinaciones() {
        // Sentado en la cabina, calibra con el tronco ya inclinado θ0 y lo mece Δθ más (la cabeza gira con el tronco),
        // con el mundo y con la cámara tapada. No cuenta en ningún nivel: no calibra (cabeza > 60°) o lo frena la
        // bisagra (el giro sobre la cadera explica la bajada de la cara) o el avance de la cara.
        var table: [String] = []
        var worst = 0
        for world in [true, false] {
            for (start, swing) in [(0.0, 45.0), (10, 40), (20, 40), (25, 26), (30, 26), (35, 26), (40, 26), (30, 40)] {
                let r = simulate(RTScenario(name: "H3 sentado \(Int(start))°+\(Int(swing))° \(world ? "mundo" : "tapada")",
                                            leadIn: world ? 2 : 5, body: { f in
                    var p = RTBody.Posture()
                    p.lean = start + swing * f.x
                    var o = RTBody.seated.pose(p)
                    o.world = world
                    return o
                }))
                table.append("\(Int(start))°+\(Int(swing))° \(world ? "mundo" : "tapada") → \(r.achieved) \(r.level) "
                             + "knee=\(r.verifier.diagnostics.compactMap(\.kneeDescent).map { Int($0 * 100) })")
                worst = max(worst, r.achieved)
                #expect(r.achieved == 0, "sentado \(start)+\(swing) mundo=\(world): \(r.rejections)")
            }
        }
        print("RT| H3 tabla: \(table)")
        #expect(worst == 0)
    }

    @Test func ataque_sacudirSuaveOdeLadoEsShaking() {
        // Sacudidas más suaves que la sintética de 6 Hz: vertical a 3,5 Hz con ±2 cm (10 m/s²) y de lado a 4 Hz con
        // ±3 cm (la vertical casi no se mueve: lo ve el zigzag de la posición en el mundo).
        for (label, axis, hz, amplitude) in [("vertical 3,5 Hz 2 cm", 1, 3.5, 0.02), ("de lado 4 Hz 3 cm", 0, 4.0, 0.03),
                                             ("adelante-atrás 5 Hz 2 cm", 2, 5.0, 0.02)] {
            let r = simulate(RTScenario(name: "H4 sacudir \(label)", leadIn: 0, trail: 6, repCount: 0, body: { f in
                var o = RTBody.standing.pose(RTBody.Posture())
                if f.t > 2.5 { o.phone[axis] += amplitude * sin(2 * .pi * hz * (f.t - 2.5)) }
                return o
            }))
            #expect(r.hard.contains(HandheldSquatAnomaly.shaking), "\(label): \(r.outcome.anomalies)")
            #expect(r.level == .suspicious)
        }
    }

    @Test func fp_caminarRapidoConElTelefonoNoEsSacudidaHard() {
        // Pasos a 2,2 Hz con ±3 cm de rebote (≈ 5,7 m/s²): ≈ 4,4 inversiones por segundo. Es `walking` (soft), no una
        // sacudida hard que deje la pausa como sospechosa. Y no cuenta reps.
        let r = simulate(RTScenario(name: "H4b caminar rápido", leadIn: 0, trail: 12, repCount: 0, body: { f in
            var p = RTBody.Posture()
            let w = max(0, f.t - 2)
            p.shift = SIMD3(0, 0.03 * sin(2 * .pi * 2.2 * w), -1.4 * w)
            var o = RTBody.standing.pose(p)
            o.steps = Int(2.2 * w)
            return o
        }))
        #expect(!r.hard.contains(HandheldSquatAnomaly.shaking), "\(r.outcome.anomalies)")
        #expect(r.soft.contains(HandheldSquatAnomaly.walking))
        #expect(r.achieved == 0)
    }

    @Test func fp_sentadillasRapidasYHondasNoSonSacudidas() {
        // Como en el iPhone real: bajar 40-70 cm en ≈ 0,5 s y subir en ≈ 0,55 s llega a 13 m/s² y ~0,8 g de RMS,
        // pero es una sola bajada suave (≤ 3 inversiones por segundo). Antes: `shaking` en casi todas.
        for (label, hip, rest) in [("40 cm", 0.40, 0.9), ("60 cm", 0.60, 0.9), ("70 cm seguidas", 0.70, 0.35)] {
            let r = simulate(RTScenario(name: "H5 rápidas \(label)",
                                        timing: { i in RTRep(down: 0.5 + 0.03 * Double(i % 3), hold: 0.05,
                                                             up: 0.55 + 0.04 * Double(i % 2), rest: rest + 0.1 * Double(i % 3)) },
                                        body: realSquat(lean: 12, tweak: { f, p in p.hipDrop = hip * f.x })))
            let maxRMS = r.samples.compactMap(\.userAccelRMS).max() ?? 0
            let maxAccel = r.samples.compactMap(\.verticalAccel).map(abs).max() ?? 0
            print("RT| H5 \(label): RMS máx \(maxRMS) g, |a| máx \(maxAccel) m/s², oscilación \(r.verifier.diagnostics.map(\.oscillation))")
            #expect(maxAccel > 9, "el caso debe ser tan brusco como el real")
            #expect(!r.rejections.contains(HandheldSquatVerifier.Rejection.shaking.rawValue), "\(label): \(r.rejections)")
            #expect(!r.hard.contains(HandheldSquatAnomaly.shaking))
            #expect(r.achieved >= 9, "\(label): \(r.rejections)")
        }
    }

    @Test func fp_telefonoVolteadoHaciaLosMuslosPidePonerloFrenteAlPecho() {
        // Como dos intentos reales: en el fondo el teléfono cabecea ~78° (pantalla hacia arriba) y baja ~45 cm más
        // que la cara. No cuenta, con la pista correcta (no "No sacuda el teléfono").
        let r = simulate(RTScenario(name: "H6 teléfono volteado", repCount: 4, body: realSquat(tweak: { f, p in
            p.armSag = 0.45 * f.x
            p.wrist = 78 * f.x
        })))
        #expect(r.achieved == 0)
        #expect(r.rejections.allSatisfy { $0 == HandheldSquatVerifier.Rejection.phoneTilted.rawValue }, "\(r.rejections)")
        #expect(r.events.contains(.cue(Cue(text: HandheldSquatCopy.phoneAtChest, symbol: "iphone"))))
        #expect(!r.events.contains(.cue(Cue(text: HandheldSquatCopy.noShake, symbol: "iphone.radiowaves.left.and.right"))))
    }

    @Test func fp_operadorConDolorLumbarLentoCortoEInclinado() {
        // Marco (52, lumbago): reps lentas (2-2,5 s abajo y arriba), cadera 10-30 cm, tronco 15-35° adelante, a veces
        // con lentes de lectura (cabeza −45° de pie). La bisagra no lo castiga: las rodillas aportan ≥ 40 %.
        var table: [String] = []
        for headBase in [-28.0, -45] {
            for (hip, lean) in [(0.10, 20.0), (0.10, 25), (0.12, 35), (0.12, 20), (0.15, 25), (0.20, 35), (0.30, 15)] {
                var body = RTBody.standing
                body.baseHeadPitch = headBase
                let r = simulate(RTScenario(name: "H7 Marco cadera \(hip) tronco \(lean) cabeza \(headBase)",
                                            timing: { i in RTRep(down: 2.0 + 0.2 * Double(i % 3), hold: 0.3,
                                                                 up: 2.2 + 0.2 * Double(i % 2), rest: 1.5 + 0.3 * Double(i % 3)) },
                                            body: realSquat(lean: lean, body: body, tweak: { f, p in p.hipDrop = hip * f.x })))
                table.append("cadera \(Int(hip * 100)) tronco \(Int(lean))° cabeza \(Int(headBase))° → \(r.achieved) \(r.level) "
                             + "knee=\(r.verifier.diagnostics.compactMap(\.kneeDescent).prefix(3).map { Int($0 * 100) })")
                #expect(r.achieved >= 9, "cadera \(hip) tronco \(lean) cabeza \(headBase): \(r.rejections)")
                #expect(r.hard.isEmpty)
                #expect(r.level == .full)
            }
        }
        print("RT| H7 tabla: \(table)")
    }

    @Test func fp_pausaLargaAbajoConElTroncoInclinadoNoReancla() {
        // Sin desafío, se queda 3 s abajo con el tronco a 40° (la cara 30 cm adelante, quieta): no es una postura de
        // pie nueva (la cabeza mira 40° más abajo), así que no se re-ancla y la rep cuenta al subir.
        let r = simulate(RTScenario(name: "H8 pausa larga tronco 40", challengeRep: 0,
                                    timing: { i in RTRep(down: 1.3, hold: i % 2 == 0 ? 3.0 : 0.3, up: 1.3, rest: 1.2) },
                                    body: realSquat(lean: 40)))
        #expect(r.achieved == 10, "\(r.rejections)")
        #expect(r.verifier.reanchorCount == 0)
        #expect(r.level == .full)
    }

    @Test func fp_correrseDeLugarEntreRepsNoEsMoved() {
        // Datos reales: entre dos reps el usuario caminó y bajó; medido contra la calibración (que se adapta lento) el
        // teléfono "recorría" 84 cm y la rep se rechazaba como `moved`. Aquí avanza 25 cm después de cada rep: desde
        // el ancla de la rep recorre lo de una sentadilla y cuenta.
        let r = simulate(RTScenario(name: "FP14 se corre entre reps",
                                    timing: { i in RTRep(down: 1.2, hold: 0.25, up: 1.1, rest: 2.4 + 0.2 * Double(i % 3)) },
                                    body: { f in
            var o = realSquat()(f)
            let steps: Double
            if let rep = f.rep {
                steps = Double(rep)
            } else if let since = f.sinceLastRep {
                steps = Double(f.done - 1) + min(1, since / 0.6)
            } else {
                steps = 0
            }
            o.phone.z -= 0.25 * steps
            o.face.z -= 0.25 * steps
            return o
        }))
        #expect(r.achieved >= 9, "\(r.rejections)")
        #expect(!r.rejections.contains(HandheldSquatVerifier.Rejection.moved.rawValue), "\(r.rejections)")
        #expect(r.level == .full)
    }

    @Test func diseno_sentadillaCortaDe15cm() {
        // Umbral de diseño (pedido del usuario: "amplía el rango de los 15 cm"): cuenta desde ≈ 10 cm de bajada.
        // Medias sentadillas de 9,5-16 cm de cadera (la cara baja 10-17 cm) cuentan con nivel full. La profundidad
        // mínima la define el kinesiólogo.
        var shallow: [RTResult] = []
        for hip in [0.095, 0.11, 0.135, 0.145, 0.16] {
            shallow.append(simulate(RTScenario(name: "FP8 corta cadera \(hip)", body: realSquat(tweak: { f, p in
                p.hipDrop = hip * f.x
            }))))
        }
        for s in shallow {
            #expect(s.achieved >= 9, "\(s.rejections)")
            #expect(s.level == .full)
        }
        // Bajo el piso de diseño (cadera 6 cm, la cara baja ≈ 7 cm): no cuenta y pide bajar un poco más.
        let half = simulate(RTScenario(name: "FP8b corta 6cm", body: realSquat(tweak: { f, p in
            p.hipDrop = 0.06 * f.x
        })))
        #expect(half.achieved == 0)
        #expect(half.events.contains(.cue(Cue(text: HandheldSquatCopy.lower, symbol: "arrow.down"))))
        #expect(half.hard.isEmpty)
    }
}

