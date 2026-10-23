import Foundation

// MARK: - Contrato de estadísticas (congelado). StatsEngine las calcula; vistas y coach las consumen.

nonisolated struct TurnoSummary: Sendable, Codable, Hashable, Identifiable {
    var turnoKey: String
    var id: String { turnoKey }
    var label: String
    var workDays: Int
    var daysWithPause: Int
    var countedPauses: Int
    var meanRDQ: Double?
    var maxRDQ: Int?
    /// Frecuencia de "Sí" por ítem del RDQ-6 (6 valores).
    var itemFrequency: [Int]
    var betterCount: Int
    var sameCount: Int
    var worseCount: Int
    var verifiedSteps: Int
    var verifiedReps: Int
    var maxStreak: Int
    var stroopMedianRTms: Int?
    var blinksPerMinute: Double?
    var neckMaxYaw: Double?
}

nonisolated struct SessionDigest: Sendable, Codable, Hashable, Identifiable {
    var id: UUID
    var date: Date
    var workDayKey: String
    var moment: Moment
    var recipe: RecipeKind
    var checkInScore: Int?
    var post: PostResponse?
    var counted: Bool
    var level: VerificationLevel
    var activityKinds: [ActivityKind]
}

nonisolated struct StatsSummary: Sendable, Codable, Hashable {
    var currentTurno: TurnoSummary?
    var previousTurno: TurnoSummary?
    var turnos: [TurnoSummary]
    var streak: Int
    var totalCountedPauses: Int
    var todayRDQ: Int?
    var recentSessions: [SessionDigest]
    /// Frases cortas ya calculadas: "Le duele más al bajar del camión", etc.
    var worsensHints: [String]
    /// ≤ 10 líneas para el prompt del coach.
    var historyLines: [String]
    /// Por día laboral del turno actual: (clave, RDQ o nil, pausas contadas).
    var currentTurnoDays: [DayStat]
}

nonisolated struct DayStat: Sendable, Codable, Hashable, Identifiable {
    var workDayKey: String
    var id: String { workDayKey }
    var dayInBlock: Int
    var rdq: Int?
    var countedPauses: Int
    var cascoUsed: Bool
    var isToday: Bool
}
