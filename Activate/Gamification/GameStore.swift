import Foundation
import Observation

// Dueño: agente "gamification".

nonisolated struct RewardLine: Sendable, Hashable, Identifiable, Codable {
    var id: UUID = UUID()
    var label: String
    var xp: Int
}

nonisolated struct SessionReward: Sendable, Hashable, Codable {
    var lines: [RewardLine]
    var totalXP: Int
    var counted: Bool
    var streak: Int
    var dayInBlock: Int
    var isDoblete: Bool
    var isTiroLimpio: Bool
    var newBadges: [Badge]
}

/// Racha por día laboral, casco automático, XP e insignias sobre `AppStore`.
/// La racha la calcula `StreakEngine` (puro) y se cachea aquí; la caché se invalida al mutar
/// y se revalida contra el libro mayor, así también sirve cuando otro módulo muta el store.
@Observable
final class GameStore {
    // MARK: Constantes (XP e insignias)

    /// Bono por la primera pausa contada del día laboral.
    static let firstPauseOfDayXP = 10
    /// Doblete: ayer laboral contado y hoy la primera contada.
    static let dobleteMultiplier = 2
    /// Fracción del XP base que entrega una actividad `reduced`.
    static let reducedXPFraction = 0.5
    /// Pausas contadas de receta Relevo para "Relevo cumplido".
    static let relevoCumplidoPauses = 5
    /// Pasos verificados acumulados para "Caminante del rajo".
    static let caminanteDelRajoSteps = 2_500

    private let store: AppStore

    private struct StreakCache {
        var dayKey: String
        var calendar: WorkCalendar
        var days: [String: WorkDay]
        var value: Int
    }
    @ObservationIgnored private var streakCache: StreakCache?

    init(store: AppStore) { self.store = store }

    // MARK: Estado

    var calendar: WorkCalendar { store.calendar }
    var todayKey: String { calendar.key(for: .now) }
    var streak: Int { streak(at: .now) }
    var cascos: Int { store.data.profile.cascos }
    var xp: Int { store.data.profile.xp }
    var badges: Set<Badge> { store.data.profile.badges }
    var pausedToday: Bool { StreakEngine.isCounted(store.data.workDays[todayKey]) }

    /// Registro de hoy (plantilla si todavía no existe).
    var today: WorkDay {
        StreakEngine.workDay(ofWorkDate: calendar.workDate(for: .now), in: store.data.workDays, calendar: calendar)
    }
    var dayInBlockToday: Int { today.dayInBlock }
    var isTurnoToday: Bool { today.kind == .turno }

    /// Ayer laboral contado y hoy todavía sin pausa: la próxima pausa es Doblete.
    var dobleteAvailable: Bool {
        StreakEngine.dobleteAvailable(days: store.data.workDays, calendar: calendar, at: .now)
    }
    /// Ayer se marcó el casco automático ("Ayer usó el casco. Racha a salvo.").
    var usedCascoYesterday: Bool {
        StreakEngine.usedCascoYesterday(days: store.data.workDays, calendar: calendar, at: .now)
    }
    /// Días con pausa contada del turno vigente (o del último, en bajada).
    var countedDaysThisTurno: Int {
        StreakEngine.countedDays(days: store.data.workDays, calendar: calendar, turnoContaining: .now)
    }

    /// Racha vigente en `date`. Cacheada: se recalcula solo si cambia el día, el calendario o el libro mayor.
    func streak(at date: Date) -> Int {
        let cal = calendar
        let key = cal.key(for: date)
        let days = store.data.workDays
        if let cached = streakCache, cached.dayKey == key, cached.calendar == cal, cached.days == days {
            return cached.value
        }
        let value = StreakEngine.streak(days: days, calendar: cal, at: date)
        streakCache = StreakCache(dayKey: key, calendar: cal, days: days, value: value)
        return value
    }

    // MARK: Cierre de día

    /// Cierra días laborales pasados sin pausa (casco automático) y repone el casco del turno.
    /// Llamar al arrancar y al volver a activo. No escribe si nada cambió.
    func applyDayRollover(now: Date = .now) {
        let result = StreakEngine.rollover(days: store.data.workDays, calendar: calendar, now: now)
        guard result.days != store.data.workDays || result.cascos != store.data.profile.cascos else { return }
        store.mutate { data in
            data.workDays = result.days
            data.profile.cascos = result.cascos
        }
        streakCache = nil
    }

    // MARK: Registro de la pausa

    /// Registra la sesión, calcula XP, racha, Doblete, insignias y la guarda en el store.
    @discardableResult
    func record(_ session: PauseSession) -> SessionReward {
        let cal = calendar
        var session = session
        if session.workDayKey.isEmpty { session.workDayKey = cal.key(for: session.startedAt) }
        let dayKey = session.workDayKey
        let dayInstant = StreakEngine.instant(forKey: dayKey, calendar: cal) ?? session.startedAt
        if session.turnoKey.isEmpty { session.turnoKey = cal.turnoKey(for: dayInstant) }

        var days = store.data.workDays
        var day = StreakEngine.workDay(forKey: dayKey, in: days, calendar: cal)
            ?? WorkDay(key: dayKey, kind: cal.kind(for: dayInstant),
                       dayInBlock: cal.dayInBlock(for: dayInstant), turnoKey: session.turnoKey)
        let firstCountedToday = !StreakEngine.isCounted(day)
        let isTurno = day.kind == .turno

        // Una pausa cuenta solo si el flujo la marcó y la verificación lo respalda:
        // `suspicious` no suma ni rompe; `simulated` queda fuera de todo.
        let counted = session.counted && !session.simulated && session.level >= .reduced
        session.counted = counted

        // XP por actividad: full = base, reduced = mitad, suspicious / simulated = 0.
        var lines: [RewardLine] = []
        var total = 0
        if !session.simulated && session.level > .suspicious {
            for activity in session.activities where activity.completed && !activity.skipped {
                let xp = Self.xp(for: activity)
                lines.append(RewardLine(label: Self.label(for: activity), xp: xp))
                total += xp
            }
        }

        var isDoblete = false
        if counted && firstCountedToday {
            lines.append(RewardLine(label: "Primera pausa del día", xp: Self.firstPauseOfDayXP))
            total += Self.firstPauseOfDayXP
            if isTurno && StreakEngine.previousWorkDayCounted(days: days, calendar: cal, at: dayInstant) {
                isDoblete = true
                let bonus = total * (Self.dobleteMultiplier - 1)
                lines.append(RewardLine(label: "Doblete: dos días seguidos (x2)", xp: bonus))
                total += bonus
            }
        }
        session.xpEarned = total

        // Libro mayor de la racha.
        if counted { day.countedPauses += 1 }
        days[dayKey] = day

        // Sesiones (reemplaza si ya existía la misma).
        var sessions = store.data.sessions
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }

        // Hitos.
        let streakNow = StreakEngine.streak(days: days, calendar: cal, at: dayInstant)
        let isTiroLimpio = counted && firstCountedToday && isTurno
            && StreakEngine.isTiroLimpio(days: days, calendar: cal, turnoContaining: dayInstant)

        // Insignias.
        var badges = store.data.profile.badges
        var newBadges: [Badge] = []
        func unlock(_ badge: Badge, if condition: Bool) {
            if condition, badges.insert(badge).inserted { newBadges.append(badge) }
        }
        unlock(.primeraPausa, if: counted)
        unlock(.doblete, if: isDoblete)
        unlock(.relevoCumplido, if: counted
               && sessions.filter { $0.counted && $0.recipe == .relevo60 }.count >= Self.relevoCumplidoPauses)
        unlock(.rajoCompleto, if: counted && Self.isRajoCompleto(session))
        unlock(.tiroLimpio, if: isTiroLimpio)
        unlock(.caminanteDelRajo, if: Self.verifiedSteps(in: sessions) >= Self.caminanteDelRajoSteps)

        store.mutate { data in
            data.workDays = days
            data.sessions = sessions
            data.profile.xp += total
            data.profile.badges = badges
        }
        streakCache = nil

        return SessionReward(lines: lines, totalXP: total, counted: counted, streak: streakNow,
                             dayInBlock: day.dayInBlock, isDoblete: isDoblete,
                             isTiroLimpio: isTiroLimpio, newBadges: newBadges)
    }

    // MARK: Reglas de XP e insignias

    static func xp(for activity: ActivityResult) -> Int {
        guard activity.completed, !activity.skipped else { return 0 }
        switch activity.level {
        case .full: return activity.kind.baseXP
        case .reduced: return Int((Double(activity.kind.baseXP) * reducedXPFraction).rounded())
        case .suspicious, .simulated: return 0
        }
    }

    static func label(for activity: ActivityResult) -> String {
        switch activity.level {
        case .full: activity.kind.name
        case .reduced: "\(activity.kind.name) · contada"
        case .suspicious, .simulated: "\(activity.kind.name) · sin verificar"
        }
    }

    /// Campamento de 5 minutos completo: todas sus actividades hechas y verificadas
    /// (la respiración, débil por naturaleza, basta con que esté contada).
    static func isRajoCompleto(_ session: PauseSession) -> Bool {
        guard session.recipe == .campamento5, !session.activities.isEmpty else { return false }
        return session.activities.allSatisfy { activity in
            guard activity.completed, !activity.skipped else { return false }
            return activity.level == .full || (activity.kind.weakByNature && activity.level == .reduced)
        }
    }

    /// Pasos verificados (`full`) acumulados en todas las pausas no simuladas.
    static func verifiedSteps(in sessions: [PauseSession]) -> Int {
        sessions.lazy
            .filter { !$0.simulated && $0.level > .suspicious }
            .flatMap(\.activities)
            .filter { $0.kind == .pasos && $0.level == .full && !$0.skipped }
            .reduce(0) { sum, activity in
                if case .steps(let count, _, _, _) = activity.metrics { return sum + count }
                return sum + activity.achieved
            }
    }
}
