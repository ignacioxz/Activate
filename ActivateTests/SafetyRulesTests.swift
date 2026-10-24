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
        #expect(d.allowed == ActivityKind.sessionOrder)
        #expect(!d.allowed.contains(.respiracion))
        #expect(!d.gentle && !d.stop && d.reason == nil)
        #expect(d.stepTargetFactor == 1 && !d.shorterActivities && !d.adjusted)
        let recipe = Recipes.base(.campamento5, demo: false)
        #expect(SafetyRules.apply(d, to: recipe) == recipe)
    }

    @Test func checkInSinSintomasNoCambiaNada() {
        let d = SafetyRules.evaluate(checkIn: checkIn())
        #expect(d.allowed == ActivityKind.sessionOrder && !d.gentle && !d.stop && !d.adjusted)
    }

    @Test func meDueleAhoraSinRespuestasNoRestringe() {
        let d = SafetyRules.evaluate(checkIn: checkIn(answers: [], source: .meDueleAhora))
        #expect(d.allowed == ActivityKind.sessionOrder && !d.gentle && !d.stop)
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
        #expect(kinds(applied) == [.pasos, .cuello, .ojos])
        #expect(target(applied, .pasos) == 125)
        #expect(target(applied, .cuello) == ActivityKind.cuello.defaultTarget)
        #expect(target(applied, .ojos) == ActivityKind.ojos.defaultTarget)
        #expect(!d.allowed.contains(.respiracion))
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
        #expect(kinds(applied) == [.pasos, .cuello, .stroop, .ojos])
        #expect(target(applied, .pasos) == ActivityKind.pasos.defaultTarget)
        #expect(d.adjusted)
    }

    @Test func pararseYSentarseSaleComoLaSentadilla() {
        // "Trata de no agacharse o arrodillarse" = Sí: fuera junto con la sentadilla y la extensión.
        let bending = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: [RDQ6.itemAvoidsBending])))
        #expect(!bending.allowed.contains(.pararseSentarse))
        #expect(!kinds(SafetyRules.apply(bending, to: Recipes.base(.campamento5, demo: false))).contains(.pararseSentarse))
        // Plan suave (RDQ ≥ 5): fuera.
        let gentle = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: [0, 1, 2, 4, 5])))
        #expect(gentle.gentle && !gentle.allowed.contains(.pararseSentarse))
        #expect(!kinds(SafetyRules.apply(gentle, to: Recipes.base(.campamento5, demo: false))).contains(.pararseSentarse))
        // De pie por períodos cortos: se acorta como las demás de pie (8 → 4; demo 4 → piso de 3).
        let standing = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: [RDQ6.itemStandsShortPeriods])))
        #expect(target(SafetyRules.apply(standing, to: Recipes.base(.campamento5, demo: false)), .pararseSentarse) == 4)
        #expect(target(SafetyRules.apply(standing, to: Recipes.base(.campamento5, demo: true)), .pararseSentarse) == SafetyRules.minRepTarget)
        // Sin check-in o sin síntomas: va en la ruta completa, con su meta.
        #expect(target(Recipes.base(.campamento5, demo: false), .pararseSentarse) == 8)
        #expect(target(Recipes.base(.colacion3, demo: true), .pararseSentarse) == 4)
        for moment in Moment.allCases {
            #expect(target(Recipes.base(moment.recipe, demo: false), .pararseSentarse) == 8, "\(moment)")
        }
    }

    @Test func caminaDistanciasCortasReduceLaMetaDePasos() {
        let d = SafetyRules.evaluate(checkIn: checkIn(answers: answers(yes: [RDQ6.itemWalksShortDistances])))
        #expect(d.allowed.contains(.pasos))
        #expect(d.stepTargetFactor == 0.5 && !d.gentle)
        #expect(d.reason == SafetyRules.Copy.shortWalkWhy)
        // Ruta completa: solo baja la meta de pasos, no saca ejercicios.
        let real = SafetyRules.apply(d, to: Recipes.base(.campamento5, demo: false))
        #expect(target(real, .pasos) == 125)
        #expect(kinds(real) == ActivityKind.sessionOrder)
        let demo = SafetyRules.apply(d, to: Recipes.base(.campamento5, demo: true))
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
        #expect(kinds(applied) == [.pasos, .cuello, .stroop, .ojos])
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
        // Toda receta es la ruta completa: todo el orden fijo (el flag de cámara de cuerpo ya no cambia nada:
        // pararse y sentarse, la sentadilla y la extensión van en las manos).
        for kind in RecipeKind.allCases {
            for ready in [false, true] {
                #expect(kinds(Recipes.base(kind, demo: false, cameraPoseReady: ready)) == ActivityKind.sessionOrder, "\(kind) ready=\(ready)")
            }
        }
        #expect(kinds(Recipes.base(.campamento5, demo: false)) == [.pasos, .pararseSentarse, .sentadilla, .cuello, .stroop, .ojos, .extensionLumbar])
        #expect(RecipeKind.colacion3.title == "Ruta completa" && RecipeKind.campamento5.title == "Ruta completa")
        #expect(Recipes.base(.campamento5, demo: false).minutes == 7 && Recipes.base(.campamento5, demo: false).title == RecipeKind.campamento5.title)
    }

    @Test func laPausaRapidaAntiguaNuncaSeArma() {
        // `relevo60` solo existe para leer sesiones guardadas: pedir su receta arma la ruta completa de 7 minutos.
        let legacy = Recipes.base(.relevo60, demo: false)
        #expect(legacy.kind == .campamento5)
        #expect(kinds(legacy) == ActivityKind.sessionOrder)
        #expect(legacy.minutes == 7)
        #expect(!Moment.allCases.contains { $0.recipe == .relevo60 })
        // Sus textos se conservan para el historial de pausas antiguas.
        #expect(RecipeKind.relevo60.title == "Pausa rápida · 1 min")
        #expect(RecipeKind.allCases.map(\.minutes) == [1, 7, 7])
    }

    @Test func todoMomentoHaceLaRutaCompleta() {
        // El momento no elige la receta y no hay pausa rápida: siempre la ruta completa.
        for moment in Moment.allCases {
            #expect(moment.recipe == .campamento5, "\(moment)")
            #expect(moment.minutes == 7, "\(moment)")
            #expect(kinds(Recipes.base(moment.recipe, demo: false)) == ActivityKind.sessionOrder, "\(moment)")
        }
    }

    @Test func recetasSalenEnElOrdenFijoYSinRetiradas() {
        for kind in RecipeKind.allCases {
            for ready in [false, true] {
                for demo in [false, true] {
                    let k = kinds(Recipes.base(kind, demo: demo, cameraPoseReady: ready))
                    #expect(!k.contains { $0.isRetired }, "\(kind) no debe traer actividades retiradas")
                    #expect(k == ActivityKind.inSessionOrder(k, kind: { $0 }), "\(kind) debe ir en el orden fijo")
                }
            }
            #expect(!kinds(Recipes.gentle(kind, demo: false)).contains(.respiracion))
        }
        #expect(Recipes.gentleKinds == ActivityKind.inSessionOrder(Recipes.gentleKinds, kind: { $0 }))
    }

    @Test func respiracionRetiradaYOrdenFijoDeLaSesion() {
        #expect(ActivityKind.sessionOrder == [.pasos, .pararseSentarse, .sentadilla, .cuello, .stroop, .ojos, .extensionLumbar])
        #expect(ActivityKind.respiracion.isRetired)
        #expect(ActivityKind.allCases.filter(\.isRetired) == [.respiracion])
        #expect(Set(ActivityKind.sessionOrder + [.respiracion]) == Set(ActivityKind.allCases))
        #expect(ActivityKind.respiracion.sessionRank == ActivityKind.sessionOrder.count)
        #expect(ActivityKind.sessionOrder.map(\.sessionRank) == Array(0..<ActivityKind.sessionOrder.count))
        // Los empates conservan el orden relativo de entrada.
        let pares: [(ActivityKind, Int)] = [(.ojos, 1), (.cuello, 2), (.ojos, 3), (.pasos, 4)]
        #expect(ActivityKind.inSessionOrder(pares, kind: { $0.0 }).map(\.1) == [4, 2, 1, 3])
    }

    @Test func cuelloSeLlamaMovilidadCervical() {
        #expect(ActivityKind.cuello.name == "Movilidad cervical")
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
        #expect(kinds(real) == [.pasos, .cuello, .ojos])
        #expect(target(real, .pasos) == 125 && target(real, .cuello) == 15 && target(real, .ojos) == 15)
        #expect(real.kind == .campamento5)
        let demo = Recipes.gentle(.campamento5, demo: true)
        #expect(kinds(demo) == [.pasos, .cuello, .ojos])
        #expect(target(demo, .pasos) == 15 && target(demo, .cuello) == 6 && target(demo, .ojos) == 8)
    }

    @Test func cuelloYPestaneoUsanUnSoloBloqueDeCara() {
        let r = [Recipes.assignment(.cuello, demo: false), Recipes.assignment(.ojos, demo: false)]
        #expect(SensorBlockPlanner.blocks(r) == [.face])
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
        // Sentadilla y extensión lumbar: en las manos, nunca apoyado con la cámara en pantalla; pararse y
        // sentarse, en el bolsillo delantero del pantalón.
        #expect(ActivityKind.sentadilla.placement == "Teléfono en las dos manos, frente al pecho")
        #expect(ActivityKind.extensionLumbar.placement == ActivityKind.sentadilla.placement)
        #expect(ActivityKind.pararseSentarse.placement == "Teléfono en el bolsillo delantero del pantalón")
        #expect(ActivityKind.stroop.placement == "Pantalla en la mano" && ActivityKind.respiracion.placement == "Pantalla en la mano")
        #expect(ActivityKind.cuello.gatingCopy == ["Sáquese casco y lentes.", "Mire al teléfono.", "Quieto un segundo."])
        #expect(ActivityKind.sentadilla.gatingCopy == ["Tome el teléfono frente al pecho y mírelo.", "Quieto un segundo.", "Baje como si se sentara."])
        #expect(ActivityKind.pararseSentarse.gatingCopy == ["Guarde el teléfono en el bolsillo delantero del pantalón.", "Siéntese quieto un segundo.", "Párese y siéntese sin usar las manos."])
        #expect(ActivityKind.extensionLumbar.gatingCopy == ["Tome el teléfono frente al pecho y mírelo.", "Quieto un segundo.", "Inclínese hacia atrás."])
        #expect(ActivityKind.pasos.gatingCopy == ["Guarde el teléfono. Camine.", "No lo bloquee."])
    }
}

// MARK: - SensorBlockPlanner

struct SensorBlockPlannerTests {
    private func a(_ k: ActivityKind) -> ActivityAssignment { ActivityAssignment(kind: k, target: k.defaultTarget) }

    @Test func campamentoSigueElOrdenFijoEnTramosDeSensor() {
        // Pararse y sentarse va en el bolsillo, en el tramo de la caminata; sentadilla y extensión en las manos
        // usan ARKit sin vista: mismo bloque que cuello y pestañeo (sin relevo de cámara).
        let groups = SensorBlockPlanner.order(Recipes.base(.campamento5, demo: false).activities)
        #expect(groups.map { $0.map(\.kind) } == [[.pasos, .pararseSentarse], [.sentadilla, .cuello], [.stroop], [.ojos, .extensionLumbar]])
        #expect(groups.compactMap(SensorBlockPlanner.block(of:)) == [.pedometer, .face, .screen, .face])
        #expect(SensorBlockPlanner.blocks(Recipes.base(.campamento5, demo: false).activities)
                == [.pedometer, .face, .screen, .face])
    }

    @Test func desordenadoSeOrdenaPorLaSesionYDescartaRetiradas() {
        let input = [a(.ojos), a(.stroop), a(.sentadilla), a(.pasos), a(.cuello), a(.pararseSentarse), a(.respiracion), a(.extensionLumbar)]
        let groups = SensorBlockPlanner.order(input)
        #expect(groups.map { $0.map(\.kind) } == [[.pasos, .pararseSentarse], [.sentadilla, .cuello], [.stroop], [.ojos, .extensionLumbar]])
        #expect(SensorBlockPlanner.ordered(input).map(\.kind) == ActivityKind.sessionOrder)
        #expect(SensorBlockPlanner.ordered([a(.respiracion)]).isEmpty)
    }

    @Test func tramosConsecutivosDelMismoSensorSeJuntan() {
        // Sin Stroop entre medio, cuello y pestañeo quedan en un solo tramo de cara.
        let input = [a(.ojos), a(.pasos), a(.cuello)]
        #expect(SensorBlockPlanner.order(input).map { $0.map(\.kind) } == [[.pasos], [.cuello, .ojos]])
        #expect(SensorBlockPlanner.blocks(input) == [.pedometer, .face])
        // Sin agacharse: caminata → cervical → Stroop → pestañeo.
        let noBending = [a(.pasos), a(.cuello), a(.stroop), a(.ojos)]
        #expect(SensorBlockPlanner.blocks(noBending) == [.pedometer, .face, .screen, .face])
    }

    @Test func unBloquePuedeRepetirseYLasRetiradasNoAparecen() {
        // Cara → pantalla → cara: el bloque de cara se repite en vez de juntarse.
        let input = [a(.ojos), a(.stroop), a(.cuello)]
        #expect(SensorBlockPlanner.order(input).map { $0.map(\.kind) } == [[.cuello], [.stroop], [.ojos]])
        #expect(SensorBlockPlanner.blocks(input) == [.face, .screen, .face])
        // La respiración (retirada) no aparece ni deja un bloque de pantalla vacío.
        let withRetired = [a(.ojos), a(.respiracion)]
        #expect(SensorBlockPlanner.order(withRetired).map { $0.map(\.kind) } == [[.ojos]])
        #expect(SensorBlockPlanner.blocks(withRetired) == [.face])
        #expect(SensorBlockPlanner.order([a(.respiracion)]).isEmpty)
        #expect(SensorBlockPlanner.order([]).isEmpty)
    }

    @Test func flattenEsInversoDeOrderParaListasOrdenadas() {
        let ordered = Recipes.base(.campamento5, demo: true).activities
        #expect(SensorBlockPlanner.flatten(SensorBlockPlanner.order(ordered)) == ordered)
        let caraSola = [a(.cuello), a(.ojos)]
        #expect(SensorBlockPlanner.flatten(SensorBlockPlanner.order(caraSola)) == caraSola)
        // Lista parcial ya ordenada (sin sentadilla ni Stroop): queda igual.
        let parcial = [a(.pasos), a(.cuello), a(.ojos), a(.extensionLumbar)]
        #expect(SensorBlockPlanner.flatten(SensorBlockPlanner.order(parcial)) == parcial)
        #expect(SensorBlockPlanner.ordered(parcial).map(\.kind) == [.pasos, .cuello, .ojos, .extensionLumbar])
        let colacion = Recipes.base(.colacion3, demo: false, cameraPoseReady: true).activities
        #expect(SensorBlockPlanner.ordered(colacion).map(\.kind) == ActivityKind.sessionOrder)
        let mixed = [a(.extensionLumbar), a(.ojos), a(.stroop), a(.pasos), a(.cuello)]
        #expect(SensorBlockPlanner.flatten(SensorBlockPlanner.order(mixed)) == SensorBlockPlanner.ordered(mixed))
    }

    @Test func conservaMetasYDuplicados() {
        let input = [ActivityAssignment(kind: .pasos, target: 125), a(.cuello), ActivityAssignment(kind: .cuello, target: 6)]
        let flat = SensorBlockPlanner.ordered(input)
        #expect(flat.map(\.target) == [125, 15, 6])
    }

    @Test func sinCamaraDeCuerpoNoHayRelevoDeCamara() {
        // Un solo bloque de cámara (ARKit sin vista): nunca hay relevo AVCaptureSession ↔ ARSession.
        #expect(SensorBlock.face.usesFrontCamera)
        #expect(!SensorBlock.pedometer.usesFrontCamera && !SensorBlock.screen.usesFrontCamera)
        #expect(!SensorBlockPlanner.needsCameraHandoff(from: .pedometer, to: .face))
        #expect(!SensorBlockPlanner.needsCameraHandoff(from: .face, to: .screen))
        #expect(!SensorBlockPlanner.needsCameraHandoff(from: .face, to: .face))
        // Ruta completa: pararse y sentarse → sentadilla → cervical y pestañeo → extensión siguen sin esperar la cámara.
        for kind in [RecipeKind.colacion3, .campamento5] {
            #expect(SensorBlockPlanner.cameraHandoffs(Recipes.base(kind, demo: false).activities).isEmpty, "\(kind)")
        }
        #expect(SensorBlockPlanner.cameraHandoffs([a(.cuello), a(.ojos)]).isEmpty)
        #expect(SensorBlockPlanner.cameraHandoffs(Recipes.base(.colacion3, demo: false, cameraPoseReady: true).activities).isEmpty)
        // Sin sentadilla: pestañeo → extensión lumbar tampoco.
        #expect(SensorBlockPlanner.cameraHandoffs([a(.pasos), a(.cuello), a(.ojos), a(.extensionLumbar)]).isEmpty)
        // Cara → pantalla → cara no suelta la cámara entre medio.
        #expect(SensorBlockPlanner.cameraHandoffs([a(.cuello), a(.stroop), a(.ojos)]).isEmpty)
        // Caminata → pararse y sentarse (mismo bloque, bolsillo) → sentadilla: sin relevo de cámara.
        #expect(ActivityKind.pararseSentarse.sensorBlock == ActivityKind.pasos.sensorBlock)
        #expect(SensorBlockPlanner.cameraHandoffs([a(.pasos), a(.pararseSentarse), a(.sentadilla)]).isEmpty)
        // Sin sentadilla: pararse y sentarse → cervical tampoco (el bolsillo no usa cámara).
        #expect(SensorBlockPlanner.cameraHandoffs([a(.pararseSentarse), a(.cuello)]).isEmpty)
    }
}
