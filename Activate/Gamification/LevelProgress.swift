import Foundation

// Dueño: paquete "gamification" (niveles por pausa completa, pedido del usuario del 2026-10-23).
//
// La pausa activa es UNA al día, y el nivel se gana día a día:
// - Crédito del día (0…1) = ejercicios completados / ejercicios planificados de esa pausa.
//   Completado = el verificador lo dio por cumplido (`completed`: llegó a la meta; en Reflejos 60 la meta
//   es la caja de 60 s con ensayos válidos suficientes), no se saltó y quedó verificado (`full`, o
//   `reduced` = contado con el sensor de respaldo). Saltado o fallido no suma.
// - Solo cuentan pausas verificadas: el coordinador la marcó (`counted`, bajo la firma) y no es simulada
//   ni sospechosa (`level >= .reduced`).
// - Denominador: lo planificado para esa pausa tras las reglas de salud. Cada ejercicio del plan deja un
//   `ActivityResult` (hecho o saltado), así que es `activities.count`: el plan suave o uno recortado por
//   el RDQ-6 también llega al 100 %. Excepción: la pausa rápida de 1 minuto (`RecipeKind.relevo60`) se
//   mide contra la ruta completa (`ActivityKind.sessionOrder.count`, 7): 2 de 2 ejercicios rápidos = 2/7.
// - Varias pausas el mismo día laboral (`WorkCalendar.key`): vale la MEJOR. Nunca más de 1 nivel por día.
// - Nivel = 1 + parte entera de la suma de créditos; el avance hacia el siguiente es la parte
//   fraccionaria, en porcentaje entero ("71 %"). 100 % de la pausa = +1 nivel ese día; 5 de 7 = +0,71,
//   que se arrastra y se suma con los días siguientes (5/7 + 5/7 = +1 nivel y 43 %).
// - Se deriva del historial de sesiones: sin campo persistido ni migración. El XP sigue igual para la
//   celebración y los premios; el nivel ya no sale del XP.

nonisolated struct LevelProgress: Sendable, Hashable {
    /// Crédito de un día laboral: la mejor pausa verificada de ese día.
    nonisolated struct Day: Sendable, Hashable, Identifiable {
        var dayKey: String
        var turnoKey: String
        var completed: Int
        var planned: Int
        /// Pausa que dio el crédito (la mejor del día).
        var sessionID: UUID
        var startedAt: Date

        var id: String { dayKey }
        /// 0…1. Nunca más de 1 nivel por día.
        var credit: Double { planned > 0 ? Double(min(max(0, completed), planned)) / Double(planned) : 0 }
        var isFull: Bool { planned > 0 && completed >= planned }
    }

    // MARK: Constantes

    /// Nivel con que parte todo el mundo (sin pausas).
    static let startLevel = 1
    /// Denominador de la pausa rápida de 1 minuto: la ruta completa.
    static var quickPauseDenominator: Int { ActivityKind.sessionOrder.count }
    /// Tolerancia de punto flotante al sumar fracciones (5/7 + 2/7 debe dar 1 exacto).
    static let epsilon = 1e-9

    // MARK: Estado (derivado)

    /// Un registro por día laboral con pausa verificada, en orden cronológico.
    var days: [Day]
    /// Día laboral de "hoy" (para el aporte de hoy).
    var todayKey: String

    var totalCredits: Double { days.reduce(0) { $0 + $1.credit } }
    var level: Int { Self.level(forCredits: totalCredits) }
    var nextLevel: Int { level + 1 }
    /// Parte fraccionaria de los créditos: avance hacia el siguiente nivel (0…<1).
    var fractionToNext: Double { Self.fraction(forCredits: totalCredits) }
    /// Avance en porcentaje entero (0…99): nunca muestra "100 %" sin haber subido de nivel.
    var percentToNext: Int { Self.percent(fractionToNext) }
    /// Días con la pausa completa (100 % de lo planificado).
    var fullDays: Int { days.filter(\.isFull).count }
    /// Días con alguna pausa verificada.
    var daysWithPause: Int { days.count }

    var today: Day? { days.last { $0.dayKey == todayKey } }
    var todayCredit: Double { today?.credit ?? 0 }
    var todayCompleted: Int { today?.completed ?? 0 }
    var todayPlanned: Int { today?.planned ?? 0 }

    // MARK: Cálculo

    /// Nivel desde el historial. `calendar` resuelve el día laboral de sesiones sin clave y el de hoy.
    static func compute(sessions: [PauseSession], calendar: WorkCalendar, now: Date = .now) -> LevelProgress {
        var best: [String: Day] = [:]
        for session in sessions {
            guard let credit = credit(for: session) else { continue }
            let key = session.workDayKey.isEmpty ? calendar.key(for: session.startedAt) : session.workDayKey
            let turno = session.turnoKey.isEmpty ? calendar.turnoKey(for: session.startedAt) : session.turnoKey
            let day = Day(dayKey: key, turnoKey: turno, completed: credit.completed, planned: credit.planned,
                          sessionID: session.id, startedAt: session.startedAt)
            if let current = best[key], !isBetter(day, than: current) { continue }
            best[key] = day
        }
        return LevelProgress(days: best.values.sorted { $0.dayKey < $1.dayKey }, todayKey: calendar.key(for: now))
    }

    /// (completados, planificados) de una pausa verificada; `nil` si la pausa no cuenta para el nivel.
    static func credit(for session: PauseSession) -> (completed: Int, planned: Int)? {
        guard isVerified(session) else { return nil }
        let planned = plannedCount(for: session)
        guard planned > 0 else { return nil }
        let completed = session.activities.filter(isCompleted).count
        return (min(completed, planned), planned)
    }

    /// La marcó el coordinador (≥ 1 actividad `full`, sin integridad dura, con check-in y cierre) y no es
    /// simulada ni sospechosa. Mismo criterio que `GameStore.counts` más el nivel de la sesión.
    static func isVerified(_ session: PauseSession) -> Bool {
        session.counted && !session.simulated && session.level >= .reduced
    }

    /// Hecha y verificada: llegó a la meta, no se saltó y no es sospechosa ni simulada.
    static func isCompleted(_ activity: ActivityResult) -> Bool {
        activity.completed && !activity.skipped && activity.level >= .reduced
    }

    /// Ejercicios planificados: los del plan de esa pausa (ya con las reglas de salud); la pausa rápida,
    /// contra la ruta completa.
    static func plannedCount(for session: PauseSession) -> Int {
        session.recipe == .relevo60 ? max(quickPauseDenominator, session.activities.count) : session.activities.count
    }

    /// Mejor crédito; a igual crédito, más ejercicios hechos; luego la primera del día (estable).
    static func isBetter(_ a: Day, than b: Day) -> Bool {
        if abs(a.credit - b.credit) > epsilon { return a.credit > b.credit }
        if a.completed != b.completed { return a.completed > b.completed }
        return a.startedAt < b.startedAt
    }

    static func level(forCredits credits: Double) -> Int {
        startLevel + Int((max(0, credits) + epsilon).rounded(.down))
    }

    static func fraction(forCredits credits: Double) -> Double {
        let c = max(0, credits)
        let f = c - (c + epsilon).rounded(.down)
        return f > epsilon ? f : 0
    }

    /// Porcentaje entero de una fracción 0…<1: 0 solo si no hay avance; nunca 100 sin subir de nivel.
    static func percent(_ fraction: Double) -> Int {
        guard fraction > epsilon else { return 0 }
        return min(99, max(1, Int((fraction * 100).rounded())))
    }

    /// El nivel tal como estaba al cerrar el día `dayKey` (incluido).
    func through(dayKey: String) -> LevelProgress {
        LevelProgress(days: days.filter { $0.dayKey <= dayKey }, todayKey: todayKey)
    }

    /// El nivel tal como estaba al cerrar el turno `turnoKey` (sus días y los de turnos anteriores).
    func through(turnoKey: String) -> LevelProgress {
        LevelProgress(days: days.filter { $0.turnoKey <= turnoKey }, todayKey: todayKey)
    }

    /// Días con pausa completa dentro del turno `turnoKey`.
    func fullDays(inTurno turnoKey: String) -> Int {
        days.filter { $0.turnoKey == turnoKey && $0.isFull }.count
    }

    // MARK: Textos (español de Chile, de usted, espacio duro antes de "%")

    static let nbsp = "\u{00A0}"

    /// "71 %".
    static func percentText(_ value: Int) -> String { "\(value)\(nbsp)%" }

    /// "Nivel 4 · 71 % hacia el nivel 5".
    var levelLine: String {
        "Nivel \(level) · \(Self.percentText(percentToNext)) hacia el nivel \(nextLevel)"
    }

    /// "Nivel 4 · 71 %" (chip del reporte).
    var shortValue: String { "Nivel \(level) · \(Self.percentText(percentToNext))" }

    /// "4 · 71 %" (columna de la tabla por turno).
    var compactValue: String { "\(level) · \(Self.percentText(percentToNext))" }

    /// "6 días con pausa completa de 9 días con pausa".
    var fullDaysLine: String {
        guard daysWithPause > 0 else { return "Sin pausas verificadas todavía" }
        return "\(Self.days(fullDays)) con pausa completa de \(Self.days(daysWithPause)) con pausa"
    }

    /// "Hoy: 5 de 7 ejercicios (+71 %)"; con la pausa completa, "(+1 nivel)". `nil` sin pausa hoy.
    var todayLine: String? {
        guard let today else { return nil }
        let noun = today.planned == 1 ? "ejercicio" : "ejercicios"
        return "Hoy: \(today.completed) de \(today.planned) \(noun) (\(Self.contributionText(today)))"
    }

    /// "+1 nivel" con la pausa completa; si no, "+71 %" (nunca "+100 %" sin completarla).
    static func contributionText(_ day: Day) -> String {
        day.isFull ? "+1 nivel" : "+" + percentText(percent(day.credit))
    }

    /// "1 día", "9 días".
    static func days(_ n: Int) -> String { n == 1 ? "1 día" : "\(n) días" }
}
