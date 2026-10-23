import SwiftUI

// Piezas chicas de Hoy: encabezado, "Me duele ahora", fichas de recompensa, botón de texto,
// título de tarjeta, ruta de íconos y la explicación del comodín. Tarjetas planas; vidrio solo en controles.

/// Encabezado: "Día 2 de 7" con "Me duele ahora" a la derecha y, en su propia línea a todo el ancho,
/// "Viernes 23 · Buen turno, Marco" (así nunca se parte al lado del botón). Con letra grande el botón
/// baja bajo el título.
struct HoyHeader: View {
    let title: String
    let subtitle: String
    let onPain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    titleText
                        .fixedSize()
                    Spacer(minLength: 0)
                    PainNowButton(fill: false, action: onPain)
                }
                VStack(alignment: .leading, spacing: 10) {
                    titleText
                        .fixedSize(horizontal: false, vertical: true)
                    PainNowButton(fill: true, action: onPain)
                }
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.title2.weight(.bold))
            .accessibilityAddTraits(.isHeader)
    }
}

/// "Me duele ahora": cápsula de vidrio funcional de 44 pt (degrada a opaca en modo exterior).
/// Registrar dolor nunca da XP: es un control, no una meta.
struct PainNowButton: View {
    /// `true` ocupa todo el ancho (versión apilada).
    var fill: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.heart")
                    .foregroundStyle(Theme.accent)
                Text("Me duele ahora")
                    .foregroundStyle(.primary)
                    .lineLimit(fill ? nil : 1)
                    .fixedSize(horizontal: !fill, vertical: fill)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: fill ? .infinity : nil, minHeight: Theme.rowHeight)
            .contentShape(.capsule)
        }
        .buttonStyle(GlassCapsuleStyle())
        .accessibilityHint("Anota dónde le duele, en un toque")
    }
}

private struct GlassCapsuleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .functionalGlass(in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Ficha plana de "Gana hoy" / "Ganó hoy" (dato, no control: sin vidrio).
/// El cobre es solo de la llama; la estrella del XP queda en oro, chica.
struct RewardTag: View {
    let chip: RewardChip
    @Environment(\.outdoorMode) private var outdoor

    var body: some View {
        Label {
            Text(chip.text)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
        } icon: {
            Image(systemName: chip.symbol)
                .foregroundStyle(color)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(Theme.quietFill, in: .capsule)
        .overlay {
            if outdoor { Capsule().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1) }
        }
    }

    private var color: Color {
        switch chip.tone {
        case .flame: Theme.copper
        case .xp: Theme.gold
        case .milestone, .badgeEarned: Theme.accent
        case .badgePending: .secondary
        }
    }
}

/// Botón de texto bajo la acción principal: "Solo tengo 1 minuto · hasta +68 XP" (44 pt, sin cápsula).
struct QuickTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "timer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Pausa rápida de un minuto: movilidad cervical y pestañeo")
    }
}

/// Título de tarjeta (headline) con un dato a la derecha.
struct HoyCardTitle: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// Los ejercicios de la ruta como íconos en fila, en el orden fijo, unidos por chevrons.
struct RouteIcons: View {
    let kinds: [ActivityKind]
    var size: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: size, height: size)
                    .background(Theme.quietFill, in: .circle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Popover "La ruta de hoy": nombres y metas iguales a los de la pausa.
struct RoutePopover: View {
    let route: [ActivityAssignment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("La ruta de hoy")
                .font(.headline)
            ForEach(Array(route.enumerated()), id: \.offset) { index, item in
                Label {
                    Text("\(index + 1). \(item.kind.name) · \(item.target) \(item.kind.unit)")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: item.kind.symbol)
                        .foregroundStyle(Theme.accent)
                }
                .font(.subheadline)
            }
            Text("Siempre en este orden. Si hoy le duele, el plan se ajusta al inicio.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}

/// Explicación breve del comodín (popover del camino del turno).
struct ComodinInfo: View {
    let available: Int

    static let symbol = "shield.lefthalf.filled"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(CelebrationCopy.comodinName, systemImage: Self.symbol)
                .font(.headline)
                .foregroundStyle(Theme.accent)
            Text(CelebrationCopy.comodinExplanation)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text(CelebrationCopy.comodinStatus(available: available))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Columnas

/// Columnas de igual ancho (momentos de hoy, camino del turno): el ancho de cada columna nunca depende
/// de su contenido, así los segmentos de `ColumnConnectors` quedan siempre entre los nodos.
/// Su ancho ideal es el número de columnas por la columna más ancha, de modo que `ViewThatFits` pasa a
/// la lista cuando una etiqueta ya no cabe en su columna (letra grande o pantalla angosta).
struct EqualColumns: Layout {
    /// Escala mínima del texto de las etiquetas (su `minimumScaleFactor`, con margen): la fila se acepta
    /// si la etiqueta más ancha cabe encogida hasta este factor.
    var minimumScale: CGFloat = 1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            width = EqualColumnsMetrics.idealWidth(columnWidths: subviews.map { $0.sizeThatFits(.unspecified).width },
                                                   minimumScale: minimumScale)
        }
        let column = width / CGFloat(subviews.count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let column = bounds.width / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + column * CGFloat(index), y: bounds.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: column, height: bounds.height))
        }
    }
}

/// Cuentas de `EqualColumns` (puras; testeables).
nonisolated enum EqualColumnsMetrics {
    /// Ancho en que cabe cada columna: columnas × la más ancha × la escala mínima del texto.
    static func idealWidth(columnWidths: [CGFloat], minimumScale: CGFloat = 1) -> CGFloat {
        CGFloat(columnWidths.count) * (columnWidths.max() ?? 0) * min(1, max(0, minimumScale))
    }
}

/// Etiquetas de hito ("Partió", "Doblete", "Tiro limpio") bajo su columna, sin cambiar el ancho de las
/// columnas: la de la primera se alinea a la izquierda, la de la última a la derecha y el resto al centro.
/// Su ancho ideal es el mínimo en que ninguna se pisa ni se sale, así `ViewThatFits` pasa a la línea de
/// texto cuando no caben. Marque cada etiqueta con `.milestoneColumn(_:)`.
struct MilestoneLabels: Layout {
    let columns: Int
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = sizes.map(\.height).max() ?? 0
        if let proposed = proposal.width, proposed.isFinite {
            return CGSize(width: proposed, height: height)
        }
        let labels = zip(subviews, sizes).map { MilestoneRowMetrics.Item(column: $0[MilestoneColumnKey.self], width: $1.width) }
        return CGSize(width: MilestoneRowMetrics.minimumWidth(labels, columns: columns, spacing: spacing), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let label = MilestoneRowMetrics.Item(column: subview[MilestoneColumnKey.self], width: size.width)
            let x = MilestoneRowMetrics.leading(label, columns: columns, total: bounds.width)
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
        }
    }
}

private nonisolated struct MilestoneColumnKey: LayoutValueKey {
    static let defaultValue = 0
}

extension View {
    /// Columna (0…) bajo la que va esta etiqueta de `MilestoneLabels`.
    func milestoneColumn(_ column: Int) -> some View {
        layoutValue(key: MilestoneColumnKey.self, value: column)
    }
}

/// Posición de las etiquetas de hito bajo columnas iguales (puro; testeable).
/// El borde izquierdo de cada etiqueta es lineal en el ancho total `W`: `a · W + b`.
nonisolated enum MilestoneRowMetrics {
    struct Item: Sendable, Equatable {
        var column: Int
        var width: CGFloat
    }

    /// Borde izquierdo de la etiqueta con ancho total `total`.
    static func leading(_ label: Item, columns: Int, total: CGFloat) -> CGFloat {
        let (a, b) = coefficients(label, columns: columns)
        return a * total + b
    }

    /// Ancho total mínimo en que las etiquetas no se salen ni se pisan (con `spacing` entre vecinas).
    static func minimumWidth(_ labels: [Item], columns: Int, spacing: CGFloat) -> CGFloat {
        let sorted = labels.sorted { $0.column < $1.column }
        var minimum: CGFloat = 0
        for label in sorted {
            let (a, b) = coefficients(label, columns: columns)
            // Borde izquierdo ≥ 0.
            if a > 0 { minimum = max(minimum, -b / a) }
            // Borde derecho ≤ W: a · W + b + ancho ≤ W.
            if a < 1 { minimum = max(minimum, (b + label.width) / (1 - a)) }
        }
        for (left, right) in zip(sorted, sorted.dropFirst()) {
            let (a1, b1) = coefficients(left, columns: columns)
            let (a2, b2) = coefficients(right, columns: columns)
            // Borde derecho de la izquierda + aire ≤ borde izquierdo de la derecha. Columnas distintas: a2 > a1.
            guard a2 > a1 else { continue }
            minimum = max(minimum, (b1 + left.width + spacing - b2) / (a2 - a1))
        }
        return minimum
    }

    private static func coefficients(_ label: Item, columns: Int) -> (a: CGFloat, b: CGFloat) {
        if label.column <= 0 { return (0, 0) }
        if label.column >= columns - 1 { return (1, -label.width) }
        return ((CGFloat(label.column) + 0.5) / CGFloat(columns), -label.width / 2)
    }
}
