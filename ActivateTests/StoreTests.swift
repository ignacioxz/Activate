import Testing
import Foundation
@testable import Activate

struct StoreTests {
    private let cal = Calendar.current

    /// Un "ahora" fijo: 23-10-2026 a la hora dada (hora local del simulador).
    private func now(hour: Int = 10, minute: Int = 15) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: hour, minute: minute))!
    }

    private func seededStore(now: Date) -> AppStore {
        let store = AppStore(inMemory: true)
        DemoSeed.load(into: store, now: now)
        return store
    }

    private func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivateStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    /// Instante dentro del día laboral de una clave (medianoche + hora de corte).
    private func inside(_ key: String, _ wc: WorkCalendar) throws -> Date {
        let midnight = try #require(wc.date(forKey: key))
        return try #require(wc.calendar.date(byAdding: .hour, value: wc.boundaryHour, to: midnight))
    }

    // MARK: - Persistencia

    @Test func guardarYCargarEnArchivoTemporal() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let n = now()
        let store = AppStore(fileURL: url)
        DemoSeed.load(into: store, now: n)
        store.addCheckIn(store.makeCheckIn(date: n, answers: [true, false, false, true, false, false], moment: .colacion))
        store.cacheStatsReading("Lectura de prueba.", forWorkDay: "2026-01-01")
        #expect(store.lastSaveError == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try #require(AppStore.load(from: url))
        #expect(loaded.version == store.data.version)
        #expect(loaded.profile == store.data.profile)
        #expect(loaded.workDays == store.data.workDays)
        #expect(loaded.checkIns == store.data.checkIns)
        #expect(loaded.sessions == store.data.sessions)
        #expect(loaded.demo == store.data.demo)
        #expect(loaded.statsReadingCache == store.data.statsReadingCache)
        #expect(loaded.lastKineSheetJSON == store.data.lastKineSheetJSON)

        let reopened = AppStore(fileURL: url)
        #expect(reopened.data.sessions.count == store.data.sessions.count)
        #expect(reopened.todayCheckIn(now: n)?.id == store.todayCheckIn(now: n)?.id)
        #expect(reopened.profile.name == "Marco")
    }

    // MARK: - Semilla

    @Test func semillaHoyEsDiaDosDeSubida() {
        let n = now()
        let store = seededStore(now: n)
        let wc = store.calendar
        #expect(store.profile.name == "Marco")
        #expect(store.profile.treatment == .usted)
        #expect(store.profile.roster == .sieteXSiete)
        #expect(store.profile.shiftType == .day)
        #expect(store.profile.usualZone == .lumbar)
        #expect(store.profile.consentGiven && store.profile.onboardingDone)
        #expect(store.data.demo == DemoConfig(enabled: true, shortTargets: true, coachOverride: .auto, notificationsMuted: true))
        #expect(store.isDemo)
        #expect(wc.kind(for: n) == .turno)
        #expect(wc.dayInBlock(for: n) == 2)
        let today = store.workDay(on: n)
        #expect(today?.dayInBlock == 2)
        #expect(today?.kind == .turno)
        #expect(today?.countedPauses == 0)
        #expect(today?.cascoUsed == false)
        #expect(store.todayCheckIn(now: n) == nil)
        #expect(store.sessions(onWorkDay: wc.key(for: n)).isEmpty)
        #expect(store.data.statsReadingCache[wc.key(for: n)] != nil)
    }

    @Test func semillaAyerContadoParaElDoblete() {
        let n = now()
        let store = seededStore(now: n)
        let wc = store.calendar
        let yKey = wc.key(for: wc.previousWorkDay(of: n))
        let day = store.workDay(for: yKey)
        #expect(day?.dayInBlock == 1)
        #expect(day?.kind == .turno)
        #expect(day?.turnoKey == wc.turnoKey(for: n))
        #expect((day?.countedPauses ?? 0) >= 1)
        #expect(day?.cascoUsed == false)
        let ySessions = store.sessions(onWorkDay: yKey)
        #expect(ySessions.contains { $0.counted && $0.level == .full && $0.postResponse == .mejor })
        #expect(store.sessions(inTurno: wc.turnoKey(for: n)).count == ySessions.count)
        #expect(store.profile.cascos == DemoSeed.cascosPerTurno)
        #expect(store.profile.badges.contains(.primeraPausa))
        #expect(!store.profile.badges.contains(.doblete))
        #expect(!store.profile.badges.contains(.tiroLimpio))
    }

    @Test func semillaRachaUnoAntesDeLaPausaEnVivoYDosConElDoblete() {
        let n = now()
        let store = seededStore(now: n)
        let wc = store.calendar
        // El turno anterior cierra el día 7 con un check-in suelto, sin pausa: la racha no viene de antes.
        #expect(StreakEngine.streak(days: store.data.workDays, calendar: wc, at: n) == 1)
        #expect(StreakEngine.dobleteAvailable(days: store.data.workDays, calendar: wc, at: n))
        // El cierre automático al arrancar no cambia eso (el casco del turno anterior ya se usó el día 2).
        let game = GameStore(store: store)
        game.applyDayRollover(now: n)
        #expect(game.streak(at: n) == 1)
        // Con la pausa en vivo de hoy (Doblete) la racha vale 2.
        var days = store.data.workDays
        days[wc.key(for: n)]?.countedPauses = 1
        #expect(StreakEngine.streak(days: days, calendar: wc, at: n) == 2)
    }

    @Test func semillaTurnoAnteriorDiaSieteEsCheckInSuelto() throws {
        let n = now()
        let store = seededStore(now: n)
        let wc = store.calendar
        let current = wc.turnoKey(for: n)
        let turnos = Set(store.data.workDays.values.map(\.turnoKey)).subtracting([current]).sorted()
        let previous = try #require(turnos.last)
        let day7 = try #require(store.workDays(inTurno: previous).first { $0.dayInBlock == 7 })
        #expect(day7.countedPauses == 0 && !day7.cascoUsed)
        #expect(store.sessions(onWorkDay: day7.key).isEmpty)
        #expect(store.checkIns(onWorkDay: day7.key).contains { $0.source == .pausa && $0.answers.count == RDQ6.items.count })
    }

    @Test func semillaSiembraZonasMultiples() {
        let n = now()
        let store = seededStore(now: n)
        #expect(store.profile.allUsualZones == [.lumbar])
        #expect(store.profile.usualZones == [.lumbar])
        #expect(store.data.checkIns.allSatisfy { $0.zones != nil && $0.allZones.contains(.lumbar) })
        #expect(store.data.checkIns.contains { $0.allZones == [.lumbar, .cuello] && $0.source == .pausa })
        #expect(store.data.checkIns.contains { $0.allZones == [.lumbar, .cuello] && $0.source == .meDueleAhora })
        #expect(store.data.checkIns.contains { $0.allZones == [.lumbar] })
        // Cada sesión lleva las mismas zonas que el check-in de su día.
        for s in store.data.sessions {
            let checkIn = store.checkIns(onWorkDay: s.workDayKey).last { $0.source == .pausa }
            #expect(s.allZones == checkIn?.allZones)
            #expect(s.zone == s.allZones.first)
        }
        #expect(store.data.sessions.contains { $0.allZones == [.lumbar, .cuello] })
    }

    // MARK: - Zonas múltiples

    @Test func makeCheckInYMakeSessionConZonas() {
        let store = AppStore(inMemory: true)
        let n = now()
        // Sin zonas explícitas: las habituales del perfil.
        store.updateProfile { $0.setUsualZones([.cuello, .lumbar]) }
        let byProfile = store.makeCheckIn(date: n, answers: Array(repeating: false, count: 6), moment: .colacion)
        #expect(byProfile.allZones == [.lumbar, .cuello] && byProfile.zone == .lumbar)
        // Zona única (API anterior).
        let single = store.makeCheckIn(date: n, answers: Array(repeating: false, count: 6), zone: .hombro)
        #expect(single.allZones == [.hombro] && single.zone == .hombro)
        // Selección múltiple explícita: normalizada y con la principal primero.
        let multi = store.makeCheckIn(date: n, answers: Array(repeating: false, count: 6), zones: [.otra, .hombro, .hombro])
        #expect(multi.zones == [.hombro, .otra] && multi.zone == .hombro)
        store.addCheckIn(multi)
        // La sesión toma las zonas del RDQ de hoy.
        let s = store.makeSession(moment: .colacion, startedAt: n.addingTimeInterval(60))
        #expect(s.allZones == [.hombro, .otra] && s.zone == .hombro)
        let explicit = store.makeSession(moment: .colacion, startedAt: n, zones: [.cuello])
        #expect(explicit.allZones == [.cuello])
    }

    @Test func seleccionVaciaEsNoMeDuele() {
        // Selección explícita vacía = "No me duele": no se reemplaza por la zona única ni por las habituales.
        #expect(AppStore.resolvedZones([], zone: .hombro, fallback: [.lumbar]) == [])
        #expect(AppStore.resolvedZones([.otra, .lumbar, .otra], zone: .hombro, fallback: []) == [.lumbar, .otra])
        #expect(AppStore.resolvedZones(nil, zone: .hombro, fallback: [.lumbar]) == [.hombro])
        #expect(AppStore.resolvedZones(nil, zone: nil, fallback: [.cuello, .lumbar]) == [.lumbar, .cuello])

        let store = AppStore(inMemory: true)
        let n = now()
        store.updateProfile { $0.setUsualZones([.cuello, .lumbar]) }
        let none = store.makeCheckIn(date: n, answers: Array(repeating: false, count: 6), zones: [], moment: .colacion)
        #expect(none.zones == [] && none.allZones.isEmpty && none.noPain)
        store.addCheckIn(none)
        // La sesión hereda el "No me duele" del RDQ de hoy; una selección vacía explícita también vale.
        let s = store.makeSession(moment: .colacion, startedAt: n.addingTimeInterval(60))
        #expect(s.allZones.isEmpty && s.noPain)
        let explicit = store.makeSession(moment: .colacion, startedAt: n, zones: [])
        #expect(explicit.allZones.isEmpty && explicit.noPain)
    }

    @Test func datosAntiguosSinZonasSiguenCargando() throws {
        // JSON guardado antes de la selección múltiple: sin "zones" ni "usualZones".
        let store = AppStore(inMemory: true)
        var legacyCheckIn = store.makeCheckIn(date: now(), answers: [true, false, false, false, false, false], zone: .cuello)
        legacyCheckIn.zones = nil
        var legacySession = store.makeSession(moment: .entrada, startedAt: now(), zone: .hombro)
        legacySession.zones = nil
        var profile = PlayerProfile(rosterStart: now())
        profile.usualZone = .hombro
        profile.usualZones = nil
        var save = SaveData(profile: profile)
        save.checkIns = [legacyCheckIn]
        save.sessions = [legacySession]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(save)
        let text = String(decoding: json, as: UTF8.self)
        #expect(!text.contains("\"zones\"") && !text.contains("\"usualZones\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(SaveData.self, from: json)
        #expect(loaded.checkIns[0].allZones == [.cuello])
        #expect(loaded.sessions[0].allZones == [.hombro])
        #expect(loaded.profile.allUsualZones == [.hombro])
    }

    @Test func semillaClavesCoherentesConWorkCalendar() throws {
        let n = now()
        let store = seededStore(now: n)
        let wc = store.calendar
        #expect(!store.data.sessions.isEmpty)
        for s in store.data.sessions {
            #expect(s.workDayKey == wc.key(for: s.startedAt))
            #expect(s.turnoKey == wc.turnoKey(for: s.startedAt))
            #expect(s.recipe == s.moment.recipe)
            #expect(Moment.infer(date: s.startedAt, shift: .day, calendar: wc.calendar) == s.moment)
            #expect(s.endedAt != nil && s.monotonicSeconds > 0)
            #expect(s.counted == VerificationPolicy.counts(s.activities))
            #expect(s.level == VerificationPolicy.sessionLevel(s.activities))
            #expect(!s.simulated && s.integrityFlags.isEmpty)
            #expect(s.checkInAnswers.count == RDQ6.items.count)
            #expect(s.checkInScore == s.checkInAnswers.filter { $0 }.count)
            #expect(s.activities.allSatisfy { $0.level >= .reduced && $0.anomalies.isEmpty })
            #expect(store.workDay(for: s.workDayKey) != nil)
        }
        for c in store.data.checkIns {
            #expect(c.workDayKey == wc.key(for: c.date))
            #expect(c.turnoKey == wc.turnoKey(for: c.date))
            #expect(!c.hasAlarm)
            if c.source == .pausa {
                #expect(c.answers.count == RDQ6.items.count)
                #expect(c.moment != nil)
            } else {
                #expect(c.answers.isEmpty && c.context != nil)
            }
        }
        for (key, day) in store.data.workDays {
            let date = try inside(key, wc)
            #expect(day.key == key)
            #expect(wc.key(for: date) == key)
            #expect(day.kind == wc.kind(for: date))
            #expect(day.dayInBlock == wc.dayInBlock(for: date))
            #expect(day.turnoKey == wc.turnoKey(for: date))
            #expect(day.countedPauses == store.sessions(onWorkDay: key).filter(\.counted).count)
            if day.cascoUsed { #expect(day.countedPauses == 0) }
        }
    }

    @Test func semillaDosTurnosAnterioresConElPatronDelCaso() throws {
        let n = now()
        let store = seededStore(now: n)
        let wc = store.calendar
        let current = wc.turnoKey(for: n)
        let previous = Set(store.data.workDays.values.map(\.turnoKey)).subtracting([current]).sorted()
        #expect(previous.count == 2)
        for t in previous {
            let days = store.workDays(inTurno: t)
            #expect(days.count == 7)
            #expect(days.map(\.dayInBlock) == Array(1...7))
            #expect(days.allSatisfy { $0.kind == .turno })
            let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.dayInBlock, $0) })
            let d1 = try #require(byDay[1]), d2 = try #require(byDay[2])
            let d3 = try #require(byDay[3]), d5 = try #require(byDay[5])
            #expect(d1.countedPauses >= 1)                       // día 1: pausa sí
            #expect(d2.countedPauses == 0 && d2.cascoUsed)       // día 2: casco
            let rdq3 = store.checkIns(onWorkDay: d3.key).filter { $0.source == .pausa }
            #expect(rdq3.contains { $0.score == 4 && $0.answers[RDQ6.itemAvoidsBending] })   // día 3
            let rdq5 = store.checkIns(onWorkDay: d5.key).filter { $0.source == .pausa }
            #expect(rdq5.contains { $0.score == RDQ6.maxScore })                              // día 5: peak
            for d in 1..<7 {                                      // nunca dos días seguidos: el Doblete es en vivo
                let a = try #require(byDay[d]), b = try #require(byDay[d + 1])
                #expect(!(a.countedPauses > 0 && b.countedPauses > 0))
            }
            #expect(days.filter { $0.cascoUsed }.count == DemoSeed.cascosPerTurno)
            let sessions = store.sessions(inTurno: t)
            #expect(sessions.count >= 3)
            #expect(sessions.allSatisfy { $0.turnoKey == t })
            #expect(sessions == sessions.sorted { $0.startedAt < $1.startedAt })
            #expect(sessions.contains { $0.activities.contains { $0.kind == .stroop } })
            #expect(sessions.contains { $0.activities.contains { $0.kind == .pasos } })
            #expect(store.checkIns(inTurno: t).contains { $0.source == .meDueleAhora })
        }
        let posts = store.data.sessions.compactMap(\.postResponse)
        #expect(posts.filter { $0 == .mejor }.count * 2 > posts.count)
        #expect(store.profile.xp == store.data.sessions.reduce(0) { $0 + $1.xpEarned })
        #expect(store.profile.xp > 0)
    }

    @Test func semillaAntesDelCambioDeDiaSigueSiendoDiaDos() {
        let n = now(hour: 2, minute: 30) // 02:30: aún es el día laboral anterior (corte 04:00)
        let store = seededStore(now: n)
        let wc = store.calendar
        #expect(wc.key(for: n) == "2026-10-22")
        #expect(wc.dayInBlock(for: n) == 2)
        #expect(store.workDay(for: "2026-10-22")?.dayInBlock == 2)
        #expect(store.workDay(for: "2026-10-22")?.countedPauses == 0)
        #expect((store.workDay(for: "2026-10-21")?.countedPauses ?? 0) >= 1)
        #expect(store.sessions(onWorkDay: "2026-10-21").contains { $0.counted })
        #expect(store.todayCheckIn(now: n) == nil)
    }

    @Test func semillaPuraConCalendarioDeSantiagoEsDeterminista() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago")!
        let n = c.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 10, minute: 15))!
        let data = DemoSeed.data(now: n, calendar: c)
        let again = DemoSeed.data(now: n, calendar: c)
        let wc = WorkCalendar(profile: data.profile, calendar: c)
        #expect(wc.key(for: n) == "2026-10-23")
        #expect(wc.dayInBlock(for: n) == 2)
        #expect(data.workDays["2026-10-23"]?.countedPauses == 0)
        #expect(data.workDays["2026-10-22"]?.countedPauses == 1)
        #expect(data.workDays["2026-10-08"]?.dayInBlock == 1)   // turno anterior
        #expect(data.workDays["2026-09-24"]?.dayInBlock == 1)   // dos turnos atrás
        #expect(data.workDays["2026-09-25"]?.cascoUsed == true)
        for s in data.sessions {
            #expect(s.workDayKey == wc.key(for: s.startedAt))
            #expect(s.turnoKey == wc.turnoKey(for: s.startedAt))
        }
        // Mismas cifras en dos cargas (solo cambian los UUID).
        #expect(data.sessions.map(\.xpEarned) == again.sessions.map(\.xpEarned))
        #expect(data.sessions.map(\.activities).map { $0.map(\.metrics) } == again.sessions.map(\.activities).map { $0.map(\.metrics) })
        #expect(data.profile.xp == again.profile.xp)
    }

    // MARK: - Consultas y mutaciones

    @Test func ensureWorkDayCreaDesdeElCalendarioYEsIdempotente() {
        let store = AppStore(inMemory: true)
        store.updateProfile { $0.rosterStart = cal.date(from: DateComponents(year: 2026, month: 10, day: 12))! }
        let d = now()                                   // 23-10 = día 5 de bajada
        let day = store.ensureWorkDay(for: d)
        #expect(day.key == "2026-10-23")
        #expect(day.kind == .descanso && day.dayInBlock == 5 && day.turnoKey == "2026-10-12")
        store.updateWorkDay(forKey: day.key) { $0.countedPauses = 2 }
        #expect(store.ensureWorkDay(for: d).countedPauses == 2)
        #expect(store.data.workDays.count == 1)
        let byKey = store.ensureWorkDay(forKey: "2026-10-14")
        #expect(byKey?.kind == .turno && byKey?.dayInBlock == 3 && byKey?.turnoKey == "2026-10-12")
        #expect(store.ensureWorkDay(forKey: "nada") == nil)
        store.updateWorkDay(forKey: "2026-10-15") { $0.cascoUsed = true }
        #expect(store.workDay(for: "2026-10-15")?.cascoUsed == true)
        #expect(store.workDay(for: "2026-10-15")?.dayInBlock == 4)
        // La bajada (23-10) pertenece al mismo ciclo: comparte turnoKey.
        #expect(store.workDays(inTurno: "2026-10-12").map(\.key) == ["2026-10-14", "2026-10-15", "2026-10-23"])
    }

    @Test func todayCheckInTomaElUltimoRDQDelDiaLaboral() {
        let store = AppStore(inMemory: true)
        let n = now()
        let first = store.makeCheckIn(date: cal.date(byAdding: .hour, value: -2, to: n)!,
                                      answers: [true, true, false, false, false, false], moment: .entrada)
        let later = store.makeCheckIn(date: n, answers: [true, true, true, false, false, false], moment: .colacion)
        let pain = store.makeCheckIn(date: cal.date(byAdding: .minute, value: 10, to: n)!,
                                     source: .meDueleAhora, answers: [], context: .alBajar)
        let yesterday = store.makeCheckIn(date: cal.date(byAdding: .day, value: -1, to: n)!,
                                          answers: [true, false, false, false, false, false], moment: .colacion)
        store.addCheckIn(first)
        store.addCheckIn(pain)
        store.addCheckIn(later)
        store.addCheckIn(yesterday)
        store.addCheckIn(later)                          // mismo id: no duplica
        #expect(store.data.checkIns.count == 4)
        #expect(store.todayCheckIn(now: n)?.id == later.id)
        #expect(store.todayCheckIn(now: n)?.score == 3)
        #expect(later.zone == store.profile.usualZone)
        #expect(later.workDayKey == store.calendar.key(for: n))
        #expect(store.checkIns(onWorkDay: later.workDayKey).map(\.id) == [first.id, later.id, pain.id])
        #expect(store.workDay(for: later.workDayKey) != nil)
        #expect(store.workDay(for: yesterday.workDayKey) != nil)
        #expect(store.todayCheckIn(now: yesterday.date)?.id == yesterday.id)
        #expect(store.todayCheckIn(now: now(hour: 3, minute: 0))?.id == yesterday.id) // antes de las 04:00
        #expect(store.todayCheckIn(now: cal.date(byAdding: .day, value: 3, to: n)!) == nil)
    }

    @Test func addYUpdateSessionReemplazanPorId() {
        let store = AppStore(inMemory: true)
        let n = now()
        let checkIn = store.makeCheckIn(date: n.addingTimeInterval(-60), answers: [true, false, true, false, false, false], moment: .colacion)
        store.addCheckIn(checkIn)
        var s = store.makeSession(moment: .colacion, startedAt: n)
        #expect(s.workDayKey == store.calendar.key(for: n))
        #expect(s.turnoKey == store.calendar.turnoKey(for: n))
        #expect(s.recipe == .colacion3)
        #expect(s.checkInScore == 2 && s.checkInAnswers == checkIn.answers)
        #expect(s.zone == store.profile.usualZone)
        store.addSession(s)
        store.addSession(s)                                   // idempotente
        #expect(store.data.sessions.count == 1)
        s.postResponse = .mejor
        s.counted = true
        s.endedAt = n.addingTimeInterval(180)
        store.updateSession(s)
        #expect(store.data.sessions.count == 1)
        #expect(store.session(id: s.id)?.postResponse == .mejor)
        #expect(store.workDay(for: s.workDayKey)?.countedPauses == 0)   // el libro mayor lo lleva GameStore
        let other = store.makeSession(moment: .campamento, startedAt: cal.date(byAdding: .day, value: -14, to: n)!)
        store.updateSession(other)                            // inexistente → se agrega
        #expect(store.data.sessions.count == 2)
        #expect(store.sessions(inTurno: s.turnoKey).map(\.id) == [s.id])
        #expect(store.sessions(inTurno: other.turnoKey).map(\.id) == [other.id])
        #expect(store.sessions(onWorkDay: s.workDayKey).map(\.id) == [s.id])
        store.removeSession(id: other.id)
        #expect(store.data.sessions.map(\.id) == [s.id])
    }

    @Test func setDemoSetProfileYResetAll() {
        let n = now()
        let store = seededStore(now: n)
        store.setDemo(DemoConfig(enabled: false, shortTargets: false, coachOverride: .rules, notificationsMuted: false))
        #expect(!store.isDemo && store.data.demo.coachOverride == .rules)
        var p = store.profile
        p.name = "Pedro"
        p.shiftType = .night
        store.setProfile(p)
        #expect(store.profile.name == "Pedro")
        #expect(store.calendar.boundaryHour == ShiftType.night.dayBoundaryHour)
        store.setKineSheetJSON("{}")
        #expect(store.data.lastKineSheetJSON == "{}")

        store.resetAll(now: n)
        #expect(store.data.sessions.isEmpty && store.data.checkIns.isEmpty && store.data.workDays.isEmpty)
        #expect(store.data.statsReadingCache.isEmpty && store.data.lastKineSheetJSON == nil)
        #expect(store.profile.xp == 0 && store.profile.badges.isEmpty && !store.profile.onboardingDone)
        #expect(store.profile.name == PlayerProfile(rosterStart: n).name)
        #expect(store.data.demo == DemoConfig())
        #expect(store.profile.rosterStart == cal.startOfDay(for: n))
    }
}
