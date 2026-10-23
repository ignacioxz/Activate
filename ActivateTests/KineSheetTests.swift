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

    // MARK: - Hoja exportada (consulta + nota + tabla)

    private func facts() -> [KineFact] {
        [KineFact(id: "rdq_tendencia", title: "Espalda turno a turno (RDQ-6)", value: "4,0 → 2,5",
                  detail: "RDQ-6 promedio por turno: 4,0 → 2,5.", question: "¿Sigo igual?", focus: "Mantener."),
         KineFact(id: "contexto_dominante", title: "Dónde le duele más", value: "Al bajar · 2 de 3",
                  detail: "Registros «Me duele ahora»: al bajar del camión 2, en la cabina 1.",
                  question: "¿Qué hago cuando me duele al bajar del camión?", focus: "Bajar del camión sin cargar la espalda."),
         KineFact(id: "mejora_post", title: "Mejor después de la pausa", value: "6 de 9 pausas",
                  detail: "Mejor 6, Igual 2 y Peor 1 veces.", question: "¿Qué más hago?", focus: "Reforzar las pausas.")]
    }

    private func content(note: PatientNote? = nil, backend: CoachBackend = .rules, edited: Bool = false) -> KineSheetContent {
        let prev = turno("2026-09-28"), cur = turno("2026-10-12", max: 5, worse: 1)
        let s = summary(turnos: [prev, cur], current: cur, previous: prev, streak: 2, todayRDQ: 3)
        var consult = KineConsultRules.template(facts(), profile: profile())
        consult.backend = backend
        let sheet = KineSheet(consult: consult, note: note, factsSignature: KineConsultRules.signature(facts()),
                              preparedAt: .now, edited: edited)
        return KineSheetContent(sheet: sheet, facts: facts(), summary: s, profile: profile(),
                                extraAlerts: ["Alarma de prueba"], generatedAt: .now)
    }

    @Test func contenidoUneHallazgosConSusCifras() {
        var c = content()
        #expect(c.findings.map(\.fact.value) == ["4,0 → 2,5", "Al bajar · 2 de 3", "6 de 9 pausas"])
        #expect(c.questions.count == 3 && c.focus == "Mantener.")
        #expect(c.note == nil)
        #expect(!c.usedModel)
        #expect(c.originLine.hasPrefix("Texto de plantilla"))
        // Un hallazgo cuyo hecho ya no existe no se muestra.
        c.sheet.consult.findings.append(KineFinding(factID: "alertas", sentence: "x"))
        #expect(c.findings.count == 3)
        // Nota vacía no se muestra; con IA el pie lo dice, y si la persona editó, también.
        let blank = PatientNote(original: "   ", summary: "", zones: [], moments: [], backend: .rules)
        #expect(content(note: blank).note == nil)
        let ai = content(backend: .foundationModels, edited: true)
        #expect(ai.usedModel)
        #expect(ai.originLine.contains("Apple Intelligence") && ai.originLine.contains("editó"))
    }

    @Test @MainActor func exportaPNGaEscala3YPDF() {
        let note = PatientNote(original: "Me duele la espalda al bajar del camión.",
                               summary: "El paciente cuenta que le duele la espalda al bajar del camión.",
                               zones: [.lumbar], moments: [.salida], backend: .foundationModels)
        let c = content(note: note, backend: .foundationModels)

        let png = KineSheetExport.pngData(c)
        #expect((png?.count ?? 0) > 10_000)
        if let png, let image = UIImage(data: png) {
            #expect(image.size.width == KineSheetExport.exportWidth * KineSheetExport.pngScale)
            #expect(image.size.height > image.size.width)
        } else {
            Issue.record("El PNG no se pudo decodificar")
        }
        // Con nota la hoja es más alta que sin nota.
        let plain = KineSheetExport.pngData(content(backend: .foundationModels)).flatMap(UIImage.init(data:))
        if let plain, let png, let full = UIImage(data: png) {
            #expect(full.size.height > plain.size.height)
        }

        let pdf = KineSheetExport.pdfData(c)
        #expect((pdf?.count ?? 0) > 1_000)
        #expect(pdf?.prefix(4) == Data("%PDF".utf8))
    }

    @Test @MainActor func soloSeGuardaLoPreparadoOEditado() {
        let store = AppStore(inMemory: true)
        let template = content().sheet
        KineSheetScreen.persist(template, noteText: "  ", store: store)
        #expect(store.data.lastKineSheetJSON == nil)

        // Con nota escrita sí se guarda (texto tal cual, sin resumen).
        KineSheetScreen.persist(template, noteText: "Me duele el cuello.", store: store)
        let withNote = KineSheetCache.decode(store.data.lastKineSheetJSON)
        #expect(withNote?.note?.original == "Me duele el cuello." && withNote?.note?.summary == "")

        // Un resumen que ya no corresponde al texto se cambia por el texto tal cual.
        var ai = content(backend: .foundationModels).sheet
        ai.note = PatientNote(original: "Texto viejo", summary: "Resumen viejo", zones: [.cuello], moments: [], backend: .foundationModels)
        #expect(KineSheetScreen.resolvedNote(ai, noteText: "Texto viejo")?.summary == "Resumen viejo")
        #expect(KineSheetScreen.resolvedNote(ai, noteText: "Texto nuevo")?.summary == "")
        KineSheetScreen.persist(ai, noteText: "Texto viejo", store: store)
        #expect(KineSheetCache.decode(store.data.lastKineSheetJSON)?.consult.backend == .foundationModels)
    }

    @Test func cacheJSONIdaYVueltaEIgnoraElFormatoAntiguo() {
        let sheet = KineSheet(consult: KineConsult(findings: [KineFinding(factID: "rdq_tendencia", sentence: "a")],
                                                   questions: ["¿b?"], focus: "c", backend: .foundationModels),
                              note: PatientNote(original: "d", summary: "e", zones: [.cuello], moments: [.colacion], backend: .foundationModels),
                              factsSignature: "rdq_tendencia=4,0", preparedAt: Date(timeIntervalSince1970: 1_800_000_000), edited: true)
        let json = KineSheetCache.encode(sheet)
        #expect(json != nil)
        #expect(KineSheetCache.decode(json) == sheet)
        #expect(KineSheetCache.decode(nil) == nil)
        #expect(KineSheetCache.decode("{no json}") == nil)
        // Formato 1 (5 bloques en prosa) guardado por versiones anteriores: se ignora.
        let old = #"{"alerts":"","backend":"foundationModels","howItGoes":"d","period":"p","whatHeDid":"b","whatWorsens":"c","whenItHurts":"a"}"#
        #expect(KineSheetCache.decode(old) == nil)
        var future = sheet
        future.format = 99
        #expect(KineSheetCache.decode(KineSheetCache.encode(future)) == nil)
        // Sirve solo si sus hallazgos siguen teniendo hecho.
        #expect(KineSheetCache.usable(sheet, facts: facts()))
        #expect(!KineSheetCache.usable(sheet, facts: Array(facts().dropFirst())))
    }
}
