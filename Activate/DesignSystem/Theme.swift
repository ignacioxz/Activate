import SwiftUI
import UIKit

// Dueño: agente "design-system" (puede ampliar este archivo). Los demás agentes lo usan, no lo editan.
//
// Lenguaje visual: plano y sobrio (como Salud / Fitness) + Liquid Glass solo en controles y HUD.
// - Un solo acento interactivo: `Theme.accent` (azul). Botones, selección, anillos y tint global.
// - `Theme.copper` queda SOLO para la llama de la racha (y la insignia Doblete). Nunca en controles.
// - Colores de estado con variantes claro / oscuro legibles como texto (contraste ≥ 4,5:1 sobre el
//   fondo del sistema en claro): `successText`, `warningText`, `dangerText`. `mint`, `gold` y `sky`
//   también se oscurecen en modo claro para que sirvan como texto.
// - Tamaños nativos: CTA 50 pt, filas y botones secundarios 44 pt, sin `.heavy` salvo el contador.

// MARK: - Paleta (valores puros, testeables sin UIKit)

/// Color sRGB en componentes 0-1 con la luminancia y el contraste WCAG 2.x.
nonisolated struct ThemeRGB: Sendable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Luminancia relativa (WCAG 2.x).
    var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Razón de contraste WCAG entre dos colores (1-21).
    static func contrast(_ a: ThemeRGB, _ b: ThemeRGB) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

    // Fondos del sistema (iOS) para verificar contraste.
    static let white = ThemeRGB(1, 1, 1)
    static let black = ThemeRGB(0, 0, 0)
    /// `secondarySystemBackground` claro (#F2F2F7).
    static let cardLight = ThemeRGB(0.949, 0.949, 0.969)
    /// `secondarySystemBackground` oscuro (#1C1C1E).
    static let cardDark = ThemeRGB(0.110, 0.110, 0.118)
}

/// Par claro / oscuro (con variantes opcionales de alto contraste) que se vuelve un `UIColor` dinámico.
nonisolated struct ThemeDynamicRGB: Sendable, Equatable {
    var light: ThemeRGB
    var dark: ThemeRGB
    var lightHighContrast: ThemeRGB? = nil
    var darkHighContrast: ThemeRGB? = nil

    /// `UIColor` que resuelve según el estilo y el contraste del entorno. El closure se crea fuera del
    /// MainActor a propósito: UIKit / Charts / ImageRenderer pueden resolverlo en cualquier hilo.
    var uiColor: UIColor {
        let spec = self
        return UIColor { traits in
            let high = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark {
                return ((high ? spec.darkHighContrast : nil) ?? spec.dark).uiColor
            }
            return ((high ? spec.lightHighContrast : nil) ?? spec.light).uiColor
        }
    }

    var color: Color { Color(uiColor: uiColor) }
}

/// Valores de la paleta. `Theme` los expone como `Color`.
nonisolated enum ThemePalette {
    /// Azul del cielo del rajo: acento de interacción.
    static let accent = ThemeDynamicRGB(light: ThemeRGB(0.13, 0.38, 0.84),
                                        dark: ThemeRGB(0.25, 0.56, 1.00),
                                        lightHighContrast: ThemeRGB(0.05, 0.28, 0.70))
    /// Verde de "logrado" legible como texto.
    static let successText = ThemeDynamicRGB(light: ThemeRGB(0.10, 0.50, 0.25),
                                             dark: ThemeRGB(0.45, 0.88, 0.60))
    /// Ámbar de aviso legible como texto (nunca amarillo puro).
    static let warningText = ThemeDynamicRGB(light: ThemeRGB(0.70, 0.36, 0.00),
                                             dark: ThemeRGB(1.00, 0.72, 0.25))
    /// Rojo de alerta legible como texto.
    static let dangerText = ThemeDynamicRGB(light: ThemeRGB(0.80, 0.12, 0.10),
                                            dark: ThemeRGB(1.00, 0.36, 0.33))
    /// RDQ-6 = 4: entre el ámbar y el rojo.
    static let rdqHigh = ThemeDynamicRGB(light: ThemeRGB(0.80, 0.30, 0.05),
                                         dark: ThemeRGB(1.00, 0.55, 0.30))
    /// Menta (logros, "mejor"): en claro se oscurece para servir como texto.
    static let mint = ThemeDynamicRGB(light: ThemeRGB(0.12, 0.53, 0.27),
                                      dark: ThemeRGB(0.45, 0.88, 0.60))
    /// Cielo (casco, plan reducido): en claro se oscurece para servir como texto.
    static let sky = ThemeDynamicRGB(light: ThemeRGB(0.05, 0.45, 0.75),
                                     dark: ThemeRGB(0.35, 0.65, 1.00))
    /// Oro (XP, "igual"): en claro es ocre para servir como texto.
    static let gold = ThemeDynamicRGB(light: ThemeRGB(0.64, 0.41, 0.00),
                                      dark: ThemeRGB(1.00, 0.80, 0.25))

    /// Color del puntaje RDQ-6 (0-6): verde ≤ 1, ámbar 2-3, naranja 4, rojo ≥ 5. Nunca amarillo puro.
    static func rdq(_ score: Int) -> ThemeDynamicRGB {
        switch score {
        case ...1: successText
        case 2...3: warningText
        case 4: rdqHigh
        default: dangerText
        }
    }

    /// Colores que se usan como texto y deben cumplir 4,5:1 en claro y oscuro (lo verifican los tests).
    static let textColors: [(name: String, value: ThemeDynamicRGB)] = [
        ("accent", accent), ("successText", successText), ("warningText", warningText),
        ("dangerText", dangerText), ("rdqHigh", rdqHigh), ("mint", mint), ("sky", sky), ("gold", gold),
    ]
}

// MARK: - Tokens

/// Tokens planos. Liquid Glass solo en la capa funcional (CTA, HUD, chip de racha, badge de celebración).
enum Theme {
    /// Acento de interacción (botones, selección, anillos de progreso, tint global).
    static let accent = ThemePalette.accent.color
    /// Cobre: SOLO la llama de la racha. Nunca en botones, selección ni anillos.
    static let copper = Color(red: 0.95, green: 0.55, blue: 0.25)
    static let copperDeep = Color(red: 0.80, green: 0.40, blue: 0.16)
    static let mint = ThemePalette.mint.color
    static let sky = ThemePalette.sky.color
    static let gold = ThemePalette.gold.color
    static let night = Color(red: 0.07, green: 0.13, blue: 0.23)
    /// Rojo del sistema para rellenos y tint (botón de alarma). Para texto use `dangerText`.
    static let danger = Color.red

    /// Texto de estado "logrado" (verde legible en claro y oscuro).
    static let successText = ThemePalette.successText.color
    /// Texto de aviso (ámbar legible en claro y oscuro).
    static let warningText = ThemePalette.warningText.color
    /// Texto de alerta (rojo legible en claro y oscuro).
    static let dangerText = ThemePalette.dangerText.color

    /// Relleno suave de controles no seleccionados (píldoras Sí/No, chips).
    static let quietFill = Color(.tertiarySystemFill)

    /// Color del puntaje RDQ-6 (0-6): verde ≤ 1, ámbar 2-3, naranja 4, rojo ≥ 5. Legible como texto.
    static func rdqColor(_ score: Int) -> Color {
        ThemePalette.rdq(score).color
    }

    /// Etiqueta de botón en minúscula inicial: "EMPEZAR" → "Empezar". Solo toca títulos escritos
    /// enteros en mayúsculas (con al menos 3 letras); cualquier otro título queda igual.
    nonisolated static func buttonTitle(_ title: String) -> String {
        let letters = title.filter(\.isLetter)
        guard letters.count >= 3, letters == letters.uppercased(), letters != letters.lowercased() else { return title }
        let lower = title.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    /// Alto del botón principal (iOS: botón grande de pantalla completa).
    static let ctaHeight: CGFloat = 50
    /// Alto del botón principal en Modo exterior (guantes, sol).
    static let ctaHeightOutdoor: CGFloat = 56
    /// Alto mínimo de filas y botones secundarios (mínimo de toque de la HIG).
    static let rowHeight: CGFloat = 44
    /// Radio de las tarjetas de contenido.
    static let cardRadius: CGFloat = 20
}

/// Modo exterior: superficies opacas, controles un poco más altos, apariencia clara.
struct OutdoorModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var outdoorMode: Bool {
        get { self[OutdoorModeKey.self] }
        set { self[OutdoorModeKey.self] = newValue }
    }
}

extension View {
    /// Tarjeta plana de contenido (nunca vidrio).
    func flatCard(padding: CGFloat = 16) -> some View {
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

/// `true` cuando el vidrio debe degradar a superficies opacas (Modo exterior, Reduce Transparency,
/// Increase Contrast).
private struct SolidSurfaces: DynamicProperty {
    @Environment(\.outdoorMode) private var outdoor
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var isOn: Bool { outdoor || reduceTransparency || contrast == .increased }
    var isOutdoor: Bool { outdoor }
}

private struct FunctionalGlass: ViewModifier {
    let tint: Color?
    let cornerRadius: CGFloat
    private let solid = SolidSurfaces()

    func body(content: Content) -> some View {
        if solid.isOn {
            content
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.primary.opacity(0.25), lineWidth: 1.5))
        } else {
            content.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - Botones

/// Contenido común de los botones: título con símbolo opcional, una línea.
private struct ButtonLabel: View {
    let title: String
    let systemImage: String?
    /// Color del símbolo (si es `nil`, el mismo del texto).
    var iconTint: Color? = nil

    var body: some View {
        let title = Theme.buttonTitle(title)
        Group {
            if let systemImage {
                Label {
                    Text(title)
                } icon: {
                    if let iconTint {
                        Image(systemName: systemImage).foregroundStyle(iconTint)
                    } else {
                        Image(systemName: systemImage)
                    }
                }
            } else {
                Text(title)
            }
        }
        // Con letra grande (Dynamic Type) parte en dos líneas en vez de cortar el texto.
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.85)
    }
}

/// Botón principal: una acción por pantalla. Cápsula de 50 pt, vidrio prominente con el acento azul.
/// En Modo exterior / Reduce Transparency / Increase Contrast: relleno sólido con texto blanco.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = Theme.accent
    var isEnabled: Bool = true
    /// `false` ajusta el ancho al texto (botón en línea); por defecto ocupa todo el ancho.
    var fullWidth: Bool = true
    let action: () -> Void

    private let solid = SolidSurfaces()

    var body: some View {
        let height = solid.isOutdoor ? Theme.ctaHeightOutdoor : Theme.ctaHeight
        if solid.isOn {
            Button(action: action) {
                ButtonLabel(title: title, systemImage: systemImage)
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
                    .contentShape(.capsule)
            }
            .buttonStyle(SolidCapsuleStyle(fill: tint, isEnabled: isEnabled))
            .disabled(!isEnabled)
        } else {
            Button(action: action) {
                ButtonLabel(title: title, systemImage: systemImage)
                    .font(.headline)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height - 2 * GlassMetrics.verticalInset)
                    .contentShape(.capsule)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(tint)
            .disabled(!isEnabled)
        }
    }
}

/// Botón secundario: cápsula de vidrio neutro de 44 pt.
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    /// `false` ajusta el ancho al texto; por defecto ocupa el ancho disponible.
    var fullWidth: Bool = true
    let action: () -> Void

    private let solid = SolidSurfaces()

    var body: some View {
        if solid.isOn {
            Button(action: action) {
                ButtonLabel(title: title, systemImage: systemImage, iconTint: Theme.accent)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Theme.rowHeight)
                    .contentShape(.capsule)
            }
            .buttonStyle(OutlinedCapsuleStyle())
        } else {
            Button(action: action) {
                ButtonLabel(title: title, systemImage: systemImage, iconTint: Theme.accent)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Theme.rowHeight - 2 * GlassMetrics.verticalInset)
                    .contentShape(.capsule)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
        }
    }
}

/// Relleno vertical que agregan `.glass` / `.glassProminent` alrededor de la etiqueta (tamaño regular).
private enum GlassMetrics {
    static let verticalInset: CGFloat = 7
}

/// Cápsula sólida (sin vidrio) para el botón principal en superficies opacas.
private struct SolidCapsuleStyle: ButtonStyle {
    let fill: Color
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .background(isEnabled ? AnyShapeStyle(fill) : AnyShapeStyle(Theme.quietFill), in: .capsule)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Cápsula opaca con borde (botón secundario en superficies opacas).
private struct OutlinedCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(Color(.secondarySystemBackground), in: .capsule)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Fila Sí / No del cuestionario: la frase y dos píldoras de 44 pt. La elegida va en azul.
struct YesNoRow: View {
    let text: String
    @Binding var answer: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ChoicePill(title: "Sí", isSelected: answer == true, context: text) { answer = true }
                ChoicePill(title: "No", isSelected: answer == false, context: text) { answer = false }
            }
        }
        .flatCard(padding: 14)
    }
}

/// Píldora de selección (Sí / No): seleccionada = relleno azul con texto blanco; si no, gris suave.
struct ChoicePill: View {
    let title: String
    let isSelected: Bool
    var context: String? = nil
    let action: () -> Void

    @Environment(\.outdoorMode) private var outdoor

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
                .contentShape(.capsule)
        }
        .buttonStyle(PillStyle(isSelected: isSelected, outlined: outdoor))
        .accessibilityLabel(context.map { "\(title): \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.snappy(duration: 0.2), value: isSelected)
    }
}

/// Estilo de píldora / chip seleccionable.
private struct PillStyle: ButtonStyle {
    let isSelected: Bool
    var outlined: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.quietFill), in: .capsule)
            .overlay {
                if outlined && !isSelected {
                    Capsule().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.5)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: - Chips de selección

/// Chip de selección (zonas, momentos): cápsula de 40 pt. Seleccionado = azul con texto blanco y,
/// si `showsCheckmark`, un ✓ (selección múltiple). No seleccionado = gris suave.
struct ChoiceChip: View {
    let title: String
    var systemImage: String? = nil
    let isSelected: Bool
    var showsCheckmark: Bool = false
    let action: () -> Void

    @Environment(\.outdoorMode) private var outdoor

    /// Alto del chip.
    static let height: CGFloat = 40

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showsCheckmark && isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .transition(.scale.combined(with: .opacity))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.footnote.weight(.semibold))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: Self.height)
            .contentShape(.capsule)
        }
        .buttonStyle(PillStyle(isSelected: isSelected, outlined: outdoor))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.snappy(duration: 0.2), value: isSelected)
    }
}

/// Grupo de chips que se acomoda en varias líneas. `allowsMultiple` permite elegir varios
/// (con ✓); si es `false`, elegir uno reemplaza al anterior. Nunca deja la selección vacía
/// cuando `requiresSelection` es `true`.
struct ChoiceChipGroup<Item: Hashable & Identifiable>: View {
    let items: [Item]
    @Binding var selection: Set<Item>
    var allowsMultiple: Bool = true
    var requiresSelection: Bool = true
    let title: (Item) -> String

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(items) { item in
                ChoiceChip(title: title(item),
                           isSelected: selection.contains(item),
                           showsCheckmark: allowsMultiple) {
                    toggle(item)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func toggle(_ item: Item) {
        selection = Self.toggled(selection, item: item, allowsMultiple: allowsMultiple, requiresSelection: requiresSelection)
    }

    /// Lógica pura del toque (testeable).
    nonisolated static func toggled(_ current: Set<Item>, item: Item, allowsMultiple: Bool, requiresSelection: Bool) -> Set<Item> {
        guard allowsMultiple else { return [item] }
        var next = current
        if next.contains(item) {
            next.remove(item)
            if next.isEmpty && requiresSelection { return current }
        } else {
            next.insert(item)
        }
        return next
    }
}

/// Distribución en filas que saltan de línea (chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width && !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Contenido

/// Anillo de progreso plano. El trazo queda dentro del marco (no se sale por los bordes).
struct ProgressRing: View {
    let progress: Double
    var color: Color = Theme.accent
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.5), value: progress)
        }
    }
}

/// Título de sección (como los encabezados de Salud): negrita, con subtítulo gris opcional.
struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
    /// Altura mínima del chip de racha (capa de vidrio; no es un control).
    static let chipHeight: CGFloat = 36
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
    private let solid = SolidSurfaces()

    func body(content: Content) -> some View {
        if solid.isOn {
            content
                .background(Color(.secondarySystemBackground), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.25), lineWidth: 1.5))
        } else {
            content.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: shape)
        }
    }
}

/// Tile plano de estadística (estilo Salud): símbolo y título chicos, valor en negrita redondeada, nota opcional.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var tint: Color = .primary
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint == .primary ? Theme.accent : tint)
                }
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .font(.footnote.weight(.semibold))
            Text(value)
                .font(.title2.weight(.bold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
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
    /// La llama es el único uso del cobre.
    private var color: Color { safe ? Theme.sky : (streak > 0 ? Theme.copper : .secondary) }

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Theme.chipHeight)
        .functionalGlass(in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(safe ? "Racha a salvo" : "Racha de \(max(0, streak)) días")
    }
}
