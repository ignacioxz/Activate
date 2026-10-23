import Testing
import Foundation
@testable import Activate

// MARK: - Helpers

private func checkIn(answers: [Bool] = Array(repeating: false, count: 6), alarm: [Bool] = [], source: CheckInSource = .pausa) -> DailyCheckIn {
    DailyCheckIn(date: Date(timeIntervalSince1970: 1_792_000_000), workDayKey: "2026-10-13", turnoKey: "2026-10-12",
                 source: source, answers: answers, alarmAnswers: alarm, zone: .lumbar)
}

private func answers(yes: Set<Int>) -> [Bool] {
    (0..<RDQ6.items.count).map { yes.contains($0) }
}

private func kinds(_ recipe: Recipe) -> [ActivityKind] { recipe.activities.map(\.kind) }

private func target(_ recipe: Recipe, _ kind: ActivityKind) -> Int? {
    recipe.activities.first { $0.kind == kind }?.target
}

// MARK: - SafetyRules

struct SafetyRulesTests {
    @Test func sinCheckInTodoPermitido() {
        let d = SafetyRules.evaluate(checkIn: nil)
        #expect(d.allowed == ActivityKind.allCases)
        #expect(!d.gentle && !d.stop && d.reason == nil)
        #expect(d.stepTargetFactor == 1 && !d.shorterActivities && !d.adjusted)
        let recipe = Recipes.base(.campamento5, demo: false)
        #expect(SafetyRules.apply(d, to: recipe) == recipe)
    }

    @Test func checkInSinSintomasNoCambiaNada() {
        let d = SafetyRules.evaluate(checkIn: checkIn())
        #expect(d.allowed == ActivityKind.allCases && !d.gentle && !d.stop && !d.adjusted)
    }

    @Test func meDueleAhoraSinRespuestasNoRestringe() {
        let d = SafetyRules.evaluate(checkIn: checkIn(answers: [], source: .meDueleAhora))
        #expect(d.allowed == ActivityKind.allCases && !d.gentle && !d.stop)
    }

    @Test func alarmaDetieneTodo() {
        let d = SafetyRules.evaluate(checkIn: checkIn(alarm: [false, true, false]))
        #expect(d.stop)
        #expect(d.reason == SafetyRules.stopReason)
        #expect(d.reason == "cuándo parar")
        #expect(d.allowed.isEmpty)
        let applied = SafetyRules.apply(d, to: Recipes.base(.campamento5, demo: false))
        #expect(applied.activities.isEmpty && applied.kind == .campamento5)
    }

    @Test func alarmaGanaAunqueElPuntajeSeaBajo() {
        let d = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: []), alarm: [true, false, false]))
        #expect(d.stop && !d.gentle)
    }

    @Test func puntajeAltoDaPlanSuave() {
        let d = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: [0, 1, 2, 3, 5])))
        #expect(d.gentle && !d.stop)
        #expect(d.allowed == Recipes.gentleKinds)
        #expect(d.stepTargetFactor == SafetyRules.reducedStepFactor)
        #expect(d.reason == SafetyRules.Copy.gentleWhy)
        let applied = SafetyRules.apply(d, to: Recipes.base(.campamento5, demo: false))
        #expect(kinds(applied) == [.pasos, .cuello, .respiracion])
        #expect(target(applied, .pasos) == 125)
        #expect(target(applied, .cuello) == ActivityKind.cuello.defaultTarget)
        #expect(target(applied, .respiracion) == ActivityKind.respiracion.defaultTarget)
    }

    @Test func puntajeBajoElUmbralNoEsSuave() {
        let d = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: [0, 1, 5, 2])))
        #expect(!d.gentle)
    }

    @Test func planSuaveNoAcumulaFactorDePasos() {
        // Suave + "solo camina distancias cortas": la meta se reduce una sola vez.
        let d = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: [0, 1, 2, 3, 4])))
        #expect(d.gentle && d.stepTargetFactor == SafetyRules.reducedStepFactor)
        let applied = SafetyRules.apply(d, to: Recipes.base(.campamento5, demo: false))
        #expect(target(applied, .pasos) == 125)
    }

    @Test func evitaAgacharseQuitaSentadillaYExtension() {
        let d = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: [RDQ6.itemAvoidsBending])))
        #expect(!d.gentle && !d.stop)
        #expect(!d.allowed.contains(.sentadilla) && !d.allowed.contains(.extensionLumbar))
        #expect(d.allowed.contains(.pasos) && d.allowed.contains(.cuello))
        #expect(d.reason == SafetyRules.Copy.noBendingWhy)
        let applied = SafetyRules.apply(d, to: Recipes.base(.campamento5, demo: false))
        #expect(kinds(applied) == [.pasos, .cuello, .ojos, .stroop, .respiracion])
        #expect(target(applied, .pasos) == ActivityKind.pasos.defaultTarget)
    }

    @Test func caminaDistanciasCortasReduceLaMetaDePasos() {
        let d = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: [RDQ6.itemWalksShortDistances])))
        #expect(d.allowed.contains(.pasos))
        #expect(d.stepTargetFactor == 0.5 && !d.gentle)
        #expect(d.reason == SafetyRules.Copy.shortWalkWhy)
        let real = SafetyRules.apply(d, to: Recipes.base(.colacion3, demo: false))
        #expect(target(real, .pasos) == 125)
        #expect(kinds(real) == [.pasos, .sentadilla, .cuello, .ojos])
        let demo = SafetyRules.apply(d, to: Recipes.base(.colacion3, demo: true))
        #expect(target(demo, .pasos) == 15)
        #expect(target(demo, .cuello) == ActivityKind.cuello.demoTarget)
    }

    @Test func dePiePeriodosCortosAcortaLasDePie() {
        let d = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: [RDQ6.itemStandsShortPeriods])))
        #expect(d.shorterActivities && d.stepTargetFactor == 1 && !d.gentle)
        #expect(d.reason == SafetyRules.Copy.shortStandingWhy)
        let applied = SafetyRules.apply(d, to: Recipes.base(.campamento5, demo: false))
        #expect(kinds(applied) == kinds(Recipes.base(.campamento5, demo: false)))
        #expect(target(applied, .sentadilla) == 5)
        #expect(target(applied, .extensionLumbar) == 5)
        #expect(target(applied, .pasos) == ActivityKind.pasos.defaultTarget)
        #expect(target(applied, .cuello) == ActivityKind.cuello.defaultTarget)
        let demo = SafetyRules.apply(d, to: Recipes.base(.campamento5, demo: true))
        #expect(target(demo, .sentadilla) == SafetyRules.minRepTarget)
    }

    @Test func combinacionDeReglasSinPlanSuave() {
        // Agacharse + caminar corto + de pie corto = 3 de 6: no es suave, pero se aplican las tres.
        let yes: Set<Int> = [RDQ6.itemAvoidsBending, RDQ6.itemWalksShortDistances, RDQ6.itemStandsShortPeriods]
        let d = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: yes)))
        #expect(!d.gentle && d.shorterActivities && d.stepTargetFactor == 0.5)
        let applied = SafetyRules.apply(d, to: Recipes.base(.campamento5, demo: false))
        #expect(kinds(applied) == [.pasos, .cuello, .ojos, .stroop, .respiracion])
        #expect(target(applied, .pasos) == 125)
    }

    @Test func decisionConservaElInitMemberwiseDelStub() {
        let d = SafetyRules.Decision(allowed: [.cuello], gentle: false, stop: false, reason: nil)
        #expect(d.stepTargetFactor == 1 && d.shorterActivities == false)
    }

    @Test func plannedRecipeEsElAtajo() {
        let ci = checkIn(answers: answers(yes: [RDQ6.itemAvoidsBending]))
        let viaAtajo = SafetyRules.plannedRecipe(.campamento5, checkIn: ci, demo: true)
        let manual = SafetyRules.apply(SafetyRules.evaluate(checkIn: ci), to: Recipes.base(.campamento5, demo: true), demo: true)
        #expect(viaAtajo == manual)
    }

    // MARK: Recetas

    @Test func recetasBase() {
        #expect(kinds(Recipes.base(.relevo60, demo: false)) == [.cuello, .ojos])
        #expect(kinds(Recipes.base(.colacion3, demo: false, cameraPoseReady: false)) == [.pasos, .sentadilla, .cuello, .ojos])
        #expect(kinds(Recipes.base(.colacion3, demo: false, cameraPoseReady: true)) == [.pasos, .sentadilla, .cuello, .ojos, .extensionLumbar])
        #expect(kinds(Recipes.base(.campamento5, demo: false)) == [.pasos, .sentadilla, .extensionLumbar, .cuello, .ojos, .stroop, .respiracion])
        #expect(Recipes.base(.relevo60, demo: false).minutes == 1 && Recipes.base(.campamento5, demo: false).title == RecipeKind.campamento5.title)
    }

    @Test func metasDemoVersusReales() {
        for kind in RecipeKind.allCases {
            let real = Recipes.base(kind, demo: false)
            let demo = Recipes.base(kind, demo: true)
            #expect(real.activities.allSatisfy { $0.target == $0.kind.defaultTarget })
            #expect(demo.activities.allSatisfy { $0.target == $0.kind.demoTarget })
            #expect(!real.usesDemoTargets && demo.usesDemoTargets)
        }
    }

    @Test func recetaSuave() {
        let real = Recipes.gentle(.campamento5, demo: false)
        #expect(kinds(real) == [.pasos, .cuello, .respiracion])
        #expect(target(real, .pasos) == 125 && target(real, .cuello) == 15 && target(real, .respiracion) == 6)
        #expect(real.kind == .campamento5)
        let demo = Recipes.gentle(.relevo60, demo: true)
        #expect(target(demo, .pasos) == 15 && target(demo, .cuello) == 6 && target(demo, .respiracion) == 3)
    }

    @Test func relevoUsaUnSoloBloqueDeCara() {
        let r = Recipes.base(.relevo60, demo: false)
        #expect(SensorBlockPlanner.blocks(r.activities) == [.face])
    }

    // MARK: Copy

    @Test func copyCompletoYSinPalabrasProhibidas() {
        let prohibidas = ["trampa", "apto", " po ", "cachai", "¡Excelente"]
        for kind in ActivityKind.allCases {
            let sentences = kind.instructions.split(separator: ".").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect(sentences.count == 2, "\(kind) debe tener 2 frases")
            #expect(!kind.placement.isEmpty && !kind.evidenceNote.isEmpty && !kind.contraindication.isEmpty)
            #expect(kind.gatingCopy.count >= 2)
            for text in [kind.instructions, kind.placement, kind.evidenceNote, kind.contraindication] + kind.gatingCopy {
                for p in prohibidas { #expect(!text.lowercased().contains(p.lowercased()), "\(kind): '\(p)' en \(text)") }
            }
        }
    }

    @Test func placementYGatingSiguenElBloque() {
        #expect(ActivityKind.cuello.placement == "Teléfono en la mano a distancia selfie")
        #expect(ActivityKind.ojos.placement == ActivityKind.cuello.placement)
        #expect(ActivityKind.pasos.placement == "Guarde el teléfono en el bolsillo del pecho y camine")
        #expect(ActivityKind.sentadilla.placement == "Apoye el teléfono a 2 metros, cuerpo entero en pantalla")
        #expect(ActivityKind.extensionLumbar.placement == ActivityKind.sentadilla.placement)
        #expect(ActivityKind.stroop.placement == "Pantalla en la mano" && ActivityKind.respiracion.placement == "Pantalla en la mano")
        #expect(ActivityKind.cuello.gatingCopy == ["Sáquese casco y lentes.", "Mire al teléfono.", "Quieto un segundo."])
        #expect(ActivityKind.sentadilla.gatingCopy == ["Apoye el teléfono. Aléjese.", "Lo veo entero.", "3 · 2 · 1"])
        #expect(ActivityKind.pasos.gatingCopy == ["Guarde el teléfono. Camine.", "No lo bloquee."])
    }
}

// MARK: - SensorBlockPlanner

struct SensorBlockPlannerTests {
    private func a(_ k: ActivityKind) -> ActivityAssignment { ActivityAssignment(kind: k, target: k.defaultTarget) }

    @Test func campamentoSeAgrupaEnCuatroBloquesEnOrden() {
        let groups = SensorBlockPlanner.order(Recipes.base(.campamento5, demo: false).activities)
        #expect(groups.map { $0.map(\.kind) } == [[.pasos], [.sentadilla, .extensionLumbar], [.cuello, .ojos], [.stroop, .respiracion]])
        #expect(groups.compactMap(SensorBlockPlanner.block(of:)) == [.pedometer, .cameraPose, .face, .screen])
    }

    @Test func desordenadoConservaElOrdenInternoDeCadaBloque() {
        let input = [a(.ojos), a(.stroop), a(.pasos), a(.cuello), a(.sentadilla), a(.respiracion), a(.extensionLumbar)]
        let groups = SensorBlockPlanner.order(input)
        #expect(groups.map { $0.map(\.kind) } == [[.pasos], [.sentadilla, .extensionLumbar], [.ojos, .cuello], [.stroop, .respiracion]])
        #expect(SensorBlockPlanner.ordered(input).map(\.kind) == [.pasos, .sentadilla, .extensionLumbar, .ojos, .cuello, .stroop, .respiracion])
    }

    @Test func bloquesVaciosNoAparecen() {
        let input = [a(.ojos), a(.respiracion)]
        #expect(SensorBlockPlanner.order(input).map { $0.map(\.kind) } == [[.ojos], [.respiracion]])
        #expect(SensorBlockPlanner.blocks(input) == [.face, .screen])
        #expect(SensorBlockPlanner.order([]).isEmpty)
    }

    @Test func flattenEsInversoDeOrderParaListasOrdenadas() {
        let ordered = Recipes.base(.campamento5, demo: true).activities
        #expect(SensorBlockPlanner.flatten(SensorBlockPlanner.order(ordered)) == ordered)
        let colacion = Recipes.base(.colacion3, demo: false, cameraPoseReady: true).activities
        #expect(SensorBlockPlanner.ordered(colacion).map(\.kind) == [.pasos, .sentadilla, .extensionLumbar, .cuello, .ojos])
    }

    @Test func conservaMetasYDuplicados() {
        let input = [ActivityAssignment(kind: .pasos, target: 125), a(.cuello), ActivityAssignment(kind: .cuello, target: 6)]
        let flat = SensorBlockPlanner.ordered(input)
        #expect(flat.map(\.target) == [125, 15, 6])
    }

    @Test func handoffDeCamaraSoloEntreCuerpoYCara() {
        #expect(SensorBlockPlanner.needsCameraHandoff(from: .cameraPose, to: .face))
        #expect(SensorBlockPlanner.needsCameraHandoff(from: .face, to: .cameraPose))
        #expect(!SensorBlockPlanner.needsCameraHandoff(from: .pedometer, to: .face))
        #expect(!SensorBlockPlanner.needsCameraHandoff(from: .face, to: .screen))
        #expect(!SensorBlockPlanner.needsCameraHandoff(from: .face, to: .face))
        let handoffs = SensorBlockPlanner.cameraHandoffs(Recipes.base(.campamento5, demo: false).activities)
        #expect(handoffs.count == 1 && handoffs.first?.from == .cameraPose && handoffs.first?.to == .face)
        #expect(SensorBlockPlanner.cameraHandoffs(Recipes.base(.relevo60, demo: false).activities).isEmpty)
    }
}
