import Foundation

/// Semilla de la demo (caso "Marco"). Reemplaza todo el estado del store con:
/// - perfil "Marco" (usted, 7×7, turno de día, zona habitual lumbar) con `rosterStart` tal que HOY sea el día 2 de subida;
/// - dos turnos anteriores completos con el patrón del caso: día 1 pausa sí, día 2 casco automático,
///   día 3 RDQ 4 con "no agacharse" = Sí, día 5 peak RDQ 6, resto variado; nunca dos días seguidos
///   (el caso dice que "casi nunca alcanza a hacerla dos días seguidos"). Algunos días marcan
///   espalda baja + cuello (selección múltiple);
/// - el turno anterior cierra el día 7 con un check-in suelto, sin pausa: la racha vale 1 antes de
///   la pausa en vivo y 2 con el Doblete;
/// - el turno actual con AYER contado y HOY sin pausa, para que la pausa en vivo dispare el Doblete.
///
/// Todas las sesiones son `.full` (salvo la respiración, `.reduced` por naturaleza) y `counted`
/// se calcula con `VerificationPolicy`, igual que en vivo. `countedPauses` de cada `WorkDay`
/// coincide con las sesiones contadas de ese día. Las cifras de los sensores vienen de un
/// generador determinista: cargar la semilla dos veces da las mismas estadísticas.
nonisolated enum DemoSeed {

    /// Siembra el store (reemplaza todo y guarda una sola vez).
    @MainActor
    static func load(into store: AppStore, now: Date = .now) {
        store.replace(with: data(now: now, calendar: .current))
    }

    /// Construye los datos sin tocar el store (puro, testeable con cualquier calendario).
    static func data(now: Date, calendar cal: Calendar = .current) -> SaveData {
        let probe = WorkCalendar(roster: .sieteXSiete, rosterStart: now,
                                 boundaryHour: ShiftType.day.dayBoundaryHour, calendar: cal)
        let today = probe.workDate(for: now)
        let rosterStart = cal.date(byAdding: .day, value: -1, to: today) ?? today

        var profile = PlayerProfile(rosterStart: rosterStart)
        profile.name = "Marco"
        profile.treatment = .usted
        profile.roster = .sieteXSiete
        profile.shiftType = .day
        profile.usualZones = PainZone.normalized(usualZones)
        profile.usualZone = profile.usualZones?.first ?? .lumbar
        profile.cascos = cascosPerTurno
        profile.outdoorMode = false
        profile.consentGiven = true
        profile.notificationsOptIn = false
        profile.onboardingDone = true

        let wc = WorkCalendar(profile: profile, calendar: cal)
        var rng = SeedRNG(seed: rngSeed)
        var builder = Builder(wc: wc, cal: cal)

        // Dos turnos anteriores (ciclo 7×7 = 14 días) y el actual.
        for (offset, script) in [(-2, turnoA), (-1, turnoB), (0, turnoActual)] {
            let first = cal.date(byAdding: .day, value: offset * wc.cycleLength, to: rosterStart) ?? rosterStart
            builder.add(turnoStarting: first, script: script, rng: &rng)
        }
        // Hoy (día 2) existe en el libro mayor, sin pausa.
        builder.ensureDay(workDate: today, casco: false)

        profile.xp = builder.sessions.reduce(0) { $0 + $1.xpEarned }
        profile.badges = badges(sessions: builder.sessions, workDays: builder.workDays)

        var save = SaveData(profile: profile)
        save.workDays = builder.workDays
        save.checkIns = builder.checkIns.sorted { $0.date < $1.date }
        save.sessions = builder.sessions.sorted { $0.startedAt < $1.startedAt }
        save.demo = DemoConfig(enabled: true, shortTargets: true, coachOverride: .auto, notificationsMuted: true)
        save.statsReadingCache = [wc.key(for: now): pregeneratedReading]
        save.lastKineSheetJSON = nil
        return save
    }

    // MARK: - Constantes

    /// Cascos con que parte cada turno (se repone el día 1).
    static let cascosPerTurno = 1
    /// Semilla del generador determinista de cifras de sensores.
    static let rngSeed: UInt64 = 0x4143_5449_5641_5445 // "ACTIVATE"
    /// XP de una actividad `.reduced` = baseXP / divisor (aproximación de la semilla; en vivo lo calcula GameStore).
    static let reducedXPDivisor = 2
    /// Segundos del check-in RDQ-6 antes de la primera actividad.
    static let checkInSeconds: ClosedRange<Double> = 18...30
    /// Segundos de transición entre actividades (preparar cámara, leer la instrucción).
    static let transitionSeconds: ClosedRange<Double> = 6...10
    /// Minutos entre el check-in y el inicio de la sesión.
    static let checkInLeadSeconds: Double = 40
    /// Minutos después del momento en que se registra un "Me duele ahora".
    static let painLogDelayMinutes = 5

    /// Horarios plausibles por momento (hora local, turno de día).
    static func clock(for moment: Moment) -> (hour: Int, minute: Int) {
        switch moment {
        case .entrada: (7, 40)
        case .colacion: (13, 10)
        case .salida: (19, 50)
        case .campamento: (21, 30)
        }
    }

    /// Receta base por momento (misma composición que `Recipes.base`, sin depender de él).
    /// Historia sembrada: en los relevos Marco hizo la pausa rápida y en la colación una parcial
    /// (no depende de `Moment.recipe`, que hoy es siempre la ruta completa).
    static func baseActivities(for moment: Moment) -> [ActivityKind] {
        switch moment {
        case .entrada, .salida: [.cuello, .ojos]
        case .colacion: [.pasos, .cuello, .ojos]
        case .campamento: [.pasos, .pararseSentarse, .sentadilla, .cuello, .stroop, .ojos, .extensionLumbar]
        }
    }

    /// Receta registrada en la historia sembrada.
    static func seededRecipe(for moment: Moment) -> RecipeKind {
        switch moment {
        case .entrada, .salida: .relevo60
        case .colacion: .colacion3
        case .campamento: .campamento5
        }
    }

    /// Campamento sin agacharse (RDQ ≥ 4 con "no agacharse" o plan suave).
    static let gentleCampamento: [ActivityKind] = [.pasos, .cuello, .stroop, .ojos]

    /// Lectura del coach pregenerada para hoy (una frase por línea).
    static let pregeneratedReading = """
    Ayer hizo la pausa y terminó mejor.
    Hoy es el día 2: el Doblete está a una pausa.
    El turno pasado le dolió más al bajar del camión.
    """

    // MARK: - Guion de los turnos

    /// Zonas habituales del perfil sembrado.
    static let usualZones: [PainZone] = [.lumbar]
    /// Días en que además le dolió el cuello (horas en cabina con el camión vibrando).
    static let lumbarYCuello: [PainZone] = [.lumbar, .cuello]

    nonisolated struct PainLog: Sendable {
        var moment: Moment
        var context: PainContext
        var zones: [PainZone] = DemoSeed.usualZones
    }

    nonisolated struct DayScript: Sendable {
        var day: Int
        /// Respuestas RDQ-6 del día (nil = sin check-in de pausa).
        var rdq: [Bool]? = nil
        /// Momento del check-in cuando NO hubo pausa (check-in suelto, cuenta para estadísticas).
        var checkInMoment: Moment? = nil
        /// Momento de la pausa verificada.
        var pause: Moment? = nil
        /// nil = receta base del momento.
        var activities: [ActivityKind]? = nil
        /// Actividad que quedó incompleta (la sesión igual cuenta si otra es `.full`).
        var incomplete: ActivityKind? = nil
        var post: PostResponse? = nil
        var casco: Bool = false
        var pain: PainLog? = nil
        var coachNote: String? = nil
        /// Zonas marcadas en el check-in de ese día (selección múltiple).
        var zones: [PainZone] = DemoSeed.usualZones
    }

    private static let T = true, F = false

    /// Dos turnos atrás.
    static let turnoA: [DayScript] = [
        DayScript(day: 1, rdq: [T, F, T, F, T, F], pause: .colacion, post: .mejor),
        DayScript(day: 2, casco: true, pain: PainLog(moment: .salida, context: .alBajar)),
        DayScript(day: 3, rdq: [T, F, T, T, T, F], pause: .campamento, activities: gentleCampamento,
                  post: .mejor, coachNote: "Hoy sin sentadilla: espalda cargada."),
        DayScript(day: 4, pain: PainLog(moment: .colacion, context: .enCabina, zones: lumbarYCuello)),
        DayScript(day: 5, rdq: [T, T, T, T, T, T], pause: .entrada, post: .igual,
                  coachNote: "Plan suave: dolor alto hoy.", zones: lumbarYCuello),
        DayScript(day: 6, rdq: [T, T, T, F, T, F], checkInMoment: .colacion),
        DayScript(day: 7, rdq: [T, F, T, F, T, F], pause: .salida, incomplete: .ojos, post: .mejor),
    ]

    /// Turno anterior.
    static let turnoB: [DayScript] = [
        DayScript(day: 1, rdq: [T, F, F, F, T, F], pause: .campamento, post: .mejor),
        DayScript(day: 2, casco: true, pain: PainLog(moment: .campamento, context: .enElBus)),
        DayScript(day: 3, rdq: [T, F, T, T, F, T], pause: .colacion, post: .mejor,
                  coachNote: "Sin agacharse: caminar y cuello.", zones: lumbarYCuello),
        DayScript(day: 4, rdq: [T, F, T, F, T, F], checkInMoment: .entrada),
        DayScript(day: 5, rdq: [T, T, T, T, T, T], pause: .campamento, activities: gentleCampamento,
                  post: .igual, coachNote: "Plan suave: dolor alto hoy."),
        DayScript(day: 6, pain: PainLog(moment: .colacion, context: .alBajar, zones: lumbarYCuello)),
        // Check-in suelto, sin pausa: la racha llega en 1 al día 2 de hoy (2 con el Doblete en vivo).
        DayScript(day: 7, rdq: [T, F, T, F, F, T], checkInMoment: .entrada),
    ]

    /// Turno actual: solo ayer (día 1). Hoy (día 2) queda sin pausa.
    static let turnoActual: [DayScript] = [
        DayScript(day: 1, rdq: [T, F, T, F, T, F], pause: .colacion, post: .mejor),
    ]

    // MARK: - Insignias coherentes con los datos

    static func badges(sessions: [PauseSession], workDays: [String: WorkDay]) -> Set<Badge> {
        var badges: Set<Badge> = []
        let counted = sessions.filter(\.counted)
        if !counted.isEmpty { badges.insert(.primeraPausa) }
        if counted.filter({ $0.recipe == .relevo60 }).count >= 5 { badges.insert(.relevoCumplido) }
        if counted.contains(where: { $0.recipe == .campamento5 && $0.activities.allSatisfy { $0.completed && !$0.skipped } }) {
            badges.insert(.rajoCompleto)
        }
        let steps = sessions.flatMap(\.activities).reduce(0) { total, r in
            if case .steps(let count, _, _, _) = r.metrics, r.level == .full { return total + count }
            return total
        }
        if steps >= 2500 { badges.insert(.caminanteDelRajo) }
        let turnos = Dictionary(grouping: workDays.values.filter { $0.kind == .turno }, by: \.turnoKey)
        for days in turnos.values {
            let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.dayInBlock, $0.countedPauses) })
            if (1..<7).contains(where: { (byDay[$0] ?? 0) > 0 && (byDay[$0 + 1] ?? 0) > 0 }) { badges.insert(.doblete) }
            if (1...7).allSatisfy({ (byDay[$0] ?? 0) > 0 }) { badges.insert(.tiroLimpio) }
        }
        return badges
    }

    // MARK: - Constructor

    nonisolated struct Builder {
        let wc: WorkCalendar
        let cal: Calendar
        var workDays: [String: WorkDay] = [:]
        var checkIns: [DailyCheckIn] = []
        var sessions: [PauseSession] = []

        init(wc: WorkCalendar, cal: Calendar) {
            self.wc = wc
            self.cal = cal
        }

        mutating func add(turnoStarting first: Date, script: [DayScript], rng: inout SeedRNG) {
            for day in script {
                guard let workDate = cal.date(byAdding: .day, value: day.day - 1, to: first) else { continue }
                ensureDay(workDate: workDate, casco: day.casco)

                if let pain = day.pain {
                    let at = clockDate(pain.moment, on: workDate, plusMinutes: DemoSeed.painLogDelayMinutes)
                    let zones = PainZone.normalized(pain.zones)
                    checkIns.append(DailyCheckIn(date: at, workDayKey: wc.key(for: at), turnoKey: wc.turnoKey(for: at),
                                                 source: .meDueleAhora, answers: [], alarmAnswers: [],
                                                 zone: zones[0], zones: zones, moment: pain.moment, context: pain.context))
                }

                let moment = day.pause ?? day.checkInMoment
                guard let moment, let rdq = day.rdq else { continue }
                let startedAt = clockDate(moment, on: workDate)
                let checkInAt = startedAt.addingTimeInterval(-DemoSeed.checkInLeadSeconds)
                let score = rdq.filter { $0 }.count
                let zones = PainZone.normalized(day.zones)
                let checkIn = DailyCheckIn(date: checkInAt, workDayKey: wc.key(for: checkInAt), turnoKey: wc.turnoKey(for: checkInAt),
                                           source: .pausa, answers: rdq,
                                           alarmAnswers: score >= RDQ6.gentlePlanThreshold ? [false, false, false] : [],
                                           zone: zones[0], zones: zones, moment: moment, context: nil)
                checkIns.append(checkIn)

                guard day.pause != nil else { continue }
                let session = makeSession(day: day, moment: moment, startedAt: startedAt, checkIn: checkIn, rng: &rng)
                sessions.append(session)
                if session.counted {
                    workDays[session.workDayKey]?.countedPauses += 1
                }
            }
        }

        /// WorkDay del día laboral cuyo `workDate` es la medianoche de calendario dada.
        mutating func ensureDay(workDate: Date, casco: Bool) {
            let inside = cal.date(byAdding: .hour, value: wc.boundaryHour, to: workDate) ?? workDate
            let key = wc.key(for: inside)
            if workDays[key] == nil {
                workDays[key] = WorkDay(key: key, kind: wc.kind(for: inside), dayInBlock: wc.dayInBlock(for: inside),
                                        turnoKey: wc.turnoKey(for: inside), countedPauses: 0, cascoUsed: casco)
            } else if casco {
                workDays[key]?.cascoUsed = true
            }
        }

        private func clockDate(_ moment: Moment, on workDate: Date, plusMinutes: Int = 0) -> Date {
            let c = DemoSeed.clock(for: moment)
            let base = cal.date(bySettingHour: c.hour, minute: c.minute + plusMinutes, second: 0, of: workDate) ?? workDate
            return Date(timeIntervalSince1970: base.timeIntervalSince1970.rounded(.down))
        }

        private func makeSession(day: DayScript, moment: Moment, startedAt: Date, checkIn: DailyCheckIn, rng: inout SeedRNG) -> PauseSession {
            let kinds = day.activities ?? DemoSeed.baseActivities(for: moment)
            var results: [ActivityResult] = []
            var seconds = rng.double(DemoSeed.checkInSeconds)
            for kind in kinds {
                let (result, duration) = DemoSeed.result(kind, incomplete: day.incomplete == kind, rng: &rng)
                results.append(result)
                seconds += duration + rng.double(DemoSeed.transitionSeconds)
            }
            seconds = seconds.rounded()
            let xp = results.reduce(0) { total, r in
                guard r.completed, !r.skipped else { return total }
                switch r.level {
                case .full: return total + r.kind.baseXP
                case .reduced: return total + r.kind.baseXP / DemoSeed.reducedXPDivisor
                case .suspicious, .simulated: return total
                }
            }
            return PauseSession(workDayKey: wc.key(for: startedAt),
                                turnoKey: wc.turnoKey(for: startedAt),
                                recipe: DemoSeed.seededRecipe(for: moment),
                                moment: moment,
                                startedAt: startedAt,
                                endedAt: startedAt.addingTimeInterval(seconds),
                                monotonicSeconds: seconds,
                                checkInScore: checkIn.score,
                                checkInAnswers: checkIn.answers,
                                zone: checkIn.zone,
                                zones: checkIn.zones,
                                postResponse: day.post,
                                activities: results,
                                counted: VerificationPolicy.counts(results),
                                level: VerificationPolicy.sessionLevel(results),
                                simulated: false,
                                coachNote: day.coachNote,
                                integrityFlags: [],
                                xpEarned: xp)
        }
    }

    // MARK: - Resultados verificados plausibles

    /// Resultado `.full` (o `.reduced` para la respiración) con métricas plausibles y su duración en segundos.
    static func result(_ kind: ActivityKind, incomplete: Bool, rng: inout SeedRNG) -> (ActivityResult, Double) {
        let target = kind.defaultTarget
        let achieved = incomplete ? Int(Double(target) * rng.double(0.6...0.8)) : target
        let completed = !incomplete
        let level: VerificationLevel = kind.weakByNature ? .reduced : .full
        let metrics: ActivityMetrics
        let duration: Double
        switch kind {
        case .pasos:
            let cadence = rng.double(1.6...1.9)
            metrics = .steps(count: achieved, meanCadence: round2(cadence),
                             walkingFraction: round2(rng.double(0.86...0.97)), rmsPeak: round2(rng.double(0.28...0.42)))
            duration = Double(achieved) / cadence
        case .sentadilla:
            let rep = rng.double(3.0...3.8)
            metrics = .reps(count: achieved, minDescentRatio: round2(rng.double(0.26...0.34)), meanRepSeconds: round2(rep))
            duration = Double(achieved) * rep + 6
        case .pararseSentarse:
            // `minDescentRatio` lleva la mayor subida del teléfono en metros (ver `SitToStandVerifier`).
            let rep = rng.double(3.2...4.2)
            metrics = .reps(count: achieved, minDescentRatio: round2(rng.double(0.38...0.46)), meanRepSeconds: round2(rep))
            duration = Double(achieved) * rep + 6
        case .extensionLumbar:
            let rep = rng.double(3.6...4.4)
            metrics = .reps(count: achieved, minDescentRatio: nil, meanRepSeconds: round2(rep))
            duration = Double(achieved) * rep + 6
        case .cuello:
            let third = achieved / 3
            metrics = .neck(rotations: achieved - 2 * third, flexions: third, tilts: third,
                            maxYaw: round2(rng.double(42...55)), maxPitch: round2(rng.double(28...38)), maxRoll: round2(rng.double(20...30)),
                            cueMatches: achieved, cueMismatches: rng.int(0...2))
            duration = rng.double(28...36)
        case .ojos:
            duration = rng.double(30...38)
            metrics = .eyes(completeBlinks: achieved, partialBlinks: rng.int(1...4),
                            blinksPerMinute: round2(Double(achieved) / duration * 60), farGazeSeconds: 0)
        case .stroop:
            let trials = max(achieved, achieved + rng.int(0...6))
            let median = rng.int(720...880)
            metrics = .stroop(trials: trials, valid: achieved, accuracy: round2(rng.double(0.84...0.95)),
                              medianRTms: median, medianCongruentRTms: median - rng.int(40...70),
                              medianIncongruentRTms: median + rng.int(60...110),
                              anticipations: rng.int(0...2), lapses: rng.int(0...2), seed: rng.next())
            duration = 60
        case .respiracion:
            metrics = .breath(cycles: achieved)
            duration = Double(achieved) * rng.double(8...9)
        }
        let result = ActivityResult(kind: kind, target: target, achieved: achieved, durationSeconds: duration.rounded(),
                                    completed: completed, level: level, metrics: metrics, anomalies: [], skipped: false)
        return (result, duration)
    }

    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    // MARK: - Generador determinista (SplitMix64)

    nonisolated struct SeedRNG: Sendable {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func int(_ range: ClosedRange<Int>) -> Int {
            let span = UInt64(range.upperBound - range.lowerBound + 1)
            return range.lowerBound + Int(next() % span)
        }

        mutating func double(_ range: ClosedRange<Double>) -> Double {
            let unit = Double(next() >> 11) / Double(1 << 53)
            return range.lowerBound + (range.upperBound - range.lowerBound) * unit
        }
    }
}
