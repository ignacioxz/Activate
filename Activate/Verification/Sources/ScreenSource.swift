import Foundation

// Dueño: paquete "stroop-breath".

/// Fuente de muestras de pantalla (Stroop A10, respiración A8). No hay sensor: la vista la alimenta
/// con `push(_:)` y el runner consume el `AsyncStream` que devuelve `start()`.
///
/// Tiempo: `start()` fija el origen con `ContinuousClock`; la vista estampa cada muestra con
/// `elapsedMs` (Stroop, enteros en ms) o `elapsedSeconds` (respiración), de modo que verificador y
/// vista comparten una sola base de tiempo monotónica. Las muestras enviadas antes de `start()` o
/// después de `stop()` se descartan.
final class ScreenSource: SampleSource {
    typealias Sample = ScreenSample

    let level: SourceLevel = .live

    private var continuation: AsyncStream<ScreenSample>.Continuation?
    private var origin: ContinuousClock.Instant?

    init() {}

    /// `true` entre `start()` y `stop()`.
    var isActive: Bool { continuation != nil }

    func start() throws -> AsyncStream<ScreenSample> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: ScreenSample.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        origin = ContinuousClock.now
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    /// La vista entrega una interacción. Se ignora si la fuente no está activa.
    func push(_ sample: ScreenSample) {
        continuation?.yield(sample)
    }

    // MARK: - Reloj compartido con la vista

    /// Tiempo desde `start()` (cero si aún no arrancó).
    var elapsed: Duration {
        guard let origin else { return .zero }
        return origin.duration(to: ContinuousClock.now)
    }

    var elapsedSeconds: Double { elapsed.seconds }

    /// Milisegundos enteros desde `start()`, para `StroopTrial.shownAtMs` / `answeredAtMs`.
    var elapsedMs: Int { Int((elapsed.seconds * 1000).rounded()) }
}

nonisolated extension Duration {
    /// Segundos con fracción (attosegundos → segundos).
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
