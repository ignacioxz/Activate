import SwiftUI

// Dueño: agente "stats-ui". Tira del turno, tiles planos y comparación "este turno vs anterior".
// Las reglas puras viven en `StatsCopy` (nonisolated, testeables); las vistas solo las pintan.

/// Sentido de un cambio entre turnos.
nonisolated enum StatsTrend: Sendable, Equatable {
    case better, same, worse, unknown

    /// La flecha muestra hacia dónde se movió el valor; el color (en la vista) dice si eso es bueno.
    func symbol(lowerIsBetter: Bool) -> String {
        switch self {
        case .better: lowerIsBetter ? "arrow.down.right" : "arrow.up.right"
        case .worse: lowerIsBetter ? "arrow.up.right" : "arrow.down.right"
        case .same: "equal"
        case .unknown: "minus"
        }
    }

    var spoken: String {
        switch self {
        case .better: "mejor que el turno anterior"
        case .worse: "peor que el turno anterior"
        case .same: "igual que el turno anterior"
        case .unknown: "sin turno anterior para comparar"
        }
    }
}

/// Estado visual de una casilla de la tira del turno.
nonisolated enum TurnoDayState: Sendable, Equatable {
    case pause, casco, today, missed, future

    var symbol: String? {
        switch self {
        case .pause: "checkmark"
        case .casco: "shield.lefthalf.filled"
        case .today: "sun.max.fill"
        case .missed: "minus"
        case .future: nil
        }
    }

    var spoken: String {
        switch self {
        case .pause: "con pausa"
        case .casco: "comodín usado, racha a salvo"
        case .today: "hoy, sin pausa todavía"
        case .missed: "sin pausa"
        case .future: "pendiente"
        }
    }
}

/// Una línea de la comparación entre turnos (texto ya formateado).
nonisolated struct TurnoComparisonLine: Sendable, Identifiable, Equatable {
    var id: String { label }
    var label: String
    var current: String
    var previous: String
    var direction: StatsTrend
    var lowerIsBetter: Bool
}

/// Reglas y copy de la pestaña Estadísticas (sin SwiftUI, para poder testearlas).
nonisolated enum StatsCopy {
    /// Diferencias menores a esto se muestran como "igual".
    static let rdqSameTolerance: Double = 0.25
    static let percentSameTolerance: Double = 2.5
    static let placeholder = "—"

    // MARK: Turno actual

    /// Días transcurridos del turno hasta hoy (incluido); si no hay "hoy", los días del turno.
    static func daysSoFar(_ summary: StatsSummary) -> Int {
        if let today = summary.currentTurnoDays.first(where: \.isToday) { return today.dayInBlock }
        if let turno = summary.currentTurno { return turno.workDays }
        return summary.currentTurnoDays.count
    }

    static func daysWithPause(_ summary: StatsSummary) -> Int {
        if let turno = summary.currentTurno { return turno.daysWithPause }
        return summary.currentTurnoDays.filter { $0.countedPauses > 0 }.count
    }

    /// Cierres "Mejor" sobre el total de cierres registrados.
    static func closures(_ turno: TurnoSummary?) -> (better: Int, total: Int) {
        guard let turno else { return (0, 0) }
        return (turno.betterCount, turno.betterCount + turno.sameCount + turno.worseCount)
    }

    static func cellState(for day: DayStat, todayIndex: Int?) -> TurnoDayState {
        if day.countedPauses > 0 { return .pause }
        if day.cascoUsed { return .casco }
        if day.isToday { return .today }
        if let todayIndex, day.dayInBlock > todayIndex { return .future }
        return .missed
    }

    // MARK: Formato

    static func format1(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func percent(_ numerator: Int, of denominator: Int) -> Int? {
        guard denominator > 0 else { return nil }
        return Int((Double(numerator) / Double(denominator) * 100).rounded())
    }

    static func betterPercent(_ turno: TurnoSummary) -> Int? {
        let c = closures(turno)
        return percent(c.better, of: c.total)
    }

    static func adherencePercent(_ turno: TurnoSummary) -> Int? {
        percent(turno.daysWithPause, of: turno.workDays)
    }

    static func percentText(_ value: Int?) -> String {
        guard let value else { return placeholder }
        return "\(value) %"
    }

    /// "12 oct" a partir de la clave "yyyy-MM-dd" del turno; si no se puede, la etiqueta del motor.
    static func turnoDateLabel(key: String, fallback: String, calendar: Calendar = .current) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return fallback }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: Comparación

    static func direction(current: Double?, previous: Double?, lowerIsBetter: Bool, tolerance: Double) -> StatsTrend {
        guard let current, let previous else { return .unknown }
        let delta = current - previous
        if abs(delta) <= tolerance { return .same }
        let improved = lowerIsBetter ? delta < 0 : delta > 0
        return improved ? .better : .worse
    }

    static func comparisonLines(current: TurnoSummary?, previous: TurnoSummary?) -> [TurnoComparisonLine] {
        let rdq = TurnoComparisonLine(
            label: "Espalda (RDQ)",
            current: current?.meanRDQ.map(format1) ?? placeholder,
            previous: previous?.meanRDQ.map(format1) ?? placeholder,
            direction: direction(current: current?.meanRDQ, previous: previous?.meanRDQ,
                                 lowerIsBetter: true, tolerance: rdqSameTolerance),
            lowerIsBetter: true)
        let better = TurnoComparisonLine(
            label: "Después mejor",
            current: percentText(current.flatMap(betterPercent)),
            previous: percentText(previous.flatMap(betterPercent)),
            direction: direction(current: current.flatMap(betterPercent).map(Double.init),
                                 previous: previous.flatMap(betterPercent).map(Double.init),
                                 lowerIsBetter: false, tolerance: percentSameTolerance),
            lowerIsBetter: false)
        let adherence = TurnoComparisonLine(
            label: "Días con pausa",
            current: current.map { "\($0.daysWithPause) de \($0.workDays)" } ?? placeholder,
            previous: previous.map { "\($0.daysWithPause) de \($0.workDays)" } ?? placeholder,
            direction: direction(current: current.flatMap(adherencePercent).map(Double.init),
                                 previous: previous.flatMap(adherencePercent).map(Double.init),
                                 lowerIsBetter: false, tolerance: percentSameTolerance),
            lowerIsBetter: false)
        return [rdq, better, adherence]
    }

    // MARK: Lectura del coach (plantilla mientras llega la de verdad)

    static func templateSentences(_ summary: StatsSummary, name: String, isRestDay: Bool) -> [String] {
        var lines: [String] = []
        let soFar = daysSoFar(summary)
        if isRestDay && summary.currentTurno == nil {
            lines.append("\(name), está de bajada. Racha a salvo.")
        } else if soFar > 0 {
            lines.append("\(name), \(daysWithPause(summary)) de \(soFar) días con pausa este turno.")
        } else {
            lines.append("\(name), el turno recién empieza.")
        }
        if let rdq = summary.todayRDQ {
            var line = "Espalda hoy: \(rdq) de 6."
            if let prev = summary.previousTurno?.meanRDQ { line += " Turno pasado: \(format1(prev))." }
            lines.append(line)
        } else {
            lines.append("Hoy todavía no responde el cuestionario.")
        }
        let c = closures(summary.currentTurno)
        if c.total > 0 {
            lines.append("Después de la pausa: mejor \(c.better) de \(c.total) veces.")
        } else {
            lines.append("Aún sin cierres de pausa este turno.")
        }
        return lines
    }
}

// MARK: - Tira del turno

/// Una casilla por día laboral del turno (7 en 7×7; se adapta a otros rosters).
struct StatsTurnoStrip: View {
    let days: [DayStat]
    var restDay: Bool = false

    private var todayIndex: Int? { days.first(where: \.isToday)?.dayInBlock }

    var body: some View {
        Group {
            if days.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: restDay ? "bed.double.fill" : "calendar")
                        .font(.title2)
                        .foregroundStyle(Theme.sky)
                    Text(restDay ? "Bajada. Racha a salvo." : "Sin días de turno registrados.")
                        .font(.title3.weight(.semibold))
                }
            } else {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: min(7, days.count))
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(days) { day in
                        DayCell(day: day, state: StatsCopy.cellState(for: day, todayIndex: todayIndex))
                    }
                }
            }
        }
        .flatCard()
    }
}

private struct DayCell: View {
    let day: DayStat
    let state: TurnoDayState

    private var fill: Color {
        switch state {
        case .pause: Theme.mint
        case .casco: Theme.sky
        case .today: Theme.accent.opacity(0.18)
        case .missed: Color.primary.opacity(0.10)
        case .future: Color.primary.opacity(0.05)
        }
    }

    private var symbolColor: Color {
        switch state {
        case .pause, .casco: Color.white
        case .today: Theme.accent
        case .missed, .future: Color.secondary
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(day.isToday ? "Hoy" : "D\(day.dayInBlock)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(day.isToday ? Theme.accent : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Circle()
                .fill(fill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if day.isToday {
                        Circle().stroke(Theme.accent, lineWidth: 3)
                    }
                }
                .overlay {
                    if let symbol = state.symbol {
                        Image(systemName: symbol)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(symbolColor)
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Día \(day.dayInBlock)\(day.isToday ? ", hoy" : ""): \(state.spoken)")
    }
}

// MARK: - Tiles

/// Tile plano: título, cifra grande y detalle. Todo ≥ .title3.
struct StatsTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var accent: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(accent)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .flatCard()
        .accessibilityElement(children: .combine)
    }
}

/// Los 3 tiles de "Este turno": Días con pausa · Espalda hoy · Después duele menos.
struct TurnoTiles: View {
    let summary: StatsSummary
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let pair = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        let closures = StatsCopy.closures(summary.currentTurno)
        let soFar = StatsCopy.daysSoFar(summary)
        let withPause = StatsCopy.daysWithPause(summary)
        VStack(spacing: 12) {
            pair {
                StatsTile(title: "Días con pausa",
                         value: soFar > 0 ? "\(withPause) de \(soFar)" : StatsCopy.placeholder,
                         detail: soFar > 0 ? "este turno" : "sin turno activo",
                         accent: soFar > 0 && withPause == soFar ? Theme.mint : .primary)
                StatsTile(title: "Después duele menos",
                         value: closures.total > 0 ? "\(closures.better) de \(closures.total)" : StatsCopy.placeholder,
                         detail: closures.total > 0 ? "pausas con cierre" : "sin cierres aún",
                         accent: closures.total > 0 ? Theme.mint : .primary)
            }
            .fixedSize(horizontal: false, vertical: true)
            StatsTile(title: "Espalda hoy (RDQ)",
                     value: summary.todayRDQ.map { "\($0) de 6" } ?? StatsCopy.placeholder,
                     detail: rdqDetail,
                     accent: summary.todayRDQ.map(Theme.rdqColor) ?? .primary)
        }
    }

    private var rdqDetail: String {
        guard summary.todayRDQ != nil else { return "Sin cuestionario hoy" }
        if let prev = summary.previousTurno?.meanRDQ { return "Turno pasado: \(StatsCopy.format1(prev))" }
        if let mean = summary.currentTurno?.meanRDQ { return "Promedio del turno: \(StatsCopy.format1(mean))" }
        return "Menos es mejor"
    }
}

// MARK: - Comparación entre turnos

struct TurnoComparisonCard: View {
    let current: TurnoSummary?
    let previous: TurnoSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Este turno vs anterior")
                .font(.title3.weight(.bold))
            if current == nil && previous == nil {
                Text("Todavía no hay dos turnos para comparar.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(StatsCopy.comparisonLines(current: current, previous: previous)) { line in
                    ComparisonRow(line: line)
                }
            }
        }
        .flatCard()
    }
}

private struct ComparisonRow: View {
    let line: TurnoComparisonLine

    private var arrowColor: Color {
        switch line.direction {
        case .better: Theme.mint
        case .worse: Theme.danger
        case .same, .unknown: Color.secondary
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(line.label).font(.title3)
                Spacer(minLength: 8)
                values
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(line.label).font(.title3)
                values
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.label): \(line.current) este turno, \(line.previous) el anterior, \(line.direction.spoken)")
    }

    private var values: some View {
        HStack(spacing: 8) {
            Text(line.current).font(.title3.weight(.bold))
            Image(systemName: line.direction.symbol(lowerIsBetter: line.lowerIsBetter))
                .font(.title3.weight(.bold))
                .foregroundStyle(arrowColor)
            Text(line.previous).font(.title3).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}
