import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Dueño: agente "coach". Coach con el modelo local de Apple. Sesión nueva por petición,
// timeout propio, validación en Swift y plantilla ante cualquier error.

/// Errores del modelo mapeados a algo que la app entiende (y puede mostrar en Perfil).
nonisolated enum CoachModelError: Error, Equatable, Sendable {
    case contextSizeExceeded(tokens: Int, limit: Int)
    case rateLimited(resetAt: Date?)
    case guardrailViolation
    case refusal
    case unsupportedLocale(String?)
    case timeout
    case assetsUnavailable
    case invalidOutput(String)
    case unavailable
    case other(String)

    var title: String {
        switch self {
        case .contextSizeExceeded: "Prompt demasiado largo"
        case .rateLimited: "Modelo ocupado"
        case .guardrailViolation: "Contenido bloqueado por el modelo"
        case .refusal: "El modelo no respondió"
        case .unsupportedLocale: "Idioma no soportado"
        case .timeout: "El modelo tardó demasiado"
        case .assetsUnavailable: "Modelo no descargado"
        case .invalidOutput(let why): "Respuesta descartada: \(why)"
        case .unavailable: "Apple Intelligence no disponible"
        case .other(let why): "Error del modelo: \(why)"
        }
    }
}

/// Carrera entre un trabajo y un reloj: devuelve lo primero que llegue; el perdedor se cancela
/// y, si el modelo no respeta la cancelación, su resultado tardío se descarta.
nonisolated enum CoachTimeout {
    static func race<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let box = ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                box.attach(cont)
                let worker = Task {
                    do { box.resume(.success(try await work())) }
                    catch { box.resume(.failure(error)) }
                }
                let clock = Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                    box.resume(.failure(CoachModelError.timeout))
                    worker.cancel()
                }
                box.setOnResume { clock.cancel() }
            }
        } onCancel: {
            box.resume(.failure(CancellationError()))
        }
    }

    nonisolated final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var done = false
        private var onResume: (@Sendable () -> Void)?

        func attach(_ c: CheckedContinuation<T, Error>) {
            lock.lock(); continuation = c; lock.unlock()
        }

        /// Si ya se resolvió antes de registrar el cierre, se ejecuta de inmediato.
        func setOnResume(_ body: @escaping @Sendable () -> Void) {
            lock.lock()
            if done { lock.unlock(); body(); return }
            onResume = body
            lock.unlock()
        }

        func resume(_ result: Result<T, Error>) {
            lock.lock()
            guard !done, let c = continuation else { lock.unlock(); return }
            done = true
            continuation = nil
            let after = onResume
            lock.unlock()
            c.resume(with: result)
            after?()
        }
    }
}

#if canImport(FoundationModels)

nonisolated struct FoundationModelsCoach: Coach {
    var backend: CoachBackend { .foundationModels }

    // Presupuestos (segundos y tokens); se calibran en el iPhone de demo.
    static let planTimeoutSeconds: Double = 3.5
    static let statsTimeoutSeconds: Double = 8
    static let kineTimeoutSeconds: Double = 15
    static let planMaxTokens = 320
    static let statsMaxTokens = 220
    static let kineMaxTokens = 600
    static let planTemperature = 0.5

    init() {}

    // MARK: - Coach (nunca lanza: ante cualquier error devuelve la plantilla)

    func plan(_ input: CoachInput) async throws -> PausePlan {
        await planResult(input).value
    }

    func statsReading(_ summary: StatsSummary, profile: PlayerProfile) async throws -> StatsReading {
        await statsReadingResult(summary, profile: profile).value
    }

    func kineSheet(_ summary: StatsSummary, profile: PlayerProfile) async throws -> KineSheet {
        await kineSheetResult(summary, profile: profile).value
    }

    /// Resultado + motivo del fallback (si lo hubo), para que el servicio lo registre.
    nonisolated struct Outcome<T: Sendable>: Sendable {
        var value: T
        var error: CoachModelError?
    }

    // MARK: - Pausa del día

    func planResult(_ input: CoachInput) async -> Outcome<PausePlan> {
        let template = RuleBasedCoach.makePlan(input)
        guard !input.allowedKinds.isEmpty else { return Outcome(value: template, error: nil) }
        let prompt = CoachPrompts.planPrompt(input)
        let options = GenerationOptions(temperature: Self.planTemperature, maximumResponseTokens: Self.planMaxTokens)
        do {
            let raw = try await CoachTimeout.race(seconds: Self.planTimeoutSeconds) {
                let session = LanguageModelSession(instructions: CoachPrompts.instructions)
                return try await session.respond(to: prompt, generating: PausaDelDia.self, options: options, contextOptions: ContextOptions(includeSchemaInPrompt: true)).content
            }
            switch Self.plan(from: raw, input: input, template: template) {
            case .success(let plan): return Outcome(value: plan, error: nil)
            case .failure(let err): return Outcome(value: template, error: err)
            }
        } catch {
            return Outcome(value: template, error: Self.map(error))
        }
    }

    /// Convierte y valida la salida del modelo. Pura; si algo no cuadra, la receta base.
    static func plan(from raw: PausaDelDia, input: CoachInput, template: PausePlan) -> Result<PausePlan, CoachModelError> {
        switch PlanValidator.validate(raw.proposal, input: input) {
        case .failure(let f):
            return .failure(.invalidOutput(describe(f)))
        case .success(let activities):
            let why = CoachText.clean(raw.porQue, maxWords: CoachText.maxShortWords) ?? template.why
            let start = CoachText.clean(raw.mensajeInicio, maxWords: CoachText.maxShortWords) ?? template.startMessage
            let reasoning = CoachText.clean(raw.razonamiento, maxWords: 60) ?? template.reasoning
            return .success(PausePlan(activities: activities,
                                      reasoning: "[\(CoachPrompts.version)] " + reasoning,
                                      why: why, startMessage: start, backend: .foundationModels))
        }
    }

    static func describe(_ f: PlanValidator.Failure) -> String {
        switch f {
        case .empty: "plan vacío"
        case .unknownID(let id): "id desconocido \(id)"
        case .notAllowed(let k): "ejercicio no permitido hoy: \(k.rawValue)"
        case .duplicate(let k): "ejercicio repetido: \(k.rawValue)"
        case .repsOutOfRange(let k, let reps, let max): "reps fuera de rango en \(k.rawValue): \(reps) (máx. \(max))"
        case .durationExceeded(let est, let limit): "duración \(est) s supera \(limit) s"
        case .tooMany(let n): "demasiados ejercicios: \(n)"
        }
    }

    // MARK: - Lectura de datos

    func statsReadingResult(_ summary: StatsSummary, profile: PlayerProfile) async -> Outcome<StatsReading> {
        let template = RuleBasedCoach.makeReading(summary, profile: profile)
        let prompt = CoachPrompts.statsPrompt(summary, profile: profile)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: Self.statsMaxTokens)
        do {
            let raw = try await CoachTimeout.race(seconds: Self.statsTimeoutSeconds) {
                let session = LanguageModelSession(instructions: CoachPrompts.instructions)
                return try await session.respond(to: prompt, generating: LecturaDatos.self, options: options, contextOptions: ContextOptions(includeSchemaInPrompt: true)).content
            }
            let sentences = raw.frases.compactMap { CoachText.clean($0, maxWords: CoachText.maxSentenceWords) }
            guard sentences.count == 3 else {
                return Outcome(value: template, error: .invalidOutput("se esperaban 3 frases"))
            }
            // La tendencia es un cálculo de Swift; el modelo solo la nombra. Si discrepa, manda Swift.
            let trend = RuleBasedCoach.trend(summary)
            let modelTrend = raw.trendValue ?? trend
            return Outcome(value: StatsReading(sentences: sentences,
                                               trend: trend == .sinDatos ? modelTrend : trend,
                                               backend: .foundationModels), error: nil)
        } catch {
            return Outcome(value: template, error: Self.map(error))
        }
    }

    // MARK: - Hoja para el kine

    func kineSheetResult(_ summary: StatsSummary, profile: PlayerProfile) async -> Outcome<KineSheet> {
        let template = RuleBasedCoach.makeKineSheet(summary, profile: profile)
        let prompt = CoachPrompts.kinePrompt(summary, profile: profile)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: Self.kineMaxTokens)
        do {
            let raw = try await CoachTimeout.race(seconds: Self.kineTimeoutSeconds) {
                let session = LanguageModelSession(instructions: CoachPrompts.instructions)
                return try await session.respond(to: prompt, generating: HojaKine.self, options: options, contextOptions: ContextOptions(includeSchemaInPrompt: true)).content
            }
            let max = CoachText.maxBlockWords
            guard let when = CoachText.clean(raw.cuandoLeDuele, maxWords: max),
                  let did = CoachText.clean(raw.queHizo, maxWords: max),
                  let worsens = CoachText.clean(raw.queLoEmpeora, maxWords: max),
                  let goes = CoachText.clean(raw.comoVa, maxWords: max),
                  let alerts = CoachText.clean(raw.alertas, maxWords: max) else {
                return Outcome(value: template, error: .invalidOutput("bloque vacío o con texto prohibido"))
            }
            return Outcome(value: KineSheet(period: template.period, whenItHurts: when, whatHeDid: did,
                                            whatWorsens: worsens, howItGoes: goes, alerts: alerts,
                                            backend: .foundationModels), error: nil)
        } catch {
            return Outcome(value: template, error: Self.map(error))
        }
    }

    // MARK: - Mapeo de errores del framework

    static func map(_ error: Error) -> CoachModelError {
        if let own = error as? CoachModelError { return own }
        if error is CancellationError { return .timeout }
        if let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded(let c): return .contextSizeExceeded(tokens: c.tokenCount, limit: c.contextSize)
            case .rateLimited(let r): return .rateLimited(resetAt: r.resetDate)
            case .guardrailViolation: return .guardrailViolation
            case .refusal: return .refusal
            case .unsupportedLanguageOrLocale(let u): return .unsupportedLocale(u.languageCode.identifier)
            case .timeout: return .timeout
            default: return .other(String(describing: e))
            }
        }
        if let e = error as? SystemLanguageModel.Error {
            switch e {
            case .assetsUnavailable: return .assetsUnavailable
            @unknown default: return .other(String(describing: e))
            }
        }
        return .other(error.localizedDescription)
    }
}

#else

/// Sin el framework (SDK antiguo): el coach "IA" es la plantilla.
nonisolated struct FoundationModelsCoach: Coach {
    var backend: CoachBackend { .foundationModels }
    nonisolated struct Outcome<T: Sendable>: Sendable { var value: T; var error: CoachModelError? }
    init() {}
    func plan(_ input: CoachInput) async throws -> PausePlan { RuleBasedCoach.makePlan(input) }
    func statsReading(_ summary: StatsSummary, profile: PlayerProfile) async throws -> StatsReading { RuleBasedCoach.makeReading(summary, profile: profile) }
    func kineSheet(_ summary: StatsSummary, profile: PlayerProfile) async throws -> KineSheet { RuleBasedCoach.makeKineSheet(summary, profile: profile) }
    func planResult(_ input: CoachInput) async -> Outcome<PausePlan> { Outcome(value: RuleBasedCoach.makePlan(input), error: .unavailable) }
    func statsReadingResult(_ summary: StatsSummary, profile: PlayerProfile) async -> Outcome<StatsReading> { Outcome(value: RuleBasedCoach.makeReading(summary, profile: profile), error: .unavailable) }
    func kineSheetResult(_ summary: StatsSummary, profile: PlayerProfile) async -> Outcome<KineSheet> { Outcome(value: RuleBasedCoach.makeKineSheet(summary, profile: profile), error: .unavailable) }
}

#endif
