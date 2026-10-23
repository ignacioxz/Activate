import Testing
import Foundation
import simd
@testable import Activate

/// Muestras sintéticas de cara para `EyeRestVerifier` (30 fps) y `NeckVerifier` (60 fps, como ARKit).
struct FaceVerifierTests {
    private static let fps: Double = 30
    private static let dt = 1 / fps

    private func face(t: Double, yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
                      blinkL: Float = 0, blinkR: Float = 0,
                      tracked: Bool = true, energy: Float = 0.05) -> FaceSample {
        FaceSample(t: t, isTracked: tracked, yaw: yaw, pitch: pitch, roll: roll,
                   position: SIMD3(0, 0, -0.4), cameraInFace: SIMD3(0, 0, 0.4), lookAt: SIMD3(0, 0, 0.4),
                   blinkL: blinkL, blinkR: blinkR, shapeEnergy: energy)
    }

    /// Alimenta `seconds` de muestras producidas por `make(t)` y devuelve los eventos.
    @discardableResult
    private func feed<V: ActivityVerifier>(_ v: inout V, _ t: inout Double, seconds: Double, fps: Double = Self.fps,
                                           _ make: (Double) -> FaceSample) -> [VerifierEvent] where V.Sample == FaceSample {
        var events: [VerifierEvent] = []
        let frames = Int((seconds * fps).rounded())
        for _ in 0..<frames {
            t += 1 / fps
            events += v.ingest(make(t), at: t)
        }
        return events
    }

    private func hasAnomaly(_ events: [VerifierEvent], kind: String, severity: Anomaly.Severity? = nil) -> Bool {
        events.contains {
            if case .anomaly(let a) = $0 { return a.kind == kind && (severity == nil || a.severity == severity) }
            return false
        }
    }

    private func anomalies(_ events: [VerifierEvent], kind: String) -> [Anomaly] {
        events.compactMap {
            if case .anomaly(let a) = $0, a.kind == kind { return a }
            return nil
        }
    }

    // MARK: - Ojos (solo parpadeo completo)

    private func eyes() -> (EyeRestVerifier, Double) {
        var v = EyeRestVerifier(spec: .standard(for: .ojos, demo: true))
        v.start(at: 0)
        return (v, 0)
    }

    /// Un cierre de `closeSeconds` con los coeficientes dados, precedido y seguido de ojos abiertos.
    @discardableResult
    private func closure(_ v: inout EyeRestVerifier, _ t: inout Double, left: Float, right: Float,
                         closeSeconds: Double) -> [VerifierEvent] {
        var events = feed(&v, &t, seconds: 0.4) { face(t: $0) }
        events += feed(&v, &t, seconds: closeSeconds) { face(t: $0, blinkL: left, blinkR: right) }
        events += feed(&v, &t, seconds: 0.4) { face(t: $0) }
        return events
    }

    @Test func guinoNoCuenta() {
        var (v, t) = eyes()
        closure(&v, &t, left: 1, right: 0, closeSeconds: 0.15)
        closure(&v, &t, left: 0, right: 0.95, closeSeconds: 0.15)
        #expect(v.completeBlinks == 0)
        #expect(v.partialBlinks == 0)
        #expect(v.progress.count == 0)
    }

    @Test func cierreLargoNoCuenta() {
        var (v, t) = eyes()
        let events = closure(&v, &t, left: 1, right: 1, closeSeconds: 0.9)
        #expect(v.completeBlinks == 0)
        #expect(!events.contains(.rep(1)))
    }

    @Test func parpadeoParcialCuentaAparte() {
        var (v, t) = eyes()
        closure(&v, &t, left: 0.6, right: 0.65, closeSeconds: 0.15)
        #expect(v.completeBlinks == 0)
        #expect(v.partialBlinks == 1)
    }

    @Test func antesDeLaMetaNoTermina() {
        var (v, t) = eyes()
        var events: [VerifierEvent] = []
        for _ in 0..<(v.spec.target - 1) {
            events += closure(&v, &t, left: 0.95, right: 0.9, closeSeconds: 0.15)
        }
        #expect(v.completeBlinks == v.spec.target - 1)
        #expect(!events.contains(.completed))
        #expect(!v.isCompleted)
    }

    @Test func metaDeParpadeosCompletaLaActividadSinMirarLejos() {
        var (v, t) = eyes()
        var events: [VerifierEvent] = []
        for _ in 0..<8 {
            events += closure(&v, &t, left: 0.95, right: 0.9, closeSeconds: 0.15)
        }
        #expect(v.completeBlinks == 8)
        #expect(events.contains(.rep(8)))
        #expect(events.contains(.cue(EyeRestVerifier.cueBlink)))
        #expect(events.contains(.completed))
        #expect(events.contains(.progress(1)))
        #expect(v.isCompleted && v.phase == .done)
        // Una sola consigna (pestañear): no hay fase de mirar lejos.
        let cues = events.filter { if case .cue = $0 { return true } else { return false } }
        #expect(cues == [.cue(EyeRestVerifier.cueBlink)])
        let outcome = v.finish(at: t, reason: .completed)
        #expect(outcome.completed)
        #expect(outcome.achieved == 8)
        if case .eyes(let complete, _, let bpm, let far) = outcome.metrics {
            #expect(complete == 8)
            #expect(bpm > 0)
            #expect(far == 0)
        } else {
            Issue.record("métricas de ojos esperadas")
        }
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .ojos) == .full)
    }

    @Test func ojosCaraPerdidaBloquea() {
        var (v, t) = eyes()
        feed(&v, &t, seconds: 0.5) { face(t: $0) }
        let events = feed(&v, &t, seconds: 2.5) { face(t: $0, tracked: false) }
        #expect(events.contains(.gate(.blocked(reason: EyeRestVerifier.blockedReason))))
        let back = feed(&v, &t, seconds: 0.2) { face(t: $0) }
        #expect(back.contains(.gate(.ready)))
    }

    // MARK: - Cuello: generador de muestras

    private static let neckFPS: Double = 60
    typealias Triple = (yaw: Double, pitch: Double, roll: Double)

    /// Opciones del "dispositivo" y de la persona para las muestras sintéticas.
    private struct Head {
        /// Postura neutra absoluta (p. ej. cabeza gacha mirando el teléfono).
        var neutral: Triple = (0, 0, 0)
        /// Deriva lenta de la postura (°/s por eje).
        var drift: Triple = (0, 0, 0)
        /// Ruido uniforme ± por eje en cada muestra.
        var jitter: Double = 0
        /// Dispositivo que invierte el signo del yaw.
        var invertYaw = false
        var rng = FaceChallengeRNG(seed: 11)
    }

    /// Muestra con la cabeza en `move` (relativo al neutro, en el sistema de la cabeza) en el instante `t`.
    private func neckSample(_ head: inout Head, t: Double, move: Triple = (0, 0, 0)) -> FaceSample {
        let base = (yaw: head.neutral.yaw + head.drift.yaw * t,
                    pitch: head.neutral.pitch + head.drift.pitch * t,
                    roll: head.neutral.roll + head.drift.roll * t)
        let m = HeadPose.matrix(yaw: base.yaw, pitch: base.pitch, roll: base.roll)
            * HeadPose.matrix(yaw: move.yaw, pitch: move.pitch, roll: move.roll)
        var a = HeadPose.angles(from: m)
        if head.jitter > 0 {
            a.yaw += Double.random(in: -head.jitter...head.jitter, using: &head.rng)
            a.pitch += Double.random(in: -head.jitter...head.jitter, using: &head.rng)
            a.roll += Double.random(in: -head.jitter...head.jitter, using: &head.rng)
        }
        if head.invertYaw { a.yaw = -a.yaw }
        return face(t: t, yaw: a.yaw, pitch: a.pitch, roll: a.roll)
    }

    @discardableResult
    private func hold(_ v: inout NeckVerifier, _ t: inout Double, _ head: inout Head, seconds: Double,
                      move: (Double) -> Triple = { _ in (0, 0, 0) }) -> [VerifierEvent] {
        feed(&v, &t, seconds: seconds, fps: Self.neckFPS) { tt in neckSample(&head, t: tt, move: move(tt)) }
    }

    /// Movimiento humano: ida lenta (0,6 s), pausa (0,3 s), vuelta (0,6 s) y descanso (0,6 s).
    @discardableResult
    private func humanMove(_ v: inout NeckVerifier, _ t: inout Double, _ head: inout Head,
                           _ direction: NeckVerifier.Direction, magnitude: Double) -> [VerifierEvent] {
        let start = t
        let up = 0.6, plateau = 0.3, down = 0.6, rest = 0.6
        return hold(&v, &t, &head, seconds: up + plateau + down + rest) { tt in
            let local = tt - start
            let amount: Double
            if local < up { amount = (1 - cos(.pi * local / up)) / 2 }
            else if local < up + plateau { amount = 1 }
            else if local < up + plateau + down { amount = (1 + cos(.pi * (local - up - plateau) / down)) / 2 }
            else { amount = 0 }
            return direction.pose(magnitude * amount)
        }
    }

    /// Cara quieta hasta que haya una consigna vigente (o hasta `maxSeconds`).
    @discardableResult
    private func waitForCue(_ v: inout NeckVerifier, _ t: inout Double, _ head: inout Head,
                            maxSeconds: Double = 3) -> [VerifierEvent] {
        var events: [VerifierEvent] = []
        let frames = Int(maxSeconds * Self.neckFPS)
        for _ in 0..<frames where v.currentCue == nil && !v.isCompleted {
            t += 1 / Self.neckFPS
            events += v.ingest(neckSample(&head, t: t), at: t)
        }
        return events
    }

    private func neck(seed: UInt64 = 7) -> (NeckVerifier, Double, Head) {
        var v = NeckVerifier(spec: .standard(for: .cuello, demo: true), seed: seed)
        v.start(at: 0)
        return (v, 0, Head())
    }

    /// Primera semilla cuya primera consigna es del eje pedido.
    private func seed(firstAxis axis: NeckVerifier.Axis) -> UInt64 {
        (1...500).first { NeckVerifier(spec: .standard(for: .cuello, demo: true), seed: UInt64($0)).plan[0].axis == axis }
            .map(UInt64.init) ?? 1
    }

    /// Una dirección de otro eje (para provocar un desajuste).
    private func otherAxisDirection(_ d: NeckVerifier.Direction) -> NeckVerifier.Direction {
        switch d.axis {
        case .rotation: .tiltRight
        case .flexion: .left
        case .tilt: .up
        }
    }

    /// Recorre todas las consignas con movimientos de `margin` grados sobre el umbral.
    private func completeAll(_ v: inout NeckVerifier, _ t: inout Double, _ head: inout Head,
                             margin: Double = 8) throws -> [VerifierEvent] {
        var all: [VerifierEvent] = []
        var guardCount = 0
        while !v.isCompleted, guardCount < v.spec.target * 3 {
            guardCount += 1
            all += waitForCue(&v, &t, &head)
            let cue = try #require(v.currentCue, "sin consigna tras \(v.progress.count) reps")
            all += humanMove(&v, &t, &head, cue, magnitude: cue.threshold + margin)
        }
        return all
    }

    // MARK: - Cuello: calibración y consignas

    @Test func planRepartidoYReproducible() {
        let a = NeckVerifier(spec: .standard(for: .cuello), seed: 99)
        let b = NeckVerifier(spec: .standard(for: .cuello), seed: 99)
        #expect(a.plan == b.plan)
        #expect(a.plan.count == 15)
        let rot = a.plan.filter { $0.axis == .rotation }.count
        let flex = a.plan.filter { $0.axis == .flexion }.count
        let tilt = a.plan.filter { $0.axis == .tilt }.count
        #expect(rot == 5 && flex == 5 && tilt == 5)
        #expect(NeckVerifier(spec: .standard(for: .cuello), seed: 100).plan != a.plan)
    }

    @Test func calibraConCabezaQuietaYEmiteLaPrimeraConsignaAlTiro() throws {
        var (v, t, head) = neck()
        #expect(v.progress.hint == NeckVerifier.hintCalibrating)
        let events = waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        #expect(cue == v.plan[0])
        #expect(events.contains(.gate(.ready)))
        #expect(events.contains(.cue(cue.cue)))
        // 0,8 s quieto (más la ventana de velocidad) y la consigna sale de inmediato, sin retardo aleatorio.
        #expect(t >= NeckVerifier.calibrationStableSeconds)
        #expect(t <= NeckVerifier.calibrationStableSeconds + 0.4)
        #expect(v.progress.live == 0)
    }

    @Test func calibracionNoOcurreMientrasSeMueve() throws {
        var (v, t, head) = neck()
        // Se acomoda: va y viene ±15° de giro (hasta ~47°/s) durante 4 s.
        let moving = hold(&v, &t, &head, seconds: 4) { tt in (15 * sin(.pi * tt), 0, 0) }
        #expect(!moving.contains(.gate(.ready)))
        #expect(!v.isCalibrated)
        #expect(v.currentCue == nil)
        #expect(v.progress.gate == .calibrating)
        #expect(v.progress.hint == NeckVerifier.hintCalibrating)
        // Se queda quieto en cualquier postura: calibra y recibe la consigna.
        let still = hold(&v, &t, &head, seconds: 1.2) { _ in (8, -5, 0) }
        #expect(still.contains(.gate(.ready)))
        #expect(v.currentCue != nil)
        #expect(abs(wrappedDegrees(v.neutral.yaw - 8)) < 1.5)
    }

    @Test func moverseDuranteLaEsperaIgualRecibeConsignaYCuenta() throws {
        var (v, t, head) = neck(seed: seed(firstAxis: .rotation))
        // Movimiento inquieto al principio: no bloquea, solo atrasa la calibración.
        hold(&v, &t, &head, seconds: 1.5) { tt in (0, 12 * sin(2 * .pi * tt), 6 * sin(3 * tt)) }
        waitForCue(&v, &t, &head)
        let first = try #require(v.currentCue)
        let start = t
        var events = hold(&v, &t, &head, seconds: 0.9) { tt in first.pose(34 * min(1, (tt - start) / 0.6)) }
        #expect(events.contains(.rep(1)))
        // Vuelve y, mientras espera, sigue moviendo los otros ejes (±6°): igual llega la consigna.
        let back = t
        events = hold(&v, &t, &head, seconds: 1.4) { tt in
            let f = min(1, (tt - back) / 0.6)
            var p = first.pose(34 * (1 - f))
            p.pitch += 6 * f * sin(5 * tt)
            p.roll += 6 * f * cos(4 * tt)
            return p
        }
        #expect(events.contains { if case .cue(let c) = $0 { return c != NeckVerifier.cueReturn } else { return false } })
        let second = try #require(v.currentCue, "la consigna debe llegar aunque se mueva")
        events += hold(&v, &t, &head, seconds: 0.4) // se aquieta antes del siguiente movimiento
        events += humanMove(&v, &t, &head, second, magnitude: second.threshold + 6)
        #expect(events.contains(.rep(2)))
        #expect(!hasAnomaly(events, kind: NeckVerifier.anomalyCueMismatch))
    }

    @Test func giroDe30CuentaY15No() throws {
        var (v, t, head) = neck(seed: seed(firstAxis: .rotation))
        waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        #expect(cue.axis == .rotation)
        // 15°: la barra avanza a la mitad pero no cuenta.
        var events = humanMove(&v, &t, &head, cue, magnitude: 15)
        #expect(!events.contains(.rep(1)))
        #expect(v.currentCue == cue)
        #expect(!hasAnomaly(events, kind: NeckVerifier.anomalyCueMismatch))
        #expect(!hasAnomaly(events, kind: NeckVerifier.anomalyAxisFlipped))
        // 30°: cuenta y pide volver al centro.
        let start = t
        events = hold(&v, &t, &head, seconds: 0.9) { tt in cue.pose(30 * min(1, (tt - start) / 0.6)) }
        #expect(events.contains(.rep(1)))
        #expect(events.contains(.cue(NeckVerifier.cueReturn)))
        #expect(v.progress.hint == NeckVerifier.hintReturn)
        #expect(v.currentCue == nil)
    }

    @Test func barraEnVivoYTextoDeDepuracion() throws {
        var (v, t, head) = neck(seed: seed(firstAxis: .rotation))
        waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        let start = t
        hold(&v, &t, &head, seconds: 0.8) { tt in cue.pose(14 * min(1, (tt - start) / 0.4)) }
        let live = try #require(v.progress.live)
        #expect(abs(live - 14 / NeckVerifier.turnThreshold) < 0.05)
        let debug = try #require(v.progress.debug)
        #expect(debug.contains("giro") && debug.contains("arriba") && debug.contains("incl"))
        // El lado contrario no llena la barra.
        let turn = t
        hold(&v, &t, &head, seconds: 0.9) { tt in
            let f = min(1, (tt - turn) / 0.5)
            return cue.pose(14 * (1 - f) - 10 * f)
        }
        #expect(v.progress.live == 0)
    }

    @Test func vueltaAlCentroSoloEnElEjeDeLaConsigna() throws {
        var (v, t, head) = neck(seed: seed(firstAxis: .rotation))
        waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        let start = t
        hold(&v, &t, &head, seconds: 0.9) { tt in cue.pose(34 * min(1, (tt - start) / 0.6)) }
        #expect(v.progress.count == 1)
        // Vuelve en el giro pero queda con 8° de flexión y 10° de inclinación: no exige los tres ejes.
        let back = t
        let events = hold(&v, &t, &head, seconds: 1.4) { tt in
            let f = min(1, (tt - back) / 0.6)
            var p = cue.pose(34 * (1 - f))
            p.pitch += 8 * f
            p.roll += 10 * f
            return p
        }
        #expect(v.currentCue != nil)
        #expect(events.contains { if case .cue(let c) = $0 { return c != NeckVerifier.cueReturn } else { return false } })
    }

    @Test func siQuedaCasiEnElCentroSeAceptaYSeRecentra() throws {
        var (v, t, head) = neck(seed: seed(firstAxis: .tilt))
        waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        #expect(cue.axis == .tilt)
        let start = t
        hold(&v, &t, &head, seconds: 0.9) { tt in cue.pose(22 * min(1, (tt - start) / 0.6)) }
        #expect(v.progress.count == 1)
        // Vuelve pero se queda con 8° de inclinación (57 % del umbral): no queda atrapado.
        let back = t
        hold(&v, &t, &head, seconds: 0.6) { tt in cue.pose(22 - 14 * min(1, (tt - back) / 0.5)) }
        #expect(v.currentCue == nil)
        let events = hold(&v, &t, &head, seconds: NeckVerifier.returnSettleSeconds + 0.8) { _ in cue.pose(8) }
        #expect(events.contains { if case .cue(let c) = $0 { return c != NeckVerifier.cueReturn } else { return false } })
        #expect(v.currentCue != nil)
    }

    @Test func movimientoEnOtroEjeNoCuentaPeroNoBloquea() throws {
        var (v, t, head) = neck(seed: seed(firstAxis: .rotation))
        waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        let wrong = otherAxisDirection(cue)
        var events = humanMove(&v, &t, &head, wrong, magnitude: wrong.threshold + 8)
        #expect(hasAnomaly(events, kind: NeckVerifier.anomalyCueMismatch, severity: .soft))
        #expect(anomalies(events, kind: NeckVerifier.anomalyCueMismatch).count == 1)
        #expect(!events.contains(.rep(1)))
        // La consigna sigue vigente y el movimiento correcto cuenta sin esperar otra.
        #expect(v.currentCue == cue)
        events = humanMove(&v, &t, &head, cue, magnitude: cue.threshold + 6)
        #expect(events.contains(.rep(1)))
        let outcome = v.finish(at: t, reason: .userStopped)
        #expect(!outcome.anomalies.contains { $0.severity == .hard })
    }

    @Test func desajusteDuroSoloConCincoYNingunAcierto() throws {
        var (v, t, head) = neck(seed: seed(firstAxis: .rotation))
        waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        let wrong = otherAxisDirection(cue)
        var events: [VerifierEvent] = []
        for _ in 0..<4 { events += humanMove(&v, &t, &head, wrong, magnitude: wrong.threshold + 8) }
        #expect(anomalies(events, kind: NeckVerifier.anomalyCueMismatch).count == 4)
        #expect(!hasAnomaly(events, kind: NeckVerifier.anomalyCueMismatch, severity: .hard))
        events += humanMove(&v, &t, &head, wrong, magnitude: wrong.threshold + 8)
        #expect(hasAnomaly(events, kind: NeckVerifier.anomalyCueMismatch, severity: .hard))
        let outcome = v.finish(at: t, reason: .userStopped)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .cuello) == .suspicious)

        // Con un acierto antes, cinco desajustes siguen siendo soft.
        var (w, t2, head2) = neck(seed: seed(firstAxis: .rotation))
        waitForCue(&w, &t2, &head2)
        let c = try #require(w.currentCue)
        humanMove(&w, &t2, &head2, c, magnitude: c.threshold + 6)
        waitForCue(&w, &t2, &head2)
        let next = try #require(w.currentCue)
        let other = otherAxisDirection(next)
        var more: [VerifierEvent] = []
        for _ in 0..<5 { more += humanMove(&w, &t2, &head2, other, magnitude: other.threshold + 8) }
        #expect(anomalies(more, kind: NeckVerifier.anomalyCueMismatch).count == 5)
        #expect(!hasAnomaly(more, kind: NeckVerifier.anomalyCueMismatch, severity: .hard))
    }

    @Test func signoInvertidoEnUnEjeSeAutocorrigeTrasDosIntentos() throws {
        var (v, t, head) = neck(seed: seed(firstAxis: .rotation))
        head.invertYaw = true
        waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        // Primer intento correcto en el cuerpo, invertido en el sensor: no cuenta, pide volver y repite la consigna.
        var events = humanMove(&v, &t, &head, cue, magnitude: cue.threshold + 6)
        #expect(!events.contains(.rep(1)))
        #expect(events.contains(.cue(NeckVerifier.cueReturn)))
        #expect(!hasAnomaly(events, kind: NeckVerifier.anomalyCueMismatch))
        waitForCue(&v, &t, &head)
        #expect(v.currentCue == cue)
        // Segundo intento igual: se invierte el eje y cuenta.
        events = humanMove(&v, &t, &head, cue, magnitude: cue.threshold + 6)
        #expect(events.contains(.rep(1)))
        #expect(hasAnomaly(events, kind: NeckVerifier.anomalyAxisFlipped, severity: .soft))
        #expect(v.axisSigns.yaw == -1 && v.axisSigns.pitch == 1 && v.axisSigns.roll == 1)
        #expect(v.progress.debug?.contains("inv giro") == true)
        // El resto de la secuencia (con el mismo sensor invertido) cuenta al primer intento.
        events = try completeAll(&v, &t, &head)
        #expect(v.isCompleted)
        #expect(!hasAnomaly(events, kind: NeckVerifier.anomalyAxisFlipped))
        let outcome = v.finish(at: t, reason: .completed)
        #expect(outcome.achieved == v.spec.target)
        #expect(outcome.anomalies.filter { $0.kind == NeckVerifier.anomalyAxisFlipped }.count == 1)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .cuello) == .full)
    }

    @Test func unSoloIntentoAlReversNoInvierte() throws {
        var (v, t, head) = neck(seed: seed(firstAxis: .rotation))
        waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        humanMove(&v, &t, &head, cue.opposite, magnitude: cue.threshold + 6)
        waitForCue(&v, &t, &head)
        #expect(v.currentCue == cue)
        let events = humanMove(&v, &t, &head, cue, magnitude: cue.threshold + 6)
        #expect(events.contains(.rep(1)))
        #expect(v.axisSigns.yaw == 1)
        #expect(!hasAnomaly(events, kind: NeckVerifier.anomalyAxisFlipped))
    }

    @Test func saltoEntreFramesSeDescarta() throws {
        var (v, t, head) = neck()
        waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        // 0 → 60° en un frame (3 600 °/s), meseta y vuelta también brusca.
        var events = hold(&v, &t, &head, seconds: 0.3) { _ in cue.pose(60) }
        events += hold(&v, &t, &head, seconds: 0.5)
        #expect(hasAnomaly(events, kind: NeckVerifier.anomalyTrackingJump, severity: .soft))
        #expect(!events.contains(.rep(1)))
        #expect(v.progress.count == 0)
        // La consigna sigue vigente y un movimiento humano después sí cuenta.
        #expect(v.currentCue == cue)
        let good = humanMove(&v, &t, &head, cue, magnitude: cue.threshold + 8)
        #expect(good.contains(.rep(1)))
    }

    @Test func secuenciaCompletaTerminaLaActividad() throws {
        var (v, t, head) = neck(seed: 3)
        let all = try completeAll(&v, &t, &head)
        #expect(all.contains(.completed))
        #expect(v.isCompleted)
        #expect(v.progress.hint == NeckVerifier.hintDone)
        let outcome = v.finish(at: t, reason: .completed)
        #expect(outcome.completed && outcome.achieved == v.spec.target)
        if case .neck(let r, let f, let ti, let maxYaw, _, _, let matches, let mismatches) = outcome.metrics {
            #expect(r + f + ti == v.spec.target)
            #expect(matches == v.spec.target && mismatches == 0)
            #expect(maxYaw >= NeckVerifier.turnThreshold)
        } else {
            Issue.record("métricas de cuello esperadas")
        }
        #expect(outcome.anomalies.isEmpty)
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .cuello) == .full)
    }

    @Test func ruidoRealistaA60HzCompletaSinAnomalias() throws {
        for seed in [UInt64(5), 21, 77] {
            var (v, t, head) = neck(seed: seed)
            head.jitter = 2
            head.rng = FaceChallengeRNG(seed: seed &* 31)
            let all = try completeAll(&v, &t, &head, margin: 6)
            #expect(v.isCompleted, "semilla \(seed)")
            #expect(!hasAnomaly(all, kind: NeckVerifier.anomalyTrackingJump), "semilla \(seed)")
            #expect(!hasAnomaly(all, kind: NeckVerifier.anomalyCueMismatch), "semilla \(seed)")
            #expect(!hasAnomaly(all, kind: NeckVerifier.anomalyAxisFlipped), "semilla \(seed)")
        }
    }

    @Test func derivaLentaDePosturaNoBloquea() throws {
        var (v, t, head) = neck(seed: 9)
        // El teléfono en la mano baja de a poco y el cuerpo gira: −1°/s de flexión y +0,6°/s de giro.
        head.drift = (0.6, -1, 0)
        let all = try completeAll(&v, &t, &head)
        #expect(v.isCompleted)
        #expect(!hasAnomaly(all, kind: NeckVerifier.anomalyCueMismatch))
        #expect(!hasAnomaly(all, kind: NeckVerifier.anomalyAxisFlipped))
        // El neutro siguió la deriva.
        #expect(v.neutral.pitch < -6)
        #expect(t > 12)
    }

    @Test func cabezaGachaMirandoElTelefonoGiraSinInclinar() throws {
        var (v, t, head) = neck(seed: seed(firstAxis: .rotation))
        head.neutral = (0, -25, 0)
        waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        let events = humanMove(&v, &t, &head, cue, magnitude: 36)
        #expect(events.contains(.rep(1)))
        let outcome = v.finish(at: t, reason: .userStopped)
        if case .neck(_, _, _, let maxYaw, let maxPitch, let maxRoll, _, _) = outcome.metrics {
            // En ejes del mundo este giro "inclina" ~15° y "levanta" ~5°; relativo a la cabeza es giro puro.
            #expect(maxYaw > 34)
            #expect(maxRoll < 2 && maxPitch < 2)
        } else {
            Issue.record("métricas de cuello esperadas")
        }
    }

    @Test func cabezaGachaCompletaLaSecuencia() throws {
        var (v, t, head) = neck(seed: 4)
        head.neutral = (0, -25, 0)
        let all = try completeAll(&v, &t, &head)
        #expect(v.isCompleted)
        #expect(!hasAnomaly(all, kind: NeckVerifier.anomalyCueMismatch))
        #expect(!hasAnomaly(all, kind: NeckVerifier.anomalyAxisFlipped))
    }

    @Test func neutroCercaDe180GradosNoRompeLaCalibracion() throws {
        var (v, t, head) = neck(seed: 8)
        head.neutral = (178, -10, 0)
        let all = try completeAll(&v, &t, &head)
        #expect(v.isCompleted)
        #expect(abs(wrappedDegrees(v.neutral.yaw - 178)) < 3)
        #expect(!hasAnomaly(all, kind: NeckVerifier.anomalyTrackingJump))
        #expect(!hasAnomaly(all, kind: NeckVerifier.anomalyCueMismatch))
    }

    // MARK: - Cuello: vida de la cara

    @Test func fotoEstaticaEsAnomaliaDura() {
        var (v, t, _) = neck()
        let events = feed(&v, &t, seconds: 2.6) { face(t: $0, energy: 0) }
        #expect(hasAnomaly(events, kind: NeckVerifier.anomalyStatic, severity: .hard))
    }

    @Test func caraPerdidaBloqueaYRecuperaLaConsigna() throws {
        var (v, t, head) = neck()
        waitForCue(&v, &t, &head)
        let cue = try #require(v.currentCue)
        var events = feed(&v, &t, seconds: 2.5) { face(t: $0, tracked: false) }
        #expect(events.contains(.gate(.blocked(reason: NeckVerifier.blockedReason))))
        #expect(v.progress.gate == .blocked(reason: NeckVerifier.blockedReason))
        events = hold(&v, &t, &head, seconds: 0.2)
        #expect(events.contains(.gate(.ready)))
        #expect(events.contains(.cue(cue.cue)))
        #expect(v.currentCue == cue)
        let good = humanMove(&v, &t, &head, cue, magnitude: cue.threshold + 8)
        #expect(good.contains(.rep(1)))
    }

    // MARK: - Matemática de la transform

    private func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }

    @Test func rotacionesPurasDe30GradosDanSignoYMagnitudCorrectos() {
        // Giro puro sobre +Y: la nariz (+Z) va hacia +X, la izquierda de la propia cara → yaw +30.
        let yaw30 = simd_float4x4(simd_quatf(angle: radians(30), axis: SIMD3(0, 1, 0)))
        let a = FaceSampleMath.angles(from: yaw30)
        #expect(abs(a.yaw - 30) < 0.01 && abs(a.pitch) < 0.01 && abs(a.roll) < 0.01)
        #expect(yaw30.columns.2.x > 0)

        // Rotación sobre X de −30°: la nariz sube → pitch +30 (mira arriba).
        let up30 = simd_float4x4(simd_quatf(angle: radians(-30), axis: SIMD3(1, 0, 0)))
        let b = FaceSampleMath.angles(from: up30)
        #expect(abs(b.pitch - 30) < 0.01 && abs(b.yaw) < 0.01 && abs(b.roll) < 0.01)
        #expect(up30.columns.2.y > 0)

        // Rotación sobre X de +30°: la nariz baja → pitch −30 (mira abajo).
        let down30 = simd_float4x4(simd_quatf(angle: radians(30), axis: SIMD3(1, 0, 0)))
        let b2 = FaceSampleMath.angles(from: down30)
        #expect(abs(b2.pitch + 30) < 0.01 && abs(b2.yaw) < 0.01 && abs(b2.roll) < 0.01)

        // Rotación sobre Z de +30°: el eje +X (lado izquierdo de la cara) sube → roll +30 (oreja derecha al hombro).
        let roll30 = simd_float4x4(simd_quatf(angle: radians(30), axis: SIMD3(0, 0, 1)))
        let c = FaceSampleMath.angles(from: roll30)
        #expect(abs(c.roll - 30) < 0.01 && abs(c.yaw) < 0.01 && abs(c.pitch) < 0.01)
        #expect(roll30.columns.0.y > 0)

        // Y los mismos signos en el verificador: cada rotación pura cae en la dirección esperada.
        #expect(NeckVerifier.Direction.left.value(yaw: a.yaw, pitch: a.pitch, roll: a.roll) > 29)
        #expect(NeckVerifier.Direction.up.value(yaw: b.yaw, pitch: b.pitch, roll: b.roll) > 29)
        #expect(NeckVerifier.Direction.down.value(yaw: b2.yaw, pitch: b2.pitch, roll: b2.roll) > 29)
        #expect(NeckVerifier.Direction.tiltRight.value(yaw: c.yaw, pitch: c.pitch, roll: c.roll) > 29)
    }

    @Test func descomposicionCompuestaYRelativa() {
        // R = Ry(20) · Rx(−15) · Rz(10) armada con cuaterniones → (20, 15, 10).
        let q = simd_quatf(angle: radians(20), axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: radians(-15), axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: radians(10), axis: SIMD3(0, 0, 1))
        let m = FaceSampleMath.angles(from: simd_float4x4(q))
        #expect(abs(m.yaw - 20) < 0.01 && abs(m.pitch - 15) < 0.01 && abs(m.roll - 10) < 0.01)
        let back = HeadPose.angles(from: HeadPose.matrix(yaw: 20, pitch: 15, roll: 10))
        #expect(abs(back.yaw - 20) < 1e-9 && abs(back.pitch - 15) < 1e-9 && abs(back.roll - 10) < 1e-9)

        // Cabeza gacha 25° y giro de 30° sobre su propio eje: relativo = giro puro.
        let neutral = (yaw: 0.0, pitch: -25.0, roll: 0.0)
        let current = HeadPose.angles(from: HeadPose.matrix(yaw: 0, pitch: -25, roll: 0) * HeadPose.matrix(yaw: 30, pitch: 0, roll: 0))
        let rel = HeadPose.relative(current: current, to: neutral)
        #expect(abs(rel.yaw - 30) < 1e-6 && abs(rel.pitch) < 1e-6 && abs(rel.roll) < 1e-6)

        // Neutro mirando hacia −Z del mundo (yaw ≈ 180°): el relativo cruza ±180 sin saltos.
        let rel180 = HeadPose.relative(current: (yaw: -175, pitch: 0, roll: 0), to: (yaw: 175, pitch: 0, roll: 0))
        #expect(abs(rel180.yaw - 10) < 1e-6)
    }

    @Test func camaraEnLaCaraYEnergia() {
        var faceT = matrix_identity_float4x4
        faceT.columns.3 = SIMD4(0, 0, -0.4, 1)
        let cam = FaceSampleMath.cameraInFace(face: faceT, camera: matrix_identity_float4x4)
        #expect(abs(cam.z - 0.4) < 0.001)
        #expect(abs(FaceSampleMath.shapeEnergy(current: [0.5, 0.2], previous: [0.1, 0.4]) - 0.6) < 1e-5)
        #expect(FaceSampleMath.shapeEnergy(current: [0.5], previous: nil) == 0)
    }
}
