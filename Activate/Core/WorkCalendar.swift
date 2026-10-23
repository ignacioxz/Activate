import Foundation

/// Calendario laboral puro: convierte fechas en "días laborales" del turno 7×7.
/// El día laboral empieza a `boundaryHour` (04:00 turno de día, 12:00 turno de noche),
/// así la colación de la 01:00 y la pausa del campamento de las 09:00 son el mismo día.
/// Contrato congelado: no cambiar firmas; agregar extensiones en otros archivos si hace falta.
nonisolated struct WorkCalendar: Sendable, Equatable {
    var roster: Roster
    /// Primer día de subida del ciclo (cualquier hora de ese día).
    var rosterStart: Date
    var boundaryHour: Int
    var calendar: Calendar

    init(roster: Roster, rosterStart: Date, boundaryHour: Int, calendar: Calendar = .current) {
        self.roster = roster
        self.rosterStart = rosterStart
        self.boundaryHour = boundaryHour
        self.calendar = calendar
    }

    init(profile: PlayerProfile, calendar: Calendar = .current) {
        self.init(roster: profile.roster, rosterStart: profile.rosterStart,
                  boundaryHour: profile.shiftType.dayBoundaryHour, calendar: calendar)
    }

    var cycleLength: Int { roster.workDays + roster.restDays }

    /// Medianoche (calendario) del día laboral al que pertenece `date`.
    func workDate(for date: Date) -> Date {
        let shifted = calendar.date(byAdding: .hour, value: -boundaryHour, to: date) ?? date
        return calendar.startOfDay(for: shifted)
    }

    /// Clave estable "yyyy-MM-dd" del día laboral.
    func key(for date: Date) -> String {
        Self.key(ofWorkDate: workDate(for: date), calendar: calendar)
    }

    static func key(ofWorkDate workDate: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: workDate)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Fecha (medianoche) de una clave "yyyy-MM-dd".
    func date(forKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func daysFromStart(_ date: Date) -> Int {
        let start = calendar.startOfDay(for: rosterStart)
        return calendar.dateComponents([.day], from: start, to: workDate(for: date)).day ?? 0
    }

    private func cycleIndex(for date: Date) -> Int {
        let d = daysFromStart(date)
        return ((d % cycleLength) + cycleLength) % cycleLength
    }

    func kind(for date: Date) -> DayKind {
        cycleIndex(for: date) < roster.workDays ? .turno : .descanso
    }

    /// Día dentro del bloque actual (turno o descanso), empezando en 1.
    func dayInBlock(for date: Date) -> Int {
        let i = cycleIndex(for: date)
        return i < roster.workDays ? i + 1 : i - roster.workDays + 1
    }

    /// Índice del ciclo 7×7 (0 = el que contiene rosterStart; negativo antes).
    func blockIndex(for date: Date) -> Int {
        let d = daysFromStart(date)
        return Int((Double(d) / Double(cycleLength)).rounded(.down))
    }

    /// Clave del primer día de subida del ciclo al que pertenece `date` (agrupa el historial por turno).
    func turnoKey(for date: Date) -> String {
        let first = calendar.date(byAdding: .day, value: -cycleIndex(for: date), to: workDate(for: date)) ?? workDate(for: date)
        return Self.key(ofWorkDate: first, calendar: calendar)
    }

    /// Mismo instante del día laboral anterior.
    func previousWorkDay(of date: Date) -> Date {
        calendar.date(byAdding: .day, value: -1, to: date) ?? date
    }

    /// Todas las fechas (medianoche laboral) del bloque de turno al que pertenece `date`.
    func workDatesOfTurno(containing date: Date) -> [Date] {
        let first = calendar.date(byAdding: .day, value: -cycleIndex(for: date), to: workDate(for: date)) ?? workDate(for: date)
        return (0..<roster.workDays).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }
}
