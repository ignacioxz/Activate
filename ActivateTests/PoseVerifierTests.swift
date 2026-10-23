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

    /// `descent` en fracción de h0 (sentadilla); `shift` en fracción del frame (extensión, hombros atrás); `rise` en fracción de h0 (cuello sube).
    mutating func frame(descent: Double = 0, shift: Double = 0, rise: Double = 0) {
        let d = descent * Synth.h0
        var joints: [JointKey: JointPoint] = [:]
        for (k, p) in Synth.base {
            var x = p.x, y = p.y
            switch k {
            case .leftKnee, .rightKnee:
                y -= d / 2
                x += (k == .leftKnee ? -1 : 1) * 0.2 * d
            case .leftAnkle, .rightAnkle:
                break
            case .nose, .neck, .leftShoulder, .rightShoulder:
                y -= d
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
        let n = Int((seconds * Synth.fps).rounded())
        for i in 0..<n {
            let p = Double(i) / Double(n)
            frame(descent: amplitude * (1 - cos(2 * .pi * p)) / 2)
        }
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
}
