import SwiftUI
import AVFoundation

// Dueño: agente "pose". Preview de la cámara frontal para las actividades de cuerpo entero.
// Contenido plano (sin vidrio): el HUD con el contador va encima, en la capa funcional.

/// Muestra la `AVCaptureSession` de `CameraPoseSource` con `AVCaptureVideoPreviewLayer`
/// (relleno proporcional, espejado como un selfie, vertical).
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.attach(session)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.attach(session) }
    }

    static func dismantleUIView(_ uiView: CameraPreviewUIView, coordinator: ()) {
        uiView.detach()
    }
}

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var startObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    func attach(_ session: AVCaptureSession) {
        detach()
        previewLayer.session = session
        configureConnection()
        // La sesión se configura en la cola de captura: la conexión del preview aparece al arrancar.
        startObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureConnection() }
        }
    }

    func detach() {
        if let startObserver { NotificationCenter.default.removeObserver(startObserver) }
        startObserver = nil
        previewLayer.session = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        configureConnection()
    }

    /// Vertical y espejado (frontal). Inofensivo si la conexión aún no existe.
    private func configureConnection() {
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(CameraPoseConfig.portraitRotation),
           connection.videoRotationAngle != CameraPoseConfig.portraitRotation {
            connection.videoRotationAngle = CameraPoseConfig.portraitRotation
        }
        if connection.isVideoMirroringSupported, !connection.automaticallyAdjustsVideoMirroring {
            connection.isVideoMirrored = true
        }
    }
}
