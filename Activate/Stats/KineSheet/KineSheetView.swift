import SwiftUI

// Dueño: agente "kine-sheet".
// Hoja para el kinesiólogo / la mutual. Vista PLANA: sin glassEffect ni materiales, porque
// ImageRenderer la rasteriza tal cual para PNG/PDF. El texto lo redacta el coach (KineSheet);
// las cifras las calcula Swift (KineSheetTable) y van siempre debajo: la narrativa nunca es la
// única fuente. Copy de usted, sin diagnóstico.

struct KineSheetView: View {
    let sheet: KineSheet
    let summary: StatsSummary
    let profile: PlayerProfile
    /// Líneas de alerta calculadas fuera de la vista (check-ins con respuesta de alarma). Vacío si no hay.
    var extraAlerts: [String] = []
    /// Ancho fijo para exportar (390 pt). `nil` en pantalla: ocupa el ancho disponible.
    var width: CGFloat? = nil
    /// Fecha de generación (cabecera y período).
    var now: Date = .now

    private var isExport: Bool { width != nil }

    var body: some View {
        let table = KineSheetTable.build(summary: summary, profile: profile, extraAlerts: extraAlerts, now: now)
        VStack(alignment: .leading, spacing: 18) {
            header(table)
            narrative(title: "Cuándo le duele", symbol: "clock", text: sheet.whenItHurts)
            narrative(title: "Qué hizo", symbol: "figure.walk", text: sheet.whatHeDid)
            narrative(title: "Qué lo empeora", symbol: "arrow.down.right.circle", text: sheet.whatWorsens)
            narrative(title: "Cómo va", symbol: "chart.line.uptrend.xyaxis", text: sheet.howItGoes)
            numbersByTurno(table)
            rdqItems(table)
            alerts(table)
            footer
        }
        .padding(20)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(Paper.background, in: .rect(cornerRadius: isExport ? 0 : Theme.cardRadius))
        .foregroundStyle(Paper.ink)
        .multilineTextAlignment(.leading)
        .fontDesign(.rounded)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hoja para el kinesiólogo de \(profile.name)")
    }

    // MARK: Cabecera

    private func header(_ table: KineSheetTable) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hoja para el kinesiólogo")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Paper.accent)
                    Text(profile.name)
                        .font(.title.weight(.heavy))
                    Text("Operador CAEX · turno \(profile.roster.rawValue)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Paper.inkSecondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: "figure.walk.motion")
                        .font(.title2)
                        .foregroundStyle(Paper.accent)
                    Text("Activate")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Paper.inkSecondary)
                }
            }
            rule
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Período").foregroundStyle(Paper.inkSecondary)
                    Text(table.periodText).fontWeight(.semibold)
                }
                GridRow {
                    Text("Zona habitual").foregroundStyle(Paper.inkSecondary)
                    Text(profile.usualZone.title).fontWeight(.semibold)
                }
                GridRow {
                    Text("Generada").foregroundStyle(Paper.inkSecondary)
                    Text(KineSheetFormat.longDate(now)).fontWeight(.semibold)
                }
            }
            .font(.footnote)
        }
    }

    // MARK: Bloques del coach

    private func narrative(title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Paper.accent)
                Text(title)
                    .font(.headline)
            }
            Text(text.isEmpty ? "Sin datos para este bloque." : text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.card, in: .rect(cornerRadius: 14))
    }

    // MARK: Tabla por turno (Swift)

    @ViewBuilder
    private func numbersByTurno(_ table: KineSheetTable) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Cifras por turno",
                          subtitle: table.truncated ? "Últimos \(table.columns.count) de \(table.totalTurnos) turnos" : "Calculadas por la app con registros verificados")
            if table.columns.isEmpty {
                Text("Sin turnos con registros todavía.")
                    .font(.footnote)
                    .foregroundStyle(Paper.inkSecondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Turno del")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Paper.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(table.columns) { column in
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(column.title).font(.caption.weight(.bold))
                                Text(column.isCurrent ? "actual" : " ")
                                    .font(.caption2)
                                    .foregroundStyle(Paper.accent)
                            }
                            .gridColumnAlignment(.trailing)
                        }
                    }
                    rule
                    ForEach(table.rows) { row in
                        GridRow {
                            Text(row.label)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                                Text(value)
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Frases del RDQ-6 (Swift)

    @ViewBuilder
    private func rdqItems(_ table: KineSheetTable) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Frases del RDQ-6 marcadas «Sí»",
                          subtitle: "Cuestionario de Discapacidad Roland-Morris, versión chilena abreviada (6 ítems)")
            if table.columns.isEmpty {
                Text("Sin cuestionarios registrados en el período.")
                    .font(.footnote)
                    .foregroundStyle(Paper.inkSecondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Debido a su dolor de espalda:")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Paper.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Actual").font(.caption.weight(.bold)).foregroundStyle(Paper.inkSecondary).gridColumnAlignment(.trailing)
                        Text("Total").font(.caption.weight(.bold)).foregroundStyle(Paper.inkSecondary).gridColumnAlignment(.trailing)
                    }
                    rule
                    ForEach(table.items) { item in
                        GridRow {
                            Text("\(item.index + 1). \(item.text)")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(KineSheetFormat.int(item.current))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text(KineSheetFormat.int(item.total))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                Text("Cantidad de días con la frase marcada «Sí» (turno actual y total del período).")
                    .font(.caption2)
                    .foregroundStyle(Paper.inkSecondary)
            }
        }
    }

    // MARK: Alertas

    @ViewBuilder
    private func alerts(_ table: KineSheetTable) -> some View {
        let coachText = sheet.alerts.trimmingCharacters(in: .whitespacesAndNewlines)
        if !coachText.isEmpty || !table.alerts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.danger)
                    Text("Alertas").font(.headline)
                }
                if !coachText.isEmpty {
                    Text(coachText)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(table.alerts.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(0.08), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.danger.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: Pie

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            rule
            Text("Datos verificados por sensores y firmados en el teléfono. Nada sale del dispositivo sin que la persona lo comparta.")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(RDQ6.citation)
                .font(.caption2)
                .foregroundStyle(Paper.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(backendLine)
                .font(.caption2)
                .foregroundStyle(Paper.inkSecondary)
        }
    }

    private var backendLine: String {
        switch sheet.backend {
        case .foundationModels: "Texto redactado por el modelo local del teléfono; cifras calculadas por la app."
        case .rules: "Texto de plantilla; cifras calculadas por la app."
        }
    }

    // MARK: Piezas

    private func sectionHeader(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Paper.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Paper.rule)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// Paleta fija de "papel": la hoja se ve igual en pantalla (claro u oscuro) y en el PNG/PDF.
private enum Paper {
    static let background = Color.white
    static let ink = Color(white: 0.10)
    static let inkSecondary = Color(white: 0.42)
    static let rule = Color(white: 0.86)
    static let card = Color(white: 0.955)
    static let accent = Theme.copperDeep
}

// MARK: - Formato (es-CL)

nonisolated enum KineSheetFormat {
    static let locale = Locale(identifier: "es_CL")

    static func int(_ n: Int) -> String {
        n.formatted(.number.locale(locale))
    }

    static func decimal(_ d: Double) -> String {
        d.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    static func percent(_ ratio: Double) -> String {
        ratio.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "12 oct" (es_CL abrevia "oct."; se quita el punto para la tabla).
    static func dayMonth(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).day().month(.abbreviated))
            .replacingOccurrences(of: ".", with: "")
    }

    /// "12 oct 2026"
    static func dayMonthYear(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).day().month(.abbreviated).year())
            .replacingOccurrences(of: ".", with: "")
    }

    /// "23 de octubre de 2026"
    static func longDate(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar))
    }
}

// MARK: - Tabla numérica (Swift puro, testeable)

nonisolated struct KineSheetTable: Sendable, Equatable {
    /// Turnos que caben en 390 pt con la columna de etiquetas legible.
    static let maxTurnos = 3
    /// Alertas de alarma (check-ins) que se listan como máximo.
    static let maxAlarmLines = 6

    nonisolated struct Column: Sendable, Equatable, Identifiable {
        var turnoKey: String
        var title: String
        var isCurrent: Bool
        var id: String { turnoKey }
    }

    nonisolated struct Row: Sendable, Equatable, Identifiable {
        var label: String
        var values: [String]
        var id: String { label }
    }

    nonisolated struct ItemRow: Sendable, Equatable, Identifiable {
        var index: Int
        var text: String
        var current: Int
        var total: Int
        var id: Int { index }
    }

    /// Turnos mostrados, ordenados del más antiguo al más reciente.
    var turnos: [TurnoSummary]
    var columns: [Column]
    var rows: [Row]
    var items: [ItemRow]
    var alerts: [String]
    var periodText: String
    var totalTurnos: Int

    var truncated: Bool { totalTurnos > columns.count }

    static func build(summary: StatsSummary, profile: PlayerProfile, extraAlerts: [String] = [],
                      now: Date = .now, calendar: Calendar = .current) -> KineSheetTable {
        let work = WorkCalendar(profile: profile, calendar: calendar)

        var all = summary.turnos
        for extra in [summary.currentTurno, summary.previousTurno].compactMap({ $0 })
        where !all.contains(where: { $0.turnoKey == extra.turnoKey }) {
            all.append(extra)
        }
        all.sort { $0.turnoKey < $1.turnoKey }
        let shown = Array(all.suffix(maxTurnos))
        let currentKey = summary.currentTurno?.turnoKey

        let columns = shown.map { turno in
            Column(turnoKey: turno.turnoKey,
                   title: work.date(forKey: turno.turnoKey).map { KineSheetFormat.dayMonth($0, calendar: calendar) } ?? turno.label,
                   isCurrent: turno.turnoKey == currentKey)
        }

        let rows: [Row] = [
            Row(label: "Días con pausa", values: shown.map { "\($0.daysWithPause) de \($0.workDays)" }),
            Row(label: "Pausas verificadas", values: shown.map { KineSheetFormat.int($0.countedPauses) }),
            Row(label: "RDQ-6 promedio", values: shown.map { $0.meanRDQ.map(KineSheetFormat.decimal) ?? "—" }),
            Row(label: "RDQ-6 máximo", values: shown.map { $0.maxRDQ.map { "\($0) de \(RDQ6.maxScore)" } ?? "—" }),
            Row(label: "Mejor después", values: shown.map { betterFraction($0) }),
            Row(label: "% Mejor", values: shown.map { betterRatio($0).map(KineSheetFormat.percent) ?? "—" }),
            Row(label: "Pasos verificados", values: shown.map { KineSheetFormat.int($0.verifiedSteps) }),
            Row(label: "Reps verificadas", values: shown.map { KineSheetFormat.int($0.verifiedReps) }),
            Row(label: "Racha máxima (días)", values: shown.map { KineSheetFormat.int($0.maxStreak) }),
        ]

        let current = shown.first { $0.turnoKey == currentKey }
        let items = RDQ6.items.enumerated().map { index, text in
            ItemRow(index: index,
                    text: text,
                    current: current.map { frequency($0, item: index) } ?? 0,
                    total: shown.reduce(0) { $0 + frequency($1, item: index) })
        }

        var alerts: [String] = []
        for turno in shown {
            if let max = turno.maxRDQ, max >= RDQ6.gentlePlanThreshold {
                let label = columns.first { $0.turnoKey == turno.turnoKey }?.title ?? turno.label
                alerts.append("RDQ-6 de \(max) de \(RDQ6.maxScore) en el turno del \(label): la app pasó al plan suave.")
            }
        }
        let worse = shown.reduce(0) { $0 + $1.worseCount }
        if worse > 0 {
            alerts.append("Respondió «Peor» después de la pausa \(worse) \(worse == 1 ? "vez" : "veces") en el período.")
        }
        alerts.append(contentsOf: extraAlerts)

        let periodText: String
        if let first = shown.first, let last = shown.last,
           let start = work.date(forKey: first.turnoKey), let lastStart = work.date(forKey: last.turnoKey) {
            let end = calendar.date(byAdding: .day, value: max(0, last.workDays - 1), to: lastStart) ?? lastStart
            let count = shown.count
            periodText = "Del \(KineSheetFormat.dayMonth(start, calendar: calendar)) al \(KineSheetFormat.dayMonthYear(end, calendar: calendar)) · \(count) \(count == 1 ? "turno" : "turnos")"
        } else {
            periodText = "Sin turnos con registros"
        }

        return KineSheetTable(turnos: shown, columns: columns, rows: rows, items: items, alerts: alerts,
                              periodText: periodText, totalTurnos: all.count)
    }

    /// Líneas para "Alertas" a partir de check-ins con alguna pregunta de alarma en Sí (las más recientes).
    static func alarmLines(checkIns: [DailyCheckIn], calendar: Calendar = .current, limit: Int = maxAlarmLines) -> [String] {
        checkIns
            .filter(\.hasAlarm)
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { checkIn in
                let questions = zip(RDQ6.alarmQuestions, checkIn.alarmAnswers)
                    .filter { $0.1 }
                    .map { "«\($0.0)»" }
                return "\(KineSheetFormat.dayMonthYear(checkIn.date, calendar: calendar)): respondió Sí a \(questions.joined(separator: " y "))."
            }
    }

    static func frequency(_ turno: TurnoSummary, item: Int) -> Int {
        turno.itemFrequency.indices.contains(item) ? turno.itemFrequency[item] : 0
    }

    static func postTotal(_ turno: TurnoSummary) -> Int {
        turno.betterCount + turno.sameCount + turno.worseCount
    }

    static func betterRatio(_ turno: TurnoSummary) -> Double? {
        let total = postTotal(turno)
        return total > 0 ? Double(turno.betterCount) / Double(total) : nil
    }

    static func betterFraction(_ turno: TurnoSummary) -> String {
        let total = postTotal(turno)
        return total > 0 ? "\(turno.betterCount) de \(total)" : "—"
    }
}

// MARK: - Plantilla (Swift) mientras llega el coach o cuando deja campos vacíos

nonisolated enum KineSheetFallback {
    /// Hoja completa redactada por reglas con las mismas cifras de la tabla.
    static func sheet(summary: StatsSummary, profile: PlayerProfile, table: KineSheetTable) -> KineSheet {
        KineSheet(period: table.periodText,
                  whenItHurts: whenItHurts(summary: summary, profile: profile, table: table),
                  whatHeDid: whatHeDid(summary: summary, table: table),
                  whatWorsens: whatWorsens(summary: summary),
                  howItGoes: howItGoes(summary: summary, table: table),
                  alerts: "",
                  backend: .rules)
    }

    /// Campo por campo: el texto del coach si trae algo; si no, la plantilla. Conserva el backend del coach.
    static func merge(_ coach: KineSheet, fallback: KineSheet) -> KineSheet {
        func pick(_ a: String, _ b: String) -> String {
            let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? b : t
        }
        return KineSheet(period: pick(coach.period, fallback.period),
                         whenItHurts: pick(coach.whenItHurts, fallback.whenItHurts),
                         whatHeDid: pick(coach.whatHeDid, fallback.whatHeDid),
                         whatWorsens: pick(coach.whatWorsens, fallback.whatWorsens),
                         howItGoes: pick(coach.howItGoes, fallback.howItGoes),
                         alerts: coach.alerts.trimmingCharacters(in: .whitespacesAndNewlines),
                         backend: coach.backend)
    }

    static func whenItHurts(summary: StatsSummary, profile: PlayerProfile, table: KineSheetTable) -> String {
        var parts: [String] = ["Zona habitual: \(profile.usualZone.title.lowercased())."]
        var hasData = false
        if let current = summary.currentTurno, let mean = current.meanRDQ {
            hasData = true
            let max = current.maxRDQ.map { " (máximo \($0))" } ?? ""
            parts.append("RDQ-6 promedio del turno actual: \(KineSheetFormat.decimal(mean)) de \(RDQ6.maxScore)\(max).")
        }
        if let today = summary.todayRDQ {
            hasData = true
            parts.append("Hoy: \(today) de \(RDQ6.maxScore).")
        }
        if let top = table.items.max(by: { $0.total < $1.total }), top.total > 0 {
            hasData = true
            parts.append("Frase más marcada: «\(top.text)» (\(top.total) \(top.total == 1 ? "día" : "días")).")
        }
        if !hasData {
            parts.append("Sin cuestionarios RDQ-6 registrados en el período.")
        }
        return parts.joined(separator: " ")
    }

    static func whatHeDid(summary: StatsSummary, table: KineSheetTable) -> String {
        let pauses = table.turnos.reduce(0) { $0 + $1.countedPauses }
        let steps = table.turnos.reduce(0) { $0 + $1.verifiedSteps }
        let reps = table.turnos.reduce(0) { $0 + $1.verifiedReps }
        guard pauses > 0 || steps > 0 || reps > 0 else {
            return "Sin pausas verificadas en el período."
        }
        let count = table.turnos.count
        var parts = ["\(KineSheetFormat.int(pauses)) \(pauses == 1 ? "pausa verificada" : "pausas verificadas") en \(count) \(count == 1 ? "turno" : "turnos")."]
        parts.append("\(KineSheetFormat.int(steps)) pasos y \(KineSheetFormat.int(reps)) repeticiones contadas por sensores.")

        var perKind: [ActivityKind: Int] = [:]
        for session in summary.recentSessions where session.level >= .reduced {
            for kind in session.activityKinds where kind != .stroop {
                perKind[kind, default: 0] += 1
            }
        }
        let top = perKind.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }.prefix(4)
        if !top.isEmpty {
            parts.append("Ejercicios recientes: " + top.map { "\(clinicalName($0.key)) ×\($0.value)" }.joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }

    static func whatWorsens(summary: StatsSummary) -> String {
        let hints = summary.worsensHints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !hints.isEmpty else { return "Sin patrones claros todavía: faltan registros." }
        return hints.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }

    static func howItGoes(summary: StatsSummary, table: KineSheetTable) -> String {
        var parts: [String] = []
        let better = table.turnos.reduce(0) { $0 + $1.betterCount }
        let same = table.turnos.reduce(0) { $0 + $1.sameCount }
        let worse = table.turnos.reduce(0) { $0 + $1.worseCount }
        let total = better + same + worse
        if total > 0 {
            parts.append("Después de la pausa: Mejor \(better), Igual \(same), Peor \(worse) (\(KineSheetFormat.percent(Double(better) / Double(total))) Mejor).")
        }
        if let current = summary.currentTurno?.meanRDQ, let previous = summary.previousTurno?.meanRDQ {
            parts.append("RDQ-6 promedio: \(KineSheetFormat.decimal(previous)) en el turno anterior, \(KineSheetFormat.decimal(current)) en el actual.")
        }
        if summary.streak > 0 {
            parts.append("Racha actual: \(summary.streak) \(summary.streak == 1 ? "día" : "días") con pausa.")
        }
        guard !parts.isEmpty else { return "Sin datos suficientes para ver una tendencia." }
        return parts.joined(separator: " ")
    }

    /// Nombre clínico para la hoja (el catálogo usa nombres coloquiales de faena).
    static func clinicalName(_ kind: ActivityKind) -> String {
        switch kind {
        case .extensionLumbar: "Extensión lumbar de pie"
        case .pasos: "Caminata"
        case .sentadilla: "Sentadilla parcial"
        case .cuello: "Movilidad cervical"
        case .respiracion: "Respiración diafragmática"
        case .ojos: "Descanso visual y parpadeo"
        case .stroop: "Prueba de reflejos"
        }
    }
}

// MARK: - Caché JSON en SaveData.lastKineSheetJSON

nonisolated enum KineSheetCache {
    static func encode(_ sheet: KineSheet) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sheet) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> KineSheet? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KineSheet.self, from: data)
    }
}

// MARK: - Datos de muestra para previews

#if DEBUG
enum KineSheetSample {
    static let profile = PlayerProfile(rosterStart: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12)) ?? .now)

    static let summary: StatsSummary = {
        let t1 = TurnoSummary(turnoKey: "2026-09-14", label: "14 sep", workDays: 7, daysWithPause: 3, countedPauses: 4,
                              meanRDQ: 4.2, maxRDQ: 5, itemFrequency: [4, 1, 3, 5, 2, 4], betterCount: 2, sameCount: 2, worseCount: 0,
                              verifiedSteps: 980, verifiedReps: 20, maxStreak: 2, stroopMedianRTms: nil, blinksPerMinute: nil, neckMaxYaw: nil)
        let t2 = TurnoSummary(turnoKey: "2026-09-28", label: "28 sep", workDays: 7, daysWithPause: 5, countedPauses: 7,
                              meanRDQ: 3.4, maxRDQ: 5, itemFrequency: [3, 0, 2, 5, 1, 3], betterCount: 5, sameCount: 2, worseCount: 0,
                              verifiedSteps: 1720, verifiedReps: 45, maxStreak: 3, stroopMedianRTms: nil, blinksPerMinute: nil, neckMaxYaw: nil)
        let t3 = TurnoSummary(turnoKey: "2026-10-12", label: "12 oct", workDays: 5, daysWithPause: 4, countedPauses: 6,
                              meanRDQ: 2.5, maxRDQ: 4, itemFrequency: [2, 0, 1, 4, 0, 2], betterCount: 5, sameCount: 1, worseCount: 0,
                              verifiedSteps: 1540, verifiedReps: 40, maxStreak: 4, stroopMedianRTms: nil, blinksPerMinute: nil, neckMaxYaw: nil)
        return StatsSummary(currentTurno: t3, previousTurno: t2, turnos: [t1, t2, t3], streak: 4, totalCountedPauses: 17, todayRDQ: 2,
                            recentSessions: [], worsensHints: ["Le duele más al bajar del camión", "El día 1 del turno es el más cargado"],
                            historyLines: [], currentTurnoDays: [])
    }()

    static var fallback: KineSheet {
        KineSheetFallback.sheet(summary: summary, profile: profile,
                                table: KineSheetTable.build(summary: summary, profile: profile))
    }
}

#Preview("Hoja (plantilla)") {
    ScrollView {
        KineSheetView(sheet: KineSheetSample.fallback, summary: KineSheetSample.summary, profile: KineSheetSample.profile)
            .padding(16)
    }
    .background(Color(.systemBackground))
}
#endif
