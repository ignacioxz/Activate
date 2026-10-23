import SwiftUI

// Dueño: paquete "zones-session". Chips de selección compactos (~40 pt) con el acento azul del
// design system. Los usan el check-in, "Me duele ahora", el alta y Perfil.

// MARK: - Lógica pura

/// Reglas de la selección múltiple (testeables sin vista).
nonisolated enum ChipSelection {
    /// Activa o desactiva `item`. Nunca deja menos de `minimum` marcados y conserva el orden de `items`.
    static func toggled<Item: Hashable>(_ item: Item, in selection: [Item], items: [Item], minimum: Int = 1) -> [Item] {
        var set = Set(selection)
        if set.contains(item) {
            guard set.count > minimum else { return items.filter { set.contains($0) } }
            set.remove(item)
        } else {
            set.insert(item)
        }
        return items.filter { set.contains($0) }
    }

    /// `true` si tocar `item` no cambia nada (es el último marcado).
    static func isLocked<Item: Hashable>(_ item: Item, in selection: [Item], minimum: Int = 1) -> Bool {
        let set = Set(selection)
        return set.contains(item) && set.count <= minimum
    }
}

// MARK: - Chip

/// Chip de selección. Marcado: fondo de acento sólido. Sin marcar: relleno gris suave.
/// `multiple` agrega el círculo / visto que anuncia "puede marcar varias".
struct SelectionChip: View {
    let title: String
    let isSelected: Bool
    var multiple: Bool = false
    var systemImage: String? = nil
    var fillsWidth: Bool = false
    let action: () -> Void

    @Environment(\.outdoorMode) private var outdoor
    @Environment(\.colorSchemeContrast) private var contrast
    /// Alto mínimo del chip (crece con Dynamic Type).
    @ScaledMetric(relativeTo: .subheadline) private var minHeight: CGFloat = 40

    private var strongBorders: Bool { outdoor || contrast == .increased }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if multiple {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color(.systemBackground) : Color.secondary)
                        .accessibilityHidden(true)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: minHeight)
            .background(Capsule().fill(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(.tertiarySystemFill))))
            .overlay(
                Capsule().strokeBorder(isSelected ? Color.clear : Color.primary.opacity(strongBorders ? 0.35 : 0.08),
                                       lineWidth: strongBorders ? 1.5 : 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Selección múltiple

/// Chips que se activan y desactivan. Mínimo `minimum` marcados: tocar el último no lo desmarca.
struct MultiSelectChips<Item: Identifiable & Hashable>: View {
    let items: [Item]
    @Binding var selection: [Item]
    let title: (Item) -> String
    var minimum: Int = 1

    @State private var lockedTick = 0

    var body: some View {
        ChipFlowLayout {
            ForEach(items) { item in
                let on = selection.contains(item)
                SelectionChip(title: title(item), isSelected: on, multiple: true) { toggle(item) }
                    .accessibilityHint(ChipSelection.isLocked(item, in: selection, minimum: minimum)
                                       ? "Debe quedar al menos una marcada."
                                       : "Puede marcar más de una.")
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.warning, trigger: lockedTick)
    }

    private func toggle(_ item: Item) {
        if ChipSelection.isLocked(item, in: selection, minimum: minimum) {
            lockedTick += 1
            return
        }
        selection = ChipSelection.toggled(item, in: selection, items: items, minimum: minimum)
    }
}

// MARK: - Selección única

/// Fila de chips de selección única (momento). Se envuelve en varias líneas si no cabe.
struct SessionChipRow<Item: Identifiable & Hashable>: View {
    let items: [Item]
    let selected: Item
    let title: (Item) -> String
    let onSelect: (Item) -> Void

    var body: some View {
        ChipFlowLayout {
            ForEach(items) { item in
                SelectionChip(title: title(item), isSelected: item == selected) { onSelect(item) }
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

// MARK: - Distribución en líneas

/// Coloca los chips de izquierda a derecha y salta de línea cuando no caben.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let widest = rows.map(\.width).max() ?? 0
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? widest
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > maxWidth {
                // Texto grande (Dynamic Type): el chip ocupa la línea y crece hacia abajo.
                size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.indices.append(index)
            current.sizes.append(size)
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Aviso de sesión simulada

/// Banner discreto para el simulador: la sesión no usa sensores reales y no suma.
struct SimulatedNotice: View {
    var body: some View {
        Label("Simulado (sin sensores reales)", systemImage: "testtube.2")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

#Preview("Chips") {
    @Previewable @State var zones: [PainZone] = [.lumbar, .cuello]
    @Previewable @State var moment: Moment = .colacion
    VStack(alignment: .leading, spacing: 16) {
        SectionTitle(title: "¿Dónde le duele?", subtitle: "Marque una o más zonas.")
        MultiSelectChips(items: PainZone.allCases, selection: $zones, title: { $0.title })
        SectionTitle(title: "Momento")
        SessionChipRow(items: Moment.allCases, selected: moment, title: { $0.title }) { moment = $0 }
        SimulatedNotice()
    }
    .padding()
}
