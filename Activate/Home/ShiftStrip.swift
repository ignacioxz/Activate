import Foundation

/// Lógica pura de la tira del turno: una casilla por día laboral del bloque (7 en el 7×7).
/// Con pausa contada = pausa · comodín usado (`casco` en los datos) = escudo · hoy · futuro.
/// La dibuja el "Camino del turno" de Hoy (`TurnoPathCard`, con `HoyProgress.path`); aquí quedan
/// las casillas, el titular para VoiceOver y la nota del comodín de ayer.
nonisolated enum ShiftStrip {
    /// Estado visual de una casilla (lógica pura, testeable).
    nonisolated enum Fill: Sendable, Hashable { case pausa, casco, vacio, futuro }

    nonisolated struct DayBox: Sendable, Hashable, Identifiable {
        var day: Int
        var workDayKey: String
        var fill: Fill
        var isToday: Bool
        var id: String { workDayKey }
    }

    /// Casillas del bloque de turno al que pertenece `now` (en bajada: el turno recién terminado).
    static func boxes(data: SaveData, calendar: WorkCalendar, now: Date) -> [DayBox] {
        let today = calendar.workDate(for: now)
        let todayKey = WorkCalendar.key(ofWorkDate: today, calendar: calendar.calendar)
        return calendar.workDatesOfTurno(containing: now).enumerated().map { index, workDate in
            let key = WorkCalendar.key(ofWorkDate: workDate, calendar: calendar.calendar)
            let record = data.workDays[key]
            let fill: Fill
            if (record?.countedPauses ?? 0) > 0 {
                fill = .pausa
            } else if record?.cascoUsed == true {
                fill = .casco
            } else if workDate > today {
                fill = .futuro
            } else {
                fill = .vacio
            }
            return DayBox(day: index + 1, workDayKey: key, fill: fill, isToday: key == todayKey)
        }
    }

    /// "Turno · día N de 7 · Vamos por el Doblete" y variantes del día 1, del último día y de la bajada.
    /// Solo promete un hito que todavía se puede lograr hoy: el Doblete si ayer hubo pausa
    /// (`dobleteAvailable`) y el Tiro limpio si todos los días anteriores del turno la tuvieron.
    static func headline(kind: DayKind, dayInBlock: Int, workDays: Int, pausedToday: Bool, allPaused: Bool,
                                     dobleteAvailable: Bool, tiroLimpioAvailable: Bool) -> String {
        guard kind == .turno else { return "Bajada: racha a salvo" }
        let prefix = "Turno · día \(dayInBlock) de \(workDays)"
        if dayInBlock <= 1 {
            return "\(prefix) · Mañana: día 2, Doblete"
        }
        if dayInBlock >= workDays {
            if allPaused { return "\(prefix) · Tiro limpio" }
            if tiroLimpioAvailable { return "\(prefix) · Vamos por el Tiro limpio" }
        }
        if pausedToday { return "\(prefix) · Día \(dayInBlock) cumplido" }
        if dobleteAvailable { return "\(prefix) · Vamos por el Doblete" }
        return prefix
    }

    /// Hoy sin pausa todavía y todos los días anteriores del turno con pausa contada.
    static func tiroLimpioAvailable(boxes: [DayBox]) -> Bool {
        guard let todayIndex = boxes.firstIndex(where: \.isToday), boxes[todayIndex].fill != .pausa else { return false }
        return boxes[..<todayIndex].allSatisfy { $0.fill == .pausa }
    }

    /// Nota corta bajo la tira: comodín automático de ayer.
    static func note(data: SaveData, calendar: WorkCalendar, now: Date) -> String? {
        guard calendar.kind(for: now) == .turno else { return nil }
        let yesterdayKey = calendar.key(for: calendar.previousWorkDay(of: now))
        if data.workDays[yesterdayKey]?.cascoUsed == true {
            return CelebrationCopy.comodinUsedYesterdayLine
        }
        return nil
    }

    static func spoken(_ box: DayBox) -> String {
        let state: String
        switch box.fill {
        case .pausa: state = "pausa cumplida"
        case .casco: state = "comodín usado, racha a salvo"
        case .vacio: state = box.isToday ? "hoy, aún sin pausa" : "sin pausa"
        case .futuro: state = "pendiente"
        }
        return box.isToday && box.fill != .vacio ? "Día \(box.day), hoy: \(state)" : "Día \(box.day): \(state)"
    }
}
