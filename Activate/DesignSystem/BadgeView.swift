import SwiftUI

// Dueño: agente "design-celebration".
// Insignia de faena: hexágono de color + símbolo SF. Variante de vidrio (solo capa funcional,
// patrón Landmarks con `GlassEffectContainer` + `glassEffectID` para el morphing) y variante plana
// (listas, Perfil, tarjeta para la familia: `ImageRenderer` no rasteriza materiales).

/// Hexágono con punta arriba (forma de la insignia de faena).
nonisolated struct Hexagon: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX, cy = rect.midY
        let r = min(w, h) / 2
        var p = Path()
        for i in 0..<6 {
            let angle = Double(i) * .pi / 3 - .pi / 2
            let point = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }
}

extension Badge {
    /// Color de marca de cada insignia (tokens de `Theme`, aislados al MainActor).
    /// El cobre queda solo para Doblete (la llama de la racha); el resto usa la paleta fría.
    @MainActor var color: Color {
        switch self {
        case .primeraPausa: Theme.accent
        case .doblete: Theme.copper
        case .relevoCumplido: Theme.sky
        case .rajoCompleto: Theme.mint
        case .tiroLimpio: Theme.gold
        case .caminanteDelRajo: Theme.mint
        }
    }
}

/// Insignia de faena.
///
/// - `style: .glass` la envuelve en `functionalGlass` (degrada a superficie opaca en modo exterior /
///   Reduce Transparency). Pásele el `namespace` de la pantalla y colóquela dentro de un
///   `GlassEffectContainer` para que la insignia morfee desde / hacia otros elementos de vidrio
///   (p. ej. el HUD de la actividad → la celebración).
/// - `style: .flat` es un hexágono plano (listas, Perfil, tarjeta exportable).
struct BadgeView: View {
    enum Style { case glass, flat }

    let badge: Badge
    var style: Style = .glass
    var size: CGFloat = 76
    var showsTitle: Bool = true
    var earned: Bool = true
    var namespace: Namespace.ID? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch style {
        case .glass:
            content
                .padding(14)
                .functionalGlass(tint: badge.color, cornerRadius: Theme.cardRadius)
                .modifier(OptionalGlassID(id: badge.id, namespace: namespace))
                .glassEffectTransition(reduceMotion ? .materialize : .matchedGeometry)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
        case .flat:
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var content: some View {
        VStack(spacing: 8) {
            hexagon
            if showsTitle {
                Text(badge.title)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: max(size, 92))
                    .foregroundStyle(earned ? .primary : .secondary)
            }
        }
    }

    private var hexagon: some View {
        ZStack {
            Hexagon()
                .fill(earned ? badge.color : Color.gray.opacity(0.35))
            Hexagon()
                .scale(0.84)
                .stroke(Color.white.opacity(earned ? 0.55 : 0.25), lineWidth: max(1.5, size * 0.03))
            Image(systemName: badge.symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .opacity(earned ? 1 : 0.7)
        }
        .frame(width: size, height: size)
        // Los tonos claros de la paleta (más saturados) dan contraste al símbolo blanco también en oscuro.
        .environment(\.colorScheme, .light)
    }

    private var accessibilityText: String {
        earned ? "Insignia \(badge.title). \(badge.detail)" : "Insignia pendiente: \(badge.title)"
    }
}

/// Aplica `glassEffectID` solo si hay namespace (sin él, la insignia no participa del morphing).
private struct OptionalGlassID: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

/// Fila de insignias planas (Perfil): las no ganadas se ven en gris.
struct BadgeGrid: View {
    let earned: Set<Badge>
    var size: CGFloat = 64

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Badge.allCases) { badge in
                BadgeView(badge: badge, style: .flat, size: size, earned: earned.contains(badge))
            }
        }
    }
}

#Preview("Insignias") {
    @Previewable @Namespace var ns
    VStack(spacing: 24) {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                BadgeView(badge: .doblete, namespace: ns)
                BadgeView(badge: .tiroLimpio, namespace: ns)
            }
        }
        BadgeGrid(earned: [.primeraPausa, .doblete])
            .flatCard()
    }
    .padding()
    .appScreen()
}
