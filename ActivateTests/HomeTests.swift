import Testing
import Foundation
@testable import Activate

/// Lógica pura del paquete Home: avisos diarios, tira del turno, tarjeta del momento, comodín,
/// consentimiento antes de la pausa y escenarios de QA.
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

    /// Por defecto, igual que una instalación nueva: demo apagada y `notificationsMuted` en su valor por defecto (`true`).
    private func data(_ p: PlayerProfile, demo: Bool = false, muted: Bool = DemoConfig().notificationsMuted) -> SaveData {
        var d = SaveData(profile: p)
        d.demo.enabled = demo
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
        let notices = DailyNotice.plan(profile: p, data: data(p, demo: true, muted: true), now: date(13, 10), calendar: calendar(p))
        #expect(notices.isEmpty)
    }

    @Test func sinDemoElSilencioPorDefectoNoBloqueaElAviso() {
        let p = profile()
        // `DemoConfig.notificationsMuted` vale `true` por defecto: sin demo activa no debe silenciar nada.
        #expect(DemoConfig().notificationsMuted)
        #expect(!DailyNotice.isMutedByDemo(DemoConfig()))
        let notices = DailyNotice.plan(profile: p, data: data(p, demo: false, muted: true), now: date(13, 10), calendar: calendar(p))
        #expect(!notices.isEmpty)
        // Demo activa pero sin silencio: avisa.
        let conDemo = DailyNotice.plan(profile: p, data: data(p, demo: true, muted: false), now: date(13, 10), calendar: calendar(p))
        #expect(!conDemo.isEmpty)
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

    private func headline(kind: DayKind = .turno, day: Int, paused: Bool = false, allPaused: Bool = false,
                          doblete: Bool = false, tiro: Bool = false) -> String {
        ShiftStrip.headline(kind: kind, dayInBlock: day, workDays: 7, pausedToday: paused, allPaused: allPaused,
                            dobleteAvailable: doblete, tiroLimpioAvailable: tiro)
    }

    @Test func titularesDeLaTira() {
        #expect(headline(kind: .descanso, day: 3) == "Bajada: racha a salvo")
        #expect(headline(day: 1, paused: true) == "Turno · día 1 de 7 · Mañana: día 2, Doblete")
        #expect(headline(day: 2, doblete: true) == "Turno · día 2 de 7 · Vamos por el Doblete")
        #expect(headline(day: 2, paused: true) == "Turno · día 2 de 7 · Día 2 cumplido")
        #expect(headline(day: 7, doblete: true, tiro: true) == "Turno · día 7 de 7 · Vamos por el Tiro limpio")
        #expect(headline(day: 7, paused: true, allPaused: true) == "Turno · día 7 de 7 · Tiro limpio")
    }

    @Test func sinPausaAyerNoPrometeElDoblete() {
        // Ayer sin pausa: el Doblete ya no se puede lograr hoy, no se anuncia.
        #expect(headline(day: 3, doblete: false) == "Turno · día 3 de 7")
        #expect(!headline(day: 3, doblete: false).contains("Doblete"))
        // Último día con un día sin pausa antes: no hay Tiro limpio posible; si ayer hubo pausa, va por el Doblete.
        #expect(headline(day: 7, doblete: true, tiro: false) == "Turno · día 7 de 7 · Vamos por el Doblete")
        #expect(headline(day: 7, paused: true, allPaused: false) == "Turno · día 7 de 7 · Día 7 cumplido")
    }

    @Test func tiroLimpioDisponibleSegunLasCasillas() {
        let p = profile()
        var d = data(p)
        for day in 12...17 {
            let key = "2026-10-\(day)"
            d.workDays[key] = WorkDay(key: key, kind: .turno, dayInBlock: day - 11, turnoKey: "2026-10-12", countedPauses: 1)
        }
        let dia7 = ShiftStrip.boxes(data: d, calendar: calendar(p), now: date(18, 10))
        #expect(ShiftStrip.tiroLimpioAvailable(boxes: dia7))
        // Con el día 3 cubierto por el comodín (sin pausa) ya no hay Tiro limpio posible.
        d.workDays["2026-10-14"]?.countedPauses = 0
        d.workDays["2026-10-14"]?.cascoUsed = true
        let conComodin = ShiftStrip.boxes(data: d, calendar: calendar(p), now: date(18, 10))
        #expect(!ShiftStrip.tiroLimpioAvailable(boxes: conComodin))
    }

    @Test func notaDelComodinDeAyer() {
        let p = profile()
        var d = data(p)
        d.workDays["2026-10-13"] = WorkDay(key: "2026-10-13", kind: .turno, dayInBlock: 2, turnoKey: "2026-10-12", cascoUsed: true)
        #expect(ShiftStrip.note(data: d, calendar: calendar(p), now: date(14, 10)) == "Ayer se usó su comodín: racha a salvo.")
        #expect(ShiftStrip.note(data: d, calendar: calendar(p), now: date(15, 10)) == nil)
        let box = ShiftStrip.DayBox(day: 2, workDayKey: "2026-10-13", fill: .casco, isToday: false)
        #expect(ShiftStrip.spoken(box) == "Día 2: comodín usado, racha a salvo")
    }

    @Test func elComodinNoSeLlamaCascoEnPantalla() {
        let visibles = [
            CelebrationCopy.comodinName,
            CelebrationCopy.comodinExplanation,
            CelebrationCopy.comodinUsedYesterdayLine,
            CelebrationCopy.comodinStatus(available: 1),
            CelebrationCopy.comodinStatus(available: 0),
            ShiftStrip.spoken(ShiftStrip.DayBox(day: 2, workDayKey: "k", fill: .casco, isToday: false)),
        ]
        for text in visibles {
            #expect(!text.lowercased().contains("casco"), "Texto visible con \"casco\": \(text)")
            #expect(!CelebrationCopy.containsBannedFragment(text), "Texto prohibido: \(text)")
        }
        #expect(CelebrationCopy.comodinExplanation
                == "Si un día de turno no alcanza a hacer la pausa, el comodín cuida su racha. Tiene 1 por turno y se usa solo.")
    }

    // MARK: - MomentCard

    @Test func lineaDeLoQueIncluye() {
        let recipe = Recipe(kind: .campamento5, activities: [
            ActivityAssignment(kind: .cuello, target: 15),
            ActivityAssignment(kind: .ojos, target: 15),
        ])
        #expect(MomentCard.includesLine(for: recipe) == "Incluye: Cervical · Pestañeo")
        #expect(MomentCard.shortName(.cuello) == "Cervical")
        #expect(MomentCard.shortName(.ojos) == "Pestañeo")
        #expect(MomentCard.shortName(.pararseSentarse) == "Pararse")
        // Campamento en el orden fijo de la sesión.
        #expect(MomentCard.includesLine(for: Recipes.base(.campamento5, demo: false))
                == "Incluye: Pasos · Pararse · Sentadillas · Cervical · Reflejos · Pestañeo · Espalda")
    }

    // MARK: - Consentimiento antes de la pausa

    @Test func sinConsentimientoLaPausaPideConsentimiento() {
        var p = profile()
        p.consentGiven = false
        #expect(HomeView.needsConsent(p))
        p.consentGiven = true
        #expect(!HomeView.needsConsent(p))
    }

    // MARK: - Escenarios de QA

    @Test @MainActor func escenariosDeQA() {
        let now = date(14, 10)
        let demo = HomeQA.data(arguments: [HomeQA.demo], now: now, calendar: Self.santiago)
        #expect(demo.profile.onboardingDone)
        #expect(demo.profile.consentGiven)

        let comodin = HomeQA.data(arguments: [HomeQA.comodinAyer], now: now, calendar: Self.santiago)
        let wc = WorkCalendar(profile: comodin.profile, calendar: Self.santiago)
        #expect(wc.dayInBlock(for: now) == 3)
        #expect(ShiftStrip.note(data: comodin, calendar: wc, now: now) == CelebrationCopy.comodinUsedYesterdayLine)
        #expect(ShiftStrip.boxes(data: comodin, calendar: wc, now: now).prefix(3).map(\.fill) == [.pausa, .casco, .vacio])
        #expect(comodin.profile.cascos == 0)

        let pausa = HomeQA.data(arguments: [HomeQA.pausaHoy], now: now, calendar: Self.santiago)
        let wcPausa = WorkCalendar(profile: pausa.profile, calendar: Self.santiago)
        #expect((pausa.workDays[wcPausa.key(for: now)]?.countedPauses ?? 0) >= 1)

        let sinConsentimiento = HomeQA.data(arguments: [HomeQA.sinConsentimiento], now: now, calendar: Self.santiago)
        #expect(HomeView.needsConsent(sinConsentimiento.profile))

        let store = AppStore(inMemory: true)
        #expect(!HomeQA.apply(arguments: ["Activate"], to: store, now: now))
        #expect(!store.profile.onboardingDone)
    }
}
