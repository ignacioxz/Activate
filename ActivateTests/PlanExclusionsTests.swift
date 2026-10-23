import Testing
import Foundation
@testable import Activate

struct PlanExclusionsTests {
    private func checkIn(_ answers: [Bool]) -> DailyCheckIn {
        DailyCheckIn(date: .now, workDayKey: "2026-10-23", turnoKey: "2026-10-22", source: .pausa, answers: answers, zone: .lumbar)
    }
    private func explain(_ recipe: RecipeKind, _ c: DailyCheckIn?, consent: Bool = true) -> [PlanExclusion] {
        let d = SafetyRules.evaluate(checkIn: c)
        let base = Recipes.base(recipe, demo: false)
        let plan = SafetyRules.apply(d, to: base, demo: false).activities.map(\.kind)
        return PlanExclusions.explain(recipe: recipe, decision: d, checkIn: c, consentGiven: consent,
                                      baseKinds: base.activities.map(\.kind), planKinds: plan)
    }

    @Test func relevoExplicaQueNoCabe() {
        let ex = explain(.relevo60, checkIn(Array(repeating: false, count: 6)))
        #expect(!ex.isEmpty)
        #expect(ex.allSatisfy { $0.reason == PlanExclusions.relevo })
        #expect(ex.map(\.kind) == ActivityKind.inSessionOrder(ex.map(\.kind), kind: { $0 }))
    }

    @Test func evitaAgacharseExplicaLaSentadilla() {
        let ex = explain(.campamento5, checkIn([false, false, false, true, false, false]))
        #expect(ex.first { $0.kind == .sentadilla }?.reason == PlanExclusions.avoidsBending)
        #expect(ex.first { $0.kind == .extensionLumbar }?.reason == PlanExclusions.avoidsBending)
    }

    @Test func planSuaveLoDice() {
        let ex = explain(.campamento5, checkIn([true, true, true, true, true, false]))
        #expect(ex.contains { $0.reason == PlanExclusions.gentle })
    }

    @Test func campamentoCompletoNoDescartaNada() {
        #expect(explain(.campamento5, checkIn(Array(repeating: false, count: 6))).isEmpty)
    }
}
