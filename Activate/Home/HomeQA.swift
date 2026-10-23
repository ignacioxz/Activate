import Foundation

/// Escenarios de QA para revisar Hoy en el simulador sin pasar por el alta (solo DEBUG; en Release no hace nada).
///
/// Cableado en `ActivateApp.init`, después de `QALaunch.current.prepare(s)` (solo DEBUG).
///
/// Argumentos de lanzamiento (`xcrun simctl launch <UDID> com.ignaciosalazar.activate -qaDemo …`):
/// - `-qaDemo`: siembra la demo "Marco, día 2" (ayer con pausa, hoy sin pausa: va por el Doblete).
/// - `-qaComodinAyer`: demo + hoy es el día 3, el día 1 con pausa y el día 2 cubierto por el comodín.
/// - `-qaPausaHoy`: demo + hoy ya tiene una pausa contada (ruta completa verificada, registrada con las
///   mismas reglas de `GameStore`: XP, Doblete e insignias reales).
/// - `-qaSinConsentimiento`: demo + sin consentimiento ("Hacer la pausa" abre el consentimiento).
/// Cualquiera de los últimos tres implica `-qaDemo`. Conserva el Modo exterior de `-qa-outdoor`.
enum HomeQA {
    static let demo = "-qaDemo"
    static let comodinAyer = "-qaComodinAyer"
    static let pausaHoy = "-qaPausaHoy"
    static let sinConsentimiento = "-qaSinConsentimiento"

    /// Aplica los escenarios pedidos. Devuelve `true` si sembró algo.
    @discardableResult
    static func apply(arguments: [String], to store: AppStore, now: Date = .now) -> Bool {
        #if DEBUG
        let wanted = Set(arguments)
        let scenarios = [comodinAyer, pausaHoy, sinConsentimiento]
        guard wanted.contains(demo) || scenarios.contains(where: wanted.contains) else { return false }
        var seeded = data(arguments: wanted, now: now)
        seeded.profile.outdoorMode = store.data.profile.outdoorMode
        store.replace(with: seeded)
        return true
        #else
        return false
        #endif
    }

    /// Datos del escenario (puro; testeable).
    static func data(arguments: Set<String>, now: Date, calendar: Calendar = .current) -> SaveData {
        var data = DemoSeed.data(now: now, calendar: calendar)
        if arguments.contains(comodinAyer) {
            applyComodinAyer(to: &data, now: now, calendar: calendar)
        }
        if arguments.contains(pausaHoy) {
            data = withPauseToday(data, now: now, calendar: calendar)
        }
        if arguments.contains(sinConsentimiento) {
            data.profile.consentGiven = false
        }
        return data
    }

    /// Hoy con una pausa de ruta completa verificada (check-in RDQ 2 de 6, cierre "Igual"), registrada con
    /// `GameStore.recording`: suma el XP real, marca el día y entrega las insignias que correspondan.
    static func withPauseToday(_ input: SaveData, now: Date, calendar: Calendar) -> SaveData {
        var data = input
        let wc = WorkCalendar(profile: data.profile, calendar: calendar)
        let dayStart = StreakEngine.instant(ofWorkDate: wc.workDate(for: now), calendar: wc)
        let startedAt = max(dayStart, now.addingTimeInterval(-25 * 60))
        let answers = [false, false, true, false, true, false]
        var checkIn = DailyCheckIn(date: startedAt, workDayKey: wc.key(for: now), turnoKey: wc.turnoKey(for: now),
                                   source: .pausa, answers: answers, zone: .lumbar, moment: nil, context: nil)
        checkIn.setZones([.lumbar])
        checkIn.moment = Moment.infer(date: startedAt, shift: data.profile.shiftType, calendar: calendar)
        data.checkIns.append(checkIn)

        let activities = Recipes.base(.campamento5, demo: data.demo.shortTargets).activities.map { item in
            let metrics: ActivityMetrics = item.kind == .pasos
                ? .steps(count: item.target, meanCadence: 1.6, walkingFraction: 0.9, rmsPeak: nil)
                : .reps(count: item.target, minDescentRatio: nil, meanRepSeconds: nil)
            return ActivityResult(kind: item.kind, target: item.target, achieved: item.target, durationSeconds: 40,
                                  completed: true, level: .full, metrics: metrics, anomalies: [])
        }
        var session = PauseSession(workDayKey: wc.key(for: now), turnoKey: wc.turnoKey(for: now),
                                   recipe: .campamento5, moment: checkIn.moment ?? .colacion,
                                   startedAt: startedAt, endedAt: startedAt.addingTimeInterval(7 * 60),
                                   checkInScore: checkIn.score, checkInAnswers: answers)
        session.setZones([.lumbar])
        session.postResponse = .igual
        session.activities = activities
        session.counted = true
        session.level = .full
        return GameStore.recording(session, in: data, calendar: wc).data
    }

    /// Hoy pasa a ser el día 3: día 1 con pausa, día 2 sin pausa y cubierto por el comodín, hoy pendiente.
    private static func applyComodinAyer(to data: inout SaveData, now: Date, calendar: Calendar) {
        var wc = WorkCalendar(profile: data.profile, calendar: calendar)
        let today = wc.workDate(for: now)
        guard let start = calendar.date(byAdding: .day, value: -2, to: today) else { return }
        data.profile.rosterStart = start
        wc = WorkCalendar(profile: data.profile, calendar: calendar)
        let turno = wc.workDatesOfTurno(containing: now)
        for (index, workDate) in turno.enumerated() {
            let key = StreakEngine.key(ofWorkDate: workDate, calendar: wc)
            var day = StreakEngine.workDay(ofWorkDate: workDate, in: [:], calendar: wc)
            switch index {
            case 0: day.countedPauses = 1
            case 1: day.cascoUsed = true
            default: break
            }
            if index <= 2 { data.workDays[key] = day } else { data.workDays[key] = nil }
        }
        data.profile.cascos = 0
    }
}
