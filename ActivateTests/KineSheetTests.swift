import Testing
import Foundation
import UIKit
@testable import Activate

struct KineSheetTests {
    private var santiago: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago")!
        return c
    }

    private func profile() -> PlayerProfile {
        PlayerProfile(rosterStart: santiago.date(from: DateComponents(year: 2026, month: 10, day: 12))!)
    }

    private func turno(_ key: String, workDays: Int = 7, withPause: Int = 4, counted: Int = 5,
                       mean: Double? = 3.0, max: Int? = 4, items: [Int] = [1, 0, 2, 3, 0, 1],
                       better: Int = 3, same: Int = 1, worse: Int = 0,
                       steps: Int = 1000, reps: Int = 30, streak: Int = 2) -> TurnoSummary {
        TurnoSummary(turnoKey: key, label: "Turno \(key)", workDays: workDays, daysWithPause: withPause,
                     countedPauses: counted, meanRDQ: mean, maxRDQ: max, itemFrequency: items,
                     betterCount: better, sameCount: same, worseCount: worse, verifiedSteps: steps,
                     verifiedReps: reps, maxStreak: streak, stroopMedianRTms: nil, blinksPerMinute: nil, neckMaxYaw: nil)
    }

    private func summary(turnos: [TurnoSummary], current: TurnoSummary? = nil, previous: TurnoSummary? = nil,
                         streak: Int = 0, todayRDQ: Int? = nil, hints: [String] = [],
                         sessions: [SessionDigest] = []) -> StatsSummary {
        StatsSummary(currentTurno: current, previousTurno: previous, turnos: turnos, streak: streak,
                     totalCountedPauses: turnos.reduce(0) { $0 + $1.countedPauses }, todayRDQ: todayRDQ,
                     recentSessions: sessions, worsensHints: hints, historyLines: [], currentTurnoDays: [])
    }

    @Test func tablaOrdenaYLimitaLosTurnos() {
        let t1 = turno("2026-08-17"), t2 = turno("2026-08-31"), t3 = turno("2026-09-14")
        let t4 = turno("2026-09-28"), t5 = turno("2026-10-12", workDays: 3)
        let s = summary(turnos: [t4, t1, t5, t3, t2], current: t5, previous: t4)
        let table = KineSheetTable.build(summary: s, profile: profile(), calendar: santiago)

        #expect(table.columns.map(\.turnoKey) == ["2026-09-14", "2026-09-28", "2026-10-12"])
        #expect(table.columns.map(\.isCurrent) == [false, false, true])
        #expect(table.columns.map(\.title) == ["14 sep", "28 sep", "12 oct"])
        #expect(table.totalTurnos == 5)
        #expect(table.truncated)
        #expect(table.periodText == "Del 14 sep al 14 oct 2026 · 3 turnos")
        #expect(table.rows.allSatisfy { $0.values.count == 3 })
    }

    @Test func turnoActualFueraDeLaListaSeAgrega() {
        let prev = turno("2026-09-28"), cur = turno("2026-10-12", workDays: 2)
        let s = summary(turnos: [prev], current: cur, previous: prev)
        let table = KineSheetTable.build(summary: s, profile: profile(), calendar: santiago)
        #expect(table.columns.map(\.turnoKey) == ["2026-09-28", "2026-10-12"])
        #expect(!table.truncated)
    }

    @Test func porcentajeMejorYFilasNumericas() {
        let t = turno("2026-10-12", withPause: 4, counted: 6, mean: 2.5, max: 4, better: 6, same: 2, worse: 1, steps: 2400, reps: 60)
        let table = KineSheetTable.build(summary: summary(turnos: [t], current: t), profile: profile(), calendar: santiago)
        func row(_ label: String) -> [String] { table.rows.first { $0.label == label }?.values ?? [] }

        #expect(row("Días con pausa") == ["4 de 7"])
        #expect(row("Pausas verificadas") == ["6"])
        #expect(row("RDQ-6 promedio") == ["2,5"])
        #expect(row("RDQ-6 máximo") == ["4 de 6"])
        #expect(row("Mejor después") == ["6 de 9"])
        #expect(row("% Mejor") == ["67%"])
        #expect(row("Pasos verificados") == ["2.400"])
        #expect(row("Reps verificadas") == ["60"])
        #expect(KineSheetTable.betterRatio(turno("x", better: 0, same: 0, worse: 0)) == nil)
    }

    @Test func frecuenciaPorItemDelRDQ6() {
        let prev = turno("2026-09-28", items: [2, 0, 1, 4, 0, 2])
        let cur = turno("2026-10-12", items: [1, 1, 0, 3, 0, 1])
        let short = turno("2026-09-14", items: [5])  // motor que entrega menos de 6 valores
        let table = KineSheetTable.build(summary: summary(turnos: [short, prev, cur], current: cur), profile: profile(), calendar: santiago)

        #expect(table.items.count == RDQ6.items.count)
        #expect(table.items.map(\.text) == RDQ6.items)
        #expect(table.items.map(\.current) == [1, 1, 0, 3, 0, 1])
        #expect(table.items.map(\.total) == [8, 1, 1, 7, 0, 3])
    }

    @Test func alertasDeSwift() {
        let bad = turno("2026-10-12", max: 5, worse: 2)
        let table = KineSheetTable.build(summary: summary(turnos: [bad], current: bad), profile: profile(),
                                         extraAlerts: ["Extra"], calendar: santiago)
        #expect(table.alerts.count == 3)
        #expect(table.alerts[0].contains("RDQ-6 de 5 de 6"))
        #expect(table.alerts[1].contains("«Peor»") && table.alerts[1].contains("2 veces"))
        #expect(table.alerts[2] == "Extra")

        let fine = turno("2026-10-12", max: 4, worse: 0)
        #expect(KineSheetTable.build(summary: summary(turnos: [fine]), profile: profile(), calendar: santiago).alerts.isEmpty)
    }

    @Test func lineasDeAlarmaDesdeCheckIns() {
        let date = santiago.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
        let alarm = DailyCheckIn(date: date, workDayKey: "2026-10-14", turnoKey: "2026-10-12", source: .pausa,
                                 answers: [true, false, true, true, false, true], alarmAnswers: [false, true, false], zone: .lumbar)
        let clean = DailyCheckIn(date: date, workDayKey: "2026-10-13", turnoKey: "2026-10-12", source: .pausa,
                                 answers: [false, false, false, false, false, false], zone: .lumbar)
        let lines = KineSheetTable.alarmLines(checkIns: [clean, alarm], calendar: santiago)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("14 oct 2026: respondió Sí a «"))
        #expect(lines[0].contains(RDQ6.alarmQuestions[1]))
    }

    @Test func plantillaRellenaLosCamposVacios() {
        let prev = turno("2026-09-28", mean: 4.0), cur = turno("2026-10-12", mean: 2.5, max: 4)
        let s = summary(turnos: [prev, cur], current: cur, previous: prev, streak: 3, todayRDQ: 2,
                        hints: ["Le duele más al bajar del camión"])
        let table = KineSheetTable.build(summary: s, profile: profile(), calendar: santiago)
        let fallback = KineSheetFallback.sheet(summary: s, profile: profile(), table: table)

        #expect(fallback.backend == .rules)
        #expect(fallback.period == table.periodText)
        #expect(fallback.whenItHurts.contains("2,5 de 6") && fallback.whenItHurts.contains("Hoy: 2 de 6"))
        #expect(fallback.whatHeDid.contains("10 pausas verificadas en 2 turnos"))
        #expect(fallback.whatWorsens == "Le duele más al bajar del camión.")
        #expect(fallback.howItGoes.contains("4,0 en el turno anterior, 2,5 en el actual"))
        #expect(fallback.howItGoes.contains("Racha actual: 3 días"))
        #expect(fallback.alerts.isEmpty)

        let coach = KineSheet(period: "", whenItHurts: "  Le duele al bajar.  ", whatHeDid: "", whatWorsens: "",
                              howItGoes: "", alerts: "Ninguna.", backend: .foundationModels)
        let merged = KineSheetFallback.merge(coach, fallback: fallback)
        #expect(merged.whenItHurts == "Le duele al bajar.")
        #expect(merged.whatHeDid == fallback.whatHeDid)
        #expect(merged.period == fallback.period)
        #expect(merged.alerts == "Ninguna.")
        #expect(merged.backend == .foundationModels)
    }

    @Test func resumenVacioNoRevienta() {
        let s = summary(turnos: [])
        let table = KineSheetTable.build(summary: s, profile: profile(), calendar: santiago)
        #expect(table.columns.isEmpty)
        #expect(table.periodText == "Sin turnos con registros")
        #expect(table.items.allSatisfy { $0.current == 0 && $0.total == 0 })

        let fallback = KineSheetFallback.sheet(summary: s, profile: profile(), table: table)
        #expect(fallback.whenItHurts.contains("Sin cuestionarios"))
        #expect(fallback.whatHeDid == "Sin pausas verificadas en el período.")
        #expect(fallback.whatWorsens.hasPrefix("Sin patrones claros"))
        #expect(fallback.howItGoes.hasPrefix("Sin datos suficientes"))
    }

    @Test func ejerciciosRecientesSoloVerificadosYSinStroop() {
        let cur = turno("2026-10-12")
        func digest(_ kinds: [ActivityKind], level: VerificationLevel) -> SessionDigest {
            SessionDigest(id: UUID(), date: .now, workDayKey: "2026-10-13", moment: .colacion, recipe: .colacion3,
                          checkInScore: 2, post: .mejor, counted: level == .full, level: level, activityKinds: kinds)
        }
        let s = summary(turnos: [cur], current: cur, sessions: [
            digest([.pasos, .cuello, .stroop], level: .full),
            digest([.pasos, .ojos], level: .reduced),
            digest([.sentadilla], level: .suspicious),
        ])
        let text = KineSheetFallback.whatHeDid(summary: s, table: KineSheetTable.build(summary: s, profile: profile(), calendar: santiago))
        #expect(text.contains("Caminata ×2"))
        #expect(text.contains("Movilidad cervical ×1"))
        #expect(!text.contains("reflejos"))
        #expect(!text.contains("Sentadilla"))
    }

    @Test @MainActor func exportaPNGaEscala3YPDF() {
        let prev = turno("2026-09-28"), cur = turno("2026-10-12", max: 5, worse: 1)
        let s = summary(turnos: [prev, cur], current: cur, previous: prev, streak: 2, todayRDQ: 3,
                        hints: ["Le duele más al bajar del camión"])
        let table = KineSheetTable.build(summary: s, profile: profile(), calendar: santiago)
        let sheet = KineSheetFallback.sheet(summary: s, profile: profile(), table: table)

        let png = KineSheetExport.pngData(sheet: sheet, summary: s, profile: profile(), extraAlerts: ["Alarma de prueba"], now: .now)
        #expect((png?.count ?? 0) > 10_000)
        if let png, let image = UIImage(data: png) {
            #expect(image.size.width == KineSheetExport.exportWidth * KineSheetExport.pngScale)
            #expect(image.size.height > image.size.width)
        } else {
            Issue.record("El PNG no se pudo decodificar")
        }

        let pdf = KineSheetExport.pdfData(sheet: sheet, summary: s, profile: profile(), extraAlerts: [], now: .now)
        #expect((pdf?.count ?? 0) > 1_000)
        #expect(pdf?.prefix(4) == Data("%PDF".utf8))
    }

    @Test func cacheJSONIdaYVuelta() {
        let sheet = KineSheet(period: "p", whenItHurts: "a", whatHeDid: "b", whatWorsens: "c", howItGoes: "d",
                              alerts: "", backend: .foundationModels)
        let json = KineSheetCache.encode(sheet)
        #expect(json != nil)
        #expect(KineSheetCache.decode(json) == sheet)
        #expect(KineSheetCache.decode(nil) == nil)
        #expect(KineSheetCache.decode("{no json}") == nil)
    }
}
