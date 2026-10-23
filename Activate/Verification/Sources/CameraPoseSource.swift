import Foundation
import AVFoundation
import Vision
import CoreMedia
import ImageIO
import UIKit

// Dueño: agente "pose". Fuente de `PoseSample` sobre la cámara frontal: AVCaptureVideoDataOutput a 30 fps
// → Vision (VNDetectHumanBodyPoseRequest) síncrono en la cola "activate.pose" → PoseSample por AsyncStream.
// La ARSession de cara y esta sesión no pueden convivir: el coordinador hace stop() de una antes del start() de la otra.

/// Parámetros de captura (constantes nombradas).
nonisolated enum CameraPoseConfig {
    static let queueLabel = "activate.pose"
    static let targetFps: Int32 = 30
    static let sessionPreset: AVCaptureSession.Preset = .hd1280x720
    /// 420f: biplanar full range, el formato que Vision consume sin conversión.
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    /// Suavizado de la medición de fps.
    static let fpsAlpha = 0.2
    static let portraitRotation: CGFloat = 90
}

/// Fuente en vivo de poses (contrato `SampleSource`). Vive en MainActor; el trabajo pesado corre en la cola serial del delegate.
final class CameraPoseSource: SampleSource {
    typealias Sample = PoseSample

    let level: SourceLevel = .live
    private let capture = PoseCaptureDelegate()
    private var permissionTask: Task<Void, Never>?
    private(set) var isRunning = false

    /// Sesión para `CameraPreviewView` (solo lectura; la configura el delegate en su cola).
    var captureSession: AVCaptureSession { capture.session }

    init() {}

    /// Estado actual del permiso de cámara.
    static var authorizationStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    /// Pide el permiso de cámara (idealmente desde el preflight, nunca a mitad de la actividad).
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        @unknown default: return false
        }
    }

    /// Arranca la cámara y entrega poses hasta `stop()`. Si el permiso aún no se pidió, se pide y la
    /// captura parte al concederlo; si se niega, el stream termina sin muestras.
    func start() throws -> AsyncStream<PoseSample> {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            throw VerificationError.permissionDenied("cámara")
        case .authorized, .notDetermined:
            break
        @unknown default:
            throw VerificationError.permissionDenied("cámara")
        }
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil else {
            throw VerificationError.sensorUnavailable("cámara frontal")
        }

        let (stream, continuation) = AsyncStream<PoseSample>.makeStream(bufferingPolicy: .bufferingNewest(4))
        isRunning = true
        let capture = self.capture
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            capture.start(continuation: continuation)
        } else {
            permissionTask?.cancel()
            permissionTask = Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, self.isRunning, !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                if granted {
                    capture.start(continuation: continuation)
                } else {
                    continuation.finish()
                }
            }
        }
        return stream
    }

    func stop() {
        permissionTask?.cancel()
        permissionTask = nil
        isRunning = false
        capture.stop()
    }
}

// MARK: - Delegate de captura (cola serial propia, Vision síncrono)

/// Todo el estado mutable se toca solo en `queue`. `AVCaptureSession` se configura y arranca en esa cola
/// (`startRunning()` bloquea). Convierte `VNHumanBodyPoseObservation` → `PoseSample` en el límite.
nonisolated final class PoseCaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: CameraPoseConfig.queueLabel, qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private let request = VNDetectHumanBodyPoseRequest()

    // Estado de la cola.
    private var configured = false
    private var configurationFailed = false
    private var continuation: AsyncStream<PoseSample>.Continuation?
    private var clockStart: ContinuousClock.Instant?
    private var lastFrameT: Double?
    private var fps: Double = 0
    private var orientation: CGImagePropertyOrientation = .up

    func start(continuation: AsyncStream<PoseSample>.Continuation) {
        queue.async { [self] in
            self.continuation?.finish()
            self.continuation = continuation
            self.clockStart = ContinuousClock.now
            self.lastFrameT = nil
            self.fps = 0
            if !self.configured { self.configure() }
            guard !self.configurationFailed else {
                continuation.finish()
                return
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if self.session.isRunning { self.session.stopRunning() }
            self.continuation?.finish()
            self.continuation = nil
            self.clockStart = nil
        }
    }

    // MARK: Configuración (en `queue`)

    private func configure() {
        configured = true
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else {
            configurationFailed = true
            return
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(CameraPoseConfig.sessionPreset) {
            session.sessionPreset = CameraPoseConfig.sessionPreset
        }
        guard session.canAddInput(input) else {
            configurationFailed = true
            return
        }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: CameraPoseConfig.pixelFormat]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            configurationFailed = true
            return
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(CameraPoseConfig.portraitRotation) {
                // Buffers ya en vertical y espejados como el preview: Vision los lee tal cual.
                connection.videoRotationAngle = CameraPoseConfig.portraitRotation
                orientation = .up
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            } else {
                // Buffer apaisado nativo del sensor frontal, sin espejo: Vision lo gira al leerlo.
                orientation = .leftMirrored
            }
        }

        configureFrameRate(device)
    }

    private func configureFrameRate(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let target = Double(CameraPoseConfig.targetFps)
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= target && target <= $0.maxFrameRate }
        guard supported else { return }
        let duration = CMTime(value: 1, timescale: CameraPoseConfig.targetFps)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate (en `queue`)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let continuation, let clockStart else { return }
        let t = Self.seconds(clockStart.duration(to: .now))
        if let last = lastFrameT, t > last {
            let instant = 1 / (t - last)
            fps = fps == 0 ? instant : fps + CameraPoseConfig.fpsAlpha * (instant - fps)
        }
        lastFrameT = t

        var joints: [JointKey: JointPoint] = [:]
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: orientation, options: [:])
        if (try? handler.perform([request])) != nil, let observation = Self.mainObservation(request.results) {
            joints = Self.joints(from: observation)
        }
        continuation.yield(PoseSample(t: t, joints: joints, fps: fps))
    }

    // MARK: Conversión Vision → dominio

    private static var jointMap: [(JointKey, VNHumanBodyPoseObservation.JointName)] { [
        (.nose, .nose), (.neck, .neck), (.root, .root),
        (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftHip, .leftHip), (.rightHip, .rightHip),
        (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
    ] }

    /// Con más de una persona en cuadro se queda con la de mayor confianza (la más cercana suele ganar).
    static func mainObservation(_ results: [VNHumanBodyPoseObservation]?) -> VNHumanBodyPoseObservation? {
        results?.max { $0.confidence < $1.confidence }
    }

    static func joints(from observation: VNHumanBodyPoseObservation) -> [JointKey: JointPoint] {
        guard let points = try? observation.recognizedPoints(.all) else { return [:] }
        var joints: [JointKey: JointPoint] = [:]
        for (key, name) in jointMap {
            guard let p = points[name] else { continue }
            // `location` normalizada 0-1 con origen abajo-izquierda (convención Vision), igual que `JointPoint`.
            joints[key] = JointPoint(x: Double(p.location.x), y: Double(p.location.y), confidence: p.confidence)
        }
        return joints
    }

    static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

// MARK: - Sentadilla "Apoyado": cámara + deviceMotion

/// Fuente del modo apoyado de la sentadilla (agente "squats"): las poses de `CameraPoseSource` más el
/// deviceMotion del `SensorHub` (único dueño de CMMotionManager) para probar que el teléfono está quieto.
/// Sin deviceMotion no se puede descartar el teléfono en la mano: la fuente se declara `.fallback`.
final class SupportedSquatSource: SampleSource {
    typealias Sample = SupportedSquatSample

    static let bufferedSamples = 256

    let camera: CameraPoseSource
    private let hub: SensorHub?
    private let consumer = UUID()
    private var forwarders: [Task<Void, Never>] = []
    private var continuation: AsyncStream<SupportedSquatSample>.Continuation?
    private var previousIdleTimerDisabled = false
    private(set) var level: SourceLevel = .live
    private(set) var isRunning = false

    /// Sesión para `CameraPreviewView`.
    var captureSession: AVCaptureSession { camera.captureSession }

    init(camera: CameraPoseSource, hub: SensorHub?) {
        self.camera = camera
        self.hub = hub
    }

    func start() throws -> AsyncStream<SupportedSquatSample> {
        stop()
        let poses = try camera.start()
        hub?.refreshAvailability()
        let motionAvailable = hub?.isDeviceMotionAvailable == true
        level = motionAvailable ? .live : .fallback

        let (stream, continuation) = AsyncStream.makeStream(of: SupportedSquatSample.self,
                                                            bufferingPolicy: .bufferingNewest(Self.bufferedSamples))
        self.continuation = continuation
        forwarders.append(Task.detached {
            for await p in poses { continuation.yield(.pose(p)) }
            continuation.finish()
        })
        if let hub, motionAvailable {
            let motion = hub.startMotion(for: consumer, origin: .now)
            forwarders.append(Task.detached {
                for await m in motion { continuation.yield(.motion(m)) }
            })
        }
        // La persona está a 2 m y no toca la pantalla: sin esto el bloqueo automático corta la cámara.
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        isRunning = true
        return stream
    }

    func stop() {
        guard isRunning || continuation != nil else { return }
        forwarders.forEach { $0.cancel() }
        forwarders = []
        hub?.stopMotion(for: consumer)
        camera.stop()
        continuation?.finish()
        continuation = nil
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        isRunning = false
    }
}
