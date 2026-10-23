import SwiftUI

@main
struct ActivateApp: App {
    @State private var store: AppStore
    @State private var sensors: SensorHub
    @State private var coach: CoachService
    @State private var game: GameStore

    init() {
        let s = AppStore()
        #if DEBUG
        // Argumentos de QA (-qa-seed, -qa-outdoor…): se aplican antes de crear los servicios.
        QALaunch.current.prepare(s)
        #endif
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
            root
                .environment(store)
                .environment(sensors)
                .environment(coach)
                .environment(game)
                .environment(\.outdoorMode, outdoorMode)
                // Modo exterior = apariencia clara siempre (sol directo); si no, sigue al sistema.
                .preferredColorScheme(outdoorMode ? .light : nil)
                .tint(Theme.accent)
        }
    }

    private var outdoorMode: Bool {
        #if DEBUG
        // La galería no depende del perfil guardado: Modo exterior solo con -qa-outdoor.
        if QALaunch.current.gallery { return QALaunch.current.outdoor }
        #endif
        return store.data.profile.outdoorMode
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if QALaunch.current.gallery {
            ThemeGallery(page: QALaunch.current.galleryPage)
        } else {
            RootGate { RootTabView(initialTab: QALaunch.current.tab ?? .home) }
        }
        #else
        RootGate { RootTabView() }
        #endif
    }
}
