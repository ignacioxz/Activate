import Foundation

// Dueño: agente "stats-engine". Motor puro de estadísticas (Swift, sin UI ni LLM): agrupa check-ins,
// sesiones firmadas y el libro mayor de días laborales por turno 7×7 y produce `StatsSummary`
// (contrato en StatsContracts.swift). El coach solo comenta cifras que salen de aquí.
//
// Reglas de exclusión (PLAN.md):
// - `simulated` queda fuera de todo (agregados, racha, sesiones recientes).
// - `suspicious` se guarda con banderas: fuera de los agregados, pero aparece en `recentSessions` con su nivel.
// - Pasos y reps "verificados" solo cuentan actividades con nivel `full`.
// - RDQ del día = último check-in con fuente `.pausa` de ese día laboral.

nonisolated enum StatsEngine {

    // MARK: - Umbrales y límites (constantes nombradas; se calibran con datos reales)

    nonisolated enum Limits {
        static let recentSessions = 20
        static let historyLines = 10
        static let historySessions = 5
        static let hints = 4
        /// Días hacia atrás que recorre el cálculo de la racha (≥ 28 ciclos 7×7).
        static let streakLookbackDays = 400
    }

    nonisolated enum Thresholds {
        /// Registros "Me duele ahora" mínimos para hablar de un contexto.
        static let minPainRecordsForContextHint = 3
        /// Fracción mínima de registros en un contexto ("Le duele más al bajar del camión").
        static let contextShare = 0.30
        /// Últimos días del turno que se comparan con el resto ("los días 5 a 7").
        static let lateTurnoTailDays = 3
        /// Primeros días del turno que se comparan con el resto ("los días 1 y 2").
        static let earlyTurnoDays = 2
        /// Diferencia mínima de RDQ promedio entre fases del turno.
        static let turnoPhaseRDQDelta = 1.0
        /// Días con RDQ mínimos en cada fase para comparar.
        static let minDaysPerTurnoPhase = 2
        /// Cierres Mejor/Igual/Peor mínimos para la frase de mejora.
        static let minPostResponsesForHint = 3
        static let betterShare = 0.5
        static let worseShare = 0.3
        /// Subida promedio mínima del RDQ al día siguiente de un día sin pausa.
        static let nextDayRDQRise = 0.5
        static let minPairsForNextDayHint = 2
    }

    // MARK: - API

    /// Resumen completo para la pestaña Estadísticas, la hoja del kine y el prompt del coach.
    static func summary(data: SaveData, calendar: WorkCalendar, now: Date) -> StatsSummary {
        let ledger = StatsLedger(data: data, calendar: calendar)
        let todayKey = calendar.key(for: now)
        let currentKey = calendar.turnoKey(for: now)

        // Turnos con datos + el actual, en orden cronológico.
        var keys = ledger.turnoKeys
        keys.insert(currentKey)
        let turnos = keys.sorted().map { turno(key: $0, ledger: ledger, calendar: calendar) }

        let current = turnos.first { $0.turnoKey == currentKey }
        let previous = turnos.last { $0.turnoKey < currentKey && ledger.hasData(turnoKey: $0.turnoKey) }

        let streak = streak(ledger: ledger, calendar: calendar, now: now)
        let recent = ledger.visibleSessions
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(Limits.recentSessions)
            .map(digest)

        let hints = worsensHints(ledger: ledger, calendar: calendar)
        let days = currentTurnoDays(ledger: ledger, calendar: calendar, now: now, todayKey: todayKey)
        let lines = historyLines(ledger: ledger, calendar: calendar, todayKey: todayKey,
                                 streak: streak, current: current, previous: previous,
                                 currentDays: days, recent: Array(recent), hints: hints)

        return StatsSummary(
            currentTurno: current,
            previousTurno: previous,
            turnos: turnos,
            streak: streak,
            totalCountedPauses: ledger.pausesByDay.values.reduce(0, +),
            todayRDQ: ledger.rdqByDay[todayKey]?.score,
            recentSessions: Array(recent),
            worsensHints: hints,
            historyLines: lines,
            currentTurnoDays: days
        )
    }

    // MARK: - Turno

    private static func turno(key: String, ledger: StatsLedger, calendar: WorkCalendar) -> TurnoSummary {
        let sessions = ledger.aggregatable.filter { $0.turnoKey == key }
        let dayKeys = ledger.dayKeys(ofTurno: key, calendar: calendar)

        let checkIns = dayKeys.compactMap { ledger.rdqByDay[$0] }
        let scores = checkIns.map(\.score)
        var frequency = Array(repeating: 0, count: RDQ6.items.count)
        for c in checkIns {
            for (i, yes) in c.answers.prefix(RDQ6.items.count).enumerated() where yes { frequency[i] += 1 }
        }

        let posts = sessions.compactMap(\.postResponse)
        let full = sessions.flatMap(\.activities).filter { $0.level == .full && !$0.skipped }

        var steps = 0, reps = 0
        var stroopRTs: [Int] = []
        var blinkRates: [Double] = []
        var yaws: [Double] = []
        for a in full {
            switch a.metrics {
            case .steps(let count, _, _, _): steps += count
            case .reps(let count, _, _): reps += count
            case .stroop(_, let valid, _, let medianRTms, _, _, _, _, _): if valid > 0 { stroopRTs.append(medianRTms) }
            case .eyes(_, _, let blinksPerMinute, _): blinkRates.append(blinksPerMinute)
            case .neck(_, _, _, let maxYaw, _, _, _, _): yaws.append(maxYaw)
            case .breath, .none: break
            }
        }

        var maxStreak = 0, run = 0
        for day in dayKeys {
            if ledger.pauses(on: day) > 0 {
                run += 1
                maxStreak = max(maxStreak, run)
            } else if !ledger.cascoDays.contains(day) {
                run = 0
            }
        }

        return TurnoSummary(
            turnoKey: key,
            label: StatsFormatting.turnoLabel(forKey: key),
            workDays: calendar.roster.workDays,
            daysWithPause: dayKeys.filter { ledger.pauses(on: $0) > 0 }.count,
            countedPauses: dayKeys.reduce(0) { $0 + ledger.pauses(on: $1) },
            meanRDQ: mean(scores.map { Double($0) }),
            maxRDQ: scores.max(),
            itemFrequency: frequency,
            betterCount: posts.filter { $0 == .mejor }.count,
            sameCount: posts.filter { $0 == .igual }.count,
            worseCount: posts.filter { $0 == .peor }.count,
            verifiedSteps: steps,
            verifiedReps: reps,
            maxStreak: maxStreak,
            stroopMedianRTms: median(stroopRTs),
            blinksPerMinute: mean(blinkRates),
            neckMaxYaw: yaws.max()
        )
    }

    // MARK: - Racha

    /// Días laborales de subida consecutivos con pausa contada, terminando hoy o ayer.
    /// Los días de descanso no suman ni cortan; un día con casco mantiene la racha sin sumar.
    static func streak(ledger: StatsLedger, calendar: WorkCalendar, now: Date) -> Int {
        var date = calendar.workDate(for: now)
        if ledger.pauses(on: WorkCalendar.key(ofWorkDate: date, calendar: calendar.calendar)) == 0 {
            date = calendar.calendar.date(byAdding: .day, value: -1, to: date) ?? date
        }
        var count = 0
        for _ in 0..<Limits.streakLookbackDays {
            let key = WorkCalendar.key(ofWorkDate: date, calendar: calendar.calendar)
            if calendar.kind(for: instant(ofWorkDate: date, calendar: calendar)) == .turno {
                if ledger.pauses(on: key) > 0 {
                    count += 1
                } else if !ledger.cascoDays.contains(key) {
                    break
                }
            }
            guard let previous = calendar.calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return count
    }

    // MARK: - Días del turno actual

    private static func currentTurnoDays(ledger: StatsLedger, calendar: WorkCalendar, now: Date, todayKey: String) -> [DayStat] {
        calendar.workDatesOfTurno(containing: now).enumerated().map { index, workDate in
            let key = WorkCalendar.key(ofWorkDate: workDate, calendar: calendar.calendar)
            return DayStat(
                workDayKey: key,
                dayInBlock: index + 1,
                rdq: ledger.rdqByDay[key]?.score,
                countedPauses: ledger.pauses(on: key),
                cascoUsed: ledger.cascoDays.contains(key),
                isToday: key == todayKey
            )
        }
    }

    // MARK: - Sesiones recientes

    private static func digest(_ s: PauseSession) -> SessionDigest {
        SessionDigest(
            id: s.id,
            date: s.startedAt,
            workDayKey: s.workDayKey,
            moment: s.moment,
            recipe: s.recipe,
            checkInScore: s.checkInScore,
            post: s.postResponse,
            counted: s.counted,
            level: s.level,
            activityKinds: s.activities.filter { !$0.skipped }.map(\.kind)
        )
    }

    // MARK: - Qué lo empeora

    /// Frases cortas ya calculadas (máximo `Limits.hints`), en orden de prioridad.
    static func worsensHints(ledger: StatsLedger, calendar: WorkCalendar) -> [String] {
        var hints: [String] = []
        if let context = contextHint(ledger: ledger) { hints.append(context) }
        if let phase = turnoPhaseHint(ledger: ledger, calendar: calendar) { hints.append(phase) }
        if let nextDay = nextDayHint(ledger: ledger, calendar: calendar) { hints.append(nextDay) }
        if let post = postHint(ledger: ledger) { hints.append(post) }
        return Array(hints.prefix(Limits.hints))
    }

    /// "Le duele más al bajar del camión" si ≥ 30 % de los registros "Me duele ahora" son en ese contexto.
    private static func contextHint(ledger: StatsLedger) -> String? {
        let records = ledger.painRecords.compactMap(\.context)
        guard records.count >= Thresholds.minPainRecordsForContextHint else { return nil }
        var counts: [PainContext: Int] = [:]
        for c in records { counts[c, default: 0] += 1 }
        guard let top = counts.max(by: { a, b in a.value != b.value ? a.value < b.value : a.key.rawValue > b.key.rawValue }),
              Double(top.value) / Double(records.count) >= Thresholds.contextShare else { return nil }
        switch top.key {
        case .enCabina: return "Le duele más en la cabina"
        case .alBajar: return "Le duele más al bajar del camión"
        case .enElBus: return "Le duele más en el bus"
        case .enCasa: return "Le duele más en casa"
        }
    }

    /// "El dolor sube los días 5 a 7 del turno" o "El dolor es mayor los días 1 y 2 del turno".
    private static func turnoPhaseHint(ledger: StatsLedger, calendar: WorkCalendar) -> String? {
        let workDays = calendar.roster.workDays
        let lateStart = max(2, workDays - Thresholds.lateTurnoTailDays + 1)
        let earlyEnd = min(Thresholds.earlyTurnoDays, workDays - 1)
        var byDay: [Int: [Double]] = [:]
        for (key, checkIn) in ledger.rdqByDay {
            guard let day = ledger.dayInBlock(ofDayKey: key, calendar: calendar) else { continue }
            byDay[day, default: []].append(Double(checkIn.score))
        }
        func scores(_ range: ClosedRange<Int>) -> [Double] { range.flatMap { byDay[$0] ?? [] } }

        if lateStart > 1, lateStart <= workDays {
            let late = scores(lateStart...workDays), early = scores(1...(lateStart - 1))
            if late.count >= Thresholds.minDaysPerTurnoPhase, early.count >= Thresholds.minDaysPerTurnoPhase,
               let lateMean = mean(late), let earlyMean = mean(early),
               lateMean - earlyMean >= Thresholds.turnoPhaseRDQDelta {
                return lateStart == workDays
                    ? "El dolor sube el día \(workDays) del turno"
                    : "El dolor sube los días \(lateStart) a \(workDays) del turno"
            }
        }
        if earlyEnd >= 1, earlyEnd < workDays {
            let early = scores(1...earlyEnd), rest = scores((earlyEnd + 1)...workDays)
            if early.count >= Thresholds.minDaysPerTurnoPhase, rest.count >= Thresholds.minDaysPerTurnoPhase,
               let earlyMean = mean(early), let restMean = mean(rest),
               earlyMean - restMean >= Thresholds.turnoPhaseRDQDelta {
                switch earlyEnd {
                case 1: return "El dolor es mayor el día 1 del turno"
                case 2: return "El dolor es mayor los días 1 y 2 del turno"
                default: return "El dolor es mayor los días 1 a \(earlyEnd) del turno"
                }
            }
        }
        return nil
    }

    /// "Sin pausa, el RDQ del día siguiente sube": compara el cambio de RDQ entre días laborales consecutivos
    /// según si el primero tuvo pausa contada.
    private static func nextDayHint(ledger: StatsLedger, calendar: WorkCalendar) -> String? {
        var afterPause: [Double] = [], afterNoPause: [Double] = []
        for turnoKey in ledger.turnoKeys {
            let days = ledger.dayKeys(ofTurno: turnoKey, calendar: calendar)
            guard days.count > 1 else { continue }
            for i in 0..<(days.count - 1) {
                guard let a = ledger.rdqByDay[days[i]]?.score, let b = ledger.rdqByDay[days[i + 1]]?.score else { continue }
                let delta = Double(b - a)
                if ledger.pauses(on: days[i]) > 0 { afterPause.append(delta) } else { afterNoPause.append(delta) }
            }
        }
        guard afterNoPause.count >= Thresholds.minPairsForNextDayHint,
              let rise = mean(afterNoPause), rise >= Thresholds.nextDayRDQRise else { return nil }
        if let withPause = mean(afterPause), withPause >= rise { return nil }
        return "Sin pausa, el RDQ del día siguiente sube"
    }

    /// "Mejora en 7 de 8 pausas" o "Peor después de 3 de 8 pausas".
    private static func postHint(ledger: StatsLedger) -> String? {
        let posts = ledger.aggregatable.compactMap(\.postResponse)
        guard posts.count >= Thresholds.minPostResponsesForHint else { return nil }
        let better = posts.filter { $0 == .mejor }.count
        let worse = posts.filter { $0 == .peor }.count
        if Double(better) / Double(posts.count) >= Thresholds.betterShare {
            return "Mejora en \(StatsFormatting.xOfY(better, posts.count)) pausas"
        }
        if Double(worse) / Double(posts.count) >= Thresholds.worseShare {
            return "Peor después de \(StatsFormatting.xOfY(worse, posts.count)) pausas"
        }
        return nil
    }

    // MARK: - Historial para el coach

    /// ≤ 10 líneas ya redactadas, sin texto libre del usuario.
    static func historyLines(ledger: StatsLedger, calendar: WorkCalendar, todayKey: String, streak: Int,
                             current: TurnoSummary?, previous: TurnoSummary?, currentDays: [DayStat],
                             recent: [SessionDigest], hints: [String]) -> [String] {
        var lines: [String] = []
        lines.append("Días seguidos: \(streak)")

        if let current {
            let elapsed = StatsFormatting.elapsedDays(in: currentDays)
            var line = "Este turno: \(StatsFormatting.daysWithPauseLabel(current.daysWithPause, of: elapsed))"
            if let rdq = current.meanRDQ { line += ", RDQ promedio \(StatsFormatting.decimal(rdq))" }
            lines.append(line)
        }
        if let previous {
            var parts: [String] = []
            if let rdq = previous.meanRDQ { parts.append("RDQ promedio \(StatsFormatting.decimal(rdq))") }
            let total = previous.betterCount + previous.sameCount + previous.worseCount
            if total > 0 { parts.append("mejor en \(StatsFormatting.xOfY(previous.betterCount, total)) pausas") }
            if !parts.isEmpty { lines.append("Turno pasado: " + parts.joined(separator: ", ")) }
        }

        for digest in recent.filter({ $0.level != .suspicious }).prefix(Limits.historySessions) {
            lines.append(StatsFormatting.sessionLine(digest, todayKey: todayKey, calendar: calendar.calendar))
        }

        if let best = mostHelpfulActivity(ledger: ledger) {
            lines.append("Ejercicio que más ayudó: \(StatsFormatting.activityName(best))")
        }
        for hint in hints where lines.count < Limits.historyLines {
            lines.append(hint)
        }
        return Array(lines.prefix(Limits.historyLines))
    }

    /// Actividad verificada (`full`) presente en más pausas con cierre "Mejor".
    static func mostHelpfulActivity(ledger: StatsLedger) -> ActivityKind? {
        var counts: [ActivityKind: Int] = [:]
        for s in ledger.aggregatable where s.postResponse == .mejor {
            for kind in Set(s.activities.filter { $0.level == .full && !$0.skipped }.map(\.kind)) {
                counts[kind, default: 0] += 1
            }
        }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key.rawValue > b.key.rawValue }?.key
    }

    // MARK: - Utilidades

    /// Instante dentro del día laboral cuya medianoche es `workDate` (para consultar `kind`/`dayInBlock`).
    static func instant(ofWorkDate workDate: Date, calendar: WorkCalendar) -> Date {
        calendar.calendar.date(byAdding: .hour, value: calendar.boundaryHour + 8, to: workDate) ?? workDate
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

// MARK: - Libro mayor por día laboral

/// Índices inmutables por día laboral y por turno, construidos una vez por resumen.
nonisolated struct StatsLedger: Sendable {
    /// Sesiones no simuladas (incluye `suspicious`, para la lista de recientes).
    let visibleSessions: [PauseSession]
    /// Sesiones que entran en los agregados (ni simuladas ni sospechosas).
    let aggregatable: [PauseSession]
    /// Registros "Me duele ahora".
    let painRecords: [DailyCheckIn]
    /// Último check-in de fuente `.pausa` de cada día laboral.
    let rdqByDay: [String: DailyCheckIn]
    /// Pausas contadas por día: máximo entre el libro mayor (`WorkDay`) y las sesiones contadas.
    let pausesByDay: [String: Int]
    let cascoDays: Set<String>
    /// Claves de turno con algún dato.
    let turnoKeys: Set<String>
    /// Claves de día con datos, por turno (sesiones, check-ins, libro mayor).
    let dayKeysByTurno: [String: Set<String>]

    init(data: SaveData, calendar: WorkCalendar) {
        let visible = data.sessions.filter { !$0.simulated && $0.level != .simulated }
        let aggregatable = visible.filter { $0.level != .suspicious }
        self.visibleSessions = visible
        self.aggregatable = aggregatable

        var rdq: [String: DailyCheckIn] = [:]
        var pain: [DailyCheckIn] = []
        for c in data.checkIns {
            switch c.source {
            case .pausa:
                if let existing = rdq[c.workDayKey], existing.date > c.date { continue }
                rdq[c.workDayKey] = c
            case .meDueleAhora:
                pain.append(c)
            }
        }
        self.rdqByDay = rdq
        self.painRecords = pain

        var pauses: [String: Int] = [:]
        var casco: Set<String> = []
        for day in data.workDays.values {
            if day.countedPauses > 0 { pauses[day.key] = day.countedPauses }
            if day.cascoUsed { casco.insert(day.key) }
        }
        var countedBySessions: [String: Int] = [:]
        for s in aggregatable where s.counted { countedBySessions[s.workDayKey, default: 0] += 1 }
        for (key, n) in countedBySessions { pauses[key] = max(pauses[key] ?? 0, n) }
        self.pausesByDay = pauses
        self.cascoDays = casco

        var turnos: Set<String> = []
        var days: [String: Set<String>] = [:]
        for s in aggregatable { turnos.insert(s.turnoKey); days[s.turnoKey, default: []].insert(s.workDayKey) }
        for c in data.checkIns { turnos.insert(c.turnoKey); days[c.turnoKey, default: []].insert(c.workDayKey) }
        for day in data.workDays.values where day.countedPauses > 0 || day.cascoUsed {
            turnos.insert(day.turnoKey); days[day.turnoKey, default: []].insert(day.key)
        }
        self.turnoKeys = turnos
        self.dayKeysByTurno = days
    }

    func pauses(on dayKey: String) -> Int { pausesByDay[dayKey] ?? 0 }

    /// Claves de todos los días de subida del turno (según el calendario) más los días con datos
    /// registrados bajo esa clave de turno, ordenadas cronológicamente.
    func dayKeys(ofTurno turnoKey: String, calendar: WorkCalendar) -> [String] {
        var keys = dayKeysByTurno[turnoKey] ?? []
        if let first = calendar.date(forKey: turnoKey) {
            for offset in 0..<calendar.roster.workDays {
                if let d = calendar.calendar.date(byAdding: .day, value: offset, to: first) {
                    keys.insert(WorkCalendar.key(ofWorkDate: d, calendar: calendar.calendar))
                }
            }
        }
        return keys.sorted()
    }

    /// Día dentro del bloque (1 = primer día de subida) de una clave de día laboral.
    func dayInBlock(ofDayKey key: String, calendar: WorkCalendar) -> Int? {
        guard let workDate = calendar.date(forKey: key) else { return nil }
        let instant = StatsEngine.instant(ofWorkDate: workDate, calendar: calendar)
        guard calendar.kind(for: instant) == .turno else { return nil }
        return calendar.dayInBlock(for: instant)
    }

    /// Hay algo que mostrar: pausa contada, RDQ de pausa o cierre.
    func hasData(turnoKey: String) -> Bool {
        if aggregatable.contains(where: { $0.turnoKey == turnoKey }) { return true }
        if rdqByDay.values.contains(where: { $0.turnoKey == turnoKey }) { return true }
        if let days = dayKeysByTurno[turnoKey], days.contains(where: { pauses(on: $0) > 0 }) { return true }
        return false
    }
}
