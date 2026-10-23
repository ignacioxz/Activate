import Testing
import Foundation
@testable import Activate

/// Simula la vista: lee el cue del ensayo, espera el ISI, muestra, responde con un RT dado.
private struct StroopDriver {
    var verifier: StroopVerifier
    /// Segundos desde el inicio (reloj del runner y de la fuente, misma base en los tests).
    var t: Double = 0
    var pending: StroopCue? = nil
    var events: [VerifierEvent] = []

    init(target: Int = 20, demo: Bool = true, seed: UInt64 = 7) {
        verifier = StroopVerifier(spec: .standard(for: .stroop, target: target, demo: demo), seed: seed)
    }

    private mutating func absorb(_ evs: [VerifierEvent]) {
        events.append(contentsOf: evs)
        for e in evs {
            if case .cue(let c) = e, let trial = StroopCue(cue: c) { pending = trial }
        }
    }

    mutating func begin() {
        verifier.start(at: t)
        absorb(verifier.ingest(.touchUp(t: t), at: t))
    }

    /// Responde el ensayo pendiente. `key` elige la tecla (−1 = sin respuesta).
    @discardableResult
    mutating func answer(rtMs: Int, key: (StroopCue) -> Int) -> [VerifierEvent] {
        guard let trial = pending else { return [] }
        pending = nil
        t += Double(trial.isiMs) / 1000
        let shownMs = Int((t * 1000).rounded())
        absorb(verifier.ingest(.stroopShown(trialIndex: trial.index, atMs: shownMs), at: t))
        t += Double(rtMs) / 1000
        let evs = verifier.ingest(.stroopAnswer(trialIndex: trial.index, answer: key(trial), atMs: shownMs + rtMs), at: t)
        absorb(evs)
        return evs
    }

    mutating func run(trials: Int, rtMs: (StroopCue) -> Int, key: (StroopCue) -> Int) {
        for _ in 0..<trials where pending != nil {
            let trial = pending!
            answer(rtMs: rtMs(trial), key: key)
        }
    }

    mutating func finish(reason: FinishReason = .completed) -> ActivityOutcome {
        verifier.finish(at: t, reason: reason)
    }

    var hardAnomalies: [Anomaly] { events.compactMap { if case .anomaly(let a) = $0, a.severity == .hard { a } else { nil } } }
    var completedEvents: Int { events.filter { $0 == .completed }.count }
}

struct StroopTests {
    @Test func secuenciaReproduciblePorSemilla() {
        let a = StroopVerifier.makeSequence(count: 40, seed: 12345)
        let b = StroopVerifier.makeSequence(count: 40, seed: 12345)
        let c = StroopVerifier.makeSequence(count: 40, seed: 54321)
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 40)
        #expect(a.filter { !$0.congruent }.count == 20)
        for (i, trial) in a.enumerated() {
            #expect(trial.index == i)
            #expect((0..<StroopVerifier.colorCount).contains(trial.word))
            #expect((0..<StroopVerifier.colorCount).contains(trial.ink))
            #expect(trial.congruent == (trial.word == trial.ink))
            #expect(StroopVerifier.isiRangeMs.contains(trial.isiMs))
        }
        // Nunca más de 2 tintas iguales seguidas.
        var run = 1
        for i in 1..<a.count {
            run = a[i].ink == a[i - 1].ink ? run + 1 : 1
            #expect(run <= StroopVerifier.maxSameInkRun)
        }
        let v1 = StroopVerifier(spec: .standard(for: .stroop, demo: true), seed: 99)
        let v2 = StroopVerifier(spec: .standard(for: .stroop, demo: true), seed: 99)
        #expect(v1.trials == v2.trials)
        #expect(v1.trials.count == ActivityKind.stroop.demoTarget)
    }

    @Test func cueCodificaYDecodificaElEnsayo() {
        let trial = StroopCue(index: 3, word: 0, ink: 1, isiMs: 850)
        #expect(trial.cue.text == "ROJO|verde|3|850")
        #expect(StroopCue(cue: trial.cue) == trial)
        #expect(StroopCue(cue: Cue(text: "Toque para empezar")) == nil)
        #expect(StroopCue(cue: Cue(text: "ROJO|morado|3|850")) == nil)
    }

    @Test func testValidoCompleta() {
        var d = StroopDriver(seed: 11)
        d.begin()
        #expect(d.pending?.index == 0)
        d.run(trials: 20, rtMs: { $0.ink == $0.word ? 600 : 760 }, key: { $0.ink })
        #expect(d.pending == nil)
        #expect(d.completedEvents == 1)
        #expect(d.hardAnomalies.isEmpty)
        let outcome = d.finish()
        #expect(outcome.completed)
        #expect(outcome.achieved == 20)
        #expect(outcome.target == 20)
        guard case .stroop(let trials, let valid, let accuracy, let median, let congruent, let incongruent, let anticipations, let lapses, let seed) = outcome.metrics else {
            Issue.record("métricas no son .stroop")
            return
        }
        #expect(trials == 20 && valid == 20 && accuracy == 1)
        #expect(congruent == 600 && incongruent == 760)
        #expect(median >= 600 && median <= 760)
        #expect(anticipations == 0 && lapses == 0)
        #expect(seed == 11)
        #expect(outcome.metrics.stroopEffectMs == 160)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .stroop) == .full)
        #expect(d.verifier.progress.count == 20)
        #expect(d.verifier.progress.fraction == 1)
    }

    @Test func anticipacionesNoValen() {
        var d = StroopDriver(seed: 3)
        d.begin()
        d.run(trials: 20, rtMs: { _ in 100 }, key: { $0.ink })
        let outcome = d.finish()
        #expect(!outcome.completed)
        #expect(outcome.achieved == 0)
        guard case .stroop(let trials, let valid, _, _, _, _, let anticipations, _, _) = outcome.metrics else {
            Issue.record("métricas no son .stroop")
            return
        }
        #expect(trials == 20 && valid == 0 && anticipations == 20)
        // Test no confiable, no sospechoso.
        #expect(outcome.anomalies.isEmpty)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .stroop) == .full)
    }

    @Test func lapsosNoValen() {
        var d = StroopDriver(seed: 5)
        d.begin()
        // 10 lapsos por tiempo, 4 sin respuesta, 6 válidos.
        var i = 0
        d.run(trials: 20, rtMs: { _ in
            defer { i += 1 }
            return i < 10 ? 2300 : 500
        }, key: { trial in (10..<14).contains(trial.index) ? StroopVerifier.noResponse : trial.ink })
        let outcome = d.finish()
        guard case .stroop(_, let valid, _, _, _, _, _, let lapses, _) = outcome.metrics else {
            Issue.record("métricas no son .stroop")
            return
        }
        #expect(lapses == 14)
        #expect(valid == 6)
        #expect(!outcome.completed)
        #expect(outcome.anomalies.isEmpty)
    }

    @Test func aporreoMismaTeclaEsAnomaliaHard() {
        var d = StroopDriver(seed: 21)
        d.begin()
        d.run(trials: 20, rtMs: { _ in 400 }, key: { _ in 2 })
        let outcome = d.finish()
        #expect(d.hardAnomalies.count == 1)
        #expect(d.hardAnomalies.first?.kind == StroopVerifier.anomalyButtonMashing)
        #expect(outcome.anomalies.count == 1)
        #expect(outcome.anomalies.first?.severity == .hard)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .stroop) == .suspicious)
    }

    @Test func aporreoPorPrecisionMuyBaja() {
        var d = StroopDriver(seed: 8)
        d.begin()
        // Siempre equivocado, alternando teclas (nunca 6 iguales seguidas).
        d.run(trials: 20, rtMs: { _ in 450 }, key: { ($0.ink + 1 + $0.index % 2) % StroopVerifier.colorCount })
        let outcome = d.finish()
        #expect(outcome.anomalies.contains { $0.kind == StroopVerifier.anomalyButtonMashing && $0.severity == .hard })
        #expect(!outcome.completed)
    }

    @Test func precisionBajaNoCompletaSinAnomalia() {
        var d = StroopDriver(seed: 13)
        d.begin()
        // Mitad correctas, mitad equivocadas: precisión 0,5 (< 0,7 pero > 0,35).
        d.run(trials: 20, rtMs: { _ in 550 }, key: { $0.index.isMultiple(of: 2) ? $0.ink : ($0.ink + 1) % StroopVerifier.colorCount })
        let outcome = d.finish()
        #expect(!outcome.completed)
        #expect(outcome.achieved == 20)
        #expect(outcome.anomalies.isEmpty)
        guard case .stroop(_, let valid, let accuracy, _, _, _, _, _, _) = outcome.metrics else {
            Issue.record("métricas no son .stroop")
            return
        }
        #expect(valid == 20)
        #expect(abs(accuracy - 0.5) < 0.001)
    }

    @Test func unLapsoEnDemoNoInvalida() {
        var d = StroopDriver(seed: 17)
        d.begin()
        d.run(trials: 20, rtMs: { $0.index == 4 ? 2500 : 650 }, key: { $0.ink })
        let outcome = d.finish()
        #expect(outcome.completed)
        #expect(outcome.achieved == 19)
    }

    @Test func cajaDeSesentaSegundosCierraElTest() {
        var d = StroopDriver(target: 40, demo: false, seed: 2)
        d.begin()
        // Respuestas lentas pero válidas: 1,5 s ISI máx + 1,9 s → ~3 s por ensayo; en 60 s caben ~20.
        d.run(trials: 40, rtMs: { _ in 1900 }, key: { $0.ink })
        #expect(d.completedEvents == 1)
        #expect(d.pending == nil)
        #expect(d.t >= StroopVerifier.windowSeconds)
        let outcome = d.finish()
        #expect(outcome.achieved < 40)
        #expect(outcome.achieved >= StroopVerifier.minValidTrials)
        #expect(outcome.completed)
    }

    @Test func ignoraMuestrasFueraDeOrden() {
        var v = StroopVerifier(spec: .standard(for: .stroop, demo: true), seed: 1)
        v.start(at: 0)
        // Antes de la señal de listo nada cuenta.
        #expect(v.ingest(.stroopShown(trialIndex: 0, atMs: 10), at: 0.01).isEmpty)
        #expect(v.ingest(.stroopAnswer(trialIndex: 0, answer: 1, atMs: 500), at: 0.5).isEmpty)
        let first = v.ingest(.touchUp(t: 1), at: 1)
        #expect(first.contains { if case .cue = $0 { true } else { false } })
        // Respuesta sin "shown" previo: se ignora.
        #expect(v.ingest(.stroopAnswer(trialIndex: 0, answer: 1, atMs: 1500), at: 1.5).isEmpty)
        // Ensayo equivocado: se ignora.
        #expect(v.ingest(.stroopShown(trialIndex: 3, atMs: 1600), at: 1.6).isEmpty)
        _ = v.ingest(.stroopShown(trialIndex: 0, atMs: 2000), at: 2)
        let evs = v.ingest(.stroopAnswer(trialIndex: 0, answer: v.trials[0].ink, atMs: 2600), at: 2.6)
        #expect(evs.contains(.rep(1)))
        // Doble respuesta al mismo ensayo: se ignora.
        #expect(v.ingest(.stroopAnswer(trialIndex: 0, answer: 0, atMs: 2700), at: 2.7).isEmpty)
        #expect(v.current == 1)
    }
}

struct BreathVerifierTests {
    private func verifier(target: Int = 3) -> BreathVerifier {
        BreathVerifier(spec: .standard(for: .respiracion, target: target, demo: true))
    }

    private var origin: Double { BreathVerifier.leadInSeconds }
    private var cycle: Double { BreathVerifier.cycleSeconds }
    private var inhale: Double { BreathVerifier.inhaleSeconds }

    @Test func faseDelPatron() {
        #expect(BreathVerifier.phase(at: 0.5).leadIn)
        let p1 = BreathVerifier.phase(at: origin + 1)
        #expect(p1.cycle == 0 && p1.inhaling && !p1.leadIn)
        let p2 = BreathVerifier.phase(at: origin + inhale + 3)
        #expect(p2.cycle == 0 && !p2.inhaling && abs(p2.fraction - 0.5) < 0.001)
        let p3 = BreathVerifier.phase(at: origin + cycle * 2 + 0.5)
        #expect(p3.cycle == 2 && p3.inhaling)
    }

    @Test func dedoEnLaExhalacionCuentaCiclos() {
        var v = verifier()
        v.start(at: 0)
        var all: [VerifierEvent] = []
        for k in 0..<3 {
            let exhaleStart = origin + Double(k) * cycle + inhale
            let down = exhaleStart + 0.3
            let up = exhaleStart + 5.8
            all += v.ingest(.touchDown(t: down), at: down)
            all += v.ingest(.touchUp(t: up), at: up)
            #expect(v.cycles == k + 1)
        }
        #expect(all.contains(.rep(3)))
        #expect(all.contains(.completed))
        let outcome = v.finish(at: origin + 3 * cycle, reason: .completed)
        #expect(outcome.completed)
        #expect(outcome.achieved == 3)
        #expect(outcome.metrics == .breath(cycles: 3))
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .respiracion) == .reduced)
    }

    @Test func exhalacionCortaNoCuenta() {
        var v = verifier()
        v.start(at: 0)
        let exhaleStart = origin + inhale
        _ = v.ingest(.touchDown(t: exhaleStart + 0.5), at: exhaleStart + 0.5)
        let evs = v.ingest(.touchUp(t: exhaleStart + 4.0), at: exhaleStart + 4.0)
        #expect(evs.isEmpty)
        #expect(v.cycles == 0)
    }

    @Test func mantenerSiempreApretadoNoCuenta() {
        var v = verifier()
        v.start(at: 0)
        _ = v.ingest(.touchDown(t: 0.5), at: 0.5)
        let end = origin + 3 * cycle
        let evs = v.ingest(.touchUp(t: end), at: end)
        #expect(evs.isEmpty)
        #expect(v.cycles == 0)
        let outcome = v.finish(at: end, reason: .timeout)
        #expect(!outcome.completed)
        #expect(outcome.achieved == 0)
    }

    @Test func dedoApretadoAlTerminarSeEvaluaEnFinish() {
        var v = verifier(target: 1)
        v.start(at: 0)
        let exhaleStart = origin + inhale
        _ = v.ingest(.touchDown(t: exhaleStart + 0.2), at: exhaleStart + 0.2)
        let outcome = v.finish(at: exhaleStart + 5.9, reason: .timeout)
        #expect(outcome.achieved == 1)
        #expect(outcome.completed)
    }
}
