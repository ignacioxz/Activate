import Foundation
import Observation

// Dueño: agente "coach". Stub con firma congelada (devuelve la receta fija).

@Observable
final class CoachService {
    nonisolated enum Availability: Sendable, Equatable { case available, deviceNotEligible, notEnabled, modelNotReady, localeUnsupported, unknown }

    private(set) var availability: Availability = .unknown
    private(set) var backend: CoachBackend = .rules
    var override: CoachOverride = .auto
    private(set) var lastLatencyMs: Int?

    init() {}

    func refreshAvailability() {}
    func prewarm() {}

    func plan(_ input: CoachInput) async -> PausePlan {
        PausePlan(activities: input.baseRecipe.activities, reasoning: "", why: "", startMessage: "Vamos.", backend: .rules)
    }

    func statsReading(_ summary: StatsSummary, profile: PlayerProfile) async -> StatsReading {
        StatsReading(sentences: ["Aún no hay datos suficientes."], trend: .sinDatos, backend: .rules)
    }

    func kineSheet(_ summary: StatsSummary, profile: PlayerProfile) async -> KineSheet {
        KineSheet(period: "", whenItHurts: "", whatHeDid: "", whatWorsens: "", howItGoes: "", alerts: "", backend: .rules)
    }
}
