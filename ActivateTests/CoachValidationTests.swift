import Testing
import Foundation
@testable import Activate

struct CoachValidationTests {
    // MARK: - Fixtures

    private func recipe(_ kind: RecipeKind = .campamento5) -> Recipe {
        func a(_ k: ActivityKind) -> ActivityAssignment { ActivityAssignment(kind: k, target: k.defaultTarget) }
        switch kind {
        case .relevo60: return Recipe(kind: kind, activities: [a(.cuello), a(.ojos)])
        case .colacion3: return Recipe(kind: kind, activities: [a(.pasos), a(.cuello), a(.ojos)])
        case .campamento5: return Recipe(kind: kind, activities: [a(.pasos), a(.sentadilla), a(.cuello), a(.stroop), a(.ojos), a(.extensionLumbar)])
        }
    }

    private func checkIn(score: Int, bending: Bool = false) -> DailyCheckIn {
        var answers = Array(repeating: false, count: RDQ6.items.count)
        for i in 0..<min(score, answers.count) { answers[i] = true }
        if bending { answers[RDQ6.itemAvoidsBending] = true }
        return DailyCheckIn(date: .now, workDayKey: "2026-10-23", turnoKey: "2026-10-19", source: .pausa,
                            answers: answers, zone: .lumbar, moment: .campamento, context: nil)
    }

    private func input(moment: Moment = .campamento, allowed: [ActivityKind] = ActivityKind.sessionOrder,
                       gentle: Bool = false, score: Int = 2, treatment: Treatment = .usted) -> CoachInput {
        let r = recipe(moment.recipe)
        return CoachInput(profileName: "Marco", treatment: treatment, checkIn: checkIn(score: score), moment: moment,
                          minutesAvailable: moment.minutes, baseRecipe: r, allowedKinds: allowed,
                          historyLines: ["Ayer: Mejor", "Antes de ayer: Igual"], gentle: gentle)
    }

    private func turno(_ key: String, label: String, mean: Double?, better: Int = 0, same: Int = 0, worse: Int = 0,
                       daysWithPause: Int = 4, workDays: Int = 7) -> TurnoSummary {
        TurnoSummary(turnoKey: key, label: label, workDays: workDays, daysWithPause: daysWithPause, countedPauses: daysWithPause,
                     meanRDQ: mean, maxRDQ: mean.map { Int($0.rounded(.up)) }, itemFrequency: [3, 0, 1, 4, 2, 0],
                     betterCount: better, sameCount: same, worseCount: worse, verifiedSteps: 1200, verifiedReps: 40,
                     maxStreak: 3, stroopMedianRTms: 640, blinksPerMinute: 12, neckMaxYaw: 55)
    }

    private func summary(current: Double? = 2.0, previous: Double? = 4.0) -> StatsSummary {
        let prev = previous.map { turno("2026-10-05", label: "Turno 5-11 oct", mean: $0, better: 3, same: 2, worse: 1) }
        let cur = current.map { turno("2026-10-19", label: "Turno 19-25 oct", mean: $0, better: 7, same: 1, worse: 0) }
        let days = (1...5).map { DayStat(workDayKey: "d\($0)", dayInBlock: $0, rdq: $0 == 3 ? 5 : 2, countedPauses: 1, cascoUsed: false, isToday: $0 == 5) }
        return StatsSummary(currentTurno: cur, previousTurno: prev, turnos: [prev, cur].compactMap { $0 },
                            streak: 4, totalCountedPauses: 11, todayRDQ: 2, recentSessions: [],
                            worsensHints: ["Le duele más al bajar del camión"], historyLines: ["Ayer: Mejor"],
                            currentTurnoDays: days)
    }

    // MARK: - PlanValidator

    @Test func catalogIdsMatchActivityKind() {
        #expect(CatalogIDs.all == ActivityKind.allCases.map(\.rawValue))
    }

    @Test func validProposalPasses() {
        let i = input()
        let r = PlanValidator.validate([.init(id: "A2", reps: 200), .init(id: "A5", reps: 12), .init(id: "A9", reps: 15)], input: i)
        guard case .success(let plan) = r else { Issue.record("Debía pasar: \(r)"); return }
        #expect(plan.map(\.kind) == [.pasos, .cuello, .ojos])
        #expect(plan[0].target == 200)
    }

    @Test func unknownIdFails() {
        let r = PlanValidator.validate([.init(id: "A4", reps: 10)], input: input())
        #expect(r == .failure(.unknownID("A4")))
    }

    @Test func notAllowedIdFails() {
        let i = input(allowed: Recipes.gentleKinds)
        let r = PlanValidator.validate([.init(id: "A3", reps: 5)], input: i)
        #expect(r == .failure(.notAllowed(.sentadilla)))
    }

    @Test func duplicateFails() {
        let r = PlanValidator.validate([.init(id: "A5", reps: 10), .init(id: "A5", reps: 10)], input: input())
        #expect(r == .failure(.duplicate(.cuello)))
    }

    @Test func repsOutOfRangeFails() {
        let r = PlanValidator.validate([.init(id: "A3", reps: 21)], input: input())
        #expect(r == .failure(.repsOutOfRange(.sentadilla, reps: 21, max: 20)))
        let zero = PlanValidator.validate([.init(id: "A3", reps: 0)], input: input())
        #expect(zero == .failure(.repsOutOfRange(.sentadilla, reps: 0, max: 20)))
    }

    @Test func durationExceededFails() {
        // Pausa rápida de 1 minuto: 15 cuello + 15 ojos + Stroop (60 s) = 90 s > 60 s.
        var i = input(moment: .entrada)
        i.minutesAvailable = RecipeKind.relevo60.minutes
        let r = PlanValidator.validate([.init(id: "A5", reps: 15), .init(id: "A9", reps: 15), .init(id: "A10", reps: 40)], input: i)
        #expect(r == .failure(.durationExceeded(estimatedSeconds: 90, limitSeconds: 60)))
    }

    @Test func emptyAndTooManyFail() {
        #expect(PlanValidator.validate([], input: input()) == .failure(.empty))
        let six = ["A1", "A2", "A3", "A5", "A9", "A10"].map { ProposedExercise(id: $0, reps: 1) }
        #expect(PlanValidator.validate(six, input: input()) == .failure(.tooMany(6)))
    }

    @Test func baseRecipesAlwaysFitTheirMinutes() {
        for kind in RecipeKind.allCases {
            let r = recipe(kind)
            #expect(PlanValidator.estimatedSeconds(r.activities) <= kind.minutes * 60, "\(kind)")
        }
    }

    @Test func fallbackFiltersByAllowed() {
        let i = input(allowed: Recipes.gentleKinds)
        #expect(PlanValidator.fallback(i).map(\.kind) == [.pasos, .cuello, .ojos])
    }

    @Test func retiredBreathingIsNeverAllowed() {
        // Respiración (A8) sigue en el catálogo para leer sesiones antiguas, pero las reglas no la permiten.
        let r = PlanValidator.validate([.init(id: "A8", reps: 3)], input: input())
        #expect(r == .failure(.notAllowed(.respiracion)))
    }

    // MARK: - Texto

    @Test func textCleaningClampsAndBans() {
        #expect(CoachText.clean("  Vamos, Marco. Un minuto.  ", maxWords: 8) == "Vamos, Marco. Un minuto.")
        #expect(CoachText.clean("", maxWords: 8) == nil)
        #expect(CoachText.clean("Eso es trampa", maxWords: 8) == nil)
        #expect(CoachText.clean("Usted está apto para la pausa", maxWords: 8) == nil)
        let long = CoachText.clean("uno dos tres cuatro cinco seis siete ocho nueve diez", maxWords: 8)
        #expect(long == "uno dos tres cuatro cinco seis siete ocho.")
    }

    // MARK: - Prompts

    @Test func instructionsStartAndEndWithLiteralSentences() {
        #expect(CoachPrompts.instructions.hasPrefix("The person's locale is es_CL."))
        #expect(CoachPrompts.instructions.hasSuffix("Responde SIEMPRE en español de Chile, de usted, en frases cortas. No diagnostiques, no recomiendes fármacos, no inventes cifras: usa solo las que recibes."))
        #expect(CoachPrompts.version == "pausa-del-dia-v1")
    }

    @Test func planPromptCarriesRdqAllowedIdsAndRecipe() {
        let i = input(allowed: Recipes.gentleKinds, gentle: true, score: 5)
        let p = CoachPrompts.planPrompt(i)
        #expect(p.contains("5 de 6"))
        #expect(p.contains("\"\(RDQ6.items[0])\""))
        #expect(p.contains("Ids permitidos hoy: A2, A5, A9."))
        #expect(p.contains("A5 · Movilidad cervical · 15 movimientos"))
        #expect(p.contains("A3 · Sentadilla minera · 10 reps"))
        #expect(p.contains("Campamento"))
        #expect(p.contains("pausa-del-dia-v1"))
        #expect(p.contains("Ayer: Mejor"))
    }

    // MARK: - RuleBasedCoach

    @Test func rulePlanHasTheSameShapeAsTheModel() async throws {
        let i = input(moment: .colacion)
        let plan = try await RuleBasedCoach().plan(i)
        #expect(plan.backend == .rules)
        #expect(plan.activities == i.baseRecipe.activities)
        #expect(!plan.why.isEmpty && CoachText.wordCount(plan.why) <= 8)
        #expect(!plan.startMessage.isEmpty && CoachText.wordCount(plan.startMessage) <= 8)
        #expect(plan.startMessage.contains("Marco"))
        #expect(!plan.reasoning.isEmpty)
        for banned in ["trampa", "apto"] {
            #expect(!plan.why.lowercased().contains(banned) && !plan.startMessage.lowercased().contains(banned))
        }
    }

    @Test func rulePlanIsGentleAndDropsForbiddenKinds() async throws {
        let i = input(allowed: Recipes.gentleKinds, gentle: true, score: 5)
        let plan = try await RuleBasedCoach().plan(i)
        #expect(plan.activities.map(\.kind) == [.pasos, .cuello, .ojos])
        #expect(!plan.activities.contains { $0.kind == .sentadilla })
        let steps = plan.activities.first { $0.kind == .pasos }!.target
        #expect(steps == Int((Double(ActivityKind.pasos.defaultTarget) * RuleBasedCoach.gentleTargetFactor).rounded()))
        #expect(plan.why == "Hoy sin sentadilla: espalda cargada." || plan.why.lowercased().contains("sentadilla"))
        #expect(plan.activities.allSatisfy { $0.target >= 1 })
        #expect(PlanValidator.estimatedSeconds(plan.activities) <= i.minutesAvailable * 60)
    }

    @Test func rulePlanIsDeterministicForTheSameInput() {
        let i = input()
        #expect(RuleBasedCoach.makePlan(i) == RuleBasedCoach.makePlan(i))
    }

    @Test func ruleReadingHasThreeSentencesAndTrend() async throws {
        let profile = PlayerProfile(rosterStart: .now)
        let r = try await RuleBasedCoach().statsReading(summary(), profile: profile)
        #expect(r.sentences.count == 3)
        #expect(r.backend == .rules)
        #expect(r.trend == .mejorando)
        #expect(r.sentences[0].contains("4 de 5"))
        #expect(r.sentences[1].contains("2 de 6"))
        #expect(r.sentences[2].contains("7 de 8"))
        #expect(RuleBasedCoach.trend(summary(current: 4.2, previous: 4.0)) == .estable)
        #expect(RuleBasedCoach.trend(summary(current: 5.0, previous: 3.0)) == .empeorando)
        #expect(RuleBasedCoach.trend(summary(current: 2.0, previous: nil)) == .sinDatos)
    }

    @Test func ruleReadingWithoutDataStillAnswers() async throws {
        let empty = StatsSummary(currentTurno: nil, previousTurno: nil, turnos: [], streak: 0, totalCountedPauses: 0,
                                 todayRDQ: nil, recentSessions: [], worsensHints: [], historyLines: [], currentTurnoDays: [])
        let r = try await RuleBasedCoach().statsReading(empty, profile: PlayerProfile(rosterStart: .now))
        #expect(r.sentences.count == 3 && r.sentences.allSatisfy { !$0.isEmpty })
        #expect(r.trend == .sinDatos)
        let k = try await RuleBasedCoach().kineConsult([], profile: PlayerProfile(rosterStart: .now))
        #expect(k.findings.isEmpty)
        #expect(k.questions.count == 3 && k.questions.allSatisfy { $0.hasPrefix("¿") && $0.hasSuffix("?") })
        #expect(!k.focus.isEmpty)
        #expect(k.backend == .rules)
    }

    // MARK: - Consulta con el kine (plantilla y validación)

    private func fact(_ id: KineFactID, value: String = "3 de 6", detail: String? = nil) -> KineFact {
        KineFact(id: id.rawValue, title: "Título \(id.rawValue)", value: value,
                 detail: detail ?? "Detalle de \(id.rawValue) con \(value).",
                 question: "¿Pregunta de \(id.rawValue)?", focus: "Foco de \(id.rawValue).")
    }

    private var kineFacts: [KineFact] {
        [fact(.rdqTendencia, value: "4,0 → 3,6 → 3,0"), fact(.peorFaseTurno, value: "Día 5: 6,0 de 6"),
         fact(.contextoDominante, value: "Al bajar · 2 de 4"), fact(.mejoraPost, value: "7 de 9 pausas")]
    }

    @Test func kineInstructionsStartWithLocaleAndVersion() {
        #expect(CoachPrompts.kineInstructions.hasPrefix("The person's locale is es_CL."))
        #expect(CoachPrompts.noteInstructions.hasPrefix("The person's locale is es_CL."))
        #expect(CoachPrompts.kineVersion == "consulta-kine-v1")
        let p = CoachPrompts.kineConsultPrompt(kineFacts, profile: PlayerProfile(rosterStart: .now))
        #expect(p.contains("consulta-kine-v1"))
        #expect(p.contains("[rdq_tendencia] Título rdq_tendencia. Cifra: 4,0 → 3,6 → 3,0."))
        #expect(p.contains("pregunta sugerida: ¿Pregunta de rdq_tendencia?"))
        #expect(p.contains("Ids válidos: rdq_tendencia, peor_fase_turno, contexto_dominante, mejora_post."))
        #expect(p.contains("espalda baja"))
    }

    @Test func planPromptListsAllMarkedZones() {
        var i = input()
        #expect(CoachPrompts.planPrompt(i).contains("Zona que duele hoy: espalda baja."))
        i.checkIn?.setZones([.cuello, .lumbar])
        #expect(CoachPrompts.planPrompt(i).contains("Zonas que duelen hoy: espalda baja y cuello."))
    }

    @Test func notePromptDelimitsTheUserText() {
        let long = String(repeating: "a", count: 400)
        let p = CoachPrompts.notePrompt("Me duele \"\"\"cuello\"\"\" " + long)
        #expect(p.contains("nota-paciente-v1"))
        #expect(!p.contains("\"\"\"cuello"))
        #expect(p.count < 400 + 600)
    }

    @Test func ruleConsultTakesTheFirstThreeFacts() async throws {
        let k = try await RuleBasedCoach().kineConsult(kineFacts, profile: PlayerProfile(rosterStart: .now))
        #expect(k.backend == .rules)
        #expect(k.findings.map(\.factID) == ["rdq_tendencia", "peor_fase_turno", "contexto_dominante"])
        #expect(k.findings[0].sentence == kineFacts[0].detail)
        #expect(k.questions == ["¿Pregunta de rdq_tendencia?", "¿Pregunta de peor_fase_turno?", "¿Pregunta de contexto_dominante?"])
        #expect(k.focus == "Foco de rdq_tendencia.")
        // Con un solo hecho, las preguntas se completan con las genéricas.
        let one = KineConsultRules.template([kineFacts[0]], profile: PlayerProfile(rosterStart: .now))
        #expect(one.findings.count == 1 && one.questions.count == 3)
        #expect(one.questions[1] == KineConsultRules.genericQuestions[0])
    }

    private func proposal(_ ids: [String], sentences: [String]? = nil, questions: [String]? = nil,
                          focus: String = "Trabajar cómo bajar del camión sin cargar la espalda.") -> KineConsultRules.Proposal {
        let s = sentences ?? ids.map { _ in "El paciente nota que esto le pesa en el turno." }
        return KineConsultRules.Proposal(findings: zip(ids, s).map { KineFinding(factID: $0.0, sentence: $0.1) },
                                         questions: questions ?? ["¿Qué hago cuando me duele al bajar del camión?",
                                                                  "¿Cómo llego mejor al final del turno?",
                                                                  "¿Sigo con los mismos ejercicios?"],
                                         focus: focus)
    }

    @Test func consultValidationAcceptsKnownDistinctIds() {
        let r = KineConsultRules.validate(proposal(["contexto_dominante", "rdq_tendencia", "mejora_post"]),
                                          facts: kineFacts, profile: PlayerProfile(rosterStart: .now))
        guard case .success(let k) = r else { Issue.record("Debía pasar: \(r)"); return }
        #expect(k.backend == .foundationModels)
        #expect(k.findings.map(\.factID) == ["contexto_dominante", "rdq_tendencia", "mejora_post"])
        #expect(k.questions.count == 3)
        #expect(k.focus == "Trabajar cómo bajar del camión sin cargar la espalda.")
    }

    @Test func consultValidationRejectsUnknownOrRepeatedIds() {
        let profile = PlayerProfile(rosterStart: .now)
        #expect(KineConsultRules.validate(proposal(["alertas", "rdq_tendencia", "mejora_post"]), facts: kineFacts, profile: profile)
                == .failure(.unknownFact("alertas")))
        #expect(KineConsultRules.validate(proposal(["rdq_tendencia", "rdq_tendencia", "rdq_tendencia"]), facts: kineFacts, profile: profile)
                == .failure(.duplicateFact("rdq_tendencia")))
        // Un solo repetido: su lugar lo toma el hecho más prioritario que falte, con frase y pregunta de plantilla.
        let repaired = KineConsultRules.validate(proposal(["rdq_tendencia", "rdq_tendencia", "mejora_post"]), facts: kineFacts, profile: profile)
        guard case .success(let fixed) = repaired else { Issue.record("Debía repararse: \(repaired)"); return }
        #expect(fixed.findings.map(\.factID) == ["rdq_tendencia", "peor_fase_turno", "mejora_post"])
        #expect(fixed.findings[1].sentence == kineFacts[1].detail)
        #expect(fixed.questions[1] == "¿Pregunta de peor_fase_turno?")
        #expect(KineConsultRules.validate(proposal(["rdq_tendencia", "mejora_post"]), facts: kineFacts, profile: profile)
                == .failure(.wrongCount(2)))
        #expect(KineConsultRules.validate(proposal(["rdq_tendencia"]), facts: [], profile: profile) == .failure(.noFacts))
        // Con menos de 3 hechos el modelo está obligado a repetir: se descartan los repetidos.
        let two = Array(kineFacts.prefix(2))
        let r = KineConsultRules.validate(proposal(["rdq_tendencia", "peor_fase_turno", "rdq_tendencia"]), facts: two, profile: profile)
        guard case .success(let k) = r else { Issue.record("Debía pasar: \(r)"); return }
        #expect(k.findings.map(\.factID) == ["rdq_tendencia", "peor_fase_turno"])
    }

    @Test func consultValidationRepairsInventedNumbersDiagnosesAndThirdPersonQuestions() {
        let profile = PlayerProfile(rosterStart: .now)
        let sentences = [
            "El dolor bajó de 4,0 a 3,0 entre turnos.",           // cifras del hecho: se aceptan
            "El día 9 del turno es el peor.",                      // 9 no está en el hecho: plantilla
            "Podría ser una hernia lumbar por la vibración.",      // diagnóstico: plantilla
        ]
        let questions = ["¿Qué ejercicios puede hacer Marco en la cabina?",  // nombre: plantilla
                         "Cómo bajo del camión sin dolor",                    // sin signos: se agregan
                         "¿Me sirve el ibuprofeno?"]                          // fármaco: plantilla
        let r = KineConsultRules.validate(proposal(["rdq_tendencia", "peor_fase_turno", "contexto_dominante"],
                                                   sentences: sentences, questions: questions,
                                                   focus: "Bajar el dolor a 1 de 6 en 15 días."),
                                          facts: kineFacts, profile: profile)
        guard case .success(let k) = r else { Issue.record("Debía pasar: \(r)"); return }
        #expect(k.findings[0].sentence == "El dolor bajó de 4,0 a 3,0 entre turnos.")
        #expect(k.findings[1].sentence == kineFacts[1].detail)
        #expect(k.findings[2].sentence == kineFacts[2].detail)
        // Cada pregunta va con su hallazgo: las inválidas se cambian por la pregunta de plantilla de ese hecho.
        #expect(k.questions == ["¿Pregunta de rdq_tendencia?", "¿Cómo bajo del camión sin dolor?", "¿Pregunta de contexto_dominante?"])
        #expect(!k.questions.contains { $0.contains("Marco") || $0.contains("ibuprofeno") })
        #expect(k.focus == "Foco de rdq_tendencia.")
    }

    @Test func questionsMustBeFirstPersonAndWhole() {
        let profile = PlayerProfile(rosterStart: .now)
        let corpus = "12 horas"
        #expect(KineConsultRules.cleanQuestion("¿Qué hago cuando me duele?", corpus: corpus, profile: profile) == "¿Qué hago cuando me duele?")
        #expect(KineConsultRules.cleanQuestion("La pausa me ayuda, ¿qué más hago?", corpus: corpus, profile: profile) == "La pausa me ayuda, ¿qué más hago?")
        #expect(KineConsultRules.cleanQuestion("¿Qué ejercicio le conviene hacer ahora?", corpus: corpus, profile: profile) == nil)
        #expect(KineConsultRules.cleanQuestion("¿Cómo debe moverse para aliviar el dolor?", corpus: corpus, profile: profile) == nil)
        #expect(KineConsultRules.cleanQuestion("¿Me conviene caminar más en los turnos de 12 horas?", corpus: corpus, profile: profile) != nil)
        let long = "¿" + Array(repeating: "puedo", count: 19).joined(separator: " ") + "?"
        #expect(KineConsultRules.cleanQuestion(long, corpus: corpus, profile: profile) == nil)
    }

    @Test func alarmFactIsAlwaysAFinding() {
        var facts = kineFacts
        var alarm = fact(.alertas, value: "1 respuesta de alarma")
        alarm.mustInclude = true
        facts.insert(alarm, at: 0)
        let r = KineConsultRules.validate(proposal(["rdq_tendencia", "contexto_dominante", "mejora_post"]),
                                          facts: facts, profile: PlayerProfile(rosterStart: .now))
        guard case .success(let k) = r else { Issue.record("Debía pasar: \(r)"); return }
        #expect(k.findings.map(\.factID) == ["rdq_tendencia", "contexto_dominante", "alertas"])
        #expect(k.questions.contains("¿Pregunta de alertas?"))
        #expect(KineConsultRules.template(facts, profile: PlayerProfile(rosterStart: .now)).findings.first?.factID == "alertas")
        #expect(CoachPrompts.kineConsultPrompt(facts, profile: PlayerProfile(rosterStart: .now)).contains("obligatorio"))
    }

    @Test func findingsDescribeWithoutJudging() {
        let f = fact(.alertas, value: "2 días con RDQ 5 o más")
        #expect(KineConsultRules.cleanFinding("Tuvo días de dolor alto.", fact: f) == "Tuvo días de dolor alto.")
        #expect(KineConsultRules.cleanFinding("Experimenta días con dolor intenso que requieren atención especial.", fact: f) == nil)
        #expect(KineConsultRules.cleanFinding("Es un riesgo para su trabajo.", fact: f) == nil)
    }

    @Test func numbersInTextAreParsedLikeTheSheet() {
        #expect(KineConsultRules.numbers(in: "Bajó de 4,0 a 3,6; 2.400 pasos y 80 %.") == ["4,0", "3,6", "2400", "80"])
        #expect(KineConsultRules.numbersAreGrounded("Caminó 2400 pasos", in: "2.400 pasos verificados"))
        #expect(!KineConsultRules.numbersAreGrounded("Subió 2 puntos", in: "subió 0,6 puntos"))
        #expect(KineConsultRules.numbersAreGrounded("Sin cifras.", in: ""))
        // Escritas con letras también cuentan: "dos de cada seis" no está en "9 de 16".
        #expect(!KineConsultRules.numbersAreGrounded("Solo en dos de cada seis turnos.", in: "9 de 16 días"))
        #expect(KineConsultRules.numbersAreGrounded("El quinto día es el peor.", in: "Día 5: 6,0 de 6"))
    }

    @Test func noteValidationKeepsOnlyMentionedZonesAndMoments() {
        let text = "Me duele la espalda al bajar del camión y en la noche me cuesta dormir."
        let n = KineConsultRules.validateNote(summary: "El paciente cuenta que le duele la espalda al bajar del camión.",
                                              zones: ["lumbar", "cuello", "nada"], moments: ["campamento", "salida", "colacion"],
                                              original: text)
        #expect(n.backend == .foundationModels)
        #expect(n.zones == [.lumbar])
        #expect(n.moments == [.salida, .campamento])
        #expect(n.original == text)
        let bad = KineConsultRules.validateNote(summary: "Es apto para trabajar 12 días.", zones: [], moments: [], original: "Me duele.")
        #expect(bad.summary.isEmpty && bad.backend == .rules)
        let raw = KineConsultRules.noteTemplate("  " + String(repeating: "x", count: 300))
        #expect(raw.original.count == PatientNote.maxCharacters && raw.summary.isEmpty && raw.backend == .rules)
    }

    #if canImport(FoundationModels)
    @Test func hallazgoGuideListsExactlyTheFactIds() throws {
        let json = String(decoding: try JSONEncoder().encode(Hallazgo.generationSchema), as: UTF8.self)
        for id in KineFactID.all { #expect(json.contains("\"\(id)\""), "falta \(id) en el @Guide") }
        #expect(KineFactID.all.count == 8)
        let note = String(decoding: try JSONEncoder().encode(NotaPaciente.generationSchema), as: UTF8.self)
        for z in PainZone.allCases { #expect(note.contains("\"\(z.rawValue)\"")) }
        for m in Moment.allCases { #expect(note.contains("\"\(m.rawValue)\"")) }
    }
    #endif

    // MARK: - CoachService (siempre responde; en el simulador de CI cae a reglas)

    @Test @MainActor func serviceAlwaysAnswers() async {
        let service = CoachService()
        service.refreshAvailability()
        service.override = .rules
        #expect(service.backend == .rules)
        let plan = await service.plan(input())
        #expect(plan.backend == .rules)
        #expect(!plan.activities.isEmpty)
        #expect(service.lastLatencyMs != nil)
        let reading = await service.statsReading(summary(), profile: PlayerProfile(rosterStart: .now))
        #expect(reading.sentences.count == 3)
        #expect(!service.kineModelReady)
        #expect(service.kineUnavailableReason != nil)
        var partials = 0
        let consult = await service.kineConsult(kineFacts, profile: PlayerProfile(rosterStart: .now)) { _ in partials += 1 }
        #expect(consult.backend == .rules && consult.findings.count == 3 && partials == 0)
        let note = await service.patientNote("Me duele el cuello.", profile: PlayerProfile(rosterStart: .now))
        #expect(note.original == "Me duele el cuello." && note.summary.isEmpty)
    }

    @Test @MainActor func overrideAiFallsBackWhenUnavailable() {
        let service = CoachService()
        service.refreshAvailability()
        service.override = .ai
        if service.availability == .available || service.availability == .localeUnsupported {
            #expect(service.backend == .foundationModels)
        } else {
            #expect(service.backend == .rules)
        }
        service.override = .rules
        #expect(service.backend == .rules)
    }
}
