import Testing
import Foundation
@testable import Activate

// "Pararse y sentarse" con el teléfono en las dos manos frente al pecho: muestras sintéticas a 60 Hz
// (`SitStandSynth`) con ruido de ARKit, balanceo, temblor, relieve TrueDepth y cinemática plausible (el tronco
// se inclina al pararse). Tres suites:
// - `SitToStandTests`: comportamiento básico y los mecanismos del endurecimiento.
// - `SitToStandFraudTests`: el red team de fraude convertido en regresión (lazo cerrado con el desafío).
// - `SitToStandHonestOperatorTests`: el red team de falsos negativos (operador real con dolor lumbar).

/// Tipo de actividad del verificador (A4).
private nonisolated let sitStandKind: ActivityKind = .pararseSentarse

private nonisolated func sitStandSpec(_ target: Int) -> VerificationSpec {
    VerificationSpec(kind: sitStandKind, target: target, minDurationSeconds: Double(target) * 1.2,
                     maxDurationSeconds: 240, demo: false)
}

private nonisolated func sitStandLevel(_ outcome: ActivityOutcome) -> VerificationLevel {
    VerificationPolicy.level(for: outcome, source: .live, kind: sitStandKind)
}

struct SitToStandTests {
    typealias Kind = SitToStandVerifier.HoldChallenge.Kind

    // MARK: Utilidades

    private func spec(target: Int) -> VerificationSpec { sitStandSpec(target) }

    private func verifier(target: Int, seed: UInt64 = 42) -> SitToStandVerifier {
        var v = SitToStandVerifier(spec: spec(target: target), kind: sitStandKind, seed: seed)
        v.start(at: 0)
        return v
    }

    /// Primera semilla cuyo desafío es del tipo pedido.
    private func seed(for kind: Kind, target: Int) -> UInt64 {
        for s in UInt64(1)...UInt64(500)
        where SitToStandVerifier(spec: spec(target: target), kind: sitStandKind, seed: s).challenge.kind == kind {
            return s
        }
        Issue.record("Sin semilla para \(kind)")
        return 1
    }

    /// Alimenta las muestras y devuelve eventos y consignas vistas.
    @discardableResult
    private func run(_ v: inout SitToStandVerifier, _ samples: [SitStandSample]) -> (events: [VerifierEvent], hints: [String]) {
        var events: [VerifierEvent] = []
        var hints: [String] = []
        for s in samples {
            events += v.ingest(s, at: s.t)
            if hints.last != v.progress.hint { hints.append(v.progress.hint) }
        }
        return (events, hints)
    }

    private func anomalies(_ v: SitToStandVerifier, _ kind: String, _ severity: Anomaly.Severity? = nil) -> [Anomaly] {
        v.anomalies.filter { $0.kind == kind && (severity == nil || $0.severity == severity) }
    }

    private func level(_ outcome: ActivityOutcome) -> VerificationLevel { sitStandLevel(outcome) }

    /// Sentado y quieto 1,6 s: alcanza para la calibración de 1 s.
    private func seated(seed: UInt64 = 1, body: SitStandSynth.Body = SitStandSynth.Body()) -> SitStandSynth {
        var synth = SitStandSynth(seed: seed, body: body)
        synth.hold(1.6)
        return synth
    }

    // MARK: Cuenta

    @Test(arguments: Kind.allCases)
    func ochoRepeticionesRealesCuentanConNivelFull(challengeKind: Kind) {
        var v = verifier(target: 8, seed: seed(for: challengeKind, target: 8))
        var synth = seated()
        synth.series(count: 8, challenge: v.challenge)
        synth.hold(1)
        let (events, hints) = run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .completed)

        #expect(v.count == 8)
        #expect(outcome.completed)
        #expect(events.contains(.completed))
        #expect(v.challengePassed)
        #expect(v.rejections.isEmpty, "Rechazos: \(v.rejections)")
        #expect(!outcome.anomalies.contains { $0.severity == .hard }, "Anomalías: \(outcome.anomalies)")
        #expect(level(outcome) == .full)
        guard case let .reps(count, maxRise, meanSeconds) = outcome.metrics else {
            Issue.record("Métricas inesperadas: \(outcome.metrics)")
            return
        }
        #expect(count == 8)
        #expect((maxRise ?? 0) > 0.38 && (maxRise ?? 0) < 0.48)
        #expect((meanSeconds ?? 0) > SitToStandVerifier.minRepSeconds && (meanSeconds ?? 0) < SitToStandVerifier.maxRepSeconds)
        // La consigna sigue el movimiento, incluido el desafío.
        #expect(hints.contains(SitStandCopy.stand))
        #expect(hints.contains(SitStandCopy.sit))
        #expect(hints.contains(challengeKind == .stand ? SitStandCopy.holdStand : SitStandCopy.holdSit))
        #expect(v.progress.hint == SitStandCopy.done)
    }

    @Test func repeticionesLentasDeOchoSegundosCuentan() {
        var v = verifier(target: 4)
        var slow = SitStandSynth.Rep()
        slow.riseSeconds = 3.4
        slow.standSeconds = 0.8
        slow.sitSeconds = 3.6
        slow.seatedSeconds = 1.2
        var synth = seated(seed: 2)
        synth.series(count: 4, challenge: v.challenge, base: slow, jitter: 0.3)
        synth.hold(1)
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .completed)
        #expect(v.count == 4, "Rechazos: \(v.rejections)")
        #expect(level(outcome) == .full)
        // Ciclo completo ≈ 8 s; la rep se mide desde que sale de la banda hasta que queda quieta sentada.
        #expect(v.repSeconds.allSatisfy { $0 > 5 }, "Duraciones: \(v.repSeconds)")
    }

    @Test func sillaAltaConSubidaDe26CmCuenta() {
        var v = verifier(target: 4, seed: 7)
        var high = SitStandSynth.Rep()
        high.rise = 0.26
        high.forward = 0.15
        high.leanDeg = 22
        high.sitLeanDeg = 18
        var synth = seated(seed: 3)
        synth.series(count: 4, challenge: v.challenge, base: high)
        synth.hold(1)
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .completed)
        #expect(v.count == 4, "Rechazos: \(v.rejections)")
        #expect(level(outcome) == .full)
        if case let .reps(_, maxRise, _) = outcome.metrics {
            #expect((maxRise ?? 0) >= SitToStandVerifier.standRise && (maxRise ?? 0) < 0.30)
        }
    }

    // MARK: No cuenta

    @Test func moverElTelefonoConLosBrazosSentadoNoCuenta() {
        var v = verifier(target: 4)
        var synth = seated()
        for _ in 0..<4 {
            synth.armsRaise(seconds: 0.9, lift: 0.32, holdSeconds: 0.6)
            synth.hold(1.0)
        }
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)
        #expect(v.count == 0)
        #expect(v.rejections.filter { $0.reason == .armsOnly }.count == 4)
        let arms = anomalies(v, SitStandAnomaly.armsOnly)
        #expect(arms.count == 4)
        #expect(arms.prefix(2).allSatisfy { $0.severity == .soft })
        #expect(arms.dropFirst(2).allSatisfy { $0.severity == .hard }, "Al tercero pasa a hard")
        #expect(level(outcome) == .suspicious)
    }

    @Test func inclinarseAdelanteSinPararseNoCuenta() {
        var v = verifier(target: 4)
        var synth = seated()
        for _ in 0..<4 {
            synth.leanForward(seconds: 1.2, leanDeg: 40, holdSeconds: 0.6)
            synth.hold(1.0)
        }
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)
        #expect(v.count == 0)
        #expect(v.rejections.filter { $0.reason == .torsoOnly }.count == 4)
        #expect(anomalies(v, SitStandAnomaly.torsoOnly, .soft).count == 4)
        #expect(!outcome.anomalies.contains { $0.severity == .hard })
    }

    @Test func enderezarseDesdeEncorvadoNoCuenta() {
        // Calibra encorvado (con los brazos adelante para ver la pantalla) y "cuenta" enderezándose.
        var body = SitStandSynth.Body()
        body.pitchFollow = 0.75
        var synth = SitStandSynth(seed: 5, body: body)
        synth.armsForward = 0.15
        synth.lean = 42
        synth.hold(1.6)
        for _ in 0..<4 {
            let n = Int((1.4 * synth.fps).rounded())
            for i in 1...n {
                synth.lean = 42 * (1 + cos(.pi * Double(i) / Double(n))) / 2
                synth.emit()
            }
            synth.hold(0.8)
            for i in 1...n {
                synth.lean = 42 * (1 - cos(.pi * Double(i) / Double(n))) / 2
                synth.emit()
            }
            synth.hold(1.0)
        }
        var v = verifier(target: 4)
        run(&v, synth.samples)
        #expect(v.reference != nil)
        #expect(v.count == 0)
        #expect(v.rejections.contains { $0.reason == .torsoOnly || $0.reason == .armsOnly }, "Rechazos: \(v.rejections)")
    }

    @Test func fotoSinMicroexpresionesEsStatic() {
        var v = verifier(target: 4)
        var synth = seated()
        synth.liveFace = false
        synth.series(count: 4, challenge: v.challenge)
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)
        #expect(!anomalies(v, SitStandAnomaly.staticFace, .hard).isEmpty)
        #expect(v.count == 0)
        #expect(v.rejections.contains { $0.reason == .notLive })
        #expect(level(outcome) == .suspicious)
    }

    @Test(arguments: Kind.allCases)
    func noSeguirLaConsignaDelDesafioEsHoldChallengeFailed(challengeKind: Kind) {
        var v = verifier(target: 4, seed: seed(for: challengeKind, target: 4))
        var quick = SitStandSynth.Rep()
        quick.standSeconds = 0.3
        quick.seatedSeconds = 0.7
        var synth = seated(seed: 4)
        synth.series(count: 6, challenge: v.challenge, base: quick, jitter: 0.5, comply: false)
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)
        let failed = anomalies(v, SitStandAnomaly.holdChallengeFailed)
        #expect(failed.count == 2)
        #expect(failed.first?.severity == .soft)
        #expect(failed.last?.severity == .hard)
        #expect(v.challengeRetired)
        #expect(!v.challengePassed)
        #expect(v.rejections.filter { $0.reason == .holdChallengeFailed }.count == 2)
        #expect(level(outcome) == .suspicious)
    }

    @Test func sacudirElTelefonoEsShaking() {
        var v = verifier(target: 4)
        var synth = seated()
        synth.shake(seconds: 2, amplitude: 0.12, hz: 5)
        synth.hold(1)
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)
        #expect(!anomalies(v, SitStandAnomaly.shaking, .hard).isEmpty)
        #expect(v.peakPhoneSpeed > SitToStandVerifier.shakeSpeed)
        #expect(v.count == 0)
        #expect(level(outcome) == .suspicious)
    }

    @Test func caminarEsWalking() {
        var v = verifier(target: 4)
        var synth = seated()
        synth.standUp(seconds: 1.3, rise: 0.42, forward: 0.3, leanDeg: 38)
        synth.walk(seconds: 6, speed: 1.2, cadence: 1.8)
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)
        #expect(anomalies(v, SitStandAnomaly.walking, .soft).count == 1)
        #expect(v.count == 0)
        #expect(!outcome.anomalies.contains { $0.severity == .hard })
    }

    @Test func bucleConRitmoPerfectoEsTooRegular() {
        // Un vídeo en bucle con pausas largas cumple cualquier desafío, pero su ritmo es perfecto.
        var v = verifier(target: 8)
        var loop = SitStandSynth.Rep()
        loop.standSeconds = SitStandSynth.challengeHoldSeconds
        loop.seatedSeconds = SitStandSynth.challengeHoldSeconds
        var synth = seated()
        synth.series(count: 8, challenge: v.challenge, base: loop, jitter: 0)
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .completed)
        #expect(v.count == 8)
        #expect(!anomalies(v, SitStandAnomaly.tooRegular, .hard).isEmpty)
        #expect(level(outcome) == .suspicious)
    }

    // MARK: Gates

    @Test func calibraSentadoConLaCaraVisible() {
        var v = verifier(target: 4)
        #expect(v.progress.gate == .calibrating)
        #expect(v.progress.hint == SitStandCopy.calibrate)
        var synth = SitStandSynth(seed: 1)
        synth.faceTracked = false
        synth.hold(1.0)
        run(&v, synth.samples)
        #expect(v.progress.gate == .calibrating, "Sin cara no calibra (1 s < 1,5 s de gracia)")
        var more = synth
        more.faceTracked = true
        more.hold(1.6)
        let (events, _) = run(&v, Array(more.samples.dropFirst(synth.samples.count)))
        #expect(events.contains(.gate(.ready)))
        #expect(v.progress.gate == .ready)
        #expect(v.reference != nil)
        #expect([SitStandCopy.stand, SitStandCopy.standThenHold].contains(v.progress.hint))
    }

    @Test func caraPerdidaBloqueaYNoCuentaEseTramo() {
        var v = verifier(target: 4, seed: seed(for: .sit, target: 4))
        var synth = seated()
        synth.standUp(seconds: 1.3, rise: 0.42, forward: 0.3, leanDeg: 38)
        synth.faceTracked = false
        synth.hold(2.0)
        synth.faceTracked = true
        synth.sitDown(seconds: 1.5, leanDeg: 30)
        synth.hold(1.0)
        let (events, _) = run(&v, synth.samples)
        #expect(events.contains(.gate(.blocked(reason: SitStandCopy.faceLost))))
        #expect(v.count == 0)
        #expect(v.rejections.contains { $0.reason == .interrupted })
        // Vuelve a estar listo después de sentarse.
        #expect(v.progress.gate == .ready)
        #expect(v.phase == .seated)
        var next = synth
        next.series(count: 1, challenge: nil)
        run(&v, Array(next.samples.dropFirst(synth.samples.count)))
        #expect(v.count == 1, "Rechazos: \(v.rejections)")
    }

    @Test func trackingLimitadoSostenidoBloqueaYNoCuenta() {
        var v = verifier(target: 4)
        var synth = seated()
        synth.standUp(seconds: 1.3, rise: 0.42, forward: 0.3, leanDeg: 38)
        synth.worldTrackingNormal = false
        synth.hold(1.0)
        synth.worldTrackingNormal = true
        synth.sitDown(seconds: 1.5, leanDeg: 30)
        synth.hold(1.0)
        let (events, hints) = run(&v, synth.samples)
        #expect(events.contains(.gate(.blocked(reason: SitStandCopy.trackingLimited))))
        #expect(hints.contains(SitStandCopy.trackingLimited))
        #expect(v.count == 0)
        #expect(v.progress.gate == .ready)
    }

    @Test func calibroDePieYAlSentarseRecalibra() {
        var body = SitStandSynth.Body()
        body.seatHipY = 0.92 // de pie
        var synth = SitStandSynth(seed: 6, body: body)
        synth.hold(1.6)
        // Se sienta (la cadera baja 42 cm y retrocede) y se queda quieto.
        let n = Int((1.5 * synth.fps).rounded())
        for i in 1...n {
            let u = Double(i) / Double(n)
            synth.hipRise = -0.42 * SitStandSynth.smoothstep(u)
            synth.hipForward = -0.30 * SitStandSynth.smoothstep(u)
            synth.lean = 25 * (1 - cos(2 * .pi * u)) / 2
            synth.emit()
        }
        synth.lean = 0
        synth.hold(2.8)
        var v = verifier(target: 4)
        let (events, _) = run(&v, synth.samples)
        #expect(events.contains(.cue(Cue(text: SitStandCopy.reseated, symbol: "checkmark.circle.fill"))))
        #expect(v.phase == .seated)
        #expect(anomalies(v, SitStandAnomaly.torsoOnly).isEmpty)
    }

    // MARK: Endurecimiento (red team)

    @Test func sinProfundidadTrueDepthCuentaIgual() {
        // Con sol directo TrueDepth no entrega profundidad: sin lecturas de relieve el verificador no decide.
        var v = verifier(target: 8)
        var synth = seated()
        synth.depth = false
        synth.series(count: 8, challenge: v.challenge)
        synth.hold(1)
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .completed)
        #expect(v.count == 8, "Rechazos: \(v.rejections)")
        #expect(!v.faceLooksFlat)
        #expect(level(outcome) == .full)
    }

    @Test func caraPlanaParaTrueDepthNoCuentaYAlTerceroEsHard() {
        // El cuerpo hace el movimiento, pero la "cara" que ve la cámara frontal es una pantalla (relieve ≈ 2 mm).
        var v = verifier(target: 4)
        var synth = seated()
        synth.flatFace = true
        synth.series(count: 5, challenge: v.challenge)
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)
        #expect(v.count == 0)
        #expect(v.faceLooksFlat)
        #expect(v.rejections.filter { $0.reason == .flatFace }.count == 5, "Rechazos: \(v.rejections)")
        let flat = anomalies(v, SitStandAnomaly.flatFace)
        #expect(flat.prefix(2).allSatisfy { $0.severity == .soft })
        #expect(flat.dropFirst(2).allSatisfy { $0.severity == .hard })
        #expect(level(outcome) == .suspicious)
    }

    @Test func subirElTelefonoConLosBrazosSinQueSubaLaCaraNoEsDePie() {
        // Teléfono 27 cm arriba (sobre `standRise`), cara 0: nunca "de pie"; se rechaza como brazos.
        var v = verifier(target: 4)
        var synth = seated()
        synth.armsRaise(seconds: 0.9, lift: 0.27, holdSeconds: 0.8)
        synth.hold(1.0)
        run(&v, synth.samples)
        #expect(v.count == 0)
        #expect(v.rejections.map(\.reason) == [.armsOnly])
    }

    @Test func pasosDeEscalonEnCadaRepEsWalkingHard() {
        // Mismo movimiento honesto, pero el podómetro suma 4 pasos por rep: no fue pararse de una silla.
        var v = verifier(target: 4)
        var synth = seated()
        for i in 1...4 {
            synth.steps = (synth.steps ?? 0) + 4
            var r = synth.naturalRep()
            if v.challenge.repIndex == i {
                switch v.challenge.kind {
                case .stand: r.standSeconds = max(r.standSeconds, SitStandSynth.challengeHoldSeconds)
                case .sit: r.seatedSeconds = max(r.seatedSeconds, SitStandSynth.challengeHoldSeconds)
                }
            }
            synth.rep(r)
        }
        synth.hold(1)
        run(&v, synth.samples)
        #expect(v.count == 4, "El movimiento es honesto; lo delatan los pasos")
        let outcome = v.finish(at: synth.t, reason: .completed)
        #expect(!anomalies(v, SitStandAnomaly.walking, .hard).isEmpty)
        #expect(level(outcome) == .suspicious)
    }

    @Test func caminarAntesDeEmpezarNoCuentaComoPasosDeLaSerie() {
        // 10 pasos hasta la silla (antes de la primera rep) y después la serie honesta.
        var v = verifier(target: 4)
        var synth = seated()
        synth.steps = 10
        synth.hold(1)
        synth.series(count: 4, challenge: v.challenge)
        synth.hold(1)
        run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .completed)
        #expect(v.count == 4)
        #expect(anomalies(v, SitStandAnomaly.walking, .hard).isEmpty)
        #expect(level(outcome) == .full)
    }

    @Test func noApuraAQuienVaLento() {
        // Ciclo de ~12 s (dentro de los 15 s): cuenta y nunca dice "más seguido".
        var v = verifier(target: 2)
        var slow = SitStandSynth.Rep()
        slow.riseSeconds = 4.5
        slow.standSeconds = 1.5
        slow.sitSeconds = 5
        slow.seatedSeconds = 1.2
        var synth = seated(seed: 8)
        synth.series(count: 2, challenge: v.challenge, base: slow, jitter: 0.2)
        synth.hold(1)
        let (events, _) = run(&v, synth.samples)
        #expect(v.count == 2, "Rechazos: \(v.rejections)")
        #expect(!events.contains { if case .cue(let c) = $0 { c.text == SitStandCopy.tooSlow } else { false } })
        #expect(SitStandCopy.tooSlow.contains("a su ritmo"))
    }

    // MARK: Runner

    @Test func runnerConReplayCompletaYQuedaSimulado() async {
        let assignment = ActivityAssignment(kind: sitStandKind, target: 4)
        let verifier = SitToStandVerifier(spec: spec(target: 4), kind: sitStandKind, seed: 99)
        let source = ReplaySource(samples: SitStandSynth.completing(verifier), speed: .infinity)
        let runner = ActivityRunner(assignment: assignment, verifier: verifier, source: source)
        runner.start()
        await runner.waitUntilFinished()
        #expect(runner.outcome?.completed == true)
        #expect(runner.outcome?.reason == .completed)
        #expect(runner.progress.count == 4)
        #expect(runner.level == .simulated)
    }
}

// MARK: - Red team: fraude

private typealias RTSChallenge = SitToStandVerifier.HoldChallenge.Kind

private enum RTS {
    static func spec(_ target: Int) -> VerificationSpec {
        sitStandSpec(target)
    }

    static func level(_ outcome: ActivityOutcome) -> VerificationLevel {
        sitStandLevel(outcome)
    }

    static let challengeHold = SitStandSynth.challengeHoldSeconds

    /// Primera semilla cuyo desafío es del tipo pedido.
    static func seed(for kind: RTSChallenge, target: Int) -> UInt64 {
        for s in UInt64(1)...UInt64(500)
        where SitToStandVerifier(spec: spec(target), kind: sitStandKind, seed: s).challenge.kind == kind {
            return s
        }
        return 1
    }

    static func jitter(_ rng: inout FixtureRandom, _ a: Double) -> SIMD3<Float> {
        SIMD3(Float(rng.symmetric(a)), Float(rng.symmetric(a)), Float(rng.symmetric(a)))
    }

    static func stats(_ ex: SitToStandVerifier.Excursion) -> String {
        String(format: "rise %.2f faceRise %.2f gap %.3f fip %.3f fshift %.2f peakPitch %.0f maxPitch %.0f upperFace %d live %d/%d flat %d",
               ex.maxRise, ex.maxFaceRise, ex.maxRiseGap, ex.maxFaceInPhoneShift, ex.maxFaceShift,
               ex.peakPitchDelta, ex.maxPitchDelta, ex.upperFaceSamples, ex.liveSamples, ex.faceSamples, ex.flatSamples)
    }
}

/// De dónde sale la "cara" que ve la cámara frontal en el montaje rígido.
private enum RTSFaceSource {
    /// Vídeo de una cara en otro teléfono: blendShapes vivos.
    case video
    /// Foto impresa: energía 0.
    case photo
    /// Foto con un salto de ruido de tracking (luz, reflejo) cada `every` segundos.
    case photoWithTrackingNoise(every: Double)
}

/// Postura objetivo; `nil` = la deja como está.
private struct RTSPose {
    var hip: Double? = nil
    var forward: Double? = nil
    var lean: Double? = nil
    var arms: Double? = nil
    var reach: Double? = nil
}

/// Sintetizador + verificador real alimentado en lazo cerrado.
private final class RTSDriver {
    var v: SitToStandVerifier
    var synth: SitStandSynth
    var events: [VerifierEvent] = []
    /// Transforma cada muestra antes de entregarla al verificador.
    var transform: (SitStandSample) -> SitStandSample = { $0 }
    /// Antes de cada cuadro de `move` / `hold` (p. ej. el pulgar tapa la cámara según la altura).
    var beforeEmit: ((inout SitStandSynth) -> Void)? = nil
    /// Último intento visto y los intentos que terminaron en rep (estadísticas del propio verificador).
    private(set) var lastExcursion: SitToStandVerifier.Excursion? = nil
    private(set) var countedExcursions: [SitToStandVerifier.Excursion] = []
    private(set) var attemptExcursions: [SitToStandVerifier.Excursion] = []
    /// Variación humana de cada duración de `move` / `hold` (±fracción): nadie es un metrónomo.
    var timing = 0.12
    private var timingRNG = FixtureRandom(seed: 99)
    private var fed = 0

    init(target: Int, seed: UInt64 = 42, synthSeed: UInt64 = 1,
         body: SitStandSynth.Body = SitStandSynth.Body(), noise: SitStandSynth.Noise = SitStandSynth.Noise()) {
        v = SitToStandVerifier(spec: RTS.spec(target), kind: sitStandKind, seed: seed)
        v.start(at: 0)
        synth = SitStandSynth(seed: synthSeed, body: body, noise: noise)
    }

    func flush() {
        let all = synth.samples
        while fed < all.count {
            let s = transform(all[fed])
            fed += 1
            let before = v.count
            events += v.ingest(s, at: s.t)
            if v.count > before, let ex = lastExcursion { countedExcursions.append(ex) }
            if v.excursion == nil, let ex = lastExcursion, attemptExcursions.last != ex { attemptExcursions.append(ex) }
            if let ex = v.excursion { lastExcursion = ex }
        }
    }

    /// Lleva la postura a `target` en `seconds` con perfil coseno.
    func move(_ target: RTSPose, seconds: Double) {
        let h0 = synth.hipRise, f0 = synth.hipForward, l0 = synth.lean, a0 = synth.armsLift, r0 = synth.armsForward
        let n = max(1, Int((seconds * (1 + timingRNG.symmetric(timing)) * synth.fps).rounded()))
        for i in 1...n {
            let u = (1 - cos(.pi * Double(i) / Double(n))) / 2
            synth.hipRise = h0 + ((target.hip ?? h0) - h0) * u
            synth.hipForward = f0 + ((target.forward ?? f0) - f0) * u
            synth.lean = l0 + ((target.lean ?? l0) - l0) * u
            synth.armsLift = a0 + ((target.arms ?? a0) - a0) * u
            synth.armsForward = r0 + ((target.reach ?? r0) - r0) * u
            beforeEmit?(&synth)
            synth.emit()
        }
        flush()
    }

    func hold(_ seconds: Double) {
        for _ in 0..<max(1, Int((seconds * (1 + timingRNG.symmetric(timing)) * synth.fps).rounded())) {
            beforeEmit?(&synth)
            synth.emit()
        }
        flush()
    }

    /// Rep honesta (cumple el desafío si lo hay).
    func honestRep(_ challenge: RTSChallenge?, base: SitStandSynth.Rep = SitStandSynth.Rep()) {
        var r = synth.naturalRep(base)
        if challenge == .stand { r.standSeconds = max(r.standSeconds, RTS.challengeHold) }
        if challenge == .sit { r.seatedSeconds = max(r.seatedSeconds, RTS.challengeHold) }
        synth.rep(r)
        flush()
    }

    /// Repite `attempt` hasta la meta o `maxAttempts`, leyendo el desafío que muestra la pantalla.
    func series(maxAttempts: Int, _ attempt: (RTSDriver, RTSChallenge?) -> Void) {
        for _ in 0..<maxAttempts where v.phase != .done {
            flush()
            attempt(self, v.activeChallenge?.kind)
        }
    }

    func finish(_ reason: FinishReason = .timeout) -> ActivityOutcome {
        v.finish(at: synth.t, reason: reason)
    }

    func anomalies(_ kind: String, _ severity: Anomaly.Severity? = nil) -> [Anomaly] {
        v.anomalies.filter { $0.kind == kind && (severity == nil || $0.severity == severity) }
    }

    func rejections(_ reason: SitToStandVerifier.Rejection) -> Int {
        v.rejections.filter { $0.reason == reason }.count
    }

    /// Avisos que no deberían aparecerle a una persona honesta.
    var badCues: [String] {
        let bad = [SitStandCopy.torsoOnly, SitStandCopy.partial, SitStandCopy.notSeated, SitStandCopy.sitUpright,
                   SitStandCopy.armsOnly, SitStandCopy.tooSlow, SitStandCopy.noTravel, SitStandCopy.phoneTilted]
        return events.compactMap { e -> String? in
            if case .cue(let c) = e, bad.contains(c.text) { return c.text }
            return nil
        }
    }

    /// Pasa de largo a "full" con la meta completa.
    func fullCredit(_ outcome: ActivityOutcome) -> Bool {
        outcome.completed && RTS.level(outcome) == .full
    }

    @discardableResult
    func log(_ name: String, _ outcome: ActivityOutcome) -> String {
        let rej = Dictionary(grouping: v.rejections, by: \.reason)
            .map { "\($0.key.rawValue)×\($0.value.count)" }.sorted().joined(separator: ",")
        let an = outcome.anomalies.map { "\($0.kind)/\($0.severity.rawValue)" }.joined(separator: ",")
        let line = "RTS| \(name): count=\(v.count)/\(v.spec.target) level=\(RTS.level(outcome)) rej=[\(rej)] anom=[\(an)]"
        print(line)
        for (i, ex) in countedExcursions.enumerated().prefix(3) { print("RTS|   rep \(i + 1): \(RTS.stats(ex))") }
        return line
    }

    /// Montaje rígido: la "cara" (foto o vídeo en otro teléfono) va fija frente a la cámara frontal, a la
    /// distancia y altura en que estaría la cara real; se mueve exactamente con el teléfono.
    func useRig(_ source: RTSFaceSource, seed: UInt64 = 77) {
        var rng = FixtureRandom(seed: seed)
        var offset: SIMD3<Float>? = nil
        var inPhone: SIMD3<Float>? = nil
        var lastSpike = -Double.infinity
        transform = { s in
            var s = s
            let o = offset ?? (s.facePos - s.phonePos)
            offset = o
            let ip = inPhone ?? s.faceInPhone
            inPhone = ip
            s.faceTracked = true
            s.facePos = s.phonePos + o + RTS.jitter(&rng, 0.002)
            s.faceInPhone = ip + RTS.jitter(&rng, 0.002)
            // Foto o pantalla: plana para TrueDepth (cuando el cuadro trae profundidad).
            if s.faceRelief != nil { s.faceRelief = Float(0.0015 + rng.unit() * 0.001) }
            switch source {
            case .video:
                s.shapeEnergy = Float(0.008 + rng.unit() * 0.05)
            case .photo:
                s.shapeEnergy = 0
            case .photoWithTrackingNoise(let every):
                if s.t - lastSpike >= every {
                    lastSpike = s.t
                    s.shapeEnergy = 0.003
                } else {
                    s.shapeEnergy = 0
                }
            }
            return s
        }
    }
}

/// Red team de fraude (lente: brazos, levantarse a medias, inclinarse sin pararse, foto o vídeo frente a la
/// cámara frontal, tapar la cámara, sacudir, caminar, escalón, ascensor, otra persona y teléfono sobre una
/// mesa), convertido en regresión. Lazo cerrado: el tramposo lee `activeChallenge` antes de cada intento y
/// cada duración varía ±12 %. Cada test imprime líneas "RTS| …" con lo medido.
/// Lo que sigue abierto va en `withKnownIssue("RESIDUAL …")`: si un cambio lo cierra, Swift Testing avisa.
struct SitToStandFraudTests {

    // MARK: Brazos

    @Test func brazosSentadoSubiendoElTelefonoNoCuenta() {
        let d = RTSDriver(target: 8)
        d.hold(1.6)
        let lifts = [0.27, 0.32, 0.40, 0.30, 0.35, 0.28]
        var i = 0
        d.series(maxAttempts: lifts.count) { d, c in
            let lift = lifts[i]
            i += 1
            d.move(RTSPose(arms: lift), seconds: 0.9)
            d.hold(c == .stand ? RTS.challengeHold : 0.6)
            d.move(RTSPose(arms: 0), seconds: 0.9)
            d.hold(c == .sit ? RTS.challengeHold : 1.0)
        }
        let outcome = d.finish()
        d.log("brazos sentado", outcome)
        #expect(d.v.count == 0)
        #expect(d.rejections(.armsOnly) == lifts.count)
        #expect(!d.anomalies(SitStandAnomaly.armsOnly, .hard).isEmpty)
        #expect(RTS.level(outcome) == .suspicious)
    }

    // MARK: Levantarse a medias

    @Test func levantarseAMedias10CmRepetidoNoCuenta() {
        let d = RTSDriver(target: 8)
        d.hold(1.6)
        var i = 0
        d.series(maxAttempts: 10) { d, c in
            let topLean = i.isMultiple(of: 2) ? 12.0 : 0.0
            i += 1
            d.move(RTSPose(forward: 0.05, lean: 35), seconds: 0.6)
            d.move(RTSPose(hip: 0.10, forward: 0.10, lean: topLean), seconds: 0.6)
            d.hold(c == .stand ? RTS.challengeHold : 0.5)
            d.move(RTSPose(hip: 0, forward: 0, lean: 25), seconds: 0.6)
            d.move(RTSPose(lean: 0), seconds: 0.5)
            d.hold(c == .sit ? RTS.challengeHold : 1.0)
        }
        let outcome = d.finish()
        d.log("medio parado 10 cm", outcome)
        #expect(d.v.count == 0)
    }

    @Test func levantarseAMediasYEmpujarElTelefonoConLosBrazosNoCuenta() {
        // Despega la cadera `hip` y completa con los brazos hasta 27 cm de subida del teléfono. Antes contaba
        // desde 18 cm (40 % de una parada); ahora la cara tiene que subir ≥ `minFaceRise` (20 cm).
        var counted: [(hip: Double, count: Int)] = []
        for hip in stride(from: 0.10, through: 0.26, by: 0.02) {
            let d = RTSDriver(target: 4, synthSeed: 3)
            d.hold(1.6)
            d.series(maxAttempts: 4) { d, c in
                d.move(RTSPose(forward: 0.05, lean: 35), seconds: 0.6)
                d.move(RTSPose(hip: hip, forward: 0.15, lean: 0), seconds: 0.7)
                d.move(RTSPose(arms: max(0, 0.27 - hip)), seconds: 0.5)
                d.hold(c == .stand ? RTS.challengeHold : 0.5)
                d.move(RTSPose(arms: 0), seconds: 0.5)
                d.move(RTSPose(hip: 0, forward: 0, lean: 25), seconds: 0.7)
                d.move(RTSPose(lean: 0), seconds: 0.4)
                d.hold(c == .sit ? RTS.challengeHold : 1.0)
            }
            let outcome = d.finish()
            d.log(String(format: "medio parado %.0f cm + brazos %.0f cm", hip * 100, max(0, 0.27 - hip) * 100), outcome)
            counted.append((hip, d.v.count))
            if hip < 0.19 { #expect(d.v.count == 0, "Cuenta con la cadera a \(hip) m") }
        }
        let cheapest = counted.filter { $0.count > 0 }.map(\.hip).min()
        print("RTS| subida mínima de la cadera que cuenta: \(cheapest.map { String(format: "%.0f cm", $0 * 100) } ?? "ninguna")")
        #expect((cheapest ?? 1) >= 0.20)
    }

    @Test func inclinarseAdelanteYDespegarApenasNoCuenta() {
        let d = RTSDriver(target: 8)
        d.hold(1.6)
        d.series(maxAttempts: 8) { d, c in
            d.move(RTSPose(forward: 0.08, lean: 48), seconds: 1.0)
            d.move(RTSPose(hip: 0.05, forward: 0.12), seconds: 0.4)
            d.hold(c == .stand ? RTS.challengeHold : 0.6)
            d.move(RTSPose(hip: 0, forward: 0, lean: 0), seconds: 1.0)
            d.hold(c == .sit ? RTS.challengeHold : 1.0)
        }
        let outcome = d.finish()
        d.log("inclinarse 48° y despegar 5 cm", outcome)
        #expect(d.v.count == 0)
        #expect(d.rejections(.torsoOnly) == 8)
    }

    // MARK: Foto o vídeo pegado frente a la cámara frontal

    /// Montaje rígido sentado + brazos que suben el conjunto 32 cm (opcionalmente adelantándolo `reach`).
    private func rigSeries(_ source: RTSFaceSource, reach: Double = 0, depth: Bool = true) -> (RTSDriver, ActivityOutcome) {
        let d = RTSDriver(target: 8)
        d.synth.depth = depth
        d.useRig(source)
        d.hold(1.6)
        d.series(maxAttempts: 10) { d, c in
            d.move(RTSPose(arms: 0.32, reach: reach), seconds: 0.9)
            d.hold(c == .stand ? RTS.challengeHold : 0.6)
            d.move(RTSPose(arms: 0, reach: 0), seconds: 0.9)
            d.hold(c == .sit ? RTS.challengeHold : 1.0)
        }
        return (d, d.finish(.completed))
    }

    @Test func montajeConFotoEstaticaNoCuenta() {
        let (d, outcome) = rigSeries(.photo)
        d.log("montaje foto estática + brazos", outcome)
        #expect(d.v.count == 0)
        #expect(!d.anomalies(SitStandAnomaly.staticFace, .hard).isEmpty)
        #expect(RTS.level(outcome) == .suspicious)
    }

    @Test(arguments: [1.2, 0.2])
    func montajeConFotoYRuidoDeTrackingNoCuenta(every: Double) {
        // Un cuadro de ruido de blendShapes cada `every` s (luz, reflejo): antes nunca había 2 s seguidos bajo
        // el umbral y contaba 8/8 full. Ahora la vida se mide por fracción (ventana de 2 s y por rep).
        let (d, outcome) = rigSeries(.photoWithTrackingNoise(every: every))
        d.log("montaje foto + ruido cada \(every) s + brazos", outcome)
        #expect(d.v.count == 0)
        #expect(!d.fullCredit(outcome))
        #expect(!d.anomalies(SitStandAnomaly.staticFace, .hard).isEmpty)
    }

    @Test func montajeConVideoDeCaraEnOtroTelefonoNoCuenta() {
        // La "cara" sube con el teléfono y no se mueve en su espacio; antes contaba 8/8 full. Pararse adelanta
        // la cara ≥ 20 cm (sobre los pies); el montaje, 1 cm.
        let (d, outcome) = rigSeries(.video)
        d.log("montaje vídeo + brazos", outcome)
        #expect(d.v.count == 0)
        #expect(!d.fullCredit(outcome))
        #expect(d.rejections(.noTravel) > 0)
    }

    @Test func montajeConVideoAdelantadoEsCaraPlana() {
        // El tramposo también adelanta el montaje 15 cm (pasa el chequeo de traslado): TrueDepth lo ve plano.
        let (d, outcome) = rigSeries(.video, reach: 0.15)
        d.log("montaje vídeo adelantado 15 cm + brazos", outcome)
        #expect(d.v.count == 0)
        #expect(d.rejections(.flatFace) > 0)
        #expect(!d.anomalies(SitStandAnomaly.flatFace, .hard).isEmpty)
        #expect(RTS.level(outcome) == .suspicious)
    }

    @Test func montajeConVideoAdelantadoSinProfundidadEsResidual() {
        // Sin mapa de profundidad (sol directo sobre la cámara frontal) no hay relieve que medir.
        let (d, outcome) = rigSeries(.video, reach: 0.15, depth: false)
        d.log("montaje vídeo adelantado sin profundidad (residual)", outcome)
        withKnownIssue("RESIDUAL: sin profundidad TrueDepth, un vídeo de cara en un montaje que además se adelanta 15 cm cuenta") {
            #expect(d.v.count == 0)
        }
    }

    // MARK: Ocultar la cara arriba

    @Test(arguments: SitToStandVerifier.HoldChallenge.Kind.allCases)
    func taparLaCamaraFrontalArribaNoCuenta(challengeKind: SitToStandVerifier.HoldChallenge.Kind) {
        // Se sienta derecho (+7 cm), sube el teléfono con los brazos y tapa la cámara frontal con el pulgar
        // mientras el teléfono está > 14 cm arriba (< 1,5 s). Antes contaba 8/8: "de pie" exige ahora ver la cara
        // arriba (≥ 20 cm) en el mismo cuadro.
        let d = RTSDriver(target: 8, seed: RTS.seed(for: challengeKind, target: 8))
        d.timing = 0.06
        d.hold(1.6)
        var honest = 0
        d.series(maxAttempts: 10) { d, c in
            if c == .stand {
                honest += 1
                d.honestRep(c)
                return
            }
            d.beforeEmit = { s in s.faceTracked = s.hipRise + s.armsLift < 0.14 }
            d.move(RTSPose(hip: 0.07), seconds: 0.5)
            d.move(RTSPose(arms: 0.25), seconds: 0.8)
            d.hold(0.3)
            d.move(RTSPose(arms: 0), seconds: 0.8)
            d.beforeEmit = nil
            d.synth.faceTracked = true
            d.move(RTSPose(hip: 0), seconds: 0.5)
            d.hold(c == .sit ? RTS.challengeHold : 1.0)
        }
        let outcome = d.finish(.completed)
        d.log("pulgar sobre la cámara arriba, desafío \(challengeKind) (\(honest) rep honesta)", outcome)
        #expect(d.v.count <= honest)
        #expect(!d.fullCredit(outcome))
    }

    // MARK: Sacudir

    @Test func sacudirYBombearElTelefonoNoCuenta() {
        let d = RTSDriver(target: 8)
        d.hold(1.6)
        d.synth.shake(seconds: 2, amplitude: 0.12, hz: 5)
        d.flush()
        d.hold(1.0)
        for _ in 0..<6 {
            d.move(RTSPose(arms: 0.30), seconds: 0.33)
            d.move(RTSPose(arms: 0), seconds: 0.33)
        }
        d.hold(1.0)
        let outcome = d.finish()
        d.log("sacudir y bombear", outcome)
        #expect(d.v.count == 0)
        #expect(!d.anomalies(SitStandAnomaly.shaking, .hard).isEmpty)
        #expect(RTS.level(outcome) == .suspicious)
    }

    @Test func dosGlitchesDeTrackingEnUnaSerieHonestaNoLaVuelvenSospechosa() {
        // Dos saltos de un cuadro (15 cm, ida y vuelta) a 0,8 s: antes daban 4 picos y `shaking` hard.
        let d = RTSDriver(target: 8)
        let glitches: Set<Int> = [400, 448]
        var index = 0
        d.transform = { s in
            var s = s
            defer { index += 1 }
            if glitches.contains(index) { s.phonePos.x += 0.15 }
            return s
        }
        d.hold(1.6)
        d.series(maxAttempts: 8) { d, c in d.honestRep(c) }
        d.hold(1)
        let outcome = d.finish(.completed)
        d.log("serie honesta con 2 glitches de tracking", outcome)
        #expect(d.anomalies(SitStandAnomaly.shaking).isEmpty)
        #expect(d.fullCredit(outcome))
    }

    // MARK: Caminar, escalón, ascensor

    @Test func caminarConElTelefonoNoCuenta() {
        let d = RTSDriver(target: 8)
        d.hold(1.6)
        d.synth.standUp(seconds: 1.3, rise: 0.42, forward: 0.30, leanDeg: 38)
        d.synth.walk(seconds: 20, speed: 1.2, cadence: 1.8)
        d.flush()
        d.hold(1)
        let outcome = d.finish()
        d.log("caminar 20 s", outcome)
        #expect(d.v.count == 0)
        #expect(d.anomalies(SitStandAnomaly.walking, .soft).count == 1)
    }

    /// Calibra de pie al pie de un escalón y sube y baja (el cuerpo entero sube y avanza, sin silla).
    private func stepSeries(_ stepHeight: Double, pedometer: Bool) -> (RTSDriver, ActivityOutcome) {
        var body = SitStandSynth.Body()
        body.seatHipY = 0.92
        let d = RTSDriver(target: 8, body: body)
        d.synth.standing = true
        if !pedometer { d.synth.steps = nil }
        d.hold(1.6)
        func step(_ d: RTSDriver) { if pedometer { d.synth.steps = (d.synth.steps ?? 0) + 1 } }
        d.series(maxAttempts: 10) { d, c in
            step(d)
            d.move(RTSPose(hip: stepHeight / 2, forward: 0.14, lean: 8), seconds: 0.5)
            step(d)
            d.move(RTSPose(hip: stepHeight, forward: 0.28, lean: 0), seconds: 0.5)
            d.hold(c == .stand ? RTS.challengeHold : 0.6)
            step(d)
            d.move(RTSPose(hip: stepHeight / 2, forward: 0.14, lean: 5), seconds: 0.5)
            step(d)
            d.move(RTSPose(hip: 0, forward: 0, lean: 0), seconds: 0.5)
            d.hold(c == .sit ? RTS.challengeHold : 1.0)
        }
        return (d, d.finish(.completed))
    }

    @Test(arguments: [0.26, 0.34])
    func subirYBajarUnEscalonDePieQuedaSospechoso(stepHeight: Double) {
        // Antes: 8/8 full con `walking` soft. Ahora 4 pasos por rep contada (≥ 2,5) → `walking` hard.
        let (d, outcome) = stepSeries(stepHeight, pedometer: true)
        d.log(String(format: "escalón de %.0f cm de pie", stepHeight * 100), outcome)
        #expect(d.anomalies(SitStandAnomaly.walking, .soft).count == 1)
        #expect(d.anomalies(SitStandAnomaly.walking, .hard).count == 1)
        #expect(!d.fullCredit(outcome))
        #expect(RTS.level(outcome) == .suspicious)
    }

    @Test func subirYBajarUnEscalonSinPodometroEsResidual() {
        let (d, outcome) = stepSeries(0.26, pedometer: false)
        d.log("escalón de 26 cm sin podómetro (residual)", outcome)
        withKnownIssue("RESIDUAL: sin podómetro (o sin permiso de Movimiento) subir y bajar un escalón de pie no se distingue de pararse de una silla") {
            #expect(!d.fullCredit(outcome))
        }
    }

    @Test func ascensorConViajeYPuertasNoCuenta() {
        var body = SitStandSynth.Body()
        body.seatHipY = 0.92
        let d = RTSDriver(target: 4, body: body)
        d.synth.standing = true
        d.hold(1.6)
        for _ in 0..<3 {
            d.move(RTSPose(hip: 3.0), seconds: 4)
            d.hold(4)
            d.move(RTSPose(hip: 0), seconds: 4)
            d.hold(4)
        }
        let outcome = d.finish()
        d.log("ascensor un piso ida y vuelta", outcome)
        #expect(d.v.count == 0)
        #expect(d.anomalies(SitStandAnomaly.altitudeDrift, .soft).count == 1)
    }

    @Test func ascensorRapidoSinPuertasNoCuenta() {
        // Peor caso irreal (VIO ideal, 3 m en 3 s): antes contaba 4/4 full; la cara no se traslada.
        var body = SitStandSynth.Body()
        body.seatHipY = 0.92
        let d = RTSDriver(target: 4, body: body)
        d.synth.standing = true
        d.hold(1.6)
        d.series(maxAttempts: 4) { d, c in
            d.move(RTSPose(hip: 3.0), seconds: 3)
            d.hold(c == .stand ? RTS.challengeHold : 1.5)
            d.move(RTSPose(hip: 0), seconds: 3)
            d.hold(c == .sit ? RTS.challengeHold : 1.5)
        }
        let outcome = d.finish(.completed)
        d.log("ascensor rápido sin puertas (VIO ideal)", outcome)
        #expect(d.anomalies(SitStandAnomaly.altitudeDrift, .soft).count == 1)
        #expect(d.v.count == 0)
        #expect(d.rejections(.noTravel) == 4)
    }

    // MARK: Pasos honestos

    @Test(arguments: [1, 2])
    func serieHonestaConPasosEspuriosSigueFull(stepsPerRep: Int) {
        // El podómetro cuenta el impulso de pararse, o la persona reacomoda los pies: solo `walking` soft.
        let d = RTSDriver(target: 8, synthSeed: 12)
        d.hold(1.6)
        d.series(maxAttempts: 10) { d, c in
            d.synth.steps = (d.synth.steps ?? 0) + stepsPerRep
            d.honestRep(c)
        }
        d.hold(1)
        let outcome = d.finish(.completed)
        d.log("honesto con \(stepsPerRep) paso(s) espurio(s) por rep", outcome)
        #expect(d.anomalies(SitStandAnomaly.walking, .hard).isEmpty)
        #expect(d.fullCredit(outcome))
    }

    @Test func caminarHastaLaSillaAntesDeEmpezarSigueFull() {
        let d = RTSDriver(target: 8, synthSeed: 12)
        d.hold(1.6)
        d.synth.steps = 10
        d.hold(1.0)
        d.series(maxAttempts: 10) { d, c in d.honestRep(c) }
        d.hold(1)
        let outcome = d.finish(.completed)
        d.log("10 pasos antes de la primera rep", outcome)
        #expect(d.fullCredit(outcome))
    }

    // MARK: Ritmo

    @Test(arguments: 0..<2)
    func pararseApenasSeSientaCuentaCadaRep(style: Int) {
        // Técnica de la prueba de 30 s: sentarse del todo y pararse de inmediato (0,4 s; lento: 0,6 s).
        // Antes se perdían 2 de 32 con 0,4 s.
        var base = SitStandSynth.Rep()
        if style == 1 {
            base.riseSeconds = 3.4
            base.standSeconds = 0.8
            base.sitSeconds = 3.6
        }
        let pause = style == 0 ? 0.4 : 0.6
        var counted = 0, attempts = 0
        for seed in UInt64(1)...UInt64(6) {
            let d = RTSDriver(target: 8, seed: seed, synthSeed: seed + 40)
            d.hold(1.6)
            d.series(maxAttempts: 8) { d, c in
                attempts += 1
                var r = d.synth.naturalRep(base, jitter: 0.5)
                r.seatedSeconds = c == .sit ? RTS.challengeHold : pause
                if c == .stand { r.standSeconds = max(r.standSeconds, RTS.challengeHold) }
                d.synth.rep(r)
                d.flush()
            }
            d.hold(1)
            counted += d.v.count
        }
        print("RTS| sin pausa (\(style == 0 ? "normal 0,4 s" : "lento 0,6 s")): \(counted) de \(attempts) reps honestas contadas")
        #expect(counted == attempts)
    }

    @Test func personaLentaHonestaNoPierdeRepsNiRecibeAvisosFalsos() {
        // Se para en ~3,4 s y se sienta en ~3,6 s inclinando el tronco ~30°. Antes: 7 reps perdidas, 1 sesión
        // suspicious y avisos "Siéntese del todo" / "Párese del todo" a alguien que lo hacía bien (la rep
        // cerraba a media bajada con el tronco inclinado y la referencia "sentado" derivaba hacia abajo).
        var slow = SitStandSynth.Rep()
        slow.riseSeconds = 3.4
        slow.sitSeconds = 3.6
        var notFull = 0, lost = 0, rejected = 0, badCues = 0
        for seed in UInt64(1)...UInt64(24) {
            let d = RTSDriver(target: 8, seed: seed, synthSeed: seed + 20)
            d.hold(1.6)
            var attempts = 0
            d.series(maxAttempts: 14) { d, c in
                attempts += 1
                d.honestRep(c, base: slow)
            }
            d.hold(1)
            let outcome = d.finish(.completed)
            lost += attempts - d.v.count
            rejected += d.v.rejections.count
            badCues += d.badCues.count
            if !d.fullCredit(outcome) {
                notFull += 1
                d.log("lento semilla \(seed)", outcome)
            }
            // La referencia "sentado" no deriva bajo el asiento real.
            #expect(abs(d.v.reference?.phoneY ?? 1) < SitToStandVerifier.seatedBand / 2, "Semilla \(seed)")
        }
        print("RTS| lento honesto (24 semillas × 8 reps): \(lost) perdidas, \(notFull) no full, \(rejected) rechazos, \(badCues) avisos falsos")
        #expect(lost == 0)
        #expect(notFull == 0)
        #expect(rejected == 0)
        #expect(badCues == 0)
    }

    @Test func seSientaMasAdelanteEnLaSillaYSigueContando() {
        // Tras pararse vuelve a sentarse 14 cm más adelante en la silla (derecho): la rep cierra igual.
        var ok = 0
        for seed in UInt64(1)...UInt64(6) {
            let d = RTSDriver(target: 4, seed: seed, synthSeed: seed + 60)
            d.hold(1.6)
            d.series(maxAttempts: 6) { d, c in
                var r = d.synth.naturalRep(SitStandSynth.Rep())
                if c == .stand { r.standSeconds = max(r.standSeconds, RTS.challengeHold) }
                d.synth.standUp(seconds: r.riseSeconds, rise: r.rise, forward: r.forward, leanDeg: r.leanDeg)
                d.synth.hold(r.standSeconds)
                let n = Int((r.sitSeconds * d.synth.fps).rounded())
                let r0 = d.synth.hipRise, f0 = d.synth.hipForward, edge = 0.14
                for k in 1...n {
                    let u = Double(k) / Double(n)
                    d.synth.lean = r.sitLeanDeg * (1 - cos(2 * .pi * u)) / 2
                    d.synth.hipRise = r0 * (1 - SitStandSynth.smoothstep(u / 0.85))
                    d.synth.hipForward = edge + (f0 - edge) * (1 - SitStandSynth.smoothstep(u))
                    d.synth.standing = u < 0.3
                    d.synth.emit()
                }
                d.synth.lean = 0
                d.synth.standing = false
                d.synth.hold(c == .sit ? RTS.challengeHold : 2.0)
                d.flush()
            }
            d.hold(1)
            let outcome = d.finish(.completed)
            if d.v.count == 4 && d.fullCredit(outcome) { ok += 1 } else { d.log("se sienta adelante, semilla \(seed)", outcome) }
        }
        #expect(ok == 6)
    }

    // MARK: Re-anclaje (no abre trampas)

    @Test func inclinarseSobreLasRodillasYQuedarseQuietoNoReAnclaUnaTrampa() {
        // De pie, se inclina sobre las rodillas compensando con las muñecas y aguanta 7 s; después "reps"
        // enderezándose desde ahí.
        let d = RTSDriver(target: 4)
        d.hold(1.6)
        d.synth.standUp(seconds: 1.3, rise: 0.42, forward: 0.30, leanDeg: 38)
        d.flush()
        d.hold(0.6)
        var body = d.synth.body
        body.pitchFollow = 0
        d.synth.body = body
        d.move(RTSPose(hip: 0.12, lean: 40), seconds: 1.2)
        d.hold(7)
        for _ in 0..<5 {
            d.move(RTSPose(hip: 0.30, lean: 0), seconds: 1.0)
            d.hold(0.6)
            d.move(RTSPose(hip: 0.12, lean: 40), seconds: 1.0)
            d.hold(1.0)
        }
        let outcome = d.finish()
        d.log("inclinado sobre las rodillas 7 s y reps desde ahí", outcome)
        #expect(d.v.count == 0)
    }

    @Test func bloquearElTrackingMedioParadoNoReAnclaUnaTrampa() {
        // Tapa la cámara trasera medio parado (cadera +20 cm), aguanta 7 s y hace "reps" medio ↔ de pie.
        let d = RTSDriver(target: 4)
        d.hold(1.6)
        d.move(RTSPose(forward: 0.05, lean: 35), seconds: 0.6)
        d.move(RTSPose(hip: 0.20, forward: 0.25, lean: 0), seconds: 0.8)
        d.synth.worldTrackingNormal = false
        d.hold(0.8)
        d.synth.worldTrackingNormal = true
        d.hold(7)
        for _ in 0..<5 {
            d.move(RTSPose(hip: 0.42, forward: 0.30), seconds: 1.0)
            d.hold(0.6)
            d.move(RTSPose(hip: 0.20, forward: 0.25), seconds: 1.0)
            d.hold(1.0)
        }
        let outcome = d.finish()
        d.log("bloqueo medio parado y reps medio ↔ de pie", outcome)
        #expect(d.v.count == 0)
    }

    // MARK: Límites aceptados

    @Test func otraPersonaHaciendoElEjercicioCuentaLimiteAceptado() {
        // Sin identidad biométrica continua no se sabe quién es: un compañero más alto, en otra silla y
        // orientación, hace las 8 reps con el teléfono de Marco y la sesión queda full.
        var body = SitStandSynth.Body()
        body.seatHipY = 0.44
        body.trunkToPhone = 0.46
        body.phoneAhead = 0.26
        body.trunkToFace = 0.80
        body.faceAhead = 0.10
        body.phonePitchDeg = 42
        body.pitchFollow = 0.7
        body.headingDeg = -75
        var rep = SitStandSynth.Rep()
        rep.rise = 0.47
        rep.forward = 0.33
        rep.leanDeg = 42
        let d = RTSDriver(target: 8, seed: 5, synthSeed: 9, body: body)
        d.hold(1.6)
        d.series(maxAttempts: 8) { d, c in d.honestRep(c, base: rep) }
        d.hold(1)
        let outcome = d.finish(.completed)
        d.log("otra persona (límite aceptado)", outcome)
        #expect(d.v.count == 8)
        #expect(d.fullCredit(outcome))
    }

    @Test func quedarseSuspendidoSobreLaSillaYPararseCuentaLimiteAceptado() {
        // No se sienta del todo: queda suspendido 12 cm sobre la silla 3 s y se para entero. Cada rep es una
        // parada completa más una isometría: más trabajo de piernas, no menos. Se re-ancla y cuenta.
        let d = RTSDriver(target: 4)
        d.hold(1.6)
        d.synth.standUp(seconds: 1.4, rise: 0.40, forward: 0.28, leanDeg: 36)
        d.synth.hold(0.8)
        for _ in 0..<5 {
            let n = Int((1.2 * d.synth.fps).rounded())
            for i in 1...n {
                let u = Double(i) / Double(n)
                d.synth.hipRise = 0.40 - 0.28 * SitStandSynth.smoothstep(u)
                d.synth.hipForward = 0.28 * (1 - SitStandSynth.smoothstep(u))
                d.synth.emit()
            }
            d.synth.hold(3.0)
            for i in 1...n {
                let u = Double(i) / Double(n)
                d.synth.hipRise = 0.12 + 0.28 * SitStandSynth.smoothstep(u)
                d.synth.hipForward = 0.28 * SitStandSynth.smoothstep(u)
                d.synth.emit()
            }
            d.synth.hold(0.8)
        }
        d.flush()
        let outcome = d.finish()
        d.log("suspendido 12 cm sobre la silla (límite aceptado)", outcome)
        #expect(d.v.count == 4)
        #expect(d.v.reanchorCount >= 1)
    }

    @Test func telefonoSobreUnaMesaQueSeLevantaNoCuenta() {
        var noise = SitStandSynth.Noise()
        noise.tremor = 0
        noise.angleJitterDeg = 0.2
        let d = RTSDriver(target: 8, noise: noise)
        d.hold(1.6)
        d.series(maxAttempts: 4) { d, c in
            d.move(RTSPose(arms: 0.30), seconds: 1.0)
            d.hold(c == .stand ? RTS.challengeHold : 0.6)
            d.move(RTSPose(arms: 0), seconds: 1.0)
            d.hold(c == .sit ? RTS.challengeHold : 1.0)
        }
        for _ in 0..<2 {
            d.move(RTSPose(arms: 0.30), seconds: 7.5)
            d.hold(1)
            d.move(RTSPose(arms: 0), seconds: 7.5)
            d.hold(1)
        }
        let outcome = d.finish()
        d.log("mesa que se levanta", outcome)
        #expect(d.v.count == 0)
        #expect(d.rejections(.armsOnly) >= 4)
        #expect(RTS.level(outcome) == .suspicious)
    }

    // MARK: Márgenes de los umbrales

    @Test func margenesHonestosDeLosUmbrales() {
        // Cinco estilos honestos: lo que mide el verificador por rep, contra los umbrales nuevos.
        var high = SitStandSynth.Rep()
        high.rise = 0.26
        high.forward = 0.15
        high.leanDeg = 22
        high.sitLeanDeg = 18
        var slow = SitStandSynth.Rep()
        slow.riseSeconds = 3.4
        slow.sitSeconds = 3.6
        var stiffWrists = SitStandSynth.Body()
        stiffWrists.pitchFollow = 0.92
        var looseWrists = SitStandSynth.Body()
        looseWrists.pitchFollow = 0.6
        let styles: [(String, SitStandSynth.Rep, SitStandSynth.Body)] = [
            ("normal", SitStandSynth.Rep(), SitStandSynth.Body()),
            ("silla alta 26 cm", high, SitStandSynth.Body()),
            ("silla alta + muñecas 0,6", high, looseWrists),
            ("muñecas 0,92", SitStandSynth.Rep(), stiffWrists),
            ("lento", slow, SitStandSynth.Body()),
        ]
        for (name, rep, body) in styles {
            var minFaceRise = Double.infinity, maxGap = -Double.infinity, minShift = Double.infinity
            var minLive = Double.infinity, maxFlat = 0
            for seed in UInt64(1)...UInt64(4) {
                let d = RTSDriver(target: 8, seed: seed, synthSeed: seed + 20, body: body)
                d.hold(1.6)
                d.series(maxAttempts: 12) { d, c in d.honestRep(c, base: rep) }
                d.hold(1)
                let outcome = d.finish(.completed)
                #expect(d.v.count == 8, "\(name) semilla \(seed): \(d.v.rejections)")
                #expect(d.fullCredit(outcome))
                #expect(d.badCues.isEmpty, "\(name) semilla \(seed): \(d.badCues)")
                for ex in d.countedExcursions {
                    minFaceRise = min(minFaceRise, ex.maxFaceRise)
                    maxGap = max(maxGap, ex.maxRiseGap)
                    minShift = min(minShift, ex.maxFaceShift)
                    minLive = min(minLive, Double(ex.liveSamples) / Double(max(1, ex.faceSamples)))
                    maxFlat = max(maxFlat, ex.flatSamples)
                }
            }
            print(String(format: "RTS| honesto %@: cara sube ≥ %.3f m, teléfono − cara ≤ %.3f m, cara se traslada ≥ %.3f m, vivos ≥ %.0f %%",
                         name, minFaceRise, maxGap, minShift, minLive * 100))
            #expect(minFaceRise >= SitToStandVerifier.minFaceRise + 0.03, "\(name)")
            #expect(maxGap <= SitToStandVerifier.armsMaxRiseGap - 0.05, "\(name)")
            #expect(minShift >= 2 * SitToStandVerifier.minFaceTravel, "\(name)")
            #expect(minLive >= 2 * SitToStandVerifier.minLiveFraction, "\(name)")
            #expect(maxFlat == 0, "\(name)")
        }
    }
}

// MARK: - Red team: falsos negativos

// MARK: - Modelo del operador (lazo cerrado)

/// Cómo se para y se sienta un operador real. Por omisión: cadera que sube 38 cm (≈ 1,75 m en una silla de
/// 45 cm), tronco que se inclina 40° al despegar, ciclo ≈ 6 s (el sintetizador de la app usa 42 cm y ≈ 4 s).
private nonisolated struct FNStyle {
    /// Subida de la cadera (= del teléfono si el tronco queda derecho), m.
    var riseM = 0.38
    /// Avance de la cadera al pararse (de la silla a sobre los pies), m.
    var forwardM = 0.26
    var leanDeg = 40.0
    var sitLeanDeg = 32.0
    /// Se adelanta en la silla y se inclina antes de despegar.
    var prepSeconds = 0.6
    /// Junta fuerza inclinado, balanceándose, antes de despegar (dolor lumbar).
    var gatherSeconds = 0.0
    var riseSeconds = 1.6
    var standSeconds = 0.8
    var sitSeconds = 1.8
    var seatedSeconds = 1.2
    /// Arriba no queda del todo derecho: tronco inclinado (°).
    var finalLeanDeg = 0.0
    /// Brazos cansados: al pararse el teléfono baja respecto del pecho (m).
    var armsSagM = 0.0
    /// 0 = teléfono fijo al tronco (modelo de `SitStandSynth`); 1 = el teléfono sigue a la cara.
    var headLock = 0.0
    /// Se deja caer al sentarse (caída corta, golpe, rebote del cojín y de los brazos).
    var plop = false
    /// Variación natural entre reps (0 = idénticas).
    var variation = 1.0
}

/// Lo que ve ARKit además del cuerpo (poca luz, relocalización).
private nonisolated struct FNSensors {
    /// Desde `from`, ARKit retoma con el origen del mundo corrido (deriva acumulada en tracking limitado).
    var worldJumpFrom: Double? = nil
    var worldJump = SIMD3<Float>(0, 0, 0)
    /// Tracking del mundo limitado intermitente: `off` s sin, `on` s con, desde `from`.
    var flickerFrom: Double? = nil
    var flickerOff = 0.3
    var flickerOn = 0.4
    /// Cuadros sueltos sin cara: `faceDropFrames` cuadros cada `faceDropEvery` s, desde `faceDropFrom`.
    var faceDropEvery: Double? = nil
    var faceDropFrames = 2
    var faceDropFrom = 0.1
    /// En este intento (1-based), al llegar de pie, el tracking del mundo queda limitado `limitedSeconds`…
    var limitedOnAttempt: Int? = nil
    var limitedSeconds = 0.8
    /// …y ARKit retoma con el origen corrido esto (m).
    var jumpOnRecovery = SIMD3<Float>(0, 0, 0)
}

private nonisolated func fnSpec(_ target: Int) -> VerificationSpec { sitStandSpec(target) }

/// Operador de lazo cerrado: antes de cada rep lee la consigna del verificador (desafío de pie / sentado)
/// y la cumple, como lo haría alguien que mira la pantalla. Hace reps hasta completar o agotar intentos.
private nonisolated struct FNOperator {
    var synth: SitStandSynth
    var verifier: SitToStandVerifier
    var style: FNStyle
    var sensors: FNSensors
    private var rng: FixtureRandom
    private var sag = 0.0
    private(set) var fed = 0
    private(set) var events: [VerifierEvent] = []
    private(set) var hints: [String] = []
    private(set) var attempts = 0

    init(seed: UInt64, target: Int = 4, style: FNStyle = FNStyle(), body: SitStandSynth.Body = SitStandSynth.Body(),
         noise: SitStandSynth.Noise = SitStandSynth.Noise(), sensors: FNSensors = FNSensors()) {
        // Si el teléfono sigue a la cara, también conserva su orientación respecto de ella (la pantalla queda
        // mirando a los ojos): el cabeceo sigue al tronco solo en la parte "rígida".
        var b = body
        b.pitchFollow *= 1 - style.headLock
        synth = SitStandSynth(seed: seed, body: b, noise: noise)
        verifier = SitToStandVerifier(spec: fnSpec(target), kind: sitStandKind, seed: seed &* 7919 &+ 3)
        verifier.start(at: 0)
        self.style = style
        self.sensors = sensors
        rng = FixtureRandom(seed: seed &+ 0xF00D)
    }

    // MARK: Cuerpo

    /// Emite un cuadro: brazos (sigue a la cara y/o cansados) sobre la postura actual del sintetizador.
    private mutating func emit() {
        let th = synth.lean * .pi / 180
        let b = synth.body
        let faceDy = b.trunkToFace * (cos(th) - 1) - b.faceAhead * sin(th)
        let faceDz = b.trunkToFace * sin(th) + b.faceAhead * (cos(th) - 1)
        let phoneDy = b.trunkToPhone * (cos(th) - 1) - b.phoneAhead * sin(th)
        let phoneDz = b.trunkToPhone * sin(th) + b.phoneAhead * (cos(th) - 1)
        synth.armsLift = style.headLock * (faceDy - phoneDy) - sag + plopArms
        synth.armsForward = style.headLock * (faceDz - phoneDz)
        synth.emit()
    }

    private var plopArms = 0.0

    private mutating func phase(_ seconds: Double, _ step: (inout FNOperator, Double) -> Void) {
        let n = max(1, Int((seconds * synth.fps).rounded()))
        for i in 1...n {
            step(&self, Double(i) / Double(n))
            emit()
        }
    }

    mutating func hold(_ seconds: Double) { phase(seconds) { _, _ in } }

    private func vary(_ x: Double, _ fraction: Double, _ rng: inout FixtureRandom) -> Double {
        x * (1 + rng.symmetric(fraction * style.variation))
    }

    private mutating func standUp() {
        let lean = style.leanDeg + rng.symmetric(3 * style.variation)
        let prep = vary(style.prepSeconds, 0.15, &rng)
        let rise = vary(style.riseSeconds, 0.12, &rng)
        let gather = style.gatherSeconds > 0 ? vary(style.gatherSeconds, 0.2, &rng) : 0
        let riseM = style.riseM, fwd = style.forwardM, fin = style.finalLeanDeg, sagM = style.armsSagM
        let scoot = min(0.05, fwd)
        phase(prep) { o, u in
            o.synth.lean = lean * (1 - cos(.pi * u)) / 2
            o.synth.hipForward = scoot * SitStandSynth.smoothstep(u)
        }
        if gather > 0 {
            phase(gather) { o, u in o.synth.lean = lean + 2 * sin(2 * .pi * 1.1 * u * gather) }
        }
        phase(rise) { o, u in
            let k = SitStandSynth.smoothstep(u)
            o.synth.hipRise = riseM * k
            o.synth.hipForward = scoot + (fwd - scoot) * k
            o.synth.lean = fin + (lean - fin) * (1 + cos(.pi * u)) / 2
            o.sag = sagM * k
            o.synth.standing = u > 0.6
        }
    }

    private mutating func sitDown() {
        let r0 = synth.hipRise, f0 = synth.hipForward, l0 = synth.lean, s0 = sag
        if style.plop {
            let sitLean = style.sitLeanDeg * 0.6
            phase(0.35) { o, u in
                o.synth.lean = l0 + (sitLean - l0) * SitStandSynth.smoothstep(u)
                o.synth.hipRise = r0 * (1 - 0.15 * u * u)
                o.synth.hipForward = f0 * (1 - 0.3 * u)
            }
            let r1 = synth.hipRise, f1 = synth.hipForward, l1 = synth.lean
            phase(0.4) { o, u in
                o.synth.hipRise = r1 * (1 - u * u)
                o.synth.hipForward = f1 * (1 - u)
                o.synth.lean = l1 * (1 - u)
                o.sag = s0 * (1 - u)
                o.plopArms = 0.04 * sin(.pi * u) // los brazos se quedan atrás en la caída
                o.synth.standing = false
            }
            phase(0.8) { o, u in // golpe: el cojín cede 2 cm y rebota; los brazos oscilan
                let e = u * 0.8
                o.synth.hipRise = -0.02 * (1 - exp(-e / 0.05)) + 0.01 * (1 - exp(-e / 0.4))
                o.plopArms = -0.05 * exp(-e / 0.12) * cos(2 * .pi * 3.5 * e)
            }
            plopArms = 0
        } else {
            let seconds = vary(style.sitSeconds, 0.12, &rng)
            let sitLean = style.sitLeanDeg + rng.symmetric(3 * style.variation)
            phase(seconds) { o, u in
                let k = SitStandSynth.smoothstep(u)
                o.synth.hipRise = r0 * (1 - SitStandSynth.smoothstep(u / 0.85))
                o.synth.hipForward = f0 * (1 - k)
                o.synth.lean = l0 * (1 - k) + sitLean * (1 - cos(2 * .pi * u)) / 2
                o.sag = s0 * (1 - k)
                o.synth.standing = u < 0.3
            }
        }
        synth.lean = 0
        synth.hipRise = 0
        synth.hipForward = 0
        sag = 0
        synth.standing = false
    }

    /// Una rep siguiendo la consigna de la pantalla.
    mutating func rep() {
        let challenge = verifier.activeChallenge?.kind
        standUp()
        if sensors.limitedOnAttempt == attempts + 1 {
            synth.worldTrackingNormal = false
            hold(sensors.limitedSeconds)
            synth.worldTrackingNormal = true
            if sensors.jumpOnRecovery != .zero {
                sensors.worldJumpFrom = synth.t
                sensors.worldJump = sensors.jumpOnRecovery
            }
        }
        hold(challenge == .stand ? SitStandSynth.challengeHoldSeconds : max(0.3, vary(style.standSeconds, 0.25, &rng)))
        sitDown()
        hold(challenge == .sit ? SitStandSynth.challengeHoldSeconds : max(0.6, vary(style.seatedSeconds, 0.25, &rng)))
        attempts += 1
        feed()
        // Ya está sentado y la pantalla igual dice "Siéntese": espera quieto un rato antes de volver a intentar.
        if verifier.progress.hint == SitStandCopy.sit || verifier.progress.hint == SitStandCopy.calibrate {
            hold(3)
            feed()
        }
    }

    /// Calibra sentado y hace reps hasta completar o agotar `maxAttempts`.
    mutating func session(maxAttempts: Int) {
        hold(1.6)
        feed()
        while verifier.phase != .done, attempts < maxAttempts { rep() }
        hold(1)
        feed()
    }

    // MARK: Sensores y verificador

    mutating func feed() {
        while fed < synth.samples.count {
            var s = synth.samples[fed]
            if let from = sensors.worldJumpFrom, s.t >= from {
                s.phonePos += sensors.worldJump
                if s.faceTracked { s.facePos += sensors.worldJump }
            }
            if let from = sensors.flickerFrom, s.t >= from,
               (s.t - from).truncatingRemainder(dividingBy: sensors.flickerOff + sensors.flickerOn) < sensors.flickerOff {
                s.worldTrackingNormal = false
            }
            if let every = sensors.faceDropEvery, s.t >= sensors.faceDropFrom {
                let period = max(1, Int((every * synth.fps).rounded()))
                if fed % period < sensors.faceDropFrames {
                    s.faceTracked = false
                    s.facePos = .zero
                    s.faceInPhone = .zero
                    s.shapeEnergy = 0
                }
            }
            events += verifier.ingest(s, at: s.t)
            if hints.last != verifier.progress.hint { hints.append(verifier.progress.hint) }
            fed += 1
        }
    }

    var cues: [String] {
        events.compactMap { if case .cue(let c) = $0 { c.text } else { nil } }
    }

    /// Avisos que no deberían aparecerle a una persona honesta.
    var badCues: [String] {
        let bad = [SitStandCopy.torsoOnly, SitStandCopy.partial, SitStandCopy.notSeated, SitStandCopy.sitUpright,
                   SitStandCopy.armsOnly, SitStandCopy.tooSlow, SitStandCopy.noTravel, SitStandCopy.phoneTilted]
        return cues.filter { bad.contains($0) }
    }

    var outcome: ActivityOutcome {
        var v = verifier
        return v.finish(at: synth.t, reason: v.phase == .done ? .completed : .timeout)
    }

    var level: VerificationLevel {
        sitStandLevel(outcome)
    }

    func diag() -> String {
        let rej = Dictionary(grouping: verifier.rejections, by: \.reason)
            .map { "\($0.key.rawValue)×\($0.value.count)" }.sorted().joined(separator: ",")
        let an = verifier.anomalies.map { "\($0.kind)/\($0.severity.rawValue)" }.joined(separator: ",")
        let dur = verifier.repSeconds.map { String(format: "%.1f", $0) }.joined(separator: ",")
        return "count=\(verifier.count)/\(verifier.spec.target) intentos=\(attempts) fase=\(verifier.phase.rawValue) "
            + "consigna='\(verifier.progress.hint)' rechazos=[\(rej)] anomalías=[\(an)] nivel=\(level) dur=[\(dur)]"
    }
}

/// Corre `seeds` operadores con el mismo estilo; devuelve (completaron con nivel full, total, diagnóstico del
/// primero que falló, avisos que no deberían aparecerle a una persona honesta).
private nonisolated func fnSweep(_ seeds: ClosedRange<UInt64>, target: Int = 4, maxAttempts: Int = 8, style: FNStyle,
                     body: SitStandSynth.Body = SitStandSynth.Body(), noise: SitStandSynth.Noise = SitStandSynth.Noise(),
                     sensors: FNSensors = FNSensors()) -> (ok: Int, n: Int, fail: String?, badCues: [String]) {
    var ok = 0
    var fail: String? = nil
    var bad: [String] = []
    for seed in seeds {
        var op = FNOperator(seed: seed, target: target, style: style, body: body, noise: noise, sensors: sensors)
        op.session(maxAttempts: maxAttempts)
        bad += op.badCues
        if op.verifier.count >= target && op.level == .full { ok += 1 } else if fail == nil { fail = "seed \(seed): " + op.diag() }
    }
    return (ok, seeds.count, fail, bad)
}

/// Red team de falsos negativos convertido en regresión. Persona: operador de camión, 52 años, dolor lumbar.
/// Se para lento, a veces junta fuerza inclinado antes de despegar, puede usar una silla alta de casino, no
/// siempre queda del todo derecho arriba, se le cansan los brazos, entrena de noche con poca luz y a veces
/// se deja caer en la silla. Operador de lazo cerrado (`FNOperator`), meta 4, hasta 8 intentos, 8 semillas.
/// Cada test exige que complete con nivel full Y que no reciba avisos de trampa ni que lo apuren.
@MainActor
struct SitToStandHonestOperatorTests {
    private static let seeds: ClosedRange<UInt64> = 1...8

    private func styled(_ change: (inout FNStyle) -> Void) -> FNStyle {
        var s = FNStyle()
        change(&s)
        return s
    }

    private func sensors(_ change: (inout FNSensors) -> Void) -> FNSensors {
        var s = FNSensors()
        change(&s)
        return s
    }

    /// Todas las semillas completan con nivel full y sin avisos falsos.
    private func expectHonest(_ name: String, style: FNStyle, body: SitStandSynth.Body = SitStandSynth.Body(),
                              sensors: FNSensors = FNSensors(), sourceLocation: SourceLocation = #_sourceLocation) {
        let r = fnSweep(Self.seeds, style: style, body: body, sensors: sensors)
        print("RT| \(name): \(r.ok)/\(r.n) completan con nivel full, \(r.badCues.count) avisos falsos"
              + (r.fail.map { " | primer fallo: \($0)" } ?? ""))
        #expect(r.ok == r.n, "\(name): \(r.fail ?? "")", sourceLocation: sourceLocation)
        #expect(r.badCues.isEmpty, "\(name): \(Set(r.badCues).sorted())", sourceLocation: sourceLocation)
    }

    /// Un operador (semilla 1) para mirar avisos y rechazos.
    private func one(style: FNStyle, body: SitStandSynth.Body = SitStandSynth.Body(), sensors: FNSensors = FNSensors()) -> FNOperator {
        var op = FNOperator(seed: 1, style: style, body: body, sensors: sensors)
        op.session(maxAttempts: 8)
        return op
    }

    // MARK: Controles

    @Test func operadorRealCuentaFull() {
        expectHonest("brazos fijos al tronco", style: FNStyle())
        expectHonest("brazos a medias (siguen la cara)", style: styled { $0.headLock = 0.5 })
        expectHonest("teléfono sigue la cara", style: styled { $0.headLock = 1 })
    }

    @Test func seDejaCaerEnLaSillaCuenta() {
        expectHonest("se deja caer", style: styled { $0.plop = true })
    }

    @Test func trackingLimitadoDePieSoloPierdeEsaRep() {
        let s = sensors { $0.limitedOnAttempt = 2 }
        expectHonest("limitado 0,8 s de pie, ARKit retoma en el mismo origen", style: FNStyle(), sensors: s)
        let op = one(style: FNStyle(), sensors: s)
        #expect(op.verifier.rejections.filter { $0.reason == .interrupted }.count == 1)
    }

    // MARK: Lento

    @Test func operadorLentoQueJuntaFuerzaAntesDePararse() {
        // Ciclo de ~11,5 s y ~13 s: se adelanta, junta fuerza inclinado, sube en 4 s, baja en 4,5-5 s.
        // Antes: maxRepSeconds = 10 (0/6) y "Un poco más seguido" a alguien con dolor.
        expectHonest("ciclo ≈ 10 s", style: styled {
            $0.prepSeconds = 1; $0.gatherSeconds = 0.5; $0.riseSeconds = 3.5; $0.standSeconds = 1; $0.sitSeconds = 4; $0.leanDeg = 44
        })
        let slow = styled {
            $0.prepSeconds = 1; $0.gatherSeconds = 1; $0.riseSeconds = 4; $0.standSeconds = 1; $0.sitSeconds = 4.5; $0.leanDeg = 44
        }
        expectHonest("ciclo ≈ 11,5 s", style: slow)
        expectHonest("ciclo ≈ 11,5 s, teléfono sigue la cara", style: styled {
            $0.prepSeconds = 1; $0.gatherSeconds = 1; $0.riseSeconds = 4; $0.standSeconds = 1; $0.sitSeconds = 4.5; $0.leanDeg = 44
            $0.headLock = 1
        })
        expectHonest("ciclo ≈ 13 s", style: styled {
            $0.prepSeconds = 1.2; $0.gatherSeconds = 1.5; $0.riseSeconds = 4.5; $0.standSeconds = 1; $0.sitSeconds = 5; $0.leanDeg = 44
        })
        let op = one(style: slow)
        #expect(!op.verifier.rejections.contains { $0.reason == .tooSlow })
        #expect(!op.cues.contains(SitStandCopy.tooSlow))
    }

    // MARK: Silla alta y persona baja

    @Test(arguments: [0.22, 0.24, 0.26])
    func sillaAltaDeCasino(rise: Double) {
        // La cadera sube 22-26 cm y avanza 14 cm. Antes, con standRise = 0,25 m, 22 y 24 cm daban 0/6 y
        // "Párese del todo, no solo incline el cuerpo" a alguien que se paró entero.
        let style = styled { $0.riseM = rise; $0.forwardM = 0.14; $0.leanDeg = 24; $0.sitLeanDeg = 20 }
        expectHonest("silla alta, sube \(Int((rise * 100).rounded())) cm", style: style)
        expectHonest("silla alta, sube \(Int((rise * 100).rounded())) cm, teléfono sigue la cara", style: styled {
            $0.riseM = rise; $0.forwardM = 0.14; $0.leanDeg = 24; $0.sitLeanDeg = 20; $0.headLock = 1
        })
        let op = one(style: style)
        #expect(!op.verifier.anomalies.contains { $0.kind == SitStandAnomaly.torsoOnly })
    }

    @Test func operadorBajoQueQuedaUnPocoEncorvado() {
        // ~1,62 m (la cadera sube 28-32 cm) y arriba queda con 10-15° de tronco: el teléfono, 30 cm delante
        // del pecho, baja 6-8 cm aunque la cara suba entera.
        expectHonest("sube 32 cm, 10° de tronco", style: styled { $0.riseM = 0.32; $0.finalLeanDeg = 10 })
        expectHonest("sube 30 cm, 10° de tronco", style: styled { $0.riseM = 0.30; $0.finalLeanDeg = 10 })
        expectHonest("sube 28 cm, 10° de tronco, brazos a medias", style: styled { $0.riseM = 0.28; $0.finalLeanDeg = 10; $0.headLock = 0.5 })
        expectHonest("sube 30 cm, 15° de tronco", style: styled { $0.riseM = 0.30; $0.finalLeanDeg = 15 })
    }

    @Test(arguments: [0.05, 0.06, 0.08, 0.10, 0.14])
    func brazosCansados(sag: Double) {
        // Al pararse el teléfono baja `sag` respecto del pecho y la cara sube entera. Antes |rise − faceRise|
        // era simétrico: 6 cm ya era armsOnly y desde el 3.º hard (una persona honesta quedaba suspicious).
        let style = styled { $0.armsSagM = sag }
        expectHonest("el teléfono cae \(Int((sag * 100).rounded())) cm", style: style)
        let op = one(style: style)
        #expect(op.level != .suspicious)
        #expect(!op.verifier.anomalies.contains { $0.kind == SitStandAnomaly.armsOnly })
    }

    @Test func troncoMuyInclinadoAlDespegar() {
        // Con dolor lumbar se inclina 50-55° para despegar y el teléfono acompaña al tronco.
        expectHonest("inclina 45°", style: styled { $0.leanDeg = 45; $0.sitLeanDeg = 37 })
        var body = SitStandSynth.Body()
        body.pitchFollow = 0.92
        expectHonest("inclina 50°, el teléfono sigue el tronco (0,92)", style: styled { $0.leanDeg = 50; $0.sitLeanDeg = 42 }, body: body)
        expectHonest("inclina 55°", style: styled { $0.leanDeg = 55; $0.sitLeanDeg = 45 })
    }

    // MARK: Poca luz

    @Test func trackingLimitadoYARKitRetomaCorrido() {
        // Tracking limitado de pie y ARKit retoma con el origen corrido, o corrige la pose de golpe. Antes la
        // serie quedaba trabada para siempre en "Siéntese" con la persona sentada.
        expectHonest("limitado 0,8 s de pie + origen +10 cm", style: FNStyle(),
                     sensors: sensors { $0.limitedOnAttempt = 2; $0.jumpOnRecovery = SIMD3(0.03, 0.10, -0.02) })
        expectHonest("limitado 0,8 s de pie + origen −10 cm", style: FNStyle(),
                     sensors: sensors { $0.limitedOnAttempt = 2; $0.jumpOnRecovery = SIMD3(0, -0.10, 0) })
        expectHonest("limitado 0,8 s de pie + origen +10 cm vertical y 8 cm horizontal", style: FNStyle(),
                     sensors: sensors { $0.limitedOnAttempt = 2; $0.jumpOnRecovery = SIMD3(0.06, 0.10, 0.05) })
        expectHonest("limitado 0,8 s de pie + origen +20 cm", style: FNStyle(),
                     sensors: sensors { $0.limitedOnAttempt = 2; $0.jumpOnRecovery = SIMD3(0, 0.20, 0) })
        expectHonest("limitado 0,8 s de pie + origen −25 cm", style: FNStyle(),
                     sensors: sensors { $0.limitedOnAttempt = 2; $0.jumpOnRecovery = SIMD3(0, -0.25, 0) })
        for dy in [0.12, 0.14] {
            expectHonest("corrección de pose de \(Int(dy * 100)) cm sin limitado (t = 14 s)", style: FNStyle(),
                         sensors: sensors { $0.worldJumpFrom = 14; $0.worldJump = SIMD3(0, Float(dy), 0) })
        }
    }

    @Test func correccionDePoseConComponenteHorizontalNoTrabaLaSerie() {
        // Salto instantáneo de 12 cm vertical y 8 cm horizontal: la cara parece adelantada y nunca "vuelve
        // sobre la silla". Esa rep se pierde, pero tras 2,5 s quieto y derecho se re-ancla y la serie sigue
        // (antes quedaba trabada diciendo "Siéntese" a alguien sentado).
        let s = sensors { $0.worldJumpFrom = 14; $0.worldJump = SIMD3(0.06, 0.12, 0.05) }
        var op = FNOperator(seed: 1, target: 4, style: FNStyle(), sensors: s)
        op.session(maxAttempts: 12)
        print("RT| salto con componente horizontal: \(op.diag())")
        #expect(op.verifier.count == 4)
        #expect(op.verifier.rejections.filter { $0.reason == .interrupted }.count == 1)
        #expect(op.level == .full)
    }

    @Test func trackingIntermitenteEnPocaLuz() {
        // El tracking del mundo parpadea 0,3 s limitado / 0,4 s normal (nunca bloquea). Antes la rep nunca
        // cerraba: `vy` desconocido tras cada hueco reiniciaba la quietud.
        expectHonest("parpadeo 0,3 s / 0,7 s", style: FNStyle(),
                     sensors: sensors { $0.flickerFrom = 3; $0.flickerOff = 0.3; $0.flickerOn = 0.7 })
        expectHonest("parpadeo 0,3 s / 0,4 s", style: FNStyle(),
                     sensors: sensors { $0.flickerFrom = 3; $0.flickerOff = 0.3; $0.flickerOn = 0.4 })
    }

    @Test func cuadrosSueltosSinCaraNoImpidenCalibrar() {
        // Casco, lentes o poca luz: la cara se pierde 1-2 cuadros sueltos. Antes nunca calibraba.
        expectHonest("2 cuadros sin cara cada 0,7 s, después de calibrar", style: FNStyle(),
                     sensors: sensors { $0.faceDropEvery = 0.7; $0.faceDropFrames = 2; $0.faceDropFrom = 3 })
        expectHonest("2 cuadros sin cara cada 0,7 s desde el inicio", style: FNStyle(),
                     sensors: sensors { $0.faceDropEvery = 0.7; $0.faceDropFrames = 2 })
        expectHonest("1 cuadro sin cara por segundo desde el inicio", style: FNStyle(),
                     sensors: sensors { $0.faceDropEvery = 1.0; $0.faceDropFrames = 1 })
        let op = one(style: FNStyle(), sensors: sensors { $0.faceDropEvery = 1.0; $0.faceDropFrames = 1 })
        #expect(op.verifier.reference != nil)
    }
}
