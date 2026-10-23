import Foundation

// Dueño: agente "stats-engine". Helpers de texto puros (sin UI) que usan las vistas de
// Estadísticas, la hoja del kine y las líneas de historial del coach. Todo en español de Chile,
// trato de usted, frases cortas, sin etiquetas de aptitud laboral.

nonisolated enum StatsFormatting {

    /// Espacio duro para que "88 %" y "2 de 6" no se partan al final de una línea.
    static let nbsp = "\u{00A0}"

    /// Abreviaturas de mes fijas (no dependen de la configuración regional del sistema).
    static let monthAbbreviations = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]

    // MARK: - Fechas y turnos

    /// Componentes (año, mes, día) de una clave "yyyy-MM-dd". `nil` si la clave está mal formada.
    static func components(ofKey key: String) -> (year: Int, month: Int, day: Int)? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// "12 oct" a partir de una clave de día laboral o de turno.
    static func shortDate(forKey key: String) -> String {
        guard let c = components(ofKey: key) else { return key }
        return "\(c.day) \(monthAbbreviations[c.month - 1])"
    }

    /// "12 oct" a partir de una fecha.
    static func shortDate(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        guard let month = c.month, let day = c.day, (1...12).contains(month) else { return "" }
        return "\(day) \(monthAbbreviations[month - 1])"
    }

    /// "Turno del 12 oct".
    static func turnoLabel(forKey turnoKey: String) -> String {
        "Turno del \(shortDate(forKey: turnoKey))"
    }

    /// "Este turno" si la clave es la del turno actual; si no, "Turno del 12 oct".
    static func turnoLabel(forKey turnoKey: String, currentTurnoKey: String?) -> String {
        turnoKey == currentTurnoKey ? "Este turno" : turnoLabel(forKey: turnoKey)
    }

    /// "Día 2 de 7".
    static func dayInBlockLabel(_ day: Int, of total: Int) -> String {
        "Día \(day) de \(total)"
    }

    /// Distancia en días laborales entre dos claves "yyyy-MM-dd" (positiva si `to` es posterior).
    static func daysBetween(_ fromKey: String, _ toKey: String, calendar: Calendar = .current) -> Int? {
        guard let a = components(ofKey: fromKey), let b = components(ofKey: toKey),
              let da = calendar.date(from: DateComponents(year: a.year, month: a.month, day: a.day)),
              let db = calendar.date(from: DateComponents(year: b.year, month: b.month, day: b.day)) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: da), to: calendar.startOfDay(for: db)).day
    }

    /// "Hoy", "Ayer", "Hace 3 días" o "12 oct" (más de 6 días), según la distancia al día laboral de hoy.
    static func relativeDayLabel(workDayKey: String, todayKey: String, calendar: Calendar = .current) -> String {
        guard let diff = daysBetween(workDayKey, todayKey, calendar: calendar), diff >= 0 else {
            return shortDate(forKey: workDayKey)
        }
        switch diff {
        case 0: return "Hoy"
        case 1: return "Ayer"
        case 2...6: return "Hace \(diff) días"
        default: return shortDate(forKey: workDayKey)
        }
    }

    // MARK: - Números

    /// "4 de 7".
    static func xOfY(_ x: Int, _ y: Int) -> String {
        "\(x) de \(y)"
    }

    /// "88 %" (porcentaje redondeado, con espacio duro al estilo chileno). `fraction` va de 0 a 1.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))\(nbsp)%"
    }

    /// "88 %" de `part` sobre `total`; "—" si no hay total.
    static func percent(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        return percent(Double(part) / Double(total))
    }

    /// "2,5" con coma decimal (Chile). Sin decimales si el número es entero y `digits` es 0.
    static func decimal(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// "2 de 6" o "—" si no hay check-in.
    static func rdq(_ score: Int?) -> String {
        guard let score else { return "—" }
        return xOfY(score, RDQ6.maxScore)
    }

    /// "RDQ 2 de 6".
    static func rdqLabel(_ score: Int?) -> String {
        "RDQ \(rdq(score))"
    }

    /// "vs turno pasado 4" o "" si no hay turno anterior con RDQ.
    static func comparisonWithPrevious(_ previousMeanRDQ: Double?) -> String {
        guard let previousMeanRDQ else { return "" }
        return "vs turno pasado \(decimal(previousMeanRDQ, digits: previousMeanRDQ.rounded() == previousMeanRDQ ? 0 : 1))"
    }

    /// Diferencia de RDQ promedio entre turnos como texto corto: "baja 1,5", "sube 0,5" o "igual".
    static func trendLabel(current: Double?, previous: Double?) -> String {
        guard let current, let previous else { return "" }
        let delta = current - previous
        if abs(delta) < 0.25 { return "igual" }
        return delta < 0 ? "baja \(decimal(abs(delta)))" : "sube \(decimal(delta))"
    }

    // MARK: - Plurales

    /// "1 día seguido" / "3 días seguidos".
    static func streakLabel(_ days: Int) -> String {
        days == 1 ? "1 día seguido" : "\(days) días seguidos"
    }

    /// "1 pausa" / "8 pausas".
    static func pausesLabel(_ count: Int) -> String {
        count == 1 ? "1 pausa" : "\(count) pausas"
    }

    /// "1 día" / "4 días".
    static func daysLabel(_ count: Int) -> String {
        count == 1 ? "1 día" : "\(count) días"
    }

    /// "4 de 5 días con pausa".
    static func daysWithPauseLabel(_ daysWithPause: Int, of elapsed: Int) -> String {
        "\(xOfY(daysWithPause, elapsed)) días con pausa"
    }

    /// Días del turno ya transcurridos (hasta hoy incluido). Si hoy no está en la lista, el turno ya terminó: todos.
    static func elapsedDays(in days: [DayStat]) -> Int {
        guard let todayIndex = days.firstIndex(where: { $0.isToday }) else { return days.count }
        return todayIndex + 1
    }

    /// "7 de 8" sesiones con Mejor a partir del turno.
    static func betterLabel(_ turno: TurnoSummary) -> String {
        xOfY(turno.betterCount, turno.betterCount + turno.sameCount + turno.worseCount)
    }

    /// Fracción de cierres "Mejor" (0-1) o `nil` sin cierres.
    static func betterShare(_ turno: TurnoSummary) -> Double? {
        let total = turno.betterCount + turno.sameCount + turno.worseCount
        guard total > 0 else { return nil }
        return Double(turno.betterCount) / Double(total)
    }

    // MARK: - Sesiones

    /// Nombre corto de la actividad para líneas de historial y tablas: "cuello", "caminata".
    static func activityName(_ kind: ActivityKind) -> String {
        switch kind {
        case .extensionLumbar: "extensión lumbar"
        case .pasos: "caminata"
        case .sentadilla: "sentadilla"
        case .cuello: "movilidad cervical"
        case .respiracion: "respiración"
        case .ojos: "ojos"
        case .stroop: "reflejos"
        }
    }

    /// Momento en minúscula para frases: "colación", "entrada".
    static func momentPhrase(_ moment: Moment) -> String {
        switch moment {
        case .entrada: "entrada"
        case .colacion: "colación"
        case .salida: "salida"
        case .campamento: "campamento"
        }
    }

    /// "pausa verificada" / "pausa contada" / "pausa sin verificar" / "pausa simulada".
    static func levelPhrase(_ level: VerificationLevel) -> String {
        switch level {
        case .full: "pausa verificada"
        case .reduced: "pausa contada"
        case .suspicious: "pausa sin verificar"
        case .simulated: "pausa simulada"
        }
    }

    /// "después mejor" / "después igual" / "después peor" / "sin cierre".
    static func postPhrase(_ post: PostResponse?) -> String {
        guard let post else { return "sin cierre" }
        return "después \(post.title.lowercased())"
    }

    /// Lista corta de actividades: "caminata, cuello y ojos".
    static func activityList(_ kinds: [ActivityKind]) -> String {
        let names = kinds.map(activityName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " y " + names[names.count - 1]
        }
    }

    /// Resumen de una sesión en una línea: "Ayer colación: RDQ 3, pausa verificada, después mejor".
    static func sessionLine(_ digest: SessionDigest, todayKey: String, calendar: Calendar = .current) -> String {
        let day = relativeDayLabel(workDayKey: digest.workDayKey, todayKey: todayKey, calendar: calendar)
        let rdqText = digest.checkInScore.map { "RDQ \($0)" } ?? "sin RDQ"
        return "\(day) \(momentPhrase(digest.moment)): \(rdqText), \(levelPhrase(digest.level)), \(postPhrase(digest.post))"
    }
}
