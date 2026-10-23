import SwiftUI

// Dueño: paquete "kine-ai". Raíz de QA (solo DEBUG) para revisar la hoja del kine sin pasar por el
// onboarding: siembra DemoSeed en un AppStore en memoria y muestra KineSheetScreen.
// Se activa con el argumento de lanzamiento "-qa-kine" si ActivateApp lo cablea:
//     WindowGroup { if KineSheetQA.isRequested { KineSheetQARoot() } else { RootGate { RootTabView() } … } }
// "-qa-kine-rules" fuerza la plantilla (sin Apple Intelligence); "-qa-kine-prepare" prepara al abrir.

#if DEBUG
enum KineSheetQA {
    static let launchArgument = "-qa-kine"
    static let rulesArgument = "-qa-kine-rules"
    static let prepareArgument = "-qa-kine-prepare"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }
    static var forcesRules: Bool { ProcessInfo.processInfo.arguments.contains(rulesArgument) }
    static var autoPrepares: Bool { ProcessInfo.processInfo.arguments.contains(prepareArgument) }

    /// Nota de ejemplo para revisar "En sus palabras".
    static let sampleNote = "Me duele la espalda al bajar del camión, sobre todo los últimos días del turno. En la noche en el campamento me cuesta dormir."
}

struct KineSheetQARoot: View {
    @State private var store: AppStore
    @State private var coach: CoachService
    private let autoPrepare: Bool
    private let note: String

    /// - Parameters:
    ///   - now: instante de la semilla (hoy = día 2 del turno de Marco).
    ///   - override: `.rules` muestra el estado sin Apple Intelligence.
    ///   - autoPrepare: prepara con Apple Intelligence al abrir (como si tocara el botón).
    ///   - note: texto inicial de "En sus palabras".
    init(now: Date = .now, override: CoachOverride? = nil, autoPrepare: Bool = KineSheetQA.autoPrepares, note: String = "") {
        let s = AppStore(inMemory: true)
        DemoSeed.load(into: s, now: now)
        let c = CoachService()
        c.refreshAvailability()
        c.override = override ?? (KineSheetQA.forcesRules ? .rules : .auto)
        _store = State(initialValue: s)
        _coach = State(initialValue: c)
        self.autoPrepare = autoPrepare
        self.note = note
    }

    var body: some View {
        NavigationStack {
            KineSheetScreen(qaAutoPrepare: autoPrepare, qaNote: note)
        }
        .environment(store)
        .environment(coach)
        .fontDesign(.rounded)
        .tint(Theme.accent)
    }
}
#endif
