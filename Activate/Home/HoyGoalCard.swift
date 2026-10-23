import SwiftUI

/// "Meta de hoy": anillo de la pausa del día con la racha adentro, el hito en juego, lo que gana
/// ("hasta"), la ruta de íconos y la única acción principal. Tarjeta plana.
struct HoyGoalCard: View {
    let goal: HoyGoal
    let route: [ActivityAssignment]
    let routeMinutes: Int
    let momentTitle: String
    let onStart: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showRoute = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    ring(size: 60)
                    texts
                }
            } else {
                HStack(alignment: .center, spacing: 14) {
                    ring(size: 76)
                    texts
                }
            }

            if let line = goal.unverifiedLine {
                Label(line, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !goal.chips.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let title = goal.chipsTitle {
                        Text(title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    FlowLayout(spacing: 8) {
                        ForEach(goal.chips) { chip in
                            RewardTag(chip: chip)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(goal.chipsSpoken.isEmpty ? goal.chips.map(\.spoken).joined(separator: "; ") : goal.chipsSpoken)
            }

            if goal.showsRoute {
                routeSection
            }

            switch goal.action {
            case .primary(let title, let symbol):
                PrimaryButton(title: title, systemImage: symbol, tint: Theme.accent, action: onStart)
                    .accessibilityHint("\(momentTitle), \(routeMinutes) minutos")
            case .secondary(let title, let symbol):
                SecondaryButton(title: title, systemImage: symbol, action: onStart)
                    .accessibilityHint("Ruta completa, \(routeMinutes) minutos")
            }
        }
        .flatCard()
    }

    // MARK: Anillo y textos

    private func ring(size: CGFloat) -> some View {
        ZStack {
            if goal.ringIsGoal {
                ProgressRing(progress: goal.ringProgress, lineWidth: 8)
            } else {
                // Bajada: anillo sin meta (solo el fondo), la racha congelada adentro.
                Circle()
                    .inset(by: 4)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 8)
            }
            // El anillo es un gráfico de tamaño fijo (su contenido lo dice el bloque de texto a VoiceOver):
            // la llama y el número escalan con el anillo, no con la letra, para no salirse.
            VStack(spacing: -2) {
                Image(systemName: "flame.fill")
                    .font(.system(size: size * 0.27))
                    .foregroundStyle(goal.streak > 0 ? Theme.copper : Color.secondary)
                Text("\(goal.streak)")
                    .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
            }
            .frame(width: size * 0.7)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if goal.done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.accent)
                    .background(Circle().fill(Color(.secondarySystemBackground)).padding(-2))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .accessibilityHidden(true)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(goal.eyebrow)
            } icon: {
                Image(systemName: goal.eyebrowSymbol)
                    .foregroundStyle(Theme.accent)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(goal.title)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Text(goal.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(goal.spoken) \(goal.eyebrow). \(goal.subtitle)")
    }

    // MARK: Ruta

    private var routeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ruta de \(routeMinutes) min")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                showRoute = true
            } label: {
                Group {
                    if typeSize.isAccessibilitySize {
                        Label("Ruta de \(route.count) ejercicios · \(routeMinutes) min", systemImage: "list.number")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        RouteIcons(kinds: route.map(\.kind))
                    }
                }
                .frame(minHeight: Theme.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showRoute, arrowEdge: .top) {
                RoutePopover(route: route)
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel("Ruta de \(routeMinutes) minutos: " + route.map(\.kind.name).joined(separator: ", "))
            .accessibilityHint("Muestra la ruta de hoy con sus metas")
        }
    }
}
