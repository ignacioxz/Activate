import Foundation

// Dueño: agente "runtime".
//
// `ReplaySource` reproduce una lista de muestras respetando su `t` (segundos desde el inicio),
// acelerable con `speed`. Es la única fuente disponible en Simulator y en tests, y declara
// `level == .replay`: todo lo que pase por ella termina con `VerificationLevel.simulated`,
// aunque la máquina de estados sea exactamente la misma que en vivo.

// MARK: - Muestras con tiempo

/// Muestra que trae su propio instante `t` (segundos desde el inicio de la actividad).
/// `ReplaySource` la usa para programar la reproducción y `ActivityRunner` para pasar `at:` al
/// verificador (así un fixture reproducido a 10× conserva sus tiempos originales).
nonisolated protocol TimedSample: Sendable {
    var t: Double { get }
}

extension PoseSample: TimedSample {}
extension FaceSample: TimedSample {}
extension MotionSample: TimedSample {}
extension PedometerSample: TimedSample {}
extension ActivitySample: TimedSample {}

extension StepSample: TimedSample {
    nonisolated var t: Double {
        switch self {
        case .pedometer(let p): p.t
        case .motion(let m): m.t
        case .activity(let a): a.t
        }
    }
}

extension ScreenSample: TimedSample {
    nonisolated var t: Double {
        switch self {
        case .stroopAnswer(_, _, let atMs), .stroopShown(_, let atMs): Double(atMs) / 1000
        case .touchDown(let t), .touchUp(let t): t
        }
    }
}

// MARK: - ReplaySource

/// Fuente que reproduce `[Sample]` en orden, durmiendo hasta `t / speed` de cada muestra.
///
/// - `speed == 1` reproduce en tiempo real; `speed == 10` diez veces más rápido;
///   `speed == .infinity` entrega todas las muestras sin esperar (tests).
/// - El stream termina solo cuando se acaban las muestras o se llama a `stop()`.
/// - Las muestras se entregan en el orden dado (no se reordenan): el fixture debe venir ordenado.
@MainActor
final class ReplaySource<Sample: Sendable & Codable>: SampleSource {
    /// Velocidad por defecto en Simulator: suficientemente rápida para una demo, visible en pantalla.
    static var defaultSimulatorSpeed: Double { 1 }

    let level: SourceLevel = .replay
    let samples: [Sample]
    let speed: Double
    private let timeOf: @Sendable (Sample) -> Double

    private(set) var isPlaying = false
    /// Cuántas veces se llamó a `stop()` (útil en tests para comprobar que el runner cierra la fuente).
    private(set) var stopCount = 0

    private var continuation: AsyncStream<Sample>.Continuation?
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - samples: muestras ordenadas por tiempo.
    ///   - speed: factor de aceleración (> 0; `.infinity` = sin esperas).
    ///   - timeOf: extrae `t` de una muestra (segundos desde el inicio).
    init(samples: [Sample], speed: Double = 1, timeOf: @escaping @Sendable (Sample) -> Double) {
        precondition(speed > 0, "ReplaySource: speed debe ser > 0")
        self.samples = samples
        self.speed = speed
        self.timeOf = timeOf
    }

    func start() throws -> AsyncStream<Sample> {
        stop()
        let (stream, continuation) = AsyncStream<Sample>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        isPlaying = true

        let samples = self.samples
        let speed = self.speed
        let timeOf = self.timeOf
        let task = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let origin = clock.now
            for sample in samples {
                if Task.isCancelled { break }
                if speed.isFinite {
                    let due = origin + .seconds(max(0, timeOf(sample)) / speed)
                    try? await clock.sleep(until: due)
                    if Task.isCancelled { break }
                }
                continuation.yield(sample)
            }
            continuation.finish()
        }
        self.task = task
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    func stop() {
        guard isPlaying || task != nil || continuation != nil else { return }
        if isPlaying { stopCount += 1 }
        isPlaying = false
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }
}

extension ReplaySource where Sample: TimedSample {
    /// Reproduce muestras que ya traen su `t`.
    convenience init(samples: [Sample], speed: Double = 1) {
        self.init(samples: samples, speed: speed, timeOf: { $0.t })
    }

    /// Reproduce un fixture cargado desde JSON o generado sintéticamente.
    convenience init(fixture: Fixture<Sample>, speed: Double = 1) {
        self.init(samples: fixture.samples, speed: speed, timeOf: { $0.t })
    }
}
