import SwiftUI

// Dueño: paquete "zones-session". Ganchos para capturas de QA en el simulador.
// En Release `qaLaunchHook()` no hace nada y `qaScrollTarget` queda siempre en nil.

/// Ancla a la que una pantalla hace scroll al aparecer. Solo la fija el gancho de QA (DEBUG).
struct QAScrollTargetKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var qaScrollTarget: String? {
        get { self[QAScrollTargetKey.self] }
        set { self[QAScrollTargetKey.self] = newValue }
    }
}

extension View {
    /// En DEBUG aplica los argumentos de lanzamiento de QA (ver `QALaunchOptions`); en Release no hace nada.
    @ViewBuilder
    func qaLaunchHook() -> some View {
        #if DEBUG
        modifier(QALaunchHook())
        #else
        self
        #endif
    }
}

#if DEBUG
/// Argumentos de lanzamiento solo para QA (DEBUG). Uso:
/// `xcrun simctl launch <UDID> com.ignaciosalazar.activate -qa-seed -qa-zones lumbar,cuello -qa-screen checkin-zones`
/// - `-qa-seed`: carga la semilla demo (Marco, día 2) al arrancar.
/// - `-qa-zones lumbar,cuello`: fija las zonas habituales del perfil (ids de `PainZone`).
/// - `-qa-no-consent`: deja el perfil sin consentimiento (el plan queda sin cámara).
/// - `-qa-screen <pantalla>`: abre `checkin`, `checkin-zones` (check-in con scroll a "¿Dónde le duele?"),
///   `painnow` ("Me duele ahora") o `profile` (Perfil).
/// - `-qa-moment <momento>`: momento con que se abre la pausa (`entrada`, `colacion`, `salida`, `campamento`).
nonisolated struct QALaunchOptions: Equatable, Sendable {
    nonisolated enum Screen: String, Identifiable, Sendable {
        case checkIn = "checkin"
        case checkInZones = "checkin-zones"
        case painNow = "painnow"
        case profile
        var id: String { rawValue }
    }

    var seed = false
    var zones: [PainZone]? = nil
    var noConsent = false
    var screen: Screen? = nil
    var moment: Moment = .colacion

    var isEmpty: Bool { !seed && zones == nil && !noConsent && screen == nil }

    static func parse(_ arguments: [String]) -> QALaunchOptions {
        var o = QALaunchOptions()
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        o.seed = arguments.contains("-qa-seed")
        o.noConsent = arguments.contains("-qa-no-consent")
        if let raw = value(after: "-qa-zones") {
            let zones = raw.split(separator: ",").compactMap { PainZone(rawValue: String($0)) }
            if !zones.isEmpty { o.zones = PainZone.normalized(zones) }
        }
        o.screen = value(after: "-qa-screen").flatMap(Screen.init(rawValue:))
        if let m = value(after: "-qa-moment").flatMap(Moment.init(rawValue:)) { o.moment = m }
        return o
    }
}

private struct QALaunchHook: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var applied = false
    @State private var cover: QALaunchOptions.Screen?
    @State private var sheet: QALaunchOptions.Screen?
    @State private var options = QALaunchOptions()

    func body(content: Content) -> some View {
        content
            .task {
                guard !applied else { return }
                applied = true
                apply(QALaunchOptions.parse(ProcessInfo.processInfo.arguments))
            }
            .fullScreenCover(item: $cover) { screen in
                PauseFlowView(moment: options.moment)
                    .environment(\.qaScrollTarget, screen == .checkInZones ? CheckInView.zonesAnchor : nil)
            }
            .sheet(item: $sheet) { screen in
                switch screen {
                case .profile: ProfileView()
                default: PainNowSheet()
                }
            }
    }

    private func apply(_ o: QALaunchOptions) {
        guard !o.isEmpty else { return }
        options = o
        if o.seed { DemoSeed.load(into: store, now: .now) }
        if let zones = o.zones { store.mutate { $0.profile.setUsualZones(zones) } }
        if o.noConsent { store.mutate { $0.profile.consentGiven = false } }
        switch o.screen {
        case .checkIn, .checkInZones: cover = o.screen
        case .painNow, .profile: sheet = o.screen
        case nil: break
        }
    }
}
#endif
