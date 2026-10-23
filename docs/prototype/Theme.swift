import SwiftUI

/// Paleta y componentes visuales compartidos: estética minera nocturna con acentos cobre.
enum Theme {
    static let copper = Color(red: 0.95, green: 0.55, blue: 0.25)
    static let lime = Color(red: 0.45, green: 0.88, blue: 0.40)
    static let sky = Color(red: 0.35, green: 0.65, blue: 1.0)
    static let gold = Color(red: 1.0, green: 0.80, blue: 0.25)
    static let night = Color(red: 0.05, green: 0.06, blue: 0.10)

    static func painColor(_ level: Int) -> Color {
        [lime, .mint, .yellow, copper, .red][max(1, min(5, level)) - 1]
    }
}

/// Fondo con degradado de malla: noche del desierto con brillo cobre.
struct AppBackground: View {
    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.6, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ],
            colors: [
                Theme.night, Color(red: 0.28, green: 0.13, blue: 0.07), Theme.night,
                Color(red: 0.06, green: 0.10, blue: 0.18), Color(red: 0.10, green: 0.08, blue: 0.12), Color(red: 0.22, green: 0.10, blue: 0.05),
                Theme.night, Color(red: 0.04, green: 0.14, blue: 0.14), Theme.night
            ]
        )
        .ignoresSafeArea()
    }
}

extension View {
    /// Tarjeta de vidrio (Liquid Glass) con esquinas redondeadas.
    func glassCard(cornerRadius: CGFloat = 26, tint: Color? = nil) -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? .regular,
                         in: .rect(cornerRadius: cornerRadius))
    }

    /// Fondo estándar de cada pantalla.
    func appScreen() -> some View {
        scrollContentBackground(.hidden)
            .background(AppBackground())
    }
}

/// Botón principal grande, con vidrio prominente.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var tint: Color = Theme.lime
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.headline.weight(.heavy))
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.glassProminent)
        .tint(tint)
    }
}

/// Anillo de progreso con degradado angular.
struct ProgressRing: View {
    let progress: Double
    var colors: [Color] = [Theme.lime, Color.mint, Theme.lime]
    var lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(AngularGradient(colors: colors, center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: (colors.first ?? .clear).opacity(0.6), radius: 8)
                .animation(.spring(duration: 0.6), value: progress)
        }
    }
}

/// Encabezado de sección.
struct SectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.bold))
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}
