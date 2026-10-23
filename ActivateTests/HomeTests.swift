import Testing
import Foundation
@testable import Activate

/// Lógica pura del paquete Home: avisos diarios, tira del turno, tarjeta del momento y registro de dolor.
struct HomeTests {
    private static let santiago: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago")!
        return c
    }()

    /// Turno 7×7 que sube el 12-10-2026.
    private func profile(shift: ShiftType = .day, optIn: Bool = true) -> PlayerProfile {
        var p = PlayerProfile(rosterStart: Self.santiago.date(from: DateComponents(year: 2026, month: 10, day: 12))!)
        p.shiftType = shift
        p.notificationsOptIn = optIn
        return p
    }

    private func calendar(_ p: PlayerProfile) -> WorkCalendar {
        WorkCalendar(profile: p, calendar: Self.santiago)
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        Self.santiago.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func data(_ p: PlayerProfile, muted: Bool = false) -> SaveData {
        var d = SaveData(profile: p)
        d.demo.notificationsMuted = muted
        return d
    }

    // MARK: - DailyNotice

    @Test func avisoTurnoDiaEsALas2030DelMismoDia() {
        let fire = DailyNotice.fireDate(forWorkDate: date(13, 0), shift: .day, calendar: Self.santiago)
        #expect(fire == date(13, 20, 30))
    }

    @Test func avisoTurnoNocheEsALas0830DelDiaSiguiente() {
        let fire = DailyNotice.fireDate(forWorkDate: date(13, 0), shift: .night, calendar: Self.santiago)
        #expect(fire == date(14, 8, 30))
    }

    @Test func sinOptInNoHayAvisos() {
        let p = profile(optIn: false)
        let notices = DailyNotice.plan(profile: p, data: data(p), now: date(13, 10), calendar: calendar(p))
        #expect(notices.isEmpty)
    }

    @Test func demoSilenciadaNoHayAvisos() {
        let p = profile()
        let notices = DailyNotice.plan(profile: p, data: data(p, muted: true), now: date(13, 10), calendar: calendar(p))
        #expect(notices.isEmpty)
    }

    @Test func unAvisoPorDiaLaboralSoloEnTurno() {
        let p = profile()
        // Día 2 del turno a las 10:00: quedan hoy (día 2) y los días 3-7; la bajada no recibe avisos.
        let notices = DailyNotice.plan(profile: p, data: data(p), now: date(13, 10), calendar: calendar(p))
        #expect(notices.count == 6)
        #expect(Set(notices.map(\.workDayKey)).count == notices.count)
        #expect(notices.first?.dayInBlock == 2)
        #expect(notices.first?.fireDate == date(13, 20, 30))
        #expect(notices.first?.body == "Día 2 está a 5 minutos.")
        #expect(notices.first?.title == "Le queda el campamento.")
        #expect(notices.first?.id == "daily-notice-2026-10-13")
        #expect(notices.allSatisfy { $0.dayInBlock >= 2 && $0.dayInBlock <= 7 })
    }

    @Test func hoyConPausaContadaNoAvisa() {
        let p = profile()
        var d = data(p)
        d.workDays["2026-10-13"] = WorkDay(key: "2026-10-13", kind: .turno, dayInBlock: 2, turnoKey: "2026-10-12", countedPauses: 1)
        let notices = DailyNotice.plan(profile: p, data: d, now: date(13, 10), calendar: calendar(p))
        #expect(!notices.contains { $0.workDayKey == "2026-10-13" })
        #expect(notices.first?.dayInBlock == 3)
    }

    @Test func pasadaLaVentanaNoAvisaHoy() {
        let p = profile()
        let notices = DailyNotice.plan(profile: p, data: data(p), now: date(13, 21), calendar: calendar(p))
        #expect(!notices.contains { $0.workDayKey == "2026-10-13" })
        #expect(notices.first?.workDayKey == "2026-10-14")
    }

    @Test func turnoNocheUsaLaClaveDelDiaLaboral() {
        let p = profile(shift: .night)
        // 01:00 del 14-10 pertenece al día laboral 13-10 (día 2); el aviso cae a las 08:30 del 14-10.
        let notices = DailyNotice.plan(profile: p, data: data(p), now: date(14, 1), calendar: calendar(p))
        #expect(notices.first?.workDayKey == "2026-10-13")
        #expect(notices.first?.dayInBlock == 2)
        #expect(notices.first?.fireDate == date(14, 8, 30))
    }

    @Test func enBajadaDejaProgramadoElProximoTurno() {
        let p = profile()
        // 24-10 es día 6 de bajada: en los 7 días siguientes (24 al 30) caben los días 1-5 del turno siguiente (26 al 30).
        let notices = DailyNotice.plan(profile: p, data: data(p), now: date(24, 10), calendar: calendar(p))
        #expect(notices.map(\.dayInBlock) == [1, 2, 3, 4, 5])
        #expect(notices.first?.workDayKey == "2026-10-26")
        #expect(notices.last?.workDayKey == "2026-10-30")
    }

    // MARK: - ShiftStrip

    @Test func casillasDelTurno() {
        let p = profile()
        var d = data(p)
        d.workDays["2026-10-12"] = WorkDay(key: "2026-10-12", kind: .turno, dayInBlock: 1, turnoKey: "2026-10-12", countedPauses: 1)
        d.workDays["2026-10-13"] = WorkDay(key: "2026-10-13", kind: .turno, dayInBlock: 2, turnoKey: "2026-10-12", cascoUsed: true)
        let boxes = ShiftStrip.boxes(data: d, calendar: calendar(p), now: date(15, 10))
        #expect(boxes.count == 7)
        #expect(boxes.map(\.fill) == [.pausa, .casco, .vacio, .vacio, .futuro, .futuro, .futuro])
        #expect(boxes.map(\.isToday) == [false, false, false, true, false, false, false])
        #expect(boxes[3].day == 4)
    }

    @Test func enBajadaMuestraElTurnoTerminado() {
        let p = profile()
        let boxes = ShiftStrip.boxes(data: data(p), calendar: calendar(p), now: date(20, 10))
        #expect(boxes.count == 7)
        #expect(boxes.first?.workDayKey == "2026-10-12")
        #expect(!boxes.contains { $0.isToday })
        #expect(boxes.allSatisfy { $0.fill == .vacio })
    }

    @Test func titularesDeLaTira() {
        #expect(ShiftStrip.headline(kind: .descanso, dayInBlock: 3, workDays: 7, pausedToday: false, allPaused: false) == "Bajada: racha a salvo")
        #expect(ShiftStrip.headline(kind: .turno, dayInBlock: 1, workDays: 7, pausedToday: true, allPaused: false) == "Turno · día 1 de 7 · Mañana: día 2, Doblete")
        #expect(ShiftStrip.headline(kind: .turno, dayInBlock: 2, workDays: 7, pausedToday: false, allPaused: false) == "Turno · día 2 de 7 · Vamos por el Doblete")
        #expect(ShiftStrip.headline(kind: .turno, dayInBlock: 2, workDays: 7, pausedToday: true, allPaused: false) == "Turno · día 2 de 7 · Día 2 cumplido")
        #expect(ShiftStrip.headline(kind: .turno, dayInBlock: 7, workDays: 7, pausedToday: false, allPaused: false) == "Turno · día 7 de 7 · Vamos por el Tiro limpio")
        #expect(ShiftStrip.headline(kind: .turno, dayInBlock: 7, workDays: 7, pausedToday: true, allPaused: true) == "Turno · día 7 de 7 · Tiro limpio")
    }

    @Test func notaDelCascoDeAyer() {
        let p = profile()
        var d = data(p)
        d.workDays["2026-10-13"] = WorkDay(key: "2026-10-13", kind: .turno, dayInBlock: 2, turnoKey: "2026-10-12", cascoUsed: true)
        #expect(ShiftStrip.note(data: d, calendar: calendar(p), now: date(14, 10)) == "Ayer usó el casco. Racha a salvo.")
        #expect(ShiftStrip.note(data: d, calendar: calendar(p), now: date(15, 10)) == nil)
    }

    // MARK: - MomentCard

    @Test func lineaDeLoQueIncluye() {
        let recipe = Recipe(kind: .relevo60, activities: [
            ActivityAssignment(kind: .cuello, target: 15),
            ActivityAssignment(kind: .ojos, target: 15),
        ])
        #expect(MomentCard.includesLine(for: recipe) == "Incluye: Cuello · Ojos")
    }

    // MARK: - PainNowSheet

    @Test func registroMeDueleAhora() {
        let p = profile(shift: .night)
        let now = date(14, 1)
        let entry = PainNowSheet.entry(now: now, profile: p, zone: .cuello, context: .alBajar, calendar: calendar(p))
        #expect(entry.source == .meDueleAhora)
        #expect(entry.answers.isEmpty)
        #expect(entry.score == 0)
        #expect(entry.workDayKey == "2026-10-13")
        #expect(entry.turnoKey == "2026-10-12")
        #expect(entry.zone == .cuello)
        #expect(entry.context == .alBajar)
        #expect(entry.moment == .colacion)
    }
}
