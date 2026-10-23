import SwiftUI
import Charts

// Dueño: agente "stats-ui". Gráficos Swift Charts planos (sin vidrio) de la pestaña Estadísticas.

/// Métrica por turno del dashboard histórico.
nonisolated enum TurnoMetric: String, CaseIterable, Identifiable, Sendable {
    case rdq, better, adherence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rdq: "Espalda (RDQ promedio)"
        case .better: "Después mejor"
        case .adherence: "Días con pausa"
        }
    }

    var subtitle: String {
        switch self {
        case .rdq: "0 a 6 · menos es mejor"
        case .better: "% de pausas con cierre \"Mejor\""
        case .adherence: "% de días del turno con pausa"
        }
    }

    var upperBound: Double {
        switch self {
        case .rdq: Double(RDQ6.maxScore)
        case .better, .adherence: 100
        }
    }

    func value(_ turno: TurnoSummary) -> Double? {
        switch self {
        case .rdq: turno.meanRDQ
        case .better: StatsCopy.betterPercent(turno).map(Double.init)
        case .adherence: StatsCopy.adherencePercent(turno).map(Double.init)
        }
    }

    func label(_ value: Double) -> String {
        switch self {
        case .rdq: StatsCopy.format1(value)
        case .better, .adherence: "\(Int(value.rounded())) %"
        }
    }
}

/// Punto del gráfico Mejor/Igual/Peor.
nonisolated struct PostPoint: Identifiable, Sendable, Hashable {
    var id: UUID
    var date: Date
    var post: PostResponse

    static func points(from digests: [SessionDigest]) -> [PostPoint] {
        digests.compactMap { d in d.post.map { PostPoint(id: d.id, date: d.date, post: $0) } }
            .sorted { $0.date < $1.date }
    }

    /// Orden del eje Y (abajo → arriba).
    static let axisOrder: [PostResponse] = [.peor, .igual, .mejor]
}

// MARK: - RDQ por día del turno

/// Barras 0-6 por día laboral del turno; color por `Theme.rdqColor`; línea punteada con el turno pasado.
struct RDQByDayChart: View {
    let days: [DayStat]
    var previousMean: Double? = nil
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 170

    private var hasData: Bool { days.contains { $0.rdq != nil } }

    private func label(_ day: DayStat) -> String { day.isToday ? "Hoy" : "D\(day.dayInBlock)" }

    var body: some View {
        Chart {
            ForEach(days) { day in
                if let rdq = day.rdq {
                    BarMark(x: .value("Día", label(day)), y: .value("RDQ", rdq))
                        .foregroundStyle(Theme.rdqColor(rdq))
                        .cornerRadius(6)
                        .annotation(position: .top, spacing: 4) {
                            Text("\(rdq)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Día \(day.dayInBlock)")
                        .accessibilityValue("\(rdq) de 6")
                }
            }
            if let previousMean, hasData {
                RuleMark(y: .value("Turno pasado", previousMean))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Turno pasado \(StatsCopy.format1(previousMean))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: days.map(label))
        .chartYScale(domain: 0...Double(RDQ6.maxScore))
        .chartYAxis {
            AxisMarks(values: [0, 2, 4, 6]) {
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let text = value.as(String.self) {
                        Text(text)
                            .font(.caption.weight(text == "Hoy" ? .bold : .regular))
                            .foregroundStyle(text == "Hoy" ? Theme.accent : Color.secondary)
                    }
                }
            }
        }
        .frame(height: chartHeight)
        .overlay {
            if !hasData {
                Text("Sin cuestionario este turno.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Mejor / Igual / Peor por sesión

/// Un punto por pausa cerrada: fecha en X, Mejor/Igual/Peor en Y.
struct PostResponseChart: View {
    let digests: [SessionDigest]
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 150
    @ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 180
    /// Margen en el eje X para que los puntos de los extremos no se corten.
    @ScaledMetric(relativeTo: .body) private var pointPadding: CGFloat = 22

    private var points: [PostPoint] { PostPoint.points(from: digests) }

    var body: some View {
        let points = points
        Chart(points) { point in
            PointMark(x: .value("Fecha", point.date), y: .value("Después", point.post.title))
                .foregroundStyle(by: .value("Después", point.post.title))
                .symbolSize(symbolSize)
                .accessibilityLabel(point.date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                .accessibilityValue(point.post.title)
        }
        .chartYScale(domain: PostPoint.axisOrder.map(\.title))
        .chartForegroundStyleScale([
            PostResponse.mejor.title: Theme.mint,
            PostResponse.igual.title: Theme.gold,
            PostResponse.peor.title: Theme.danger,
        ])
        .chartLegend(.hidden)
        .chartXScale(range: .plotDimension(startPadding: pointPadding, endPadding: pointPadding))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let text = value.as(String.self) {
                        Text(text).font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .frame(height: chartHeight)
        .overlay {
            if points.isEmpty {
                Text("Sin pausas cerradas este turno.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Barras por turno

/// Una barra por turno 7×7 para una métrica; el turno actual en cobre, el resto en gris.
struct TurnoBarsChart: View {
    let turnos: [TurnoSummary]
    let metric: TurnoMetric
    var currentKey: String? = nil
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 130

    private var sorted: [TurnoSummary] { turnos.sorted { $0.turnoKey < $1.turnoKey } }

    private func xLabel(_ turno: TurnoSummary) -> String {
        StatsCopy.turnoDateLabel(key: turno.turnoKey, fallback: turno.label)
    }

    private var hasData: Bool { turnos.contains { metric.value($0) != nil } }

    var body: some View {
        let sorted = sorted
        Chart(sorted) { turno in
            if let value = metric.value(turno) {
                BarMark(x: .value("Turno", xLabel(turno)), y: .value(metric.title, value))
                    .foregroundStyle(turno.turnoKey == currentKey ? Theme.accent : Color.secondary.opacity(0.45))
                    .cornerRadius(6)
                    .annotation(position: .top, spacing: 4) {
                        Text(metric.label(value))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(turno.label)
                    .accessibilityValue(metric.label(value))
            }
        }
        .chartXScale(domain: sorted.map(xLabel))
        .chartYScale(domain: 0...metric.upperBound)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let text = value.as(String.self) {
                        Text(text).font(.caption)
                    }
                }
            }
        }
        .frame(height: chartHeight)
        .overlay {
            if !hasData {
                Text("Sin datos.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Tarjeta con las tres métricas por turno, una debajo de otra.
struct TurnoBarsCard: View {
    let turnos: [TurnoSummary]
    var currentKey: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if turnos.isEmpty {
                Text("Todavía no hay turnos con datos.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(TurnoMetric.allCases) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric.title).font(.title3.weight(.bold))
                        Text(metric.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        TurnoBarsChart(turnos: turnos, metric: metric, currentKey: currentKey)
                    }
                }
            }
        }
        .flatCard()
    }
}
