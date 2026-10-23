import ARKit
import AVFoundation
import Foundation
import simd

// Dueño: agente "face". Fuente en vivo de `FaceSample` sobre una `ARSession` sin renderizar.
// Conversión en el límite (cola serial propia) a structs Sendable; nada de ARKit sale de este archivo.

// MARK: - Matemática de la cara (pura; también la usa el replay y los tests)

nonisolated enum FaceSampleMath {
    /// Ángulos de Tait-Bryan (grados) de la rotación `R = Ry(yaw) · Rx(−pitch) · Rz(roll)` de una transform de cara.
    /// Sistema de la cara de ARKit: +X = izquierda de la propia cara (derecha de quien la mira), +Y = arriba,
    /// +Z = sale de la cara por la nariz (hacia la cámara). Columnas de la transform = ejes de la cara en el mundo.
    /// - yaw > 0: la nariz gira hacia +X → la persona gira hacia SU izquierda.
    /// - pitch > 0: la nariz sube → mira arriba.
    /// - roll > 0: el lado izquierdo de la cara sube → oreja derecha al hombro derecho.
    /// La descomposición la hace `HeadPose` (fuente única, verificada con rotaciones puras de 30° en los tests);
    /// si el dispositivo invierte algún eje, `NeckVerifier` lo autocorrige.
    static func angles(from transform: simd_float4x4) -> (yaw: Double, pitch: Double, roll: Double) {
        let c0 = transform.columns.0, c1 = transform.columns.1, c2 = transform.columns.2
        let m = simd_double3x3(columns: (SIMD3(Double(c0.x), Double(c0.y), Double(c0.z)),
                                         SIMD3(Double(c1.x), Double(c1.y), Double(c1.z)),
                                         SIMD3(Double(c2.x), Double(c2.y), Double(c2.z))))
        return HeadPose.angles(from: m)
    }

    /// Posición de la cámara expresada en el espacio de la cara: `(face⁻¹ · camera).columns.3`.
    static func cameraInFace(face: simd_float4x4, camera: simd_float4x4) -> SIMD3<Float> {
        let c = (face.inverse * camera).columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    /// Suma de |Δ| entre dos vectores de blendShapes (misma longitud y orden).
    static func shapeEnergy(current: [Float], previous: [Float]?) -> Float {
        guard let previous, previous.count == current.count else { return 0 }
        return zip(current, previous).reduce(0) { $0 + abs($1.0 - $1.1) }
    }
}

// MARK: - Fuente

/// `SampleSource` de cara: `ARFaceTrackingConfiguration` con una sola cara, sin vista, delegate en cola propia.
/// Pide permiso de cámara si aún no se decidió; lanza `sensorUnavailable` si el teléfono no soporta face tracking
/// y `permissionDenied` si la cámara está denegada o restringida.
@MainActor
final class FaceSource: SampleSource {
    typealias Sample = FaceSample

    nonisolated let level: SourceLevel = .live

    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }
    static var cameraAuthorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    /// Para pedir el permiso con calma (preflight / onboarding), nunca a mitad de la demo.
    static func requestCameraAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

    static let unsupportedMessage = "Este teléfono no puede seguir la cara"
    static let deniedMessage = "Active la cámara en Ajustes"
    private static let bufferedSamples = 32

    private var session: ARSession?
    private var relay: FaceSessionRelay?
    private var continuation: AsyncStream<FaceSample>.Continuation?
    private var generation = 0
    private(set) var isRunning = false

    init() {}

    func start() throws -> AsyncStream<FaceSample> {
        guard Self.isSupported else { throw VerificationError.sensorUnavailable(Self.unsupportedMessage) }
        let status = Self.cameraAuthorization
        if status == .denied || status == .restricted {
            throw VerificationError.permissionDenied(Self.deniedMessage)
        }
        stop()

        let (stream, continuation) = AsyncStream.makeStream(of: FaceSample.self,
                                                            bufferingPolicy: .bufferingNewest(Self.bufferedSamples))
        let relay = FaceSessionRelay(continuation: continuation)
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
        session?.pause()
        session?.delegate = nil
        session?.delegateQueue = nil
        session = nil
        relay?.invalidate()
        relay = nil
        continuation?.finish()
        continuation = nil
        isRunning = false
    }

    private func run(_ session: ARSession) {
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isLightEstimationEnabled = false
        relay?.resetClock()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }
}

// MARK: - Delegate (fuera del main actor)

/// Recibe los callbacks de ARKit en `queue`, convierte `ARFaceAnchor` a `FaceSample` y publica por el stream.
nonisolated final class FaceSessionRelay: NSObject, ARSessionDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "cl.activate.face-source", qos: .userInteractive)

    /// Orden fijo de los 8 blendShapes que alimentan `shapeEnergy`.
    static let energyShapes: [ARFaceAnchor.BlendShapeLocation] = [
        .eyeBlinkLeft, .eyeBlinkRight, .jawOpen, .mouthSmileLeft, .mouthSmileRight,
        .browInnerUp, .eyeSquintLeft, .eyeSquintRight,
    ]
    /// Si ARKit deja de actualizar el anchor (cara perdida), se emite una muestra `isTracked == false` cada tanto
    /// para que el verificador pueda medir la pérdida.
    static let heartbeatAfterSeconds: Double = 0.25
    static let heartbeatIntervalSeconds: Double = 0.1

    // Estado solo tocado en `queue`.
    private var continuation: AsyncStream<FaceSample>.Continuation?
    private var startInstant = ContinuousClock.now
    private var previousShapes: [Float]?
    private var lastCameraTransform: simd_float4x4?
    private var lastSample: FaceSample?
    private var lastAnchorT: Double = -1
    private var lastHeartbeatT: Double = -1

    init(continuation: AsyncStream<FaceSample>.Continuation) {
        self.continuation = continuation
        super.init()
    }

    func resetClock() {
        queue.sync {
            startInstant = .now
            previousShapes = nil
            lastSample = nil
            lastAnchorT = -1
            lastHeartbeatT = -1
        }
    }

    func invalidate() {
        queue.sync {
            continuation?.finish()
            continuation = nil
        }
    }

    private var elapsed: Double {
        let d = startInstant.duration(to: .now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }

    // MARK: ARSessionDelegate (llega en `queue`)

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        let camera = session.currentFrame?.camera.transform ?? lastCameraTransform
        let t = elapsed
        let sample = makeSample(face, camera: camera, t: t)
        lastAnchorT = t
        lastSample = sample
        continuation?.yield(sample)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lastCameraTransform = frame.camera.transform
        let t = elapsed
        guard lastAnchorT >= 0, t - lastAnchorT > Self.heartbeatAfterSeconds,
              t - lastHeartbeatT >= Self.heartbeatIntervalSeconds, var sample = lastSample else { return }
        lastHeartbeatT = t
        sample.t = t
        sample.isTracked = false
        sample.shapeEnergy = 0
        continuation?.yield(sample)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        continuation?.finish()
        continuation = nil
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // Sin frames no hay muestras; la UI reinicia la actividad al volver (IntegrityMonitor → backgrounded).
    }

    // MARK: Conversión

    private func makeSample(_ anchor: ARFaceAnchor, camera: simd_float4x4?, t: Double) -> FaceSample {
        let transform = anchor.transform
        let angles = FaceSampleMath.angles(from: transform)
        let shapes = anchor.blendShapes
        let current = Self.energyShapes.map { shapes[$0]?.floatValue ?? 0 }
        let energy = FaceSampleMath.shapeEnergy(current: current, previous: previousShapes)
        previousShapes = current
        let p = transform.columns.3
        let cameraInFace = camera.map { FaceSampleMath.cameraInFace(face: transform, camera: $0) } ?? SIMD3<Float>(0, 0, 0)
        return FaceSample(
            t: t,
            isTracked: anchor.isTracked,
            yaw: angles.yaw,
            pitch: angles.pitch,
            roll: angles.roll,
            position: SIMD3(p.x, p.y, p.z),
            cameraInFace: cameraInFace,
            lookAt: anchor.lookAtPoint,
            blinkL: shapes[.eyeBlinkLeft]?.floatValue ?? 0,
            blinkR: shapes[.eyeBlinkRight]?.floatValue ?? 0,
            shapeEnergy: energy
        )
    }
}
