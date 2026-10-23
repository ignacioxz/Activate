import Foundation

/// Estado de una insignia en Hoy: ganada (y si fue hoy) o cuánto falta, con datos verificados reales.
nonisolated struct BadgeStatus: Sendable, Hashable, Identifiable {
    var badge: Badge
    var earned: Bool
    /// Se ganó con las pausas de hoy.
    var earnedToday: Bool
    /// "Ganada", "Con la pausa de hoy", "1.500 de 2.500 pasos"…
    var status: String
    /// Barra de avance (0...1); `nil` cuando no hay nada que medir todavía o ya está ganada.
    var progress: Double?
    /// Se gana con la próxima pausa contada de hoy.
    var highlight: Bool
    /// Qué tan cerca está (0...1): ordena de la más cercana a la más lejana.
    var closeness: Double

    var id: Badge { badge }

    /// VoiceOver: "Insignia Doblete: con la pausa de hoy."
    var spoken: String {
        "Insignia \(badge.title): \(status.prefix(1).lowercased() + status.dropFirst())\(status.hasSuffix(".") ? "" : ".")"
    }
}

/// Avance hacia las 6 insignias con las mismas reglas con que `GameStore.recording` las entrega.
nonisolated enum BadgeProgress {
    /// Texto para las que ya no se pueden lograr en este turno.
    static let nextTurnoLine = "Se intenta el próximo turno."
    static let withTodayPauseLine = "Con la pausa de hoy"

    /// Nombre corto para las fichas ("Insignia Tiro limpio").
    static func shortTitle(_ badge: Badge) -> String {
        badge == .tiroLimpio ? "Tiro limpio" : badge.title
    }

    /// Los datos ya cumplen la regla de la insignia. Con `beforeKey`, solo con lo anterior a ese día
    /// laboral ("yyyy-MM-dd"): así se sabe si se ganó hoy sin guardar la fecha.
    static func conditionMet(_ badge: Badge, data: SaveData, calendar: WorkCalendar, beforeKey: String? = nil) -> Bool {
        let sessions = beforeKey.map { key in data.sessions.filter { $0.workDayKey < key } } ?? data.sessions
        let days = beforeKey.map { key in data.workDays.filter { $0.key < key } } ?? data.workDays
        switch badge {
        case .primeraPausa:
            return sessions.contains(where: GameStore.counts)
        case .doblete:
            return days.values.contains { day in
                guard StreakEngine.isCounted(day),
                      let instant = StreakEngine.instant(forKey: day.key, calendar: calendar),
                      calendar.kind(for: instant) == .turno else { return false }
                return StreakEngine.previousWorkDayCounted(days: days, calendar: calendar, at: instant)
            }
        case .relevoCumplido:
            return GameStore.relevoPauses(in: sessions) >= GameStore.relevoCumplidoPauses
        case .rajoCompleto:
            return sessions.contains { GameStore.counts($0) && GameStore.isRajoCompleto($0) }
        case .tiroLimpio:
            return days.values.contains { day in
                guard StreakEngine.isCounted(day),
                      let instant = StreakEngine.instant(forKey: day.key, calendar: calendar),
                      calendar.kind(for: instant) == .turno else { return false }
                return StreakEngine.isTiroLimpio(days: days, calendar: calendar, turnoContaining: instant)
            }
        case .caminanteDelRajo:
            return GameStore.verifiedSteps(in: sessions) >= GameStore.caminanteDelRajoSteps
        }
    }

    /// Insignias ganadas con lo de hoy: están en el perfil, los datos las cumplen y sin hoy no las cumplían.
    static func earnedToday(data: SaveData, calendar: WorkCalendar, todayKey: String) -> [Badge] {
        Badge.allCases.filter { badge in
            data.profile.badges.contains(badge)
                && conditionMet(badge, data: data, calendar: calendar)
                && !conditionMet(badge, data: data, calendar: calendar, beforeKey: todayKey)
        }
    }

    /// Mejor avance de "Rajo completo": ejercicios de la ruta verificados en una sola pausa de ruta completa.
    static func bestRajoCount(sessions: [PauseSession]) -> Int {
        sessions
            .filter { !$0.simulated && $0.recipe == .campamento5 }
            .map { session in
                Set(session.activities.filter(GameStore.isVerifiedDone).map(\.kind))
                    .intersection(GameStore.rajoCompletoKinds).count
            }
            .max() ?? 0
    }

    /// Las 6 insignias, la más cercana primero y las ganadas al final (las de hoy antes).
    static func statuses(data: SaveData, calendar: WorkCalendar, facts: HoyFacts) -> [BadgeStatus] {
        let todayEarned = Set(earnedToday(data: data, calendar: calendar, todayKey: facts.todayKey))
        let all = Badge.allCases.map { badge -> BadgeStatus in
            if data.profile.badges.contains(badge) {
                let today = todayEarned.contains(badge)
                return BadgeStatus(badge: badge, earned: true, earnedToday: today,
                                   status: today ? "Ganada hoy" : "Ganada", progress: nil, highlight: false, closeness: 1)
            }
            return pending(badge, data: data, facts: facts)
        }
        return sorted(all)
    }

    static func sorted(_ statuses: [BadgeStatus]) -> [BadgeStatus] {
        func order(_ badge: Badge) -> Int { Badge.allCases.firstIndex(of: badge) ?? 0 }
        let pending = statuses.filter { !$0.earned }.sorted { a, b in
            if a.highlight != b.highlight { return a.highlight }
            if a.closeness != b.closeness { return a.closeness > b.closeness }
            return order(a.badge) < order(b.badge)
        }
        let earned = statuses.filter(\.earned).sorted { a, b in
            if a.earnedToday != b.earnedToday { return a.earnedToday }
            return order(a.badge) < order(b.badge)
        }
        return pending + earned
    }

    private static func pending(_ badge: Badge, data: SaveData, facts: HoyFacts) -> BadgeStatus {
        func status(_ text: String, progress: Double? = nil, highlight: Bool = false, closeness: Double = 0) -> BadgeStatus {
            BadgeStatus(badge: badge, earned: false, earnedToday: false, status: text,
                        progress: progress.map { min(1, max(0, $0)) }, highlight: highlight,
                        closeness: highlight ? 1 : min(1, max(0, closeness)))
        }
        let turno = facts.kind == .turno
        switch badge {
        case .primeraPausa:
            return status(withTodayPauseLine, highlight: true)
        case .doblete:
            if facts.dobleteAvailable { return status(withTodayPauseLine, highlight: true) }
            guard turno, !facts.isLastDay else { return status(nextTurnoLine) }
            if facts.pausedToday { return status("Mañana, con otra pausa", progress: 0.5, closeness: 0.5) }
            return status("Hoy y mañana con pausa")
        case .relevoCumplido:
            let n = GameStore.relevoPauses(in: data.sessions)
            let goal = GameStore.relevoCumplidoPauses
            let fraction = Double(n) / Double(goal)
            return status("\(n) de \(goal) pausas en un relevo", progress: n > 0 ? fraction : nil, closeness: fraction)
        case .rajoCompleto:
            let best = bestRajoCount(sessions: data.sessions)
            let total = GameStore.rajoCompletoKinds.count
            guard best > 0 else { return status("Ruta completa, todo verificado") }
            let fraction = Double(best) / Double(total)
            return status("\(best) de \(total) ejercicios en una pausa", progress: fraction, closeness: fraction)
        case .tiroLimpio:
            guard turno, facts.tiroLimpioPossible else { return status(nextTurnoLine) }
            if facts.isLastDay && !facts.pausedToday { return status(withTodayPauseLine, highlight: true) }
            let fraction = Double(facts.countedDaysThisTurno) / Double(max(1, facts.workDays))
            return status("\(facts.countedDaysThisTurno) de \(facts.workDays) días",
                          progress: facts.countedDaysThisTurno > 0 ? fraction : nil, closeness: fraction)
        case .caminanteDelRajo:
            let steps = GameStore.verifiedSteps(in: data.sessions)
            let goal = GameStore.caminanteDelRajoSteps
            let fraction = Double(steps) / Double(goal)
            return status("\(SpanishDate.thousands(steps)) de \(SpanishDate.thousands(goal)) pasos",
                          progress: steps > 0 ? fraction : nil, closeness: fraction)
        }
    }
}
