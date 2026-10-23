import Testing
import Foundation
import UIKit
@testable import Activate

/// Niveles por pausa completa (`LevelProgress`): la pausa activa es una al día; 100 % de la pausa = +1
/// nivel; una parcial suma su parte y se arrastra; vale la mejor pausa del día; la pausa rápida se mide
/// contra la ruta completa; solo pausas verificadas. Y el nivel en el Reporte de Salud.
struct LevelProgressTests {
    private var santiago: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago")!
        return c
    }

    private func date(_ day: Int, hour: Int = 10, minute: Int = 0) -> Date {
        santiago.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// 7×7 que sube el lunes 12-10-2026 (12-18 turno), turno de día (el día laboral empieza a las 04:00).
    private var profile: PlayerProfile {
        PlayerProfile(rosterStart: santiago.startOfDay(for: date(12)))
    }

    private var work: WorkCalendar { WorkCalendar(profile: profile, calendar: santiago) }

    private func activity(_ kind: ActivityKind, done: Bool = true, skipped: Bool = false,
                          level: VerificationLevel = .full) -> ActivityResult {
        ActivityResult(kind: kind, target: kind.defaultTarget, achieved: done ? kind.defaultTarget : 0, durationSeconds: 30,
                       completed: done, level: level, metrics: .none, anomalies: [], skipped: skipped)
    }

    /// Pausa con los primeros `done` ejercicios hechos y verificados; el resto, saltados ("no suma").
    private func pause(day: Int, hour: Int = 10, done: Int, kinds: [ActivityKind] = ActivityKind.sessionOrder,
                       recipe: RecipeKind = .campamento5, counted: Bool = true, level: VerificationLevel = .full,
                       simulated: Bool = false) -> PauseSession {
        let at = date(day, hour: hour)
        var s = PauseSession(workDayKey: work.key(for: at), turnoKey: work.turnoKey(for: at), recipe: recipe,
                             moment: .colacion, startedAt: at)
        s.endedAt = at.addingTimeInterval(400)
        s.activities = kinds.enumerated().map { i, kind in
            i < done ? activity(kind) : activity(kind, done: false, skipped: true)
        }
        s.counted = counted
        s.level = level
        s.simulated = simulated
        s.postResponse = .mejor
        return s
    }

    private func progress(_ sessions: [PauseSession], today: Int = 17) -> LevelProgress {
        LevelProgress.compute(sessions: sessions, calendar: work, now: date(today, hour: 18))
    }

    private let pct = "\u{00A0}%"

    // MARK: - Reglas

    @Test func sinPausasPartimosEnNivelUno() {
        let p = progress([])
        #expect(p.level == 1 && p.totalCredits == 0 && p.percentToNext == 0)
        #expect(p.fullDays == 0 && p.daysWithPause == 0)
        #expect(p.todayLine == nil && p.todayPlanned == 0)
        #expect(p.levelLine == "Nivel 1 · 0\(pct) hacia el nivel 2")
        #expect(p.fullDaysLine == "Sin pausas verificadas todavía")
    }

    @Test func sieteDeSieteSubeUnNivel() {
        let p = progress([pause(day: 17, done: 7)])
        #expect(p.level == 2)
        #expect(p.fractionToNext == 0 && p.percentToNext == 0)
        #expect(p.fullDays == 1 && p.daysWithPause == 1)
        #expect(p.todayCredit == 1 && p.todayCompleted == 7 && p.todayPlanned == 7)
        #expect(p.todayLine == "Hoy: 7 de 7 ejercicios (+1 nivel)")
        #expect(p.levelLine == "Nivel 2 · 0\(pct) hacia el nivel 3")
        #expect(p.fullDaysLine == "1 día con pausa completa de 1 día con pausa")
    }

    @Test func cincoDeSieteSeArrastraAlDiaSiguiente() {
        let one = progress([pause(day: 16, done: 5)], today: 16)
        #expect(one.level == 1)
        #expect(abs(one.totalCredits - 5.0 / 7.0) < 1e-12)
        #expect(one.percentToNext == 71)
        #expect(one.todayLine == "Hoy: 5 de 7 ejercicios (+71\(pct))")
        #expect(one.levelLine == "Nivel 1 · 71\(pct) hacia el nivel 2")

        // 5/7 + 5/7 = 1,43: sube un nivel y arrastra 43 %.
        let two = progress([pause(day: 16, done: 5), pause(day: 17, done: 5)])
        #expect(two.level == 2)
        #expect(abs(two.fractionToNext - 3.0 / 7.0) < 1e-9)
        #expect(two.percentToNext == 43)
        #expect(two.levelLine == "Nivel 2 · 43\(pct) hacia el nivel 3")
        #expect(two.fullDays == 0 && two.daysWithPause == 2)
        #expect(two.fullDaysLine == "0 días con pausa completa de 2 días con pausa")

        // 5/7 + 2/7 = 1 exacto (sin error de punto flotante): nivel 2 y 0 %.
        let exact = progress([pause(day: 15, done: 5), pause(day: 16, done: 2)])
        #expect(exact.level == 2 && exact.percentToNext == 0)

        // Cuatro pausas completas y una de 5 de 7: nivel 5 y 71 % hacia el 6.
        let mixed = progress([13, 14, 15, 16].map { pause(day: $0, done: 7) } + [pause(day: 17, done: 5)])
        #expect(mixed.level == 5 && mixed.percentToNext == 71)
        #expect(mixed.fullDaysLine == "4 días con pausa completa de 5 días con pausa")
    }

    @Test func soloCuentaLaMejorPausaDelDia() {
        // Dos pausas completas el mismo día laboral: nunca más de 1 nivel por día.
        let twice = progress([pause(day: 17, hour: 9, done: 7), pause(day: 17, hour: 15, done: 7)])
        #expect(twice.level == 2 && twice.percentToNext == 0 && twice.daysWithPause == 1)

        // Una parcial y una completa el mismo día: vale la completa, en cualquier orden.
        let morning = pause(day: 17, hour: 9, done: 5), afternoon = pause(day: 17, hour: 15, done: 7)
        let a = progress([morning, afternoon])
        let b = progress([afternoon, morning])
        #expect(a.level == 2 && a.todayCompleted == 7)
        #expect(a == b && a.today?.sessionID == afternoon.id)

        // Dos parciales el mismo día no se suman (5/7 y 5/7 = 71 %, no 143 %).
        let partials = progress([pause(day: 17, hour: 9, done: 5), pause(day: 17, hour: 15, done: 5)])
        #expect(partials.level == 1 && partials.percentToNext == 71)

        // El día laboral manda: 23:00 del 16 y 02:00 del 17 son el mismo día (empieza a las 04:00).
        let night = progress([pause(day: 16, hour: 23, done: 7), pause(day: 17, hour: 2, done: 6)])
        #expect(night.daysWithPause == 1 && night.level == 2)
        #expect(night.days.first?.dayKey == "2026-10-16")
    }

    @Test func pausaRapidaSeMideContraLaRutaCompleta() {
        let quick = pause(day: 17, done: 2, kinds: [.cuello, .ojos], recipe: .relevo60)
        let p = progress([quick])
        #expect(LevelProgress.plannedCount(for: quick) == ActivityKind.sessionOrder.count)
        #expect(p.todayCompleted == 2 && p.todayPlanned == 7)
        #expect(abs(p.todayCredit - 2.0 / 7.0) < 1e-12)
        #expect(p.percentToNext == 29 && p.level == 1)
        #expect(p.todayLine == "Hoy: 2 de 7 ejercicios (+29\(pct))")
        // Una ruta completa ese mismo día gana a la rápida.
        let both = progress([quick, pause(day: 17, hour: 14, done: 7)])
        #expect(both.level == 2 && both.todayPlanned == 7 && both.todayCompleted == 7)
    }

    @Test func planSuaveOAcortadoPorElRDQLlegaAlCien() {
        // Plan suave (RDQ-6 alto): caminata corta + cuello + pestañeo, 3 de 3 = +1 nivel.
        let gentle = pause(day: 17, done: 3, kinds: Recipes.gentleKinds)
        let p = progress([gentle])
        #expect(p.level == 2 && p.todayLine == "Hoy: 3 de 3 ejercicios (+1 nivel)")
        // Plan sin sentadilla ni pararse y sentarse ("trata de no agacharse"): 5 de 5 también es completa.
        let noBending = ActivityKind.sessionOrder.filter { $0 != .sentadilla && $0 != .pararseSentarse }
        #expect(progress([pause(day: 17, done: 5, kinds: noBending)]).fullDays == 1)
    }

    @Test func saltadasYFallidasNoSuman() {
        var s = pause(day: 17, done: 7)
        s.activities[1].skipped = true           // saltada (aunque viniera marcada como hecha)
        s.activities[2].completed = false        // fallida: no llegó a la meta
        s.activities[3] = activity(.cuello, done: false, skipped: true)
        let p = progress([s])
        #expect(p.todayCompleted == 4 && p.todayPlanned == 7)
        #expect(p.percentToNext == 57 && p.level == 1)
        // Por actividad: verificada (full o contada con el respaldo) sí; sospechosa o simulada no.
        #expect(LevelProgress.isCompleted(activity(.pasos)))
        #expect(LevelProgress.isCompleted(activity(.extensionLumbar, level: .reduced)))
        #expect(!LevelProgress.isCompleted(activity(.stroop, level: .suspicious)))
        #expect(!LevelProgress.isCompleted(activity(.ojos, level: .simulated)))
        #expect(!LevelProgress.isCompleted(activity(.cuello, done: false)))
        #expect(!LevelProgress.isCompleted(activity(.cuello, skipped: true)))
    }

    @Test func sospechosasYSimuladasNoCuentan() {
        let suspicious = pause(day: 15, done: 7, level: .suspicious)
        let simulated = pause(day: 16, done: 7, level: .simulated, simulated: true)
        let notCounted = pause(day: 17, done: 7, counted: false)
        let p = progress([suspicious, simulated, notCounted])
        #expect(p.level == 1 && p.daysWithPause == 0 && p.totalCredits == 0)
        #expect(LevelProgress.credit(for: suspicious) == nil)
        #expect(LevelProgress.credit(for: simulated) == nil)
        #expect(LevelProgress.credit(for: notCounted) == nil)
        // Una sospechosa no le quita el día a una verificada del mismo día.
        let mixed = progress([pause(day: 17, hour: 9, done: 7, level: .suspicious), pause(day: 17, hour: 15, done: 6)])
        #expect(mixed.todayCompleted == 6 && mixed.percentToNext == 86)
        // Contada con el sensor de respaldo (`reduced`) sí cuenta.
        #expect(progress([pause(day: 17, done: 7, level: .reduced)]).level == 2)
    }

    @Test func porcentajeNuncaDiceCienSinSubir() {
        #expect(LevelProgress.percent(0.999) == 99)
        #expect(LevelProgress.percent(0.001) == 1)
        #expect(LevelProgress.percent(0) == 0)
        #expect(LevelProgress.level(forCredits: 0.9999999999) == 2)  // tolerancia de punto flotante
        #expect(LevelProgress.level(forCredits: 3.5) == 4)
    }

    @Test func nivelAlCierreDeCadaTurno() {
        // Turno del 12 oct: 2 completas; bajada; turno del 26 oct: 1 completa y 5 de 7.
        let p = progress([pause(day: 13, done: 7), pause(day: 14, done: 7), pause(day: 26, done: 7), pause(day: 27, done: 5)],
                         today: 27)
        #expect(p.level == 4 && p.percentToNext == 71)
        #expect(p.through(turnoKey: "2026-10-12").level == 3)
        #expect(p.through(turnoKey: "2026-10-12").compactValue == "3 · 0\(pct)")
        #expect(p.through(turnoKey: "2026-10-26").compactValue == "4 · 71\(pct)")
        #expect(p.fullDays(inTurno: "2026-10-12") == 2 && p.fullDays(inTurno: "2026-10-26") == 1)
        #expect(p.through(dayKey: "2026-10-13").level == 2)
    }

    @Test @MainActor func gameStoreDerivaElNivelDelHistorial() {
        // El store usa el calendario del sistema: las pausas se arman con ese mismo calendario.
        let cal = Calendar.current
        func local(_ day: Int, hour: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        let store = AppStore(inMemory: true)
        store.mutate { $0.profile.rosterStart = cal.startOfDay(for: local(12, hour: 0)) }
        let game = GameStore(store: store)
        func localPause(_ day: Int, done: Int) -> PauseSession {
            var s = pause(day: day, done: done)
            s.startedAt = local(day, hour: 10)
            s.workDayKey = store.calendar.key(for: s.startedAt)
            s.turnoKey = store.calendar.turnoKey(for: s.startedAt)
            return s
        }
        #expect(game.levelProgress(at: local(16, hour: 18)).level == 1)
        let xpBefore = store.data.profile.xp
        game.record(localPause(15, done: 7))
        game.record(localPause(16, done: 5))
        let p = game.levelProgress(at: local(16, hour: 18))
        #expect(p.level == 2 && p.percentToNext == 71)
        #expect(p.todayLine == "Hoy: 5 de 7 ejercicios (+71\(pct))")
        // El XP sigue sumando como siempre (celebración y premios); el nivel ya no sale de él.
        #expect(store.data.profile.xp > xpBefore)
    }

    // MARK: - Reporte de Salud

    private func data(_ sessions: [PauseSession]) -> SaveData {
        var d = SaveData(profile: profile)
        d.sessions = sessions
        for s in sessions where s.counted {
            let at = s.startedAt
            var day = d.workDays[s.workDayKey] ?? WorkDay(key: s.workDayKey, kind: work.kind(for: at),
                                                          dayInBlock: work.dayInBlock(for: at), turnoKey: s.turnoKey)
            day.countedPauses += 1
            d.workDays[s.workDayKey] = day
        }
        return d
    }

    @Test func elNivelVaEnLosHechosDelReporte() throws {
        let d = data([pause(day: 13, done: 7), pause(day: 14, done: 5), pause(day: 16, done: 5)])
        let now = date(17, hour: 18)
        let summary = StatsEngine.summary(data: d, calendar: work, now: now)
        let facts = KineFacts.build(data: d, summary: summary, calendar: santiago)
        let nivel = try #require(facts.first { $0.id == KineFactID.nivel.rawValue })
        // 1 + 5/7 + 5/7 = 2,43 → nivel 3 y 43 %.
        #expect(nivel.value == "Nivel 3 · 43\(pct)")
        #expect(nivel.detail.hasPrefix("Nivel 3 · 43\(pct) hacia el nivel 4: 1 día con pausa completa de 3 días con pausa."))
        let gistHasDigits = nivel.gist.contains { $0.isNumber }
        #expect(!gistHasDigits)
        #expect(nivel.question.hasPrefix("¿") && nivel.question.hasSuffix("?"))
        #expect(!nivel.focus.isEmpty && !nivel.mustInclude)
        #expect(!KineConsultRules.hasClinicalTerm(nivel.detail + nivel.gist + nivel.question + nivel.focus))
        #expect(KineFactID.all.contains("nivel"))
        #expect(CoachPrompts.kineConsultPrompt(facts, profile: d.profile).contains("[nivel] Nivel por pausas completas. Cifra: Nivel 3 · 43\(pct)."))

        // El modelo puede citarlo por id; la cifra la pone la app.
        let proposal = KineConsultRules.Proposal(
            findings: [KineFinding(factID: "nivel", sentence: "Completa la pausa entera solo algunos días."),
                       KineFinding(factID: facts[0].id, sentence: facts[0].gist),
                       KineFinding(factID: facts[1].id, sentence: facts[1].gist)],
            questions: ["¿Qué ejercicio de la pausa me conviene priorizar?", "¿Qué hago?", "¿Cómo sigo?"],
            focus: "Completar la pausa más días.")
        if case .success(let consult) = KineConsultRules.validate(proposal, facts: facts, profile: d.profile) {
            #expect(consult.findings.first?.factID == "nivel")
        } else {
            Issue.record("La validación rechazó un hallazgo con el id del nivel")
        }
        // Una frase que inventa cifras del nivel se cambia por la de plantilla.
        #expect(KineConsultRules.cleanFinding("Subió al nivel 9.", fact: nivel) == nil)

        // Sin pausas verificadas no hay hecho de nivel.
        let empty = data([pause(day: 13, done: 7, level: .suspicious)])
        let none = KineFacts.build(data: empty, summary: StatsEngine.summary(data: empty, calendar: work, now: now), calendar: santiago)
        #expect(!none.contains { $0.id == "nivel" })
    }

    /// Historial de nivel 7 · 43 %: 6 días completos, uno con 1 de 7 y otro con 2 de 7 (1 + 6 + 3/7).
    private var nivelSiete: [PauseSession] {
        (12...17).map { pause(day: $0, done: 7) } + [pause(day: 18, done: 1), pause(day: 26, done: 2)]
    }

    @Test func elModeloNoPuedeDarOtroNivelEnUnHallazgo() throws {
        let p = progress(nivelSiete, today: 26)
        #expect(p.level == 7 && p.percentToNext == 43)
        let nivel = try #require(KineFacts.nivel(p))
        #expect(nivel.value == "Nivel 7 · 43\(pct)")
        // El detalle trae otras cifras (el nivel siguiente, los días): no sirven de ancla para la frase.
        #expect(nivel.detail.hasPrefix("Nivel 7 · 43\(pct) hacia el nivel 8: 6 días con pausa completa de 8 días con pausa."))
        #expect(KineConsultRules.computedLevel(in: [nivel]) == KineConsultRules.ComputedLevel(level: 7))

        // La frase del nivel va sin cifras (ni con letras): la cifra la pone el chip de la app.
        for wrong in ["Está en el nivel 6.", "Está en el nivel ocho.", "Llegó al nivel 8 con su pausa.",
                      "Está en el nivel 7.", "Está en el nivel uno.", "Llegó al séptimo nivel.",
                      "Lleva seis días con la pausa completa."] {
            #expect(KineConsultRules.cleanFinding(wrong, fact: nivel) == nil, "\(wrong)")
        }
        #expect(KineConsultRules.cleanFinding("Completa la pausa entera más de la mitad de los días.", fact: nivel) != nil)
        #expect(KineConsultRules.cleanFinding("Sube un nivel cada día que completa la pausa.", fact: nivel) != nil)
        // Otro hecho tampoco nombra un nivel con cifra.
        let other = KineFact(id: KineFactID.adherencia.rawValue, title: "Pausas del turno", value: "6 de 8 días",
                             detail: "Hizo la pausa 6 de 8 días del turno.", gist: "Hace la pausa casi todos los días.")
        #expect(KineConsultRules.cleanFinding("Hizo la pausa 6 de 8 días.", fact: other) != nil)
        #expect(KineConsultRules.cleanFinding("Está en el nivel 6 de pausas.", fact: other) == nil)

        // Validada como salida del modelo: el hallazgo vuelve a la frase de plantilla (el resumen).
        let d = data(nivelSiete)
        let now = date(26, hour: 18)
        let facts = KineFacts.build(data: d, summary: StatsEngine.summary(data: d, calendar: work, now: now), calendar: santiago)
        let built = try #require(facts.first { $0.id == KineFactID.nivel.rawValue })
        #expect(built.value == nivel.value)
        let others = facts.filter { $0.id != KineFactID.nivel.rawValue && !$0.mustInclude }
        try #require(others.count >= 2)
        for wrong in ["Está en el nivel 6.", "Está en el nivel ocho."] {
            let proposal = KineConsultRules.Proposal(
                findings: [KineFinding(factID: "nivel", sentence: wrong),
                           KineFinding(factID: others[0].id, sentence: others[0].gist),
                           KineFinding(factID: others[1].id, sentence: others[1].gist)],
                questions: ["¿Qué hago para no bajar el ritmo?", "¿Qué hago?", "¿Cómo sigo?"],
                focus: "Completar la pausa más días.")
            guard case .success(let consult) = KineConsultRules.validate(proposal, facts: facts, profile: d.profile) else {
                Issue.record("La validación debía pasar con la frase de plantilla")
                continue
            }
            let finding = try #require(consult.findings.first { $0.factID == "nivel" })
            #expect(finding.sentence == KineConsultRules.templateSentence(built), "\(wrong)")
            #expect(!finding.sentence.contains { $0.isNumber })
        }
    }

    @Test func elModeloNoPuedeDarOtroNivelEnPreguntasNiFoco() throws {
        let d = data(nivelSiete)
        let now = date(26, hour: 18)
        let facts = KineFacts.build(data: d, summary: StatsEngine.summary(data: d, calendar: work, now: now), calendar: santiago)
        let nivel = try #require(facts.first { $0.id == KineFactID.nivel.rawValue })
        let level = try #require(KineConsultRules.computedLevel(in: facts))
        #expect(level.level == 7 && level.next == 8)
        let corpus = KineConsultRules.groundingCorpus(facts, profile: d.profile)
        func question(_ q: String) -> String? {
            KineConsultRules.cleanQuestion(q, corpus: corpus, profile: d.profile, level: level)
        }
        // El 6 está en el corpus (los días con pausa completa), pero no es el nivel.
        #expect(question("¿Por qué sigo en el nivel 6?") == nil)
        #expect(question("¿Por qué sigo en el nivel seis?") == nil)
        #expect(question("¿Cómo llego al nivel 9?") == nil)
        #expect(question("¿Qué hago para seguir en el nivel 8?") == nil)  // el siguiente, solo "al"/"hacia el"
        #expect(question("¿Me conviene subir dos niveles?") == nil)
        #expect(question("¿Qué me falta para llegar al nivel 8?") == "¿Qué me falta para llegar al nivel 8?")
        #expect(question("¿Qué hago para seguir en el nivel 7?") == "¿Qué hago para seguir en el nivel 7?")
        #expect(question("¿Qué me sirve para subir de nivel?") == "¿Qué me sirve para subir de nivel?")
        // Sin nivel calculado, ninguna cifra junto a "nivel".
        #expect(KineConsultRules.cleanQuestion("¿Qué hago para seguir en el nivel 7?", corpus: corpus, profile: d.profile) == nil)

        // En la validación completa: la pregunta y el foco inventados vuelven a los de plantilla.
        let others = facts.filter { $0.id != KineFactID.nivel.rawValue && !$0.mustInclude }
        try #require(others.count >= 2)
        let proposal = KineConsultRules.Proposal(
            findings: [KineFinding(factID: "nivel", sentence: nivel.gist),
                       KineFinding(factID: others[0].id, sentence: others[0].gist),
                       KineFinding(factID: others[1].id, sentence: others[1].gist)],
            questions: ["¿Por qué sigo en el nivel 6?", "¿Qué hago?", "¿Cómo sigo?"],
            focus: "Seguir en el nivel 6 completando la pausa.")
        guard case .success(let consult) = KineConsultRules.validate(proposal, facts: facts, profile: d.profile) else {
            Issue.record("La validación debía pasar con la pregunta y el foco de plantilla")
            return
        }
        #expect(consult.findings.first?.factID == "nivel")
        #expect(consult.questions.first == nivel.question)
        #expect(!consult.questions.contains { $0.contains("nivel 6") })
        #expect(consult.focus == nivel.focus)
        let ok = KineConsultRules.Proposal(findings: proposal.findings, questions: proposal.questions,
                                           focus: "Completar la pausa para pasar al nivel 8.")
        if case .success(let k) = KineConsultRules.validate(ok, facts: facts, profile: d.profile) {
            #expect(k.focus == "Completar la pausa para pasar al nivel 8.")
        } else {
            Issue.record("Un foco con el nivel siguiente bien dicho debía pasar")
        }
    }

    @Test func lasCifrasJuntoANivelSeLeenConDigitosOLetras() {
        typealias M = KineConsultRules.LevelMention
        #expect(KineConsultRules.levelMentions(in: "Está en el nivel 6.") == [M(value: 6, towardNext: false)])
        #expect(KineConsultRules.levelMentions(in: "Llegó al nivel ocho.") == [M(value: 8, towardNext: true)])
        #expect(KineConsultRules.levelMentions(in: "Va hacia el nivel 8.") == [M(value: 8, towardNext: true)])
        #expect(KineConsultRules.levelMentions(in: "Subió al séptimo nivel.") == [M(value: 7, towardNext: true)])
        #expect(KineConsultRules.levelMentions(in: "Nivel 7º del turno") == [M(value: 7, towardNext: false)])
        #expect(KineConsultRules.levelMentions(in: "nivel treinta y dos") == [M(value: 32, towardNext: false)])
        #expect(KineConsultRules.levelMentions(in: "nivel ciento cinco") == [M(value: 105, towardNext: false)])
        #expect(KineConsultRules.levelMentions(in: "Subió 2 niveles.") == [M(value: 2, towardNext: false)])
        #expect(KineConsultRules.levelMentions(in: "Cada día con la pausa completa sube un nivel.").isEmpty)
        #expect(KineConsultRules.levelMentions(in: "Sin cifras de nivel.").isEmpty)
    }

    @Test func elNivelVaEnLaTablaDelReporte() {
        let sessions = [pause(day: 13, done: 7), pause(day: 14, done: 7), pause(day: 16, done: 5)]
        let d = data(sessions)
        let now = date(17, hour: 18)
        let summary = StatsEngine.summary(data: d, calendar: work, now: now)
        let level = LevelProgress.compute(sessions: sessions, calendar: work, now: now)
        let table = KineSheetTable.build(summary: summary, profile: d.profile, level: level, now: now, calendar: santiago)
        func row(_ label: String) -> [String]? { table.rows.first { $0.label == label }?.values }
        #expect(table.columns.last?.isCurrent == true)
        #expect(row(KineSheetTable.levelFullDaysLabel)?.last == "2")
        #expect(row(KineSheetTable.levelReachedLabel)?.last == "3 · 71\(pct)")
        #expect(table.rows.allSatisfy { $0.values.count == table.columns.count })
        // Sin nivel la tabla queda como antes.
        let plain = KineSheetTable.build(summary: summary, profile: d.profile, now: now, calendar: santiago)
        #expect(row(KineSheetTable.levelReachedLabel) != nil && !plain.rows.contains { $0.label == KineSheetTable.levelReachedLabel })

        // El contenido muestra el nivel solo si hay días con pausa.
        let sheet = KineSheet(consult: KineConsultRules.template([], profile: d.profile), note: nil,
                              factsSignature: "", preparedAt: now)
        let content = KineSheetContent(sheet: sheet, facts: [], summary: summary, profile: d.profile, level: level)
        #expect(content.shownLevel?.levelLine == "Nivel 3 · 71\(pct) hacia el nivel 4")
        #expect(content.shownLevel?.fullDaysLine == "2 días con pausa completa de 3 días con pausa")
        var noDays = content
        noDays.level = LevelProgress.compute(sessions: [], calendar: work, now: now)
        #expect(noDays.shownLevel == nil)
    }

    @Test func elArchivoSeLlamaReporteDeSalud() {
        var marco = profile
        marco.name = "Marco"
        #expect(HealthReport.title == "Reporte de Salud")
        #expect(KineSheetExport.fileStem(for: marco) == "Reporte de Salud - Marco")
        #expect("\(KineSheetExport.fileStem(for: marco)).pdf" == "Reporte de Salud - Marco.pdf")
        var anonymous = profile
        anonymous.name = "   "
        #expect(KineSheetExport.fileStem(for: anonymous) == "Reporte de Salud")
        #expect(CelebrationCopy.postNote(.peor) == "Quedó en su Reporte de Salud.")
    }

    @Test @MainActor func elReporteExportadoLlevaElNivelYElTitulo() throws {
        let sessions = [pause(day: 13, done: 7), pause(day: 16, done: 5)]
        let d = data(sessions)
        let now = date(17, hour: 18)
        let summary = StatsEngine.summary(data: d, calendar: work, now: now)
        let sheet = KineSheet(consult: KineConsultRules.template([], profile: d.profile), note: nil,
                              factsSignature: "", preparedAt: now)
        var marco = d.profile
        marco.name = "Marco"
        let plain = KineSheetContent(sheet: sheet, facts: [], summary: summary, profile: marco, generatedAt: now)
        var withLevel = plain
        withLevel.level = LevelProgress.compute(sessions: sessions, calendar: work, now: now)

        let a = try #require(KineSheetExport.pngData(plain).flatMap(UIImage.init(data:)))
        let b = try #require(KineSheetExport.pngData(withLevel).flatMap(UIImage.init(data:)))
        #expect(b.size.height > a.size.height)  // fila "Nivel" en la cabecera y dos filas en la tabla

        let pdf = try #require(KineSheetExport.pdfData(withLevel))
        let document = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
        var title: CGPDFStringRef?
        if let info = document.info, CGPDFDictionaryGetString(info, "Title", &title), let title {
            #expect(CGPDFStringCopyTextString(title) as String? == "Reporte de Salud - Marco")
        } else {
            Issue.record("El PDF no trae título")
        }
    }
}
