import Testing
import Foundation
@testable import Activate

// Fixtures sintéticas de PoseSample (30 fps, origen abajo-izquierda) para las máquinas de estado de cámara.

/// Generador determinista (SplitMix64) para el micro-movimiento de un cuerpo real.
private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniforme en [-1, 1].
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) * 2 - 1 }
}

/// Esqueleto de pie a ~2 m, de frente, cuerpo entero (altura cuello→tobillo 0,67 del frame).
private struct Synth {
    static let fps = 30.0
    static let dt = 1.0 / fps
    static let base: [JointKey: (x: Double, y: Double)] = [
        .nose: (0.50, 0.90), .neck: (0.50, 0.82),
        .leftShoulder: (0.42, 0.80), .rightShoulder: (0.58, 0.80),
        .root: (0.50, 0.55), .leftHip: (0.45, 0.55), .rightHip: (0.55, 0.55),
        .leftKnee: (0.45, 0.35), .rightKnee: (0.55, 0.35),
        .leftAnkle: (0.44, 0.15), .rightAnkle: (0.56, 0.15),
    ]
    static let h0 = 0.82 - 0.15

    var t = 0.0
    var fps = Synth.fps
    var jitter = 0.0025
    var offset = (x: 0.0, y: 0.0)
    var ankleConfidence: Float = 0.9
    var rng = SplitMix(state: 7)
    var samples: [PoseSample] = []
    /// Tramos [inicio, fin] de cada sentadilla generada (para sincronizar el deviceMotion sintético).
    var repRanges: [ClosedRange<Double>] = []

    /// `descent` en fracción de h0 (sentadilla); `shift` en fracción del frame (extensión, hombros atrás); `rise` en fracción de h0 (cuello sube).
    /// `kneeFactor`: cuánto baja la rodilla respecto de la cadera (0,5 = sentadilla; 1 = todo el cuerpo igual).
    /// `fold`: cuánto más bajan cuello/hombros/nariz que la cadera (fracción de h0; bisagra de cintura).
    mutating func frame(descent: Double = 0, shift: Double = 0, rise: Double = 0, kneeFactor: Double = 0.5, fold: Double = 0) {
        let d = descent * Synth.h0
        var joints: [JointKey: JointPoint] = [:]
        for (k, p) in Synth.base {
            var x = p.x, y = p.y
            switch k {
            case .leftKnee, .rightKnee:
                y -= d * kneeFactor
                x += (k == .leftKnee ? -1 : 1) * 0.2 * d
            case .leftAnkle, .rightAnkle:
                break
            case .nose, .neck, .leftShoulder, .rightShoulder:
                y -= d + fold * Synth.h0
                x += shift
                y += rise * Synth.h0
            default:
                y -= d
            }
            x += offset.x + jitter * rng.unit()
            y += offset.y + jitter * rng.unit()
            let c: Float = (k == .leftAnkle || k == .rightAnkle) ? ankleConfidence : 0.9
            joints[k] = JointPoint(x: x, y: y, confidence: c)
        }
        samples.append(PoseSample(t: t, joints: joints, fps: fps))
        t += Synth.dt
    }

    mutating func stand(seconds: Double) {
        for _ in 0..<Int((seconds * Synth.fps).rounded()) { frame() }
    }

    /// Sentadilla suave (bajar y subir) de `seconds` con descenso máximo `amplitude`·h0.
    mutating func squat(amplitude: Double, seconds: Double) {
        let start = t
        let n = Int((seconds * Synth.fps).rounded())
        for i in 0..<n {
            let p = Double(i) / Double(n)
            frame(descent: amplitude * (1 - cos(2 * .pi * p)) / 2)
        }
        repRanges.append(start...t)
    }

    /// Bajada de `seconds / 2`, pausa abajo de `hold` y subida; con rodillas y torso configurables.
    mutating func squat(amplitude: Double, seconds: Double, hold: Double, kneeFactor: Double = 0.5, fold: Double = 0) {
        let start = t
        let half = Int((seconds / 2 * Synth.fps).rounded())
        for i in 0..<half {
            let x = (1 - cos(.pi * Double(i) / Double(half))) / 2
            frame(descent: amplitude * x, kneeFactor: kneeFactor, fold: fold * x)
        }
        for _ in 0..<Int((hold * Synth.fps).rounded()) {
            frame(descent: amplitude, kneeFactor: kneeFactor, fold: fold)
        }
        for i in 0..<half {
            let x = (1 + cos(.pi * Double(i) / Double(half))) / 2
            frame(descent: amplitude * x, kneeFactor: kneeFactor, fold: fold * x)
        }
        repRanges.append(start...t)
    }

    /// Extensión lumbar: hombros se desplazan `shift` del frame y vuelven.
    mutating func extend(shift: Double, seconds: Double) {
        let n = Int((seconds * Synth.fps).rounded())
        for i in 0..<n {
            let p = Double(i) / Double(n)
            frame(shift: shift * (1 - cos(2 * .pi * p)) / 2)
        }
    }

    mutating func series(count: Int, amplitude: Double, durations: [Double], pauses: [Double]) {
        for i in 0..<count {
            squat(amplitude: amplitude, seconds: durations[i % durations.count])
            stand(seconds: pauses[i % pauses.count])
        }
    }
}

private let variedDurations = [1.6, 1.9, 1.7, 2.3, 1.8, 2.0, 1.5, 2.2, 1.7, 2.1]
private let variedPauses = [0.4, 0.7, 0.5, 0.9, 0.6, 0.8, 0.5, 1.0, 0.6, 0.7]

private func run<V: ActivityVerifier>(_ verifier: inout V, _ samples: [PoseSample]) -> [VerifierEvent] where V.Sample == PoseSample {
    verifier.start(at: 0)
    var events: [VerifierEvent] = []
    for s in samples { events += verifier.ingest(s, at: s.t) }
    return events
}

private func hardKinds(_ outcome: ActivityOutcome) -> [String] { outcome.anomalies.filter { $0.severity == .hard }.map(\.kind) }

/// deviceMotion sintético a 50 Hz: quieto sobre la mesa, o moviéndose en los tramos `moving`.
private func motion(until end: Double, moving: [ClosedRange<Double>] = [], seed: UInt64 = 11) -> [MotionSample] {
    var rng = SplitMix(state: seed)
    let dt = 1.0 / 50
    return (0...Int(end / dt)).map { i in
        let t = Double(i) * dt
        let inHand = moving.contains { $0.contains(t) }
        let a = inHand ? 0.12 : 0.004
        let r = inHand ? 0.8 : 0.01
        return MotionSample(t: t,
                            userAccel: SIMD3(a * rng.unit(), a * rng.unit(), a * rng.unit()),
                            gravity: inHand ? SIMD3(0.15 * rng.unit(), -0.95, -0.25) : SIMD3(0, -0.98, -0.2),
                            rotationRate: SIMD3(r * rng.unit(), r * rng.unit(), r * rng.unit()))
    }
}

/// Mezcla pose + deviceMotion ordenados por tiempo (lo que entrega `SupportedSquatSource`).
private func combined(_ poses: [PoseSample], _ motions: [MotionSample]) -> [SupportedSquatSample] {
    (poses.map(SupportedSquatSample.pose) + motions.map(SupportedSquatSample.motion)).sorted { $0.t < $1.t }
}

private func run(_ verifier: inout SupportedSquatVerifier, _ samples: [SupportedSquatSample]) -> [VerifierEvent] {
    verifier.start(at: 0)
    var events: [VerifierEvent] = []
    for s in samples { events += verifier.ingest(s, at: s.t) }
    return events
}

struct PoseVerifierTests {
    @Test func diezSentadillasCuentanDiez() {
        var synth = Synth()
        synth.stand(seconds: 1.5)
        synth.series(count: 10, amplitude: 0.22, durations: variedDurations, pauses: variedPauses)

        var v = SquatVerifier(target: 10)
        let events = run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .completed)

        #expect(events.contains(.gate(.ready)))
        #expect(events.contains(.rep(10)))
        #expect(events.contains(.completed))
        #expect(outcome.achieved == 10)
        #expect(outcome.completed)
        #expect(outcome.anomalies.isEmpty)
        #expect(v.progress.count == 10)
        #expect(v.progress.gate == .ready)
        if case let .reps(count, minDescent, meanRep) = outcome.metrics {
            #expect(count == 10)
            #expect((minDescent ?? 0) >= PoseThresholds.squatEnter)
            #expect((meanRep ?? 0) >= PoseThresholds.minRepSeconds)
        } else {
            Issue.record("métricas de reps esperadas")
        }
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .full)
    }

    @Test func diezMediasSentadillasCuentanCero() {
        var synth = Synth()
        synth.stand(seconds: 1.5)
        synth.series(count: 10, amplitude: 0.08, durations: variedDurations, pauses: variedPauses)

        var v = SquatVerifier(target: 10)
        let events = run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)

        #expect(events.contains(.gate(.ready)))
        #expect(!events.contains(.completed))
        #expect(outcome.achieved == 0)
        #expect(!outcome.completed)
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func seriePerfectamentePeriodicaEsTooRegular() {
        var synth = Synth()
        synth.jitter = 0
        synth.stand(seconds: 1.5)
        synth.series(count: 8, amplitude: 0.22, durations: [2.0], pauses: [0.5])

        var v = SquatVerifier(target: 10)
        let events = run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .userStopped)

        #expect(outcome.achieved == 8)
        #expect(hardKinds(outcome).contains(PoseAnomaly.tooRegular))
        #expect(events.contains { if case .anomaly(let a) = $0 { return a.kind == PoseAnomaly.tooRegular } else { return false } })
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .suspicious)
    }

    @Test func camaraQueSaltaEsPhoneMoved() {
        var synth = Synth()
        synth.stand(seconds: 1.5)
        synth.series(count: 2, amplitude: 0.22, durations: variedDurations, pauses: variedPauses)
        // El teléfono se cae/se mueve: el encuadre salta y se queda ahí.
        synth.offset = (x: 0.22, y: 0.08)
        synth.stand(seconds: 1.5)
        synth.series(count: 2, amplitude: 0.22, durations: variedDurations, pauses: variedPauses)

        var v = SquatVerifier(target: 10)
        let events = run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .userStopped)

        let moved = outcome.anomalies.filter { $0.kind == PoseAnomaly.phoneMoved }
        #expect(moved.count == 1)
        #expect(moved.first?.severity == .soft)
        #expect(events.contains(.gate(.calibrating)))
        #expect(events.filter { $0 == .gate(.ready) }.count == 2)
        #expect(outcome.achieved == 4)
        #expect(v.progress.gate == .ready)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .full)
    }

    @Test func perderElEncuadreBloqueaYVuelve() {
        var synth = Synth()
        synth.stand(seconds: 1.5)
        synth.ankleConfidence = 0.2
        synth.stand(seconds: 1.0)
        synth.ankleConfidence = 0.9
        synth.stand(seconds: 1.5)
        synth.squat(amplitude: 0.22, seconds: 1.8)
        synth.stand(seconds: 0.5)

        var v = SquatVerifier(target: 5)
        let events = run(&v, synth.samples)

        #expect(events.contains(.gate(.blocked(reason: PoseCopy.partialBody))))
        #expect(events.filter { $0 == .gate(.ready) }.count == 2)
        #expect(v.progress.count == 1)
        #expect(v.progress.gate == .ready)
    }

    @Test func fotoEstaticaEsStatic() {
        var synth = Synth()
        synth.jitter = 0
        synth.stand(seconds: 5.0)

        var v = SquatVerifier(target: 5)
        _ = run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)

        #expect(hardKinds(outcome) == [PoseAnomaly.staticImage])
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .suspicious)
    }

    @Test func fpsBajoSostenidoEsLowFpsSuave() {
        var synth = Synth()
        synth.fps = 8
        synth.stand(seconds: 1.5)
        synth.series(count: 3, amplitude: 0.22, durations: variedDurations, pauses: variedPauses)

        var v = SquatVerifier(target: 5)
        _ = run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .userStopped)

        let low = outcome.anomalies.filter { $0.kind == PoseAnomaly.lowFps }
        #expect(low.count == 1)
        #expect(low.first?.severity == .soft)
        #expect(outcome.achieved == 3)
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func extensionCuentaReps() {
        var synth = Synth()
        synth.stand(seconds: 1.5)
        for i in 0..<5 {
            synth.extend(shift: 0.09, seconds: variedDurations[i])
            synth.stand(seconds: variedPauses[i])
        }

        var v = ExtensionVerifier(target: 5)
        let events = run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .completed)

        #expect(events.contains(.completed))
        #expect(outcome.achieved == 5)
        #expect(outcome.completed)
        #expect(outcome.kind == .extensionLumbar)
        #expect(outcome.anomalies.isEmpty)
    }

    @Test func sentadillaNoCuentaComoExtension() {
        var synth = Synth()
        synth.stand(seconds: 1.5)
        synth.series(count: 5, amplitude: 0.22, durations: variedDurations, pauses: variedPauses)

        var v = ExtensionVerifier(target: 5)
        _ = run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)

        #expect(outcome.achieved == 0)
        #expect(v.progress.gate == .ready)
    }

    @Test func sinCuerpoNoCalibra() {
        var synth = Synth()
        synth.ankleConfidence = 0.1
        synth.stand(seconds: 3.0)

        var v = SquatVerifier(target: 5)
        let events = run(&v, synth.samples)

        #expect(!events.contains(.gate(.ready)))
        #expect(v.progress.gate == .calibrating)
        #expect(v.progress.hint == PoseCopy.placePhone)
        #expect(v.calibration == nil)
    }

    // MARK: Endurecimiento del modo apoyado

    @Test func inclinarseDeCinturaSinDoblarRodillasNoCuenta() {
        var synth = Synth()
        synth.stand(seconds: 1.5)
        // Bisagra con rodillas apenas blandas: la cadera baja algo, el torso se pliega mucho.
        for i in 0..<5 {
            synth.squat(amplitude: 0.14, seconds: variedDurations[i], hold: 0.2, kneeFactor: 0.3, fold: 0.25)
            synth.stand(seconds: variedPauses[i])
        }
        // Bisagra pura: la cadera no baja (ni siquiera entra a la rep).
        for i in 0..<3 {
            synth.squat(amplitude: 0.03, seconds: variedDurations[i], hold: 0.2, kneeFactor: 0.0, fold: 0.30)
            synth.stand(seconds: variedPauses[i])
        }

        var v = SquatVerifier(target: 10)
        _ = run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)

        #expect(outcome.achieved == 0)
        #expect(v.rejections == Array(repeating: .torsoBend, count: 5))
        #expect(outcome.anomalies.filter { $0.kind == PoseAnomaly.torsoBend }.count == 5)
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func bajarSinDoblarRodillasNoCuenta() {
        var synth = Synth()
        synth.stand(seconds: 1.5)
        for i in 0..<4 {
            synth.squat(amplitude: 0.2, seconds: variedDurations[i], hold: 0.2, kneeFactor: 1.0)
            synth.stand(seconds: variedPauses[i])
        }

        var v = SquatVerifier(target: 5)
        _ = run(&v, synth.samples)
        let outcome = v.finish(at: synth.t, reason: .timeout)

        #expect(outcome.achieved == 0)
        #expect(v.rejections == Array(repeating: .kneesStraight, count: 4))
    }

    @Test func telefonoApoyadoQuietoCuentaConFull() {
        var synth = Synth()
        synth.stand(seconds: 1.5)
        synth.series(count: 6, amplitude: 0.22, durations: variedDurations, pauses: variedPauses)

        var v = SupportedSquatVerifier(spec: .standard(for: .sentadilla, target: 6))
        let events = run(&v, combined(synth.samples, motion(until: synth.t)))
        let outcome = v.finish(at: synth.t, reason: .completed)

        #expect(events.contains(.completed))
        #expect(outcome.achieved == 6)
        #expect(outcome.anomalies.isEmpty)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .full)
    }

    @Test func telefonoEnLaManoEsPhoneHandheld() {
        var synth = Synth()
        synth.stand(seconds: 1.5)
        synth.series(count: 4, amplitude: 0.22, durations: variedDurations, pauses: variedPauses)

        var v = SupportedSquatVerifier(spec: .standard(for: .sentadilla, target: 5))
        let events = run(&v, combined(synth.samples, motion(until: synth.t, moving: synth.repRanges)))
        let outcome = v.finish(at: synth.t, reason: .timeout)

        #expect(outcome.achieved == 0)
        #expect(hardKinds(outcome) == [PoseAnomaly.phoneHandheld])
        #expect(events.contains(.cue(Cue(text: PoseCopy.leavePhone, symbol: "iphone"))))
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .sentadilla) == .suspicious)
    }

    @Test func golpeCortoALaMesaNoEsPhoneHandheld() {
        var synth = Synth()
        synth.stand(seconds: 1.5)
        synth.series(count: 3, amplitude: 0.22, durations: variedDurations, pauses: variedPauses)
        // Un golpe de 0,1 s en medio de la segunda rep (más corto que el sostenido mínimo).
        let mid = synth.repRanges[1].lowerBound + 0.6
        var v = SupportedSquatVerifier(spec: .standard(for: .sentadilla, target: 3))
        _ = run(&v, combined(synth.samples, motion(until: synth.t, moving: [mid...(mid + 0.1)])))
        let outcome = v.finish(at: synth.t, reason: .completed)

        #expect(outcome.achieved == 3)
        #expect(hardKinds(outcome).isEmpty)
    }

    @Test func desafioDePausaEnModoApoyado() {
        // Cumple: la 2ª rep se queda abajo 2 s.
        var ok = Synth()
        ok.stand(seconds: 1.5)
        for i in 0..<4 {
            ok.squat(amplitude: 0.22, seconds: variedDurations[i], hold: i == 1 ? 2.0 : 0.2)
            ok.stand(seconds: variedPauses[i])
        }
        var passed = SquatVerifier(target: 4, challenge: SquatHoldChallenge(repNumber: 2))
        let okEvents = run(&passed, ok.samples)
        let okOutcome = passed.finish(at: ok.t, reason: .completed)
        #expect(okEvents.contains(.cue(SquatHoldChallenge.cue)))
        #expect(okOutcome.achieved == 4 && passed.challenge.passed)
        #expect(hardKinds(okOutcome).isEmpty)

        // Vídeo que no sigue la consigna: nunca se queda abajo.
        var video = Synth()
        video.stand(seconds: 1.5)
        video.series(count: 6, amplitude: 0.22, durations: variedDurations, pauses: variedPauses)
        var failed = SquatVerifier(target: 6, challenge: SquatHoldChallenge(repNumber: 2))
        let videoEvents = run(&failed, video.samples)
        let videoOutcome = failed.finish(at: video.t, reason: .timeout)
        #expect(videoEvents.contains(.cue(SquatHoldChallenge.missedCue)))
        #expect(hardKinds(videoOutcome) == [SquatHoldChallenge.anomalyKind])
        #expect(videoOutcome.achieved == 4)
    }

    @Test func fixtureDeReplayApoyadoCompletaConDesafio() {
        for demo in [false, true] {
            let spec = VerificationSpec.standard(for: .sentadilla, demo: demo)
            let challenge = SquatHoldChallenge(seed: 77, target: spec.target)
            var v = SupportedSquatVerifier(spec: spec, challenge: challenge)
            let samples = SupportedSquatFixtures.replay(target: spec.target, challengeRep: challenge.repNumber)
            let events = run(&v, samples)
            let outcome = v.finish(at: samples.last?.t ?? 0, reason: .completed)
            #expect(events.contains(.completed), "demo=\(demo)")
            #expect(outcome.achieved == spec.target)
            #expect(v.challenge.passed)
            #expect(hardKinds(outcome).isEmpty)
            #expect((samples.last?.t ?? .infinity) < spec.maxDurationSeconds)
        }
    }
}
