import SwiftUI

/// Tres pestañas: Hoy · Estadísticas · Perfil. La pausa corre en fullScreenCover sin tab bar.
struct RootTabView: View {
    @Environment(AppStore.self) private var store
    @Environment(GameStore.self) private var game
    @Environment(CoachService.self) private var coach
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Hoy", systemImage: "sun.max.fill") { HomeView() }
            Tab("Estadísticas", systemImage: "chart.bar.fill") { StatsView() }
            Tab("Perfil", systemImage: "person.fill") { ProfileView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                game.applyDayRollover()
                coach.refreshAvailability()
            }
        }
        .task {
            game.applyDayRollover()
            coach.refreshAvailability()
        }
    }
}
