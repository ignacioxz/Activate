import Testing
import Foundation
@testable import Activate

// MARK: - Dobles de prueba

/// Muestra mínima con tiempo propio.
nonisolated struct Tick: Sendable, Codable, Hashable, TimedSample {
    var t: Double
    var value: Double
}

/// Verificador trivial: cada muestra con `value ≥ 0.5` es una rep; `value < 0` es anomalía hard.
nonisolated struct CountingVerifier: ActivityVerifier {
    typealias Sample = Tick

    var spec: VerificationSpec
    var progress: VerifierProgress
    var anomalies: [Anomaly] = []
    var startedAt: Double? = nil
    var kind: ActivityKind { spec.kind }

    init(spec: VerificationSpec) {
        self.spec = spec
        progress = VerifierProgress(target: spec.target)
    }

    mutating func start(at t: Double) {
        startedAt = t
        progress.gate = .ready
        progress.hint = "Empiece cuando quiera"
    }

    mutating func ingest(_ sample: Tick, at t: Double) -> [VerifierEvent] {
        var events: [VerifierEvent] = []
        if sample.value < 0 {
            let a = Anomaly(kind: "test", severity: .hard, at: t)
            anomalies.append(a)
            events.append(.anomaly(a))
        } else if sample.value >= 0.5 {
            progress.count += 1
            events.append(.rep(progress.count))
            if progress.count == 1 { events.append(.cue(Cue(text: "Siga así"))) }
            events.append(.progress(progress.fraction))
        }
        progress.elapsed = t
        if progress.count >= spec.target { events.append(.completed) }
        return events
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        ActivityOutcome(kind: kind, target: spec.target, achieved: progress.count,
                        completed: reason == .completed && progress.count >= spec.target,
                        durationSeconds: t,
                        metrics: .reps(count: progress.count, minDescentRatio: nil, meanRepSeconds: nil),
                        anomalies: anomalies, reason: reason)
    }
}

/// Envuelve un `ReplaySource` declarando otro nivel (para probar la política de niveles).
@MainActor
final class LeveledSource<Sample: Sendable & Codable & TimedSample>: SampleSource {
    let level: SourceLevel
    let inner: ReplaySource<Sample>
    init(level: SourceLevel, samples: [Sample], speed: Double = .infinity) {
        self.level = level
        inner = ReplaySource(samples: samples, speed: speed)
    }
    func start() throws -> AsyncStream<Sample> { try inner.start() }
    func stop() { inner.stop() }
}

/// Fuente que nunca entrega nada ni termina (sensor mudo).
@MainActor
final class SilentSource: SampleSource {
    typealias Sample = Tick
    let level: SourceLevel = .live
    private var continuation: AsyncStream<Tick>.Continuation?
    private(set) var stopped = false
    func start() throws -> AsyncStream<Tick> {
        let (stream, c) = AsyncStream<Tick>.makeStream()
        continuation = c
        return stream
    }
    func stop() {
        stopped = true
        continuation?.finish()
    }
}

/// Muestra sin tiempo propio y su verificador: el runner debe usar su propio reloj.
nonisolated struct Plain: Sendable, Codable, Hashable { var value: Double }

nonisolated struct PlainVerifier: ActivityVerifier {
    typealias Sample = Plain
    var spec: VerificationSpec
    var progress: VerifierProgress
    var times: [Double] = []
    var kind: ActivityKind { spec.kind }
    init(spec: VerificationSpec) { self.spec = spec; progress = VerifierProgress(target: spec.target) }
    mutating func start(at t: Double) { progress.gate = .ready }
    mutating func ingest(_ sample: Plain, at t: Double) -> [VerifierEvent] {
        times.append(t)
        progress.count += 1
        return progress.count >= spec.target ? [.completed] : [.rep(progress.count)]
    }
    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        ActivityOutcome(kind: kind, target: spec.target, achieved: progress.count, completed: reason == .completed,
                        durationSeconds: t, metrics: .none, anomalies: [], reason: reason)
    }
}

/// Fuente que falla al arrancar.
@MainActor
final class FailingSource: SampleSource {
    typealias Sample = Tick
    let level: SourceLevel = .live
    func start() throws -> AsyncStream<Tick> { throw VerificationError.cameraBusy }
    func stop() {}
}

private func spec(_ kind: ActivityKind = .sentadilla, target: Int = 3, maxDuration: Double = 60) -> VerificationSpec {
    VerificationSpec(kind: kind, target: target, minDurationSeconds: 0, maxDurationSeconds: maxDuration, demo: true)
}

private func ticks(_ values: [Double], every dt: Double = 0.5) -> [Tick] {
    values.enumerated().map { Tick(t: Double($0.offset) * dt, value: $0.element) }
}

/// Descenso de la cadera normalizado por la estatura, la señal que usa la sentadilla.
private func hipDescentSignal(_ samples: [PoseSample]) -> [(t: Double, v: Double)] {
    guard let first = samples.first,
          let hip0 = first.joints[.root]?.y, let nose0 = first.joints[.nose]?.y, let ankle0 = first.joints[.leftAnkle]?.y else { return [] }
    let h0 = nose0 - ankle0
    return samples.compactMap { s in
        guard let hip = s.joints[.root]?.y else { return nil }
        return (s.t, (hip0 - hip) / h0)
    }
}

// MARK: - Suite

@Suite(.serialized)
struct RunnerTests {

    // MARK: RepMachine

    @Test func repMachineCuentaConHisteresis() {
        var m = RepMachine(enterThreshold: 0.12, exitThreshold: 0.04, minRepSeconds: 0.6, maxRepSeconds: 6)
        // Sube, se queda entre umbrales (no cuenta), vuelve abajo tras 1 s → 1 rep.
        #expect(m.update(0.00, at: 0.0) == .idle)
        #expect(m.update(0.13, at: 0.5) == .entered(at: 0.5))
        #expect(m.update(0.08, at: 1.0) == .idle)
        #expect(m.update(0.20, at: 1.2) == .idle)
        if case .rep(let count, let seconds, let peak) = m.update(0.03, at: 1.6) {
            #expect(count == 1)
            #expect(abs(seconds - 1.1) < 1e-9)
            #expect(peak == 0.20)
        } else {
            Issue.record("Debía contar una repetición")
        }
        #expect(m.count == 1)
        #expect(m.lastRepAt == 1.6)
        #expect(m.meanRepSeconds.map { abs($0 - 1.1) < 1e-9 } == true)
    }

    @Test func repMachineRechazaCortasLargasYSeguidas() {
        var m = RepMachine(enterThreshold: 0.5, exitThreshold: 0.2, minRepSeconds: 0.5, maxRepSeconds: 2, minRestSeconds: 1)
        _ = m.update(0.6, at: 0)
        #expect(m.update(0.1, at: 0.2) == .rejected(.tooShort, at: 0.2))
        _ = m.update(0.6, at: 1)
        #expect(m.update(0.1, at: 4) == .rejected(.tooLong, at: 4))
        _ = m.update(0.6, at: 5)
        if case .rep(let count, _, _) = m.update(0.1, at: 6) { #expect(count == 1) } else { Issue.record("Debía contar") }
        // Antes del descanso mínimo: se rechaza y sigue en reposo.
        #expect(m.update(0.9, at: 6.5) == .rejected(.tooSoon, at: 6.5))
        #expect(m.phase == .rest)
        #expect(m.rejectedCount == 3)
        _ = m.update(0.9, at: 7.5)
        if case .rep(let count, _, _) = m.update(0.1, at: 8.5) { #expect(count == 2) } else { Issue.record("Debía contar") }
        m.reset()
        #expect(m.count == 0 && m.phase == .rest && m.repSeconds.isEmpty)
    }

    // MARK: Detectores

    @Test func staticDetectorDisparaUnaVezYSeRearma() {
        var d = StaticSignalDetector(windowSeconds: 1, epsilon: 1e-6)
        var fired: [Anomaly] = []
        for i in 0...40 { if let a = d.ingest(0.5, at: Double(i) * 0.1) { fired.append(a) } }
        #expect(fired.count == 1)
        #expect(fired.first?.kind == StaticSignalDetector.anomalyKind)
        #expect(fired.first?.severity == .hard)
        #expect(fired.first.map { $0.at >= 1.0 } == true)
        // Se mueve: se rearma; vuelve a quedarse quieta: dispara de nuevo.
        for i in 41...60 { if let a = d.ingest(Double(i % 2) * 0.3, at: Double(i) * 0.1) { fired.append(a) } }
        #expect(fired.count == 1)
        for i in 61...90 { if let a = d.ingest(0.9, at: Double(i) * 0.1) { fired.append(a) } }
        #expect(fired.count == 2)
    }

    @Test func staticDetectorIgnoraSenalViva() {
        var d = StaticSignalDetector(windowSeconds: 1, epsilon: 1e-6)
        var rng = FixtureRandom(seed: 7)
        for i in 0...100 {
            #expect(d.ingest(0.5 + rng.symmetric(0.01), at: Double(i) * 0.05) == nil)
        }
    }

    @Test func regularityDetectorDistinguePeriodicoDeHumano() {
        var loop = RegularityDetector()
        var fired: Anomaly? = nil
        for i in 1...8 { if let a = loop.recordRep(at: Double(i) * 2.0) { fired = fired ?? a } }
        #expect(fired?.kind == RegularityDetector.anomalyKind)
        #expect(fired?.severity == .hard)
        #expect(fired?.at == 12.0, "Dispara en la sexta rep")

        var human = RegularityDetector()
        var rng = FixtureRandom(seed: 3)
        var t = 0.0
        for _ in 1...12 {
            t += 2.0 * (1 + rng.symmetric(0.2))
            #expect(human.recordRep(at: t) == nil)
        }
        #expect((human.coefficientOfVariation ?? 0) > RegularityDetector.defaultMaxCoefficientOfVariation)
    }

    @Test func trackingDropDetectorDetectaSaltosYRespetaCooldown() {
        var d = TrackingDropDetector()
        #expect(d.ingest(yaw: 0, pitch: 0, roll: 0, at: 0) == nil)
        #expect(d.ingest(yaw: 2, pitch: 1, roll: 0, at: 1 / 60) == nil)
        let jump = d.ingest(yaw: 90, pitch: 1, roll: 0, at: 2 / 60)
        #expect(jump?.kind == TrackingDropDetector.anomalyKind)
        #expect(jump?.severity == .soft)
        // Dentro del cooldown: cuenta pero no emite.
        #expect(d.ingest(yaw: 0, pitch: 1, roll: 0, at: 3 / 60) == nil)
        #expect(d.jumpCount == 2)
        // Envoltura: de 179° a -179° son 2°, no 358°.
        #expect(d.ingest(yaw: 179, pitch: 0, roll: 0, at: 5) == nil)
        #expect(d.ingest(yaw: -179, pitch: 0, roll: 0, at: 5 + 1 / 60) == nil)
        // Tras pérdida de tracking (reset) el primer valor no se compara.
        d.reset()
        #expect(d.ingest(yaw: 100, pitch: 0, roll: 0, at: 6) == nil)
        #expect(AngleMath.delta(-179, 179) == 2)
    }

    @Test func smootherConverge() {
        var s = ExponentialSmoother(alpha: 0.5)
        #expect(s.update(1) == 1)
        #expect(s.update(0) == 0.5)
        #expect(s.update(0) == 0.25)
        s.reset()
        #expect(s.value == nil)
    }

    // MARK: Fixtures sintéticas

    @Test func sentadillasSinteticasCuentanConRepMachine() {
        let samples = FixtureSynth.squats(count: 8)
        var m = RepMachine(enterThreshold: 0.12, exitThreshold: 0.04, minRepSeconds: 0.6, maxRepSeconds: 6)
        var regular = RegularityDetector()
        var regularFired = false
        for (t, v) in hipDescentSignal(samples) {
            if case .rep = m.update(v, at: t) {
                if regular.recordRep(at: t) != nil { regularFired = true }
            }
        }
        #expect(m.count == 8)
        #expect(!regularFired, "Con jitter humano no es demasiado regular")
        #expect((regular.coefficientOfVariation ?? 0) > RegularityDetector.defaultMaxCoefficientOfVariation)
        #expect(m.repSeconds.allSatisfy { $0 > 0.6 && $0 < 2.5 })
        #expect(samples.first?.joints.count == JointKey.allCases.count)
    }

    @Test func sentadillasAMediasNoCuentanYFotoEsEstatica() {
        var m = RepMachine(enterThreshold: 0.12, exitThreshold: 0.04, minRepSeconds: 0.6, maxRepSeconds: 6)
        for (t, v) in hipDescentSignal(FixtureSynth.halfSquats(count: 5)) { m.update(v, at: t) }
        #expect(m.count == 0)

        var d = StaticSignalDetector()
        var fired = 0
        for (t, v) in hipDescentSignal(FixtureSynth.staticPose(seconds: 5)) where d.ingest(v, at: t) != nil { fired += 1 }
        #expect(fired == 1)

        var loopMachine = RepMachine(enterThreshold: 0.12, exitThreshold: 0.04, minRepSeconds: 0.6, maxRepSeconds: 6)
        var loopDetector = RegularityDetector()
        var loopFired = false
        for (t, v) in hipDescentSignal(FixtureSynth.loopedSquats(count: 8)) {
            if case .rep = loopMachine.update(v, at: t), loopDetector.recordRep(at: t) != nil { loopFired = true }
        }
        #expect(loopFired, "Un bucle perfecto dispara tooRegular")
    }

    @Test func parpadeosSinteticos() {
        func completeBlinks(_ samples: [FaceSample]) -> Int {
            var closed = false
            var count = 0
            for s in samples {
                let closure = min(s.blinkL, s.blinkR)
                if !closed, closure >= 0.8 { closed = true }
                if closed, closure <= 0.3 { closed = false; count += 1 }
            }
            return count
        }
        #expect(completeBlinks(FixtureSynth.blinks(count: 15)) == 15)
        #expect(completeBlinks(FixtureSynth.partialBlinks(count: 15)) == 0)
        #expect(completeBlinks(FixtureSynth.winks(count: 15)) == 0)
        #expect(FixtureSynth.blinks(count: 3).allSatisfy { $0.isTracked && $0.shapeEnergy > 0 })
        #expect(FixtureSynth.staticFace(seconds: 2).allSatisfy { $0.shapeEnergy == 0 })
    }

    @Test func cuelloYMiradaSinteticos() {
        let seq = FixtureSynth.neckSequence([.rotateLeft, .rotateRight, .flexion, .tiltLeft])
        #expect((seq.map(\.yaw).max() ?? 0) > 45)
        #expect((seq.map(\.yaw).min() ?? 0) < -45)
        #expect((seq.map(\.pitch).min() ?? 0) < -25)
        #expect((seq.map(\.roll).max() ?? 0) > 20)
        var jumps = TrackingDropDetector()
        var jumpSeen = false
        for s in seq where jumps.ingest(yaw: s.yaw, pitch: s.pitch, roll: s.roll, at: s.t) != nil { jumpSeen = true }
        #expect(!jumpSeen, "Un cuello real no salta")

        var jumpDetector = TrackingDropDetector()
        var seen = 0
        for s in FixtureSynth.faceTrackingJump(seconds: 2, atSecond: 1) where jumpDetector.ingest(yaw: s.yaw, pitch: s.pitch, roll: s.roll, at: s.t) != nil { seen += 1 }
        #expect(seen == 1)

        func angleToCamera(_ s: FaceSample) -> Double {
            let a = s.lookAt / max(1e-6, (s.lookAt * s.lookAt).sum().squareRoot())
            let b = s.cameraInFace / max(1e-6, (s.cameraInFace * s.cameraInFace).sum().squareRoot())
            return Double(acos(max(-1, min(1, (a * b).sum())))) * 180 / .pi
        }
        #expect(FixtureSynth.gaze(seconds: 1, awayDegrees: 0).allSatisfy { angleToCamera($0) < 1 })
        #expect(FixtureSynth.gaze(seconds: 1, awayDegrees: 20).allSatisfy { abs(angleToCamera($0) - 20) < 1 })
    }

    @Test func pasosSinteticos() {
        func summary(_ samples: [StepSample]) -> (steps: Int, rms: Double, walking: Bool) {
            var steps = 0
            var sumSq = 0.0
            var n = 0
            var walking = 0
            var activities = 0
            for s in samples {
                switch s {
                case .pedometer(let p): steps = max(steps, p.steps)
                case .motion(let m):
                    sumSq += (m.userAccel * m.userAccel).sum()
                    n += 1
                case .activity(let a):
                    activities += 1
                    if a.walking { walking += 1 }
                }
            }
            return (steps, n > 0 ? (sumSq / Double(n)).squareRoot() : 0, activities > 0 && walking == activities)
        }
        let walk = summary(FixtureSynth.walk(steps: 250))
        #expect(abs(walk.steps - 250) <= 2)
        #expect(walk.rms > 0.1 && walk.rms < 0.7)
        #expect(walk.walking)
        let shake = summary(FixtureSynth.shake(seconds: 20))
        #expect(shake.rms > 0.7)
        #expect(!shake.walking)
        #expect(shake.steps > 30)
        let still = summary(FixtureSynth.stationary(seconds: 20))
        #expect(still.steps == 0 && !still.walking && still.rms < 0.1)
        let ts = FixtureSynth.walk(steps: 50).map(\.t)
        #expect(ts == ts.sorted())
    }

    @Test func fixtureJSONIdaYVuelta() throws {
        let fixture = Fixture(name: "sentadillas-5", samples: FixtureSynth.squats(count: 5))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("activate-fixtures-\(UUID().uuidString)")
        let url = try fixture.write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(url.lastPathComponent == "sentadillas-5.json")
        let loaded = try Fixture<PoseSample>.load(url: url)
        #expect(loaded == fixture)

        let faces = Fixture(name: "parpadeos", samples: FixtureSynth.blinks(count: 3))
        let round = try Fixture<FaceSample>.decode(faces.jsonData())
        #expect(round.samples.count == faces.samples.count)
        #expect(round.samples.first?.cameraInFace == faces.samples.first?.cameraInFace)

        let steps = Fixture(name: "marcha", samples: FixtureSynth.walk(steps: 10))
        let decodedSteps = try Fixture<StepSample>.decode(steps.jsonData())
        #expect(decodedSteps == steps)

        #expect(throws: FixtureError.notFound("no-existe")) {
            try Fixture<PoseSample>.load("no-existe", bundle: Bundle.main)
        }
    }

    // MARK: ReplaySource

    @Test func replaySourceRespetaTiemposYVelocidad() async throws {
        let samples = ticks([1, 1, 1, 1], every: 0.1)
        let slow = ReplaySource(samples: samples, speed: 1)
        let clock = ContinuousClock()
        let t0 = clock.now
        var received = 0
        for await _ in try slow.start() { received += 1 }
        let elapsed = t0.duration(to: clock.now)
        #expect(received == 4)
        #expect(elapsed >= .milliseconds(290))
        #expect(slow.level == .replay)

        let fast = ReplaySource(samples: ticks(Array(repeating: 1, count: 200), every: 1), speed: .infinity)
        let t1 = clock.now
        var fastCount = 0
        for await _ in try fast.start() { fastCount += 1 }
        #expect(fastCount == 200)
        #expect(t1.duration(to: clock.now) < .seconds(2))

        let tenX = ReplaySource(samples: ticks([1, 1, 1], every: 1), speed: 10)
        let t2 = clock.now
        var tenCount = 0
        for await _ in try tenX.start() { tenCount += 1 }
        let tenElapsed = t2.duration(to: clock.now)
        #expect(tenCount == 3)
        #expect(tenElapsed >= .milliseconds(190) && tenElapsed < .seconds(1.5))
    }

    @Test func replaySourceStopCortaElStream() async throws {
        let source = ReplaySource(samples: ticks(Array(repeating: 1, count: 50), every: 0.2), speed: 1)
        let stream = try source.start()
        var received = 0
        for await _ in stream {
            received += 1
            if received == 2 { source.stop() }
        }
        #expect(received <= 3)
        #expect(source.stopCount == 1)
        #expect(!source.isPlaying)
    }

    // MARK: ActivityRunner

    @Test func runnerCompletaConReplayYQuedaSimulado() async throws {
        let assignment = ActivityAssignment(kind: .sentadilla, target: 3)
        let source = ReplaySource(samples: ticks([0, 1, 0, 1, 0, 1, 1, 1]), speed: .infinity)
        let runner = ActivityRunner(assignment: assignment, verifier: CountingVerifier(spec: spec(target: 3)), source: source)
        var seen: [VerifierEvent] = []
        runner.onEvent = { seen.append($0) }
        #expect(runner.progress.gate == .calibrating)

        runner.start()
        #expect(runner.isRunning)
        #expect(runner.progress.gate == .ready)
        await runner.waitUntilFinished()

        #expect(!runner.isRunning)
        #expect(runner.outcome?.completed == true)
        #expect(runner.outcome?.reason == .completed)
        #expect(runner.outcome?.achieved == 3)
        #expect(runner.progress.count == 3)
        #expect(runner.level == .simulated)
        #expect(runner.result?.level == .simulated)
        #expect(runner.result?.skipped == false)
        #expect(runner.result?.kind == .sentadilla)
        #expect(runner.lastRepAt == 2.5, "La tercera rep está en t = 5 × 0,5")
        #expect(runner.cue?.text == "Siga así")
        #expect(runner.timedFraction == 1)
        #expect(runner.sampleCount == 6, "Tras completar no se ingieren más muestras")
        #expect(seen.contains(.completed))
        #expect(seen.filter { if case .rep = $0 { true } else { false } }.count == 3)
        #expect(source.stopCount == 1)
        #expect(runner.progress.elapsed >= 2.5)
        // Un runner se usa una sola vez.
        runner.start()
        #expect(!runner.isRunning)
    }

    @Test func runnerStopDelUsuarioEntregaParcial() async throws {
        let assignment = ActivityAssignment(kind: .cuello, target: 10)
        let source = ReplaySource(samples: ticks(Array(repeating: 1, count: 100), every: 0.1), speed: 1)
        let runner = ActivityRunner(assignment: assignment, verifier: CountingVerifier(spec: spec(.cuello, target: 10)), source: source)
        runner.start()
        try await Task.sleep(for: .milliseconds(250))
        runner.stop(reason: .userStopped)
        #expect(runner.outcome?.reason == .userStopped)
        #expect(runner.outcome?.completed == false)
        #expect((runner.outcome?.achieved ?? 0) >= 1)
        #expect((runner.outcome?.achieved ?? 100) < 10)
        #expect(!runner.isRunning)
        #expect(source.stopCount == 1)
        #expect(runner.result?.completed == false)
        // Lo que llegue después no cambia nada.
        try await Task.sleep(for: .milliseconds(200))
        #expect(runner.outcome?.reason == .userStopped)
        await runner.waitUntilFinished()
    }

    @Test func runnerTimeoutPorTiempoDeMuestra() async {
        let assignment = ActivityAssignment(kind: .ojos, target: 50)
        let samples = ticks(Array(repeating: 1, count: 20), every: 0.5)  // t hasta 9,5 s
        let source = ReplaySource(samples: samples, speed: .infinity)
        let runner = ActivityRunner(assignment: assignment, verifier: CountingVerifier(spec: spec(.ojos, target: 50, maxDuration: 3)), source: source)
        runner.start()
        await runner.waitUntilFinished()
        #expect(runner.outcome?.reason == .timeout)
        #expect(runner.outcome?.achieved == 7, "Muestras con t = 0 … 3,0 incluidas")
        #expect(runner.cue?.text == "Se acabó el tiempo.")
        #expect(runner.level == .simulated)
    }

    @Test func runnerTimeoutPorRelojConFuenteMuda() async {
        let assignment = ActivityAssignment(kind: .pasos, target: 30)
        let source = SilentSource()
        let runner = ActivityRunner(assignment: assignment, verifier: CountingVerifier(spec: spec(.pasos, target: 30, maxDuration: 0.4)), source: source)
        let clock = ContinuousClock()
        let t0 = clock.now
        runner.start()
        await runner.waitUntilFinished()
        #expect(t0.duration(to: clock.now) >= .milliseconds(380))
        #expect(runner.outcome?.reason == .timeout)
        #expect(runner.outcome?.achieved == 0)
        #expect((runner.outcome?.durationSeconds ?? 0) >= 0.38)
        #expect(source.stopped)
        #expect(runner.elapsedSeconds >= 0.38)
    }

    @Test func runnerFuenteAgotadaTerminaComoTimeout() async {
        let assignment = ActivityAssignment(kind: .sentadilla, target: 10)
        let source = ReplaySource(samples: ticks([1, 1, 1]), speed: .infinity)
        let runner = ActivityRunner(assignment: assignment, verifier: CountingVerifier(spec: spec(target: 10)), source: source)
        runner.start()
        await runner.waitUntilFinished()
        #expect(runner.outcome?.reason == .timeout)
        #expect(runner.outcome?.achieved == 3)
        #expect(runner.outcome?.completed == false)
    }

    @Test func runnerNivelesSegunFuenteYAnomalias() async {
        func run(kind: ActivityKind, level: SourceLevel, values: [Double]) async -> VerificationLevel? {
            let assignment = ActivityAssignment(kind: kind, target: 2)
            let source = LeveledSource(level: level, samples: ticks(values))
            let runner = ActivityRunner(assignment: assignment, verifier: CountingVerifier(spec: spec(kind, target: 2)), source: source)
            runner.start()
            await runner.waitUntilFinished()
            return runner.level
        }
        let full = await run(kind: .sentadilla, level: .live, values: [1, 1])
        #expect(full == .full)
        let suspicious = await run(kind: .sentadilla, level: .live, values: [1, -1, 1])
        #expect(suspicious == .suspicious)
        let fallback = await run(kind: .sentadilla, level: .fallback, values: [1, 1])
        #expect(fallback == .reduced)
        let weak = await run(kind: .respiracion, level: .live, values: [1, 1])
        #expect(weak == .reduced)
        let replay = await run(kind: .sentadilla, level: .replay, values: [1, 1])
        #expect(replay == .simulated)
    }

    @Test func runnerFuenteQueFallaBloqueaYPermiteSaltar() async {
        let assignment = ActivityAssignment(kind: .sentadilla, target: 5)
        let runner = ActivityRunner(assignment: assignment, verifier: CountingVerifier(spec: spec(target: 5)), source: FailingSource())
        runner.start()
        #expect(!runner.isRunning)
        let busy: Bool = { if case .cameraBusy? = runner.startError { return true }; return false }()
        #expect(busy)
        #expect(runner.progress.gate == .blocked(reason: "Cámara ocupada"))
        #expect(runner.outcome == nil)
        runner.stop(reason: .skipped)
        #expect(runner.outcome?.reason == .skipped)
        #expect(runner.result?.skipped == true)
        #expect(runner.result?.completed == false)
    }

    @Test func runnerStopAntesDeStartEsSaltada() {
        let assignment = ActivityAssignment(kind: .stroop, target: 20)
        let runner = ActivityRunner(assignment: assignment, verifier: CountingVerifier(spec: spec(.stroop, target: 20)), source: SilentSource())
        runner.stop(reason: .skipped)
        #expect(runner.outcome?.reason == .skipped)
        #expect(runner.outcome?.achieved == 0)
        #expect(runner.result?.skipped == true)
        #expect(runner.level == .full, "Sin anomalías y fuente live: la política dice full; `skipped` lo excluye de la sesión")
        #expect(VerificationPolicy.counts([runner.result!]) == false)
    }

    @Test func runnerUsaRelojCuandoLaMuestraNoTraeTiempo() async {
        let source = ReplaySource(samples: [Plain(value: 1), Plain(value: 1)], speed: 1, timeOf: { _ in 0.15 })
        let runner = ActivityRunner(assignment: ActivityAssignment(kind: .respiracion, target: 2), verifier: PlainVerifier(spec: spec(.respiracion, target: 2)), source: source)
        runner.start()
        await runner.waitUntilFinished()
        #expect(runner.outcome?.completed == true)
        #expect((runner.outcome?.durationSeconds ?? 0) >= 0.14, "Sin TimedSample el `at:` sale del ContinuousClock del runner")
        #expect(runner.level == .simulated)
    }

    // MARK: Factory

    @Test func factoryDevuelvePlaceholderYRespetaRegistro() async {
        let assignment = ActivityAssignment(kind: .cuello, target: 6)
        ActivityRunnerFactory.unregisterAll()
        let fallback = ActivityRunnerFactory.make(assignment: assignment, demo: true)
        #expect(fallback is PlaceholderRunner)
        #expect(fallback.progress.gate == .blocked(reason: "Sin verificador"))

        ActivityRunnerFactory.register(.cuello) { assignment, _, _ in
            ActivityRunnerFactory.replayRunner(assignment: assignment,
                                               verifier: CountingVerifier(spec: spec(.cuello, target: assignment.target)),
                                               samples: ticks(Array(repeating: 1, count: assignment.target)),
                                               speed: .infinity)
        }
        defer { ActivityRunnerFactory.unregisterAll() }
        let runner = ActivityRunnerFactory.make(assignment: assignment, demo: true, replay: true)
        #expect(!(runner is PlaceholderRunner))
        runner.start()
        while runner.outcome == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(runner.outcome?.completed == true)
        #expect(runner.level == .simulated)
    }
}
