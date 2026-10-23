import Foundation

/// Momentos reales del turno donde cabe una pausa con el teléfono permitido.
nonisolated enum Moment: String, Codable, CaseIterable, Sendable, Identifiable {
    case entrada, colacion, salida, campamento

    var id: String { rawValue }

    var title: String {
        switch self {
        case .entrada: "Relevo de entrada"
        case .colacion: "Colación"
        case .salida: "Relevo de salida"
        case .campamento: "Campamento"
        }
    }

    /// Cualquier momento hace la ruta completa (pedido del usuario: sin molestias, ruta completa).
    /// La pausa rápida de 1 minuto es una elección explícita ("Solo tengo 1 minuto"), no del momento.
    var recipe: RecipeKind { .campamento5 }

    var minutes: Int { recipe.minutes }

    /// Ventanas por tipo de turno (hora local). Turno de día ≈ 08:00-20:00; noche ≈ 20:00-08:00.
    static func infer(date: Date, shift: ShiftType, calendar: Calendar = .current) -> Moment {
        let h = calendar.component(.hour, from: date)
        let m = calendar.component(.minute, from: date)
        let t = Double(h) + Double(m) / 60
        switch shift {
        case .day:
            if t >= 4 && t < 9.5 { return .entrada }
            if t >= 9.5 && t < 15 { return .colacion }
            if t >= 15 && t < 20.5 { return .salida }
            return .campamento
        case .night:
            if t >= 16 && t < 21.5 { return .entrada }
            if t >= 21.5 || t < 3 { return .colacion }
            if t >= 3 && t < 8.5 { return .salida }
            return .campamento
        }
    }
}
