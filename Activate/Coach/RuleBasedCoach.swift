import Foundation

// Dueño: agente "coach". Coach de plantillas: misma forma de datos que el LLM, sin modelo.

nonisolated struct RuleBasedCoach: Coach {
    var backend: CoachBackend { .rules }

    /// Factor de reducción de metas en plan suave (se calibra con el kine).
    static let gentleTargetFactor = 0.6
    /// Diferencia de RDQ promedio entre turnos para hablar de tendencia.
    static let trendDeltaThreshold = 0.5

    init() {}

    // MARK: - Pausa del día

    func plan(_ input: CoachInput) async throws -> PausePlan {
        Self.makePlan(input)
    }

    /// Versión síncrona y pura (la usa el fallback del LLM y los tests).
    static func makePlan(_ input: CoachInput) -> PausePlan {
        var activities = PlanValidator.fallback(input)
        if input.gentle {
            activities = activities.map { a in
                var g = a
                g.target = max(1, Int((Double(a.target) * gentleTargetFactor).rounded()))
                return g
            }
        }
        let removed = input.baseRecipe.activities.map(\.kind).filter { !input.allowedKinds.contains($0) }
        let removedSquat = removed.contains(.sentadilla)
        let seed = Self.seed(input)
        return PausePlan(
            activities: activities,
            reasoning: CoachPhrases.reasoning(gentle: input.gentle, removed: removed),
            why: CoachPhrases.why(gentle: input.gentle, moment: input.moment, removedSquat: removedSquat, seed: seed),
            startMessage: CoachPhrases.start(name: input.profileName, treatment: input.treatment,
                                             moment: input.moment, gentle: input.gentle, seed: seed),
            backend: .rules
        )
    }

    /// Semilla estable (sin Hasher, que cambia por proceso) para variar frases entre días.
    static func seed(_ input: CoachInput) -> Int {
        let momentIndex = Moment.allCases.firstIndex(of: input.moment) ?? 0
        let score = input.checkIn?.score ?? 0
        return momentIndex * 7 + input.historyLines.count * 3 + score + input.minutesAvailable
    }

    // MARK: - Lectura de datos (3 frases)

    func statsReading(_ summary: StatsSummary, profile: PlayerProfile) async throws -> StatsReading {
        Self.makeReading(summary, profile: profile)
    }

    static func makeReading(_ summary: StatsSummary, profile: PlayerProfile) -> StatsReading {
        StatsReading(
            sentences: [adherenceSentence(summary), rdqSentence(summary), betterSentence(summary)],
            trend: trend(summary),
            backend: .rules
        )
    }

    static func adherenceSentence(_ s: StatsSummary) -> String {
        guard let t = s.currentTurno else { return "Este turno aún no registra pausas." }
        let elapsed = daysElapsed(s) ?? t.workDays
        if t.daysWithPause == 0 { return "Este turno aún sin pausas contadas." }
        if elapsed > 0, t.daysWithPause >= elapsed { return "Pausa en todos los días del turno: \(t.daysWithPause)." }
        return "Pausa en \(t.daysWithPause) de \(max(elapsed, t.daysWithPause)) días del turno."
    }

    static func rdqSentence(_ s: StatsSummary) -> String {
        let today: Int? = s.todayRDQ ?? s.currentTurno?.meanRDQ.map { Int($0.rounded()) }
        guard let today else { return "Hoy aún no responde el cuestionario de espalda." }
        if let prev = s.previousTurno?.meanRDQ {
            return "Espalda hoy: \(today) de 6; turno pasado, \(CoachFormat.decimal(prev))."
        }
        return "Espalda hoy: \(today) de 6. Sin turno anterior aún."
    }

    static func betterSentence(_ s: StatsSummary) -> String {
        let t = s.currentTurno
        var better = t?.betterCount ?? 0
        var total = (t?.betterCount ?? 0) + (t?.sameCount ?? 0) + (t?.worseCount ?? 0)
        if total == 0 {
            better = s.turnos.reduce(0) { $0 + $1.betterCount }
            total = s.turnos.reduce(0) { $0 + $1.betterCount + $1.sameCount + $1.worseCount }
        }
        guard total > 0 else { return "Aún sin respuestas después de la pausa." }
        return "Después de la pausa: mejor en \(better) de \(total)."
    }

    static func trend(_ s: StatsSummary) -> StatsReading.Trend {
        guard let cur = s.currentTurno?.meanRDQ, let prev = s.previousTurno?.meanRDQ else { return .sinDatos }
        let delta = cur - prev
        if delta <= -trendDeltaThreshold { return .mejorando }
        if delta >= trendDeltaThreshold { return .empeorando }
        return .estable
    }

    /// Días del turno actual hasta hoy (inclusive), si la lista marca el día de hoy.
    static func daysElapsed(_ s: StatsSummary) -> Int? {
        guard let todayIndex = s.currentTurnoDays.firstIndex(where: \.isToday) else {
            return s.currentTurnoDays.isEmpty ? nil : s.currentTurnoDays.count
        }
        return todayIndex + 1
    }

    // MARK: - Consulta con el kine (plantilla con la misma forma que el modelo)

    func kineConsult(_ facts: [KineFact], profile: PlayerProfile) async throws -> KineConsult {
        KineConsultRules.template(facts, profile: profile)
    }

    func patientNote(_ text: String, profile: PlayerProfile) async throws -> PatientNote {
        KineConsultRules.noteTemplate(text)
    }
}
