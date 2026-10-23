import Foundation

// Dueño: paquete "kine-ai". Hechos del Reporte de Salud (consulta con el kine o la mutual), calculados en Swift (puro, testeable)
// desde StatsSummary + check-ins + sesiones. Cada hecho trae su cifra (`value`) y una frase completa
// (`detail`); Apple Intelligence solo elige cuáles importan y los explica. Solo salen los hechos que
// tienen datos suficientes, en orden de prioridad (la plantilla toma los 3 primeros).

nonisolated enum KineFacts {
    nonisolated enum Thresholds {
        /// Diferencia de RDQ promedio entre turnos para hablar de subida o bajada.
        static let trendDelta = 0.5
        /// Turno con menos días de cuestionario que esto se marca como "lleva N días".
        static let fewDaysInTurno = 3
        /// Peor día del turno: registros mínimos ese día y en el resto, y diferencia mínima.
        static let minDaySamples = 2
        static let minOtherSamples = 2
        static let worstDayDelta = 1.0
        /// "Me duele ahora": registros mínimos y fracción mínima del contexto dominante.
        static let minPainRecords = 2
        static let contextShare = 0.30
        /// Cierres Mejor/Igual/Peor mínimos.
        static let minPostResponses = 3
        static let betterShare = 0.5
        /// Ejercicio que acompaña la mejora: pausas mínimas con y sin él y diferencia mínima de % Mejor.
        static let minGroupSessions = 2
        static let minExerciseLift = 0.10
        /// Frase del RDQ-6: días mínimos marcada.
        static let minItemDays = 2
        /// RDQ desde el cual un día cuenta como dolor alto (coincide con el plan suave).
        static var highRDQ: Int { RDQ6.gentlePlanThreshold }
    }

    /// Hechos desde el estado completo de la app.
    static func build(data: SaveData, summary: StatsSummary, calendar: Calendar = .current) -> [KineFact] {
        build(summary: summary, checkIns: data.checkIns, sessions: data.sessions, profile: data.profile, calendar: calendar)
    }

    static func build(summary: StatsSummary, checkIns: [DailyCheckIn], sessions: [PauseSession],
                      profile: PlayerProfile, calendar: Calendar = .current) -> [KineFact] {
        let work = WorkCalendar(profile: profile, calendar: calendar)
        let rdqDays = rdqByDay(checkIns)
        let pain = checkIns.filter { $0.source == .meDueleAhora }
        let closed = sessions.filter { !$0.simulated && $0.level >= .reduced }

        let alarm = alertas(checkIns: checkIns, rdqDays: rdqDays, sessions: closed, calendar: calendar)
        let urgent = checkIns.contains(where: \.hasAlarm)
        let ordered: [KineFact?] = [
            urgent ? alarm : nil,
            rdqTendencia(summary, rdqDays: rdqDays),
            peorFaseTurno(rdqDays, work: work),
            contextoDominante(pain),
            itemFrecuente(rdqDays),
            mejoraPost(closed),
            ejercicioQueAyuda(closed),
            urgent ? nil : alarm,
            adherencia(summary),
            nivel(LevelProgress.compute(sessions: sessions, calendar: work)),
        ]
        return ordered.compactMap { $0 }
    }

    /// Último check-in de pausa (con las 6 respuestas) de cada día laboral, en orden cronológico.
    static func rdqByDay(_ checkIns: [DailyCheckIn]) -> [DailyCheckIn] {
        var byDay: [String: DailyCheckIn] = [:]
        for c in checkIns where c.source == .pausa && c.answers.count == RDQ6.items.count {
            if let existing = byDay[c.workDayKey], existing.date > c.date { continue }
            byDay[c.workDayKey] = c
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    // MARK: - Espalda turno a turno

    static func rdqTendencia(_ s: StatsSummary, rdqDays: [DailyCheckIn]) -> KineFact? {
        let means = s.turnos.sorted { $0.turnoKey < $1.turnoKey }.compactMap { t in t.meanRDQ.map { (t, $0) } }
        guard let last = means.last else { return nil }
        let id = KineFactID.rdqTendencia.rawValue
        let title = "Espalda turno a turno (RDQ-6)"
        let lastDays = rdqDays.filter { $0.turnoKey == last.0.turnoKey }.count
        let isCurrent = last.0.turnoKey == s.currentTurno?.turnoKey
        let fewDays = lastDays > 0 && lastDays < Thresholds.fewDaysInTurno && isCurrent
            ? " (lleva \(lastDays) \(lastDays == 1 ? "día" : "días") con cuestionario)"
            : ""

        guard means.count >= 2 else {
            return KineFact(id: id, title: title,
                            value: "\(KineSheetFormat.decimal(last.1)) de \(RDQ6.maxScore)",
                            detail: "RDQ-6 promedio de \(KineSheetFormat.decimal(last.1)) de \(RDQ6.maxScore) (menos es mejor)\(fewDays); aún no hay otro turno para comparar.",
                            gist: "Hay un solo turno con cuestionario; aún no se ve hacia dónde va el dolor de espalda.",
                            question: "¿Qué ejercicio me conviene sumar para que baje el dolor de espalda?",
                            focus: "Definir qué ejercicios le convienen para la espalda durante el turno.")
        }
        let previous = means[means.count - 2].1
        let delta = last.1 - previous
        let shown = means.suffix(3).map { KineSheetFormat.decimal($0.1) }.joined(separator: " → ")
        let change = KineSheetFormat.decimal(abs(delta))
        let trend: String, gist: String, question: String, focus: String
        if delta <= -Thresholds.trendDelta {
            trend = "bajó \(change) puntos frente al anterior"
            gist = "El puntaje de dolor de espalda viene bajando de un turno a otro."
            question = "Mi espalda viene mejor, ¿sigo con los mismos ejercicios o subo la carga?"
            focus = "Revisar los ejercicios que le están ayudando y ver si conviene subir la carga."
        } else if delta >= Thresholds.trendDelta {
            trend = "subió \(change) puntos frente al anterior"
            gist = "El puntaje de dolor de espalda viene subiendo de un turno a otro."
            question = "Mi espalda viene peor, ¿qué cambio en las pausas del turno?"
            focus = "Revisar por qué sube el dolor y ajustar las pausas del turno."
        } else {
            trend = "se mantiene parecido al anterior"
            gist = "El puntaje de dolor de espalda se mantiene parecido entre turnos."
            question = "Mi dolor de espalda no baja, ¿qué ejercicio me conviene agregar?"
            focus = "Buscar qué ejercicio agregar para que el dolor de espalda baje."
        }
        return KineFact(id: id, title: title, value: shown,
                        detail: "RDQ-6 promedio por turno (0 a \(RDQ6.maxScore), menos es mejor): \(shown). \(isCurrent ? "Este turno" : "El último turno") \(trend)\(fewDays).",
                        gist: gist, question: question, focus: focus)
    }

    // MARK: - Día más cargado del turno

    static func peorFaseTurno(_ rdqDays: [DailyCheckIn], work: WorkCalendar) -> KineFact? {
        var byDay: [Int: [Int]] = [:]
        for c in rdqDays where work.kind(for: c.date) == .turno {
            byDay[work.dayInBlock(for: c.date), default: []].append(c.score)
        }
        func mean(_ v: [Int]) -> Double { Double(v.reduce(0, +)) / Double(max(1, v.count)) }
        let candidates = byDay.filter { $0.value.count >= Thresholds.minDaySamples }
        guard let worst = candidates.max(by: { a, b in
            mean(a.value) != mean(b.value) ? mean(a.value) < mean(b.value) : a.key > b.key
        }) else { return nil }
        let rest = byDay.filter { $0.key != worst.key }.flatMap(\.value)
        guard rest.count >= Thresholds.minOtherSamples else { return nil }
        let worstMean = mean(worst.value), restMean = mean(rest)
        guard worstMean - restMean >= Thresholds.worstDayDelta else { return nil }
        let day = worst.key
        return KineFact(id: KineFactID.peorFaseTurno.rawValue,
                        title: "Día más cargado del turno",
                        value: "Día \(day): \(KineSheetFormat.decimal(worstMean)) de \(RDQ6.maxScore)",
                        detail: "El día \(day) del turno el RDQ-6 promedia \(KineSheetFormat.decimal(worstMean)) de \(RDQ6.maxScore) (en \(worst.value.count) turnos); los demás días, \(KineSheetFormat.decimal(restMean)).",
                        gist: "El día \(day) del turno es el de más dolor de espalda.",
                        question: "¿Cómo llego mejor al día \(day) del turno, que es el más pesado?",
                        focus: "Preparar la espalda para el día \(day) del turno, el más cargado.")
    }

    // MARK: - Dónde le duele más ("Me duele ahora")

    static func contextoDominante(_ records: [DailyCheckIn]) -> KineFact? {
        let contexts = records.compactMap(\.context)
        guard contexts.count >= Thresholds.minPainRecords else { return nil }
        var counts: [PainContext: Int] = [:]
        for c in contexts { counts[c, default: 0] += 1 }
        let sorted = counts.sorted { a, b in
            a.value != b.value ? a.value > b.value
                : PainContext.allCases.firstIndex(of: a.key)! < PainContext.allCases.firstIndex(of: b.key)!
        }
        guard let top = sorted.first, Double(top.value) / Double(contexts.count) >= Thresholds.contextShare else { return nil }

        var detail = "Registros «Me duele ahora»: " + sorted.map { "\(contextPhrase($0.key)) \($0.value)" }.joined(separator: ", ") + "."
        let zones = PainZone.normalized(records.flatMap(\.allZones))
        if !records.isEmpty { detail += " Zonas: \(PainZone.listTitle(zones).lowercased())." }
        var moments: [Moment: Int] = [:]
        for m in records.compactMap(\.moment) { moments[m, default: 0] += 1 }
        if let m = moments.max(by: { a, b in a.value != b.value ? a.value < b.value : a.key.rawValue > b.key.rawValue }), m.value >= 2 {
            detail += " Momento más frecuente: \(m.key.title.lowercased())."
        }
        let (question, focus) = contextQuestion(top.key)
        return KineFact(id: KineFactID.contextoDominante.rawValue,
                        title: "Dónde le duele más",
                        value: "\(top.key.title) · \(top.value) de \(contexts.count)",
                        detail: detail,
                        gist: "Le duele más \(contextPhrase(top.key)) que en otros momentos.",
                        question: question, focus: focus)
    }

    static func contextPhrase(_ c: PainContext) -> String {
        switch c {
        case .enCabina: "en la cabina"
        case .alBajar: "al bajar del camión"
        case .enElBus: "en el bus"
        case .enCasa: "en casa"
        }
    }

    static func contextQuestion(_ c: PainContext) -> (String, String) {
        switch c {
        case .enCabina: ("¿Cómo me acomodo en la cabina para que no me duela?",
                         "Revisar la postura en la cabina y las pausas durante la conducción.")
        case .alBajar: ("¿Qué hago cuando me duele al bajar del camión?",
                        "Trabajar cómo bajar del camión sin cargar la espalda.")
        case .enElBus: ("¿Qué puedo hacer en el bus para que no me duela la espalda?",
                        "Buscar alivio para los traslados largos en bus.")
        case .enCasa: ("¿Qué ejercicios hago en casa durante la bajada?",
                       "Ordenar ejercicios para los días de descanso en casa.")
        }
    }

    // MARK: - Frase del RDQ-6 que más marca

    static func itemFrecuente(_ rdqDays: [DailyCheckIn]) -> KineFact? {
        guard !rdqDays.isEmpty else { return nil }
        var counts = Array(repeating: 0, count: RDQ6.items.count)
        for c in rdqDays { for (i, yes) in c.answers.enumerated() where yes && i < counts.count { counts[i] += 1 } }
        guard let best = counts.enumerated().max(by: { a, b in a.element != b.element ? a.element < b.element : a.offset > b.offset }),
              best.element >= Thresholds.minItemDays else { return nil }
        let (question, focus) = itemQuestion(best.offset)
        return KineFact(id: KineFactID.itemFrecuente.rawValue,
                        title: "Lo que más marca en el cuestionario",
                        value: "\(best.element) de \(rdqDays.count) días",
                        detail: "Marcó «\(itemText(best.offset))» en \(best.element) de \(rdqDays.count) días con cuestionario RDQ-6.",
                        gist: "\(frequencyWords(best.element, of: rdqDays.count)) marca que \(itemParaphrase(best.offset)).",
                        question: question, focus: focus)
    }

    /// "Todos los días", "Casi todos los días", "Más de la mitad de los días", "Algunos días".
    static func frequencyWords(_ n: Int, of total: Int) -> String {
        guard total > 0 else { return "Algunos días" }
        let share = Double(n) / Double(total)
        if n == total { return "Todos los días" }
        if share >= 0.8 { return "Casi todos los días" }
        if share > 0.5 { return "Más de la mitad de los días" }
        return "Algunos días"
    }

    /// La frase del RDQ-6 en tercera persona, para frases sin cifras.
    static func itemParaphrase(_ index: Int) -> String {
        switch index {
        case RDQ6.itemWalksSlower: "camina más lento que lo habitual"
        case RDQ6.itemOthersDoThings: "trata de que otros hagan cosas por él"
        case RDQ6.itemStandsShortPeriods: "solo está de pie por ratos cortos"
        case RDQ6.itemAvoidsBending: "trata de no agacharse ni arrodillarse"
        case RDQ6.itemWalksShortDistances: "solo camina distancias cortas"
        default: "evita los trabajos pesados en la casa"
        }
    }

    /// Frase del RDQ-6 sin el punto final (va entre comillas dentro de otra frase).
    static func itemText(_ index: Int) -> String {
        var text = RDQ6.items[index]
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func itemQuestion(_ index: Int) -> (String, String) {
        switch index {
        case RDQ6.itemWalksSlower: ("¿Qué me ayuda a caminar a mi ritmo sin que me duela?",
                                    "Trabajar la caminata para que vuelva a su ritmo sin dolor.")
        case RDQ6.itemOthersDoThings: ("¿Cómo vuelvo a hacer mis cosas sin pedir ayuda?",
                                       "Recuperar autonomía en las tareas del día a día.")
        case RDQ6.itemStandsShortPeriods: ("¿Cómo aguanto más rato de pie sin dolor?",
                                           "Aumentar el tiempo que tolera de pie.")
        case RDQ6.itemAvoidsBending: ("¿Cómo me agacho sin que me duela la espalda?",
                                      "Trabajar el agacharse sin dolor.")
        case RDQ6.itemWalksShortDistances: ("¿Cómo voy alargando lo que camino sin que me duela?",
                                            "Alargar de a poco las distancias que camina.")
        default: ("¿Qué trabajos de la casa puedo hacer sin riesgo para la espalda?",
                  "Volver de a poco a los trabajos de la casa.")
        }
    }

    // MARK: - Mejor después de la pausa

    static func mejoraPost(_ sessions: [PauseSession]) -> KineFact? {
        let posts = sessions.compactMap(\.postResponse)
        guard posts.count >= Thresholds.minPostResponses else { return nil }
        let better = posts.filter { $0 == .mejor }.count
        let same = posts.filter { $0 == .igual }.count
        let worse = posts.filter { $0 == .peor }.count
        let share = Double(better) / Double(posts.count)
        let helps = share >= Thresholds.betterShare
        let gist = share >= 0.75 ? "Después de la pausa casi siempre dice sentirse mejor."
            : helps ? "La mayoría de las veces se siente mejor después de la pausa."
            : "Pocas veces se siente mejor después de la pausa."
        return KineFact(id: KineFactID.mejoraPost.rawValue,
                        title: "Mejor después de la pausa",
                        value: "\(better) de \(posts.count) pausas",
                        detail: "Después de la pausa respondió Mejor \(better), Igual \(same) y Peor \(worse) \(posts.count == 1 ? "vez" : "veces") (\(KineSheetFormat.percent(Double(better) / Double(posts.count))) Mejor).",
                        gist: gist,
                        question: helps ? "La pausa me ayuda, ¿qué más puedo hacer en los turnos de 12 horas?"
                                        : "La pausa no siempre me alivia, ¿qué ejercicio cambio?",
                        focus: helps ? "Reforzar las pausas que le funcionan durante el turno."
                                     : "Ajustar los ejercicios de la pausa para que lo alivien más.")
    }

    // MARK: - Ejercicio que acompaña la mejora

    /// Compara el % de pausas "Mejor" con y sin cada ejercicio (verificado o contado, sin reflejos).
    /// Un ejercicio que está en todas las pausas no se puede comparar y no sale.
    static func ejercicioQueAyuda(_ sessions: [PauseSession]) -> KineFact? {
        let closed = sessions.filter { $0.postResponse != nil }
        var best: (kind: ActivityKind, lift: Double, with: (Int, Int), without: (Int, Int))?
        for kind in ActivityKind.allCases where kind != .stroop {
            func did(_ s: PauseSession) -> Bool {
                s.activities.contains { $0.kind == kind && !$0.skipped && $0.level >= .reduced }
            }
            let with = closed.filter(did), without = closed.filter { !did($0) }
            guard with.count >= Thresholds.minGroupSessions, without.count >= Thresholds.minGroupSessions else { continue }
            let w = with.filter { $0.postResponse == .mejor }.count
            let wo = without.filter { $0.postResponse == .mejor }.count
            let lift = Double(w) / Double(with.count) - Double(wo) / Double(without.count)
            guard lift >= Thresholds.minExerciseLift else { continue }
            if best == nil || lift > best!.lift || (lift == best!.lift && with.count > best!.with.1) {
                best = (kind, lift, (w, with.count), (wo, without.count))
            }
        }
        guard let best else { return nil }
        let name = exerciseName(best.kind)
        return KineFact(id: KineFactID.ejercicioQueAyuda.rawValue,
                        title: "Ejercicio que acompaña la mejora",
                        value: "\(name.capitalizedFirst) · \(best.with.0) de \(best.with.1)",
                        detail: "Las pausas con \(name) terminaron Mejor \(best.with.0) de \(best.with.1) veces; sin \(name), \(best.without.0) de \(best.without.1).",
                        gist: "Las pausas con \(name) terminan mejor más seguido que las pausas sin \(name).",
                        question: exerciseQuestion(best.kind),
                        focus: "Ver si conviene repetir \(name) más veces durante el turno.")
    }

    /// Nombre clínico en minúscula para frases (el catálogo usa nombres coloquiales de faena).
    static func exerciseName(_ kind: ActivityKind) -> String {
        switch kind {
        case .extensionLumbar: "extensión lumbar de pie"
        case .pasos: "caminata"
        case .sentadilla: "sentadilla parcial"
        case .pararseSentarse: "pararse y sentarse de la silla"
        case .cuello: "movilidad de cuello"
        case .respiracion: "respiración diafragmática"
        case .ojos: "parpadeo"
        case .stroop: "prueba de reflejos"
        }
    }

    static func exerciseQuestion(_ kind: ActivityKind) -> String {
        switch kind {
        case .pasos: "¿Me conviene caminar más seguido durante el turno?"
        case .extensionLumbar: "¿Me conviene hacer más extensiones de espalda en el turno?"
        case .sentadilla: "¿Puedo hacer más sentadillas o conviene bajar la carga?"
        case .pararseSentarse: "¿Me conviene pararme de la silla más veces durante el turno?"
        case .cuello: "¿Me conviene mover más el cuello durante el turno?"
        case .respiracion: "¿Cuándo me conviene hacer la respiración para el dolor?"
        case .ojos: "¿Cada cuánto conviene descansar la vista en la cabina?"
        case .stroop: "¿Qué ejercicio me conviene repetir en el turno?"
        }
    }

    // MARK: - Alertas

    static func alertas(checkIns: [DailyCheckIn], rdqDays: [DailyCheckIn], sessions: [PauseSession],
                        calendar: Calendar) -> KineFact? {
        let alarms = checkIns.filter(\.hasAlarm).sorted { $0.date > $1.date }
        let high = rdqDays.filter { $0.score >= Thresholds.highRDQ }
        let worse = sessions.filter { $0.postResponse == .peor }.count
        let asked = checkIns.contains { !$0.alarmAnswers.isEmpty }
        guard !alarms.isEmpty || !high.isEmpty || worse > 0 else { return nil }

        var parts: [String] = []
        if let last = alarms.first {
            let questions = zip(RDQ6.alarmQuestions, last.alarmAnswers).filter { $0.1 }.map { "«\($0.0)»" }
            parts.append("El \(KineSheetFormat.dayMonth(last.date, calendar: calendar)) respondió Sí a \(questions.joined(separator: " y ")).")
        }
        if !high.isEmpty {
            let max = high.map(\.score).max() ?? Thresholds.highRDQ
            parts.append("RDQ-6 de \(Thresholds.highRDQ) o más en \(high.count) \(high.count == 1 ? "día" : "días") (máximo \(max) de \(RDQ6.maxScore)); la app pasó al plan suave.")
        }
        if worse > 0 {
            parts.append("Respondió Peor después de la pausa \(worse) \(worse == 1 ? "vez" : "veces").")
        }
        if alarms.isEmpty && asked {
            parts.append("Preguntas de alarma: todas respondidas No.")
        }

        let value: String
        if !alarms.isEmpty {
            value = "\(alarms.count) \(alarms.count == 1 ? "respuesta" : "respuestas") de alarma"
        } else if !high.isEmpty {
            value = "\(high.count) \(high.count == 1 ? "día" : "días") con RDQ \(Thresholds.highRDQ) o más"
        } else {
            value = "Peor \(worse) \(worse == 1 ? "vez" : "veces")"
        }
        return KineFact(id: KineFactID.alertas.rawValue,
                        title: alarms.isEmpty ? "Días de dolor alto" : "Señales de alarma",
                        value: value,
                        detail: parts.joined(separator: " "),
                        gist: !alarms.isEmpty ? "Marcó una señal de alarma en el cuestionario."
                            : !high.isEmpty ? "Tuvo días de dolor alto en que la app pasó al plan suave."
                            : "Algunas pausas terminaron con más dolor que antes.",
                        question: alarms.isEmpty ? "¿Qué hago los días en que el dolor está muy alto?"
                                                 : "Marqué una señal de alarma, ¿cuándo debo consultar de urgencia?",
                        focus: alarms.isEmpty ? "Ajustar los ejercicios para los días de dolor alto."
                                              : "Revisar las señales de alarma antes de seguir con los ejercicios.",
                        mustInclude: !alarms.isEmpty)
    }

    // MARK: - Días de turno con pausa

    static func adherencia(_ s: StatsSummary) -> KineFact? {
        let turnos = s.turnos.filter { $0.workDays > 0 }
        let currentKey = s.currentTurno?.turnoKey
        let elapsed = RuleBasedCoach.daysElapsed(s)
        func days(_ t: TurnoSummary) -> Int {
            t.turnoKey == currentKey ? max(t.daysWithPause, min(t.workDays, elapsed ?? t.workDays)) : t.workDays
        }
        let total = turnos.reduce(0) { $0 + days($1) }
        let withPause = turnos.reduce(0) { $0 + $1.daysWithPause }
        guard total > 0, withPause > 0 else { return nil }
        let share = Double(withPause) / Double(total)
        let gist = share >= 0.75 ? "Hace la pausa en la mayoría de los días de turno."
            : share >= 0.4 ? "Hace la pausa en cerca de la mitad de los días de turno."
            : "Le cuesta hacer la pausa en los días de turno."
        var detail = "Hizo al menos una pausa verificada en \(withPause) de \(total) días de turno (\(turnos.count) \(turnos.count == 1 ? "turno" : "turnos"))."
        if let cur = s.currentTurno, turnos.count > 1 {
            detail += " Este turno: \(cur.daysWithPause) de \(days(cur)) días."
        }
        if s.streak > 0 { detail += " Racha actual: \(s.streak) \(s.streak == 1 ? "día" : "días")." }
        return KineFact(id: KineFactID.adherencia.rawValue,
                        title: "Días de turno con pausa",
                        value: "\(withPause) de \(total) días",
                        detail: detail,
                        gist: gist,
                        question: "¿Qué hago los días que no alcanzo a hacer la pausa?",
                        focus: "Encontrar cómo hacer la pausa todos los días del turno.")
    }

    // MARK: - Nivel por pausas completas (LevelProgress)

    /// Nivel y días con la pausa completa, calculados en Swift (`LevelProgress`): el modelo solo cita
    /// este hecho por su id; la cifra la pone siempre la app.
    static func nivel(_ p: LevelProgress) -> KineFact? {
        guard p.daysWithPause > 0 else { return nil }
        let full = p.fullDays, total = p.daysWithPause
        let share = Double(full) / Double(total)
        let gist: String
        if full == total {
            gist = "Completa la pausa entera todos los días que la hace."
        } else if share >= 0.8 {
            gist = "Completa la pausa entera casi todos los días que la hace."
        } else if share > 0.5 {
            gist = "Completa la pausa entera más de la mitad de los días que la hace."
        } else if full > 0 {
            gist = "Completa la pausa entera solo algunos días; los demás hace una parte."
        } else {
            gist = "Todavía no completa la pausa entera; hace una parte de los ejercicios."
        }
        let mostly = share > 0.5
        return KineFact(id: KineFactID.nivel.rawValue,
                        title: "Nivel por pausas completas",
                        value: p.shortValue,
                        detail: "\(p.levelLine): \(p.fullDaysLine). Cada día con la pausa completa sube un nivel; una pausa incompleta suma la parte que hizo.",
                        gist: gist,
                        question: mostly ? "Completo la pausa la mayoría de los días, ¿me conviene subir las metas?"
                                         : "¿Qué ejercicio de la pausa me conviene priorizar si no alcanzo a hacerla entera?",
                        focus: mostly ? "Mantener la pausa completa y ver si conviene subir las metas."
                                      : "Ver qué ejercicios de la pausa le cuestan y cómo completarla más días.")
    }
}

extension String {
    /// "caminata" → "Caminata".
    nonisolated var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
