import Testing
import Foundation
import simd
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
    /// `kneeFactor`: cuánto baja la rodilla respecto de la cadera (0,3 = sentadilla de frente: el muslo se
    /// acorta y la canilla casi no; 1 = todo el cuerpo igual).
    /// `fold`: cuánto más bajan cuello/hombros/nariz que la cadera (fracción de h0; bisagra de cintura).
    mutating func frame(descent: Double = 0, shift: Double = 0, rise: Double = 0, kneeFactor: Double = 0.3, fold: Double = 0) {
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
    mutating func squat(amplitude: Double, seconds: Double, hold: Double, kneeFactor: Double = 0.3, fold: Double = 0) {
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

// Red team del modo apoyado (SupportedSquatVerifier = SquatVerifier + deviceMotion): secuencias sintéticas
// realistas (pose a 30 fps con micro-movimiento + deviceMotion a 50 Hz) por el verificador real. Cada test
// imprime una línea "RTP| …" con lo medido.

// MARK: - Red team del modo apoyado: utilidades

private struct RTPRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniforme en [-1, 1].
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) * 2 - 1 }
    /// Uniforme en [lo, hi].
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (unit() + 1) / 2 * (hi - lo) }
    /// Normal estándar (Box-Muller).
    mutating func gauss() -> Double {
        let u1 = max(1e-12, (unit() + 1) / 2)
        let u2 = (unit() + 1) / 2
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Esqueleto de pie a ~2 m, de frente (mismas proporciones que PoseVerifierTests: h0 = 0,67 del frame).
private enum RTPBody {
    static let base: [JointKey: (x: Double, y: Double)] = [
        .nose: (0.50, 0.90), .neck: (0.50, 0.82),
        .leftShoulder: (0.42, 0.80), .rightShoulder: (0.58, 0.80),
        .root: (0.50, 0.55), .leftHip: (0.45, 0.55), .rightHip: (0.55, 0.55),
        .leftKnee: (0.45, 0.35), .rightKnee: (0.55, 0.35),
        .leftAnkle: (0.44, 0.15), .rightAnkle: (0.56, 0.15),
    ]
    static let ankleY = 0.15
    static let h0 = 0.82 - 0.15
    /// Fila del horizonte con la cámara apoyada en una mesa a ~1 m de altura y 2 m de distancia
    /// (0,472 frame/m: tobillo a 0,08 m → 0,15; cuello a 1,50 m → 0,82).
    static let horizonY = 0.584
    static let legs: Set<JointKey> = [.leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
}

/// Lo que ve la cámara en un frame: el cuerpo (descenso real, rodillas, torso, pies) y las
/// transformaciones de la imagen que producen los ataques (escala, inclinación, giro, desplazamiento).
private struct RTPPose {
    /// Descenso real de la cadera (fracción de h0).
    var descent = 0.0
    /// Cuánto baja la rodilla respecto de la cadera (0,3 ≈ sentadilla real de frente).
    var kneeFactor = 0.3
    /// Pliegue del torso: cuello/hombros bajan esto más que la cadera (fracción de h0).
    var fold = 0.0
    /// Escala isotrópica de la imagen alrededor de la fila `anchorY` (alejarse con la cámara al nivel
    /// de los tobillos, zoom en una tablet, acercarse a leer la pantalla).
    var scale = 1.0
    /// Escala solo vertical alrededor de `anchorY` (foto impresa inclinada sobre su borde inferior).
    var scaleY = 1.0
    var anchorY = RTPBody.ankleY
    /// Desplazamiento vertical de toda la imagen (teléfono o foto que suben y bajan).
    var shiftY = 0.0
    /// Giro de la imagen alrededor del centro (teléfono apoyado que se desliza de lado).
    var rollDegrees = 0.0
    /// Pies que cambian de lugar (fracción del frame; + = suben en la imagen = se alejan).
    var ankleShiftY = 0.0

    static func lerp(_ a: RTPPose, _ b: RTPPose, _ x: Double) -> RTPPose {
        func l(_ p: Double, _ q: Double) -> Double { p + (q - p) * x }
        return RTPPose(descent: l(a.descent, b.descent), kneeFactor: l(a.kneeFactor, b.kneeFactor),
                       fold: l(a.fold, b.fold), scale: l(a.scale, b.scale), scaleY: l(a.scaleY, b.scaleY),
                       anchorY: l(a.anchorY, b.anchorY), shiftY: l(a.shiftY, b.shiftY),
                       rollDegrees: l(a.rollDegrees, b.rollDegrees), ankleShiftY: l(a.ankleShiftY, b.ankleShiftY))
    }
}

private struct RTPSynth {
    var fps = 30.0
    var t = 0.0
    /// < 1: persona más lejos (cuerpo más chico, anclado en los tobillos).
    var bodyScale = 1.0
    /// Micro-movimiento uniforme por coordenada (persona real ≈ 0,0025; foto vista por la cámara ≈ 0,0005).
    var jitter = 0.0025
    /// Ruido gaussiano extra en rodillas y tobillos (pantalón holgado, botas de seguridad).
    var legSigma = 0.0
    var confidence: Float = 0.9
    var hidden: Set<JointKey> = []
    var rng: RTPRandom
    var samples: [PoseSample] = []
    var current = RTPPose()
    var repRanges: [ClosedRange<Double>] = []

    init(seed: UInt64 = 101) { rng = RTPRandom(seed) }

    var h0: Double { RTPBody.h0 * bodyScale }

    mutating func joints(for p: RTPPose) -> [JointKey: JointPoint] {
        let h = h0
        let d = p.descent * h
        let roll = p.rollDegrees * .pi / 180
        var out: [JointKey: JointPoint] = [:]
        for (k, b) in RTPBody.base where !hidden.contains(k) {
            var x = 0.5 + (b.x - 0.5) * bodyScale
            var y = RTPBody.ankleY + (b.y - RTPBody.ankleY) * bodyScale
            switch k {
            case .leftKnee, .rightKnee:
                y -= d * p.kneeFactor
                x += (k == .leftKnee ? -1 : 1) * 0.2 * d
            case .leftAnkle, .rightAnkle:
                y += p.ankleShiftY
            case .nose, .neck, .leftShoulder, .rightShoulder:
                y -= d + p.fold * h
            default:
                y -= d
            }
            x = 0.5 + (x - 0.5) * p.scale
            y = p.anchorY + (y - p.anchorY) * p.scale * p.scaleY
            if roll != 0 {
                let dx = x - 0.5, dy = y - 0.5
                x = 0.5 + dx * cos(roll) - dy * sin(roll)
                y = 0.5 + dx * sin(roll) + dy * cos(roll)
            }
            y += p.shiftY
            let sigma = RTPBody.legs.contains(k) ? legSigma : 0
            x += jitter * rng.unit() + sigma * rng.gauss()
            y += jitter * rng.unit() + sigma * rng.gauss()
            out[k] = JointPoint(x: x, y: y, confidence: confidence)
        }
        return out
    }

    mutating func frame(_ p: RTPPose) {
        current = p
        samples.append(PoseSample(t: t, joints: joints(for: p), fps: fps))
        t += 1 / fps
    }

    /// Frames sin nadie (cámara tapada / persona caminando a su lugar).
    mutating func empty(seconds: Double) {
        for _ in 0..<Int((seconds * fps).rounded()) {
            samples.append(PoseSample(t: t, joints: [:], fps: fps))
            t += 1 / fps
        }
    }

    mutating func stay(seconds: Double) {
        let p = current
        for _ in 0..<Int((seconds * fps).rounded()) { frame(p) }
    }

    /// Transición suave (coseno) desde la pose actual.
    mutating func move(to p: RTPPose, seconds: Double) {
        let a = current
        let n = max(1, Int((seconds * fps).rounded()))
        for i in 1...n {
            let x = (1 - cos(.pi * Double(i) / Double(n))) / 2
            frame(RTPPose.lerp(a, p, x))
        }
    }

    /// Una rep: baja a `bottom`, se queda `hold` y vuelve a la pose de partida (o a `top`).
    mutating func rep(bottom: RTPPose, down: Double, hold: Double, up: Double, top: RTPPose? = nil) {
        let start = t
        let back = top ?? current
        move(to: bottom, seconds: down)
        stay(seconds: hold)
        move(to: back, seconds: up)
        repRanges.append(start...t)
    }

    /// Sentadillas reales con variación natural; `holdAll` = pausa abajo en todas (vídeo preparado);
    /// si no, pausa solo en `challengeRep`.
    mutating func realSquats(_ count: Int, depth: ClosedRange<Double> = 0.18...0.24, kneeFactor: Double = 0.3,
                             fold: ClosedRange<Double> = 0.0...0.03, holdAll: ClosedRange<Double>? = nil,
                             challengeRep: Int = 0, ankleShiftAtBottom: Double = 0) {
        for i in 1...max(1, count) {
            var bottom = current
            bottom.descent = rng.range(depth.lowerBound, depth.upperBound)
            bottom.kneeFactor = kneeFactor
            bottom.fold = rng.range(fold.lowerBound, fold.upperBound)
            bottom.ankleShiftY = current.ankleShiftY + ankleShiftAtBottom
            let hold: Double
            if let holdAll {
                hold = rng.range(holdAll.lowerBound, holdAll.upperBound)
            } else {
                hold = i == challengeRep ? rng.range(2.0, 2.4) : rng.range(0.1, 0.4)
            }
            rep(bottom: bottom, down: rng.range(0.9, 1.3), hold: hold, up: rng.range(0.9, 1.3))
            stay(seconds: rng.range(0.5, 1.2))
        }
    }
}

/// deviceMotion a 50 Hz: teléfono apoyado (ruido de mesa) más lo que agreguen los cierres.
private func rtpMotion(until end: Double, seed: UInt64 = 9,
                       gravity: (Double) -> SIMD3<Double> = { _ in SIMD3(0, -0.98, -0.2) },
                       accel: (Double) -> SIMD3<Double> = { _ in .zero },
                       rotation: (Double) -> SIMD3<Double> = { _ in .zero },
                       noiseAccel: Double = 0.004, noiseRotation: Double = 0.01) -> [MotionSample] {
    var rng = RTPRandom(seed)
    let dt = 1.0 / 50
    return (0...Int(end / dt)).map { i in
        let t = Double(i) * dt
        let a = accel(t) + SIMD3(noiseAccel * rng.unit(), noiseAccel * rng.unit(), noiseAccel * rng.unit())
        let r = rotation(t) + SIMD3(noiseRotation * rng.unit(), noiseRotation * rng.unit(), noiseRotation * rng.unit())
        return MotionSample(t: t, userAccel: a, gravity: gravity(t), rotationRate: r)
    }
}

/// Gravedad con el teléfono girado `degrees` alrededor de su eje Z (se desliza de lado).
private func rtpRolledGravity(_ degrees: Double) -> SIMD3<Double> {
    let r = degrees * .pi / 180
    let g = SIMD3(0.0, -0.98, -0.2)
    return SIMD3(g.x * cos(r) - g.y * sin(r), g.x * sin(r) + g.y * cos(r), g.z)
}

private struct RTPResult {
    var outcome: ActivityOutcome
    var events: [VerifierEvent]
    var rejections: [SquatVerifier.Rejection]
    var level: VerificationLevel
    var challengePassed: Bool

    var achieved: Int { outcome.achieved }
    var hard: [String] { outcome.anomalies.filter { $0.severity == .hard }.map(\.kind) }
    var soft: [String] { outcome.anomalies.filter { $0.severity == .soft }.map(\.kind) }
    /// Contó la meta con nivel `full`: el ataque logró una actividad verificada.
    var fullCredit: Bool { outcome.completed && level == .full }
    var cues: [String] {
        events.compactMap { if case .cue(let c) = $0 { return c.text } else { return nil } }
    }

    func log(_ name: String) {
        var seen = Set<String>()
        let uniqueCues = cues.filter { seen.insert($0).inserted }
        let rejects = Dictionary(grouping: rejections, by: { $0.rawValue }).mapValues(\.count)
        var blocked: [String: Int] = [:]
        for e in events { if case .gate(.blocked(let reason)) = e { blocked[reason, default: 0] += 1 } }
        print("RTP| \(name) | achieved=\(achieved)/\(outcome.target) level=\(level) hard=\(hard) soft=\(soft) "
              + "rejections=\(rejects) challengePassed=\(challengePassed) gateBlocked=\(blocked) cues=\(uniqueCues)")
    }
}

private let rtpSeed: UInt64 = 4242


private func rtpRun(_ poses: [PoseSample], motion: [MotionSample]? = nil, target: Int,
                    source: SourceLevel = .live) -> RTPResult {
    let spec = VerificationSpec.standard(for: .sentadilla, target: target)
    var v = SupportedSquatVerifier(spec: spec, challenge: SquatHoldChallenge(seed: rtpSeed, target: spec.target))
    let end = poses.last?.t ?? 0
    let motions = motion ?? rtpMotion(until: end)
    let samples = (poses.map(SupportedSquatSample.pose) + motions.map(SupportedSquatSample.motion)).sorted { $0.t < $1.t }
    v.start(at: 0)
    var events: [VerifierEvent] = []
    var completedAt: Double?
    for s in samples where completedAt == nil {
        let e = v.ingest(s, at: s.t)
        events += e
        if e.contains(.completed) { completedAt = s.t }   // ActivityRunner cierra en `.completed`
    }
    let outcome = v.finish(at: completedAt ?? max(end, samples.last?.t ?? 0), reason: completedAt == nil ? .timeout : .completed)
    return RTPResult(outcome: outcome, events: events, rejections: v.inner.rejections,
                     level: VerificationPolicy.level(for: outcome, source: source, kind: .sentadilla),
                     challengePassed: v.challenge.passed)
}

/// Sesión en lazo cerrado: un operador que SIGUE la consigna (se queda abajo cuando el desafío está armado).
/// Se alimenta el verificador rep a rep para decidir la pausa de la siguiente.
private struct RTPSession {
    var v: SupportedSquatVerifier
    var motions: [MotionSample]
    var mi = 0
    var fed = 0
    var events: [VerifierEvent] = []
    var source: SourceLevel
    var completedAt: Double?

    init(target: Int, motion: [MotionSample]? = nil, source: SourceLevel = .live) {
        let spec = VerificationSpec.standard(for: .sentadilla, target: target)
        v = SupportedSquatVerifier(spec: spec, challenge: SquatHoldChallenge(seed: rtpSeed, target: spec.target))
        motions = motion ?? rtpMotion(until: 240)
        self.source = source
        v.start(at: 0)
    }

    mutating func feed(_ s: RTPSynth) {
        while fed < s.samples.count, completedAt == nil {
            let p = s.samples[fed]
            while mi < motions.count, motions[mi].t <= p.t {
                events += v.ingest(.motion(motions[mi]), at: motions[mi].t)
                mi += 1
            }
            let e = v.ingest(.pose(p), at: p.t)
            events += e
            if e.contains(.completed) { completedAt = p.t }   // ActivityRunner cierra en `.completed`
            fed += 1
        }
    }

    var challengeArmed: Bool { v.challenge.isArmed(nextRep: v.progress.count + 1) }

    /// `count` sentadillas reales; la pausa abajo va solo cuando el desafío está armado (como pide la app).
    mutating func squats(_ s: inout RTPSynth, _ count: Int, depth: ClosedRange<Double> = 0.18...0.24,
                         kneeFactor: Double = 0.3, fold: ClosedRange<Double> = 0.0...0.03, ankleShiftAtBottom: Double = 0) {
        for _ in 0..<count where completedAt == nil {
            feed(s)
            let hold = challengeArmed ? s.rng.range(2.0, 2.4) : s.rng.range(0.1, 0.4)
            var bottom = s.current
            bottom.descent = s.rng.range(depth.lowerBound, depth.upperBound)
            bottom.kneeFactor = kneeFactor
            bottom.fold = s.rng.range(fold.lowerBound, fold.upperBound)
            bottom.ankleShiftY = s.current.ankleShiftY + ankleShiftAtBottom
            s.rep(bottom: bottom, down: s.rng.range(0.9, 1.3), hold: hold, up: s.rng.range(0.9, 1.3))
            s.stay(seconds: s.rng.range(0.5, 1.2))
        }
        feed(s)
    }

    mutating func result(_ s: RTPSynth) -> RTPResult {
        feed(s)
        let outcome = v.finish(at: completedAt ?? s.t, reason: completedAt == nil ? .timeout : .completed)
        return RTPResult(outcome: outcome, events: events, rejections: v.inner.rejections,
                         level: VerificationPolicy.level(for: outcome, source: source, kind: .sentadilla),
                         challengePassed: v.challenge.passed)
    }
}

// MARK: - Ataques y casos legítimos del modo apoyado (regresión del red team)

/// Ataque = no cuenta o no queda `full`; caso legítimo (operador que sigue la consigna, lazo cerrado) =
/// cuenta. Lo que sigue abierto va en `withKnownIssue` con la razón.
struct PoseSquatAttackTests {

    // MARK: Foto / pantalla

    @Test func ataqueFotoQuietaFrenteALaCamara() {
        var s = RTPSynth(seed: 1)
        s.jitter = 0.0004
        s.stay(seconds: 8)
        let r = rtpRun(s.samples, target: 10)
        r.log("foto quieta")
        #expect(r.achieved == 0)
        #expect(r.hard.contains(PoseAnomaly.staticImage))
    }

    @Test func ataqueFotoMovidaArribaYAbajoFrenteALaCamara() {
        var s = RTPSynth(seed: 2)
        s.jitter = 0.003
        s.stay(seconds: 1.5)
        for _ in 0..<10 {
            var bottom = s.current
            bottom.shiftY = -0.11
            s.rep(bottom: bottom, down: s.rng.range(0.9, 1.3), hold: s.rng.range(1.9, 2.3), up: s.rng.range(0.9, 1.3))
            s.stay(seconds: s.rng.range(0.5, 1.0))
        }
        let r = rtpRun(s.samples, target: 10)
        r.log("foto movida arriba/abajo")
        #expect(r.achieved == 0)
        #expect(r.rejections.allSatisfy { $0 == .feetMoved })
    }

    // MARK: Teléfono movido frente a una persona quieta

    @Test func ataqueTelefonoEnLaManoFrenteAPersonaQuieta() {
        var s = RTPSynth(seed: 3)
        s.stay(seconds: 1.5)
        for _ in 0..<10 {
            var bottom = s.current
            bottom.shiftY = -0.11
            s.rep(bottom: bottom, down: s.rng.range(0.9, 1.3), hold: s.rng.range(1.9, 2.3), up: s.rng.range(0.9, 1.3))
            s.stay(seconds: s.rng.range(0.5, 1.0))
        }
        var rng = RTPRandom(33)
        let ranges = s.repRanges
        let inHand = { (t: Double) in ranges.contains { $0.contains(t) } }
        let motion = rtpMotion(until: s.t,
                               gravity: { t in inHand(t) ? SIMD3(0.1 * rng.unit(), -0.95, -0.27) : SIMD3(0, -0.98, -0.2) },
                               accel: { t in inHand(t) ? SIMD3(0.1, 0.1, 0.1) * rng.unit() : .zero },
                               rotation: { t in inHand(t) ? SIMD3(0.6, 0.6, 0.6) * rng.unit() : .zero })
        let r = rtpRun(s.samples, motion: motion, target: 10)
        r.log("teléfono en la mano frente a persona quieta")
        #expect(r.achieved == 0)
        #expect(r.hard.contains(PoseAnomaly.phoneHandheld))

        let rail = rtpRun(s.samples, target: 10)
        rail.log("teléfono en riel vertical frente a persona quieta")
        #expect(rail.achieved == 0)
    }

    // MARK: Vídeo

    @Test func limiteVideoPregrabadoConPausaAbajoEnTodasLasReps() {
        // Residual documentado: un vídeo de sentadillas REALES con la pausa de 2 s en todas las reps, en una
        // pantalla frente al teléfono apoyado, pasa todas las reglas geométricas y el desafío. Cerrarlo pide
        // medir el medio (tamaño físico con la TrueDepth) o una consigna aleatoria sincronizada, ambas por
        // validar en el iPhone a 2 m.
        var s = RTPSynth(seed: 4)
        s.stay(seconds: 1.5)
        s.realSquats(10, holdAll: 1.9...2.4)
        let r = rtpRun(s.samples, target: 10)
        r.log("vídeo pregrabado con pausa en todas")
        withKnownIssue("Vídeo de sentadillas reales con pausa en todas las reps: indistinguible en 2D") {
            #expect(!r.fullCredit)
        }
    }

    @Test func ataqueVideoEnBucleDeUnaSolaRep() {
        // GIF/bucle de UNA rep con pausa: reps idénticas al frame → tooRegular aunque la meta sea 5.
        var cycle = RTPSynth(seed: 5)
        cycle.stay(seconds: 0.8)
        var bottom = cycle.current
        bottom.descent = 0.21
        cycle.rep(bottom: bottom, down: 1.1, hold: 2.1, up: 1.1)
        let period = cycle.t
        var loop: [PoseSample] = []
        for k in 0..<12 {
            for p in cycle.samples {
                loop.append(PoseSample(t: p.t + Double(k) * period, joints: p.joints, fps: p.fps))
            }
        }
        let five = rtpRun(loop.filter { $0.t < 6.5 * period }, target: 5)
        five.log("bucle de 1 rep, meta 5")
        #expect(!five.fullCredit)
        #expect(five.hard.contains(PoseAnomaly.tooRegular))

        let ten = rtpRun(loop, target: 10)
        ten.log("bucle de 1 rep, meta 10")
        #expect(ten.hard.contains(PoseAnomaly.tooRegular))
        #expect(ten.level == .suspicious)
    }

    // MARK: Escala de la imagen (sin doblar las rodillas)

    @Test func ataqueCaminarHaciaAtrasConElTelefonoEnElSuelo() {
        // Cámara a la altura de los tobillos: alejarse erguido achica la imagen alrededor de los pies. Los
        // anchos de hombros y caderas se achican igual → distanceChanged.
        var s = RTPSynth(seed: 6)
        s.stay(seconds: 1.5)
        for _ in 0..<10 {
            var far = s.current
            far.scale = 0.78
            s.rep(bottom: far, down: s.rng.range(1.2, 1.6), hold: s.rng.range(1.9, 2.3), up: s.rng.range(1.2, 1.6))
            s.stay(seconds: s.rng.range(0.6, 1.2))
        }
        let r = rtpRun(s.samples, target: 10)
        r.log("caminar hacia atrás con el teléfono en el suelo")
        #expect(r.achieved == 0)
        #expect(!r.fullCredit)
        #expect(r.rejections.allSatisfy { $0 == .distanceChanged })
    }

    @Test func ataqueFotoEnTabletConZoomAncladoEnLosPies() {
        var s = RTPSynth(seed: 7)
        s.jitter = 0.0006
        s.stay(seconds: 1.5)
        for _ in 0..<10 {
            var zoomOut = s.current
            zoomOut.scale = 0.78
            s.rep(bottom: zoomOut, down: s.rng.range(0.7, 1.4), hold: s.rng.range(1.9, 2.4), up: s.rng.range(0.7, 1.4))
            s.stay(seconds: s.rng.range(0.4, 1.8))
        }
        let r = rtpRun(s.samples, target: 10)
        r.log("foto en tablet con zoom anclado en los pies")
        #expect(r.achieved == 0)
        #expect(!r.fullCredit)
    }

    @Test func ataqueFotoImpresaInclinadaSobreElBordeDeLosPies() {
        // Escala solo vertical (los anchos no cambian): la canilla se acorta igual que el muslo → kneesStraight.
        var s = RTPSynth(seed: 8)
        s.jitter = 0.003
        s.stay(seconds: 1.5)
        for _ in 0..<10 {
            var tilted = s.current
            tilted.scaleY = 0.78
            s.rep(bottom: tilted, down: s.rng.range(0.8, 1.4), hold: s.rng.range(1.9, 2.4), up: s.rng.range(0.8, 1.4))
            s.stay(seconds: s.rng.range(0.4, 1.8))
        }
        let r = rtpRun(s.samples, target: 10)
        r.log("foto impresa inclinada sobre el borde de los pies")
        #expect(r.achieved == 0)
        #expect(r.rejections.allSatisfy { $0 == .kneesStraight })
    }

    @Test func ataqueTelefonoEnCarroLentoFrenteAPersonaQuieta() {
        var s = RTPSynth(seed: 9)
        s.stay(seconds: 1.5)
        var moves: [(start: Double, seconds: Double, sign: Double)] = []
        for _ in 0..<10 {
            let down = s.rng.range(2.5, 2.8), up = s.rng.range(2.5, 2.8), hold = s.rng.range(1.9, 2.2)
            moves.append((s.t, down, 1))
            moves.append((s.t + down + hold, up, -1))
            var far = s.current
            far.scale = 0.78
            s.rep(bottom: far, down: down, hold: hold, up: up)
            s.stay(seconds: s.rng.range(0.6, 2.2))
        }
        let path = 0.65
        let accel: (Double) -> SIMD3<Double> = { t in
            for m in moves where t >= m.start && t <= m.start + m.seconds {
                let a = m.sign * path * .pi * .pi / (2 * m.seconds * m.seconds) * cos(.pi * (t - m.start) / m.seconds) / 9.81
                return SIMD3(0, 0.26 * a, 0.97 * a)
            }
            return .zero
        }
        let motion = rtpMotion(until: s.t, accel: accel, noiseAccel: 0.008, noiseRotation: 0.03)
        let r = rtpRun(s.samples, motion: motion, target: 10)
        r.log("teléfono en carro lento")
        #expect(r.achieved == 0)
        #expect(!r.fullCredit)
    }

    // MARK: Inclinarse de cintura, medias sentadillas

    @Test func ataqueInclinarseDeCinturaSinDoblarRodillas() {
        var s = RTPSynth(seed: 10)
        s.stay(seconds: 1.5)
        for i in 0..<10 {
            var hinge = s.current
            if i.isMultiple(of: 2) {
                hinge.descent = 0.04; hinge.kneeFactor = 0.0; hinge.fold = 0.30
            } else {
                hinge.descent = 0.14; hinge.kneeFactor = 0.3; hinge.fold = 0.22
            }
            s.rep(bottom: hinge, down: s.rng.range(0.9, 1.3), hold: s.rng.range(1.9, 2.3), up: s.rng.range(0.9, 1.3))
            s.stay(seconds: s.rng.range(0.5, 1.0))
        }
        let r = rtpRun(s.samples, target: 10)
        r.log("inclinarse de cintura")
        #expect(r.achieved == 0)
        #expect(r.hard.isEmpty)
    }

    @Test func ataqueMediasSentadillas() {
        var s = RTPSynth(seed: 11)
        s.stay(seconds: 1.5)
        s.realSquats(10, depth: 0.08...0.11, holdAll: 1.9...2.3)
        let r = rtpRun(s.samples, target: 10)
        r.log("medias sentadillas (0,08-0,11 h0)")
        #expect(r.achieved == 0)
    }

    // MARK: Cámara tapada u oscura, sujeto fuera de cuadro

    @Test func ataqueCamaraTapadaUOscura() {
        var covered = RTPSynth(seed: 12)
        covered.empty(seconds: 20)
        let c = rtpRun(covered.samples, target: 10)
        c.log("cámara tapada")
        #expect(c.achieved == 0)
        #expect(!c.events.contains(.gate(.ready)))

        var dark = RTPSynth(seed: 13)
        dark.confidence = 0.35
        dark.jitter = 0.01
        dark.stay(seconds: 1.5)
        dark.realSquats(10, holdAll: 1.9...2.3)
        let d = rtpRun(dark.samples, target: 10)
        d.log("cámara oscura (confianza 0,35)")
        #expect(d.achieved == 0)
        #expect(!d.events.contains(.gate(.ready)))
    }

    @Test func ataqueSujetoParcialmenteFueraDeCuadro() {
        var legsOut = RTPSynth(seed: 14)
        legsOut.hidden = [.leftAnkle, .rightAnkle, .leftKnee, .rightKnee]
        legsOut.stay(seconds: 1.5)
        legsOut.realSquats(10, holdAll: 1.9...2.3)
        let r = rtpRun(legsOut.samples, target: 10)
        r.log("piernas fuera de cuadro")
        #expect(r.achieved == 0)
        #expect(!r.events.contains(.gate(.ready)))

        // Cabeza cortada arriba (casco fuera de cuadro) con hombros visibles: legítimo, debe contar.
        var session = RTPSession(target: 10)
        var headOut = RTPSynth(seed: 15)
        headOut.hidden = [.nose, .neck]
        headOut.stay(seconds: 1.5)
        session.squats(&headOut, 10)
        let h = session.result(headOut)
        h.log("cabeza fuera de cuadro (legítimo)")
        #expect(h.achieved == 10)
    }

    // MARK: Operador real que sigue la consigna (lazo cerrado)

    @Test func legitimoApoyarElTelefonoDespuesDeIniciar() {
        // La actividad arranca con el teléfono en la mano; el operador lo apoya y camina a 2 m. Quieto en la
        // mesa, la referencia de gravedad se re-ancla aunque quede "inclinado" respecto de la mano.
        let motion = rtpMotion(until: 240,
                               gravity: { t in t < 3 ? SIMD3(0, -0.71, -0.70) : SIMD3(0, -0.98, -0.2) },
                               accel: { t in (t >= 3 && t < 4.2) ? SIMD3(0.08, 0.12, 0.1) : .zero },
                               rotation: { t in t < 3 ? SIMD3(0.2, 0.1, 0.1) : (t < 4.2 ? SIMD3(0.9, 0.6, 0.4) : .zero) })
        var session = RTPSession(target: 10, motion: motion)
        var s = RTPSynth(seed: 16)
        s.empty(seconds: 6)
        s.stay(seconds: 1.5)
        session.squats(&s, 10)
        let r = session.result(s)
        r.log("apoyar el teléfono después de iniciar")
        #expect(r.achieved == 10)
        #expect(r.level == .full)
    }

    @Test func legitimoTelefonoApoyadoQueSeVaDeLado() {
        // Tras 3 reps el teléfono se va 6° de lado contra la taza y queda quieto: nueva referencia.
        let tipStart = 9.0, tipSeconds = 0.15
        let motion = rtpMotion(until: 240,
                               gravity: { t in rtpRolledGravity(t < tipStart ? 0 : min(6, (t - tipStart) / tipSeconds * 6)) },
                               accel: { t in (t >= tipStart && t < tipStart + tipSeconds) ? SIMD3(0.05, 0.08, 0.05) : .zero },
                               rotation: { t in (t >= tipStart && t < tipStart + tipSeconds) ? SIMD3(0, 0, 0.7) : .zero })
        var session = RTPSession(target: 10, motion: motion)
        var s = RTPSynth(seed: 17)
        s.stay(seconds: 1.5)
        session.squats(&s, 3)
        if s.t < tipStart { s.stay(seconds: tipStart - s.t) }
        var tipped = s.current
        tipped.rollDegrees = 6
        s.move(to: tipped, seconds: tipSeconds)
        s.stay(seconds: 1.5)
        session.squats(&s, 9)
        let r = session.result(s)
        r.log("teléfono que se va 6° entre reps, 12 intentos")
        #expect(r.achieved == 10)
        #expect(r.hard.isEmpty)
    }

    @Test func legitimoOperadorUnPocoMasLejos() {
        // A ~2,6 m (h0 0,40): calibrado, abajo basta el cuerpo entero con ≥ 55 % de la estatura de pie.
        var session = RTPSession(target: 10)
        var s = RTPSynth(seed: 18)
        s.bodyScale = 0.6
        s.stay(seconds: 1.5)
        session.squats(&s, 12)
        let r = session.result(s)
        r.log("operador a ~2,6 m (h0 0,40), 12 intentos")
        #expect(r.achieved == 10)
    }

    @Test func operadorDemasiadoLejosRecibeAcerquese() {
        // Cuerpo entero pero más chico que 1/3 del cuadro: la consigna es acercarse, no alejarse.
        var s = RTPSynth(seed: 24)
        s.bodyScale = 0.42
        s.stay(seconds: 3)
        let spec = VerificationSpec.standard(for: .sentadilla, target: 10)
        var v = SupportedSquatVerifier(spec: spec)
        v.start(at: 0)
        for p in s.samples { _ = v.ingest(.pose(p), at: p.t) }
        #expect(v.progress.gate == .calibrating)
        #expect(v.progress.hint == PoseCopy.comeCloser)
    }

    @Test func legitimoSeAcercaParaLeerLaPantalla() {
        // Tras 3 reps se acerca ~15 cm para leer la consigna: los tobillos se miden contra su posición de pie
        // justo antes de cada rep (no contra la calibración original).
        var session = RTPSession(target: 10)
        var s = RTPSynth(seed: 19)
        s.stay(seconds: 1.5)
        session.squats(&s, 3)
        var closer = s.current
        closer.scale = 1.08
        closer.anchorY = RTPBody.horizonY
        s.move(to: closer, seconds: 0.9)
        s.stay(seconds: 1.5)
        session.squats(&s, 9)
        let r = session.result(s)
        r.log("se acerca 15 cm tras 3 reps, 12 intentos")
        #expect(r.achieved == 10)
    }

    @Test func legitimoSentarseYPararseDeUnaSilla() {
        var session = RTPSession(target: 10)
        var s = RTPSynth(seed: 20)
        s.stay(seconds: 1.5)
        session.squats(&s, 10, depth: 0.26...0.30, kneeFactor: 0.05, fold: 0.02...0.05)
        let r = session.result(s)
        r.log("silla sin mover los pies")
        #expect(r.achieved == 10)
        #expect(r.level == .full)
    }

    @Test func legitimoSillaConLosPiesRecogidos() {
        // Recoge los pies ~15 cm hacia la silla al pararse: tobillos suavizados y tolerancia de 0,07·h0.
        var session = RTPSession(target: 10)
        var s = RTPSynth(seed: 21)
        s.stay(seconds: 1.5)
        session.squats(&s, 12, depth: 0.26...0.30, kneeFactor: 0.05, fold: 0.02...0.05, ankleShiftAtBottom: 0.03)
        let r = session.result(s)
        r.log("silla con los pies recogidos, 12 intentos")
        #expect(r.achieved == 10)
    }

    @Test func legitimoRopaHolgadaYBotas() {
        // Ruido gaussiano en rodillas y tobillos (pantalón holgado, botas), persona a ~2,3 m (h0 0,54).
        for (i, sigma) in [0.004, 0.008, 0.012, 0.016].enumerated() {
            var session = RTPSession(target: 10)
            var s = RTPSynth(seed: 220 + UInt64(i))
            s.bodyScale = 0.8
            s.jitter = 0.003
            s.legSigma = sigma
            s.stay(seconds: 1.5)
            session.squats(&s, 12, depth: 0.16...0.22)
            let r = session.result(s)
            r.log("ropa holgada σ=\(sigma), h0 0,54, 12 intentos")
            #expect(r.achieved == 10, "σ = \(sigma)")
        }
    }

    @Test func legitimoSentadillaParcialConInclinacionNatural() {
        var session = RTPSession(target: 10)
        var s = RTPSynth(seed: 23)
        s.stay(seconds: 1.5)
        session.squats(&s, 12, depth: 0.14...0.16, fold: 0.10...0.11)
        let r = session.result(s)
        r.log("parcial con inclinación natural ~45°, 12 intentos")
        #expect(r.achieved == 10)
        #expect(r.level == .full)
    }

    @Test func legitimoGolpeAisladoAlTelefonoEnUnaRepEsSoft() {
        // Un roce que mueve el teléfono durante UNA rep: esa rep no cuenta y queda phoneHandheld soft.
        var session = RTPSession(target: 10, motion: rtpMotion(until: 240,
                                                               accel: { t in (t >= 4.4 && t < 4.9) ? SIMD3(0.09, 0.09, 0.09) : .zero },
                                                               rotation: { t in (t >= 4.4 && t < 4.9) ? SIMD3(0.5, 0.4, 0.3) : .zero }))
        var s = RTPSynth(seed: 25)
        s.stay(seconds: 1.5)
        session.squats(&s, 12)
        let r = session.result(s)
        r.log("golpe aislado en una rep")
        #expect(r.achieved == 10)
        #expect(r.hard.isEmpty)
        #expect(r.rejections.filter { $0 == .phoneHandheld }.count <= 1)
    }
}
