import Testing
import Foundation
@testable import Activate

struct WorkCalendarTests {
    private func cal(shift: ShiftType = .day) -> WorkCalendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago")!
        let start = c.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        return WorkCalendar(roster: .sieteXSiete, rosterStart: start, boundaryHour: shift.dayBoundaryHour, calendar: c)
    }

    @Test func turnoDeNocheNoRompeElDiaLaboral() {
        let c = cal(shift: .night)
        let colacion = c.calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 1))!
        let campamento = c.calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
        #expect(c.key(for: colacion) == c.key(for: campamento))
        #expect(c.key(for: colacion) == "2026-10-13")
    }

    @Test func cicloSieteXSiete() {
        let c = cal()
        let d1 = c.calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 8))!
        let d8 = c.calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8))!
        let d15 = c.calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8))!
        #expect(c.kind(for: d1) == .turno && c.dayInBlock(for: d1) == 1)
        #expect(c.kind(for: d8) == .descanso && c.dayInBlock(for: d8) == 1)
        #expect(c.kind(for: d15) == .turno && c.turnoKey(for: d15) == "2026-10-26")
        #expect(c.turnoKey(for: d1) == "2026-10-12")
    }
}
