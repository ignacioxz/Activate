import Foundation

/// Línea "por qué" del plan, compuesta en Swift a partir de lo que la persona respondió y de las reglas
/// que se aplicaron. La IA no la redacta: un modelo de 3B inventaba motivos (caso real: con el cuestionario
/// todo en "No" escribió "Menos espalda baja hoy" porque le llegó una zona prellenada).
nonisolated enum PlanWhy {
    static let gentle = "Plan suave: su espalda está cargada hoy."
    static let noBending = "Sin sentadillas: evita agacharse hoy."
    static let shortWalk = "Caminata más corta hoy."
    static let shorter = "Ejercicios más cortos hoy."
    static let noCamera = "Sin cámara: solo pasos y pantalla."
    static let noPain = "Hoy sin molestias: pausa completa."
    static let normal = "Pausa completa, a su ritmo."
    static let coachAdjusted = "Metas ajustadas a su historial."

    /// Hasta dos motivos, del más importante al menos.
    static func compose(decision: SafetyRules.Decision, checkIn: DailyCheckIn?, cameraBlocked: Bool,
                        coachAdjustedTargets: Bool = false) -> String {
        var reasons: [String] = []
        if decision.gentle {
            reasons.append(gentle)
        } else {
            let answers = checkIn?.answers ?? []
            if answers.indices.contains(RDQ6.itemAvoidsBending), answers[RDQ6.itemAvoidsBending] {
                reasons.append(noBending)
            }
            if decision.stepTargetFactor < 1 { reasons.append(shortWalk) }
            if decision.shorterActivities { reasons.append(shorter) }
        }
        if cameraBlocked { reasons.append(noCamera) }
        if reasons.isEmpty {
            let painFree = checkIn.map { $0.noPain || $0.score == 0 } ?? false
            reasons.append(painFree ? noPain : normal)
        }
        if coachAdjustedTargets { reasons.append(coachAdjusted) }
        return reasons.prefix(2).joined(separator: " ")
    }

    /// Palabras que el mensaje de inicio del modelo no puede usar: hablar de dolor o de zonas es tarea de Swift.
    static let forbiddenInStartMessage = ["espalda", "lumbar", "cuello", "hombro", "dolor", "duele", "molest", "lesión", "lesion"]

    /// Acepta el mensaje de inicio del modelo solo si no menciona dolor ni zonas; si no, `nil` (se usa la plantilla).
    static func sanitizedStartMessage(_ message: String?) -> String? {
        guard let message, !message.isEmpty else { return nil }
        let lower = message.lowercased()
        return forbiddenInStartMessage.contains(where: { lower.contains($0) }) ? nil : message
    }
}
