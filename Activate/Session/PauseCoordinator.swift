import Foundation
import Observation

/// Orquesta una pausa: check-in → alarma (si RDQ alto) → plan → actividad(i) → cierre → premio.
/// Los sensores verifican (`ActivityRunner`), Swift calcula, el coach solo ajusta el plan si pasa la validación.
/// Nunca hay botón "hecho": la única forma de avanzar es que el runner publique un `ActivityOutcome`
/// o que la persona salte la actividad ("no suma").
@Observable
@MainActor
final class PauseCoordinator {
    enum Stage: Equatable {
        case checkIn
        /// Tres preguntas de alarma (solo con RDQ ≥ `RDQ6.gentlePlanThreshold`).
        case alarm
        /// Tarjeta "cuándo parar": derivación al policlínico de faena, sin ejercicio.
        case stopped
        case planning
        case activity(Int)
        case postCheck
        case reward
    }

    // MARK: Constantes nombradas (se calibran después)

    /// Tiempo máximo que se espera al coach antes de quedarse con la receta fija.
    static let coachTimeoutSeconds: Double = 3.5
    /// Nivel que se registra cuando el runner no declara ninguno: nunca se asume verificación.
    static let undeclaredLevel: VerificationLevel = .suspicious
    /// Espera entre `stop()` de una fuente de cámara y `start()` de la otra (ARSession ↔ AVCaptureSession).
    static let cameraHandoffSeconds: Double = 1.0

    // MARK: Dependencias

    let moment: Moment
    private let store: AppStore
    private let game: GameStore
    private let coach: CoachService

    // MARK: Estado observable

    private(set) var stage: Stage = .checkIn
    /// Check-in de hoy (vía pausa) que ya existía al entrar; `nil` tras "Volver a responder".
    private(set) var existingCheckIn: DailyCheckIn?
    private(set) var checkIn: DailyCheckIn?
    private(set) var decision: SafetyRules.Decision?
    /// Plan vigente: receta fija al instante, ajustada por el coach solo si pasa la validación.
    private(set) var plan: [ActivityAssignment] = []
    private(set) var coachWhy: String?
    private(set) var coachStartMessage: String?
    private(set) var coachBackend: CoachBackend?
    /// Sin consentimiento no se usa la cámara: el plan queda solo con pasos y pantalla.
    private(set) var cameraBlocked = false
    /// Ejercicios del orden fijo que no entran hoy, con su razón (pantalla de plan).
    private(set) var excluded: [PlanExclusion] = []
    /// Momento elegido en el chip "Momento" del check-in de esta pausa (nil si se reutilizó uno anterior).
    private(set) var selectedMoment: Moment?
    private(set) var results: [ActivityResult] = []
    private(set) var post: PostResponse?
    private(set) var reward: SessionReward?
    private(set) var session: PauseSession?
    private(set) var runner: (any ActivityRunning)?
    /// Cambia cada vez que se crea un runner; la vista de actividad usa `.id(runnerGeneration)`.
    private(set) var runnerGeneration = 0
    private(set) var isFinishing = false
    private(set) var signError: String?

    // MARK: Estado interno

    private let startedAt = Date.now
    private let monoStart = ContinuousClock.now
    /// Relojes de pared y monotónico + cambios de hora y segundo plano (viaja firmado en `integrityFlags`).
    @ObservationIgnored private let integrity = IntegrityMonitor()
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored private var handoffTask: Task<Void, Never>?
    @ObservationIgnored private var finishedIndex = -1
    @ObservationIgnored private var restartAfterBackground = false

    init(moment: Moment, quick: Bool = false, store: AppStore, game: GameStore, coach: CoachService) {
        self.moment = moment
        self.quick = quick
        self.store = store
        self.game = game
        self.coach = coach
        existingCheckIn = Self.todayPauseCheckIn(in: store)
        integrity.begin()
        coach.prewarm()
        Haptics.shared.prepare()
    }

    // MARK: Lecturas

    var profileName: String { store.profile.name }
    var treatment: Treatment { store.profile.treatment }
    /// Zonas habituales del perfil (preselección del check-in).
    var usualZones: [PainZone] { store.profile.allUsualZones }
    /// Momento vigente: el que se eligió en el check-in de esta pausa o, si no, el de apertura.
    /// Manda en la receta, en el `CoachInput` y en la sesión guardada.
    var effectiveMoment: Moment { selectedMoment ?? moment }
    /// "Solo tengo 1 minuto" → pausa rápida; si no, la ruta completa.
    let quick: Bool
    var recipeKind: RecipeKind { quick ? .relevo60 : effectiveMoment.recipe }

    var currentIndex: Int? {
        if case .activity(let i) = stage { return i }
        return nil
    }

    var isGentle: Bool {
        (decision?.gentle ?? false) || (checkIn?.score ?? 0) >= RDQ6.gentlePlanThreshold
    }

    /// Avance global para la barra del encabezado.
    var progressFraction: Double {
        switch stage {
        case .checkIn: 0.05
        case .alarm: 0.10
        case .stopped: 1
        case .planning: 0.15
        case .activity(let i): 0.2 + 0.6 * Double(i) / Double(max(1, plan.count))
        case .postCheck: 0.85
        case .reward: 1
        }
    }

    /// Segundos monotónicos desde que se abrió la pausa (ContinuousClock).
    var elapsedSeconds: Double {
        let d = monoStart.duration(to: .now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Último check-in de hoy hecho desde una pausa (los "Me duele ahora" no cuentan).
    static func todayPauseCheckIn(in store: AppStore, now: Date = .now) -> DailyCheckIn? {
        store.todayCheckIn(now: now)
    }

    // MARK: Check-in

    /// Guarda el check-in al instante (cuenta para estadísticas aunque no siga) y evalúa seguridad.
    /// `zones` es la selección múltiple de "¿Dónde le duele?" (vacía = "No me duele": se guarda sin zonas).
    func submitCheckIn(answers: [Bool], zones: [PainZone], moment checkInMoment: Moment) {
        guard answers.count == RDQ6.items.count else { return }
        let entry = store.makeCheckIn(date: .now, source: .pausa, answers: answers, zones: zones, moment: checkInMoment)
        store.addCheckIn(entry)
        checkIn = entry
        selectedMoment = checkInMoment
        existingCheckIn = nil
        evaluateSafety()
    }

    /// Sigue con el check-in de hoy ya respondido. Su momento es el de cuando se respondió (quizás
    /// otro relevo): aquí manda el momento con que se abrió la pausa.
    func continueWithExistingCheckIn() {
        guard let existingCheckIn else { return }
        checkIn = existingCheckIn
        selectedMoment = nil
        evaluateSafety()
    }

    /// "Volver a responder": muestra el cuestionario vacío.
    func answerAgain() {
        existingCheckIn = nil
        stage = .checkIn
    }

    private func evaluateSafety() {
        guard let checkIn else { return }
        let d = SafetyRules.evaluate(checkIn: checkIn)
        decision = d
        if d.stop || checkIn.hasAlarm {
            stage = .stopped
            Haptics.shared.warning()
            return
        }
        let high = checkIn.score >= RDQ6.gentlePlanThreshold
        if high && checkIn.alarmAnswers.count < RDQ6.alarmQuestions.count {
            stage = .alarm
            return
        }
        buildPlan()
    }

    // MARK: Alarma

    /// Guarda las respuestas de alarma en el mismo check-in; cualquier Sí → derivación sin ejercicio.
    func submitAlarm(answers: [Bool]) {
        guard var current = checkIn, answers.count == RDQ6.alarmQuestions.count else { return }
        current.alarmAnswers = answers
        store.addCheckIn(current)
        checkIn = current
        let d = SafetyRules.evaluate(checkIn: current)
        decision = d
        if d.stop || current.hasAlarm {
            stage = .stopped
            Haptics.shared.warning()
            return
        }
        buildPlan()
    }

    // MARK: Plan

    private func buildPlan() {
        let demo = store.data.demo.shortTargets
        let d = decision ?? SafetyRules.evaluate(checkIn: checkIn)
        let consent = store.profile.consentGiven
        // `apply` reemplaza la base por `Recipes.gentle` cuando la decisión es suave, filtra y escala metas.
        let safe = SafetyRules.apply(d, to: Recipes.base(recipeKind, demo: demo), demo: demo)
        // Segunda barrera del consentimiento: sin él no hay actividades de cámara (cara ni cuerpo).
        let filtered = Self.consentFiltered(safe, consentGiven: consent, allowed: d.allowed, demo: demo)
        let allowed = Self.consentAllowed(d.allowed, consentGiven: consent)
        cameraBlocked = !consent
        plan = SensorBlockPlanner.ordered(filtered.activities)
        // El "por qué" lo compone Swift con lo que la persona respondió (nunca la IA).
        coachWhy = PlanWhy.compose(decision: d, checkIn: checkIn, cameraBlocked: !consent)
        excluded = PlanExclusions.explain(recipe: recipeKind, decision: d, checkIn: checkIn, consentGiven: consent,
                                          baseKinds: Recipes.base(recipeKind, demo: demo).activities.map(\.kind),
                                          planKinds: plan.map(\.kind))
        coachStartMessage = nil
        coachBackend = nil
        stage = .planning
        let reduced = d.stepTargetFactor < 1 || d.shorterActivities
        requestCoachPlan(base: filtered, allowed: allowed, demo: demo, reducedTargets: reduced)
    }

    /// Actividades que usan la cámara (cara con ARKit, cuerpo con Vision).
    nonisolated static func usesCamera(_ kind: ActivityKind) -> Bool {
        kind.sensorBlock == .face || kind.sensorBlock == .cameraPose
    }

    /// Tipos permitidos para el coach: sin consentimiento, fuera los de cámara.
    nonisolated static func consentAllowed(_ allowed: [ActivityKind], consentGiven: Bool) -> [ActivityKind] {
        consentGiven ? allowed : allowed.filter { !usesCamera($0) }
    }

    /// Quita las actividades de cámara sin consentimiento. Si la receta queda vacía (relevo: cuello + ojos)
    /// y las reglas lo permiten, deja el Stroop, que solo usa la pantalla.
    nonisolated static func consentFiltered(_ recipe: Recipe, consentGiven: Bool, allowed: [ActivityKind], demo: Bool) -> Recipe {
        guard !consentGiven, !recipe.activities.isEmpty else { return recipe }
        var activities = recipe.activities.filter { !usesCamera($0.kind) }
        if activities.isEmpty, allowed.contains(.stroop) {
            activities = [Recipes.assignment(.stroop, demo: demo)]
        }
        return Recipe(kind: recipe.kind, activities: activities)
    }

    /// Pide el ajuste al coach en paralelo; se aplica solo si llega a tiempo (ver `adopt`).
    private func requestCoachPlan(base: Recipe, allowed: [ActivityKind], demo: Bool, reducedTargets: Bool) {
        planTask?.cancel()
        let history = StatsEngine.summary(data: store.data, calendar: store.calendar, now: .now).historyLines
        let m = effectiveMoment
        let input = CoachInput(profileName: store.profile.name, treatment: store.profile.treatment, checkIn: checkIn,
                               moment: m, minutesAvailable: recipeKind.minutes, baseRecipe: base,
                               allowedKinds: allowed, historyLines: Array(history.prefix(10)), gentle: isGentle)
        let minutes = recipeKind.minutes
        planTask = Task { [weak self] in
            guard let self else { return }
            guard let proposal = await self.planWithTimeout(input) else { return }
            guard !Task.isCancelled, self.stage == .planning else { return }
            guard let adoption = Self.adopt(proposal, current: self.plan, input: input, base: base, minutes: minutes,
                                            demo: demo, reducedTargets: reducedTargets) else { return }
            let adjusted = adoption.plan != self.plan
            let removed = Set(self.plan.map(\.kind)).subtracting(adoption.plan.map(\.kind))
            self.plan = adoption.plan
            self.excluded = PlanExclusions.explain(
                recipe: self.recipeKind, decision: self.decision ?? SafetyRules.evaluate(checkIn: self.checkIn),
                checkIn: self.checkIn, consentGiven: !self.cameraBlocked,
                baseKinds: Recipes.base(self.recipeKind, demo: demo).activities.map(\.kind),
                planKinds: adoption.plan.map(\.kind), coachRemoved: removed)
            self.coachWhy = PlanWhy.compose(decision: self.decision ?? SafetyRules.evaluate(checkIn: self.checkIn),
                                            checkIn: self.checkIn, cameraBlocked: self.cameraBlocked,
                                            coachAdjustedTargets: adjusted && proposal.backend == .foundationModels)
            self.coachStartMessage = proposal.backend == .foundationModels
                ? PlanWhy.sanitizedStartMessage(adoption.startMessage)
                : adoption.startMessage
            self.coachBackend = proposal.backend
        }
    }

    /// Lo que se toma de la respuesta del coach.
    nonisolated struct CoachAdoption: Sendable, Equatable {
        var plan: [ActivityAssignment]
        var why: String?
        var startMessage: String?
    }

    /// - Reglas (`.rules`): solo el "por qué" y el mensaje de inicio. Las metas quedan las de la receta ya
    ///   filtrada (la plantilla volvería a escalar ×0,6 el plan suave que `Recipes.gentle` ya redujo).
    /// - IA (`.foundationModels`): metas y textos, solo si el plan pasa las dos barreras de `validated`.
    nonisolated static func adopt(_ proposal: PausePlan, current: [ActivityAssignment], input: CoachInput, base: Recipe,
                                  minutes: Int, demo: Bool, reducedTargets: Bool) -> CoachAdoption? {
        let why = proposal.why.isEmpty ? nil : proposal.why
        let start = proposal.startMessage.isEmpty ? nil : proposal.startMessage
        switch proposal.backend {
        case .rules:
            guard why != nil || start != nil else { return nil }
            return CoachAdoption(plan: current, why: why, startMessage: start)
        case .foundationModels:
            guard let accepted = validated(proposal, input: input, base: base, minutes: minutes, demo: demo,
                                           reducedTargets: reducedTargets) else { return nil }
            // El coach ajusta metas, no quita ni agrega ejercicios: la ruta la deciden las reglas.
            let merged = current.map { a in accepted.first { $0.kind == a.kind }.map { ActivityAssignment(kind: a.kind, target: $0.target) } ?? a }
            return CoachAdoption(plan: merged, why: why, startMessage: start)
        }
    }

    /// El LLM nunca decide solo: su plan pasa por `PlanValidator` (ids, duplicados, reps, duración) y,
    /// como todo plan del coach, por `SessionPlanCheck` (segunda barrera). La plantilla por reglas no
    /// pasa por `PlanValidator` (campamento trae más ejercicios que el máximo del prompt).
    /// `reducedTargets`: las reglas ya bajaron metas (caminata corta, de pie por poco rato, plan suave);
    /// entonces el techo es la meta reducida (1×), no el doble.
    nonisolated static func validated(_ proposal: PausePlan, input: CoachInput, base: Recipe, minutes: Int, demo: Bool,
                                      reducedTargets: Bool = false) -> [ActivityAssignment]? {
        var activities = proposal.activities
        if proposal.backend == .foundationModels {
            let proposed = activities.map { ProposedExercise(id: $0.kind.rawValue, reps: $0.target) }
            guard case .success(let valid) = PlanValidator.validate(proposed, input: input) else { return nil }
            activities = valid
        }
        guard SessionPlanCheck.accepts(proposal, allowed: input.allowedKinds, base: base, minutes: minutes, demo: demo,
                                       reducedTargets: reducedTargets) else { return nil }
        return activities
    }

    private func planWithTimeout(_ input: CoachInput) async -> PausePlan? {
        let coach = self.coach
        return await withTaskGroup(of: PausePlan?.self) { group in
            group.addTask { await coach.plan(input) }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.coachTimeoutSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Actividades

    /// "Empezar": congela el plan y arranca la primera actividad.
    func startActivities() {
        planTask?.cancel()
        planTask = nil
        results = []
        finishedIndex = -1
        guard !plan.isEmpty else {
            stage = .postCheck
            return
        }
        enter(index: 0)
    }

    private func enter(index: Int) {
        guard plan.indices.contains(index) else { return }
        let demo = store.data.demo.shortTargets
        runner = ActivityRunnerFactory.make(assignment: plan[index], demo: demo)
        runnerGeneration += 1
        stage = .activity(index)
    }

    /// La vista llama cuando el runner publica su `outcome`. `index` evita aplicar un resultado tardío a otra actividad.
    func activityFinished(_ outcome: ActivityOutcome, at index: Int) {
        guard index == currentIndex, index > finishedIndex, outcome.kind == plan[index].kind else { return }
        if outcome.reason == .backgrounded {
            // Actividad de cámara/cara interrumpida: se reinicia al volver, no se registra.
            restartAfterBackground = true
            return
        }
        // El `ActivityResult` sale SOLO del runner (testigo `Verified`): nunca se arma aquí.
        guard let result = runner?.verifiedResult, result.kind == outcome.kind else { return }
        finishedIndex = index
        results.append(result)
        advance(from: index)
    }

    /// "Saltar (no suma)": detiene el runner y registra la actividad como saltada.
    func skipCurrent() {
        guard let index = currentIndex, index > finishedIndex else { return }
        // Sin runner (p. ej. durante el relevo de cámara) se usa el provisional, que también entrega un resultado con testigo.
        let current = runner ?? PlaceholderRunner(assignment: plan[index])
        if current.outcome == nil { current.stop(reason: .skipped) }
        guard let outcome = current.outcome else { return }
        runner = current
        activityFinished(outcome, at: index)
    }

    private func advance(from index: Int) {
        runner = nil
        handoffTask?.cancel()
        handoffTask = nil
        let next = index + 1
        guard next < plan.count else {
            stage = .postCheck
            return
        }
        let from = plan[index].kind.sensorBlock
        let to = plan[next].kind.sensorBlock
        guard SensorBlockPlanner.needsCameraHandoff(from: from, to: to) else {
            enter(index: next)
            return
        }
        // ARSession y AVCaptureSession no conviven: la fuente anterior ya hizo `stop()` al cerrar el runner;
        // se espera un instante ("Preparando cámara…") antes del `start()` de la siguiente.
        stage = .activity(next)
        handoffTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.cameraHandoffSeconds))
            guard let self, !Task.isCancelled, self.stage == .activity(next), self.runner == nil else { return }
            self.enter(index: next)
        }
    }

    // MARK: Ciclo de vida de la app

    /// A background a mitad de una actividad de cámara/cara: se detiene y se reinicia al volver (no se completa).
    func appWentToBackground() {
        integrity.noteBackgrounded()
        guard let index = currentIndex, index > finishedIndex, let runner, runner.outcome == nil else { return }
        let block = plan[index].kind.sensorBlock
        guard block == .cameraPose || block == .face else { return }
        restartAfterBackground = true
        runner.stop(reason: .backgrounded)
    }

    func appBecameActive() {
        integrity.noteForegrounded()
        // La caminata sigue en background: al volver se acredita lo que contó el coprocesador.
        runner?.stepSource?.resumeReconciliation()
        guard restartAfterBackground, let index = currentIndex, index > finishedIndex else { return }
        restartAfterBackground = false
        enter(index: index)
    }

    /// Cierre anticipado desde la X: libera sensores; nada se registra como sesión.
    func cancel() {
        planTask?.cancel()
        planTask = nil
        handoffTask?.cancel()
        handoffTask = nil
        if let runner, runner.outcome == nil { runner.stop(reason: .userStopped) }
        runner = nil
        integrity.cancel()
        Haptics.shared.release()
    }

    // MARK: Cierre

    /// "¿Y ahora la espalda?": arma, firma y registra la sesión.
    func submitPost(_ response: PostResponse) {
        guard stage == .postCheck, !isFinishing else { return }
        post = response
        isFinishing = true
        Task { await self.finish() }
    }

    /// Compone `PauseSession`, la firma (si falla, queda sin firma) y pide el premio a `GameStore`.
    func finish() async {
        var s = composeSession()
        do {
            s = try await SessionSigner.shared.signed(s)
            signError = nil
        } catch {
            signError = error.localizedDescription
            s.payloadData = nil
            s.signature = nil
            s.keyID = nil
            s.backing = nil
        }
        // `GameStore.record` calcula XP/racha/insignias y guarda la sesión en el store.
        let r = game.record(s)
        session = s
        reward = r
        isFinishing = false
        stage = .reward
        // El aviso diario de hoy ya no hace falta si la pausa contó.
        DailyNotice.refresh(store: store)
        // La háptica de celebración la dispara `CelebrationView` junto con su escalera (no se duplica aquí).
    }

    private func composeSession() -> PauseSession {
        let cal = store.calendar
        // Leer el monotónico antes de `end()` (que cierra el monitor) y adjuntar sus banderas firmadas.
        let monotonic = integrity.monotonicSeconds
        let flags = integrity.end()
        let hardIntegrity = flags.contains { $0.severity == .hard }
        let simulated = results.contains { $0.level == .simulated }
        var level = VerificationPolicy.sessionLevel(results)
        if hardIntegrity { level = min(level, .suspicious) }
        let counted = VerificationPolicy.counts(results) && !simulated && !hardIntegrity && checkIn != nil && post != nil
        // El momento del chip del check-in manda (si se respondió en esta pausa); la receta es la de la
        // pausa hecha (rápida si eligió "Solo tengo 1 minuto", si no la ruta completa).
        let m = effectiveMoment
        var s = PauseSession(workDayKey: cal.key(for: startedAt), turnoKey: cal.turnoKey(for: startedAt),
                             recipe: recipeKind, moment: m, startedAt: startedAt, endedAt: .now,
                             monotonicSeconds: monotonic, checkInScore: checkIn?.score,
                             checkInAnswers: checkIn?.answers ?? [], zone: checkIn?.zone ?? store.profile.usualZone,
                             postResponse: post, activities: results, counted: counted,
                             level: level, simulated: simulated, coachNote: coachWhy)
        s.setZones(checkIn?.allZones ?? store.profile.allUsualZones)
        s.integrityFlags = flags
        return s
    }
}

// MARK: - Validación del plan del coach

/// El LLM nunca decide solo: ids permitidos, sin repetidos, reps acotadas y duración dentro del momento.
/// Segunda barrera después de `PlanValidator` (paquete coach); usa la duración mínima de verificación.
nonisolated enum SessionPlanCheck {
    /// Máximo de actividades que acepta el plan del coach (el `@Guide(.count(1...5))` del prompt).
    static let maxActivities = 5
    /// Reps máximas respecto de la meta base.
    static let maxTargetFactor = 2.0
    /// Techo cuando `SafetyRules` ya redujo metas: nunca sobre la meta reducida.
    static let reducedTargetFactor = 1.0
    /// Tolerancia sobre los minutos del momento (la estimación es un mínimo).
    static let durationTolerance = 1.25
    /// Segundos de preparación por actividad (gating, colocación del teléfono).
    static let setupSecondsPerActivity: Double = 5

    /// `reducedTargets`: las reglas clínicas ya bajaron las metas; el techo pasa a ser la meta reducida (1×).
    static func accepts(_ plan: PausePlan, allowed: [ActivityKind], base: Recipe, minutes: Int, demo: Bool,
                        reducedTargets: Bool = false) -> Bool {
        let acts = plan.activities
        let maxCount = max(maxActivities, base.activities.count)
        guard !acts.isEmpty, acts.count <= maxCount else { return false }
        guard Set(acts.map(\.kind)).count == acts.count else { return false }
        let factor = reducedTargets ? reducedTargetFactor : maxTargetFactor
        for a in acts {
            guard allowed.contains(a.kind), a.target >= 1 else { return false }
            let reference = base.activities.first { $0.kind == a.kind }?.target ?? (demo ? a.kind.demoTarget : a.kind.defaultTarget)
            guard Double(a.target) <= Double(reference) * factor else { return false }
        }
        return estimatedSeconds(acts, demo: demo) <= Double(minutes * 60) * durationTolerance
    }

    /// Duración mínima estimada del plan (suma de `VerificationSpec.minDurationSeconds` + preparación).
    static func estimatedSeconds(_ activities: [ActivityAssignment], demo: Bool) -> Double {
        activities.reduce(0) { acc, a in
            acc + VerificationSpec.standard(for: a.kind, target: a.target, demo: demo).minDurationSeconds + setupSecondsPerActivity
        }
    }
}
