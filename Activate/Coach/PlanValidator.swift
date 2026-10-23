import Foundation

// Dueño: agente "coach". Validación pura del plan propuesto por el LLM (sin FoundationModels).

/// Ids del catálogo tal como los conoce el `@Guide(.anyOf(...))` de `EjercicioAsignado`
/// (el guide exige un literal; aquí queda la copia que los tests comparan con `ActivityKind`).
nonisolated enum CatalogIDs {
    static let all: [String] = ["A1", "A2", "A3", "A5", "A8", "A9", "A10"]
}

/// Ejercicio propuesto (id + reps) antes de validar. Es lo que produce el LLM.
nonisolated struct ProposedExercise: Sendable, Hashable {
    var id: String
    var reps: Int
}

nonisolated enum PlanValidator {
    nonisolated enum Failure: Error, Equatable, Sendable {
        case empty
        case unknownID(String)
        case notAllowed(ActivityKind)
        case duplicate(ActivityKind)
        case repsOutOfRange(ActivityKind, reps: Int, max: Int)
        case durationExceeded(estimatedSeconds: Int, limitSeconds: Int)
        case tooMany(Int)
    }

    // Umbrales nombrados (se calibran en dispositivo).
    /// Segundos por repetición (extensión, sentadilla, movimiento de cuello, parpadeo).
    static let secondsPerRep: Double = 1
    /// Segundos por paso.
    static let secondsPerStep: Double = 0.5
    /// Duración fija del Stroop.
    static let stroopSeconds: Double = 60
    /// Duración fija de la respiración.
    static let breathSeconds: Double = 60
    /// Multiplicador máximo de reps sobre la meta base.
    static let maxRepsFactor = 2
    /// Máximo de ejercicios por pausa (coincide con `@Guide(.count(1...5))`).
    static let maxExercises = 5

    /// Duración estimada de una asignación.
    static func estimatedSeconds(_ a: ActivityAssignment) -> Double {
        switch a.kind {
        case .pasos: Double(a.target) * secondsPerStep
        case .stroop: stroopSeconds
        case .respiracion: breathSeconds
        case .extensionLumbar, .sentadilla, .cuello, .ojos: Double(a.target) * secondsPerRep
        }
    }

    static func estimatedSeconds(_ plan: [ActivityAssignment]) -> Int {
        Int(plan.reduce(0) { $0 + estimatedSeconds($1) }.rounded(.up))
    }

    /// Meta de referencia para una actividad: la de la receta base o, si no está, la meta por defecto.
    static func referenceTarget(for kind: ActivityKind, in recipe: Recipe) -> Int {
        recipe.activities.first { $0.kind == kind }?.target ?? kind.defaultTarget
    }

    /// Valida ids (existen y están permitidos), duplicados, reps en [1, 2×meta] y duración ≤ minutos.
    static func validate(_ proposal: [ProposedExercise], input: CoachInput) -> Result<[ActivityAssignment], Failure> {
        guard !proposal.isEmpty else { return .failure(.empty) }
        guard proposal.count <= maxExercises else { return .failure(.tooMany(proposal.count)) }
        var seen = Set<ActivityKind>()
        var out: [ActivityAssignment] = []
        for p in proposal {
            let id = p.id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let kind = ActivityKind(rawValue: id) else { return .failure(.unknownID(p.id)) }
            guard input.allowedKinds.contains(kind) else { return .failure(.notAllowed(kind)) }
            guard seen.insert(kind).inserted else { return .failure(.duplicate(kind)) }
            let maxReps = referenceTarget(for: kind, in: input.baseRecipe) * maxRepsFactor
            guard p.reps >= 1, p.reps <= maxReps else {
                return .failure(.repsOutOfRange(kind, reps: p.reps, max: maxReps))
            }
            out.append(ActivityAssignment(kind: kind, target: p.reps))
        }
        let limit = input.minutesAvailable * 60
        let est = estimatedSeconds(out)
        guard est <= limit else { return .failure(.durationExceeded(estimatedSeconds: est, limitSeconds: limit)) }
        return .success(out)
    }

    /// Receta base filtrada por las reglas: lo que queda cuando el LLM falla o tarda.
    static func fallback(_ input: CoachInput) -> [ActivityAssignment] {
        input.baseRecipe.activities.filter { input.allowedKinds.contains($0.kind) }
    }
}

// MARK: - Límites de texto (puros)

nonisolated enum CoachText {
    /// Máximo de palabras en "por qué" y "mensaje de inicio".
    static let maxShortWords = 8
    /// Máximo de palabras por frase de la lectura de datos.
    static let maxSentenceWords = 16
    /// Máximo de palabras por bloque de la hoja del kine.
    static let maxBlockWords = 60
    /// Palabras prohibidas en cualquier texto del coach.
    static let bannedWords: [String] = ["trampa", "apto", "no apto", "cachai", " po "]

    /// Limpia espacios, rechaza vacío y palabras prohibidas, recorta a `maxWords` (cierra con punto).
    static func clean(_ text: String, maxWords: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !trimmed.isEmpty else { return nil }
        let lower = " " + trimmed.lowercased() + " "
        for banned in bannedWords where lower.contains(banned.hasPrefix(" ") ? banned : " \(banned)") {
            return nil
        }
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > maxWords else { return trimmed }
        var cut = words.prefix(maxWords).joined(separator: " ")
        while let last = cut.last, ",;:".contains(last) { cut.removeLast() }
        return cut.hasSuffix(".") ? cut : cut + "."
    }

    static func wordCount(_ text: String) -> Int {
        text.split(separator: " ", omittingEmptySubsequences: true).count
    }
}
