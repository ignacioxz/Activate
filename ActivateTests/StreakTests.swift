import Testing
import Foundation
@testable import Activate

/// Racha, casco automático, Doblete, Tiro limpio y XP sobre `GameStore` + `StreakEngine`.
/// Turno 7×7 que sube el lunes 12-10-2026 (días 12-18 turno, 19-25 descanso, 26 día 1 otra vez).
@MainActor
struct StreakTests {
    private let cal = Calendar.current

    private func date(_ day: Int, month: Int = 10, hour: Int = 8, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeGame(shift: ShiftType = .day) -> (AppStore, GameStore) {
        let store = AppStore(inMemory: true)
        store.mutate { data in
            data.profile.rosterStart = cal.startOfDay(for: date(12))
            data.profile.shiftType = shift
            data.profile.cascos = 1
        }
        return (store, GameStore(store: store))
    }

    private func result(_ kind: ActivityKind, level: VerificationLevel = .full, completed: Bool = true, steps: Int? = nil) -> ActivityResult {
        let metrics: ActivityMetrics = steps.map { .steps(count: $0, meanCadence: nil, walkingFraction: nil, rmsPeak: nil) } ?? .none
        return ActivityResult(kind: kind, target: kind.defaultTarget, achieved: kind.defaultTarget, durationSeconds: 30,
                              completed: completed, level: level, metrics: metrics, anomalies: [])
    }

    private func session(at date: Date, store: AppStore, recipe: RecipeKind = .relevo60,
                         activities: [ActivityResult]? = nil, counted: Bool = true,
                         level: VerificationLevel = .full, simulated: Bool = false) -> PauseSession {
        let c = store.calendar
        var s = PauseSession(workDayKey: c.key(for: date), turnoKey: c.turnoKey(for: date), recipe: recipe, moment: .entrada, startedAt: date)
        s.endedAt = date.addingTimeInterval(60)
        s.activities = activities ?? [result(.cuello), result(.ojos)]
        s.counted = counted
        s.level = level
        s.simulated = simulated
        return s
    }

    // MARK: Racha

    @Test func bajadaNoRompeLaRacha() {
        let (store, game) = makeGame()
        var last: SessionReward?
        for day in 12...18 { last = game.record(session(at: date(day), store: store)) }
        #expect(last?.streak == 7)
        #expect(game.streak(at: date(18, hour: 23)) == 7)

        // Toda la bajada: la racha se congela, no se corta.
        #expect(game.streak(at: date(22)) == 7)
        game.applyDayRollover(now: date(26))
        #expect(game.cascos == 1)
        #expect(store.data.workDays.values.allSatisfy { !$0.cascoUsed })
        #expect(game.streak(at: date(26)) == 7)

        // Día 1 del turno siguiente: sigue sumando, sin Doblete (ayer fue descanso).
        let reward = game.record(session(at: date(26), store: store))
        #expect(reward.streak == 8)
        #expect(reward.dayInBlock == 1)
        #expect(!reward.isDoblete)
    }

    @Test func motorPuroConCascoYBajada() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago")!
        let start = c.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        let wc = WorkCalendar(roster: .sieteXSiete, rosterStart: start, boundaryHour: 4, calendar: c)
        func day(_ key: String, counted: Int = 0, casco: Bool = false) -> WorkDay {
            var d = StreakEngine.workDay(forKey: key, in: [:], calendar: wc)!
            d.countedPauses = counted
            d.cascoUsed = casco
            return d
        }
        var days: [String: WorkDay] = [
            "2026-10-12": day("2026-10-12", counted: 1),
            "2026-10-13": day("2026-10-13", counted: 2),
            "2026-10-14": day("2026-10-14", casco: true),
            "2026-10-15": day("2026-10-15", counted: 1),
        ]
        func at(_ day: Int, hour: Int = 9) -> Date { c.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        // Hoy (día 5) sin pausa todavía: 3 días contados; el casco mantiene sin sumar.
        #expect(StreakEngine.streak(days: days, calendar: wc, at: at(16)) == 3)
        #expect(days["2026-10-14"]?.dayInBlock == 3)
        #expect(days["2026-10-14"]?.turnoKey == "2026-10-12")
        #expect(StreakEngine.dobleteAvailable(days: days, calendar: wc, at: at(16)))
        // Día 5 cerrado sin pausa ni casco: se corta.
        #expect(StreakEngine.streak(days: days, calendar: wc, at: at(17)) == 0)

        // Turno completo hasta el día 7: la bajada congela la racha y el día 1 siguiente la retoma.
        for d in 16...18 { days["2026-10-\(d)"] = day("2026-10-\(d)", counted: 1) }
        #expect(StreakEngine.streak(days: days, calendar: wc, at: at(18, hour: 23)) == 6)
        #expect(StreakEngine.streak(days: days, calendar: wc, at: at(22)) == 6)
        #expect(StreakEngine.streak(days: days, calendar: wc, at: at(26)) == 6)
        #expect(!StreakEngine.dobleteAvailable(days: days, calendar: wc, at: at(22)))
        #expect(!StreakEngine.dobleteAvailable(days: days, calendar: wc, at: at(26)))
        // Día 1 del turno siguiente cerrado sin pausa ni casco: se corta recién ahí.
        #expect(StreakEngine.streak(days: days, calendar: wc, at: at(27)) == 0)
        #expect(StreakEngine.isTiroLimpio(days: days, calendar: wc, turnoContaining: at(18)) == false)
        days["2026-10-14"] = day("2026-10-14", counted: 1)
        #expect(StreakEngine.isTiroLimpio(days: days, calendar: wc, turnoContaining: at(18)))
        #expect(StreakEngine.countedDays(days: days, calendar: wc, turnoContaining: at(22)) == 7)
    }

    // MARK: Casco automático

    @Test func cascoAutomaticoUnoPorTurno() {
        let (store, game) = makeGame()
        game.record(session(at: date(12), store: store))

        // Día 2 sin pausa; al abrir el día 3 se marca solo y se descuenta.
        game.applyDayRollover(now: date(14))
        #expect(store.data.workDays["2026-10-13"]?.cascoUsed == true)
        #expect(store.data.workDays["2026-10-13"]?.countedPauses == 0)
        #expect(store.data.workDays["2026-10-13"]?.dayInBlock == 2)
        #expect(game.cascos == 0)
        #expect(game.streak(at: date(14)) == 1)

        // Pausa del día 3: la racha sigue (1 + 1), pero no es Doblete (ayer fue casco, no pausa).
        let reward = game.record(session(at: date(14), store: store))
        #expect(reward.streak == 2)
        #expect(!reward.isDoblete)

        // Día 4 sin pausa y sin casco: no se marca y la racha se corta.
        game.applyDayRollover(now: date(16))
        #expect(store.data.workDays["2026-10-15"]?.cascoUsed != true)
        #expect(game.streak(at: date(16)) == 0)

        // Idempotente.
        let before = store.data.workDays
        game.applyDayRollover(now: date(16))
        #expect(store.data.workDays == before)

        // Día 1 del turno siguiente: se repone el casco; el día 4 viejo no se marca retroactivamente.
        game.applyDayRollover(now: date(26))
        #expect(game.cascos == 1)
        #expect(store.data.workDays["2026-10-15"]?.cascoUsed != true)
        // Nunca se inventan días anteriores a la primera pausa (ni del ciclo previo al rosterStart).
        #expect(store.data.workDays.keys.allSatisfy { $0 >= "2026-10-12" })
        #expect(store.data.workDays.values.filter(\.cascoUsed).map(\.key) == ["2026-10-13"])
    }

    @Test func sinPausaPreviaElCascoSeGuarda() {
        // Marco se registra el día 3 del turno: los días 1 y 2 no gastan el casco.
        let (store, game) = makeGame()
        game.applyDayRollover(now: date(14))
        #expect(game.cascos == 1)
        #expect(store.data.workDays.isEmpty)
        game.record(session(at: date(14), store: store))
        game.applyDayRollover(now: date(16))
        #expect(store.data.workDays["2026-10-15"]?.cascoUsed == true)
        #expect(game.cascos == 0)
        #expect(game.streak(at: date(16)) == 1)
    }

    @Test func cascoCubreVariosDiasSinAbrirLaApp() {
        let (store, game) = makeGame()
        game.record(session(at: date(12), store: store))
        // No abre la app los días 2 y 3; el casco va al primero, el segundo corta.
        game.applyDayRollover(now: date(15))
        #expect(store.data.workDays["2026-10-13"]?.cascoUsed == true)
        #expect(store.data.workDays["2026-10-14"]?.cascoUsed != true)
        #expect(game.cascos == 0)
        #expect(game.streak(at: date(15)) == 0)
    }

    // MARK: Turno de noche

    @Test func turnoDeNocheConCambioALas12() {
        let (store, game) = makeGame(shift: .night)
        #expect(store.calendar.boundaryHour == 12)
        // Día 1 (12-10 12:00 → 13-10 12:00): pausa de entrada a las 20:00.
        let r1 = game.record(session(at: date(12, hour: 20), store: store))
        #expect(r1.dayInBlock == 1)
        // Día 2: colación a la 01:00 del 14-10 pertenece al día laboral 13-10.
        let r2 = game.record(session(at: date(14, hour: 1), store: store))
        #expect(store.data.workDays["2026-10-13"]?.countedPauses == 1)
        #expect(r2.dayInBlock == 2)
        #expect(r2.isDoblete)
        #expect(r2.streak == 2)
        // Campamento a las 09:00 del mismo día laboral: segunda pausa, sin bono ni Doblete.
        let r3 = game.record(session(at: date(14, hour: 9), store: store, recipe: .campamento5))
        #expect(store.data.workDays["2026-10-13"]?.countedPauses == 2)
        #expect(!r3.isDoblete)
        #expect(!r3.lines.contains { $0.label == "Primera pausa del día" })
        // Cierre del día a las 12:00: no hay nada que proteger, el casco sigue disponible.
        game.applyDayRollover(now: date(14, hour: 11))
        game.applyDayRollover(now: date(14, hour: 13))
        #expect(game.cascos == 1)
        #expect(store.data.workDays.values.allSatisfy { !$0.cascoUsed })
        #expect(game.streak(at: date(14, hour: 11)) == 2)
        #expect(game.streak(at: date(14, hour: 13)) == 2)
    }

    // MARK: Doblete y XP

    @Test func dobleteDuplicaElXP() {
        let (store, game) = makeGame()
        let r1 = game.record(session(at: date(12), store: store))
        #expect(r1.totalXP == 12 + 12 + 10)
        #expect(r1.newBadges == [.primeraPausa])
        #expect(!r1.isDoblete)

        let r2 = game.record(session(at: date(13), store: store))
        #expect(r2.isDoblete)
        #expect(r2.totalXP == (12 + 12 + 10) * 2)
        #expect(r2.lines.map(\.xp).reduce(0, +) == r2.totalXP)
        #expect(r2.newBadges == [.doblete])
        #expect(r2.streak == 2)
        #expect(r2.dayInBlock == 2)
        #expect(store.data.profile.xp == 34 + 68)
        #expect(store.data.sessions.count == 2)
        #expect(store.data.sessions.last?.xpEarned == 68)
    }

    @Test func xpSegunNivelDeVerificacion() {
        let (store, game) = makeGame()
        let acts = [result(.pasos), result(.respiracion, level: .reduced), result(.stroop, level: .suspicious), result(.sentadilla, completed: false)]
        let r = game.record(session(at: date(12), store: store, recipe: .campamento5, activities: acts))
        #expect(r.lines.map(\.xp) == [20, 4, 0, 10])
        #expect(r.totalXP == 34)
        #expect(!r.newBadges.contains(.rajoCompleto))

        // Sesión sospechosa: no suma, no cuenta, no rompe.
        let s = game.record(session(at: date(13), store: store, level: .suspicious))
        #expect(s.totalXP == 0 && !s.counted && s.lines.isEmpty)
        #expect(store.data.workDays["2026-10-13"]?.countedPauses == 0)
        #expect(game.streak(at: date(13)) == 1)

        // Simulada: fuera de todo.
        let sim = game.record(session(at: date(13), store: store, level: .full, simulated: true))
        #expect(sim.totalXP == 0 && !sim.counted)
        #expect(store.data.profile.xp == 34)
    }

    // MARK: Tiro limpio e insignias

    @Test func tiroLimpioAlSeptimoDia() {
        let (store, game) = makeGame()
        var rewards: [SessionReward] = []
        for day in 12...18 { rewards.append(game.record(session(at: date(day), store: store))) }
        #expect(rewards.dropLast().allSatisfy { !$0.isTiroLimpio })
        let last = rewards.last!
        #expect(last.isTiroLimpio)
        #expect(last.streak == 7)
        #expect(last.dayInBlock == 7)
        #expect(last.newBadges.contains(.tiroLimpio))
        // Una segunda pausa el día 7 no vuelve a celebrar el hito.
        let again = game.record(session(at: date(18, hour: 21), store: store))
        #expect(!again.isTiroLimpio)
        #expect(store.data.profile.badges.contains(.tiroLimpio))
    }

    @Test func insigniasRelevoRajoYCaminante() {
        let (store, game) = makeGame()
        // Relevo cumplido: 5 pausas contadas de relevo.
        var relevo: [SessionReward] = []
        for day in 12...16 { relevo.append(game.record(session(at: date(day), store: store))) }
        #expect(!relevo[3].newBadges.contains(.relevoCumplido))
        #expect(relevo[4].newBadges.contains(.relevoCumplido))

        // Rajo completo: campamento con todo verificado (respiración contada basta).
        let full = Recipes.base(.campamento5, demo: false).activities.map { a -> ActivityResult in
            result(a.kind, level: a.kind.weakByNature ? .reduced : .full, steps: a.kind == .pasos ? 1_300 : nil)
        }
        let rajo = game.record(session(at: date(17), store: store, recipe: .campamento5, activities: full))
        #expect(rajo.newBadges.contains(.rajoCompleto))
        #expect(!rajo.newBadges.contains(.caminanteDelRajo))

        // Caminante del rajo: 2.500 pasos verificados acumulados (los sospechosos no suman).
        let sospechoso = game.record(session(at: date(18), store: store, recipe: .colacion3,
                                             activities: [result(.pasos, level: .suspicious, steps: 5_000), result(.cuello)]))
        #expect(!sospechoso.newBadges.contains(.caminanteDelRajo))
        let caminante = game.record(session(at: date(18, hour: 21), store: store, recipe: .colacion3,
                                            activities: [result(.pasos, steps: 1_200), result(.cuello)]))
        #expect(caminante.newBadges.contains(.caminanteDelRajo))
        #expect(GameStore.verifiedSteps(in: store.data.sessions) == 2_500)
    }
}
