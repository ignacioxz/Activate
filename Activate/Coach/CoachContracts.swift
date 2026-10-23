import Foundation

// MARK: - Contrato del coach (congelado).

nonisolated enum CoachBackend: String, Sendable, Codable { case foundationModels, rules }

nonisolated struct CoachInput: Sendable, Hashable {
    var profileName: String
    var treatment: Treatment
    var checkIn: DailyCheckIn?
    var moment: Moment
    var minutesAvailable: Int
    var baseRecipe: Recipe
    var allowedKinds: [ActivityKind]
    /// ≤ 10 líneas preformateadas por StatsEngine.
    var historyLines: [String]
    var gentle: Bool
}

nonisolated struct PausePlan: Sendable, Codable, Hashable {
    var activities: [ActivityAssignment]
    var reasoning: String
    /// ≤ 8 palabras, p. ej. "Hoy sin sentadilla: espalda cargada."
    var why: String
    /// ≤ 8 palabras, p. ej. "Vamos, Marco. Un minuto."
    var startMessage: String
    var backend: CoachBackend
}

nonisolated struct StatsReading: Sendable, Codable, Hashable {
    nonisolated enum Trend: String, Codable, Sendable { case mejorando, estable, empeorando, sinDatos }
    var sentences: [String]
    var trend: Trend
    var backend: CoachBackend
}

nonisolated struct KineSheet: Sendable, Codable, Hashable {
    var period: String
    var whenItHurts: String
    var whatHeDid: String
    var whatWorsens: String
    var howItGoes: String
    var alerts: String
    var backend: CoachBackend
}

nonisolated protocol Coach: Sendable {
    var backend: CoachBackend { get }
    func plan(_ input: CoachInput) async throws -> PausePlan
    func statsReading(_ summary: StatsSummary, profile: PlayerProfile) async throws -> StatsReading
    func kineSheet(_ summary: StatsSummary, profile: PlayerProfile) async throws -> KineSheet
}
