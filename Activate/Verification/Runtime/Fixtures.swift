import Foundation
import simd

// Dueño: agente "runtime".
//
// Fixtures: listas de muestras con nombre, en JSON, para reproducir con `ReplaySource` en el
// simulador y en los tests. Hay dos orígenes: grabadas en el iPhone (`FixtureRecorder`, paquetes de
// sensores) y sintéticas (`FixtureSynth`, aquí). Las sintéticas sirven para probar cada máquina de
// estados con casos límite (sentadilla válida / a medias / foto estática / vídeo en bucle;
// parpadeo completo / guiño; cuello; marcha / sacudida / quieto) sin dispositivo.
//
// Convención de archivos: `ActivateTests/Fixtures/<nombre>.json` (el grupo sincronizado del target de
// tests los copia como recursos) y se cargan con `Fixture<PoseSample>.load("nombre", bundle: Fixture.testBundle)`.

// MARK: - Fixture

nonisolated struct Fixture<Sample: Codable>: Codable {
    var name: String
    var samples: [Sample]

    init(name: String, samples: [Sample]) {
        self.name = name
        self.samples = samples
    }

    /// Carga `<name>.json` desde un bundle (por defecto, el bundle de tests si existe).
    static func load(_ name: String, bundle: Bundle? = Fixture.testBundle, subdirectory: String? = nil) throws -> Fixture {
        guard let bundle else { throw FixtureError.bundleUnavailable }
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: subdirectory)
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw FixtureError.notFound(name)
        }
        return try load(url: url)
    }

    static func load(url: URL) throws -> Fixture {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Fixture {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Fixture.self, from: data)
    }

    func jsonData(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Escribe `<name>.json` en un directorio (lo usa `FixtureRecorder` en el iPhone).
    @discardableResult
    func write(to directory: URL, pretty: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("json")
        try jsonData(pretty: pretty).write(to: url, options: .atomic)
        return url
    }

    /// Bundle `.xctest` cargado, si el proceso corre tests.
    static var testBundle: Bundle? {
        Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }
    }
}

extension Fixture: Sendable where Sample: Sendable {}
extension Fixture: Equatable where Sample: Equatable {}

nonisolated enum FixtureError: Error, Sendable, Equatable {
    case notFound(String)
    case bundleUnavailable
}

// MARK: - Generador aleatorio determinista

/// SplitMix64: mismo `seed` → misma secuencia en cualquier plataforma (fixtures reproducibles).
nonisolated struct FixtureRandom: RandomNumberGenerator, Sendable, Hashable, Codable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniforme en [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Uniforme en [-amplitude, amplitude].
    mutating func symmetric(_ amplitude: Double) -> Double {
        (unit() * 2 - 1) * amplitude
    }
}

// MARK: - Sintetizadores

/// Generadores sintéticos de muestras. Todos deterministas por `seed`.
nonisolated enum FixtureSynth {

    // MARK: Pose (sentadilla / extensión lumbar)

    /// Esqueleto de pie, normalizado 0-1 con origen abajo-izquierda (convención Vision).
    /// Estatura en el cuadro `h0 = nose.y - ankle.y = 0.74` (≥ 1/3 del frame, como exige el gating).
    nonisolated struct Skeleton: Sendable, Hashable {
        static let ankleY = 0.12, kneeY = 0.30, hipY = 0.46, shoulderY = 0.76, neckY = 0.80, noseY = 0.86
        static let centerX = 0.5
        static let shoulderHalfWidth = 0.08, hipHalfWidth = 0.06, kneeHalfWidth = 0.07, ankleHalfWidth = 0.08
        static var height: Double { noseY - ankleY }
    }

    nonisolated struct SquatOptions: Sendable, Hashable {
        /// Duración de una repetición (bajar y subir).
        var periodSeconds: Double = 2.0
        /// Descenso máximo de la cadera como fracción de la estatura (≥ 0,12 cuenta; 0,07 es "a medias").
        var depthRatio: Double = 0.18
        var fps: Double = 30
        /// Ruido uniforme por coordenada (micro-movimiento de una persona real).
        var noise: Double = 0.002
        /// Variación aleatoria del período por repetición (±fracción). 0 = vídeo en bucle.
        var periodJitter: Double = 0.15
        /// Segundos de pie antes y después de las repeticiones.
        var leadInSeconds: Double = 1.0
        var trailSeconds: Double = 1.0
        /// Desplazamiento horizontal del encuadre por segundo (0 = teléfono apoyado; > 0 = `phoneMoved`).
        var cameraDriftPerSecond: Double = 0
        var confidence: Float = 0.9
        var seed: UInt64 = 1

        init() {}
    }

    /// `count` sentadillas parciales: la cadera (y todo lo que está encima) baja `depthRatio · h0`,
    /// las rodillas bajan un poco y se abren, los tobillos no se mueven.
    static func squats(count: Int, options: SquatOptions = SquatOptions()) -> [PoseSample] {
        var rng = FixtureRandom(seed: options.seed)
        let dt = 1 / max(1, options.fps)
        var periods: [Double] = []
        for _ in 0..<max(0, count) {
            periods.append(options.periodSeconds * (1 + rng.symmetric(options.periodJitter)))
        }
        let repsStart = options.leadInSeconds
        let repsEnd = repsStart + periods.reduce(0, +)
        let total = repsEnd + options.trailSeconds
        let frames = Int((total / dt).rounded(.up))
        var samples: [PoseSample] = []
        samples.reserveCapacity(frames + 1)

        for i in 0...frames {
            let t = Double(i) * dt
            var descent = 0.0
            if t >= repsStart, t < repsEnd {
                var local = t - repsStart
                var index = 0
                while index < periods.count, local >= periods[index] {
                    local -= periods[index]
                    index += 1
                }
                if index < periods.count {
                    let s = local / periods[index]
                    descent = options.depthRatio * Skeleton.height * (1 - cos(2 * .pi * s)) / 2
                }
            }
            let drift = options.cameraDriftPerSecond * t
            samples.append(poseFrame(t: t, descent: descent, drift: drift, options: options, rng: &rng))
        }
        return samples
    }

    /// Sentadillas "a medias": no llegan al umbral de descenso.
    static func halfSquats(count: Int, options: SquatOptions = SquatOptions()) -> [PoseSample] {
        var o = options
        o.depthRatio = 0.07
        return squats(count: count, options: o)
    }

    /// Vídeo en bucle: repeticiones idénticas, período exacto, sin micro-movimiento.
    static func loopedSquats(count: Int, options: SquatOptions = SquatOptions()) -> [PoseSample] {
        var o = options
        o.periodJitter = 0
        o.noise = 0
        return squats(count: count, options: o)
    }

    /// Foto frente a la cámara: una persona de pie sin ningún movimiento.
    static func staticPose(seconds: Double, fps: Double = 30) -> [PoseSample] {
        var o = SquatOptions()
        o.noise = 0
        o.fps = fps
        o.leadInSeconds = seconds
        o.trailSeconds = 0
        return squats(count: 0, options: o)
    }

    private static func poseFrame(t: Double, descent: Double, drift: Double, options: SquatOptions, rng: inout FixtureRandom) -> PoseSample {
        let cx = Skeleton.centerX + drift
        let kneeSpread = Skeleton.kneeHalfWidth + descent * 0.3
        func joint(_ x: Double, _ y: Double) -> JointPoint {
            JointPoint(x: x + rng.symmetric(options.noise),
                       y: y + rng.symmetric(options.noise),
                       confidence: options.confidence + Float(rng.symmetric(0.02)))
        }
        let joints: [JointKey: JointPoint] = [
            .nose: joint(cx, Skeleton.noseY - descent),
            .neck: joint(cx, Skeleton.neckY - descent),
            .leftShoulder: joint(cx - Skeleton.shoulderHalfWidth, Skeleton.shoulderY - descent),
            .rightShoulder: joint(cx + Skeleton.shoulderHalfWidth, Skeleton.shoulderY - descent),
            .root: joint(cx, Skeleton.hipY - descent),
            .leftHip: joint(cx - Skeleton.hipHalfWidth, Skeleton.hipY - descent),
            .rightHip: joint(cx + Skeleton.hipHalfWidth, Skeleton.hipY - descent),
            .leftKnee: joint(cx - kneeSpread, Skeleton.kneeY - descent * 0.45),
            .rightKnee: joint(cx + kneeSpread, Skeleton.kneeY - descent * 0.45),
            .leftAnkle: joint(cx - Skeleton.ankleHalfWidth, Skeleton.ankleY),
            .rightAnkle: joint(cx + Skeleton.ankleHalfWidth, Skeleton.ankleY),
        ]
        return PoseSample(t: t, joints: joints, fps: options.fps)
    }

    // MARK: Cara (parpadeo, mirada lejos, cuello)

    nonisolated struct FaceOptions: Sendable, Hashable {
        var fps: Double = 60
        /// Ruido angular en grados (una cabeza viva nunca está perfectamente quieta).
        var angleNoise: Double = 0.3
        /// Energía de blendShapes de una cara viva (≈ 0 = foto).
        var shapeEnergy: Float = 0.02
        /// Apertura de párpado en reposo (0 = abierto del todo).
        var blinkBaseline: Float = 0.05
        /// Distancia cámara-cara en metros (teléfono en la mano a distancia selfie).
        var cameraDistance: Float = 0.45
        var seed: UInt64 = 1

        init() {}
    }

    nonisolated struct BlinkOptions: Sendable, Hashable {
        var face = FaceOptions()
        /// Segundos de cara neutra antes del primer parpadeo (calibración).
        var leadInSeconds: Double = 2.0
        var intervalSeconds: Double = 1.2
        var intervalJitter: Double = 0.15
        /// Duración del parpadeo (ventana válida 50-500 ms).
        var closeSeconds: Double = 0.18
        /// Cierre máximo: ≥ 0,8 completo; 0,5 parcial.
        var peak: Float = 0.95
        /// `false` = guiño (solo el ojo izquierdo).
        var bilateral: Bool = true
        var trailSeconds: Double = 1.0

        init() {}
    }

    /// `count` parpadeos sobre una cara neutra que mira al teléfono.
    static func blinks(count: Int, options: BlinkOptions = BlinkOptions()) -> [FaceSample] {
        var rng = FixtureRandom(seed: options.face.seed)
        var starts: [Double] = []
        var cursor = options.leadInSeconds
        for _ in 0..<max(0, count) {
            starts.append(cursor)
            cursor += options.closeSeconds + options.intervalSeconds * (1 + rng.symmetric(options.intervalJitter))
        }
        let total = cursor + options.trailSeconds
        let dt = 1 / max(1, options.face.fps)
        let frames = Int((total / dt).rounded(.up))
        var samples: [FaceSample] = []
        samples.reserveCapacity(frames + 1)
        for i in 0...frames {
            let t = Double(i) * dt
            var closure: Float = 0
            if let start = starts.last(where: { $0 <= t }), t < start + options.closeSeconds {
                let u = (t - start) / options.closeSeconds
                closure = Float((1 - cos(2 * .pi * u)) / 2)
            }
            let base = options.face.blinkBaseline
            let l = base + (options.peak - base) * closure
            let r = options.bilateral ? l : base
            samples.append(faceFrame(t: t, yaw: 0, pitch: 0, roll: 0, awayDegrees: 0,
                                     blinkL: l, blinkR: r, options: options.face, rng: &rng))
        }
        return samples
    }

    /// Parpadeos incompletos (cierre 0,5): no cuentan.
    static func partialBlinks(count: Int, options: BlinkOptions = BlinkOptions()) -> [FaceSample] {
        var o = options
        o.peak = 0.5
        return blinks(count: count, options: o)
    }

    /// Guiños (solo un ojo): no cuentan.
    static func winks(count: Int, options: BlinkOptions = BlinkOptions()) -> [FaceSample] {
        var o = options
        o.bilateral = false
        return blinks(count: count, options: o)
    }

    /// Cara que mira a `awayDegrees` de la cámara (0 = mira el teléfono; ≥ θ₀ + 12° = descanso visual).
    static func gaze(seconds: Double, awayDegrees: Double, options: FaceOptions = FaceOptions()) -> [FaceSample] {
        var rng = FixtureRandom(seed: options.seed)
        let dt = 1 / max(1, options.fps)
        let frames = Int((seconds / dt).rounded(.up))
        return (0...frames).map { i in
            let t = Double(i) * dt
            return faceFrame(t: t, yaw: 0, pitch: 0, roll: 0, awayDegrees: awayDegrees,
                             blinkL: options.blinkBaseline, blinkR: options.blinkBaseline, options: options, rng: &rng)
        }
    }

    /// Foto o vídeo congelado frente a la cámara: tracking "válido" pero sin energía ni ruido.
    static func staticFace(seconds: Double, fps: Double = 60) -> [FaceSample] {
        var o = FaceOptions()
        o.fps = fps
        o.angleNoise = 0
        o.shapeEnergy = 0
        return gaze(seconds: seconds, awayDegrees: 0, options: o)
    }

    nonisolated enum NeckMove: String, Sendable, Hashable, Codable, CaseIterable {
        case rotateLeft, rotateRight, flexion, extensionMove, tiltLeft, tiltRight
    }

    nonisolated struct NeckOptions: Sendable, Hashable {
        var face = FaceOptions()
        var leadInSeconds: Double = 1.0
        /// Amplitudes en grados (rotación ≥ 45, flexión/extensión ≥ 25, inclinación ≥ 20 para contar).
        var yawDegrees: Double = 50
        var pitchDegrees: Double = 30
        var rollDegrees: Double = 25
        var rampSeconds: Double = 0.5
        var holdSeconds: Double = 0.3
        var pauseSeconds: Double = 0.4
        var jitter: Double = 0.1
        var trailSeconds: Double = 0.5

        init() {}
    }

    private nonisolated struct NeckSegment: Sendable {
        var start: Double
        var ramp: Double
        var hold: Double
        var move: NeckMove
    }

    /// Secuencia de movimientos de cuello, cada uno con ida, pausa, vuelta al neutro y descanso.
    static func neckSequence(_ moves: [NeckMove], options: NeckOptions = NeckOptions()) -> [FaceSample] {
        var rng = FixtureRandom(seed: options.face.seed)
        var segments: [NeckSegment] = []
        var cursor = options.leadInSeconds
        for move in moves {
            let ramp = options.rampSeconds * (1 + rng.symmetric(options.jitter))
            let hold = options.holdSeconds * (1 + rng.symmetric(options.jitter))
            segments.append(NeckSegment(start: cursor, ramp: ramp, hold: hold, move: move))
            cursor += ramp * 2 + hold + options.pauseSeconds * (1 + rng.symmetric(options.jitter))
        }
        let total = cursor + options.trailSeconds
        let dt = 1 / max(1, options.face.fps)
        let frames = Int((total / dt).rounded(.up))
        var samples: [FaceSample] = []
        samples.reserveCapacity(frames + 1)
        for i in 0...frames {
            let t = Double(i) * dt
            var yaw = 0.0, pitch = 0.0, roll = 0.0
            if let seg = segments.last(where: { $0.start <= t }), t < seg.start + seg.ramp * 2 + seg.hold {
                let local = t - seg.start
                let amount: Double
                if local < seg.ramp {
                    amount = (1 - cos(.pi * local / seg.ramp)) / 2
                } else if local < seg.ramp + seg.hold {
                    amount = 1
                } else {
                    amount = (1 + cos(.pi * (local - seg.ramp - seg.hold) / seg.ramp)) / 2
                }
                switch seg.move {
                case .rotateLeft: yaw = options.yawDegrees * amount
                case .rotateRight: yaw = -options.yawDegrees * amount
                case .flexion: pitch = -options.pitchDegrees * amount
                case .extensionMove: pitch = options.pitchDegrees * amount
                case .tiltLeft: roll = options.rollDegrees * amount
                case .tiltRight: roll = -options.rollDegrees * amount
                }
            }
            samples.append(faceFrame(t: t, yaw: yaw, pitch: pitch, roll: roll, awayDegrees: 0,
                                     blinkL: options.face.blinkBaseline, blinkR: options.face.blinkBaseline,
                                     options: options.face, rng: &rng))
        }
        return samples
    }

    /// Cara neutra con un salto brusco de `jumpDegrees` de yaw en `atSecond` (cambio de cara/vídeo).
    static func faceTrackingJump(seconds: Double, jumpDegrees: Double = 90, atSecond: Double, options: FaceOptions = FaceOptions()) -> [FaceSample] {
        var rng = FixtureRandom(seed: options.seed)
        let dt = 1 / max(1, options.fps)
        let frames = Int((seconds / dt).rounded(.up))
        return (0...frames).map { i in
            let t = Double(i) * dt
            let yaw = t >= atSecond ? jumpDegrees : 0
            return faceFrame(t: t, yaw: yaw, pitch: 0, roll: 0, awayDegrees: 0,
                             blinkL: options.blinkBaseline, blinkR: options.blinkBaseline, options: options, rng: &rng)
        }
    }

    private static func faceFrame(t: Double, yaw: Double, pitch: Double, roll: Double, awayDegrees: Double,
                                  blinkL: Float, blinkR: Float, options: FaceOptions, rng: inout FixtureRandom) -> FaceSample {
        let n = options.angleNoise
        let camera = SIMD3<Float>(0, 0, options.cameraDistance)
        let away = Float(awayDegrees * .pi / 180)
        // Mirada: dirección a la cámara girada `away` grados alrededor del eje vertical, a 3 m si mira lejos.
        let length: Float = awayDegrees == 0 ? options.cameraDistance : 3
        let lookAt = SIMD3<Float>(sin(away) * length, 0, cos(away) * length)
        let energyNoise = options.shapeEnergy > 0 ? Float(rng.symmetric(Double(options.shapeEnergy) * 0.5)) : 0
        return FaceSample(
            t: t,
            isTracked: true,
            yaw: yaw + rng.symmetric(n),
            pitch: pitch + rng.symmetric(n),
            roll: roll + rng.symmetric(n),
            position: SIMD3<Float>(0, 0, -options.cameraDistance),
            cameraInFace: camera,
            lookAt: lookAt,
            blinkL: blinkL + Float(rng.symmetric(0.01)),
            blinkR: blinkR + Float(rng.symmetric(0.01)),
            shapeEnergy: max(0, options.shapeEnergy + energyNoise)
        )
    }

    // MARK: Pasos (podómetro + movimiento + actividad)

    nonisolated struct WalkOptions: Sendable, Hashable {
        /// Pasos por segundo (marcha normal 1,6-2,0; con dolor puede bajar a 0,8).
        var cadence: Double = 1.8
        var motionHz: Double = 50
        /// El coprocesador entrega acumulados cada ~3 s.
        var pedometerIntervalSeconds: Double = 3
        var activityIntervalSeconds: Double = 5
        /// Amplitud vertical de `userAccel` en g (marcha ≈ 0,3; sacudida ≈ 1,5).
        var accelAmplitudeG: Double = 0.3
        var accelNoiseG: Double = 0.03
        var seed: UInt64 = 1

        init() {}
    }

    /// Marcha real de `steps` pasos: podómetro que sube con la cadencia, acelerómetro oscilando al
    /// ritmo del paso y `CMMotionActivity` caminando con confianza alta.
    static func walk(steps: Int, options: WalkOptions = WalkOptions()) -> [StepSample] {
        let seconds = Double(max(0, steps)) / max(0.1, options.cadence)
        return stepStream(seconds: seconds, stepsPerSecond: options.cadence, walking: true,
                          amplitude: options.accelAmplitudeG, frequency: options.cadence, options: options)
    }

    /// Teléfono sacudido de pie: el podómetro sube rápido, el acelerómetro se dispara y la actividad
    /// del sistema dice `stationary` con confianza alta.
    static func shake(seconds: Double, options: WalkOptions = WalkOptions()) -> [StepSample] {
        stepStream(seconds: seconds, stepsPerSecond: 3.0, walking: false,
                   amplitude: 1.5, frequency: 4.0, options: options)
    }

    /// Quieto: podómetro plano, acelerómetro con ruido, actividad `stationary`.
    static func stationary(seconds: Double, options: WalkOptions = WalkOptions()) -> [StepSample] {
        stepStream(seconds: seconds, stepsPerSecond: 0, walking: false,
                   amplitude: 0, frequency: 0, options: options)
    }

    private static func stepStream(seconds: Double, stepsPerSecond: Double, walking: Bool,
                                   amplitude: Double, frequency: Double, options: WalkOptions) -> [StepSample] {
        var rng = FixtureRandom(seed: options.seed)
        var samples: [StepSample] = []

        // Movimiento a `motionHz`.
        let dt = 1 / max(1, options.motionHz)
        let motionFrames = Int((seconds / dt).rounded(.up))
        for i in 0...motionFrames {
            let t = Double(i) * dt
            let vertical = amplitude * sin(2 * .pi * frequency * t)
            let accel = SIMD3<Double>(rng.symmetric(options.accelNoiseG),
                                      vertical + rng.symmetric(options.accelNoiseG),
                                      rng.symmetric(options.accelNoiseG))
            let gravity = SIMD3<Double>(rng.symmetric(0.02), -1 + rng.symmetric(0.02), rng.symmetric(0.02))
            let rotation = SIMD3<Double>(rng.symmetric(0.1 + amplitude * 0.5), rng.symmetric(0.1), rng.symmetric(0.1))
            samples.append(.motion(MotionSample(t: t, userAccel: accel, gravity: gravity, rotationRate: rotation)))
        }

        // Podómetro acumulado cada `pedometerIntervalSeconds` (y una última muestra al final).
        var pedometerTimes = stride(from: 0, through: seconds, by: max(0.5, options.pedometerIntervalSeconds)).map { $0 }
        if pedometerTimes.last.map({ $0 < seconds }) ?? true { pedometerTimes.append(seconds) }
        var lastSteps = 0
        for t in pedometerTimes {
            let ideal = Int((stepsPerSecond * t).rounded(.down))
            let jitter = stepsPerSecond > 0 ? Int(rng.symmetric(1.4)) : 0
            let steps = max(lastSteps, ideal + jitter)
            lastSteps = steps
            let cadence: Double? = stepsPerSecond > 0 ? stepsPerSecond + rng.symmetric(0.05) : nil
            samples.append(.pedometer(PedometerSample(t: t, steps: steps, cadence: cadence,
                                                      distance: stepsPerSecond > 0 ? Double(steps) * 0.7 : 0)))
        }

        // Actividad del sistema cada `activityIntervalSeconds`.
        for t in stride(from: 0, through: seconds, by: max(0.5, options.activityIntervalSeconds)) {
            samples.append(.activity(ActivitySample(t: t, walking: walking, running: false, stationary: !walking,
                                                    automotive: false, unknown: false, confidence: 2)))
        }

        return samples.sorted { $0.t < $1.t }
    }
}
