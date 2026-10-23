import Foundation

/// Un ejercicio del catálogo que no entra en la pausa de hoy, con una razón corta.
nonisolated struct PlanExclusion: Sendable, Hashable, Identifiable {
    var kind: ActivityKind
    var reason: String
    var id: String { kind.rawValue }
}

/// Explica por qué cada ejercicio del orden fijo quedó fuera de la pausa. Lo calcula Swift con las
/// respuestas del check-in, las reglas, el consentimiento y la receta del momento: nunca la IA.
nonisolated enum PlanExclusions {
    static let noConsent = "Usa la cámara y falta su consentimiento (Perfil › Privacidad)."
    static let gentle = "Plan suave: hoy su espalda está cargada."
    static let avoidsBending = "Usted marcó que evita agacharse o arrodillarse."
    static let notAdvisable = "No conviene con sus respuestas de hoy."
    static let relevo = "Eligió la pausa rápida de 1 minuto."
    static let needsPropping = "Necesita apoyar el teléfono a 2 metros: va en el campamento."
    static let campamento = "Va en el campamento, con más tiempo."
    static let coachRemoved = "El coach la dejó para otra pausa según su historial."
    static let unavailable = "No disponible hoy."

    static func explain(recipe: RecipeKind, decision: SafetyRules.Decision, checkIn: DailyCheckIn?,
                        consentGiven: Bool, baseKinds: [ActivityKind], planKinds: [ActivityKind],
                        coachRemoved: Set<ActivityKind> = []) -> [PlanExclusion] {
        let inPlan = Set(planKinds)
        let avoids: Bool = {
            guard let a = checkIn?.answers, a.indices.contains(RDQ6.itemAvoidsBending) else { return false }
            return a[RDQ6.itemAvoidsBending]
        }()
        return ActivityKind.sessionOrder.filter { !inPlan.contains($0) }.map { kind in
            PlanExclusion(kind: kind, reason: reason(for: kind, recipe: recipe, decision: decision, avoids: avoids,
                                                     consentGiven: consentGiven, inBase: baseKinds.contains(kind),
                                                     removedByCoach: coachRemoved.contains(kind)))
        }
    }

    private static func reason(for kind: ActivityKind, recipe: RecipeKind, decision: SafetyRules.Decision,
                               avoids: Bool, consentGiven: Bool, inBase: Bool, removedByCoach: Bool) -> String {
        let camera = kind.sensorBlock == .face || kind.sensorBlock == .cameraPose
        if !consentGiven && camera { return noConsent }
        if decision.gentle && !Recipes.gentleKinds.contains(kind) { return gentle }
        if !decision.allowed.contains(kind) { return avoids ? avoidsBending : notAdvisable }
        if !inBase {
            switch recipe {
            case .relevo60: return relevo
            case .colacion3: return kind.sensorBlock == .cameraPose ? needsPropping : campamento
            case .campamento5: return unavailable
            }
        }
        if removedByCoach { return coachRemoved }
        return unavailable
    }
}
