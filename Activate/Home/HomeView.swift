import SwiftUI

// Dueño: agente "home". Placeholder.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Hoy").font(.largeTitle.weight(.heavy))
                Text("Pantalla en construcción").foregroundStyle(.secondary)
            }
            .appScreen()
        }
    }
}
