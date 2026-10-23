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

    @Test func ningunMomentoDescartaPorFaltaDeTiempo() {
        // No hay pausa rápida: sin molestias, todo momento hace la ruta completa y no descarta nada.
        for moment in Moment.allCases {
            #expect(explain(moment.recipe, checkIn(Array(repeating: false, count: 6))).isEmpty, "\(moment)")
        }
        // La receta antigua (`relevo60`) tampoco recorta: pedirla arma la ruta completa.
        #expect(explain(.relevo60, checkIn(Array(repeating: false, count: 6))).isEmpty)
        // Ninguna razón habla de minutos.
        for answers in [[false, false, false, true, false, false], [true, true, true, true, true, false]] {
            #expect(explain(.campamento5, checkIn(answers)).allSatisfy { !$0.reason.lowercased().contains("minuto") })
        }
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

    @Test func pararseYSentarseQuedaFueraConSuRazon() {
        // Evita agacharse: misma razón que la sentadilla.
        let bending = explain(.campamento5, checkIn([false, false, false, true, false, false]))
        #expect(bending.first { $0.kind == .pararseSentarse }?.reason == PlanExclusions.avoidsBending)
        // Plan suave.
        let gentle = explain(.campamento5, checkIn([true, true, true, true, true, false]))
        #expect(gentle.first { $0.kind == .pararseSentarse }?.reason == PlanExclusions.gentle)
        // Sin consentimiento de cámara (la segunda barrera del coordinador la saca del plan).
        let c = checkIn(Array(repeating: false, count: 6))
        let d = SafetyRules.evaluate(checkIn: c)
        let base = Recipes.base(.campamento5, demo: false)
        let filtered = PauseCoordinator.consentFiltered(SafetyRules.apply(d, to: base, demo: false), consentGiven: false,
                                                        allowed: d.allowed, demo: false)
        let noConsent = PlanExclusions.explain(recipe: .campamento5, decision: d, checkIn: c, consentGiven: false,
                                               baseKinds: base.kinds, planKinds: filtered.kinds)
        #expect(noConsent.first { $0.kind == .pararseSentarse }?.reason == PlanExclusions.noConsent)
        // Toda exclusión trae su razón y va en el orden fijo.
        for ex in [bending, gentle, noConsent] {
            #expect(ex.allSatisfy { !$0.reason.isEmpty })
            #expect(ex.map(\.kind) == ActivityKind.inSessionOrder(ex.map(\.kind), kind: { $0 }))
        }
    }

    @Test func campamentoCompletoNoDescartaNada() {
        #expect(explain(.campamento5, checkIn(Array(repeating: false, count: 6))).isEmpty)
    }
}
