import Foundation

/// Escenarios de QA para revisar Hoy en el simulador sin pasar por el alta (solo DEBUG; en Release no hace nada).
///
/// Cableado (una línea en `ActivateApp.init`, justo después de `let s = AppStore()`):
///
///     HomeQA.apply(arguments: ProcessInfo.processInfo.arguments, to: s)
///
/// Argumentos de lanzamiento (`xcrun simctl launch <UDID> com.ignaciosalazar.activate -qaDemo …`):
/// - `-qaDemo`: siembra la demo "Marco, día 2" (ayer con pausa, hoy sin pausa: va por el Doblete).
/// - `-qaComodinAyer`: demo + hoy es el día 3, el día 1 con pausa y el día 2 cubierto por el comodín.
/// - `-qaPausaHoy`: demo + hoy ya tiene una pausa contada.
/// - `-qaSinConsentimiento`: demo + sin consentimiento ("Hacer la pausa" abre el consentimiento).
/// Cualquiera de los últimos tres implica `-qaDemo`.
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
        store.replace(with: data(arguments: wanted, now: now))
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
            let wc = WorkCalendar(profile: data.profile, calendar: calendar)
            let key = wc.key(for: now)
            var today = StreakEngine.workDay(ofWorkDate: wc.workDate(for: now), in: data.workDays, calendar: wc)
            today.countedPauses = max(1, today.countedPauses)
            data.workDays[key] = today
        }
        if arguments.contains(sinConsentimiento) {
            data.profile.consentGiven = false
        }
        return data
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
