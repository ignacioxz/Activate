import SwiftUI

// Dueño: agente "design-system" (puede ampliar este archivo). Los demás agentes lo usan, no lo editan.

/// Tokens planos. Liquid Glass solo en la capa funcional (CTA, HUD, chip de racha, badge de celebración).
enum Theme {
    static let copper = Color(red: 0.95, green: 0.55, blue: 0.25)
    static let copperDeep = Color(red: 0.80, green: 0.40, blue: 0.16)
    static let mint = Color(red: 0.45, green: 0.88, blue: 0.60)
    static let sky = Color(red: 0.35, green: 0.65, blue: 1.0)
    static let gold = Color(red: 1.0, green: 0.80, blue: 0.25)
    static let night = Color(red: 0.07, green: 0.13, blue: 0.23)
    static let danger = Color.red

    static func rdqColor(_ score: Int) -> Color {
        switch score {
        case ...1: mint
        case 2...3: Color.yellow
        case 4: copper
        default: danger
        }
    }

    /// Alturas mínimas de toque (guantes, sol, 52 años).
    static let ctaHeight: CGFloat = 64
    static let rowHeight: CGFloat = 64
    static let cardRadius: CGFloat = 22
}

/// Modo exterior: superficies opacas, controles grandes, apariencia clara.
struct OutdoorModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var outdoorMode: Bool {
        get { self[OutdoorModeKey.self] }
        set { self[OutdoorModeKey.self] = newValue }
    }
}

extension View {
    /// Tarjeta plana de contenido (nunca vidrio).
    func flatCard(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Theme.cardRadius))
    }

    /// Vidrio solo para controles/HUD. Degrada a superficie opaca en modo exterior o Reduce Transparency.
    func functionalGlass(tint: Color? = nil, cornerRadius: CGFloat = 22) -> some View {
        modifier(FunctionalGlass(tint: tint, cornerRadius: cornerRadius))
    }

    func appScreen() -> some View {
        self.background(Color(.systemBackground).ignoresSafeArea())
    }
}

private struct FunctionalGlass: ViewModifier {
    let tint: Color?
    let cornerRadius: CGFloat
    @Environment(\.outdoorMode) private var outdoor
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if outdoor || reduceTransparency || contrast == .increased {
            content
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.primary.opacity(0.25), lineWidth: 1.5))
        } else {
            content.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

/// Botón principal: una acción por pantalla, 64 pt, vidrio prominente con tinte de marca.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = Theme.copper
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .font(.title3.weight(.heavy))
            .frame(maxWidth: .infinity, minHeight: Theme.ctaHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.roundedRectangle(radius: Theme.cardRadius))
        .tint(tint)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Botón secundario grande.
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: Theme.cardRadius))
    }
}

/// Fila SÍ / NO del cuestionario (texto grande, dos botones de 64 pt).
struct YesNoRow: View {
    let text: String
    @Binding var answer: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                choice("SÍ", value: true, tint: Theme.copper)
                choice("NO", value: false, tint: Theme.sky)
            }
        }
        .flatCard()
    }

    private func choice(_ label: String, value: Bool, tint: Color) -> some View {
        Button {
            answer = value
        } label: {
            Text(label)
                .font(.title2.weight(.heavy))
                .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.bordered)
        .tint(answer == value ? tint : .gray)
        .accessibilityLabel("\(label): \(text)")
        .accessibilityAddTraits(answer == value ? .isSelected : [])
    }
}

/// Anillo de progreso plano.
struct ProgressRing: View {
    let progress: Double
    var color: Color = Theme.copper
    var lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.5), value: progress)
        }
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.bold))
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Ampliaciones del paquete "design-celebration" (solo se agrega; lo anterior no cambia).

extension Theme {
    /// Colores del confeti (cobre / menta / blanco). En apariencia clara el blanco se cambia por `night`.
    static let confettiColors: [Color] = [copper, mint, .white]
    static let confettiColorsLight: [Color] = [copper, mint, night]
    /// Radio de los tiles de estadísticas (más chico que la tarjeta).
    static let tileRadius: CGFloat = 16
    /// Altura mínima del chip de racha (capa de vidrio).
    static let chipHeight: CGFloat = 44
}

extension View {
    /// Vidrio funcional con forma arbitraria (círculo del símbolo de celebración, cápsula del chip).
    /// Degrada igual que `functionalGlass(tint:cornerRadius:)` en modo exterior / Reduce Transparency.
    func functionalGlass<S: Shape>(tint: Color? = nil, in shape: S) -> some View {
        modifier(FunctionalGlassShape(tint: tint, shape: shape))
    }
}

private struct FunctionalGlassShape<S: Shape>: ViewModifier {
    let tint: Color?
    let shape: S
    @Environment(\.outdoorMode) private var outdoor
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if outdoor || reduceTransparency || contrast == .increased {
            content
                .background(Color(.secondarySystemBackground), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.25), lineWidth: 1.5))
        } else {
            content.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: shape)
        }
    }
}

/// Tile plano de estadística: título chico, valor grande (dígitos monoespaciados, transición numérica), nota opcional.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var tint: Color = .primary
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(tint == .primary ? Theme.copper : tint)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(value)
                .font(.title.weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Theme.tileRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)\(caption.map { ". \($0)" } ?? "")")
    }
}

/// Chip de racha (capa de vidrio). `safe == true` muestra "Racha a salvo" (bajada o casco), nunca "racha rota".
struct StreakChip: View {
    let streak: Int
    var safe: Bool = false

    private var text: String {
        if safe { return "Racha a salvo" }
        switch streak {
        case ...0: return "Racha: parte hoy"
        case 1: return "Racha: 1 día"
        default: return "Racha: \(streak) días"
        }
    }

    private var symbol: String { safe ? "shield.fill" : "flame.fill" }
    private var color: Color { safe ? Theme.sky : (streak > 0 ? Theme.copper : .secondary) }

    var body: some View {
        Label {
            Text(text)
                .font(.headline)
                .monospacedDigit()
                .contentTransition(.numericText())
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Theme.chipHeight)
        .functionalGlass(tint: color, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(safe ? "Racha a salvo" : "Racha de \(max(0, streak)) días")
    }
}
