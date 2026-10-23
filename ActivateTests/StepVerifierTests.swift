import Testing
import Foundation
@testable import Activate

/// Fixtures sintéticas para `PedometerVerifier` (A2 "Camina").
/// Cada fixture mezcla los tres streams como los entregaría `StepSource`: podómetro cada 3 s (acumulado),
/// deviceMotion a 50 Hz y una clasificación de actividad inicial.
nonisolated enum StepFixtures {
    static let hz = 50.0
    static let callbackEvery = 3.0

    struct Options {
        var duration: Double
        /// Pasos por segundo que informa el coprocesador (acumulado = cadence × t).
        var cadence: Double
        /// RMS de |userAccel| (g) de la señal de movimiento.
        var accelRMS: Double
        var activity: ActivitySample
        /// Ventanas [desde, hasta) con un RMS distinto (picos aislados).
        var spikes: [(from: Double, to: Double, rms: Double)] = []
        var reportCadence = true
    }

    static func walking(confidence: Int = 2) -> ActivitySample {
        ActivitySample(t: 0.5, walking: true, running: false, stationary: false, automotive: false, unknown: false, confidence: confidence)
    }

    static func stationary(confidence: Int = 2) -> ActivitySample {
        ActivitySample(t: 0.5, walking: false, running: false, stationary: true, automotive: false, unknown: false, confidence: confidence)
    }

    static func make(_ o: Options) -> [(t: Double, sample: StepSample)] {
        var out: [(t: Double, sample: StepSample)] = []
        out.append((o.activity.t, .activity(o.activity)))
        let n = Int(o.duration * hz)
        for i in 0..<n {
            let t = Double(i) / hz
            let rms = o.spikes.first { t >= $0.from && t < $0.to }?.rms ?? o.accelRMS
            // Seno de amplitud rms·√2 → RMS = rms.
            let a = rms * 2.0.squareRoot() * sin(2 * .pi * max(o.cadence, 1) * t)
            out.append((t, .motion(MotionSample(t: t, userAccel: SIMD3(0, a, 0), gravity: SIMD3(0, -1, 0), rotationRate: .zero))))
        }
        var t = callbackEvery
        while t <= o.duration {
            let steps = Int((o.cadence * t).rounded(.down))
            out.append((t, .pedometer(PedometerSample(t: t, steps: steps, cadence: o.reportCadence ? o.cadence : nil, distance: nil))))
            t += callbackEvery
        }
        return out.sorted { $0.t < $1.t }
    }

    /// Corre la fixture completa y devuelve los eventos y el outcome.
    static func run(_ o: Options, spec: VerificationSpec, reason: FinishReason = .completed) -> (events: [VerifierEvent], outcome: ActivityOutcome, verifier: PedometerVerifier) {
        var v = PedometerVerifier(spec: spec)
        v.start(at: 0)
        var events: [VerifierEvent] = []
        for (t, s) in make(o) { events += v.ingest(s, at: t) }
        let outcome = v.finish(at: o.duration, reason: reason)
        return (events, outcome, v)
    }

    static func hardAnomalies(_ events: [VerifierEvent]) -> [Anomaly] {
        events.compactMap { if case .anomaly(let a) = $0, a.severity == .hard { return a } else { return nil } }
    }
}

struct StepVerifierTests {
    private let demo = VerificationSpec.standard(for: .pasos, demo: true) // 30 pasos, mínimo 10 s

    @Test func marchaRealCuentaYQuedaSinAnomaliasHard() {
        let r = StepFixtures.run(.init(duration: 24, cadence: 1.8, accelRMS: 0.3, activity: StepFixtures.walking()), spec: demo)
        #expect(r.events.contains(.completed))
        #expect(r.outcome.completed)
        #expect(r.outcome.achieved >= demo.target)
        #expect(r.outcome.anomalies.allSatisfy { $0.severity == .soft })
        #expect(r.outcome.anomalies.isEmpty)
        #expect(VerificationPolicy.level(for: r.outcome, source: .live, kind: .pasos) == .full)
        guard case .steps(let count, let cadence, let walking, let rms) = r.outcome.metrics else {
            Issue.record("métricas no son .steps"); return
        }
        #expect(count == r.outcome.achieved)
        #expect(abs((cadence ?? 0) - 1.8) < 0.2)
        #expect((walking ?? 0) > 0.95)
        #expect((rms ?? 1) < PedometerVerifier.Tuning.rmsMaxG)
    }

    @Test func sacudidaConEstacionarioEsHard() {
        // Teléfono sacudido de pie: el clasificador dice stationary (alta), el RMS supera el tope y los pasos suben.
        let r = StepFixtures.run(.init(duration: 20, cadence: 2.5, accelRMS: 1.5, activity: StepFixtures.stationary()), spec: demo)
        let hard = StepFixtures.hardAnomalies(r.events)
        #expect(hard.contains { $0.kind == PedometerVerifier.AnomalyKind.stationaryWhileCounting })
        #expect(r.outcome.anomalies.contains { $0.kind == PedometerVerifier.AnomalyKind.stepGatesFailed && $0.severity == .hard })
        #expect(r.outcome.anomalies.contains { $0.kind == PedometerVerifier.AnomalyKind.accelRMSHigh })
        #expect(r.outcome.anomalies.contains { $0.kind == PedometerVerifier.AnomalyKind.walkingFractionLow })
        #expect(VerificationPolicy.level(for: r.outcome, source: .live, kind: .pasos) == .suspicious)
    }

    @Test func marchaCortaConCadenciaUnoEsValida() {
        // Marcha lenta por dolor: 1,0 pasos/s con confianza media no debe salir sospechosa.
        let r = StepFixtures.run(.init(duration: 33, cadence: 1.0, accelRMS: 0.25, activity: StepFixtures.walking(confidence: 1)), spec: demo)
        #expect(r.events.contains(.completed))
        #expect(r.outcome.completed)
        #expect(r.outcome.anomalies.isEmpty)
        #expect(VerificationPolicy.level(for: r.outcome, source: .live, kind: .pasos) == .full)
        guard case .steps(_, let cadence, _, _) = r.outcome.metrics else { Issue.record("métricas no son .steps"); return }
        #expect(abs((cadence ?? 0) - 1.0) < 0.15)
    }

    @Test func unSoloPicoDeAceleracionNoFallaElGate() {
        // Guardar el teléfono en el bolsillo produce un pico aislado; no es sacudida sostenida.
        let r = StepFixtures.run(.init(duration: 24, cadence: 1.8, accelRMS: 0.3, activity: StepFixtures.walking(),
                                       spikes: [(from: 4, to: 6, rms: 2.0)]), spec: demo)
        #expect(r.outcome.completed)
        #expect(!r.outcome.anomalies.contains { $0.kind == PedometerVerifier.AnomalyKind.accelRMSHigh })
        guard case .steps(_, _, _, let rms) = r.outcome.metrics else { Issue.record("métricas no son .steps"); return }
        #expect((rms ?? 0) > PedometerVerifier.Tuning.rmsMaxG)
    }

    @Test func soloFallarUnGateNoEsSospechoso() {
        // RMS alto pero caminando con cadencia plausible (p. ej. teléfono suelto en el bolsillo): 1 de 3 → sin hard.
        let r = StepFixtures.run(.init(duration: 24, cadence: 1.8, accelRMS: 1.0, activity: StepFixtures.walking()), spec: demo)
        #expect(r.outcome.anomalies.contains { $0.kind == PedometerVerifier.AnomalyKind.accelRMSHigh && $0.severity == .soft })
        #expect(!r.outcome.anomalies.contains { $0.severity == .hard })
        #expect(VerificationPolicy.level(for: r.outcome, source: .live, kind: .pasos) == .full)
    }

    @Test func barraPredictivaAvanzaEntreCallbacksSinTocarElContador() {
        var v = PedometerVerifier(spec: demo)
        v.start(at: 0)
        _ = v.ingest(.activity(StepFixtures.walking()), at: 0.5)
        _ = v.ingest(.pedometer(PedometerSample(t: 3, steps: 5, cadence: 1.8, distance: nil)), at: 3)
        #expect(v.progress.count == 5)
        var predicted: [Double] = []
        for i in 1...100 {
            let t = 3 + Double(i) / StepFixtures.hz
            let m = MotionSample(t: t, userAccel: SIMD3(0, 0.2, 0), gravity: SIMD3(0, -1, 0), rotationRate: .zero)
            for e in v.ingest(.motion(m), at: t) { if case .progress(let p) = e { predicted.append(p) } }
        }
        #expect(!predicted.isEmpty)
        #expect((predicted.last ?? 0) > v.progress.fraction)
        #expect(v.progress.count == 5)
    }

    @Test func noCompletaAntesDeLaDuracionMinima() {
        var v = PedometerVerifier(spec: demo)
        v.start(at: 0)
        _ = v.ingest(.activity(StepFixtures.walking()), at: 0.5)
        let early = v.ingest(.pedometer(PedometerSample(t: 6, steps: 31, cadence: 3.0, distance: nil)), at: 6)
        #expect(!early.contains(.completed))
        #expect(early.contains { if case .cue(let c) = $0 { return c.text == PedometerVerifier.Copy.keepGoing } else { return false } })
        let later = v.ingest(.pedometer(PedometerSample(t: 12, steps: 40, cadence: 1.5, distance: nil)), at: 12)
        #expect(later.contains(.completed))
        #expect(v.progress.count == 40)
        #expect(v.progress.hint == PedometerVerifier.Copy.done)
    }

    @Test func saltarOTerminarAntesNoCompleta() {
        var v = PedometerVerifier(spec: demo)
        v.start(at: 0)
        _ = v.ingest(.pedometer(PedometerSample(t: 6, steps: 12, cadence: 2.0, distance: nil)), at: 6)
        let stopped = v.finish(at: 7, reason: .userStopped)
        #expect(!stopped.completed)
        #expect(stopped.achieved == 12)
        #expect(stopped.reason == .userStopped)

        var w = PedometerVerifier(spec: demo)
        w.start(at: 0)
        _ = w.ingest(.pedometer(PedometerSample(t: 12, steps: 35, cadence: 2.0, distance: nil)), at: 12)
        let skipped = w.finish(at: 12, reason: .skipped)
        #expect(!skipped.completed)
    }

    @Test func reconciliacionAcreditaPasosAcumulados() {
        // Tras una suspensión, StepSource inyecta una muestra con el acumulado real: el contador salta sin duplicar.
        var v = PedometerVerifier(spec: demo)
        v.start(at: 0)
        _ = v.ingest(.pedometer(PedometerSample(t: 3, steps: 4, cadence: 1.5, distance: nil)), at: 3)
        let events = v.ingest(.pedometer(PedometerSample(t: 40, steps: 55, cadence: nil, distance: nil)), at: 40)
        #expect(events.contains(.rep(55)))
        #expect(events.contains(.completed))
        let outcome = v.finish(at: 41, reason: .completed)
        #expect(outcome.achieved == 55)
        #expect(outcome.completed)
    }
}
