import Foundation

/// Textos y símbolos del momento del turno que usan Hoy y el accesorio "Próxima pausa".
/// (La tarjeta del momento se reemplazó por la "Meta de hoy" y los "Momentos de hoy".)
nonisolated enum MomentCard {
    static func symbol(for moment: Moment) -> String { moment.symbol }

    /// Una línea con lo que incluye la receta: "Incluye: Cuello · Pestañeo".
    static func includesLine(for recipe: Recipe) -> String {
        let names = recipe.activities.map { shortName($0.kind) }
        guard !names.isEmpty else { return "Incluye: lo que alcance." }
        return "Incluye: " + names.joined(separator: " · ")
    }

    /// Nombres cortos para la línea de resumen (los nombres largos viven en ActivityKind.name).
    static func shortName(_ kind: ActivityKind) -> String {
        switch kind {
        case .extensionLumbar: "Espalda"
        case .pasos: "Pasos"
        case .sentadilla: "Sentadillas"
        case .pararseSentarse: "Pararse"
        case .cuello: "Cervical"
        case .respiracion: "Respiración"
        case .ojos: "Pestañeo"
        case .stroop: "Reflejos"
        }
    }
}
