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
        case .campamento5: return Recipe(kind: kind, activities: [a(.pasos), a(.sentadilla), a(.extensionLumbar), a(.cuello), a(.ojos), a(.stroop), a(.respiracion)])
        }
    }

    private func checkIn(score: Int, bending: Bool = false) -> DailyCheckIn {
        var answers = Array(repeating: false, count: RDQ6.items.count)
        for i in 0..<min(score, answers.count) { answers[i] = true }
        if bending { answers[RDQ6.itemAvoidsBending] = true }
        return DailyCheckIn(date: .now, workDayKey: "2026-10-23", turnoKey: "2026-10-19", source: .pausa,
                            answers: answers, zone: .lumbar, moment: .campamento, context: nil)
    }

    private func input(moment: Moment = .campamento, allowed: [ActivityKind] = ActivityKind.allCases,
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
        let i = input(allowed: [.pasos, .cuello, .respiracion])
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
        // Relevo de 1 minuto: 15 cuello + 15 ojos + Stroop (60 s) = 90 s > 60 s.
        let i = input(moment: .entrada)
        let r = PlanValidator.validate([.init(id: "A5", reps: 15), .init(id: "A9", reps: 15), .init(id: "A10", reps: 40)], input: i)
        #expect(r == .failure(.durationExceeded(estimatedSeconds: 90, limitSeconds: 60)))
    }

    @Test func emptyAndTooManyFail() {
        #expect(PlanValidator.validate([], input: input()) == .failure(.empty))
        let six = ["A1", "A2", "A3", "A5", "A8", "A9"].map { ProposedExercise(id: $0, reps: 1) }
        #expect(PlanValidator.validate(six, input: input()) == .failure(.tooMany(6)))
    }

    @Test func baseRecipesAlwaysFitTheirMinutes() {
        for kind in RecipeKind.allCases {
            let r = recipe(kind)
            #expect(PlanValidator.estimatedSeconds(r.activities) <= kind.minutes * 60, "\(kind)")
        }
    }

    @Test func fallbackFiltersByAllowed() {
        let i = input(allowed: [.pasos, .cuello, .respiracion])
        #expect(PlanValidator.fallback(i).map(\.kind) == [.pasos, .cuello, .respiracion])
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
        let i = input(allowed: [.pasos, .cuello, .respiracion], gentle: true, score: 5)
        let p = CoachPrompts.planPrompt(i)
        #expect(p.contains("5 de 6"))
        #expect(p.contains("\"\(RDQ6.items[0])\""))
        #expect(p.contains("Ids permitidos hoy: A2, A5, A8."))
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
        let i = input(allowed: [.pasos, .cuello, .respiracion], gentle: true, score: 5)
        let plan = try await RuleBasedCoach().plan(i)
        #expect(plan.activities.map(\.kind) == [.pasos, .cuello, .respiracion])
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
        let k = try await RuleBasedCoach().kineSheet(empty, profile: PlayerProfile(rosterStart: .now))
        #expect(!k.period.isEmpty && !k.whenItHurts.isEmpty && !k.whatHeDid.isEmpty && !k.whatWorsens.isEmpty && !k.howItGoes.isEmpty && !k.alerts.isEmpty)
    }

    @Test func ruleKineSheetCarriesTheFigures() async throws {
        let k = try await RuleBasedCoach().kineSheet(summary(), profile: PlayerProfile(rosterStart: .now))
        #expect(k.backend == .rules)
        #expect(k.period == "Turno 5-11 oct – Turno 19-25 oct")
        #expect(k.whenItHurts.contains("día 3"))
        #expect(k.whatHeDid.contains("2.400"))
        #expect(k.whatWorsens.contains("Le duele más al bajar del camión"))
        #expect(k.whatWorsens.contains(RDQ6.items[RDQ6.itemAvoidsBending]))
        #expect(k.howItGoes.contains("4,0 → 2,0"))
        #expect(k.howItGoes.contains("10 de 14"))
        #expect(k.alerts.contains("plan suave"))
    }

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
