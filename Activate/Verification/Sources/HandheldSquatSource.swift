import ARKit
import AVFoundation
import Foundation
import Observation
import UIKit
import simd

// Dueño: agente "squats". Fuente en vivo de la sentadilla EN LAS MANOS: una `ARSession` propia (no la de
// `FaceSource`) con `ARFaceTrackingConfiguration` (una cara, TrueDepth) y, cuando el equipo lo soporta,
// `isWorldTrackingEnabled = true`: la cámara trasera + IMU dan la pose 6DOF del teléfono en el mundo
// (`worldAlignment = .gravity`, eje Y hacia arriba) mientras la frontal sigue la cara.
//
// En cada `ARFrame` (cola serial propia del delegate) se convierte a `HandheldSquatSample`: posición del
// teléfono (`camera.transform`), cara en el mundo (`ARFaceAnchor.transform`) y en el espacio del teléfono
// (`camera⁻¹ · face`), cabeceo de la cabeza respecto de la gravedad (eje +Z de la cara en el mundo
// alineado a la gravedad), relieve 3D de la cara en el mapa de profundidad TrueDepth
// (`frame.capturedDepthData`, ≈ 15 Hz, ver `FaceReliefEstimator`), energía de 8 blendShapes, estado del
// seguimiento del mundo y lo último del `SensorHub` (gravedad y aceleración vertical de deviceMotion,
// altímetro, podómetro). Nada de ARKit sale de este archivo. `ARSession` y `AVCaptureSession` no conviven:
// el coordinador / `SquatRunner` hacen `stop()` de una antes del `start()` de la otra.

/// `SampleSource` de la sentadilla en las manos. Vive en MainActor; el trabajo corre en la cola del relay.
@Observable
final class HandheldSquatSource: SampleSource {
    typealias Sample = HandheldSquatSample

    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }
    /// Cara + mundo a la vez (TrueDepth + cámara trasera). Se verifica en runtime al arrancar.
    static var supportsWorldTracking: Bool { ARFaceTrackingConfiguration.supportsWorldTracking }
    static let unsupportedMessage = "Este teléfono no puede seguir la cara"
    static let deniedMessage = "Active la cámara en Ajustes"
    static let bufferedSamples = 64

    /// Última muestra (≈ 10 Hz) para el texto de depuración de la demo; nil si no se publica.
    private(set) var telemetry: HandheldSquatSample?
    private(set) var isRunning = false

    @ObservationIgnored let publishesTelemetry: Bool
    @ObservationIgnored private let hub: SensorHub?
    @ObservationIgnored private let consumer = UUID()
    @ObservationIgnored private var session: ARSession?
    @ObservationIgnored private var relay: HandheldSquatRelay?
    @ObservationIgnored private var forwarders: [Task<Void, Never>] = []
    @ObservationIgnored private var continuation: AsyncStream<HandheldSquatSample>.Continuation?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var worldTrackingSupported = false
    @ObservationIgnored private var lastStats = HandheldSquatSourcePolicy.Stats()
    @ObservationIgnored private var previousIdleTimerDisabled = false

    /// - Parameters:
    ///   - hub: dueño de CoreMotion (deviceMotion, altímetro, podómetro); nil = solo ARKit.
    ///   - publishesTelemetry: publica `telemetry` para la depuración de la demo.
    init(hub: SensorHub?, publishesTelemetry: Bool = false) {
        self.hub = hub
        self.publishesTelemetry = publishesTelemetry
    }

    /// `.live` con seguimiento del mundo sostenido; `.fallback` si el equipo no lo soporta o si la serie
    /// se midió sobre todo con el respaldo IMU (cámara trasera tapada, poca luz).
    var level: SourceLevel {
        HandheldSquatSourcePolicy.level(worldTrackingSupported: worldTrackingSupported, stats: relay?.stats ?? lastStats)
    }

    // MARK: SampleSource

    func start() throws -> AsyncStream<HandheldSquatSample> {
        guard Self.isSupported else { throw VerificationError.sensorUnavailable(Self.unsupportedMessage) }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted {
            throw VerificationError.permissionDenied(Self.deniedMessage)
        }
        stop()

        worldTrackingSupported = Self.supportsWorldTracking
        lastStats = HandheldSquatSourcePolicy.Stats()
        let (stream, continuation) = AsyncStream.makeStream(of: HandheldSquatSample.self,
                                                            bufferingPolicy: .bufferingNewest(Self.bufferedSamples))
        let tap = HandheldMotionTap()
        let relay = HandheldSquatRelay(continuation: continuation, tap: tap, worldTracking: worldTrackingSupported)
        if publishesTelemetry {
            relay.onTelemetry = { [weak self] sample in
                guard let self else { return }
                Task { @MainActor in self.telemetry = sample }
            }
        }
        let session = ARSession()
        session.delegate = relay
        session.delegateQueue = relay.queue
        self.session = session
        self.relay = relay
        self.continuation = continuation
        generation += 1
        let gen = generation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.generation == gen { self.stop() }
            }
        }
        startMotionSensors(tap)
        keepScreenAwake()

        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    guard self.generation == gen, let session = self.session else { return }
                    if granted { self.run(session) } else { self.stop() }
                }
            }
        } else {
            run(session)
        }
        return stream
    }

    func stop() {
        guard session != nil || continuation != nil else { return }
        if let relay { lastStats = relay.stats }
        session?.pause()
        session?.delegate = nil
        session?.delegateQueue = nil
        session = nil
        relay?.invalidate()
        relay = nil
        forwarders.forEach { $0.cancel() }
        forwarders = []
        hub?.stopMotion(for: consumer)
        hub?.stopRelativeAltitude(for: consumer)
        hub?.stopPedometer(for: consumer)
        continuation?.finish()
        continuation = nil
        isRunning = false
        restoreScreenTimer()
    }

    // MARK: Interno

    private func run(_ session: ARSession) {
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isLightEstimationEnabled = false
        configuration.worldAlignment = .gravity
        if worldTrackingSupported { configuration.isWorldTrackingEnabled = true }
        relay?.resetClock()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    /// deviceMotion (gravedad + aceleración vertical + RMS), altímetro y podómetro del `SensorHub`.
    /// El podómetro y el altímetro solo con el permiso ya concedido (no se pide a mitad de la pausa).
    private func startMotionSensors(_ tap: HandheldMotionTap) {
        guard let hub else { return }
        hub.refreshAvailability()
        let origin = ContinuousClock.now
        if hub.isDeviceMotionAvailable {
            let motion = hub.startMotion(for: consumer, origin: origin)
            forwarders.append(Task.detached { for await m in motion { tap.add(m) } })
        }
        guard hub.isMotionAuthorized else { return }
        if hub.isAltimeterAvailable {
            let altitude = hub.startRelativeAltitude(for: consumer, origin: origin)
            forwarders.append(Task.detached { for await a in altitude { tap.setAltitude(a.relativeAltitude) } })
        }
        if hub.isPedometerAvailable {
            let steps = hub.startPedometer(for: consumer, from: .now, origin: origin)
            forwarders.append(Task.detached { for await p in steps { tap.setSteps(p.steps) } })
        }
    }

    /// Nadie toca la pantalla durante la serie: sin esto el bloqueo automático corta la cámara.
    private func keepScreenAwake() {
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func restoreScreenTimer() {
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    }
}

// MARK: - Último dato de CoreMotion (seguro desde cualquier cola)

/// Guarda lo último de deviceMotion / altímetro / podómetro; el relay lo lee en cada ARFrame.
nonisolated final class HandheldMotionTap: @unchecked Sendable {
    nonisolated struct Reading: Sendable {
        var gravity: SIMD3<Double>?
        var verticalAccel: Double?
        var accelRMS: Double?
        var altitude: Double?
        var steps: Int?
    }

    static let standardGravity = 9.80665
    static let rmsWindowSeconds = 0.5

    private let lock = NSLock()
    private var gravity: SIMD3<Double>?
    private var verticalSum = 0.0
    private var verticalCount = 0
    private var lastVertical: Double?
    private var magnitudes: [(t: Double, m2: Double)] = []
    private var altitude: Double?
    private var steps: Int?

    func add(_ m: MotionSample) {
        let length = simd_length(m.gravity)
        // userAcceleration y gravity vienen en g; la gravedad apunta hacia abajo: arriba = −ĝ.
        let up = length > 0 ? -simd_dot(m.userAccel, m.gravity / length) * Self.standardGravity : 0
        lock.lock()
        gravity = m.gravity
        verticalSum += up
        verticalCount += 1
        lastVertical = up
        magnitudes.append((m.t, simd_length_squared(m.userAccel)))
        while let first = magnitudes.first, first.t < m.t - Self.rmsWindowSeconds { magnitudes.removeFirst() }
        lock.unlock()
    }

    func setAltitude(_ value: Double) {
        lock.lock()
        altitude = value
        lock.unlock()
    }

    func setSteps(_ value: Int) {
        lock.lock()
        steps = value
        lock.unlock()
    }

    /// Lectura para un frame: la aceleración vertical es el promedio desde la lectura anterior.
    func read() -> Reading {
        lock.lock()
        defer { lock.unlock() }
        let vertical = verticalCount > 0 ? verticalSum / Double(verticalCount) : lastVertical
        verticalSum = 0
        verticalCount = 0
        let rms: Double? = magnitudes.isEmpty ? nil : (magnitudes.reduce(0) { $0 + $1.m2 } / Double(magnitudes.count)).squareRoot()
        return Reading(gravity: gravity, verticalAccel: vertical, accelRMS: rms, altitude: altitude, steps: steps)
    }
}

// MARK: - Delegate (fuera del main actor)

/// Recibe los ARFrame en `queue`, los convierte a `HandheldSquatSample` y los publica por el stream.
nonisolated final class HandheldSquatRelay: NSObject, ARSessionDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "cl.activate.handheld-squat", qos: .userInteractive)

    /// Mismos 8 blendShapes que la fuente de cara (orden fijo).
    static let energyShapes: [ARFaceAnchor.BlendShapeLocation] = [
        .eyeBlinkLeft, .eyeBlinkRight, .jawOpen, .mouthSmileLeft, .mouthSmileRight,
        .browInnerUp, .eyeSquintLeft, .eyeSquintRight,
    ]
    /// Cada cuántos frames se publica la telemetría de depuración (60 Hz / 6 ≈ 10 Hz).
    static let telemetryEveryFrames = 6
    /// Cada cuántos mapas de profundidad nuevos se mide el relieve (≈ 15 Hz / 2 ≈ 7 Hz).
    static let reliefEveryDepthMaps = 2

    let worldTracking: Bool
    /// Llamado en `queue` con una muestra cada `telemetryEveryFrames`.
    var onTelemetry: (@Sendable (HandheldSquatSample) -> Void)?

    private let tap: HandheldMotionTap
    private let statsLock = NSLock()
    private var _stats = HandheldSquatSourcePolicy.Stats()

    // Estado solo tocado en `queue`.
    private var continuation: AsyncStream<HandheldSquatSample>.Continuation?
    private var startInstant = ContinuousClock.now
    private var firstFrameTimestamp: TimeInterval?
    private var firstFrameOffset = 0.0
    private var previousShapes: [Float]?
    private var frameIndex = 0
    private var lastDepthTimestamp: TimeInterval = -1
    private var depthMapIndex = 0
    /// Último relieve medido (para la telemetría de depuración, que no coincide con los frames de profundidad).
    private var lastRelief: Float?

    init(continuation: AsyncStream<HandheldSquatSample>.Continuation, tap: HandheldMotionTap, worldTracking: Bool) {
        self.continuation = continuation
        self.tap = tap
        self.worldTracking = worldTracking
        super.init()
    }

    /// Frames con cara desde que el mundo llegó a `.normal` (para el nivel de la fuente).
    var stats: HandheldSquatSourcePolicy.Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _stats
    }

    func resetClock() {
        queue.sync {
            startInstant = .now
            firstFrameTimestamp = nil
            previousShapes = nil
            frameIndex = 0
            lastDepthTimestamp = -1
            depthMapIndex = 0
            lastRelief = nil
        }
        statsLock.lock()
        _stats = HandheldSquatSourcePolicy.Stats()
        statsLock.unlock()
    }

    func invalidate() {
        queue.sync {
            continuation?.finish()
            continuation = nil
            onTelemetry = nil
        }
    }

    // MARK: ARSessionDelegate (llega en `queue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let continuation else { return }
        let t = time(for: frame.timestamp)
        let camera = frame.camera.transform
        var normal = false
        if worldTracking, case .normal = frame.camera.trackingState { normal = true }
        let face = frame.anchors.lazy.compactMap { $0 as? ARFaceAnchor }.first(where: { $0.isTracked })
        let motion = tap.read()

        let attitude = motion.gravity.map(Self.attitude(gravity:)) ?? Self.attitude(camera: camera)
        let phone = camera.columns.3
        var facePos = SIMD3<Float>(repeating: 0)
        var faceInPhone = SIMD3<Float>(repeating: 0)
        var energy: Float = 0
        var headPitch: Double? = nil
        var relief: Float? = nil
        if let face {
            let p = face.transform.columns.3
            facePos = SIMD3(p.x, p.y, p.z)
            headPitch = Self.headPitch(face: face.transform)
            relief = reliefIfNewDepth(frame)
            let rel = (camera.inverse * face.transform).columns.3
            faceInPhone = SIMD3(rel.x, rel.y, rel.z)
            let shapes = face.blendShapes
            let current = Self.energyShapes.map { shapes[$0]?.floatValue ?? 0 }
            if let previousShapes, previousShapes.count == current.count {
                energy = zip(current, previousShapes).reduce(0) { $0 + abs($1.0 - $1.1) }
            }
            previousShapes = current
        } else {
            previousShapes = nil
        }

        let sample = HandheldSquatSample(
            t: t,
            phonePos: SIMD3(phone.x, phone.y, phone.z),
            phonePitchDeg: attitude.pitch,
            phoneRollDeg: attitude.roll,
            faceTracked: face != nil,
            facePos: facePos,
            faceInPhone: faceInPhone,
            shapeEnergy: energy,
            worldTrackingNormal: normal,
            altitude: motion.altitude,
            userAccelRMS: motion.accelRMS,
            verticalAccel: motion.verticalAccel,
            steps: motion.steps,
            headPitchDeg: headPitch,
            faceRelief: relief)

        statsLock.lock()
        if normal { _stats.everNormal = true }
        if _stats.everNormal, face != nil {
            _stats.countedFrames += 1
            if normal { _stats.normalFrames += 1 }
        }
        statsLock.unlock()

        continuation.yield(sample)
        frameIndex += 1
        if let relief { lastRelief = relief }
        if frameIndex % Self.telemetryEveryFrames == 0 {
            var telemetry = sample
            telemetry.faceRelief = relief ?? lastRelief
            onTelemetry?(telemetry)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        continuation?.finish()
        continuation = nil
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // Sin frames no hay muestras: el coordinador reinicia la actividad al volver (backgrounded).
    }

    // MARK: Conversión

    /// Relieve de la cara si este frame trae un mapa de profundidad nuevo (uno de cada
    /// `reliefEveryDepthMaps`); nil en los demás.
    private func reliefIfNewDepth(_ frame: ARFrame) -> Float? {
        guard let depth = frame.capturedDepthData, frame.capturedDepthDataTimestamp != lastDepthTimestamp else { return nil }
        lastDepthTimestamp = frame.capturedDepthDataTimestamp
        depthMapIndex += 1
        guard depthMapIndex % Self.reliefEveryDepthMaps == 0 else { return nil }
        return Self.relief(depth)
    }

    /// Profundidad en metros (Float32) → `FaceReliefEstimator`. nil si el formato no es el esperado.
    static func relief(_ data: AVDepthData) -> Float? {
        let depth = data.depthDataType == kCVPixelFormatType_DepthFloat32
            ? data : data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = depth.depthDataMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let stride = MemoryLayout<Float32>.stride
        guard width > 0, height > 0, rowBytes >= width * stride else { return nil }
        return FaceReliefEstimator.relief(width: width, height: height) { x, y in
            base.loadUnaligned(fromByteOffset: y * rowBytes + x * stride, as: Float32.self)
        }
    }

    /// Cabeceo de la cabeza respecto de la gravedad (°): elevación del eje +Z del `ARFaceAnchor` (sale de
    /// la cara) en el mundo con `worldAlignment = .gravity` (Y arriba). Negativo = la cara mira hacia abajo.
    static func headPitch(face transform: simd_float4x4) -> Double? {
        let z = transform.columns.2
        let length = simd_length(SIMD3(z.x, z.y, z.z))
        guard length > 0 else { return nil }
        return asin(Double(max(-1, min(1, z.y / length)))) * 180 / .pi
    }

    /// Tiempo monotónico: el primer frame se ancla al ContinuousClock; los siguientes usan el timestamp
    /// de captura de ARKit (dt exacto para integrar).
    private func time(for timestamp: TimeInterval) -> Double {
        if let first = firstFrameTimestamp {
            return firstFrameOffset + (timestamp - first)
        }
        let d = startInstant.duration(to: .now).components
        firstFrameOffset = Double(d.seconds) + Double(d.attoseconds) / 1e18
        firstFrameTimestamp = timestamp
        return firstFrameOffset
    }

    /// Cabeceo (pantalla hacia arriba > 0) y giro en el plano de la pantalla, desde la gravedad de
    /// CoreMotion en ejes del dispositivo (x derecha, y arriba, z hacia la persona).
    static func attitude(gravity g: SIMD3<Double>) -> (pitch: Double, roll: Double) {
        let length = simd_length(g)
        guard length > 0 else { return (0, 0) }
        let n = g / length
        let k = 180 / Double.pi
        return (asin(max(-1, min(1, -n.z))) * k, atan2(n.x, -n.y) * k)
    }

    /// Respaldo sin deviceMotion: el eje óptico de la cámara (columna 2) es perpendicular a la pantalla,
    /// así que su elevación es ± el cabeceo; el verificador solo usa cambios respecto de la referencia.
    static func attitude(camera: simd_float4x4) -> (pitch: Double, roll: Double) {
        let z = camera.columns.2
        let x = camera.columns.0
        let y = camera.columns.1
        let k = 180 / Double.pi
        let pitch = asin(Double(max(-1, min(1, z.y)))) * k
        let roll = atan2(Double(-y.y), Double(-x.y)) * k
        return (pitch, roll)
    }
}
