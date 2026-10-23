import SwiftUI

@main
struct ActivateApp: App {
    @State private var store = AppStore()
    @State private var sensors = SensorHub()
    @State private var coach = CoachService()
    @State private var game: GameStore

    init() {
        let s = AppStore()
        _store = State(initialValue: s)
        _game = State(initialValue: GameStore(store: s))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(sensors)
                .environment(coach)
                .environment(game)
                .environment(\.outdoorMode, store.data.profile.outdoorMode)
                .fontDesign(.rounded)
                .tint(Theme.copper)
        }
    }
}
