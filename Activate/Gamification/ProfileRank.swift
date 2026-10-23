import Foundation

/// Niveles y rangos por XP. Lo comparten Hoy (barra de nivel) y Perfil (anillo y nombre del rango).
/// Sin ligas ni rankings: el nivel es contra uno mismo.
nonisolated enum ProfileRank {
    static let xpPerLevel = 150
    static let names = ["Aprendiz", "Operador", "Operador experto", "Capataz", "Jefe de turno", "Superintendente"]

    static func level(xp: Int) -> Int { max(0, xp) / xpPerLevel + 1 }

    /// Nombre del rango según el nivel por día (Perfil): cada 2 niveles sube de rango.
    static func title(level: Int) -> String {
        names[min(names.count - 1, max(0, level - 1) / 2)]
    }

    /// Nombre del rango por XP (versión anterior; se mantiene para datos y pruebas antiguas).
    static func title(xp: Int) -> String {
        names[min(names.count - 1, (level(xp: xp) - 1) / 2)]
    }

    /// Avance dentro del nivel actual (0...1).
    static func progress(xp: Int) -> Double {
        Double(xpIntoLevel(xp: xp)) / Double(xpPerLevel)
    }

    /// XP ya ganados dentro del nivel actual (0..<150).
    static func xpIntoLevel(xp: Int) -> Int { max(0, xp) % xpPerLevel }

    /// XP que faltan para el nivel siguiente (1...150).
    static func xpToNextLevel(xp: Int) -> Int { xpPerLevel - xpIntoLevel(xp: xp) }
}

/// Resumen de la tarjeta "Nivel" de Hoy, con la regla por día (`LevelProgress`): la pausa completa de un día
/// sube 1 nivel; una parcial suma su porcentaje (5 de 7 = 71 %), que se acumula con los días siguientes.
nonisolated struct LevelSummary: Sendable, Equatable {
    var level: Int
    /// Avance hacia el nivel siguiente en porcentaje entero (0…99).
    var percentToNext: Int
    /// Avance real hacia el nivel siguiente (0…<1).
    var progress: Double
    /// Hasta dónde llegaría la barra con la pausa completa de hoy (tope 1).
    var ghostProgress: Double
    /// Completar la pausa de hoy cruza al nivel siguiente.
    var nextPauseCrossesLevel: Bool
    /// Subió de nivel con la pausa de hoy.
    var leveledUpToday: Bool
    var note: String

    /// - Parameters:
    ///   - levels: nivel derivado del historial (`LevelProgress.compute`).
    ///   - optional: la pausa de hoy es opcional (bajada).
    static func make(levels: LevelProgress, optional: Bool = false) -> LevelSummary {
        let fraction = levels.fractionToNext
        let todayCredit = levels.todayCredit
        // Lo que todavía puede sumar hoy: vale la mejor pausa del día, nunca más de 1 nivel.
        let remainingToday = max(0, 1 - todayCredit)
        let ghost = min(1, fraction + remainingToday)
        let before = LevelProgress.level(forCredits: levels.totalCredits - todayCredit)
        let leveledUp = todayCredit > 0 && levels.level > before
        let toward = "\(LevelProgress.percentText(levels.percentToNext)) hacia el nivel \(levels.nextLevel)"
        let note: String
        if leveledUp {
            note = "Subió al nivel \(levels.level) hoy. Lleva \(toward)."
        } else if let line = levels.todayLine {
            note = "\(line). Lleva \(toward)."
        } else if optional {
            note = "Pausa opcional: completa, también sube 1 nivel."
        } else {
            note = "La pausa completa de hoy sube 1 nivel."
        }
        return LevelSummary(level: levels.level, percentToNext: levels.percentToNext, progress: fraction,
                            ghostProgress: max(fraction, ghost),
                            nextPauseCrossesLevel: remainingToday > 0 && fraction + remainingToday >= 1 - LevelProgress.epsilon,
                            leveledUpToday: leveledUp, note: note)
    }

    /// "Nivel 4, 71 por ciento hacia el nivel 5. …"
    var spoken: String { "Nivel \(level), \(percentToNext) por ciento hacia el nivel \(level + 1). \(note)" }
}
