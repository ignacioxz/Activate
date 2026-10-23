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

/// Racha por día laboral, comodín automático (internamente "casco"), XP e insignias sobre `AppStore`.
/// La racha la calcula `StreakEngine` (puro) y se cachea aquí; la caché se invalida al mutar
/// y se revalida contra el libro mayor, así también sirve cuando otro módulo muta el store.
@Observable
final class GameStore {
    // MARK: Constantes (XP e insignias)

    /// Bono por la primera pausa contada del día laboral.
    nonisolated static let firstPauseOfDayXP = 10
    /// Doblete: ayer laboral contado y hoy la primera contada.
    nonisolated static let dobleteMultiplier = 2
    /// Fracción del XP base que entrega una actividad `reduced`.
    nonisolated static let reducedXPFraction = 0.5
    /// Pausas contadas de ruta completa en un relevo (entrada o salida) para "Relevo cumplido".
    nonisolated static let relevoCumplidoPauses = 5
    /// Pasos verificados acumulados para "Caminante del rajo".
    nonisolated static let caminanteDelRajoSteps = 2_500

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
    /// Ayer se usó el comodín automático ("Ayer se usó su comodín: racha a salvo.").
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

    // MARK: Nivel (pausa completa por día; reglas en `LevelProgress`)

    /// Nivel derivado del historial: cada día con la pausa completa sube 1 nivel y una pausa parcial suma
    /// su parte (5 de 7 = +71 %), que se arrastra a los días siguientes. No sale del XP.
    var levelProgress: LevelProgress { levelProgress(at: .now) }

    /// Nivel con `date` como "hoy" (para el aporte del día).
    func levelProgress(at date: Date) -> LevelProgress {
        LevelProgress.compute(sessions: store.data.sessions, calendar: calendar, now: date)
    }

    // MARK: Cierre de día

    /// Cierra días laborales pasados sin pausa (comodín automático) y repone el comodín del turno.
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
        let result = Self.recording(session, in: store.data, calendar: calendar)
        store.mutate { data in
            data.workDays = result.data.workDays
            data.sessions = result.data.sessions
            data.profile.xp = result.data.profile.xp
            data.profile.badges = result.data.profile.badges
        }
        streakCache = nil
        return result.reward
    }

    /// Lógica pura de `record`: devuelve los datos con la sesión registrada (libro mayor, sesiones,
    /// XP e insignias) y la recompensa. No toca el store; la usan `record` y los escenarios de QA.
    nonisolated static func recording(_ session: PauseSession, in input: SaveData,
                                      calendar cal: WorkCalendar) -> (data: SaveData, reward: SessionReward) {
        var data = input
        var session = session
        if session.workDayKey.isEmpty { session.workDayKey = cal.key(for: session.startedAt) }
        let dayKey = session.workDayKey
        let dayInstant = StreakEngine.instant(forKey: dayKey, calendar: cal) ?? session.startedAt
        if session.turnoKey.isEmpty { session.turnoKey = cal.turnoKey(for: dayInstant) }

        var days = data.workDays
        var day = StreakEngine.workDay(forKey: dayKey, in: days, calendar: cal)
            ?? WorkDay(key: dayKey, kind: cal.kind(for: dayInstant),
                       dayInBlock: cal.dayInBlock(for: dayInstant), turnoKey: session.turnoKey)
        let firstCountedToday = !StreakEngine.isCounted(day)
        let isTurno = day.kind == .turno

        // Si cuenta lo decide el coordinador (≥ 1 actividad `full`, sin integridad dura, con check-in)
        // y queda bajo la firma: aquí no se recalcula ni se reescribe. `simulated` queda fuera de todo.
        let counted = Self.counts(session)

        // XP por actividad: full = base, reduced = mitad, suspicious / simulated = 0.
        // Una sesión `suspicious` no anula las actividades que sí se verificaron.
        var lines: [RewardLine] = []
        var total = 0
        if !session.simulated {
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
        var sessions = data.sessions
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
        var badges = data.profile.badges
        var newBadges: [Badge] = []
        func unlock(_ badge: Badge, if condition: Bool) {
            if condition, badges.insert(badge).inserted { newBadges.append(badge) }
        }
        unlock(.primeraPausa, if: counted)
        unlock(.doblete, if: isDoblete)
        unlock(.relevoCumplido, if: counted && Self.relevoPauses(in: sessions) >= Self.relevoCumplidoPauses)
        unlock(.rajoCompleto, if: counted && Self.isRajoCompleto(session))
        unlock(.tiroLimpio, if: isTiroLimpio)
        unlock(.caminanteDelRajo, if: Self.verifiedSteps(in: sessions) >= Self.caminanteDelRajoSteps)

        data.workDays = days
        data.sessions = sessions
        data.profile.xp += total
        data.profile.badges = badges

        let reward = SessionReward(lines: lines, totalXP: total, counted: counted, streak: streakNow,
                                   dayInBlock: day.dayInBlock, isDoblete: isDoblete,
                                   isTiroLimpio: isTiroLimpio, newBadges: newBadges)
        return (data, reward)
    }

    // MARK: Reglas de XP e insignias

    /// La pausa vale para racha / Doblete / Tiro limpio: lo marcó el coordinador y no es simulada.
    nonisolated static func counts(_ session: PauseSession) -> Bool {
        session.counted && !session.simulated
    }

    nonisolated static func xp(for activity: ActivityResult) -> Int {
        guard activity.completed, !activity.skipped else { return 0 }
        switch activity.level {
        case .full: return activity.kind.baseXP
        case .reduced: return Int((Double(activity.kind.baseXP) * reducedXPFraction).rounded())
        case .suspicious, .simulated: return 0
        }
    }

    nonisolated static func label(for activity: ActivityResult) -> String {
        switch activity.level {
        case .full: activity.kind.name
        case .reduced: "\(activity.kind.name) · contada"
        case .suspicious, .simulated: "\(activity.kind.name) · sin verificar"
        }
    }

    /// Actividades que exige "Rajo completo": la receta Campamento completa (las 7).
    nonisolated static var rajoCompletoKinds: Set<ActivityKind> {
        Set(Recipes.base(.campamento5, demo: false).activities.map(\.kind))
    }

    /// Una actividad hecha y verificada (la respiración, débil por naturaleza, basta con que esté contada).
    nonisolated static func isVerifiedDone(_ activity: ActivityResult) -> Bool {
        guard activity.completed, !activity.skipped else { return false }
        return activity.level == .full || (activity.kind.weakByNature && activity.level == .reduced)
    }

    /// Campamento de 5 minutos completo: cubre la receta Campamento entera y todas sus
    /// actividades quedaron hechas y verificadas. Un plan recortado (suave, o con saltos) no basta.
    nonisolated static func isRajoCompleto(_ session: PauseSession) -> Bool {
        guard session.recipe == .campamento5, !session.simulated, !session.activities.isEmpty,
              session.activities.allSatisfy(isVerifiedDone) else { return false }
        let done = Set(session.activities.map(\.kind))
        return rajoCompletoKinds.isSubset(of: done)
    }

    /// Pausas contadas de ruta completa hechas en un relevo (entrada o salida): el avance de "Relevo cumplido".
    /// Las antiguas pausas rápidas (`relevo60`) no son ruta completa y no suman.
    nonisolated static func relevoPauses(in sessions: [PauseSession]) -> Int {
        sessions.filter { counts($0) && $0.moment.isRelevo && $0.recipe != .relevo60 }.count
    }

    // MARK: Vista previa del XP ("hasta")

    /// Máximo XP que puede dar una actividad: el de su mejor nivel posible (la respiración, débil por
    /// naturaleza, llega a `reduced` y paga la mitad), con las mismas reglas que `xp(for:)`.
    nonisolated static func maxXP(for kind: ActivityKind) -> Int {
        let best: VerificationLevel = kind.weakByNature ? .reduced : .full
        return xp(for: ActivityResult(kind: kind, target: 1, achieved: 1, durationSeconds: 0, completed: true,
                                      level: best, metrics: .none, anomalies: []))
    }

    /// Lo más que puede sumar la próxima pausa con estas actividades, con las reglas de `recording`:
    /// suma de actividades + bono de primera pausa del día (si todavía no hay una contada), todo ×2
    /// con Doblete. Es un techo: el plan puede recortarse por dolor y una actividad `reduced` paga la mitad.
    nonisolated static func previewXP(kinds: [ActivityKind], firstCountedToday: Bool, doblete: Bool) -> Int {
        let activities = kinds.reduce(0) { $0 + maxXP(for: $1) }
        guard firstCountedToday else { return activities }
        let withBonus = activities + firstPauseOfDayXP
        return doblete ? withBonus * dobleteMultiplier : withBonus
    }

    /// Pasos verificados (actividad `full`) acumulados en todas las pausas no simuladas.
    /// Se mira el nivel de cada actividad, no el de la sesión.
    nonisolated static func verifiedSteps(in sessions: [PauseSession]) -> Int {
        sessions.lazy
            .filter { !$0.simulated }
            .flatMap(\.activities)
            .filter { $0.kind == .pasos && $0.level == .full && !$0.skipped }
            .reduce(0) { sum, activity in
                if case .steps(let count, _, _, _) = activity.metrics { return sum + count }
                return sum + activity.achieved
            }
    }
}
