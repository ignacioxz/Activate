import SwiftUI

/// Plan de la pausa: receta fija visible al instante; la línea "por qué" del coach aparece si llega a tiempo.
struct PlanView: View {
    let name: String
    let recipe: RecipeKind
    let activities: [ActivityAssignment]
    let why: String?
    let startMessage: String?
    let gentle: Bool
    /// Sin consentimiento: se quitaron las actividades de cámara.
    var cameraBlocked: Bool = false
    /// Ejercicios que no entran hoy y por qué (calculado en Swift).
    var excluded: [PlanExclusion] = []
    let onStart: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Línea que explica por qué no hay actividades de cara ni cuerpo.
    static let cameraBlockedCopy = "Sin permiso de cámara: solo pasos y pantalla"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: recipe.title, subtitle: subtitle)

                if gentle {
                    Label("Plan suave hoy.", systemImage: "leaf.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.mint)
                }

                if cameraBlocked {
                    Label(Self.cameraBlockedCopy, systemImage: "video.slash.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if activities.isEmpty {
                    Text("Hoy no queda ejercicio para usted.")
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                        .flatCard()
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(activities.enumerated()), id: \.element.id) { index, a in
                            PlanRow(position: index + 1, assignment: a)
                        }
                    }
                }

                if let why, !why.isEmpty {
                    Label(why, systemImage: "sparkles")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .flatCard()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }

                if !excluded.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No incluidas hoy")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(excluded) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(item.kind.name, systemImage: item.kind.symbol)
                                    .font(.subheadline.weight(.semibold))
                                Text(item.reason)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .flatCard()
                }
            }
            .padding()
            .animation(reduceMotion ? nil : .smooth, value: why)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if let startMessage, !startMessage.isEmpty, !activities.isEmpty {
                    Text(startMessage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                if activities.isEmpty {
                    SecondaryButton(title: "Cerrar") { onClose() }
                } else {
                    PrimaryButton(title: "Empezar", systemImage: "play.fill") { onStart() }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .animation(reduceMotion ? nil : .smooth, value: startMessage)
        }
    }

    private var subtitle: String {
        let n = activities.count
        let count = n == 1 ? "1 actividad" : "\(n) actividades"
        return "\(name), \(recipe.minutes) min · \(count)"
    }
}

/// Fila de una actividad del plan: símbolo, nombre, meta y colocación del teléfono.
struct PlanRow: View {
    let position: Int
    let assignment: ActivityAssignment

    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 48

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.14))
                Image(systemName: assignment.kind.symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: iconSize, height: iconSize)
            VStack(alignment: .leading, spacing: 4) {
                Text(assignment.kind.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(assignment.target) \(assignment.kind.unit)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label(Self.placement(for: assignment.kind), systemImage: Self.placementSymbol(for: assignment.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("\(position)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .flatCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    /// Dónde va el teléfono. La sentadilla, pararse y sentarse y la extensión lumbar usan el bloque de cara
    /// (`.face`), pero van con el teléfono en las dos manos frente al pecho, no en una mano a distancia selfie.
    static func placement(for kind: ActivityKind) -> String {
        switch kind {
        case .sentadilla, .pararseSentarse, .extensionLumbar: kind.placement
        default: placement(for: kind.sensorBlock)
        }
    }

    static func placementSymbol(for kind: ActivityKind) -> String {
        switch kind {
        case .sentadilla, .pararseSentarse, .extensionLumbar: "iphone"
        default: placementSymbol(for: kind.sensorBlock)
        }
    }

    /// Dónde va el teléfono según el bloque de sensor.
    static func placement(for block: SensorBlock) -> String {
        switch block {
        case .pedometer: "Teléfono en el bolsillo"
        case .face: "Teléfono en la mano"
        case .screen: "Teléfono en la mano"
        }
    }

    static func placementSymbol(for block: SensorBlock) -> String {
        switch block {
        case .pedometer: "figure.walk.motion"
        case .face: "faceid"
        case .screen: "hand.tap.fill"
        }
    }
}
