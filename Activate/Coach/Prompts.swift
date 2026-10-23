import Foundation

// Dueño: agente "coach". Prompts versionados + pool de frases de plantilla.
// Regla: nunca texto libre del usuario en el prompt; solo cifras y frases ya calculadas por Swift.

nonisolated enum CoachPrompts {
    /// Versión del juego de prompts (se registra en el razonamiento del plan).
    static let version = "pausa-del-dia-v1"

    /// Frase literal obligatoria al inicio de las instrucciones (fija el idioma del modelo).
    static let localePrefix = "The person's locale is es_CL."
    /// Frase literal obligatoria al cierre de las instrucciones.
    static let closingRule = "Responde SIEMPRE en español de Chile, de usted, en frases cortas. No diagnostiques, no recomiendes fármacos, no inventes cifras: usa solo las que recibes."

    /// Instrucciones fijas de la sesión (una sesión nueva por petición).
    static let instructions: String = [
        localePrefix,
        "Eres el coach de pausas activas de Activate, una app para operadores de camión de extracción en minería chilena.",
        "La persona pasa 12 horas sentada con vibración, tiene poco tiempo y no quiere sermones.",
        "Tu trabajo: ajustar una pausa breve con ejercicios de un catálogo fijo, explicar en pocas palabras por qué y comentar cifras ya calculadas.",
        "Los sensores verifican los ejercicios; tú nunca decides si se hicieron ni cambias los puntajes.",
        "Usa solo los identificadores de ejercicio que te entregan como permitidos; nunca agregues otros.",
        "Nunca uses las palabras \"trampa\", \"apto\" o \"no apto\". Nada de tono infantil ni jerga.",
        "No hagas preguntas; no pidas más datos.",
        closingRule,
    ].joined(separator: "\n")

    // MARK: - Prompt de la pausa del día

    static func planPrompt(_ input: CoachInput) -> String {
        var lines: [String] = []
        lines.append("Trabajo: \(version).")
        lines.append("Persona: \(input.profileName) (trato: \(input.treatment == .usted ? "usted" : "tú")).")
        lines.append("Momento: \(input.moment.title). Minutos disponibles: \(input.minutesAvailable).")
        lines.append(rdqBlock(input.checkIn))
        if let zone = input.checkIn?.zone {
            lines.append("Zona que duele hoy: \(zone.title).")
        }
        lines.append("Plan suave hoy: \(input.gentle ? "sí (menos carga, más corto)" : "no").")
        lines.append("Receta base (id · ejercicio · meta):")
        for a in input.baseRecipe.activities {
            lines.append("- \(a.kind.rawValue) · \(a.kind.name) · \(a.target) \(a.kind.unit)")
        }
        let allowed = input.allowedKinds.map(\.rawValue).joined(separator: ", ")
        lines.append("Ids permitidos hoy: \(allowed.isEmpty ? "ninguno" : allowed). Use solo estos.")
        if !input.historyLines.isEmpty {
            lines.append("Historial reciente:")
            for h in input.historyLines.prefix(10) { lines.append("- \(h)") }
        }
        lines.append("Tarea: proponga la pausa de hoy a partir de la receta base.")
        lines.append("Reglas: entre 1 y 5 ejercicios, sin repetir id; reps entre 1 y el doble de la meta; el total debe caber en \(input.minutesAvailable) minutos.")
        lines.append("razonamiento: máximo 2 frases. porQue: máximo 8 palabras, dice qué cambió y por qué. mensajeInicio: máximo 8 palabras, con el nombre \(input.profileName).")
        return lines.joined(separator: "\n")
    }

    /// Bloque RDQ-6 con el puntaje "x de 6" y las frases marcadas Sí, textuales del cuestionario.
    static func rdqBlock(_ checkIn: DailyCheckIn?) -> String {
        guard let checkIn, checkIn.answers.count == RDQ6.items.count else {
            return "Cuestionario de espalda (RDQ-6): sin responder hoy."
        }
        var lines = ["Cuestionario de espalda (RDQ-6): \(checkIn.score) de \(RDQ6.maxScore)."]
        let marked = zip(RDQ6.items, checkIn.answers).filter { $0.1 }.map { $0.0 }
        if marked.isEmpty {
            lines.append("Frases marcadas Sí: ninguna.")
        } else {
            lines.append("Frases marcadas Sí:")
            for m in marked { lines.append("- \"\(m)\"") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Prompt de la lectura de datos (3 frases)

    static func statsPrompt(_ summary: StatsSummary, profile: PlayerProfile) -> String {
        var lines: [String] = []
        lines.append("Trabajo: lectura-datos-v1.")
        lines.append("Persona: \(profile.name) (trato: \(profile.treatment == .usted ? "usted" : "tú")).")
        lines.append(contentsOf: figures(summary))
        lines.append("Tarea: escriba exactamente 3 frases cortas (máximo 12 palabras cada una) para \(profile.name), con estas cifras exactas: adherencia del turno, espalda hoy frente al turno anterior, y cuántas veces dijo Mejor después de la pausa.")
        lines.append("tendencia: mejorando si el RDQ del turno actual es menor que el anterior; empeorando si es mayor; estable si es parecido; sinDatos si falta alguno.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Prompt de la hoja para el kine

    static func kinePrompt(_ summary: StatsSummary, profile: PlayerProfile) -> String {
        var lines: [String] = []
        lines.append("Trabajo: hoja-kine-v1.")
        lines.append("Paciente: \(profile.name), operador de camión de extracción, turno \(profile.roster.rawValue), \(profile.shiftType.title.lowercased()). Zona habitual: \(profile.usualZone.title).")
        lines.append(contentsOf: figures(summary))
        if let t = summary.currentTurno, t.itemFrequency.count == RDQ6.items.count {
            lines.append("Frecuencia por frase del RDQ-6 en el turno actual (días con Sí):")
            for (item, n) in zip(RDQ6.items, t.itemFrequency) where n > 0 {
                lines.append("- \"\(item)\": \(n)")
            }
        }
        if !summary.currentTurnoDays.isEmpty {
            let days = summary.currentTurnoDays.map { d in
                "día \(d.dayInBlock): RDQ \(d.rdq.map(String.init) ?? "-"), pausas \(d.countedPauses)"
            }
            lines.append("Turno actual por día: " + days.joined(separator: "; ") + ".")
        }
        if !summary.worsensHints.isEmpty {
            lines.append("Correlaciones ya calculadas (qué lo empeora):")
            for h in summary.worsensHints.prefix(5) { lines.append("- \(h)") }
        }
        lines.append("Tarea: redacte una hoja breve para el kinesiólogo o la mutual, en tercera persona (\"el paciente\"), máximo 40 palabras por bloque, solo con estas cifras.")
        lines.append("Bloques: cuandoLeDuele (momento, zona, día del turno), queHizo (solo ejercicios verificados), queLoEmpeora (correlaciones), comoVa (RDQ por turno, % Mejor, adherencia), alertas (puntajes altos o nada que informar).")
        return lines.joined(separator: "\n")
    }

    /// Cifras compartidas por lectura y hoja: solo lo que calculó StatsEngine.
    static func figures(_ summary: StatsSummary) -> [String] {
        var lines: [String] = []
        if let t = summary.currentTurno {
            lines.append("Turno actual (\(t.label)): \(turnoLine(t))")
        } else {
            lines.append("Turno actual: sin datos.")
        }
        if let p = summary.previousTurno {
            lines.append("Turno anterior (\(p.label)): \(turnoLine(p))")
        } else {
            lines.append("Turno anterior: sin datos.")
        }
        if let today = summary.todayRDQ {
            lines.append("RDQ-6 de hoy: \(today) de \(RDQ6.maxScore).")
        } else {
            lines.append("RDQ-6 de hoy: sin responder.")
        }
        lines.append("Días seguidos con pausa: \(summary.streak). Pausas contadas en total: \(summary.totalCountedPauses).")
        if !summary.historyLines.isEmpty {
            lines.append("Historial:")
            for h in summary.historyLines.prefix(10) { lines.append("- \(h)") }
        }
        return lines
    }

    static func turnoLine(_ t: TurnoSummary) -> String {
        var parts: [String] = []
        parts.append("pausa en \(t.daysWithPause) de \(t.workDays) días")
        parts.append("\(t.countedPauses) pausas contadas")
        if let m = t.meanRDQ { parts.append("RDQ promedio \(CoachFormat.decimal(m)) de \(RDQ6.maxScore)") }
        if let mx = t.maxRDQ { parts.append("RDQ máximo \(mx)") }
        let answered = t.betterCount + t.sameCount + t.worseCount
        if answered > 0 {
            parts.append("después de la pausa: Mejor \(t.betterCount), Igual \(t.sameCount), Peor \(t.worseCount)")
        }
        parts.append("\(t.verifiedSteps) pasos y \(t.verifiedReps) repeticiones verificadas")
        if let rt = t.stroopMedianRTms { parts.append("reflejos mediana \(rt) ms") }
        return parts.joined(separator: "; ") + "."
    }
}

// MARK: - Pool de frases de plantilla (RuleBasedCoach y fallback del LLM)

nonisolated enum CoachPhrases {
    /// "Por qué" (≤ 8 palabras) según plan suave y momento.
    static func why(gentle: Bool, moment: Moment, removedSquat: Bool, seed: Int) -> String {
        if removedSquat {
            return pick(["Hoy sin sentadilla: espalda cargada.", "Sin sentadilla hoy; cuidamos la espalda.", "Hoy no agacharse: sin sentadilla."], seed)
        }
        if gentle {
            return pick(["Hoy suave: la espalda manda.", "Menos carga hoy, mismo hábito.", "Pausa corta y suave hoy."], seed)
        }
        switch moment {
        case .entrada: return pick(["Un minuto antes de subir.", "Cuello y vista antes del turno.", "Soltar antes de la cabina."], seed)
        case .colacion: return pick(["Caminar corta la vibración.", "Mitad de turno: moverse ayuda.", "Pasos y cuello en la colación."], seed)
        case .salida: return pick(["Soltar la espalda al bajar.", "Un minuto antes del bus.", "Cuello y vista al salir."], seed)
        case .campamento: return pick(["Pausa completa: cinco minutos.", "Con tiempo: la pausa entera.", "Campamento: espalda y reflejos."], seed)
        }
    }

    /// Mensaje de inicio (≤ 8 palabras) con nombre de pila y trato.
    static func start(name: String, treatment: Treatment, moment: Moment, gentle: Bool, seed: Int) -> String {
        let n = name.isEmpty ? "operador" : name
        if gentle {
            return pick(["Vamos, \(n). Sin apuro.", "Tranquilo, \(n). Paso a paso.", "\(n), hoy con calma."], seed)
        }
        switch treatment {
        case .usted:
            switch moment {
            case .entrada, .salida: return pick(["Vamos, \(n). Un minuto.", "\(n), un minuto y listo.", "Ahora, \(n). Es corto."], seed)
            case .colacion: return pick(["Vamos, \(n). Tres minutos.", "\(n), aproveche la colación.", "Ahora, \(n). Tres minutos."], seed)
            case .campamento: return pick(["Vamos, \(n). Cinco minutos.", "\(n), la pausa completa.", "Ahora, \(n). Con tiempo."], seed)
            }
        case .tu:
            switch moment {
            case .entrada, .salida: return pick(["Vamos, \(n). Un minuto.", "\(n), un minuto y listo.", "Dale, \(n). Es corto."], seed)
            case .colacion: return pick(["Vamos, \(n). Tres minutos.", "\(n), aprovecha la colación.", "Dale, \(n). Tres minutos."], seed)
            case .campamento: return pick(["Vamos, \(n). Cinco minutos.", "\(n), la pausa completa.", "Dale, \(n). Con tiempo."], seed)
            }
        }
    }

    /// Razonamiento de plantilla (texto interno, no se muestra grande).
    static func reasoning(gentle: Bool, removed: [ActivityKind]) -> String {
        var parts = ["Receta base del momento filtrada por las reglas de seguridad."]
        if !removed.isEmpty {
            parts.append("Se dejó fuera: " + removed.map(\.name).joined(separator: ", ") + ".")
        }
        if gentle { parts.append("Metas reducidas por puntaje alto en el cuestionario.") }
        return parts.joined(separator: " ")
    }

    static func pick(_ pool: [String], _ seed: Int) -> String {
        guard !pool.isEmpty else { return "" }
        let i = ((seed % pool.count) + pool.count) % pool.count
        return pool[i]
    }
}

// MARK: - Formato de cifras (es_CL)

nonisolated enum CoachFormat {
    static let locale = Locale(identifier: "es_CL")

    /// "4,2" con una decimal.
    static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// "2.300" con separador de miles.
    static func integer(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(locale))
    }

    /// "88 %".
    static func percent(_ numerator: Int, of denominator: Int) -> String {
        guard denominator > 0 else { return "0 %" }
        let p = Int((Double(numerator) / Double(denominator) * 100).rounded())
        return "\(p) %"
    }
}
