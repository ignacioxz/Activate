import SwiftUI

/// Plan de la pausa: receta fija visible al instante; la línea "por qué" del coach aparece si llega a tiempo.
struct PlanView: View {
    let name: String
    let recipe: RecipeKind
    let activities: [ActivityAssignment]
    let why: String?
    let startMessage: String?
    let gentle: Bool
    let onStart: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: recipe.title, subtitle: subtitle)

                if gentle {
                    Label("Plan suave hoy.", systemImage: "leaf.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.mint)
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
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding()
            .animation(.smooth, value: why)
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
                    PrimaryButton(title: "CERRAR", tint: .gray) { onClose() }
                } else {
                    PrimaryButton(title: "EMPEZAR", systemImage: "play.fill") { onStart() }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .animation(.smooth, value: startMessage)
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

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.copper.opacity(0.15))
                Image(systemName: assignment.kind.symbol)
                    .font(.title2)
                    .foregroundStyle(Theme.copper)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(assignment.kind.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(assignment.target) \(assignment.kind.unit)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label(Self.placement(for: assignment.kind.sensorBlock), systemImage: Self.placementSymbol(for: assignment.kind.sensorBlock))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("\(position)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .flatCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    /// Dónde va el teléfono según el bloque de sensor.
    static func placement(for block: SensorBlock) -> String {
        switch block {
        case .pedometer: "Teléfono en el bolsillo"
        case .cameraPose: "Teléfono apoyado, a 2 metros"
        case .face: "Teléfono en la mano"
        case .screen: "Teléfono en la mano"
        }
    }

    static func placementSymbol(for block: SensorBlock) -> String {
        switch block {
        case .pedometer: "figure.walk.motion"
        case .cameraPose: "camera.fill"
        case .face: "faceid"
        case .screen: "hand.tap.fill"
        }
    }
}
