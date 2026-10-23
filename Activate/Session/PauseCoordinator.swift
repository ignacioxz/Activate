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

    init(moment: Moment, store: AppStore, game: GameStore, coach: CoachService) {
        self.moment = moment
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
    var usualZone: PainZone { store.profile.usualZone }
    var recipeKind: RecipeKind { moment.recipe }

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
    func submitCheckIn(answers: [Bool], zone: PainZone, moment checkInMoment: Moment) {
        guard answers.count == RDQ6.items.count else { return }
        let entry = store.makeCheckIn(date: .now, source: .pausa, answers: answers, zone: zone, moment: checkInMoment)
        store.addCheckIn(entry)
        checkIn = entry
        existingCheckIn = nil
        evaluateSafety()
    }

    /// Sigue con el check-in de hoy ya respondido.
    func continueWithExistingCheckIn() {
        guard let existingCheckIn else { return }
        checkIn = existingCheckIn
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
        // `apply` reemplaza la base por `Recipes.gentle` cuando la decisión es suave, filtra y escala metas.
        let filtered = SafetyRules.apply(d, to: Recipes.base(moment.recipe, demo: demo), demo: demo)
        plan = SensorBlockPlanner.ordered(filtered.activities)
        coachWhy = nil
        coachStartMessage = nil
        coachBackend = nil
        stage = .planning
        requestCoachPlan(base: filtered, allowed: d.allowed, demo: demo)
    }

    /// Pide el ajuste al coach en paralelo; se aplica solo si llega a tiempo y pasa la validación.
    private func requestCoachPlan(base: Recipe, allowed: [ActivityKind], demo: Bool) {
        planTask?.cancel()
        let history = StatsEngine.summary(data: store.data, calendar: store.calendar, now: .now).historyLines
        let input = CoachInput(profileName: store.profile.name, treatment: store.profile.treatment, checkIn: checkIn,
                               moment: moment, minutesAvailable: moment.minutes, baseRecipe: base,
                               allowedKinds: allowed, historyLines: Array(history.prefix(10)), gentle: isGentle)
        let minutes = moment.minutes
        planTask = Task { [weak self] in
            guard let self else { return }
            guard let proposal = await self.planWithTimeout(input) else { return }
            guard !Task.isCancelled, self.stage == .planning else { return }
            guard let accepted = Self.validated(proposal, input: input, base: base, minutes: minutes, demo: demo) else { return }
            self.plan = SensorBlockPlanner.ordered(accepted)
            self.coachWhy = proposal.why.isEmpty ? nil : proposal.why
            self.coachStartMessage = proposal.startMessage.isEmpty ? nil : proposal.startMessage
            self.coachBackend = proposal.backend
        }
    }

    /// El LLM nunca decide solo: su plan pasa por `PlanValidator` (ids, duplicados, reps, duración) y,
    /// como todo plan del coach, por `SessionPlanCheck` (segunda barrera). La plantilla por reglas no
    /// pasa por `PlanValidator` (campamento trae más ejercicios que el máximo del prompt).
    nonisolated static func validated(_ proposal: PausePlan, input: CoachInput, base: Recipe, minutes: Int, demo: Bool) -> [ActivityAssignment]? {
        var activities = proposal.activities
        if proposal.backend == .foundationModels {
            let proposed = activities.map { ProposedExercise(id: $0.kind.rawValue, reps: $0.target) }
            guard case .success(let valid) = PlanValidator.validate(proposed, input: input) else { return nil }
            activities = valid
        }
        guard SessionPlanCheck.accepts(proposal, allowed: input.allowedKinds, base: base, minutes: minutes, demo: demo) else { return nil }
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

    /// "EMPEZAR": congela el plan y arranca la primera actividad.
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
        var s = PauseSession(workDayKey: cal.key(for: startedAt), turnoKey: cal.turnoKey(for: startedAt),
                             recipe: moment.recipe, moment: moment, startedAt: startedAt, endedAt: .now,
                             monotonicSeconds: monotonic, checkInScore: checkIn?.score,
                             checkInAnswers: checkIn?.answers ?? [], zone: checkIn?.zone ?? store.profile.usualZone,
                             postResponse: post, activities: results, counted: counted,
                             level: level, simulated: simulated, coachNote: coachWhy)
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
    /// Tolerancia sobre los minutos del momento (la estimación es un mínimo).
    static let durationTolerance = 1.25
    /// Segundos de preparación por actividad (gating, colocación del teléfono).
    static let setupSecondsPerActivity: Double = 5

    static func accepts(_ plan: PausePlan, allowed: [ActivityKind], base: Recipe, minutes: Int, demo: Bool) -> Bool {
        let acts = plan.activities
        let maxCount = max(maxActivities, base.activities.count)
        guard !acts.isEmpty, acts.count <= maxCount else { return false }
        guard Set(acts.map(\.kind)).count == acts.count else { return false }
        for a in acts {
            guard allowed.contains(a.kind), a.target >= 1 else { return false }
            let reference = base.activities.first { $0.kind == a.kind }?.target ?? (demo ? a.kind.demoTarget : a.kind.defaultTarget)
            guard Double(a.target) <= Double(reference) * maxTargetFactor else { return false }
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
