import Foundation

// Dueño: agente "activities". Recetas base y reglas clínicas deterministas.
// Firmas congeladas que se conservan: `Recipes.base(_:demo:)`, `SafetyRules.Decision`,
// `SafetyRules.evaluate(checkIn:)`, `SafetyRules.apply(_:to:)`.
// Todo es puro y `nonisolated`: se puede llamar desde MainActor o desde el coach.

// MARK: - Recetas

nonisolated enum Recipes {
    /// La cámara de cuerpo entero (Vision pose) queda lista el día 5. Hasta entonces, Colación no
    /// incluye A1 (extensión lumbar con el teléfono apoyado en la mesa).
    static let cameraPoseReady = false

    /// Factor de la meta de pasos en el plan suave (RDQ-6 ≥ umbral).
    static let gentleStepFactor: Double = 0.5

    /// Actividades del plan suave, en orden: caminata corta + cuello + respiración.
    static let gentleKinds: [ActivityKind] = [.pasos, .cuello, .ojos]

    /// Receta base por tipo; `demo` usa metas cortas.
    static func base(_ kind: RecipeKind, demo: Bool) -> Recipe {
        base(kind, demo: demo, cameraPoseReady: cameraPoseReady)
    }

    /// Variante con el flag explícito (tests y previews).
    static func base(_ kind: RecipeKind, demo: Bool, cameraPoseReady: Bool) -> Recipe {
        let kinds: [ActivityKind]
        switch kind {
        case .relevo60:
            // Pausa rápida (elegida por el usuario): solo lo que cabe en un minuto con el teléfono en la mano.
            kinds = [.cuello, .ojos]
        case .colacion3, .campamento5:
            // Ruta completa: todo el orden fijo de la sesión.
            kinds = ActivityKind.sessionOrder
        }
        return Recipe(kind: kind, activities: ActivityKind.inSessionOrder(kinds, kind: { $0 }).map { assignment($0, demo: demo) })
    }

    /// Plan suave (RDQ-6 ≥ `RDQ6.gentlePlanThreshold`): pasos con meta reducida + movilidad cervical + pestañeo.
    static func gentle(_ kind: RecipeKind, demo: Bool) -> Recipe {
        gentle(kind, demo: demo, stepFactor: gentleStepFactor)
    }

    /// Plan suave con factor de pasos explícito (lo usa `SafetyRules.apply` para no acumular factores).
    static func gentle(_ kind: RecipeKind, demo: Bool, stepFactor: Double) -> Recipe {
        let activities = gentleKinds.map { k in
            assignment(k, demo: demo, factor: k == .pasos ? stepFactor : 1)
        }
        return Recipe(kind: kind, activities: activities)
    }

    /// Asignación con la meta real o de demo, opcionalmente escalada.
    static func assignment(_ kind: ActivityKind, demo: Bool, factor: Double = 1) -> ActivityAssignment {
        ActivityAssignment(kind: kind, target: scaledTarget(kind, demo: demo, factor: factor))
    }

    /// Meta escalada con piso por tipo de unidad (nunca 0).
    static func scaledTarget(_ kind: ActivityKind, demo: Bool, factor: Double) -> Int {
        scale(demo ? kind.demoTarget : kind.defaultTarget, kind: kind, by: factor)
    }

    static func scale(_ target: Int, kind: ActivityKind, by factor: Double) -> Int {
        guard factor < 1 else { return target }
        let scaled = Int((Double(target) * factor).rounded())
        return max(minimumTarget(for: kind), scaled)
    }

    /// Piso de la meta tras aplicar factores.
    static func minimumTarget(for kind: ActivityKind) -> Int {
        switch kind {
        case .pasos: SafetyRules.minStepTarget
        case .extensionLumbar, .sentadilla, .cuello: SafetyRules.minRepTarget
        case .respiracion, .ojos, .stroop: 1
        }
    }
}

nonisolated extension Recipe {
    /// Heurística: la receta se armó con metas de demo (alguna meta coincide con `demoTarget`).
    var usesDemoTargets: Bool {
        activities.contains { $0.target == $0.kind.demoTarget && $0.kind.demoTarget != $0.kind.defaultTarget }
    }

    var kinds: [ActivityKind] { activities.map(\.kind) }
}

// MARK: - Reglas clínicas

nonisolated enum SafetyRules {
    nonisolated struct Decision: Sendable, Hashable, Codable {
        var allowed: [ActivityKind]
        var gentle: Bool
        var stop: Bool
        var reason: String?
        /// 1 = meta de pasos normal; `SafetyRules.reducedStepFactor` cuando "solo camina distancias cortas" o plan suave.
        var stepTargetFactor: Double = 1
        /// "Sólo está de pie por períodos cortos" = Sí: las actividades de pie llevan menos reps.
        var shorterActivities: Bool = false

        /// Hay algo que contar en la pantalla de plan (la receta cambió respecto a la base).
        var adjusted: Bool { stop || gentle || shorterActivities || stepTargetFactor < 1 || allowed.count < ActivityKind.sessionOrder.count }
    }

    // Constantes nombradas (se calibran después con el kine).
    static let reducedStepFactor: Double = 0.5
    static let shorterRepFactor: Double = 0.5
    static let minStepTarget = 10
    static let minRepTarget = 3

    /// Motivo de la decisión `stop` (tarjeta "cuándo parar").
    static let stopReason = "cuándo parar"

    /// Copy fijo de las tarjetas que muestra la pantalla de plan.
    nonisolated enum Copy {
        static let stopTitle = "Cuándo parar"
        static let stopBody = "Hoy no haga ejercicio. Pase por el policlínico de faena y cuente lo que marcó."
        static let stopButton = "Entendido"
        static let gentleWhy = "Hoy plan suave: espalda cargada."
        static let noBendingWhy = "Hoy sin sentadilla: evita agacharse."
        static let shortWalkWhy = "Hoy caminata más corta."
        static let shortStandingWhy = "Hoy actividades más breves."
    }

    /// Lo que sacan las reglas de "no agacharse / arrodillarse" = Sí (bisagra A4 cuando exista).
    static let bendingKinds: [ActivityKind] = [.sentadilla, .extensionLumbar]

    /// Reglas clínicas deterministas (nunca en el prompt del LLM). Sin check-in → todo permitido.
    static func evaluate(checkIn: DailyCheckIn?) -> Decision {
        guard let checkIn else {
            return Decision(allowed: ActivityKind.sessionOrder, gentle: false, stop: false, reason: nil)
        }
        if checkIn.hasAlarm {
            return Decision(allowed: [], gentle: false, stop: true, reason: stopReason)
        }

        let gentle = checkIn.score >= RDQ6.gentlePlanThreshold
        let avoidsBending = checkIn.answered(RDQ6.itemAvoidsBending)
        let walksShort = checkIn.answered(RDQ6.itemWalksShortDistances)
        let standsShort = checkIn.answered(RDQ6.itemStandsShortPeriods)

        var allowed = gentle ? Recipes.gentleKinds : ActivityKind.sessionOrder
        if avoidsBending { allowed.removeAll { bendingKinds.contains($0) } }

        let reason: String?
        if gentle { reason = Copy.gentleWhy }
        else if avoidsBending { reason = Copy.noBendingWhy }
        else if walksShort { reason = Copy.shortWalkWhy }
        else if standsShort { reason = Copy.shortStandingWhy }
        else { reason = nil }

        return Decision(
            allowed: allowed,
            gentle: gentle,
            stop: false,
            reason: reason,
            stepTargetFactor: (walksShort || gentle) ? reducedStepFactor : 1,
            shorterActivities: standsShort
        )
    }

    /// Filtra una receta con la decisión (infiere demo/real de las metas de la receta).
    static func apply(_ decision: Decision, to recipe: Recipe) -> Recipe {
        apply(decision, to: recipe, demo: recipe.usesDemoTargets)
    }

    /// Filtra y escala una receta: `stop` la vacía, `gentle` la reemplaza por el plan suave,
    /// `allowed` filtra, `stepTargetFactor` escala pasos y `shorterActivities` acorta las de pie.
    static func apply(_ decision: Decision, to recipe: Recipe, demo: Bool) -> Recipe {
        if decision.stop { return Recipe(kind: recipe.kind, activities: []) }
        let source = decision.gentle ? Recipes.gentle(recipe.kind, demo: demo, stepFactor: decision.stepTargetFactor) : recipe
        let activities = source.activities
            .filter { decision.allowed.contains($0.kind) }
            .map { assignment -> ActivityAssignment in
                var a = assignment
                if a.kind == .pasos, !decision.gentle {
                    a.target = Recipes.scale(a.target, kind: a.kind, by: decision.stepTargetFactor)
                }
                if decision.shorterActivities, a.kind.isStanding, a.kind != .pasos {
                    a.target = Recipes.scale(a.target, kind: a.kind, by: shorterRepFactor)
                }
                return a
            }
        return Recipe(kind: recipe.kind, activities: activities)
    }

    /// Atajo: receta base ya pasada por las reglas.
    static func plannedRecipe(_ kind: RecipeKind, checkIn: DailyCheckIn?, demo: Bool) -> Recipe {
        apply(evaluate(checkIn: checkIn), to: Recipes.base(kind, demo: demo), demo: demo)
    }
}

nonisolated extension DailyCheckIn {
    /// Respuesta Sí al ítem `index` de `RDQ6.items` (falso si no se respondió, p. ej. "Me duele ahora").
    func answered(_ index: Int) -> Bool {
        index >= 0 && index < answers.count && answers[index]
    }
}
