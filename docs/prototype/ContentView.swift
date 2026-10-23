import SwiftUI

struct ContentView: View {
    @State private var store = GameStore()
    @State private var activity = DailyActivity()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Ruta", systemImage: "map.fill") {
                PathView()
            }
            Tab("Actividad", systemImage: "figure.walk") {
                ActivityView()
            }
            Tab("Espalda", systemImage: "heart.text.square.fill") {
                BackView()
            }
            Tab("Perfil", systemImage: "person.crop.circle.fill") {
                ProfileView()
            }
        }
        .tint(Theme.copper)
        .fontDesign(.rounded)
        .preferredColorScheme(.dark)
        .environment(store)
        .environment(activity)
        .task { activity.start() }
        // Reprograma los recordatorios cuando cambia el progreso o la configuración.
        .task(id: store.notificationKey) {
            await NotificationScheduler.reschedule(for: store)
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await NotificationScheduler.reschedule(for: store) }
            }
        }
    }
}

/// Barra superior estilo Duolingo: racha, cascos, pepitas y XP en cápsulas de vidrio.
struct StatsBar: View {
    @Environment(GameStore.self) private var store

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                stat("flame.fill", "\(store.streak)", .orange, label: "Racha de turnos")
                stat("shield.fill", "\(store.data.shields)", Theme.sky, label: "Cascos protectores")
                stat("diamond.fill", "\(store.data.nuggets)", Theme.copper, label: "Pepitas de cobre")
                stat("bolt.fill", "\(store.data.xp)", Theme.gold, label: "Puntos de experiencia")
            }
        }
    }

    private func stat(_ symbol: String, _ value: String, _ color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color.gradient)
            Text(value).contentTransition(.numericText())
        }
        .font(.subheadline.weight(.bold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .glassEffect()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

extension LessonUnit {
    var color: Color {
        switch colorName {
        case "orange": Theme.copper
        case "blue": Theme.sky
        default: Theme.lime
        }
    }
}

#Preview {
    ContentView()
}
