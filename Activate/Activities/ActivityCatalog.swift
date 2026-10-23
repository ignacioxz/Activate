import Foundation

// Dueño: agente "activities". Stubs con firma congelada.

enum Recipes {
    /// Receta base por tipo; `demo` usa metas cortas.
    static func base(_ kind: RecipeKind, demo: Bool) -> Recipe {
        func a(_ k: ActivityKind) -> ActivityAssignment { ActivityAssignment(kind: k, target: demo ? k.demoTarget : k.defaultTarget) }
        switch kind {
        case .relevo60: return Recipe(kind: kind, activities: [a(.cuello), a(.ojos)])
        case .colacion3: return Recipe(kind: kind, activities: [a(.pasos), a(.cuello), a(.ojos)])
        case .campamento5: return Recipe(kind: kind, activities: [a(.pasos), a(.sentadilla), a(.extensionLumbar), a(.cuello), a(.ojos), a(.stroop), a(.respiracion)])
        }
    }
}

enum SafetyRules {
    nonisolated struct Decision: Sendable, Hashable {
        var allowed: [ActivityKind]
        var gentle: Bool
        var stop: Bool
        var reason: String?
    }
    /// Reglas clínicas deterministas (nunca en el prompt del LLM).
    static func evaluate(checkIn: DailyCheckIn?) -> Decision {
        Decision(allowed: ActivityKind.allCases, gentle: false, stop: false, reason: nil)
    }
    /// Filtra una receta con la decisión.
    static func apply(_ decision: Decision, to recipe: Recipe) -> Recipe {
        Recipe(kind: recipe.kind, activities: recipe.activities.filter { decision.allowed.contains($0.kind) })
    }
}
