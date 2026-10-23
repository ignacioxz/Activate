import SwiftUI

@main
struct ActivateApp: App {
    @State private var store: AppStore
    @State private var sensors: SensorHub
    @State private var coach: CoachService
    @State private var game: GameStore

    init() {
        let s = AppStore()
        let hub = SensorHub()
        let c = CoachService()
        c.override = s.data.demo.coachOverride
        _store = State(initialValue: s)
        _sensors = State(initialValue: hub)
        _coach = State(initialValue: c)
        _game = State(initialValue: GameStore(store: s))
        // Un builder por actividad (verificador + fuente); en simulador siempre replay.
        VerifierWiring.register(sensors: hub, store: s)
    }

    var body: some Scene {
        WindowGroup {
            RootGate { RootTabView() }
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
