import Foundation
import Observation

// Dueño: agente "runtime". Stub con firma congelada: el UI usa `ActivityRunnerFactory.make`.

/// Fábrica que arma verificador + fuente para una asignación.
@MainActor
enum ActivityRunnerFactory {
    /// `demo` acorta metas; `replay` fuerza fixtures (simulador o tests).
    static func make(assignment: ActivityAssignment, demo: Bool, replay: Bool = false) -> any ActivityRunning {
        PlaceholderRunner(assignment: assignment)
    }
}

/// Runner provisional que no verifica nada (se reemplaza en el paquete runtime).
@Observable
final class PlaceholderRunner: ActivityRunning {
    let assignment: ActivityAssignment
    var progress: VerifierProgress
    var cue: Cue? = Cue(text: "Verificador en construcción")
    var lastRepAt: Double? = nil
    var outcome: ActivityOutcome? = nil
    var level: VerificationLevel? = nil
    var isRunning = false

    init(assignment: ActivityAssignment) {
        self.assignment = assignment
        progress = VerifierProgress(target: assignment.target, gate: .blocked(reason: "Sin verificador"))
    }

    func start() { isRunning = true }
    func stop(reason: FinishReason) {
        isRunning = false
        outcome = ActivityOutcome(kind: assignment.kind, target: assignment.target, achieved: 0, completed: false,
                                  durationSeconds: 0, metrics: .none, anomalies: [], reason: reason)
        level = .simulated
    }
}
