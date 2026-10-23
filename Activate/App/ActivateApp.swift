import SwiftUI

@main
struct ActivateApp: App {
    @State private var store: AppStore
    @State private var sensors: SensorHub
    @State private var coach: CoachService
    @State private var game: GameStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Diagnostics.log("app arranca build=\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
        let s = AppStore()
        #if DEBUG
        // Argumentos de QA (-qa-seed, -qa-outdoor…): se aplican antes de crear los servicios.
        QALaunch.current.prepare(s)
        // Escenarios de Hoy (-qaPausaHoy, -qaComodinAyer, -qaSinConsentimiento): después de la semilla.
        HomeQA.apply(arguments: ProcessInfo.processInfo.arguments, to: s)
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
        // Sentadilla y extensión lumbar: en las manos (ARKit cara + mundo). Nunca se muestra la cámara.
        SquatWiring.register(hub: hub, store: s)
        // Pararse y sentarse: la misma fuente en las manos que la sentadilla (sin modo apoyado ni cámara en pantalla).
        SitStandWiring.register(hub: hub, store: s)
        ExtensionWiring.register(hub: hub, store: s)
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
                // La pantalla no se bloquea mientras la app está abierta (pedido del usuario): las pausas
                // se hacen con el teléfono en la mano (o en el bolsillo al caminar) y sin tocarlo. Al salir se restaura.
                .onAppear { ScreenAwake.update(for: .active) }
                .onChange(of: scenePhase) { _, phase in
                    ScreenAwake.update(for: phase)
                    Diagnostics.log("app escena=\(phase)")
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Diagnostics.log("app aviso de memoria")
                }
                .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                    Diagnostics.log("app temperatura=\(ProcessInfo.processInfo.thermalState.rawValue)")
                }
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


/// Bloqueo automático de pantalla desactivado solo con la app en primer plano.
enum ScreenAwake {
    static func update(for phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = (phase == .active)
    }
}
