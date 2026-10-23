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
