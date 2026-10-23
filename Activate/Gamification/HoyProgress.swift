import Foundation

// Lógica pura de la pantalla Hoy (gamificación del turno). Sin UI ni reloj: todo recibe `SaveData`,
// el `WorkCalendar` del perfil y `now`, así se prueba cada estado del día (día 1, días 3-6, día 7,
// comodín, bajada, pausa hecha, pausa no verificada) sin tocar `.now`.
// Reglas: solo se gamifica lo verificado; nunca se premia el dolor ni "Mejor"; nunca "racha rota";
// toda vista previa de XP dice "hasta" (el plan puede recortarse y una actividad `reduced` paga la mitad).

// MARK: - Hechos del día

/// Hechos del día laboral que comparten todas las tarjetas de Hoy.
nonisolated struct HoyFacts: Sendable, Equatable {
    var now: Date
    var todayKey: String
    var kind: DayKind
    var dayInBlock: Int
    var workDays: Int
    var isLastDay: Bool
    var pausedToday: Bool
    var streak: Int
    /// Racha si la pausa de hoy cuenta (igual a `streak` si ya contó o si es bajada).
    var streakIfPaused: Int
    /// Ayer contado y hoy (turno) sin pausa: la próxima pausa va x2.
    var dobleteAvailable: Bool
    /// Hoy (turno) contado con ayer contado: hoy fue Doblete.
    var dobleteToday: Bool
    /// Turno y todos los días anteriores del turno con pausa contada (hoy pendiente o contado).
    var tiroLimpioPossible: Bool
    /// Último día del turno con los 7 días contados.
    var tiroLimpioToday: Bool
    var usedComodinYesterday: Bool
    var countedDaysThisTurno: Int
    var cascos: Int
    /// XP de las sesiones de hoy (ya sumados al perfil).
    var xpToday: Int
    var shift: ShiftType
    var moment: Moment

    static func make(data: SaveData, calendar: WorkCalendar, now: Date) -> HoyFacts {
        let days = data.workDays
        let todayKey = calendar.key(for: now)
        let kind = calendar.kind(for: now)
        let dayInBlock = calendar.dayInBlock(for: now)
        let workDays = calendar.roster.workDays
        let turno = kind == .turno
        let paused = StreakEngine.isCounted(days[todayKey])
        let isLastDay = turno && dayInBlock >= workDays
        let boxes = ShiftStrip.boxes(data: data, calendar: calendar, now: now)
        let todayIndex = boxes.firstIndex(where: \.isToday)
        let previousAllPaused = todayIndex.map { boxes[..<$0].allSatisfy { $0.fill == .pausa } } ?? false
        return HoyFacts(
            now: now,
            todayKey: todayKey,
            kind: kind,
            dayInBlock: dayInBlock,
            workDays: workDays,
            isLastDay: isLastDay,
            pausedToday: paused,
            streak: StreakEngine.streak(days: days, calendar: calendar, at: now),
            streakIfPaused: StreakEngine.streakIfCountedToday(days: days, calendar: calendar, at: now),
            dobleteAvailable: StreakEngine.dobleteAvailable(days: days, calendar: calendar, at: now),
            dobleteToday: turno && paused && StreakEngine.previousWorkDayCounted(days: days, calendar: calendar, at: now),
            tiroLimpioPossible: turno && previousAllPaused,
            tiroLimpioToday: isLastDay && paused && StreakEngine.isTiroLimpio(days: days, calendar: calendar, turnoContaining: now),
            usedComodinYesterday: turno && StreakEngine.usedCascoYesterday(days: days, calendar: calendar, at: now),
            countedDaysThisTurno: StreakEngine.countedDays(days: days, calendar: calendar, turnoContaining: now),
            cascos: data.profile.cascos,
            xpToday: HoyProgress.xpEarned(sessions: data.sessions, workDayKey: todayKey),
            shift: data.profile.shiftType,
            moment: Moment.infer(date: now, shift: data.profile.shiftType, calendar: calendar.calendar)
        )
    }
}

extension StreakEngine {
    /// Racha que quedaría si la pausa de hoy cuenta: la misma regla de `streak`, con hoy marcado como contado.
    nonisolated static func streakIfCountedToday(days: [String: WorkDay], calendar: WorkCalendar, at date: Date) -> Int {
        var hypothetical = days
        var today = workDay(ofWorkDate: calendar.workDate(for: date), in: days, calendar: calendar)
        today.countedPauses = max(1, today.countedPauses)
        hypothetical[today.key] = today
        return streak(days: hypothetical, calendar: calendar, at: date)
    }
}

// MARK: - Fichas, acciones y meta del día

/// Ficha plana de "Gana hoy" / "Ganó hoy" (no es un control: sin vidrio).
nonisolated struct RewardChip: Sendable, Hashable, Identifiable {
    nonisolated enum Tone: Sendable, Hashable {
        /// Llama de la racha (único cobre).
        case flame
        /// Estrella del XP (oro, pequeña).
        case xp
        /// Hito del turno (Partió, Tiro limpio): acento.
        case milestone
        /// Insignia por ganar (gris) o ganada hoy (acento).
        case badgePending, badgeEarned
    }

    var symbol: String
    var text: String
    var tone: Tone
    var spoken: String

    var id: String { text }
}

/// Acción de la tarjeta principal: "Hacer la pausa" (principal) o un botón secundario de 44 pt.
nonisolated enum HoyAction: Sendable, Hashable {
    case primary(title: String, symbol: String)
    case secondary(title: String, symbol: String)

    var title: String {
        switch self {
        case .primary(let title, _), .secondary(let title, _): title
        }
    }
}

/// Tarjeta "Meta de hoy": anillo con la racha, hito en juego, lo que gana y la acción.
nonisolated struct HoyGoal: Sendable, Equatable {
    var eyebrowSymbol: String
    var eyebrow: String
    var streak: Int
    /// 0 pendiente, 1 cumplida.
    var ringProgress: Double
    /// `false` en bajada: el anillo se dibuja sin meta.
    var ringIsGoal: Bool
    var done: Bool
    var title: String
    var subtitle: String
    /// "Gana hoy" / "Ganó hoy" (nil: sin encabezado de fichas).
    var chipsTitle: String?
    var chips: [RewardChip]
    var showsRoute: Bool
    var action: HoyAction
    /// "Solo tengo 1 minuto · hasta +68 XP"
    var quickTitle: String
    /// "La pausa de las 14:02 no se pudo verificar. Repita cuando pueda."
    var unverifiedLine: String?
    /// VoiceOver del anillo y los textos.
    var spoken: String

    /// VoiceOver de las fichas: "Gana hoy: Doblete, XP por dos; hasta 218 XP; insignia Doblete."
    var chipsSpoken: String {
        guard let chipsTitle, !chips.isEmpty else { return "" }
        return "\(chipsTitle): " + chips.map(\.spoken).joined(separator: "; ") + "."
    }
}

/// Lo más que puede sumar la próxima pausa ("hasta").
nonisolated struct XPPreviews: Sendable, Equatable {
    /// Ruta completa del momento.
    var full: Int
    /// "Solo tengo 1 minuto".
    var quick: Int
}

// MARK: - Camino del turno

nonisolated struct TurnoPath: Sendable, Equatable {
    nonisolated enum NodeState: Sendable, Hashable { case pausa, comodin, todayPending, missed, future }
    nonisolated enum Finale: Sendable, Hashable { case possible, achieved }

    nonisolated struct Node: Sendable, Hashable, Identifiable {
        var day: Int
        var key: String
        var state: NodeState
        var isToday: Bool
        /// "jue" / "Hoy"
        var weekday: String
        /// "Partió" (D1), "Doblete" (D2), "Tiro limpio" (último): solo si se logró o todavía se puede.
        var milestone: String?
        /// Hoy pendiente con racha en juego: llama cobre adentro.
        var showsFlame: Bool
        /// Último día con Tiro limpio posible o logrado.
        var finale: Finale?
        var spoken: String

        var id: String { key }
    }

    /// "Camino del turno" / "Turno pasado"
    var title: String
    /// "1 de 7 con pausa"
    var trailing: String
    var nodes: [Node]
    /// Continuidad de la racha entre nodos vecinos (pausa o comodín en ambos): `nodes.count - 1` valores.
    var segments: [Bool]
    /// Comodín: listo, usado en el turno o usado ayer (nil en bajada).
    var comodinLine: String?
    /// "Bajada desde el jueves 29." / "Próximo turno: jueves 5 de noviembre."
    var dateLine: String
    var spoken: String
}

// MARK: - Su espalda hoy

nonisolated struct BackSummary: Sendable, Equatable {
    nonisolated struct Previous: Sendable, Equatable {
        /// "Ayer" / "El martes 20"
        var label: String
        var score: Int?
        var post: PostResponse?

        /// "Ayer: 3 de 6 · terminó Mejor" (dato, nunca premio).
        var line: String {
            var parts: [String] = []
            if let score { parts.append("\(score) de \(RDQ6.maxScore)") }
            if let post { parts.append("terminó \(post.title)") }
            return "\(label): " + parts.joined(separator: " · ")
        }
    }

    /// RDQ-6 de hoy (check-in de la pausa); nil = todavía no se responde.
    var todayScore: Int?
    var previous: Previous?
    /// "Dolor registrado hoy · Al bajar · 15:20"
    var painLine: String?
}

// MARK: - Momentos de hoy

nonisolated struct HoyMoments: Sendable, Equatable {
    var trailing: String
    var stops: [MomentStop]
    var line: String
}

// MARK: - Pantalla completa

nonisolated struct HoySnapshot: Sendable, Equatable {
    var title: String
    var subtitle: String
    var isRestDay: Bool
    var goal: HoyGoal
    var previews: XPPreviews
    /// Ruta completa de hoy (íconos y popover), en el orden fijo.
    var route: [ActivityAssignment]
    var routeMinutes: Int
    /// nil en bajada (no hay momentos del turno).
    var moments: HoyMoments?
    var path: TurnoPath
    var level: LevelSummary
    var badges: [BadgeStatus]
    var earnedBadges: Int
    var back: BackSummary
}

nonisolated enum HoyProgress {
    static let comodinReadyLine = "Comodín listo: cuida un día si no alcanza."
    static let comodinUsedLine = "Comodín usado en este turno."
    static let doneTitle = "Ganó hoy"
    static let pendingTitle = "Gana hoy"

    /// Arma todo lo que muestra Hoy.
    static func snapshot(data: SaveData, calendar: WorkCalendar, now: Date) -> HoySnapshot {
        let facts = HoyFacts.make(data: data, calendar: calendar, now: now)
        let demo = data.demo.shortTargets
        let route = Recipes.base(facts.moment.recipe, demo: demo)
        let quick = Recipes.base(.relevo60, demo: demo)
        let previews = XPPreviews(
            full: GameStore.previewXP(kinds: route.activities.map(\.kind), firstCountedToday: !facts.pausedToday,
                                      doblete: facts.dobleteAvailable),
            quick: GameStore.previewXP(kinds: quick.activities.map(\.kind), firstCountedToday: !facts.pausedToday,
                                       doblete: facts.dobleteAvailable))
        let badges = BadgeProgress.statuses(data: data, calendar: calendar, facts: facts)
        let earnedToday = badges.filter(\.earnedToday).map(\.badge)
        let unlockable = unlockableBadges(earned: data.profile.badges, facts: facts)
        let isRest = facts.kind == .descanso

        return HoySnapshot(
            title: headerTitle(facts: facts),
            subtitle: headerSubtitle(name: data.profile.name, isRestDay: isRest, now: now, calendar: calendar.calendar),
            isRestDay: isRest,
            goal: goal(facts: facts, previews: previews, unlockable: unlockable, earnedToday: earnedToday,
                       sessions: data.sessions, calendar: calendar),
            previews: previews,
            route: route.activities,
            routeMinutes: route.minutes,
            moments: isRest ? nil : moments(data: data, facts: facts, calendar: calendar),
            path: path(data: data, calendar: calendar, facts: facts),
            level: LevelSummary.make(xp: data.profile.xp, xpToday: facts.xpToday, nextPausePreview: previews.full,
                                     optional: isRest),
            badges: badges,
            earnedBadges: badges.filter(\.earned).count,
            back: back(data: data, calendar: calendar, now: now)
        )
    }

    // MARK: Datos derivados

    /// XP ganados en un día laboral (suma de `xpEarned` de sus sesiones; las simuladas valen 0).
    static func xpEarned(sessions: [PauseSession], workDayKey: String) -> Int {
        sessions.filter { $0.workDayKey == workDayKey && !$0.simulated }.reduce(0) { $0 + $1.xpEarned }
    }

    /// Momentos con una pausa contada hoy.
    static func doneMoments(sessions: [PauseSession], workDayKey: String) -> Set<Moment> {
        Set(sessions.filter { $0.workDayKey == workDayKey && GameStore.counts($0) }.map(\.moment))
    }

    /// Insignias que la próxima pausa contada de hoy entrega seguro (si no están ganadas).
    static func unlockableBadges(earned: Set<Badge>, facts: HoyFacts) -> [Badge] {
        guard !facts.pausedToday else { return [] }
        var badges: [Badge] = []
        if facts.isLastDay && facts.tiroLimpioPossible { badges.append(.tiroLimpio) }
        if facts.dobleteAvailable { badges.append(.doblete) }
        badges.append(.primeraPausa)
        return badges.filter { !earned.contains($0) }
    }

    static func days(_ n: Int) -> String { n == 1 ? "1 día" : "\(n) días" }

    // MARK: Encabezado

    static func headerTitle(facts: HoyFacts) -> String {
        facts.kind == .turno ? "Día \(facts.dayInBlock) de \(facts.workDays)" : "Bajada"
    }

    /// "Viernes 23 · Buen turno, Marco" (sin nombre: "Viernes 23 · Buen turno").
    static func headerSubtitle(name: String, isRestDay: Bool, now: Date, calendar: Calendar) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let greeting = (isRestDay ? "Buen descanso" : "Buen turno") + (trimmed.isEmpty ? "" : ", \(trimmed)")
        return SpanishDate.capitalizedFirst(SpanishDate.weekdayDay(now, calendar: calendar)) + " · " + greeting
    }

    // MARK: Meta de hoy

    static func goal(facts: HoyFacts, previews: XPPreviews, unlockable: [Badge], earnedToday: [Badge],
                     sessions: [PauseSession], calendar: WorkCalendar) -> HoyGoal {
        let quickTitle = "Solo tengo 1 minuto · hasta +\(previews.quick) XP"
        let unverified = facts.pausedToday ? nil : unverifiedLine(sessions: sessions, todayKey: facts.todayKey,
                                                                  calendar: calendar.calendar)
        let badgeChips = (facts.pausedToday ? earnedToday : unlockable).map { badge in
            RewardChip(symbol: "hexagon.fill", text: "Insignia \(BadgeProgress.shortTitle(badge))",
                       tone: facts.pausedToday ? .badgeEarned : .badgePending,
                       spoken: "insignia \(BadgeProgress.shortTitle(badge))")
        }

        if facts.kind == .descanso {
            return restGoal(facts: facts, previews: previews, badgeChips: badgeChips, quickTitle: quickTitle,
                            unverified: unverified, calendar: calendar)
        }

        let window = Moment.windowEnd(after: facts.now, shift: facts.shift, calendar: calendar.calendar)
        let eyebrow = "\(facts.moment.title) · hasta las \(SpanishDate.clock(window, calendar: calendar.calendar))"

        if facts.pausedToday {
            var chips: [RewardChip] = []
            let title: String
            var subtitle: String
            if facts.tiroLimpioToday {
                title = "Tiro limpio cumplido"
                subtitle = "\(facts.workDays) de \(facts.workDays) días con pausa."
                chips.append(RewardChip(symbol: "checkmark.seal.fill", text: "Tiro limpio \(facts.workDays)/\(facts.workDays)",
                                        tone: .milestone, spoken: "Tiro limpio"))
            } else if facts.dobleteToday {
                title = "Doblete cumplido"
                subtitle = "Racha de \(days(facts.streak))."
            } else if facts.dayInBlock <= 1 {
                title = "Partió el turno"
                subtitle = "Racha de \(days(facts.streak))."
                chips.append(RewardChip(symbol: "flag.fill", text: "Partió", tone: .milestone, spoken: "Partió el turno"))
            } else {
                title = "Día \(facts.dayInBlock) cumplido"
                subtitle = "Racha de \(days(facts.streak))."
            }
            if !facts.tiroLimpioToday {
                subtitle += facts.isLastDay ? " Sigue el próximo turno."
                    : (facts.dayInBlock <= 1 ? " Mañana va por el Doblete." : " Mañana sigue.")
            }
            if facts.dobleteToday {
                chips.insert(RewardChip(symbol: "flame.fill", text: "Doblete", tone: .flame, spoken: "Doblete"), at: 0)
            }
            if facts.xpToday > 0 {
                chips.append(RewardChip(symbol: "star.fill", text: "+\(facts.xpToday) XP", tone: .xp,
                                        spoken: "\(facts.xpToday) XP"))
            }
            chips += badgeChips
            return HoyGoal(eyebrowSymbol: facts.moment.symbol, eyebrow: eyebrow, streak: facts.streak,
                           ringProgress: 1, ringIsGoal: true, done: true, title: title, subtitle: subtitle,
                           chipsTitle: chips.isEmpty ? nil : doneTitle, chips: chips, showsRoute: false,
                           action: .secondary(title: "Hacer otra pausa · hasta +\(previews.full) XP", symbol: "arrow.clockwise"),
                           quickTitle: quickTitle, unverifiedLine: nil,
                           spoken: "Racha de \(days(facts.streak)). Meta de hoy: cumplida. \(title).")
        }

        // Antes de la pausa: un solo hito en juego (Tiro limpio > Doblete > Partió > seguir la racha).
        var chips: [RewardChip] = []
        let title: String
        let subtitle: String
        let streakLine = facts.streak > 0
            ? "Racha de \(days(facts.streak)). Con la pausa, sube a \(facts.streakIfPaused)."
            : "Con la pausa, su racha parte en \(facts.streakIfPaused)."
        if facts.isLastDay && facts.tiroLimpioPossible {
            title = "Vamos por el Tiro limpio"
            let before = facts.workDays - 1
            subtitle = "\(before) de \(before) días con pausa. Falta hoy."
            chips.append(RewardChip(symbol: "checkmark.seal.fill", text: "Tiro limpio \(facts.workDays)/\(facts.workDays)",
                                    tone: .milestone, spoken: "Tiro limpio"))
        } else if facts.dobleteAvailable && facts.dayInBlock == 2 {
            title = "Vamos por el Doblete"
            subtitle = streakLine
        } else if facts.dayInBlock <= 1 {
            title = "Parta el turno"
            subtitle = facts.streak > 0 ? streakLine : "Haga su primera pausa del turno."
            chips.append(RewardChip(symbol: "flag.fill", text: "Partió", tone: .milestone, spoken: "Partió el turno"))
        } else if facts.streak > 0 {
            title = "Siga la racha"
            subtitle = streakLine
        } else {
            title = "Parta la racha"
            subtitle = streakLine
        }
        if facts.dobleteAvailable {
            chips.insert(RewardChip(symbol: "flame.fill", text: "Doblete x2", tone: .flame, spoken: "Doblete, XP por dos"),
                         at: chips.isEmpty ? 0 : 1)
        }
        chips.append(RewardChip(symbol: "star.fill", text: "Hasta +\(previews.full) XP", tone: .xp,
                                spoken: "hasta \(previews.full) XP"))
        chips += badgeChips
        return HoyGoal(eyebrowSymbol: facts.moment.symbol, eyebrow: eyebrow, streak: facts.streak,
                       ringProgress: 0, ringIsGoal: true, done: false, title: title, subtitle: subtitle,
                       chipsTitle: pendingTitle, chips: chips, showsRoute: true,
                       action: .primary(title: "Hacer la pausa", symbol: "play.fill"),
                       quickTitle: quickTitle, unverifiedLine: unverified,
                       spoken: "Racha de \(days(facts.streak)). Meta de hoy: pausa pendiente. \(title).")
    }

    private static func restGoal(facts: HoyFacts, previews: XPPreviews, badgeChips: [RewardChip], quickTitle: String,
                                 unverified: String?, calendar: WorkCalendar) -> HoyGoal {
        let back = nextTurnoStart(calendar: calendar, now: facts.now)
        let restDays = calendar.roster.restDays
        let eyebrow = "Día \(facts.dayInBlock) de \(restDays) de bajada"
        let returnLine = "Vuelve al turno el \(SpanishDate.weekdayDayMonth(back, calendar: calendar.calendar))."
        if facts.pausedToday {
            var chips: [RewardChip] = []
            if facts.xpToday > 0 {
                chips.append(RewardChip(symbol: "star.fill", text: "+\(facts.xpToday) XP", tone: .xp,
                                        spoken: "\(facts.xpToday) XP"))
            }
            chips += badgeChips
            return HoyGoal(eyebrowSymbol: "house.fill", eyebrow: eyebrow, streak: facts.streak, ringProgress: 1,
                           ringIsGoal: false, done: true, title: "Racha a salvo",
                           subtitle: "Pausa opcional hecha. \(returnLine)",
                           chipsTitle: chips.isEmpty ? nil : doneTitle, chips: chips, showsRoute: false,
                           action: .secondary(title: "Hacer otra pausa · hasta +\(previews.full) XP", symbol: "arrow.clockwise"),
                           quickTitle: quickTitle, unverifiedLine: nil,
                           spoken: "Bajada. Racha de \(days(facts.streak)), a salvo. Pausa opcional hecha.")
        }
        let chips = [RewardChip(symbol: "star.fill", text: "Pausa opcional: hasta +\(previews.full) XP", tone: .xp,
                                spoken: "pausa opcional: hasta \(previews.full) XP")] + badgeChips
        return HoyGoal(eyebrowSymbol: "house.fill", eyebrow: eyebrow, streak: facts.streak, ringProgress: 0,
                       ringIsGoal: false, done: false, title: "Racha a salvo", subtitle: returnLine,
                       chipsTitle: nil, chips: chips, showsRoute: false,
                       action: .secondary(title: "Hacer una pausa opcional", symbol: "play.fill"),
                       quickTitle: quickTitle, unverifiedLine: unverified,
                       spoken: "Bajada. Racha de \(days(facts.streak)), a salvo. \(returnLine)")
    }

    /// Pausa de hoy que terminó sin contar (la última). Nunca en rojo ni como castigo.
    static func unverifiedLine(sessions: [PauseSession], todayKey: String, calendar: Calendar) -> String? {
        guard let last = sessions
            .filter({ $0.workDayKey == todayKey && !$0.simulated && !$0.counted })
            .max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        let time = SpanishDate.clock(last.startedAt, calendar: calendar)
        if last.xpEarned > 0 {
            return "La pausa de las \(time) se verificó solo en parte. Repita cuando pueda."
        }
        return "La pausa de las \(time) no se pudo verificar. Repita cuando pueda."
    }

    /// Primer día del próximo turno (en bajada) o el siguiente al bloque actual.
    static func nextTurnoStart(calendar: WorkCalendar, now: Date) -> Date {
        let today = calendar.workDate(for: now)
        var cursor = today
        for _ in 0...calendar.cycleLength {
            guard let next = calendar.calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            let instant = StreakEngine.instant(ofWorkDate: cursor, calendar: calendar)
            if calendar.kind(for: instant) == .turno && calendar.dayInBlock(for: instant) == 1 { return cursor }
        }
        return cursor
    }

    // MARK: Momentos

    static func moments(data: SaveData, facts: HoyFacts, calendar: WorkCalendar) -> HoyMoments {
        let done = doneMoments(sessions: data.sessions, workDayKey: facts.todayKey)
        return HoyMoments(trailing: facts.shift.title,
                          stops: Moment.stops(now: facts.now, shift: facts.shift, doneMoments: done, calendar: calendar.calendar),
                          line: Moment.stopsLine(current: facts.moment, pausedToday: facts.pausedToday, doneMoments: done))
    }

    // MARK: Camino del turno

    static func path(data: SaveData, calendar: WorkCalendar, facts: HoyFacts) -> TurnoPath {
        let boxes = ShiftStrip.boxes(data: data, calendar: calendar, now: facts.now)
        let dates = calendar.workDatesOfTurno(containing: facts.now)
        let turno = facts.kind == .turno
        func failed(_ box: ShiftStrip.DayBox) -> Bool {
            box.fill == .casco || (box.fill == .vacio && !box.isToday)
        }
        let anyFailed = boxes.contains(where: failed)
        let allPaused = !boxes.isEmpty && boxes.allSatisfy { $0.fill == .pausa }
        let lastIndex = boxes.count - 1

        let nodes: [TurnoPath.Node] = boxes.enumerated().map { index, box in
            let state: TurnoPath.NodeState
            switch box.fill {
            case .pausa: state = .pausa
            case .casco: state = .comodin
            case .vacio: state = box.isToday ? .todayPending : .missed
            case .futuro: state = .future
            }
            var milestone: String?
            if index == 0, box.fill == .pausa || state == .todayPending { milestone = "Partió" }
            if index == 1, boxes.count > 2, !failed(boxes[0]), !failed(box) { milestone = "Doblete" }
            var finale: TurnoPath.Finale?
            if index == lastIndex, lastIndex > 0, !anyFailed {
                milestone = "Tiro limpio"
                finale = allPaused ? .achieved : .possible
            }
            let weekday = box.isToday ? "Hoy"
                : (index < dates.count ? SpanishDate.weekdayShort(dates[index], calendar: calendar.calendar) : "D\(box.day)")
            let spoken = ShiftStrip.spoken(box) + (milestone.map { ". Hito: \($0)" } ?? "")
            return TurnoPath.Node(day: box.day, key: box.workDayKey, state: state, isToday: box.isToday,
                                  weekday: weekday, milestone: milestone,
                                  showsFlame: state == .todayPending && facts.streak > 0,
                                  finale: finale, spoken: spoken)
        }
        let sustains: (TurnoPath.NodeState) -> Bool = { $0 == .pausa || $0 == .comodin }
        let segments = nodes.indices.dropLast().map { sustains(nodes[$0].state) && sustains(nodes[$0 + 1].state) }

        let counted = boxes.filter { $0.fill == .pausa }.count
        let comodinLine: String?
        if !turno {
            comodinLine = nil
        } else if facts.usedComodinYesterday {
            comodinLine = CelebrationCopy.comodinUsedYesterdayLine
        } else if facts.cascos > 0 {
            comodinLine = comodinReadyLine
        } else {
            comodinLine = comodinUsedLine
        }

        let dateLine: String
        if turno, let last = dates.last, let bajada = calendar.calendar.date(byAdding: .day, value: 1, to: last) {
            dateLine = "Bajada desde el \(SpanishDate.weekdayDay(bajada, calendar: calendar.calendar))."
        } else {
            dateLine = "Próximo turno: \(SpanishDate.weekdayDayMonth(nextTurnoStart(calendar: calendar, now: facts.now), calendar: calendar.calendar))."
        }

        let headline = ShiftStrip.headline(kind: facts.kind, dayInBlock: facts.dayInBlock, workDays: facts.workDays,
                                           pausedToday: facts.pausedToday, allPaused: allPaused,
                                           dobleteAvailable: facts.dobleteAvailable,
                                           tiroLimpioAvailable: ShiftStrip.tiroLimpioAvailable(boxes: boxes))
        let trailing = "\(counted) de \(boxes.count) con pausa"
        return TurnoPath(title: turno ? "Camino del turno" : "Turno pasado", trailing: trailing, nodes: nodes,
                         segments: segments, comodinLine: comodinLine, dateLine: dateLine,
                         spoken: "\(headline). \(trailing).")
    }

    // MARK: Su espalda hoy

    static func back(data: SaveData, calendar: WorkCalendar, now: Date) -> BackSummary {
        let todayKey = calendar.key(for: now)
        let yesterdayKey = calendar.key(for: calendar.previousWorkDay(of: now))
        let todayScore = data.checkIns
            .filter { $0.source == .pausa && $0.workDayKey == todayKey }
            .max { $0.date < $1.date }?.score

        let previousSession = data.sessions
            .filter { $0.workDayKey < todayKey && !$0.simulated && ($0.checkInScore != nil || $0.postResponse != nil) }
            .max { $0.startedAt < $1.startedAt }
        let previous = previousSession.map { session -> BackSummary.Previous in
            let label: String
            if session.workDayKey == yesterdayKey {
                label = "Ayer"
            } else if let date = calendar.date(forKey: session.workDayKey) {
                label = "El \(SpanishDate.weekdayDay(date, calendar: calendar.calendar))"
            } else {
                label = "Última pausa"
            }
            return BackSummary.Previous(label: label, score: session.checkInScore, post: session.postResponse)
        }

        var painLine: String?
        if let pain = data.checkIns
            .filter({ $0.source == .meDueleAhora && $0.workDayKey == todayKey })
            .max(by: { $0.date < $1.date }) {
            var parts = ["Dolor registrado hoy"]
            if let context = pain.context { parts.append(context.title) }
            parts.append(SpanishDate.clock(pain.date, calendar: calendar.calendar))
            painLine = parts.joined(separator: " · ")
        }
        return BackSummary(todayScore: todayScore, previous: previous, painLine: painLine)
    }

    /// Nombre para "Le ayuda más: …" (igual al de la pausa; la caminata se nombra como sustantivo).
    static func helpName(_ kind: ActivityKind) -> String {
        kind == .pasos ? "Caminata" : kind.name
    }
}
