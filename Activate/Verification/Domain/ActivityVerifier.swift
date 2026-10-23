import Foundation

// MARK: - Contrato de verificación (congelado).

nonisolated enum GateState: Sendable, Equatable, Codable {
    case calibrating
    case ready
    case blocked(reason: String)
}

nonisolated struct Cue: Sendable, Equatable, Codable {
    var text: String
    var symbol: String? = nil
}

nonisolated enum VerifierEvent: Sendable, Equatable {
    case rep(Int)
    case progress(Double)
    case gate(GateState)
    case cue(Cue)
    case anomaly(Anomaly)
    case completed
}

nonisolated struct VerifierProgress: Sendable, Equatable, Codable {
    var count: Int = 0
    var target: Int
    var gate: GateState = .calibrating
    var hint: String = ""
    var elapsed: Double = 0
    /// Avance 0…1 hacia la meta de la consigna actual (p. ej. cuánto lleva girado el cuello); nil si no aplica.
    var live: Double? = nil
    /// Texto de depuración en vivo (ángulos, velocidad); la UI lo muestra solo en modo demo.
    var debug: String? = nil
    var fraction: Double { target > 0 ? min(1, Double(count) / Double(target)) : 0 }
}

nonisolated enum FinishReason: String, Sendable, Codable { case completed, timeout, userStopped, backgrounded, skipped }

/// Resultado crudo de una máquina de estados. Solo `ActivityRunner` lo convierte en `ActivityResult`.
nonisolated struct ActivityOutcome: Sendable, Codable, Hashable {
    var kind: ActivityKind
    var target: Int
    var achieved: Int
    var completed: Bool
    var durationSeconds: Double
    var metrics: ActivityMetrics
    var anomalies: [Anomaly]
    var reason: FinishReason
}

/// Máquina de estados pura por actividad: sin imports de frameworks de sensores, testeable con fixtures.
nonisolated protocol ActivityVerifier: Sendable {
    associatedtype Sample: Sendable & Codable
    var kind: ActivityKind { get }
    var spec: VerificationSpec { get }
    var progress: VerifierProgress { get }
    mutating func start(at t: Double)
    mutating func ingest(_ sample: Sample, at t: Double) -> [VerifierEvent]
    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome
}

/// Nivel de confianza que declara la fuente de muestras.
nonisolated enum SourceLevel: String, Sendable, Codable { case live, fallback, replay }

/// Política pura que convierte (outcome, fuente) en nivel de verificación.
nonisolated enum VerificationPolicy {
    static func level(for outcome: ActivityOutcome, source: SourceLevel, kind: ActivityKind) -> VerificationLevel {
        if source == .replay { return .simulated }
        if outcome.anomalies.contains(where: { $0.severity == .hard }) { return .suspicious }
        if source == .fallback || kind.weakByNature { return .reduced }
        return .full
    }

    /// Nivel de la sesión = mínimo de las actividades completadas (o `simulated` si alguna lo es).
    static func sessionLevel(_ results: [ActivityResult]) -> VerificationLevel {
        let done = results.filter { $0.completed && !$0.skipped }
        guard !done.isEmpty else { return .suspicious }
        return done.map(\.level).min() ?? .suspicious
    }

    /// Una pausa cuenta si tiene ≥ 1 actividad `full` completada.
    static func counts(_ results: [ActivityResult]) -> Bool {
        results.contains { $0.completed && !$0.skipped && $0.level == .full }
    }
}

/// Interfaz observable que consume la UI de la actividad. Lo implementa `ActivityRunner` (Verification/Runtime).
@MainActor
protocol ActivityRunning: AnyObject, Observable {
    var assignment: ActivityAssignment { get }
    var progress: VerifierProgress { get }
    var cue: Cue? { get }
    var lastRepAt: Double? { get }
    var outcome: ActivityOutcome? { get }
    var level: VerificationLevel? { get }
    var isRunning: Bool { get }
    func start()
    func stop(reason: FinishReason)
}

/// Fuente de muestras para un verificador (sensor en vivo, fallback o replay de fixtures).
/// Cada muestra ya trae su `t` (segundos desde `start`, ContinuousClock medido en la fuente).
@MainActor
protocol SampleSource: AnyObject {
    associatedtype Sample: Sendable & Codable
    var level: SourceLevel { get }
    /// Arranca el sensor y entrega muestras hasta `stop()`.
    func start() throws -> AsyncStream<Sample>
    func stop()
}

nonisolated enum VerificationError: Error, Sendable {
    case sensorUnavailable(String)
    case permissionDenied(String)
    case cameraBusy
}
