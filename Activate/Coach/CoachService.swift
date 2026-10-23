import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Dueño: agente "coach". Gate de disponibilidad + elección de backend + latencia + fallback.
// Firma pública congelada: Availability, availability, backend, override, lastLatencyMs,
// refreshAvailability(), prewarm(), plan(_:), statsReading(_:profile:).
// Hoja del kine (paquete kine-ai): kineModelReady, kineUnavailableReason, kineConsult(_:profile:onPartial:),
// patientNote(_:profile:). La genera la persona con un botón; nunca se dispara sola.

@Observable
final class CoachService {
    nonisolated enum Availability: Sendable, Equatable { case available, deviceNotEligible, notEnabled, modelNotReady, localeUnsupported, unknown }

    private(set) var availability: Availability = .unknown
    private(set) var backend: CoachBackend = .rules
    var override: CoachOverride = .auto {
        didSet { backend = resolvedBackend() }
    }
    private(set) var lastLatencyMs: Int?
    /// Último motivo por el que se usó la plantilla con el modelo activo (nil = el modelo respondió).
    private(set) var lastModelError: CoachModelError?
    /// Backend que produjo la última respuesta (puede ser `.rules` aunque `backend` sea `.foundationModels`).
    private(set) var lastAnsweredBy: CoachBackend?

    @ObservationIgnored private let rules = RuleBasedCoach()
    @ObservationIgnored private let models = FoundationModelsCoach()
    #if canImport(FoundationModels)
    @ObservationIgnored private var warmSession: LanguageModelSession?
    #endif

    /// Locales aceptados: es_CL primero; el modelo cae a es-419 si hace falta.
    nonisolated static let acceptedLocales = ["es_CL", "es_419", "es"]

    init() {}

    // MARK: - Gate

    func refreshAvailability() {
        availability = Self.readAvailability()
        backend = resolvedBackend()
    }

    nonisolated static func readAvailability() -> Availability {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            let ok = acceptedLocales.contains { model.supportsLocale(Locale(identifier: $0)) }
            return ok ? .available : .localeUnsupported
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown
            }
        }
        #else
        return .deviceNotEligible
        #endif
    }

    /// `.rules` fuerza plantillas; `.ai` fuerza el modelo si el sistema lo tiene (aunque el locale no
    /// sea es_CL: cae a es-419); `.auto` exige disponibilidad y locale.
    private func resolvedBackend() -> CoachBackend {
        switch override {
        case .rules: return .rules
        case .ai: return (availability == .available || availability == .localeUnsupported) ? .foundationModels : .rules
        case .auto: return availability == .available ? .foundationModels : .rules
        }
    }

    /// Texto corto para la tarjeta de Perfil.
    var statusTitle: String {
        switch availability {
        case .available: backend == .foundationModels ? "Coach con Apple Intelligence" : "Coach con reglas"
        case .deviceNotEligible: "Este iPhone no tiene Apple Intelligence"
        case .notEnabled: "Apple Intelligence está apagado"
        case .modelNotReady: "El modelo se está preparando"
        case .localeUnsupported: "El modelo no habla español de Chile"
        case .unknown: "Comprobando el coach"
        }
    }

    /// Conviene mostrar la tarjeta "cómo activar Apple Intelligence".
    var shouldSuggestEnabling: Bool { availability == .notEnabled }

    // MARK: - Prewarm (al entrar al check-in)

    func prewarm() {
        #if canImport(FoundationModels)
        guard backend == .foundationModels else { return }
        let session = LanguageModelSession(instructions: CoachPrompts.instructions)
        session.prewarm()
        warmSession = session
        #endif
    }

    // MARK: - Trabajos (siempre devuelven algo)

    func plan(_ input: CoachInput) async -> PausePlan {
        let start = ContinuousClock.now
        defer { record(start) }
        if backend == .foundationModels {
            let out = await models.planResult(input)
            lastModelError = out.error
            lastAnsweredBy = out.value.backend
            return out.value
        }
        lastModelError = nil
        lastAnsweredBy = .rules
        return RuleBasedCoach.makePlan(input)
    }

    func statsReading(_ summary: StatsSummary, profile: PlayerProfile) async -> StatsReading {
        let start = ContinuousClock.now
        defer { record(start) }
        if backend == .foundationModels {
            let out = await models.statsReadingResult(summary, profile: profile)
            lastModelError = out.error
            lastAnsweredBy = out.value.backend
            return out.value
        }
        lastModelError = nil
        lastAnsweredBy = .rules
        return RuleBasedCoach.makeReading(summary, profile: profile)
    }

    // MARK: - Consulta con el kine

    /// El botón "Preparar con Apple Intelligence" está activo (modelo disponible y sin override de reglas).
    var kineModelReady: Bool { backend == .foundationModels }

    /// Explicación breve cuando el botón está deshabilitado (nil si está activo).
    var kineUnavailableReason: String? {
        guard !kineModelReady else { return nil }
        if override == .rules && (availability == .available || availability == .localeUnsupported) {
            return "El coach está en modo reglas. Cámbielo en Perfil para preparar el reporte."
        }
        switch availability {
        case .deviceNotEligible: return "Este iPhone no tiene Apple Intelligence. Puede compartir el reporte igual."
        case .modelNotReady: return "Apple Intelligence se está preparando. Pruebe en unos minutos."
        case .localeUnsupported: return "Apple Intelligence no está disponible en este idioma."
        case .notEnabled, .unknown, .available: return "Active Apple Intelligence en Ajustes para preparar el reporte."
        }
    }

    /// Elige y explica 3 hechos, propone 3 preguntas y un foco. Con el modelo, `onPartial` recibe los
    /// borradores mientras escribe; sin modelo (o ante error) devuelve la plantilla al tiro.
    func kineConsult(_ facts: [KineFact], profile: PlayerProfile,
                     onPartial: (@MainActor @Sendable (KineConsultDraft) -> Void)? = nil) async -> KineConsult {
        let start = ContinuousClock.now
        defer { record(start) }
        if backend == .foundationModels {
            var forward: (@Sendable (KineConsultDraft) async -> Void)?
            if let onPartial {
                forward = { @Sendable draft in await onPartial(draft) }
            }
            let out = await models.kineConsultResult(facts, profile: profile, onPartial: forward)
            lastModelError = out.error
            lastAnsweredBy = out.value.backend
            return out.value
        }
        lastModelError = nil
        lastAnsweredBy = .rules
        return KineConsultRules.template(facts, profile: profile)
    }

    /// Resume "En palabras de Marco". Sin modelo (o ante error) devuelve el texto tal cual.
    func patientNote(_ text: String, profile: PlayerProfile) async -> PatientNote {
        let start = ContinuousClock.now
        defer { record(start) }
        if backend == .foundationModels {
            let out = await models.patientNoteResult(text, profile: profile)
            lastModelError = out.error
            lastAnsweredBy = out.value.backend
            return out.value
        }
        lastModelError = nil
        lastAnsweredBy = .rules
        return KineConsultRules.noteTemplate(text)
    }

    private func record(_ start: ContinuousClock.Instant) {
        let elapsed = start.duration(to: .now)
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        lastLatencyMs = Int(ms)
    }
}
