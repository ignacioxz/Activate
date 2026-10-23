import SwiftUI

/// Pasos y pisos del día con metas que entregan premios.
struct ActivityView: View {
    @Environment(GameStore.self) private var store
    @Environment(DailyActivity.self) private var activity

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    StatsBar()

                    if !activity.isAvailable {
                        Label("El podómetro no está disponible en este dispositivo.", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .glassCard(cornerRadius: 18, tint: .orange)
                    }

                    HStack(spacing: 14) {
                        ring(value: activity.steps, goal: ActivityGoal.steps8000.target,
                             colors: [Theme.lime, .mint, Theme.lime], symbol: "figure.walk", label: "pasos")
                        ring(value: activity.floors, goal: ActivityGoal.floors10.target,
                             colors: [Theme.copper, Theme.gold, Theme.copper], symbol: "figure.stairs", label: "pisos")
                    }

                    Label(String(format: "%.1f km recorridos hoy", activity.distanceKm), systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.headline)
                        .glassCard(cornerRadius: 18)

                    SectionTitle(title: "Metas diarias")
                    ForEach(ActivityGoal.allCases, id: \.self) { goal in
                        goalRow(goal)
                    }

                    Label("Prefiere la escalera del campamento y camina en la colación. Con dolor lumbar, caminar es de los mejores ejercicios.",
                          systemImage: "lightbulb.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .glassCard(cornerRadius: 18, tint: Theme.gold)
                }
                .padding()
            }
            .appScreen()
            .navigationTitle("Actividad")
        }
    }

    private func ring(value: Int, goal: Int, colors: [Color], symbol: String, label: String) -> some View {
        VStack(spacing: 10) {
            ZStack {
                ProgressRing(progress: min(1, Double(value) / Double(goal)), colors: colors, lineWidth: 14)
                VStack(spacing: 2) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(colors[0].gradient)
                    Text("\(value)")
                        .font(.title2.weight(.heavy))
                        .contentTransition(.numericText())
                    Text("de \(goal)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, height: 130)
            Text(label.capitalized).font(.headline)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .glassEffect(in: .rect(cornerRadius: 26))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) de \(goal) \(label)")
    }

    private func goalRow(_ goal: ActivityGoal) -> some View {
        let current = goal == .steps8000 ? activity.steps : activity.floors
        let reached = current >= goal.target
        let claimed = store.isClaimed(goal)

        return HStack(spacing: 14) {
            Image(systemName: goal == .steps8000 ? "figure.walk.circle.fill" : "figure.stairs.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(reached ? Theme.lime.gradient : Color.gray.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.title).font(.headline)
                Text("+\(goal.xp) XP").font(.subheadline).foregroundStyle(Theme.gold)
            }
            Spacer()
            if claimed {
                Label("Listo", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.lime)
            } else {
                Button("Reclamar") {
                    store.claim(goal, steps: activity.steps, floors: activity.floors)
                }
                .font(.subheadline.weight(.heavy))
                .buttonStyle(.glassProminent)
                .tint(Theme.lime)
                .disabled(!reached)
            }
        }
        .glassCard(cornerRadius: 22)
        .sensoryFeedback(.success, trigger: claimed)
    }
}

#Preview {
    ActivityView()
        .environment(GameStore(inMemory: true))
        .environment(DailyActivity())
        .preferredColorScheme(.dark)
}
