import SwiftUI

// Dueño: paquete "kine-ai".
// "Reporte de Salud" (antes "Hoja para el kine"), para el kinesiólogo o la mutual, tal como se comparte
// (PNG/PDF). Vista PLANA: sin glassEffect ni materiales, porque ImageRenderer la rasteriza tal cual.
// Arriba el nivel por pausas completas (Swift), luego "Para la consulta" (3 hallazgos con su cifra de
// Swift, 3 preguntas y un foco), "En palabras de Marco" si escribió algo, y debajo las cifras por turno
// que calcula Swift: la redacción nunca es la única fuente. Copy sin diagnóstico. Los tipos conservan el
// prefijo `Kine`; lo que ve la persona dice "Reporte de Salud".

/// Nombre visible del documento y a quién va dirigido.
nonisolated enum HealthReport {
    static let title = "Reporte de Salud"
    /// Subtítulo corto bajo el título (pantalla, PNG y PDF).
    static let audience = "Para el kinesiólogo o la mutual"
}

/// Todo lo que necesita la hoja exportada (Sendable: viaja en `Transferable`).
nonisolated struct KineSheetContent: Sendable, Hashable {
    var sheet: KineSheet
    var facts: [KineFact]
    var summary: StatsSummary
    var profile: PlayerProfile
    /// Líneas de alarma calculadas desde los check-ins (vacío si no hay).
    var extraAlerts: [String] = []
    var generatedAt: Date = .now
    /// Nivel por pausas completas (`LevelProgress`, Swift). `nil` o sin días: el reporte no lo muestra.
    var level: LevelProgress? = nil

    /// Nivel que se muestra (solo si hay al menos un día con pausa verificada).
    var shownLevel: LevelProgress? {
        guard let level, level.daysWithPause > 0 else { return nil }
        return level
    }

    /// Hallazgos con su hecho (los que perdieron su hecho, p. ej. caché antigua, no se muestran).
    var findings: [(fact: KineFact, sentence: String)] {
        sheet.consult.findings.compactMap { f in
            facts.first { $0.id == f.factID }.map { ($0, f.sentence) }
        }
    }

    var questions: [String] {
        sheet.consult.questions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var focus: String { sheet.consult.focus.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Nota con texto (nil si la persona no escribió nada).
    var note: PatientNote? {
        guard let n = sheet.note, !n.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return n
    }

    var usedModel: Bool {
        sheet.consult.backend == .foundationModels || note?.backend == .foundationModels
    }

    /// Origen del texto para el pie de la hoja.
    var originLine: String {
        var line = usedModel
            ? "Hallazgos, preguntas y resumen redactados en el iPhone con Apple Intelligence; cifras calculadas por la app."
            : "Texto de plantilla armado por la app; cifras calculadas por la app."
        if sheet.edited { line += " La persona revisó y editó el texto antes de compartir." }
        return line
    }
}

struct KineSheetView: View {
    let content: KineSheetContent
    /// Ancho fijo para exportar (390 pt). `nil` en pantalla: ocupa el ancho disponible.
    var width: CGFloat? = nil

    private var isExport: Bool { width != nil }
    private var profile: PlayerProfile { content.profile }

    var body: some View {
        let table = KineSheetTable.build(summary: content.summary, profile: profile,
                                         extraAlerts: content.extraAlerts, level: content.shownLevel,
                                         now: content.generatedAt)
        VStack(alignment: .leading, spacing: 18) {
            header(table)
            consultSection
            noteSection
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
        .accessibilityLabel("\(HealthReport.title) de \(profile.name)")
    }

    // MARK: Cabecera

    private func header(_ table: KineSheetTable) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(HealthReport.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Paper.accent)
                    Text(HealthReport.audience)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Paper.inkSecondary)
                    Text(profile.name)
                        .font(.title.weight(.heavy))
                        .padding(.top, 4)
                    Text("Operador CAEX · \(profile.roster.rawValue) · \(profile.shiftType.title.lowercased())")
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
                    Text(profile.allUsualZones.count > 1 ? "Zonas habituales" : "Zona habitual").foregroundStyle(Paper.inkSecondary)
                    Text(PainZone.listTitle(profile.allUsualZones)).fontWeight(.semibold)
                }
                if let level = content.shownLevel {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Nivel").foregroundStyle(Paper.inkSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(level.levelLine).fontWeight(.semibold)
                            Text(level.fullDaysLine)
                                .foregroundStyle(Paper.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                GridRow {
                    Text("Generado").foregroundStyle(Paper.inkSecondary)
                    Text(KineSheetFormat.longDate(content.generatedAt)).fontWeight(.semibold)
                }
            }
            .font(.footnote)
        }
    }

    // MARK: Para la consulta

    @ViewBuilder
    private var consultSection: some View {
        let findings = content.findings
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Para la consulta",
                          subtitle: content.sheet.consult.backend == .foundationModels
                              ? "Lo más relevante, elegido con Apple Intelligence a partir de las cifras de la app"
                              : "Lo más relevante según las cifras de la app")
            if findings.isEmpty {
                Text("Aún no hay datos suficientes para destacar hallazgos.")
                    .font(.footnote)
                    .foregroundStyle(Paper.inkSecondary)
            }
            ForEach(Array(findings.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.fact.title)
                            .font(.subheadline.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text(item.fact.value)
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Paper.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Paper.accentSoft, in: Capsule())
                            .fixedSize()
                    }
                    Text(item.sentence)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.fact.detail.isEmpty && item.fact.detail != item.sentence {
                        Text(item.fact.detail)
                            .font(.caption2)
                            .foregroundStyle(Paper.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Paper.card, in: .rect(cornerRadius: 12))
            }

            let questions = content.questions
            if !questions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preguntas de \(profile.name)").font(.subheadline.weight(.bold))
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, q in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(Paper.accent)
                            Text(q).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.top, 4)
            }

            if !content.focus.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Foco sugerido para la próxima sesión").font(.subheadline.weight(.bold))
                    Text(content.focus)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: En palabras de Marco

    @ViewBuilder
    private var noteSection: some View {
        if let note = content.note {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("En palabras de \(profile.name)")
                let summary = note.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let tags = note.zones.map(\.title) + note.moments.map(\.title)
                if !tags.isEmpty {
                    PaperTags(tags: tags)
                }
                Text("«\(note.original)»")
                    .font(summary.isEmpty ? .subheadline : .footnote)
                    .italic()
                    .foregroundStyle(summary.isEmpty ? Paper.ink : Paper.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.card, in: .rect(cornerRadius: 12))
        }
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
                        Text(RDQ6.stem)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Alertas (Swift)

    @ViewBuilder
    private func alerts(_ table: KineSheetTable) -> some View {
        if !table.alerts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Paper.danger)
                    Text("Alertas").font(.headline)
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
            .background(Paper.danger.opacity(0.07), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Paper.danger.opacity(0.3), lineWidth: 1))
        }
    }

    // MARK: Pie

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            rule
            Text("Datos verificados por sensores y firmados en el teléfono. Nada sale del dispositivo sin que la persona lo comparta.")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(content.originLine)
                .font(.caption2)
                .foregroundStyle(Paper.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(RDQ6.citation)
                .font(.caption2)
                .foregroundStyle(Paper.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

/// Etiquetas planas (zonas y momentos) en filas que se parten solas.
private struct PaperTags: View {
    let tags: [String]
    var body: some View {
        FlowRows(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Paper.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Paper.accentSoft, in: Capsule())
            }
        }
    }
}

/// Layout de filas que se parten (chips). Plano: sirve en pantalla y en ImageRenderer.
struct FlowRows: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Paleta fija de "papel": la hoja se ve igual en pantalla (claro u oscuro) y en el PNG/PDF.
/// Acento azul fijo (variante clara de `Theme.accent`): sin cobre en la hoja.
private enum Paper {
    static let background = Color.white
    static let ink = Color(white: 0.10)
    static let inkSecondary = Color(white: 0.40)
    static let rule = Color(white: 0.86)
    static let card = Color(white: 0.955)
    static let accent = Color(red: 0.13, green: 0.38, blue: 0.84)
    static let accentSoft = Color(red: 0.13, green: 0.38, blue: 0.84).opacity(0.10)
    static let danger = Color(red: 0.78, green: 0.16, blue: 0.14)
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

    /// Filas del nivel por pausas completas (solo si hay días con pausa verificada).
    static let levelFullDaysLabel = "Días con pausa completa"
    static let levelReachedLabel = "Nivel alcanzado"

    /// `level`: nivel por pausas completas (`LevelProgress`); agrega por turno los días con pausa completa
    /// y el nivel alcanzado al cierre de cada turno (el turno actual, hasta hoy).
    static func build(summary: StatsSummary, profile: PlayerProfile, extraAlerts: [String] = [],
                      level: LevelProgress? = nil,
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

        var rows: [Row] = [
            Row(label: "Días con pausa", values: shown.map { "\($0.daysWithPause) de \($0.workDays)" }),
            Row(label: "Pausas verificadas", values: shown.map { KineSheetFormat.int($0.countedPauses) }),
        ]
        if let level, level.daysWithPause > 0 {
            rows.append(Row(label: levelFullDaysLabel,
                            values: shown.map { KineSheetFormat.int(level.fullDays(inTurno: $0.turnoKey)) }))
            rows.append(Row(label: levelReachedLabel,
                            values: shown.map { level.through(turnoKey: $0.turnoKey).compactValue }))
        }
        rows += [
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
            let turnoEnd = calendar.date(byAdding: .day, value: max(0, last.workDays - 1), to: lastStart) ?? lastStart
            // El turno en curso termina "hoy" en la hoja (no en una fecha futura).
            let today = work.workDate(for: now)
            let end = last.turnoKey == currentKey && today >= lastStart ? min(turnoEnd, today) : turnoEnd
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


// MARK: - Caché JSON en SaveData.lastKineSheetJSON (formato 2)

nonisolated enum KineSheetCache {
    static func encode(_ sheet: KineSheet) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sheet) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Tolerante: JSON roto, el formato antiguo (5 bloques en prosa) u otra versión → nil (se ignora).
    static func decode(_ json: String?) -> KineSheet? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sheet = try? decoder.decode(KineSheet.self, from: data),
              sheet.format == KineSheet.currentFormat else { return nil }
        return sheet
    }

    /// La hoja cacheada sirve si todos sus hallazgos siguen teniendo su hecho.
    static func usable(_ sheet: KineSheet, facts: [KineFact]) -> Bool {
        let ids = Set(facts.map(\.id))
        return !sheet.consult.findings.isEmpty && sheet.consult.findings.allSatisfy { ids.contains($0.factID) }
    }
}

// MARK: - Datos de muestra para previews y pruebas de render

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
                            recentSessions: [], worsensHints: ["Le duele más al bajar del camión"],
                            historyLines: [], currentTurnoDays: [])
    }()

    static let facts: [KineFact] = [
        KineFact(id: "rdq_tendencia", title: "Espalda turno a turno (RDQ-6)", value: "4,2 → 3,4 → 2,5",
                 detail: "RDQ-6 promedio por turno (0 a 6, menos es mejor): 4,2 → 3,4 → 2,5. Este turno bajó 0,9 puntos frente al anterior.",
                 gist: "El puntaje de dolor de espalda viene bajando de un turno a otro.",
                 question: "Mi espalda viene mejor, ¿sigo con los mismos ejercicios o subo la carga?",
                 focus: "Revisar los ejercicios que le están ayudando y ver si conviene subir la carga."),
        KineFact(id: "contexto_dominante", title: "Dónde le duele más", value: "Al bajar · 3 de 5",
                 detail: "Registros «Me duele ahora»: al bajar del camión 3, en la cabina 1, en el bus 1. Zonas: espalda baja.",
                 gist: "Le duele más al bajar del camión que en otros momentos.",
                 question: "¿Qué hago cuando me duele al bajar del camión?",
                 focus: "Trabajar cómo bajar del camión sin cargar la espalda."),
        KineFact(id: "mejora_post", title: "Mejor después de la pausa", value: "12 de 16 pausas",
                 detail: "Después de la pausa respondió Mejor 12, Igual 4 y Peor 0 veces (75 % Mejor).",
                 gist: "Después de la pausa casi siempre dice sentirse mejor.",
                 question: "La pausa me ayuda, ¿qué más puedo hacer en los turnos de 12 horas?",
                 focus: "Reforzar las pausas que le funcionan durante el turno."),
    ]

    static var sheet: KineSheet {
        KineSheet(consult: KineConsultRules.template(facts, profile: profile),
                  note: PatientNote(original: "Me duele la espalda al bajar del camión y en la noche me cuesta dormir.",
                                    summary: "El paciente cuenta que le duele la espalda al bajar del camión y que de noche le cuesta dormir.",
                                    zones: [.lumbar], moments: [.salida, .campamento], backend: .foundationModels),
                  factsSignature: KineConsultRules.signature(facts), preparedAt: .now)
    }

    /// Días con pausa de los tres turnos de muestra (pausa completa = 7 de 7, o 3 de 3 en el plan suave).
    static let level: LevelProgress = {
        func day(_ key: String, _ turno: String, _ done: Int, of planned: Int = 7) -> LevelProgress.Day {
            LevelProgress.Day(dayKey: key, turnoKey: turno, completed: done, planned: planned,
                              sessionID: UUID(), startedAt: .now)
        }
        return LevelProgress(days: [
            day("2026-09-14", "2026-09-14", 7), day("2026-09-16", "2026-09-14", 2), day("2026-09-18", "2026-09-14", 5),
            day("2026-09-28", "2026-09-28", 7), day("2026-09-29", "2026-09-28", 3, of: 3), day("2026-10-01", "2026-09-28", 7),
            day("2026-10-02", "2026-09-28", 5), day("2026-10-04", "2026-09-28", 7),
            day("2026-10-12", "2026-10-12", 7), day("2026-10-13", "2026-10-12", 6), day("2026-10-15", "2026-10-12", 7),
            day("2026-10-16", "2026-10-12", 2),
        ], todayKey: "2026-10-16")
    }()

    static var content: KineSheetContent {
        KineSheetContent(sheet: sheet, facts: facts, summary: summary, profile: profile, level: level)
    }
}

#Preview("Reporte de Salud (plantilla)") {
    ScrollView {
        KineSheetView(content: KineSheetSample.content)
            .padding(16)
    }
    .background(Color(.systemBackground))
}
#endif
