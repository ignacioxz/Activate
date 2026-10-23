import Testing
import Foundation
@testable import Activate

/// Lógica pura del nuevo Hoy: ventanas de los momentos, vista previa del XP ("hasta"), racha si hace la
/// pausa, nivel compartido con Perfil, insignias con avance, camino del turno, su espalda hoy y los
/// estados del día (día 1, días 3-6, día 7, comodín, bajada, pausa hecha, pausa no verificada).
@MainActor
struct HoyProgressTests {
    private static let santiago: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        Self.santiago.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Demo de Marco: viernes 23-10-2026 a las 15:14, día 2 de 7, ayer con pausa, hoy sin pausa.
    private var demoNow: Date { date(23, 15, 14) }

    private func demo(now: Date? = nil) -> (SaveData, WorkCalendar) {
        let data = DemoSeed.data(now: now ?? demoNow, calendar: Self.santiago)
        return (data, WorkCalendar(profile: data.profile, calendar: Self.santiago))
    }

    private func snapshot(_ data: SaveData, now: Date? = nil) -> HoySnapshot {
        HoyProgress.snapshot(data: data, calendar: WorkCalendar(profile: data.profile, calendar: Self.santiago),
                             now: now ?? demoNow)
    }

    /// Perfil 7×7 que sube el lunes 12-10-2026 (12-18 turno, 19-25 bajada, 26 día 1).
    private func blankData(shift: ShiftType = .day) -> SaveData {
        var profile = PlayerProfile(rosterStart: date(12, 0))
        profile.shiftType = shift
        profile.name = "Marco"
        profile.consentGiven = true
        profile.onboardingDone = true
        return SaveData(profile: profile)
    }

    /// Marca días del turno que sube el 12-10 como contados (o con comodín).
    private func mark(_ data: inout SaveData, counted: [Int], comodin: [Int] = []) {
        let wc = WorkCalendar(profile: data.profile, calendar: Self.santiago)
        for day in counted + comodin {
            let key = String(format: "2026-10-%02d", day)
            var record = StreakEngine.workDay(forKey: key, in: data.workDays, calendar: wc)!
            if counted.contains(day) { record.countedPauses = 1 } else { record.cascoUsed = true }
            data.workDays[key] = record
        }
    }

    private func fullSession(at start: Date, data: SaveData, counted: Bool = true, level: VerificationLevel = .full,
                             recipe: RecipeKind = .campamento5) -> PauseSession {
        let wc = WorkCalendar(profile: data.profile, calendar: Self.santiago)
        var s = PauseSession(workDayKey: wc.key(for: start), turnoKey: wc.turnoKey(for: start), recipe: recipe,
                             moment: Moment.infer(date: start, shift: data.profile.shiftType, calendar: Self.santiago),
                             startedAt: start, endedAt: start.addingTimeInterval(420), checkInScore: 2)
        s.activities = Recipes.base(recipe, demo: false).activities.map { item in
            ActivityResult(kind: item.kind, target: item.target, achieved: item.target, durationSeconds: 30, completed: true,
                           level: level, metrics: .none, anomalies: [])
        }
        s.counted = counted
        s.level = level
        s.postResponse = .igual
        return s
    }

    // MARK: - Ventanas de los momentos

    /// Reglas originales de `Moment.infer` (antes de las ventanas), para comprobar que no cambiaron.
    private func legacyInfer(minute: Int, shift: ShiftType) -> Moment {
        let t = Double(minute) / 60
        switch shift {
        case .day:
            if t >= 4 && t < 9.5 { return .entrada }
            if t >= 9.5 && t < 15 { return .colacion }
            if t >= 15 && t < 20.5 { return .salida }
            return .campamento
        case .night:
            if t >= 16 && t < 21.5 { return .entrada }
            if t >= 21.5 || t < 3 { return .colacion }
            if t >= 3 && t < 8.5 { return .salida }
            return .campamento
        }
    }

    @Test func ventanasCubrenElDiaSinSolaparseYCalzanConInfer() {
        for shift in ShiftType.allCases {
            let windows = Moment.windows(for: shift)
            #expect(windows.map(\.moment) == [.entrada, .colacion, .salida, .campamento])
            for minute in 0..<1440 {
                let matching = windows.filter { $0.contains(minuteOfDay: minute) }
                #expect(matching.count == 1, "minuto \(minute) \(shift)")
                let instant = Self.santiago.date(byAdding: .minute, value: minute, to: date(14, 0))!
                let inferred = Moment.infer(date: instant, shift: shift, calendar: Self.santiago)
                #expect(inferred == matching.first?.moment)
                #expect(inferred == legacyInfer(minute: minute, shift: shift), "minuto \(minute) \(shift)")
            }
        }
        #expect(Moment.windows(for: .day).map(\.startLabel) == ["04:00", "09:30", "15:00", "20:30"])
        #expect(Moment.windows(for: .night).map(\.startLabel) == ["16:00", "21:30", "03:00", "08:30"])
        // El aviso diario cae al inicio del campamento: misma ventana.
        #expect(Moment.campamento.window(shift: .day).startMinute
                == DailyNotice.dayShiftNoticeHour * 60 + DailyNotice.dayShiftNoticeMinute)
        #expect(Moment.campamento.window(shift: .night).startMinute
                == DailyNotice.nightShiftNoticeHour * 60 + DailyNotice.nightShiftNoticeMinute)
    }

    @Test func finDeLaVentanaVigente() {
        #expect(Moment.windowEnd(after: date(23, 15, 14), shift: .day, calendar: Self.santiago) == date(23, 20, 30))
        #expect(Moment.windowEnd(after: date(23, 22, 0), shift: .day, calendar: Self.santiago) == date(24, 4, 0))
        #expect(Moment.windowEnd(after: date(23, 1, 0), shift: .day, calendar: Self.santiago) == date(23, 4, 0))
        #expect(Moment.windowEnd(after: date(23, 23, 0), shift: .night, calendar: Self.santiago) == date(24, 3, 0))
        #expect(Moment.windowEnd(after: date(23, 13, 0), shift: .night, calendar: Self.santiago) == date(23, 16, 0))
    }

    @Test func paradasDeLosMomentosDeHoy() {
        let day = Moment.stops(now: date(23, 15, 14), shift: .day, doneMoments: [.colacion], calendar: Self.santiago)
        #expect(day.map(\.phase) == [.past, .past, .now, .next])
        #expect(day.map(\.start) == ["04:00", "09:30", "15:00", "20:30"])
        #expect(day.map(\.done) == [false, true, false, false])
        // Turno de día de madrugada: el campamento (desde las 20:30) sigue siendo "ahora".
        let lateNight = Moment.stops(now: date(24, 2, 0), shift: .day, doneMoments: [], calendar: Self.santiago)
        #expect(lateNight.map(\.phase) == [.past, .past, .past, .now])
        // Turno de noche a las 13:00: el día laboral partió a las 12:00; la entrada de las 16:00 todavía viene.
        let night = Moment.stops(now: date(23, 13, 0), shift: .night, doneMoments: [], calendar: Self.santiago)
        #expect(night.map(\.phase) == [.next, .next, .next, .now])
        let nightMorning = Moment.stops(now: date(23, 10, 0), shift: .night, doneMoments: [], calendar: Self.santiago)
        #expect(nightMorning.map(\.phase) == [.past, .past, .past, .now])
        let nightColacion = Moment.stops(now: date(23, 23, 0), shift: .night, doneMoments: [], calendar: Self.santiago)
        #expect(nightColacion.map(\.phase) == [.past, .now, .next, .next])
    }

    @Test func lineaDeLosMomentos() {
        #expect(Moment.stopsLine(current: .salida, pausedToday: false, doneMoments: [])
                == "La pausa calza ahora, en el relevo de salida.")
        #expect(Moment.stopsLine(current: .colacion, pausedToday: false, doneMoments: [])
                == "La pausa calza ahora, en la colación.")
        #expect(Moment.stopsLine(current: .salida, pausedToday: true, doneMoments: [.salida])
                == "Pausa hecha en el relevo de salida.")
        #expect(Moment.stopsLine(current: .campamento, pausedToday: true, doneMoments: [.colacion])
                == "Pausa de hoy hecha. Si quiere otra, calza ahora, en el campamento.")
    }

    // MARK: - Vista previa del XP

    @Test func vistaPreviaDelXPConLasReglasDePuntaje() {
        let full = Recipes.base(.campamento5, demo: false).activities.map(\.kind)
        let quick = Recipes.base(.relevo60, demo: false).activities.map(\.kind)
        #expect(GameStore.previewXP(kinds: full, firstCountedToday: true, doblete: false) == 109)
        #expect(GameStore.previewXP(kinds: full, firstCountedToday: true, doblete: true) == 218)
        #expect(GameStore.previewXP(kinds: quick, firstCountedToday: true, doblete: false) == 34)
        #expect(GameStore.previewXP(kinds: quick, firstCountedToday: true, doblete: true) == 68)
        // Segunda pausa del día: sin bono ni Doblete.
        #expect(GameStore.previewXP(kinds: full, firstCountedToday: false, doblete: true) == 99)
        #expect(GameStore.previewXP(kinds: quick, firstCountedToday: false, doblete: false) == 24)
        // La respiración (débil por naturaleza) llega a `reduced`: paga la mitad, como en `xp(for:)`.
        #expect(GameStore.maxXP(for: .respiracion) == 4)
        #expect(GameStore.maxXP(for: .pasos) == ActivityKind.pasos.baseXP)
    }

    @Test func laVistaPreviaCoincideConLoQueRegistraGameStore() {
        // Todo con `Calendar.current`, igual que `GameStore` (usa el calendario del store).
        let cal = Calendar.current
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let store = AppStore(inMemory: true)
        var profile = PlayerProfile(rosterStart: cal.startOfDay(for: at(12, 0)))
        profile.consentGiven = true
        store.replace(with: SaveData(profile: profile))
        let game = GameStore(store: store)
        func session(_ date: Date, reduced: Bool = false) -> PauseSession {
            let wc = store.calendar
            var s = PauseSession(workDayKey: wc.key(for: date), turnoKey: wc.turnoKey(for: date), recipe: .campamento5,
                                 moment: .colacion, startedAt: date, checkInScore: 1)
            s.activities = Recipes.base(.campamento5, demo: false).activities.enumerated().map { index, item in
                ActivityResult(kind: item.kind, target: item.target, achieved: item.target, durationSeconds: 30,
                               completed: true, level: reduced && index == 0 ? .reduced : .full, metrics: .none, anomalies: [])
            }
            s.counted = true
            s.level = .full
            s.postResponse = .igual
            return s
        }
        func preview(_ date: Date) -> Int {
            HoyProgress.snapshot(data: store.data, calendar: store.calendar, now: date).previews.full
        }
        // Día 1 contado; el día 2 la pausa completa es Doblete.
        game.record(session(at(12, 13)))
        let doblete = preview(at(13, 13))
        #expect(doblete == 218)
        let reward = game.record(session(at(13, 13, 5)))
        #expect(reward.isDoblete)
        #expect(reward.totalXP == doblete)
        // Segunda pausa del mismo día: la vista previa (99) es exactamente lo que paga.
        let second = preview(at(13, 14))
        #expect(second == 99)
        #expect(game.record(session(at(13, 14, 5))).totalXP == second)
        // Una actividad `reduced` paga menos: la vista previa es un techo ("hasta").
        let ceiling = preview(at(14, 12))
        #expect(game.record(session(at(14, 13), reduced: true)).totalXP < ceiling)
    }

    // MARK: - Racha si hace la pausa

    @Test func rachaSiHaceLaPausaHoy() {
        var data = blankData()
        mark(&data, counted: [12])
        let wc = WorkCalendar(profile: data.profile, calendar: Self.santiago)
        #expect(StreakEngine.streak(days: data.workDays, calendar: wc, at: date(13, 10)) == 1)
        #expect(StreakEngine.streakIfCountedToday(days: data.workDays, calendar: wc, at: date(13, 10)) == 2)
        // Ya contado hoy: no suma dos veces.
        mark(&data, counted: [12, 13])
        #expect(StreakEngine.streakIfCountedToday(days: data.workDays, calendar: wc, at: date(13, 10)) == 2)
        // En bajada una pausa no suma racha (solo cuentan los días de turno).
        #expect(StreakEngine.streakIfCountedToday(days: data.workDays, calendar: wc, at: date(20, 10))
                == StreakEngine.streak(days: data.workDays, calendar: wc, at: date(20, 10)))
        // Sin racha: parte en 1.
        let empty = blankData()
        #expect(StreakEngine.streakIfCountedToday(days: empty.workDays, calendar: wc, at: date(14, 10)) == 1)
    }

    // MARK: - Nivel (compartido con Perfil)

    @Test func nivelConTramoDeLaProximaPausa() {
        #expect(ProfileRank.xpIntoLevel(xp: 375) == 75)
        #expect(ProfileRank.xpToNextLevel(xp: 375) == 75)
        #expect(ProfileRank.xpToNextLevel(xp: 300) == 150)

        let before = LevelSummary.make(xp: 375, xpToday: 0, nextPausePreview: 218)
        #expect(before.level == 3)
        #expect(before.progress == 0.5)
        #expect(before.ghostProgress == 1)
        #expect(before.nextPauseCrossesLevel)
        #expect(!before.leveledUpToday)
        #expect(before.note == "Faltan 75 XP para el nivel 4. La pausa de hoy da hasta +218 XP.")

        let short = LevelSummary.make(xp: 310, xpToday: 0, nextPausePreview: 109)
        #expect(!short.nextPauseCrossesLevel)
        #expect(abs(short.ghostProgress - Double(10 + 109) / 150) < 0.0001)

        let after = LevelSummary.make(xp: 593, xpToday: 218, nextPausePreview: 99)
        #expect(after.level == 4)
        #expect(after.leveledUpToday)
        #expect(after.note == "Subió al nivel 4 hoy. Faltan 7 XP para el nivel 5.")

        let sameLevel = LevelSummary.make(xp: 470, xpToday: 20, nextPausePreview: 99)
        #expect(sameLevel.note == "Hoy sumó +20 XP. Faltan 130 XP para el nivel 5.")

        let rest = LevelSummary.make(xp: 0, xpToday: 0, nextPausePreview: 109, optional: true)
        #expect(rest.note == "Faltan 150 XP para el nivel 2. La pausa opcional da hasta +109 XP.")
        #expect(rest.spoken.hasPrefix("Nivel 1, 0 XP."))
    }

    // MARK: - XP de hoy

    @Test func xpGanadoHoySoloCuentaHoyYNoSimuladas() {
        var data = blankData()
        var a = fullSession(at: date(13, 10), data: data)
        a.xpEarned = 109
        var b = fullSession(at: date(13, 15), data: data)
        b.xpEarned = 24
        var simulated = fullSession(at: date(13, 16), data: data)
        simulated.simulated = true
        simulated.xpEarned = 50
        var yesterday = fullSession(at: date(12, 10), data: data)
        yesterday.xpEarned = 99
        data.sessions = [a, b, simulated, yesterday]
        #expect(HoyProgress.xpEarned(sessions: data.sessions, workDayKey: "2026-10-13") == 133)
        // Día laboral de noche: la 01:00 del 14 es del día 13 (`workDayKey`).
        #expect(HoyProgress.xpEarned(sessions: data.sessions, workDayKey: "2026-10-12") == 99)
    }

    // MARK: - Demo de Marco: antes y después de la pausa

    @Test func demoAntesDeLaPausa() {
        let (data, _) = demo()
        let snap = snapshot(data)
        #expect(snap.title == "Día 2 de 7")
        #expect(snap.subtitle == "Viernes 23 · Buen turno, Marco")
        #expect(snap.goal.eyebrow == "Relevo de salida · hasta las 20:30")
        #expect(snap.goal.title == "Vamos por el Doblete")
        #expect(snap.goal.subtitle == "Racha de 1 día. Con la pausa, sube a 2.")
        #expect(snap.goal.chipsTitle == "Gana hoy")
        #expect(snap.goal.chips.map(\.text) == ["Doblete x2", "Hasta +218 XP", "Insignia Doblete"])
        #expect(snap.goal.action == .primary(title: "Hacer la pausa", symbol: "play.fill"))
        #expect(snap.goal.quickTitle == "Solo tengo 1 minuto · hasta +68 XP")
        #expect(snap.goal.showsRoute)
        #expect(snap.route.map(\.kind) == ActivityKind.sessionOrder)
        #expect(snap.goal.spoken == "Racha de 1 día. Meta de hoy: pausa pendiente. Vamos por el Doblete.")
        #expect(snap.goal.chipsSpoken == "Gana hoy: Doblete, XP por dos; hasta 218 XP; insignia Doblete.")
        #expect(snap.moments?.line == "La pausa calza ahora, en el relevo de salida.")
        #expect(snap.moments?.trailing == "Turno de día")
        // Nivel con datos reales de la demo (no fijos en la vista).
        #expect(snap.level.xp == data.profile.xp)
        #expect(snap.level.level == ProfileRank.level(xp: data.profile.xp))
    }

    @Test func demoCaminoDelTurno() {
        let (data, _) = demo()
        let path = snapshot(data).path
        #expect(path.title == "Camino del turno")
        #expect(path.trailing == "1 de 7 con pausa")
        #expect(path.nodes.map(\.state) == [.pausa, .todayPending, .future, .future, .future, .future, .future])
        #expect(path.nodes.map(\.weekday) == ["jue", "Hoy", "sáb", "dom", "lun", "mar", "mié"])
        #expect(path.nodes.map(\.milestone) == ["Partió", "Doblete", nil, nil, nil, nil, "Tiro limpio"])
        #expect(path.nodes.last?.finale == .possible)
        #expect(path.nodes[1].showsFlame)
        #expect(path.segments == [false, false, false, false, false, false])
        #expect(path.comodinLine == "Comodín listo: cuida un día si no alcanza.")
        #expect(path.dateLine == "Bajada desde el jueves 29.")
        #expect(path.spoken.contains("Vamos por el Doblete"))
    }

    @Test func demoInsigniasDeLaMasCercanaALaMasLejana() {
        let (data, _) = demo()
        let snap = snapshot(data)
        let pending = snap.badges.filter { !$0.earned }
        #expect(pending.first?.badge == .doblete)
        #expect(pending.first?.status == "Con la pausa de hoy")
        #expect(pending.first?.highlight == true)
        // Avance ordenado de mayor a menor y las ganadas al final.
        let closeness = pending.dropFirst().map(\.closeness)
        #expect(closeness == closeness.sorted(by: >))
        let tail = Array(snap.badges.suffix(snap.earnedBadges))
        #expect(tail.allSatisfy { $0.earned })
        #expect(snap.earnedBadges == data.profile.badges.count)
        // Cifras reales de la demo.
        let steps = GameStore.verifiedSteps(in: data.sessions)
        let walker = snap.badges.first { $0.badge == .caminanteDelRajo }
        #expect(walker?.status == "\(SpanishDate.thousands(steps)) de 2.500 pasos")
        let relevo = snap.badges.first { $0.badge == .relevoCumplido }
        #expect(relevo?.status == "\(GameStore.relevoPauses(in: data.sessions)) de 5 pausas de 1 minuto")
        let tiro = snap.badges.first { $0.badge == .tiroLimpio }
        #expect(tiro?.status == "1 de 7 días")
        let earnedStatuses = snap.badges.filter { $0.earned }
        #expect(earnedStatuses.allSatisfy { $0.status == "Ganada" && !$0.earnedToday })
    }

    @Test func demoDespuesDeLaPausa() {
        let (before, _) = demo()
        let data = HomeQA.withPauseToday(before, now: demoNow, calendar: Self.santiago)
        let snap = snapshot(data)
        #expect(snap.goal.done)
        #expect(snap.goal.ringProgress == 1)
        #expect(snap.goal.title == "Doblete cumplido")
        #expect(snap.goal.subtitle == "Racha de 2 días. Mañana sigue.")
        #expect(snap.goal.chipsTitle == "Ganó hoy")
        #expect(snap.goal.chips.map(\.text) == ["Doblete", "+218 XP", "Insignia Doblete"])
        #expect(snap.goal.action == .secondary(title: "Hacer otra pausa · hasta +99 XP", symbol: "arrow.clockwise"))
        #expect(snap.goal.quickTitle == "Solo tengo 1 minuto · hasta +24 XP")
        #expect(!snap.goal.showsRoute)
        #expect(data.profile.xp == before.profile.xp + 218)
        #expect(snap.level.xp == before.profile.xp + 218)
        // Camino: hoy lleno y la línea azul une D1 y D2.
        #expect(snap.path.trailing == "2 de 7 con pausa")
        #expect(snap.path.segments.first == true)
        #expect(snap.path.nodes[1].state == .pausa)
        // Momentos: ✓ en el momento de la pausa.
        let pauseMoment = data.sessions.last?.moment
        #expect(snap.moments?.stops.first { $0.moment == pauseMoment }?.done == true)
        // Insignia del día: Doblete ganada hoy, la primera de las ganadas.
        let earned = snap.badges.filter(\.earned)
        #expect(earned.first?.badge == .doblete)
        #expect(earned.first?.status == "Ganada hoy")
        #expect(snap.earnedBadges == before.profile.badges.count + 1)
        #expect(BadgeProgress.earnedToday(data: data, calendar: WorkCalendar(profile: data.profile, calendar: Self.santiago),
                                          todayKey: "2026-10-23") == [.doblete])
        // Espalda: el RDQ de hoy aparece después del check-in.
        #expect(snap.back.todayScore == 2)
    }

    @Test func espaldaHoyConDatosReales() {
        let (data, wc) = demo()
        let back = snapshot(data).back
        #expect(back.todayScore == nil)
        let last = data.sessions.filter { $0.workDayKey < "2026-10-23" && ($0.checkInScore != nil || $0.postResponse != nil) }
            .max { $0.startedAt < $1.startedAt }
        #expect(back.previous?.score == last?.checkInScore)
        #expect(back.previous?.post == last?.postResponse)
        if last?.workDayKey == "2026-10-22" { #expect(back.previous?.label == "Ayer") }

        var withPain = data
        withPain.checkIns.append(DailyCheckIn(date: date(23, 15, 20), workDayKey: wc.key(for: date(23, 15, 20)),
                                              turnoKey: wc.turnoKey(for: date(23, 15, 20)), source: .meDueleAhora,
                                              answers: [], zone: .lumbar, context: .alBajar))
        #expect(snapshot(withPain).back.painLine == "Dolor registrado hoy · Al bajar · 15:20")
        #expect(BackSummary.Previous(label: "Ayer", score: 3, post: .mejor).line == "Ayer: 3 de 6 · terminó Mejor")
        #expect(BackSummary.Previous(label: "El martes 20", score: nil, post: .igual).line == "El martes 20: terminó Igual")
    }

    @Test func registrarDolorOMejorNoDaXPNiInsignias() {
        let (data, wc) = demo()
        var withPain = data
        for minute in 0..<3 {
            let at = date(23, 15, 20 + minute)
            withPain.checkIns.append(DailyCheckIn(date: at, workDayKey: wc.key(for: at), turnoKey: wc.turnoKey(for: at),
                                                  source: .meDueleAhora, answers: [], zone: .lumbar, context: .enCabina))
        }
        let a = snapshot(data), b = snapshot(withPain)
        #expect(a.goal == b.goal)
        #expect(a.level == b.level)
        #expect(a.badges == b.badges)
        // Un cierre "Mejor" no cambia el XP de la pausa (lo calcula `recording`, no la respuesta).
        var better = fullSession(at: date(23, 15, 0), data: data)
        better.postResponse = .mejor
        var worse = better
        worse.id = UUID()
        worse.postResponse = .peor
        #expect(GameStore.recording(better, in: data, calendar: wc).reward.totalXP
                == GameStore.recording(worse, in: data, calendar: wc).reward.totalXP)
    }

    // MARK: - Estados del día

    @Test func dia1PartaElTurno() {
        var data = blankData()
        mark(&data, counted: [12, 13, 14, 15, 16, 17, 18])
        // Lunes 26: día 1 del turno siguiente (ayer fue bajada: nunca x2).
        let snap = snapshot(data, now: date(26, 10))
        #expect(snap.title == "Día 1 de 7")
        #expect(snap.goal.title == "Parta el turno")
        #expect(snap.goal.subtitle == "Racha de 7 días. Con la pausa, sube a 8.")
        #expect(snap.goal.chips.map(\.text) == ["Partió", "Hasta +109 XP", "Insignia Primera pausa"])
        #expect(!snap.goal.chips.contains { $0.text.contains("x2") })
        #expect(snap.goal.eyebrow == "Colación · hasta las 15:00")
        // Sin racha: primera pausa del turno.
        let fresh = snapshot(blankData(), now: date(12, 10))
        #expect(fresh.goal.subtitle == "Haga su primera pausa del turno.")
        #expect(fresh.badges.first { $0.badge == .doblete }?.status == "Hoy y mañana con pausa")
    }

    @Test func dias3a6SigaLaRacha() {
        var data = blankData()
        data.profile.badges = [.primeraPausa, .doblete]
        mark(&data, counted: [12, 13, 14])
        let snap = snapshot(data, now: date(15, 16))
        #expect(snap.goal.title == "Siga la racha")
        #expect(snap.goal.subtitle == "Racha de 3 días. Con la pausa, sube a 4.")
        #expect(snap.goal.chips.map(\.text) == ["Doblete x2", "Hasta +218 XP"])
        // Ayer sin pausa (ni comodín): sin x2, y el camino quita Doblete y Tiro limpio solo si ya no se pueden.
        var gap = blankData()
        mark(&gap, counted: [12])
        let noDoblete = snapshot(gap, now: date(14, 10))
        #expect(noDoblete.goal.chips.map(\.text) == ["Hasta +109 XP", "Insignia Primera pausa"])
        #expect(noDoblete.path.nodes.map(\.milestone) == ["Partió", nil, nil, nil, nil, nil, nil])
        #expect(noDoblete.path.nodes[1].state == .missed)
        #expect(noDoblete.badges.first { $0.badge == .tiroLimpio }?.status == BadgeProgress.nextTurnoLine)
    }

    @Test func dia7VamosPorElTiroLimpio() {
        var data = blankData()
        data.profile.badges = [.primeraPausa, .doblete]
        mark(&data, counted: [12, 13, 14, 15, 16, 17])
        let snap = snapshot(data, now: date(18, 16))
        #expect(snap.goal.title == "Vamos por el Tiro limpio")
        #expect(snap.goal.subtitle == "6 de 6 días con pausa. Falta hoy.")
        #expect(snap.goal.chips.map(\.text) == ["Tiro limpio 7/7", "Doblete x2", "Hasta +218 XP", "Insignia Tiro limpio"])
        #expect(snap.badges.first?.badge == .tiroLimpio)
        #expect(snap.badges.first?.status == "Con la pausa de hoy")
        #expect(snap.path.nodes.last?.finale == .possible)

        // Hecha la pausa del día 7 (registrada con las reglas reales): Tiro limpio cumplido.
        let wc = WorkCalendar(profile: data.profile, calendar: Self.santiago)
        let done = GameStore.recording(fullSession(at: date(18, 15), data: data), in: data, calendar: wc).data
        let after = snapshot(done, now: date(18, 16))
        #expect(after.goal.title == "Tiro limpio cumplido")
        #expect(after.goal.subtitle == "7 de 7 días con pausa.")
        #expect(after.goal.chips.map(\.text).prefix(3) == ["Doblete", "Tiro limpio 7/7", "+218 XP"])
        #expect(after.goal.chips.contains { $0.text == "Insignia Tiro limpio" })
        #expect(after.path.nodes.last?.finale == .achieved)
        #expect(after.path.segments.allSatisfy { $0 })
        #expect(after.badges.first { $0.badge == .tiroLimpio }?.status == "Ganada hoy")
    }

    @Test func comodinUsadoAyer() {
        let data = HomeQA.data(arguments: [HomeQA.comodinAyer], now: date(14, 15, 30), calendar: Self.santiago)
        let snap = snapshot(data, now: date(14, 15, 30))
        #expect(snap.title == "Día 3 de 7")
        #expect(snap.goal.title == "Siga la racha")
        #expect(!snap.goal.chips.contains { $0.text.contains("x2") })
        #expect(snap.goal.chips.contains { $0.text == "Hasta +109 XP" })
        #expect(snap.path.comodinLine == CelebrationCopy.comodinUsedYesterdayLine)
        #expect(snap.path.nodes.prefix(3).map(\.state) == [.pausa, .comodin, .todayPending])
        #expect(snap.path.segments.first == true)
        #expect(snap.path.nodes.last?.milestone == nil)
        #expect(snap.path.nodes[1].milestone == nil)
        #expect(snap.badges.first { $0.badge == .tiroLimpio }?.status == "Se intenta el próximo turno.")
    }

    @Test func bajadaRachaASalvo() {
        var data = blankData()
        mark(&data, counted: [12, 13, 15, 16, 17, 18], comodin: [14])
        let snap = snapshot(data, now: date(21, 11))
        #expect(snap.isRestDay)
        #expect(snap.title == "Bajada")
        #expect(snap.subtitle == "Miércoles 21 · Buen descanso, Marco")
        #expect(snap.goal.title == "Racha a salvo")
        #expect(snap.goal.subtitle == "Vuelve al turno el lunes 26 de octubre.")
        #expect(snap.goal.eyebrow == "Día 3 de 7 de bajada")
        #expect(!snap.goal.ringIsGoal)
        #expect(snap.goal.streak == 6)
        #expect(snap.goal.chips.map(\.text).first == "Pausa opcional: hasta +109 XP")
        #expect(snap.goal.action == .secondary(title: "Hacer una pausa opcional", symbol: "play.fill"))
        #expect(snap.moments == nil)
        #expect(snap.path.title == "Turno pasado")
        #expect(snap.path.trailing == "6 de 7 con pausa")
        #expect(snap.path.comodinLine == nil)
        #expect(snap.path.dateLine == "Próximo turno: lunes 26 de octubre.")
        #expect(snap.path.nodes.allSatisfy { !$0.isToday })
        #expect(snap.level.note.hasSuffix("La pausa opcional da hasta +109 XP."))
    }

    @Test func pausaNoVerificadaNoEsCastigo() {
        var data = blankData()
        mark(&data, counted: [12])
        var failed = fullSession(at: date(13, 14, 2), data: data, counted: false, level: .suspicious)
        failed.xpEarned = 0
        data.sessions.append(failed)
        let snap = snapshot(data, now: date(13, 15))
        #expect(snap.goal.unverifiedLine == "La pausa de las 14:02 no se pudo verificar. Repita cuando pueda.")
        #expect(snap.goal.action == .primary(title: "Hacer la pausa", symbol: "play.fill"))
        #expect(!snap.goal.done)
        failed.xpEarned = 24
        data.sessions = [failed]
        #expect(snapshot(data, now: date(13, 15)).goal.unverifiedLine
                == "La pausa de las 14:02 se verificó solo en parte. Repita cuando pueda.")
    }

    @Test func turnoDeNocheUsaSusVentanas() {
        var data = blankData(shift: .night)
        mark(&data, counted: [12])
        // 01:00 del 14 pertenece al día laboral 13 (día 2): colación de noche, hasta las 03:00.
        let snap = snapshot(data, now: date(14, 1))
        #expect(snap.title == "Día 2 de 7")
        #expect(snap.goal.eyebrow == "Colación · hasta las 03:00")
        #expect(snap.moments?.trailing == "Turno de noche")
        #expect(snap.moments?.stops.map(\.start) == ["16:00", "21:30", "03:00", "08:30"])
        #expect(snap.moments?.stops.map(\.phase) == [.past, .now, .next, .next])
    }

    @Test func sinNombreYNuncaRachaRota() {
        var data = blankData()
        data.profile.name = "  "
        mark(&data, counted: [12], comodin: [13])
        for (day, hour) in [(12, 10), (13, 10), (14, 10), (16, 10), (18, 10), (21, 10), (26, 10)] {
            let snap = snapshot(data, now: date(day, hour))
            var texts = [snap.title, snap.subtitle, snap.goal.title, snap.goal.subtitle, snap.goal.eyebrow,
                         snap.goal.quickTitle, snap.goal.action.title, snap.path.trailing, snap.path.dateLine, snap.level.note]
            texts += snap.goal.chips.map(\.text) + snap.badges.map(\.status)
            texts += [snap.path.comodinLine, snap.moments?.line, snap.goal.unverifiedLine].compactMap { $0 }
            for text in texts {
                #expect(!text.lowercased().contains("rota"), "\(text)")
                #expect(!text.lowercased().contains("casco"), "\(text)")
                #expect(!CelebrationCopy.containsBannedFragment(text), "\(text)")
            }
            // Toda vista previa de XP dice "hasta".
            if !snap.goal.done {
                for chip in snap.goal.chips where chip.text.contains("XP") {
                    #expect(chip.text.lowercased().contains("hasta"), "\(chip.text)")
                }
            }
            #expect(snap.goal.quickTitle.contains("hasta +"))
            #expect(!snap.subtitle.contains(","))
        }
    }

    // MARK: - Fechas, caché y QA

    @Test func fechasEnEspanol() {
        #expect(SpanishDate.weekdayDay(date(23, 10), calendar: Self.santiago) == "viernes 23")
        #expect(SpanishDate.weekdayShort(date(28, 10), calendar: Self.santiago) == "mié")
        #expect(SpanishDate.weekdayDayMonth(date(5, 10, month: 11), calendar: Self.santiago) == "jueves 5 de noviembre")
        #expect(SpanishDate.clock(date(23, 9, 5), calendar: Self.santiago) == "09:05")
        #expect(SpanishDate.capitalizedFirst("sábado 31") == "Sábado 31")
        #expect(SpanishDate.thousands(2_500) == "2.500")
        #expect(SpanishDate.thousands(999) == "999")
        #expect(SpanishDate.thousands(1_234_567) == "1.234.567")
        #expect(SpanishDate.thousands(0) == "0")
    }

    @Test func cacheDelEjercicioQueMasAyudaPorDia() {
        let cache = PerDayCache<ActivityKind?>()
        var calls = 0
        let compute: () -> ActivityKind? = { calls += 1; return .cuello }
        #expect(cache.value(for: "2026-10-23#40", compute: compute) == .cuello)
        for _ in 0..<60 { _ = cache.value(for: "2026-10-23#40", compute: compute) }
        #expect(calls == 1)
        #expect(cache.computations == 1)
        // Pausa nueva o día nuevo: se recalcula una vez.
        _ = cache.value(for: "2026-10-23#41", compute: compute)
        _ = cache.value(for: "2026-10-24#41", compute: compute)
        #expect(calls == 3)
        // `nil` también se guarda (sin pausas "Mejor" no se recorre el historial cada minuto).
        let empty = PerDayCache<ActivityKind?>()
        var emptyCalls = 0
        for _ in 0..<5 { _ = empty.value(for: "k") { emptyCalls += 1; return nil } }
        #expect(emptyCalls == 1)
    }

    @Test func escenarioQADePausaHechaUsaLasReglasReales() {
        let (before, wc) = demo()
        let data = HomeQA.withPauseToday(before, now: demoNow, calendar: Self.santiago)
        let today = wc.key(for: demoNow)
        #expect(data.workDays[today]?.countedPauses == 1)
        let session = data.sessions.first { $0.workDayKey == today }
        #expect(session?.counted == true)
        #expect(session?.xpEarned == 218)
        #expect(data.profile.badges.contains(.doblete))
        #expect(data.checkIns.contains { $0.workDayKey == today && $0.source == .pausa })
    }
}
