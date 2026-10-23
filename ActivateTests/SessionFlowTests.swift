import Testing
import Foundation
@testable import Activate

/// Lógica pura del paquete session: validación del plan del coach, orden por sensor, receta suave y coordinador.
struct SessionFlowTests {
    private func plan(_ acts: [ActivityAssignment]) -> PausePlan {
        PausePlan(activities: acts, reasoning: "", why: "", startMessage: "", backend: .rules)
    }

    private func a(_ k: ActivityKind, _ target: Int) -> ActivityAssignment { ActivityAssignment(kind: k, target: target) }

    // MARK: SessionPlanCheck

    @Test func aceptaLasRecetasBase() {
        for kind in RecipeKind.allCases {
            for demo in [false, true] {
                let base = Recipes.base(kind, demo: demo)
                #expect(SessionPlanCheck.accepts(plan(base.activities), allowed: ActivityKind.allCases, base: base,
                                                 minutes: kind.minutes, demo: demo),
                        "receta \(kind) demo=\(demo) debe pasar")
            }
        }
    }

    @Test func rechazaIdNoPermitido() {
        let base = Recipes.base(.campamento5, demo: false)
        let allowed = ActivityKind.allCases.filter { $0 != .sentadilla }
        let p = plan([a(.pasos, 250), a(.sentadilla, 10)])
        #expect(!SessionPlanCheck.accepts(p, allowed: allowed, base: base, minutes: 5, demo: false))
    }

    @Test func rechazaRepsSobreElDoble() {
        let base = Recipes.base(.relevo60, demo: false)
        let ok = plan([a(.cuello, 30)])
        let tooMany = plan([a(.cuello, 31)])
        #expect(SessionPlanCheck.accepts(ok, allowed: ActivityKind.allCases, base: base, minutes: 1, demo: false))
        #expect(!SessionPlanCheck.accepts(tooMany, allowed: ActivityKind.allCases, base: base, minutes: 1, demo: false))
    }

    @Test func rechazaVacioDuplicadosYCero() {
        let base = Recipes.base(.colacion3, demo: false)
        #expect(!SessionPlanCheck.accepts(plan([]), allowed: ActivityKind.allCases, base: base, minutes: 3, demo: false))
        #expect(!SessionPlanCheck.accepts(plan([a(.cuello, 5), a(.cuello, 5)]), allowed: ActivityKind.allCases, base: base, minutes: 3, demo: false))
        #expect(!SessionPlanCheck.accepts(plan([a(.cuello, 0)]), allowed: ActivityKind.allCases, base: base, minutes: 3, demo: false))
    }

    @Test func rechazaDuracionExcedida() {
        // Pasos (100 s mínimo) + Stroop (45 s) no caben en el relevo de 1 minuto.
        let base = Recipes.base(.relevo60, demo: false)
        let p = plan([a(.pasos, 250), a(.stroop, 40)])
        #expect(!SessionPlanCheck.accepts(p, allowed: ActivityKind.allCases, base: base, minutes: 1, demo: false))
    }

    // MARK: Orden por bloque de sensor (SensorBlockPlanner, paquete activities)

    @Test func ordenaPorBloqueDeSensorConservandoElOrdenInterno() {
        let mixed = [a(.cuello, 15), a(.pasos, 250), a(.stroop, 40), a(.sentadilla, 10), a(.respiracion, 6), a(.ojos, 15), a(.extensionLumbar, 10)]
        let ordered = SensorBlockPlanner.ordered(mixed).map(\.kind)
        #expect(ordered == [.pasos, .sentadilla, .extensionLumbar, .cuello, .ojos, .stroop, .respiracion])
    }

    // MARK: Receta suave (Recipes.gentle vía SafetyRules.apply)

    @Test func recetaSuaveSinSentadillaYConPasosReducidos() {
        let gentle = Recipes.gentle(.campamento5, demo: false)
        let kinds = gentle.activities.map(\.kind)
        #expect(kinds == [.pasos, .cuello, .respiracion])
        #expect(gentle.activities[0].target == 125)
    }

    // MARK: Plan del coach: PlanValidator solo para el LLM, SessionPlanCheck para todos

    @Test func planDelLLMPasaPorPlanValidatorYLaPlantillaNo() {
        let base = Recipes.base(.campamento5, demo: false)
        let input = CoachInput(profileName: "Marco", treatment: .usted, checkIn: nil, moment: .campamento,
                               minutesAvailable: 5, baseRecipe: base, allowedKinds: ActivityKind.allCases,
                               historyLines: [], gentle: false)
        // La plantilla por reglas devuelve las 7 actividades de campamento: la acepta SessionPlanCheck.
        let rules = PausePlan(activities: base.activities, reasoning: "", why: "", startMessage: "", backend: .rules)
        #expect(PauseCoordinator.validated(rules, input: input, base: base, minutes: 5, demo: false)?.count == 7)
        // El mismo plan "del LLM" supera el máximo de 5 ejercicios del prompt: PlanValidator lo rechaza.
        let llm = PausePlan(activities: base.activities, reasoning: "", why: "", startMessage: "", backend: .foundationModels)
        #expect(PauseCoordinator.validated(llm, input: input, base: base, minutes: 5, demo: false) == nil)
        // Un plan corto y permitido del LLM pasa las dos barreras.
        let short = PausePlan(activities: [a(.pasos, 200), a(.cuello, 10)], reasoning: "", why: "", startMessage: "", backend: .foundationModels)
        #expect(PauseCoordinator.validated(short, input: input, base: base, minutes: 5, demo: false)?.map(\.kind) == [.pasos, .cuello])
    }

    // MARK: PauseCoordinator

    @MainActor
    private func makeCoordinator(moment: Moment = .colacion) -> (PauseCoordinator, AppStore) {
        let store = AppStore(inMemory: true)
        let game = GameStore(store: store)
        let coach = CoachService()
        return (PauseCoordinator(moment: moment, store: store, game: game, coach: coach), store)
    }

    @MainActor
    @Test func checkInSeGuardaAlInstanteYPasaAlPlan() {
        let (c, store) = makeCoordinator()
        #expect(c.stage == .checkIn)
        #expect(c.existingCheckIn == nil)
        c.submitCheckIn(answers: [true, false, false, false, false, false], zone: .lumbar, moment: .colacion)
        #expect(store.data.checkIns.count == 1)
        #expect(store.data.checkIns[0].score == 1)
        #expect(store.data.checkIns[0].source == .pausa)
        #expect(c.stage == .planning)
        #expect(!c.plan.isEmpty)
        #expect(c.plan.map(\.kind) == SensorBlockPlanner.ordered(Recipes.base(.colacion3, demo: false).activities).map(\.kind))
    }

    @MainActor
    @Test func rdqAltoPideAlarmaYUnSiDeriva() {
        let (c, store) = makeCoordinator()
        c.submitCheckIn(answers: [true, true, true, true, true, false], zone: .lumbar, moment: .colacion)
        #expect(c.stage == .alarm)
        c.submitAlarm(answers: [false, true, false])
        #expect(c.stage == .stopped)
        #expect(store.data.checkIns[0].alarmAnswers == [false, true, false])
        #expect(store.data.checkIns[0].hasAlarm)
    }

    @MainActor
    @Test func rdqAltoSinAlarmaDaPlanSuave() {
        let (c, _) = makeCoordinator(moment: .campamento)
        c.submitCheckIn(answers: [true, true, true, true, true, true], zone: .lumbar, moment: .campamento)
        c.submitAlarm(answers: [false, false, false])
        #expect(c.stage == .planning)
        #expect(c.isGentle)
        #expect(!c.plan.contains { $0.kind == .sentadilla })
        #expect(c.plan.contains { $0.kind == .respiracion })
    }

    @MainActor
    @Test func checkInExistenteSeReutiliza() {
        let store = AppStore(inMemory: true)
        let cal = store.calendar
        let now = Date.now
        store.mutate {
            $0.checkIns.append(DailyCheckIn(date: now, workDayKey: cal.key(for: now), turnoKey: cal.turnoKey(for: now),
                                            source: .pausa, answers: [false, false, true, false, false, false], zone: .cuello, moment: .entrada))
        }
        let c = PauseCoordinator(moment: .entrada, store: store, game: GameStore(store: store), coach: CoachService())
        #expect(c.existingCheckIn?.score == 1)
        c.continueWithExistingCheckIn()
        #expect(c.stage == .planning)
        #expect(store.data.checkIns.count == 1)
    }

    @MainActor
    @Test func saltarTodoLlevaAlCierreYLaSesionNoCuenta() async {
        let (c, _) = makeCoordinator(moment: .entrada)
        c.submitCheckIn(answers: [false, false, false, false, false, false], zone: .lumbar, moment: .entrada)
        c.startActivities()
        let total = c.plan.count
        #expect(total == 2)
        for i in 0..<total {
            #expect(c.stage == .activity(i))
            #expect(c.runner != nil)
            c.skipCurrent()
        }
        #expect(c.stage == .postCheck)
        #expect(c.results.count == total)
        #expect(c.results.allSatisfy { $0.skipped && !$0.completed })
        c.submitPost(.igual)
        #expect(c.isFinishing)
        // Esperar el cierre asíncrono (firma + registro).
        for _ in 0..<50 where c.stage != .reward {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(c.stage == .reward)
        #expect(c.reward != nil)
        #expect(c.session?.counted == false)
        #expect(c.session?.postResponse == .igual)
        #expect(c.session?.checkInScore == 0)
        #expect((c.session?.monotonicSeconds ?? -1) >= 0)
    }

    /// El `ActivityResult` sale solo del runner (testigo `Verified`): el coordinador ya no lo arma.
    @MainActor
    @Test func resultadoSaleSoloDelRunner() {
        let placeholder = PlaceholderRunner(assignment: a(.ojos, 15))
        #expect(placeholder.verifiedResult == nil)
        placeholder.stop(reason: .skipped)
        let skipped = try? #require(placeholder.verifiedResult)
        #expect(skipped?.kind == .ojos && skipped?.skipped == true && skipped?.completed == false && skipped?.level == .simulated)
    }

    @MainActor
    @Test func sesionCerradaLlevaBanderasDeIntegridadYMonotonico() async {
        let (c, _) = makeCoordinator(moment: .entrada)
        c.submitCheckIn(answers: [false, false, false, false, false, false], zone: .lumbar, moment: .entrada)
        c.startActivities()
        while case .activity = c.stage { c.skipCurrent() }
        c.submitPost(.mejor)
        for _ in 0..<50 where c.stage != .reward {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let session = try? #require(c.session)
        // Sin cambios de hora ni segundo plano no hay banderas duras; el monotónico viene del IntegrityMonitor.
        #expect(session?.integrityFlags.contains { $0.severity == .hard } == false)
        #expect((session?.monotonicSeconds ?? -1) >= 0)
        #expect(session?.level == .suspicious) // todas saltadas
        #expect(session?.counted == false)
    }
}
