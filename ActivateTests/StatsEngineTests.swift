import Testing
import Foundation
@testable import Activate

/// Datos sintéticos: roster 7×7 que sube el lunes 12 oct 2026. Turnos con datos:
/// T0 = 14 sep, T1 = 28 sep, T2 = 12 oct (actual). "Hoy" por defecto es el 16 oct (día 5) a las 10:00.
struct StatsEngineTests {

    // MARK: - Fixture

    struct Fixture {
        var cal: WorkCalendar
        var data: SaveData

        init(shift: ShiftType = .day) {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "America/Santiago")!
            let start = c.date(from: DateComponents(year: 2026, month: 10, day: 12))!
            cal = WorkCalendar(roster: .sieteXSiete, rosterStart: start, boundaryHour: shift.dayBoundaryHour, calendar: c)
            var profile = PlayerProfile(rosterStart: start)
            profile.shiftType = shift
            data = SaveData(profile: profile)
        }

        func date(_ month: Int, _ day: Int, hour: Int = 10, minute: Int = 0) -> Date {
            cal.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }

        @discardableResult
        mutating func checkIn(_ month: Int, _ day: Int, hour: Int = 9, score: Int, answers: [Bool]? = nil,
                              source: CheckInSource = .pausa, context: PainContext? = nil) -> DailyCheckIn {
            let d = date(month, day, hour: hour)
            let a = answers ?? (0..<6).map { $0 < score }
            let c = DailyCheckIn(date: d, workDayKey: cal.key(for: d), turnoKey: cal.turnoKey(for: d), source: source,
                                 answers: source == .pausa ? a : [], zone: .lumbar,
                                 moment: Moment.infer(date: d, shift: data.profile.shiftType, calendar: cal.calendar),
                                 context: context)
            data.checkIns.append(c)
            return c
        }

        @discardableResult
        mutating func pain(_ month: Int, _ day: Int, hour: Int = 15, context: PainContext) -> DailyCheckIn {
            checkIn(month, day, hour: hour, score: 0, source: .meDueleAhora, context: context)
        }

        @discardableResult
        mutating func session(_ month: Int, _ day: Int, hour: Int = 12, moment: Moment = .colacion,
                              rdq: Int? = 2, post: PostResponse? = .mejor, level: VerificationLevel = .full,
                              counted: Bool? = nil, simulated: Bool = false,
                              activities: [ActivityResult] = []) -> PauseSession {
            let d = date(month, day, hour: hour)
            let acts = activities.isEmpty ? [Self.stroop(rt: 650, level: level)] : activities
            let s = PauseSession(workDayKey: cal.key(for: d), turnoKey: cal.turnoKey(for: d), recipe: moment.recipe,
                                 moment: moment, startedAt: d, endedAt: d.addingTimeInterval(180), monotonicSeconds: 180,
                                 checkInScore: rdq, postResponse: post, activities: acts,
                                 counted: counted ?? (level == .full && !simulated), level: level, simulated: simulated)
            data.sessions.append(s)
            return s
        }

        mutating func ledger(_ month: Int, _ day: Int, counted: Int = 1, casco: Bool = false) {
            let d = date(month, day)
            let key = cal.key(for: d)
            data.workDays[key] = WorkDay(key: key, kind: cal.kind(for: d), dayInBlock: cal.dayInBlock(for: d),
                                         turnoKey: cal.turnoKey(for: d), countedPauses: counted, cascoUsed: casco)
        }

        func summary(now: Date? = nil) -> StatsSummary {
            StatsEngine.summary(data: data, calendar: cal, now: now ?? date(10, 16))
        }

        // Actividades
        static func steps(_ count: Int, level: VerificationLevel = .full, skipped: Bool = false) -> ActivityResult {
            ActivityResult(kind: .pasos, target: count, achieved: count, durationSeconds: 120, completed: true, level: level,
                           metrics: .steps(count: count, meanCadence: 1.8, walkingFraction: 0.9, rmsPeak: 1.2), anomalies: [], skipped: skipped)
        }
        static func reps(_ count: Int, level: VerificationLevel = .full, skipped: Bool = false) -> ActivityResult {
            ActivityResult(kind: .sentadilla, target: count, achieved: count, durationSeconds: 40, completed: true, level: level,
                           metrics: .reps(count: count, minDescentRatio: 0.3, meanRepSeconds: 3), anomalies: [], skipped: skipped)
        }
        static func stroop(rt: Int, level: VerificationLevel = .full) -> ActivityResult {
            ActivityResult(kind: .stroop, target: 40, achieved: 40, durationSeconds: 60, completed: true, level: level,
                           metrics: .stroop(trials: 40, valid: 38, accuracy: 0.9, medianRTms: rt, medianCongruentRTms: rt - 50,
                                            medianIncongruentRTms: rt + 50, anticipations: 1, lapses: 1, seed: 7), anomalies: [])
        }
        static func eyes(bpm: Double, level: VerificationLevel = .full) -> ActivityResult {
            ActivityResult(kind: .ojos, target: 15, achieved: 15, durationSeconds: 60, completed: true, level: level,
                           metrics: .eyes(completeBlinks: 15, partialBlinks: 2, blinksPerMinute: bpm, farGazeSeconds: 20), anomalies: [])
        }
        static func neck(yaw: Double, level: VerificationLevel = .full) -> ActivityResult {
            ActivityResult(kind: .cuello, target: 15, achieved: 15, durationSeconds: 45, completed: true, level: level,
                           metrics: .neck(rotations: 6, flexions: 5, tilts: 4, maxYaw: yaw, maxPitch: 30, maxRoll: 20, cueMatches: 14, cueMismatches: 1), anomalies: [])
        }
    }

    // MARK: - Agrupación por turno

    @Test func agrupaTresTurnosYEligeActualYAnterior() {
        var f = Fixture()
        for (d, r) in [(14, 4), (15, 5)] { f.checkIn(9, d, score: r); f.session(9, d, rdq: r) }
        for (d, r) in [(28, 3), (29, 3), (30, 2)] { f.checkIn(9, d, score: r); f.session(9, d, rdq: r) }
        for (d, r) in [(12, 2), (13, 2), (14, 1), (15, 2)] { f.checkIn(10, d, score: r); f.session(10, d, rdq: r) }
        f.checkIn(10, 16, score: 3)

        let s = f.summary()
        #expect(s.turnos.map(\.turnoKey) == ["2026-09-14", "2026-09-28", "2026-10-12"])
        #expect(s.currentTurno?.turnoKey == "2026-10-12")
        #expect(s.previousTurno?.turnoKey == "2026-09-28")
        #expect(s.currentTurno?.label == "Turno del 12 oct")
        #expect(s.previousTurno?.label == "Turno del 28 sep")
        #expect(s.currentTurno?.workDays == 7)
        #expect(s.currentTurno?.daysWithPause == 4)
        #expect(s.currentTurno?.countedPauses == 4)
        #expect(s.currentTurno?.maxStreak == 4)
        #expect(s.currentTurno?.meanRDQ == 2.0)
        #expect(s.currentTurno?.maxRDQ == 3)
        #expect(s.previousTurno?.meanRDQ.map { ($0 * 100).rounded() / 100 } == 2.67)
        #expect(s.turnos[0].meanRDQ == 4.5 && s.turnos[0].maxRDQ == 5)
        #expect(s.streak == 4)
        #expect(s.todayRDQ == 3)
        #expect(s.totalCountedPauses == 9)
    }

    @Test func turnoSoloConSesionSospechosaNoEsElAnterior() {
        var f = Fixture()
        f.session(9, 14, post: .mejor)
        f.session(9, 29, post: .mejor, level: .suspicious)
        f.session(10, 12)
        let s = f.summary()
        #expect(s.previousTurno?.turnoKey == "2026-09-14")
        #expect(s.turnos.map(\.turnoKey) == ["2026-09-14", "2026-10-12"])
    }

    @Test func sinDatosEntregaTurnoActualVacio() {
        let f = Fixture()
        let s = f.summary()
        #expect(s.currentTurno?.turnoKey == "2026-10-12")
        #expect(s.currentTurno?.countedPauses == 0 && s.currentTurno?.meanRDQ == nil)
        #expect(s.previousTurno == nil)
        #expect(s.streak == 0 && s.todayRDQ == nil && s.recentSessions.isEmpty)
        #expect(s.currentTurnoDays.count == 7)
        #expect(s.currentTurno?.itemFrequency == [0, 0, 0, 0, 0, 0])
        #expect(s.historyLines.first == "Días seguidos: 0")
    }

    // MARK: - Exclusiones

    @Test func excluyeSimuladasSiempreYSospechosasDeLosAgregados() {
        var f = Fixture()
        f.session(10, 12, post: .mejor, activities: [Fixture.steps(100)])
        f.session(10, 13, post: .mejor, level: .simulated, counted: true, simulated: true, activities: [Fixture.steps(500)])
        f.session(10, 14, post: .mejor, level: .suspicious, activities: [Fixture.steps(300, level: .suspicious)])

        let s = f.summary()
        #expect(s.currentTurno?.verifiedSteps == 100)
        #expect(s.currentTurno?.betterCount == 1)
        #expect(s.currentTurno?.countedPauses == 1 && s.currentTurno?.daysWithPause == 1)
        #expect(s.totalCountedPauses == 1)
        #expect(s.recentSessions.count == 2)
        #expect(s.recentSessions.map(\.level) == [.suspicious, .full])
        #expect(!s.recentSessions.contains { $0.level == .simulated })
        #expect(!s.historyLines.contains { $0.contains("sin verificar") })
    }

    // MARK: - RDQ

    @Test func rdqDelDiaEsElUltimoCheckInDePausa() {
        var f = Fixture()
        f.checkIn(10, 12, hour: 8, score: 4, answers: [true, true, true, true, false, false])
        f.checkIn(10, 12, hour: 13, score: 2, answers: [true, true, false, false, false, false])
        f.pain(10, 12, context: .alBajar)
        f.checkIn(10, 13, hour: 9, score: 3, answers: [true, false, true, false, true, false])

        let s = f.summary()
        #expect(s.currentTurno?.meanRDQ == 2.5)
        #expect(s.currentTurno?.maxRDQ == 3)
        #expect(s.currentTurno?.itemFrequency == [2, 1, 1, 0, 1, 0])
        #expect(s.currentTurnoDays[0].rdq == 2)
        #expect(s.currentTurnoDays[1].rdq == 3)
        #expect(s.currentTurnoDays[2].rdq == nil)
    }

    // MARK: - Racha

    @Test func rachaCuentaDiasDeSubidaConCascoYDescanso() {
        var f = Fixture()
        f.ledger(10, 12); f.ledger(10, 13); f.ledger(10, 14, counted: 0, casco: true); f.ledger(10, 15)
        #expect(f.summary(now: f.date(10, 16)).streak == 3)
        #expect(f.summary(now: f.date(10, 15, hour: 20)).streak == 3)

        // Días 6 y 7 también con pausa: en la bajada la racha queda a salvo.
        f.ledger(10, 17); f.ledger(10, 18)
        let bajada = f.summary(now: f.date(10, 20))
        #expect(bajada.streak == 2)
        #expect(bajada.currentTurno?.maxStreak == 3)
        #expect(bajada.currentTurno?.daysWithPause == 5)
        #expect(bajada.currentTurnoDays.map(\.cascoUsed) == [false, false, true, false, false, false, false])
        #expect(!bajada.currentTurnoDays.contains { $0.isToday })

        // Día de turno sin pausa ni casco corta la racha.
        f.ledger(10, 16, counted: 0)
        #expect(f.summary(now: f.date(10, 17, hour: 8)).streak == 1)
    }

    @Test func turnoDeNocheAgrupaColacionYCampamentoEnElMismoDia() {
        var f = Fixture(shift: .night)
        f.session(10, 12, hour: 20, moment: .entrada)
        f.session(10, 14, hour: 1, moment: .colacion)
        f.session(10, 14, hour: 9, moment: .campamento)
        f.checkIn(10, 14, hour: 1, score: 3)

        let s = f.summary(now: f.date(10, 14, hour: 10))
        #expect(s.currentTurnoDays.map(\.workDayKey).prefix(2) == ["2026-10-12", "2026-10-13"])
        #expect(s.currentTurnoDays[1].countedPauses == 2)
        #expect(s.currentTurnoDays[1].isToday)
        #expect(s.currentTurnoDays[1].rdq == 3)
        #expect(s.currentTurno?.daysWithPause == 2)
        #expect(s.currentTurno?.countedPauses == 3)
        #expect(s.streak == 2)
        #expect(s.todayRDQ == 3)
        #expect(s.recentSessions.first?.workDayKey == "2026-10-13")
    }

    // MARK: - Métricas verificadas

    @Test func sumaSoloMetricasDeActividadesFull() {
        var f = Fixture()
        f.session(10, 12, activities: [Fixture.steps(120), Fixture.reps(10), Fixture.stroop(rt: 600), Fixture.eyes(bpm: 10), Fixture.neck(yaw: 40)])
        f.session(10, 13, activities: [Fixture.steps(80, level: .reduced), Fixture.reps(5, skipped: true), Fixture.stroop(rt: 800), Fixture.eyes(bpm: 14), Fixture.neck(yaw: 55)])
        f.session(10, 14, activities: [Fixture.steps(30), Fixture.stroop(rt: 700)])

        let t = f.summary().currentTurno
        #expect(t?.verifiedSteps == 150)
        #expect(t?.verifiedReps == 10)
        #expect(t?.stroopMedianRTms == 700)
        #expect(t?.blinksPerMinute == 12)
        #expect(t?.neckMaxYaw == 55)
    }

    @Test func medianaDeStroopConCantidadPar() {
        var f = Fixture()
        f.session(10, 12, activities: [Fixture.stroop(rt: 600)])
        f.session(10, 13, activities: [Fixture.stroop(rt: 900)])
        #expect(f.summary().currentTurno?.stroopMedianRTms == 750)
    }

    // MARK: - Pistas de empeoramiento

    @Test func calculaLasCuatroPistas() {
        var f = Fixture()
        // T0: RDQ 1,1,1,2,4,5,5 con pausa los días 1-3.
        let t0: [(Int, Int, PostResponse?)] = [(14, 1, .mejor), (15, 1, .mejor), (16, 1, .igual), (17, 2, nil), (18, 4, nil), (19, 5, nil), (20, 5, nil)]
        for (d, r, p) in t0 { f.checkIn(9, d, score: r); if let p { f.session(9, d, rdq: r, post: p) } }
        // T1: RDQ 2,1,2,2,4,4,5 con pausa los días 1-4.
        let t1: [(Int, Int, Int, PostResponse?)] = [(9, 28, 2, .mejor), (9, 29, 1, .mejor), (9, 30, 2, .mejor), (10, 1, 2, .peor), (10, 2, 4, nil), (10, 3, 4, nil), (10, 4, 5, nil)]
        for (m, d, r, p) in t1 { f.checkIn(m, d, score: r); if let p { f.session(m, d, rdq: r, post: p) } }
        // "Me duele ahora": 2 de 4 al bajar.
        f.pain(10, 12, context: .alBajar); f.pain(10, 13, context: .enCabina); f.pain(10, 14, context: .alBajar); f.pain(10, 15, context: .enCasa)

        let s = f.summary()
        #expect(s.worsensHints == [
            "Le duele más al bajar del camión",
            "El dolor sube los días 5 a 7 del turno",
            "Sin pausa, el RDQ del día siguiente sube",
            "Mejora en 5 de 7 pausas",
        ])
        #expect(s.worsensHints.count <= 4)
        #expect(s.historyLines.count <= 10)
    }

    @Test func sinSuficientesDatosNoInventaPistas() {
        var f = Fixture()
        f.pain(10, 12, context: .alBajar)
        f.session(10, 12, post: .mejor)
        f.session(10, 13, post: .mejor)
        let s = f.summary()
        #expect(s.worsensHints.isEmpty)
    }

    @Test func pistaDeDiasInicialesYDePeor() {
        var f = Fixture()
        // Días 1-2 altos, resto bajo, en dos turnos.
        for (d, r) in [(14, 5), (15, 5), (16, 1), (17, 1), (18, 1), (19, 2), (20, 1)] { f.checkIn(9, d, score: r) }
        for (m, d, r) in [(9, 28, 5), (9, 29, 4), (9, 30, 2), (10, 1, 1), (10, 2, 1), (10, 3, 1), (10, 4, 1)] { f.checkIn(m, d, score: r) }
        f.session(10, 12, post: .peor); f.session(10, 13, post: .igual); f.session(10, 14, post: .peor); f.session(10, 15, post: .igual)
        let s = f.summary()
        #expect(s.worsensHints.contains("El dolor es mayor los días 1 y 2 del turno"))
        #expect(s.worsensHints.contains("Peor después de 2 de 4 pausas"))
    }

    // MARK: - Historial para el coach

    @Test func historialParaElCoach() {
        var f = Fixture()
        f.checkIn(10, 14, score: 4); f.session(10, 14, moment: .campamento, rdq: 4, post: .igual, level: .reduced, activities: [Fixture.steps(50, level: .reduced)])
        f.checkIn(10, 15, score: 3); f.session(10, 15, moment: .colacion, rdq: 3, post: .mejor, activities: [Fixture.neck(yaw: 50), Fixture.steps(100)])
        f.session(10, 13, moment: .entrada, rdq: 2, post: .mejor, activities: [Fixture.neck(yaw: 45)])

        let s = f.summary()
        #expect(s.historyLines.count <= 10)
        #expect(s.historyLines[0] == "Días seguidos: 1")
        #expect(s.historyLines.contains("Este turno: 2 de 5 días con pausa, RDQ promedio 3,5"))
        #expect(s.historyLines.contains("Ayer colación: RDQ 3, pausa verificada, después mejor"))
        #expect(s.historyLines.contains("Hace 2 días campamento: RDQ 4, pausa contada, después igual"))
        #expect(s.historyLines.contains("Hace 3 días entrada: RDQ 2, pausa verificada, después mejor"))
        #expect(s.historyLines.contains("Ejercicio que más ayudó: cuello"))
    }

    @Test func historialNuncaPasaDeDiezLineas() {
        var f = Fixture()
        for d in 14...20 { f.checkIn(9, d, score: d - 13); f.session(9, d, rdq: d - 13, post: d < 18 ? .mejor : .peor, activities: [Fixture.steps(60)]) }
        for d in 28...30 { f.checkIn(9, d, score: 2); f.session(9, d, rdq: 2, post: .mejor, activities: [Fixture.reps(8)]) }
        for d in 12...15 { f.checkIn(10, d, score: 1); f.session(10, d, rdq: 1, post: .mejor, activities: [Fixture.reps(8)]) }
        for d in 12...15 { f.pain(10, d, context: .alBajar) }
        let s = f.summary()
        #expect(s.historyLines.count == 10)
        #expect(s.historyLines.filter { $0.contains("RDQ ") && $0.contains("pausa ") }.count == 5)
    }

    // MARK: - Sesiones recientes y días del turno

    @Test func sesionesRecientesOrdenadasYLimitadasAVeinte() {
        var f = Fixture()
        for d in 12...16 { for h in [6, 12, 17, 21, 23] { f.session(10, d, hour: h, moment: .campamento) } }
        let s = f.summary(now: f.date(10, 17))
        #expect(s.recentSessions.count == 20)
        #expect(zip(s.recentSessions, s.recentSessions.dropFirst()).allSatisfy { $0.0.date >= $0.1.date })
        #expect(s.recentSessions.first?.date == f.date(10, 16, hour: 23))
        #expect(s.recentSessions.first?.activityKinds == [.stroop])
        #expect(s.currentTurno?.countedPauses == 25 && s.currentTurno?.daysWithPause == 5)
    }

    @Test func diasDelTurnoActual() {
        let s = Fixture().summary()
        #expect(s.currentTurnoDays.map(\.dayInBlock) == Array(1...7))
        #expect(s.currentTurnoDays.first?.workDayKey == "2026-10-12")
        #expect(s.currentTurnoDays.last?.workDayKey == "2026-10-18")
        #expect(s.currentTurnoDays.map(\.isToday) == [false, false, false, false, true, false, false])
        #expect(StatsFormatting.elapsedDays(in: s.currentTurnoDays) == 5)
    }

    // MARK: - Formato

    @Test func formatoDeTextos() {
        #expect(StatsFormatting.xOfY(4, 7) == "4 de 7")
        #expect(StatsFormatting.percent(0.875) == "88\u{00A0}%")
        #expect(StatsFormatting.percent(7, of: 8) == "88\u{00A0}%")
        #expect(StatsFormatting.percent(0, of: 0) == "—")
        #expect(StatsFormatting.decimal(2.5) == "2,5")
        #expect(StatsFormatting.decimal(nil) == "—")
        #expect(StatsFormatting.rdq(2) == "2 de 6" && StatsFormatting.rdq(nil) == "—")
        #expect(StatsFormatting.turnoLabel(forKey: "2026-10-12") == "Turno del 12 oct")
        #expect(StatsFormatting.turnoLabel(forKey: "2026-10-12", currentTurnoKey: "2026-10-12") == "Este turno")
        #expect(StatsFormatting.shortDate(forKey: "2026-01-03") == "3 ene")
        #expect(StatsFormatting.dayInBlockLabel(2, of: 7) == "Día 2 de 7")
        #expect(StatsFormatting.streakLabel(1) == "1 día seguido" && StatsFormatting.streakLabel(3) == "3 días seguidos")
        #expect(StatsFormatting.pausesLabel(1) == "1 pausa" && StatsFormatting.pausesLabel(8) == "8 pausas")
        #expect(StatsFormatting.activityList([.pasos, .cuello, .ojos]) == "caminata, cuello y ojos")
        #expect(StatsFormatting.activityList([.sentadilla]) == "sentadilla")
        #expect(StatsFormatting.comparisonWithPrevious(4.0) == "vs turno pasado 4")
        #expect(StatsFormatting.comparisonWithPrevious(2.5) == "vs turno pasado 2,5")
        #expect(StatsFormatting.trendLabel(current: 2.0, previous: 4.0) == "baja 2,0")
        #expect(StatsFormatting.trendLabel(current: 3.1, previous: 3.0) == "igual")
        #expect(StatsFormatting.levelPhrase(.suspicious) == "pausa sin verificar")
        #expect(StatsFormatting.postPhrase(nil) == "sin cierre" && StatsFormatting.postPhrase(.peor) == "después peor")
    }

    @Test func etiquetasRelativasDeDia() {
        let c = Fixture().cal.calendar
        #expect(StatsFormatting.relativeDayLabel(workDayKey: "2026-10-16", todayKey: "2026-10-16", calendar: c) == "Hoy")
        #expect(StatsFormatting.relativeDayLabel(workDayKey: "2026-10-15", todayKey: "2026-10-16", calendar: c) == "Ayer")
        #expect(StatsFormatting.relativeDayLabel(workDayKey: "2026-10-13", todayKey: "2026-10-16", calendar: c) == "Hace 3 días")
        #expect(StatsFormatting.relativeDayLabel(workDayKey: "2026-10-01", todayKey: "2026-10-16", calendar: c) == "1 oct")
        #expect(StatsFormatting.relativeDayLabel(workDayKey: "2026-10-17", todayKey: "2026-10-16", calendar: c) == "17 oct")
    }
}
