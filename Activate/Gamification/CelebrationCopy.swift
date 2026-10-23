import Foundation

// Dueño: agente "design-celebration".
// Pool FIJO de frases de celebración (sin LLM, sin mascota, sin trofeo, sin "¡Excelente!").
// Reglas: trato de usted + nombre de pila cuando aplica, frases ≤ 6 palabras, verbo al inicio,
// sin "po/cachai", nunca "trampa" ni "apto/no apto", sin signos de exclamación.
// Nunca se premia reportar mejoría ni un puntaje bajo: la respuesta Mejor/Igual/Peor es un dato.

/// Hito que determina qué escalón de la celebración se muestra.
nonisolated enum CelebrationMilestone: String, Sendable, CaseIterable, Hashable {
    /// Fin de una actividad individual (HUD de la actividad).
    case activityDone
    /// La pausa terminó pero no se pudo verificar (no suma, no rompe la racha).
    case notVerified
    /// Pausa contada, día 1 del turno.
    case day1
    /// Pausa contada, día 2 del turno: dos días seguidos.
    case doblete
    /// Pausa contada, día 7 de 7 con todos los días cumplidos.
    case tiroLimpio
    /// Pausa contada cualquier otro día.
    case pauseDone

    /// Escalón del hito: cuanto más alto, más celebración (confeti solo desde `doblete`).
    nonisolated var tier: Int {
        switch self {
        case .activityDone: 0
        case .notVerified: 0
        case .pauseDone: 1
        case .day1: 1
        case .doblete: 2
        case .tiroLimpio: 3
        }
    }

    nonisolated var usesConfetti: Bool { tier >= 2 }

    /// Hito de una recompensa de sesión. Prioridad: Tiro limpio > Doblete > día 1 > pausa normal.
    nonisolated static func forReward(counted: Bool, dayInBlock: Int, isDoblete: Bool, isTiroLimpio: Bool) -> CelebrationMilestone {
        guard counted else { return .notVerified }
        if isTiroLimpio { return .tiroLimpio }
        if isDoblete { return .doblete }
        if dayInBlock <= 1 { return .day1 }
        return .pauseDone
    }

    nonisolated static func forReward(_ reward: SessionReward) -> CelebrationMilestone {
        forReward(counted: reward.counted, dayInBlock: reward.dayInBlock,
                  isDoblete: reward.isDoblete, isTiroLimpio: reward.isTiroLimpio)
    }
}

nonisolated enum CelebrationCopy {
    /// Máximo de palabras por frase del pool (regla de copy del plan).
    static let maxWordsPerPhrase = 6

    /// Palabras prohibidas (comparación por palabra completa, en minúsculas) en todo el copy de celebración.
    static let bannedWords: Set<String> = [
        "excelente", "trampa", "apto", "po", "cachai", "crack", "campeón", "genial", "increíble", "mascota",
    ]
    /// Signos prohibidos (tono sobrio: sin exclamaciones).
    static let bannedCharacters: Set<Character> = ["¡", "!"]

    // MARK: - Títulos fijos

    nonisolated static func title(for milestone: CelebrationMilestone) -> String {
        switch milestone {
        case .activityDone: "Listo."
        case .notVerified: "Pausa terminada"
        case .day1, .pauseDone: "Pausa cumplida"
        case .doblete: "Doblete"
        case .tiroLimpio: "Tiro limpio"
        }
    }

    // MARK: - Pools por hito (fijos; la primera frase es la canónica del plan)

    nonisolated static func phrases(for milestone: CelebrationMilestone) -> [String] {
        switch milestone {
        case .activityDone:
            ["Listo.", "Hecha.", "Cumplida.", "Siguiente."]
        case .notVerified:
            ["No pude verificarla. Repita cuando pueda."]
        case .day1:
            ["Partió.", "Partió el turno.", "Día 1 cumplido.", "Empezó bien el turno."]
        case .pauseDone:
            ["Hoy sí alcanzó.", "Otro día cumplido.", "Minutos bien usados.", "Sigue firme.", "Un día más."]
        case .doblete:
            ["Dos días seguidos.", "Dos de dos.", "Ayer y hoy.", "Lo que costaba, cumplido."]
        case .tiroLimpio:
            ["Siete de siete.", "Turno completo con pausa.", "Los 7 días cumplidos.", "Tiro limpio, sin fallas."]
        }
    }

    /// Frase determinista del pool: el mismo `seed` devuelve siempre la misma frase.
    nonisolated static func phrase(for milestone: CelebrationMilestone, seed: Int) -> String {
        let pool = phrases(for: milestone)
        guard !pool.isEmpty else { return "" }
        let index = ((seed % pool.count) + pool.count) % pool.count
        return pool[index]
    }

    /// Frase de "no verificada" conjugada por trato.
    nonisolated static func notVerifiedLine(treatment: Treatment) -> String {
        switch treatment {
        case .usted: "No pude verificarla. Repita cuando pueda."
        case .tu: "No pude verificarla. Repite cuando puedas."
        }
    }

    /// Semilla estable a partir de la recompensa (no cambia entre redibujos de la vista).
    nonisolated static func seed(for reward: SessionReward) -> Int {
        reward.dayInBlock &* 31 &+ reward.streak &* 7 &+ reward.totalXP &+ reward.lines.count
    }

    // MARK: - Líneas de datos (no se celebran, se informan)

    nonisolated static func dayLine(dayInBlock: Int, workDays: Int = 7) -> String {
        "Día \(max(1, dayInBlock)) de \(workDays)"
    }

    /// "Hoy: mejor después de la pausa" — la respuesta es un dato, nunca un premio.
    nonisolated static func postLine(_ post: PostResponse?) -> String? {
        guard let post else { return nil }
        return "Hoy: \(post.title.lowercased()) después de la pausa"
    }

    /// Nota breve bajo la respuesta Peor/Igual (sin consejo médico, sin castigo).
    nonisolated static func postNote(_ post: PostResponse?) -> String? {
        switch post {
        case .peor: "Quedó en su hoja del kine."
        case .igual: "Quedó registrado."
        case .mejor, nil: nil
        }
    }

    /// Texto del nivel de verificación derivado de la recompensa.
    nonisolated static func verificationLine(counted: Bool, totalXP: Int, treatment: Treatment) -> String {
        if counted { return "Pausa verificada por sensores." }
        if totalXP > 0 { return "Verificación parcial. Suma XP." }
        return notVerifiedLine(treatment: treatment)
    }

    /// Símbolo SF para el nivel de verificación mostrado.
    nonisolated static func verificationSymbol(counted: Bool, totalXP: Int) -> String {
        if counted { return "checkmark.seal.fill" }
        if totalXP > 0 { return "checkmark.seal" }
        return "questionmark.circle"
    }

    nonisolated static func xpLine(total: Int) -> String {
        total > 0 ? "+\(total) XP" : "Sin XP esta vez"
    }

    nonisolated static func streakLine(streak: Int) -> String {
        switch streak {
        case ...0: "Racha: parte hoy"
        case 1: "Racha: 1 día"
        default: "Racha: \(streak) días"
        }
    }

    nonisolated static func newBadgeLine(count: Int) -> String {
        count == 1 ? "Nueva insignia" : "Nuevas insignias"
    }

    // MARK: - Tarjeta para la familia (Tiro limpio)

    static let familyCardAction = "Tarjeta para la familia"
    static let familyCardHeadline = "Tiro limpio"
    static let familyCardSubline = "7 de 7 días con pausa"
    static let familyCardFooter = "Pausas verificadas con sensores · Activate"

    static let closeAction = "Listo"

    // MARK: - Comodín (internamente "casco")

    /// Nombre visible del comodín que protege la racha (1 por turno, se usa solo).
    static let comodinName = "Comodín"
    /// Explicación corta del comodín (chip de Hoy).
    static let comodinExplanation = "Si un día de turno no alcanza a hacer la pausa, el comodín cuida su racha. Tiene 1 por turno y se usa solo."
    /// Aviso cuando ayer se usó el comodín (tira del turno y celebración). Es un dato, no una frase del pool.
    static let comodinUsedYesterdayLine = "Ayer se usó su comodín: racha a salvo."

    /// Estado del comodín bajo la explicación.
    nonisolated static func comodinStatus(available: Int) -> String {
        available > 0 ? "Disponible en este turno." : "Ya se usó en este turno. Vuelve el día 1 del próximo."
    }

    // MARK: - Utilidades de validación (tests)

    nonisolated static func wordCount(_ phrase: String) -> Int {
        phrase.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }

    nonisolated static func containsBannedFragment(_ phrase: String) -> Bool {
        if phrase.contains(where: { bannedCharacters.contains($0) }) { return true }
        let words = phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains { bannedWords.contains($0) }
    }

    /// Todo el copy fijo del paquete, para auditoría en tests.
    nonisolated static var allFixedPhrases: [String] {
        var all: [String] = []
        for m in CelebrationMilestone.allCases {
            all.append(title(for: m))
            all.append(contentsOf: phrases(for: m))
        }
        all.append(notVerifiedLine(treatment: .usted))
        all.append(notVerifiedLine(treatment: .tu))
        all.append(verificationLine(counted: true, totalXP: 10, treatment: .usted))
        all.append(verificationLine(counted: false, totalXP: 5, treatment: .usted))
        all.append(familyCardAction)
        all.append(familyCardHeadline)
        all.append(familyCardSubline)
        all.append(closeAction)
        for p in PostResponse.allCases {
            if let line = postLine(p) { all.append(line) }
            if let note = postNote(p) { all.append(note) }
        }
        return all
    }
}
