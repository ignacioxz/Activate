import AVFoundation
import Foundation

// Integración: cableado de `ActivityRunnerFactory`. Un builder por `ActivityKind` que arma el
// verificador (máquina de estados pura) con su fuente de muestras (sensor en vivo o replay).
//
// - En dispositivo: sensores reales (`StepSource`, `CameraPoseSource`, `FaceSource`, `ScreenSource`).
// - Con `replay == true` y SIEMPRE en simulador: `ReplaySource` con fixtures sintéticas de
//   `FixtureSynth` que completan la actividad; la política marca todo lo reproducido como `simulated`.
//   Stroop y respiración no tienen sensor (la pantalla es la fuente): en replay se usa un
//   `ScreenSource` con nivel `.replay`, así la vista sigue funcionando y la sesión queda `simulated`.

@MainActor
enum VerifierWiring {
    /// Velocidad de reproducción de las fixtures (1 = tiempo real, visible en pantalla).
    static let replaySpeed: Double = 1
    /// Margen de pasos sobre la meta para que el podómetro sintético la supere con holgura.
    static let walkStepMarginFactor: Double = 1.15
    static let walkStepMarginSteps = 5
    /// Segundos extra de fixture después de cumplir la duración mínima.
    static let fixtureSlackSeconds: Double = 5

    /// En simulador no hay podómetro, cámara frontal ni ARKit: siempre replay.
    static var forcesReplay: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Una sola `AVCaptureSession` reutilizada entre A3 y A1 (`start()` tras `stop()` rearranca sin reconfigurar).
    private static var sharedCameraSource: CameraPoseSource?

    private static func cameraSource() -> CameraPoseSource {
        if let sharedCameraSource { return sharedCameraSource }
        let source = CameraPoseSource()
        sharedCameraSource = source
        return source
    }

    /// Registra un builder por tipo de actividad. Se llama una vez desde `ActivateApp.init`.
    static func register(sensors: SensorHub, store: AppStore) {
        for kind in ActivityKind.allCases {
            ActivityRunnerFactory.register(kind, builder(for: kind, sensors: sensors, store: store))
        }
    }

    /// Builder de un tipo (expuesto para tests; `speed` solo afecta al replay).
    static func builder(for kind: ActivityKind, sensors: SensorHub, store: AppStore,
                        speed: Double = replaySpeed) -> ActivityRunnerFactory.Builder {
        switch kind {
        case .pasos:
            return { assignment, demo, replay in
                let spec = VerificationSpec.standard(for: .pasos, target: assignment.target, demo: demo)
                let verifier = PedometerVerifier(spec: spec)
                if replay || forcesReplay {
                    let source = ReplaySource(samples: ReplayFixtures.walk(spec: spec), speed: speed)
                    return ActivityRunner(assignment: assignment, verifier: verifier, source: source)
                }
                let source = StepSource(hub: sensors, spec: spec, watchdogEnabled: !store.data.demo.notificationsMuted)
                return ActivityRunner(assignment: assignment, verifier: verifier, source: source)
            }

        case .sentadilla:
            return { assignment, demo, replay in
                let spec = VerificationSpec.standard(for: .sentadilla, target: assignment.target, demo: demo)
                let verifier = SquatVerifier(spec: spec)
                if replay || forcesReplay {
                    let source = ReplaySource(samples: ReplayFixtures.squats(spec: spec), speed: speed)
                    return ActivityRunner(assignment: assignment, verifier: verifier, source: source)
                }
                return ActivityRunner(assignment: assignment, verifier: verifier, source: cameraSource())
            }

        case .extensionLumbar:
            return { assignment, demo, replay in
                let spec = VerificationSpec.standard(for: .extensionLumbar, target: assignment.target, demo: demo)
                let verifier = ExtensionVerifier(spec: spec)
                if replay || forcesReplay {
                    let source = ReplaySource(samples: ReplayFixtures.extensions(spec: spec), speed: speed)
                    return ActivityRunner(assignment: assignment, verifier: verifier, source: source)
                }
                return ActivityRunner(assignment: assignment, verifier: verifier, source: cameraSource())
            }

        case .cuello:
            return { assignment, demo, replay in
                let spec = VerificationSpec.standard(for: .cuello, target: assignment.target, demo: demo)
                let verifier = NeckVerifier(spec: spec)
                if replay || forcesReplay {
                    // La fixture sigue el plan de consignas de esta semilla.
                    let source = ReplaySource(samples: ReplayFixtures.neck(plan: verifier.plan), speed: speed)
                    return ActivityRunner(assignment: assignment, verifier: verifier, source: source)
                }
                return ActivityRunner(assignment: assignment, verifier: verifier, source: FaceSource())
            }

        case .ojos:
            return { assignment, demo, replay in
                let spec = VerificationSpec.standard(for: .ojos, target: assignment.target, demo: demo)
                let verifier = EyeRestVerifier(spec: spec)
                if replay || forcesReplay {
                    let source = ReplaySource(samples: ReplayFixtures.eyes(verifier: verifier), speed: speed)
                    return ActivityRunner(assignment: assignment, verifier: verifier, source: source)
                }
                return ActivityRunner(assignment: assignment, verifier: verifier, source: FaceSource())
            }

        case .stroop:
            return { assignment, demo, replay in
                let spec = VerificationSpec.standard(for: .stroop, target: assignment.target, demo: demo)
                let source = ScreenSource(level: (replay || forcesReplay) ? .replay : .live)
                return ActivityRunner(assignment: assignment, verifier: StroopVerifier(spec: spec), source: source)
            }

        case .respiracion:
            return { assignment, demo, replay in
                let spec = VerificationSpec.standard(for: .respiracion, target: assignment.target, demo: demo)
                let source = ScreenSource(level: (replay || forcesReplay) ? .replay : .live)
                return ActivityRunner(assignment: assignment, verifier: BreathVerifier(spec: spec), source: source)
            }
        }
    }
}

// MARK: - Acceso a la fuente desde el flujo de pausa

extension ActivityRunning {
    /// Fuente de pantalla que la vista debe alimentar (solo runners de Stroop / respiración).
    var screenSource: ScreenSource? {
        (self as? ActivityRunner<StroopVerifier, ScreenSource>)?.source
            ?? (self as? ActivityRunner<BreathVerifier, ScreenSource>)?.source
    }

    /// Sesión de captura para `CameraPreviewView` (solo runners de cámara de cuerpo entero en vivo).
    var cameraCaptureSession: AVCaptureSession? {
        (self as? ActivityRunner<SquatVerifier, CameraPoseSource>)?.source.captureSession
            ?? (self as? ActivityRunner<ExtensionVerifier, CameraPoseSource>)?.source.captureSession
    }

    /// Fuente de pasos en vivo (para `resumeReconciliation()` al volver a `.active`).
    var stepSource: StepSource? {
        (self as? ActivityRunner<PedometerVerifier, StepSource>)?.source
    }
}

// MARK: - Fixtures que completan cada actividad

/// Muestras sintéticas (deterministas) que llevan a cada verificador hasta `.completed`.
/// Se usan en simulador y en tests; el runner las marca `simulated`.
nonisolated enum ReplayFixtures {
    /// Marcha a cadencia normal con pasos de sobra y duración ≥ mínimo de la spec.
    static func walk(spec: VerificationSpec) -> [StepSample] {
        let options = FixtureSynth.WalkOptions()
        let byTarget = Int((Double(spec.target) * VerifierWiring.walkStepMarginFactor).rounded(.up)) + VerifierWiring.walkStepMarginSteps
        let byDuration = Int(((spec.minDurationSeconds + VerifierWiring.fixtureSlackSeconds) * options.cadence).rounded(.up))
        return FixtureSynth.walk(steps: max(byTarget, byDuration), options: options)
    }

    /// Sentadillas válidas con 2 s de pie para el gating/calibración.
    static func squats(spec: VerificationSpec) -> [PoseSample] {
        var options = FixtureSynth.SquatOptions()
        options.leadInSeconds = 2
        options.trailSeconds = 1.5
        return FixtureSynth.squats(count: spec.target, options: options)
    }

    // MARK: Extensión lumbar

    nonisolated struct ExtensionOptions: Sendable, Hashable {
        /// Desplazamiento horizontal de hombros/cuello/nariz (fracción del cuadro) en el pico.
        var shift: Double = 0.10
        var periodSeconds: Double = 1.9
        var periodJitter: Double = 0.15
        var pauseSeconds: Double = 0.7
        var fps: Double = 30
        var noise: Double = 0.002
        var leadInSeconds: Double = 2
        var trailSeconds: Double = 1.5
        var confidence: Float = 0.9
        var seed: UInt64 = 3

        init() {}
    }

    /// Extensiones lumbares de pie: hombros, cuello y nariz se desplazan y vuelven; cadera y tobillos quietos.
    static func extensions(spec: VerificationSpec) -> [PoseSample] {
        extensions(count: spec.target)
    }

    static func extensions(count: Int, options: ExtensionOptions = ExtensionOptions()) -> [PoseSample] {
        var rng = FixtureRandom(seed: options.seed)
        var segments: [(start: Double, period: Double)] = []
        var cursor = options.leadInSeconds
        for _ in 0..<max(0, count) {
            let period = options.periodSeconds * (1 + rng.symmetric(options.periodJitter))
            segments.append((cursor, period))
            cursor += period + options.pauseSeconds * (1 + rng.symmetric(options.periodJitter))
        }
        let total = cursor + options.trailSeconds
        let dt = 1 / max(1, options.fps)
        let frames = Int((total / dt).rounded(.up))
        var samples: [PoseSample] = []
        samples.reserveCapacity(frames + 1)
        for i in 0...frames {
            let t = Double(i) * dt
            var shift = 0.0
            if let seg = segments.last(where: { $0.start <= t }), t < seg.start + seg.period {
                let s = (t - seg.start) / seg.period
                shift = options.shift * (1 - cos(2 * .pi * s)) / 2
            }
            samples.append(extensionFrame(t: t, shift: shift, options: options, rng: &rng))
        }
        return samples
    }

    private static func extensionFrame(t: Double, shift: Double, options: ExtensionOptions, rng: inout FixtureRandom) -> PoseSample {
        typealias S = FixtureSynth.Skeleton
        let cx = S.centerX
        func joint(_ x: Double, _ y: Double) -> JointPoint {
            JointPoint(x: x + rng.symmetric(options.noise),
                       y: y + rng.symmetric(options.noise),
                       confidence: options.confidence + Float(rng.symmetric(0.02)))
        }
        let joints: [JointKey: JointPoint] = [
            .nose: joint(cx + shift, S.noseY),
            .neck: joint(cx + shift, S.neckY),
            .leftShoulder: joint(cx - S.shoulderHalfWidth + shift, S.shoulderY),
            .rightShoulder: joint(cx + S.shoulderHalfWidth + shift, S.shoulderY),
            .root: joint(cx, S.hipY),
            .leftHip: joint(cx - S.hipHalfWidth, S.hipY),
            .rightHip: joint(cx + S.hipHalfWidth, S.hipY),
            .leftKnee: joint(cx - S.kneeHalfWidth, S.kneeY),
            .rightKnee: joint(cx + S.kneeHalfWidth, S.kneeY),
            .leftAnkle: joint(cx - S.ankleHalfWidth, S.ankleY),
            .rightAnkle: joint(cx + S.ankleHalfWidth, S.ankleY),
        ]
        return PoseSample(t: t, joints: joints, fps: options.fps)
    }

    // MARK: Cuello

    /// Segundos de cara neutra antes del primer movimiento: calibración (0,5 s) + retardo máximo de consigna (2,5 s) + margen.
    static let neckLeadInSeconds: Double = NeckVerifier.calibrationSeconds + NeckVerifier.cueDelayRange.upperBound + 1
    /// Pausa en el centro entre movimientos: mayor que el retardo máximo de la siguiente consigna.
    static let neckPauseSeconds: Double = NeckVerifier.cueDelayRange.upperBound + 0.6

    /// Secuencia que sigue el plan de consignas del verificador (misma semilla), con pausas que dejan
    /// llegar cada consigna antes del movimiento.
    static func neck(plan: [NeckVerifier.Direction]) -> [FaceSample] {
        var options = FixtureSynth.NeckOptions()
        options.leadInSeconds = neckLeadInSeconds
        options.pauseSeconds = neckPauseSeconds
        options.trailSeconds = 1
        return FixtureSynth.neckSequence(plan.map(neckMove), options: options)
    }

    /// `NeckVerifier.Direction` → `FixtureSynth.NeckMove` por signo de ángulo (yaw > 0 izquierda,
    /// pitch > 0 arriba, roll > 0 oreja derecha al hombro derecho; el sintetizador invierte el roll).
    static func neckMove(_ direction: NeckVerifier.Direction) -> FixtureSynth.NeckMove {
        switch direction {
        case .left: .rotateLeft
        case .right: .rotateRight
        case .up: .extensionMove
        case .down: .flexion
        case .tiltRight: .tiltLeft
        case .tiltLeft: .tiltRight
        }
    }

    // MARK: Ojos

    /// Grados de desvío de la mirada en el descanso visual (≥ θ₀ + 12°).
    static let eyesAwayDegrees: Double = 25

    /// Parpadeos completos hasta la meta, cara neutra para calibrar la mirada y luego mirada lejos
    /// hasta cubrir la meta de descanso (20 s reales / 8 s demo).
    static func eyes(verifier: EyeRestVerifier) -> [FaceSample] {
        eyes(target: verifier.spec.target, farGazeSeconds: verifier.farGazeGoal)
    }

    static func eyes(target: Int, farGazeSeconds: Double) -> [FaceSample] {
        var blinkOptions = FixtureSynth.BlinkOptions()
        blinkOptions.trailSeconds = EyeRestVerifier.gazeCalibrationSeconds + 1.5
        let blinks = FixtureSynth.blinks(count: target, options: blinkOptions)
        let dt = 1 / blinkOptions.face.fps
        let offset = (blinks.last?.t ?? 0) + dt
        let gaze = FixtureSynth.gaze(seconds: farGazeSeconds + EyeRestVerifier.graceSeconds + 2,
                                     awayDegrees: eyesAwayDegrees).map { sample in
            var s = sample
            s.t += offset
            return s
        }
        return blinks + gaze
    }
}
