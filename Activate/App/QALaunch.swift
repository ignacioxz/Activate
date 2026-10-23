#if DEBUG
import Foundation

// Dueño: agente "design-system". Solo Debug: nunca entra en la versión que va al teléfono de Marco.
//
// Argumentos de lanzamiento para revisar pantallas en el simulador sin tocar nada:
//   -qa-seed                 carga la demo de Marco (DemoSeed) y salta el alta
//   -qa-tab home|stats|profile   pestaña inicial (también "hoy", "estadisticas", "perfil")
//   -qa-outdoor              enciende el Modo exterior
//   -qa-gallery [1-3]        muestra la galería del design system (página opcional)
//   -qa-scroll-bottom        abre Hoy al final (segunda captura)
//   -qaPausaHoy …            escenarios de Hoy (ver HomeQA): pausa hecha, comodín de ayer, sin consentimiento
// Ejemplo: xcrun simctl launch <UDID> com.ignaciosalazar.activate -qa-seed -qa-tab stats

/// Opciones de QA leídas de `ProcessInfo.arguments`.
nonisolated struct QALaunch: Equatable, Sendable {
    var seed = false
    var outdoor = false
    var tab: RootTab? = nil
    var gallery = false
    var galleryPage: Int? = nil
    /// Hoy abre al final (capturas del resto de las tarjetas).
    var scrollBottom = false

    /// Opciones del proceso actual.
    static let current = parse(ProcessInfo.processInfo.arguments)

    /// `true` si se pidió cualquier opción.
    var isActive: Bool { seed || outdoor || tab != nil || gallery || scrollBottom }

    static func parse(_ arguments: [String]) -> QALaunch {
        var result = QALaunch()
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch arg {
            case "-qa-seed":
                result.seed = true
            case "-qa-outdoor":
                result.outdoor = true
            case "-qa-scroll-bottom":
                result.scrollBottom = true
            case "-qa-tab":
                if let next, let tab = RootTab(argument: next) {
                    result.tab = tab
                    index += 1
                }
            case "-qa-gallery":
                result.gallery = true
                if let next, let page = Int(next) {
                    result.galleryPage = page
                    index += 1
                }
            default:
                break
            }
            index += 1
        }
        return result
    }

    /// Prepara el store antes de crear el resto de los servicios.
    @MainActor
    func prepare(_ store: AppStore, now: Date = .now) {
        if seed {
            DemoSeed.load(into: store, now: now)
            store.mutate { $0.profile.onboardingDone = true }
        }
        if outdoor {
            store.mutate { $0.profile.outdoorMode = true }
        }
    }
}
#endif
