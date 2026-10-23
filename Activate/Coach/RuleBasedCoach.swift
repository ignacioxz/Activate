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

    // MARK: - Hoja para el kine

    func kineSheet(_ summary: StatsSummary, profile: PlayerProfile) async throws -> KineSheet {
        Self.makeKineSheet(summary, profile: profile)
    }

    static func makeKineSheet(_ s: StatsSummary, profile: PlayerProfile) -> KineSheet {
        KineSheet(
            period: period(s),
            whenItHurts: whenItHurts(s, profile: profile),
            whatHeDid: whatHeDid(s),
            whatWorsens: whatWorsens(s),
            howItGoes: howItGoes(s),
            alerts: alerts(s),
            backend: .rules
        )
    }

    static func period(_ s: StatsSummary) -> String {
        let labels = s.turnos.map(\.label)
        guard let first = labels.first, let last = labels.last else {
            return s.currentTurno?.label ?? "Sin registros todavía"
        }
        return first == last ? first : "\(first) – \(last)"
    }

    static func whenItHurts(_ s: StatsSummary, profile: PlayerProfile) -> String {
        var parts = ["Zona: \(profile.usualZone.title.lowercased())."]
        let scored = s.currentTurnoDays.compactMap { d in d.rdq.map { (d.dayInBlock, $0) } }
        if let worst = scored.max(by: { $0.1 < $1.1 }) {
            parts.append("Peor día del turno: día \(worst.0) (RDQ \(worst.1) de 6).")
        }
        if let moment = worstMoment(s) {
            parts.append("Momento con más dolor: \(moment.title.lowercased()).")
        }
        if let t = s.currentTurno, let mean = t.meanRDQ {
            parts.append("RDQ promedio del turno: \(CoachFormat.decimal(mean)) de 6.")
        }
        if scored.isEmpty && s.currentTurno == nil { parts.append("Aún sin cuestionarios registrados.") }
        return parts.joined(separator: " ")
    }

    static func worstMoment(_ s: StatsSummary) -> Moment? {
        var sum: [Moment: (Int, Int)] = [:]
        for d in s.recentSessions {
            guard let score = d.checkInScore else { continue }
            let cur = sum[d.moment] ?? (0, 0)
            sum[d.moment] = (cur.0 + score, cur.1 + 1)
        }
        return sum.max { Double($0.value.0) / Double($0.value.1) < Double($1.value.0) / Double($1.value.1) }?.key
    }

    static func whatHeDid(_ s: StatsSummary) -> String {
        let counted = s.recentSessions.filter { $0.counted && $0.level >= .reduced }
        let steps = s.turnos.reduce(0) { $0 + $1.verifiedSteps }
        let reps = s.turnos.reduce(0) { $0 + $1.verifiedReps }
        var parts = ["Pausas verificadas: \(CoachFormat.integer(s.totalCountedPauses))."]
        parts.append("Pasos verificados: \(CoachFormat.integer(steps)); repeticiones verificadas: \(CoachFormat.integer(reps)).")
        var freq: [ActivityKind: Int] = [:]
        for d in counted { for k in d.activityKinds { freq[k, default: 0] += 1 } }
        let top = freq.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }.prefix(3)
        if !top.isEmpty {
            parts.append("Ejercicios más frecuentes: " + top.map { $0.key.name }.joined(separator: ", ") + ".")
        }
        if let mx = s.turnos.map(\.maxStreak).max(), mx > 0 { parts.append("Mejor racha: \(mx) días.") }
        return parts.joined(separator: " ")
    }

    static func whatWorsens(_ s: StatsSummary) -> String {
        var parts: [String] = []
        for h in s.worsensHints.prefix(4) {
            parts.append(h.hasSuffix(".") ? h : h + ".")
        }
        if let t = s.currentTurno, t.itemFrequency.count == RDQ6.items.count,
           let best = t.itemFrequency.enumerated().max(by: { $0.element < $1.element }), best.element > 0 {
            let n = best.element
            parts.append("Frase más marcada: \"\(RDQ6.items[best.offset])\" (\(n) \(n == 1 ? "día" : "días")).")
        }
        if parts.isEmpty { parts.append("Sin correlaciones claras todavía; faltan registros.") }
        return parts.joined(separator: " ")
    }

    static func howItGoes(_ s: StatsSummary) -> String {
        var parts: [String] = []
        let means = s.turnos.compactMap(\.meanRDQ)
        if means.count >= 2 {
            parts.append("RDQ promedio por turno: " + means.map(CoachFormat.decimal).joined(separator: " → ") + ".")
        } else if let m = means.first {
            parts.append("RDQ promedio del turno: \(CoachFormat.decimal(m)) de 6.")
        }
        let better = s.turnos.reduce(0) { $0 + $1.betterCount }
        let total = s.turnos.reduce(0) { $0 + $1.betterCount + $1.sameCount + $1.worseCount }
        if total > 0 { parts.append("Dijo Mejor después de la pausa en \(CoachFormat.percent(better, of: total)) (\(better) de \(total)).") }
        if let t = s.currentTurno {
            parts.append("Adherencia este turno: \(t.daysWithPause) de \(t.workDays) días.")
        }
        switch trend(s) {
        case .mejorando: parts.append("Tendencia: mejorando frente al turno anterior.")
        case .empeorando: parts.append("Tendencia: empeorando frente al turno anterior.")
        case .estable: parts.append("Tendencia: estable frente al turno anterior.")
        case .sinDatos: parts.append("Tendencia: sin datos suficientes.")
        }
        return parts.joined(separator: " ")
    }

    static func alerts(_ s: StatsSummary) -> String {
        var parts: [String] = []
        let highDays = s.currentTurnoDays.filter { ($0.rdq ?? 0) >= RDQ6.gentlePlanThreshold }.count
        if highDays > 0 {
            parts.append("RDQ \(RDQ6.gentlePlanThreshold) o más en \(highDays) \(highDays == 1 ? "día" : "días") del turno; la app pasó a plan suave.")
        } else if let mx = s.currentTurno?.maxRDQ, mx >= RDQ6.gentlePlanThreshold {
            parts.append("RDQ máximo del turno: \(mx) de 6; la app pasó a plan suave.")
        } else {
            parts.append("Sin puntajes altos este turno.")
        }
        if trend(s) == .empeorando { parts.append("El RDQ sube frente al turno anterior: conviene revisar.") }
        return parts.joined(separator: " ")
    }
}
