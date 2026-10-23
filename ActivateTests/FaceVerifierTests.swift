import Testing
import Foundation
import simd
@testable import Activate

/// Muestras sintéticas de cara a 30 fps para `NeckVerifier` y `EyeRestVerifier`.
struct FaceVerifierTests {
    private static let fps: Double = 30
    private static let dt = 1 / fps

    /// Mirada al teléfono: `lookAt` y `cameraInFace` apuntan en la misma dirección (θ ≈ 0).
    private static let lookAtPhone = SIMD3<Float>(0, 0, 0.4)
    /// Mirada desviada 20° (más que los 12° de descanso).
    private static let lookFar = SIMD3<Float>(sin(20 * Float.pi / 180), 0, cos(20 * Float.pi / 180)) * 0.4

    private func face(t: Double, yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
                      blinkL: Float = 0, blinkR: Float = 0, lookAt: SIMD3<Float> = Self.lookAtPhone,
                      tracked: Bool = true, energy: Float = 0.05) -> FaceSample {
        FaceSample(t: t, isTracked: tracked, yaw: yaw, pitch: pitch, roll: roll,
                   position: SIMD3(0, 0, -0.4), cameraInFace: SIMD3(0, 0, 0.4), lookAt: lookAt,
                   blinkL: blinkL, blinkR: blinkR, shapeEnergy: energy)
    }

    /// Alimenta `seconds` de muestras producidas por `make(t)` y devuelve los eventos.
    @discardableResult
    private func feed<V: ActivityVerifier>(_ v: inout V, _ t: inout Double, seconds: Double,
                                           _ make: (Double) -> FaceSample) -> [VerifierEvent] where V.Sample == FaceSample {
        var events: [VerifierEvent] = []
        let frames = Int((seconds * Self.fps).rounded())
        for _ in 0..<frames {
            t += Self.dt
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

    private func hasCue(_ events: [VerifierEvent]) -> Bool {
        events.contains { if case .cue = $0 { return true } else { return false } }
    }

    // MARK: - Ojos

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

    @Test func ochoParpadeosValidosCuentan() {
        var (v, t) = eyes()
        var events: [VerifierEvent] = []
        for _ in 0..<8 {
            events += closure(&v, &t, left: 0.95, right: 0.9, closeSeconds: 0.15)
        }
        #expect(v.completeBlinks == 8)
        #expect(events.contains(.rep(8)))
        #expect(events.contains(.cue(EyeRestVerifier.cueBlink)))
        #expect(events.contains(.cue(EyeRestVerifier.cueLookAtScreen)))
        #expect(v.phase == .gazeCalibration)
    }

    @Test func descansoVisualCompletaLaActividad() {
        var (v, t) = eyes()
        for _ in 0..<8 { closure(&v, &t, left: 0.95, right: 0.9, closeSeconds: 0.15) }
        // Calibración mirando la pantalla.
        var events = feed(&v, &t, seconds: 2.2) { face(t: $0) }
        #expect(events.contains(.cue(EyeRestVerifier.cueLookFar)))
        #expect(v.phase == .gaze)
        // Mirar lejos no acumula si la cabeza está agachada.
        events = feed(&v, &t, seconds: 3) { face(t: $0, pitch: -30, lookAt: Self.lookFar) }
        #expect(!events.contains(.completed))
        #expect(v.farGazeSeconds < 1.5)
        // Mirar lejos con la cabeza derecha sí.
        events = feed(&v, &t, seconds: 9) { face(t: $0, lookAt: Self.lookFar) }
        #expect(events.contains(.completed))
        #expect(v.isCompleted)
        #expect(v.farGazeSeconds >= v.farGazeGoal)
        let outcome = v.finish(at: t, reason: .completed)
        #expect(outcome.completed)
        #expect(outcome.achieved == 8)
        if case .eyes(let complete, _, let bpm, let far) = outcome.metrics {
            #expect(complete == 8)
            #expect(bpm > 0)
            #expect(far >= 8)
        } else {
            Issue.record("métricas de ojos esperadas")
        }
    }

    @Test func mirarAlTelefonoNoAcumulaDescanso() {
        var (v, t) = eyes()
        for _ in 0..<8 { closure(&v, &t, left: 0.95, right: 0.9, closeSeconds: 0.15) }
        feed(&v, &t, seconds: 2.2) { face(t: $0) }
        let events = feed(&v, &t, seconds: 10) { face(t: $0) }
        #expect(!events.contains(.completed))
        // Solo el segundo de gracia inicial puede haber sumado.
        #expect(v.farGazeSeconds <= EyeRestVerifier.graceSeconds + 2 * Self.dt)
    }

    @Test func anguloDeMirada() {
        let straight = EyeRestVerifier.gazeAngleDegrees(lookAt: Self.lookAtPhone, cameraInFace: SIMD3(0, 0, 0.4))
        let far = EyeRestVerifier.gazeAngleDegrees(lookAt: Self.lookFar, cameraInFace: SIMD3(0, 0, 0.4))
        #expect(abs((straight ?? 99)) < 0.01)
        #expect(abs((far ?? 0) - 20) < 0.01)
        #expect(EyeRestVerifier.gazeAngleDegrees(lookAt: .zero, cameraInFace: SIMD3(0, 0, 0.4)) == nil)
    }

    // MARK: - Cuello

    private func neck(seed: UInt64 = 7) -> (NeckVerifier, Double) {
        var v = NeckVerifier(spec: .standard(for: .cuello, demo: true), seed: seed)
        v.start(at: 0)
        return (v, 0)
    }

    /// Muestras neutras hasta que salga una consigna (o hasta `maxSeconds`).
    @discardableResult
    private func waitForCue(_ v: inout NeckVerifier, _ t: inout Double, maxSeconds: Double = 4) -> [VerifierEvent] {
        var events: [VerifierEvent] = []
        let frames = Int(maxSeconds * Self.fps)
        for _ in 0..<frames {
            t += Self.dt
            let e = v.ingest(face(t: t), at: t)
            events += e
            if hasCue(e) { break }
        }
        return events
    }

    /// Rampa lineal entre dos magnitudes en la dirección dada.
    private func ramp(_ v: inout NeckVerifier, _ t: inout Double, _ direction: NeckVerifier.Direction,
                      from: Double, to: Double, seconds: Double) -> [VerifierEvent] {
        let start = t
        return feed(&v, &t, seconds: seconds) { tt in
            let f = min(1, max(0, (tt - start) / seconds))
            let p = direction.pose(from + (to - from) * f)
            return face(t: tt, yaw: p.yaw, pitch: p.pitch, roll: p.roll)
        }
    }

    private func humanMove(_ v: inout NeckVerifier, _ t: inout Double, _ direction: NeckVerifier.Direction,
                           magnitude: Double) -> [VerifierEvent] {
        var events = ramp(&v, &t, direction, from: 0, to: magnitude, seconds: 0.6)
        events += ramp(&v, &t, direction, from: magnitude, to: magnitude, seconds: 0.3)
        events += ramp(&v, &t, direction, from: magnitude, to: 0, seconds: 0.6)
        events += feed(&v, &t, seconds: 0.3) { face(t: $0) }
        return events
    }

    private func other(than d: NeckVerifier.Direction) -> NeckVerifier.Direction {
        switch d {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        case .tiltLeft: .tiltRight
        case .tiltRight: .tiltLeft
        }
    }

    @Test func planRepartidoYReproducible() {
        let a = NeckVerifier(spec: .standard(for: .cuello), seed: 99)
        let b = NeckVerifier(spec: .standard(for: .cuello), seed: 99)
        #expect(a.plan == b.plan)
        #expect(a.plan.count == 15)
        let rot = a.plan.filter { $0.axis == .rotation }.count
        let flex = a.plan.filter { $0.axis == .flexion }.count
        let tilt = a.plan.filter { $0.axis == .tilt }.count
        #expect(rot == 5 && flex == 5 && tilt == 5)
    }

    @Test func calibraYEmiteConsignaConRetardo() throws {
        var (v, t) = neck()
        let calib = feed(&v, &t, seconds: 0.6) { face(t: $0) }
        #expect(calib.contains(.gate(.ready)))
        #expect(v.currentCue == nil)
        let events = waitForCue(&v, &t)
        let cue = try #require(v.currentCue)
        #expect(events.contains(.cue(cue.cue)))
        // La calibración termina a los 0,5 s; la consigna llega entre 0,8 y 2,5 s después.
        #expect(t >= NeckVerifier.calibrationSeconds + NeckVerifier.cueDelayRange.lowerBound - 2 * Self.dt)
        #expect(t <= 0.6 + NeckVerifier.cueDelayRange.upperBound + 2 * Self.dt)
    }

    @Test func giroQueCoincideCuenta() throws {
        var (v, t) = neck()
        feed(&v, &t, seconds: 0.6) { face(t: $0) }
        waitForCue(&v, &t)
        let cue = try #require(v.currentCue)
        let events = humanMove(&v, &t, cue, magnitude: cue.threshold + 10)
        #expect(events.contains(.rep(1)))
        #expect(v.progress.count == 1)
        #expect(!hasAnomaly(events, kind: NeckVerifier.anomalyCueMismatch))
        #expect(!hasAnomaly(events, kind: NeckVerifier.anomalyTrackingJump))
        #expect(v.currentCue == nil)
    }

    @Test func giroQueNoCoincideGeneraMismatch() throws {
        var (v, t) = neck()
        feed(&v, &t, seconds: 0.6) { face(t: $0) }
        waitForCue(&v, &t)
        let cue = try #require(v.currentCue)
        let wrong = other(than: cue)
        var events = humanMove(&v, &t, wrong, magnitude: wrong.threshold + 10)
        #expect(hasAnomaly(events, kind: NeckVerifier.anomalyCueMismatch, severity: .soft))
        #expect(!events.contains(.rep(1)))
        #expect(v.progress.count == 0)
        // Tras volver al centro se vuelve a pedir la misma consigna.
        waitForCue(&v, &t)
        #expect(v.currentCue == cue)
        // Tercer fallo → hard.
        events = humanMove(&v, &t, wrong, magnitude: wrong.threshold + 10)
        waitForCue(&v, &t)
        events += humanMove(&v, &t, wrong, magnitude: wrong.threshold + 10)
        #expect(hasAnomaly(events, kind: NeckVerifier.anomalyCueMismatch, severity: .hard))
        let outcome = v.finish(at: t, reason: .userStopped)
        #expect(!outcome.completed)
        #expect(outcome.anomalies.contains { $0.severity == .hard })
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .cuello) == .suspicious)
    }

    @Test func movimientoSinConsignaNoCuenta() {
        var (v, t) = neck()
        feed(&v, &t, seconds: 0.6) { face(t: $0) }
        // Se mueve antes de que salga la consigna (vídeo que no espera la señal).
        let first = v.plan[0]
        let events = humanMove(&v, &t, first, magnitude: first.threshold + 10)
        #expect(!events.contains(.rep(1)))
        #expect(v.progress.count == 0)
    }

    @Test func saltoEntreFramesSeDescarta() throws {
        var (v, t) = neck()
        feed(&v, &t, seconds: 0.6) { face(t: $0) }
        waitForCue(&v, &t)
        let cue = try #require(v.currentCue)
        // 0 → 60° en un frame (1 800 °/s), meseta y vuelta también brusca.
        var events = feed(&v, &t, seconds: 0.3) { tt in
            let p = cue.pose(60)
            return face(t: tt, yaw: p.yaw, pitch: p.pitch, roll: p.roll)
        }
        events += feed(&v, &t, seconds: 0.5) { face(t: $0) }
        #expect(hasAnomaly(events, kind: NeckVerifier.anomalyTrackingJump, severity: .soft))
        #expect(!events.contains(.rep(1)))
        #expect(v.progress.count == 0)
        // La consigna sigue vigente y un movimiento humano después sí cuenta.
        #expect(v.currentCue == cue)
        let good = humanMove(&v, &t, cue, magnitude: cue.threshold + 10)
        #expect(good.contains(.rep(1)))
    }

    @Test func secuenciaCompletaTerminaLaActividad() throws {
        var (v, t) = neck(seed: 3)
        feed(&v, &t, seconds: 0.6) { face(t: $0) }
        var all: [VerifierEvent] = []
        for _ in 0..<v.spec.target {
            waitForCue(&v, &t)
            let cue = try #require(v.currentCue)
            all += humanMove(&v, &t, cue, magnitude: cue.threshold + 15)
        }
        #expect(all.contains(.completed))
        #expect(v.isCompleted)
        let outcome = v.finish(at: t, reason: .completed)
        #expect(outcome.completed && outcome.achieved == v.spec.target)
        if case .neck(let r, let f, let ti, let maxYaw, _, _, let matches, let mismatches) = outcome.metrics {
            #expect(r + f + ti == v.spec.target)
            #expect(matches == v.spec.target && mismatches == 0)
            #expect(maxYaw >= NeckVerifier.yawThreshold)
        } else {
            Issue.record("métricas de cuello esperadas")
        }
        #expect(VerificationPolicy.level(for: outcome, source: .live, kind: .cuello) == .full)
    }

    @Test func fotoEstaticaEsAnomaliaDura() {
        var (v, t) = neck()
        let events = feed(&v, &t, seconds: 2.6) { face(t: $0, energy: 0) }
        #expect(hasAnomaly(events, kind: NeckVerifier.anomalyStatic, severity: .hard))
    }

    @Test func caraPerdidaBloqueaYRecupera() {
        var (v, t) = neck()
        feed(&v, &t, seconds: 0.6) { face(t: $0) }
        var events = feed(&v, &t, seconds: 2.5) { face(t: $0, tracked: false) }
        #expect(events.contains(.gate(.blocked(reason: NeckVerifier.blockedReason))))
        #expect(v.progress.gate == .blocked(reason: NeckVerifier.blockedReason))
        events = feed(&v, &t, seconds: 0.2) { face(t: $0) }
        #expect(events.contains(.gate(.ready)))
    }

    // MARK: - Matemática de la transform

    @Test func descomposicionDeAngulos() {
        let yaw30 = simd_float4x4(simd_quatf(angle: 30 * .pi / 180, axis: SIMD3(0, 1, 0)))
        let a = FaceSampleMath.angles(from: yaw30)
        #expect(abs(a.yaw - 30) < 0.01 && abs(a.pitch) < 0.01 && abs(a.roll) < 0.01)

        // Rotación sobre X de −20°: la nariz (+Z) sube → pitch +20.
        let up20 = simd_float4x4(simd_quatf(angle: -20 * .pi / 180, axis: SIMD3(1, 0, 0)))
        let b = FaceSampleMath.angles(from: up20)
        #expect(abs(b.pitch - 20) < 0.01 && abs(b.yaw) < 0.01)

        // Rotación sobre Z de +15°: el eje X de la cara sube → roll +15.
        let roll15 = simd_float4x4(simd_quatf(angle: 15 * .pi / 180, axis: SIMD3(0, 0, 1)))
        let c = FaceSampleMath.angles(from: roll15)
        #expect(abs(c.roll - 15) < 0.01 && abs(c.yaw) < 0.01)

        var faceT = matrix_identity_float4x4
        faceT.columns.3 = SIMD4(0, 0, -0.4, 1)
        let cam = FaceSampleMath.cameraInFace(face: faceT, camera: matrix_identity_float4x4)
        #expect(abs(cam.z - 0.4) < 0.001)

        #expect(abs(FaceSampleMath.shapeEnergy(current: [0.5, 0.2], previous: [0.1, 0.4]) - 0.6) < 1e-5)
        #expect(FaceSampleMath.shapeEnergy(current: [0.5], previous: nil) == 0)
    }
}
