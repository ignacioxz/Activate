import Foundation

/// Niveles y rangos por XP. Lo comparten Hoy (barra de nivel) y Perfil (anillo y nombre del rango).
/// Sin ligas ni rankings: el nivel es contra uno mismo.
nonisolated enum ProfileRank {
    static let xpPerLevel = 150
    static let names = ["Aprendiz", "Operador", "Operador experto", "Capataz", "Jefe de turno", "Superintendente"]

    static func level(xp: Int) -> Int { max(0, xp) / xpPerLevel + 1 }

    /// Nombre del rango (solo en Perfil).
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

/// Resumen de la tarjeta "Nivel" de Hoy: barra con el tramo que puede sumar la próxima pausa.
nonisolated struct LevelSummary: Sendable, Equatable {
    var level: Int
    var xp: Int
    /// Avance real dentro del nivel (0...1).
    var progress: Double
    /// Hasta dónde llegaría la barra con la próxima pausa ("hasta"), tope 1.
    var ghostProgress: Double
    /// La próxima pausa puede cruzar al nivel siguiente.
    var nextPauseCrossesLevel: Bool
    /// Subió de nivel con lo ganado hoy.
    var leveledUpToday: Bool
    var note: String

    /// - Parameters:
    ///   - xp: XP total del perfil.
    ///   - xpToday: XP de las pausas de hoy (ya incluidos en `xp`).
    ///   - nextPausePreview: máximo que puede sumar la próxima pausa ("hasta").
    ///   - optional: la próxima pausa es opcional (bajada).
    static func make(xp: Int, xpToday: Int, nextPausePreview: Int, optional: Bool = false) -> LevelSummary {
        let level = ProfileRank.level(xp: xp)
        let into = ProfileRank.xpIntoLevel(xp: xp)
        let toNext = ProfileRank.xpToNextLevel(xp: xp)
        let preview = max(0, nextPausePreview)
        let progress = ProfileRank.progress(xp: xp)
        let ghost = min(1, Double(into + preview) / Double(ProfileRank.xpPerLevel))
        let leveledUp = xpToday > 0 && ProfileRank.level(xp: xp - xpToday) < level
        let missing = "Faltan \(toNext) XP para el nivel \(level + 1)."
        let note: String
        if leveledUp {
            note = "Subió al nivel \(level) hoy. \(missing)"
        } else if xpToday > 0 {
            note = "Hoy sumó +\(xpToday) XP. \(missing)"
        } else {
            note = "\(missing) La pausa \(optional ? "opcional" : "de hoy") da hasta +\(preview) XP."
        }
        return LevelSummary(level: level, xp: max(0, xp), progress: progress, ghostProgress: max(progress, ghost),
                            nextPauseCrossesLevel: preview >= toNext, leveledUpToday: leveledUp, note: note)
    }

    /// "Nivel 3, 375 XP. Faltan 75 XP para el nivel 4. …"
    var spoken: String { "Nivel \(level), \(xp) XP. \(note)" }
}
