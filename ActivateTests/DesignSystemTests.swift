import Testing
import Foundation
@testable import Activate

/// Paquete design-system: contraste de la paleta, colores del RDQ, etiquetas de botones,
/// chips de selección múltiple, accesorio de la barra y argumentos de QA.
struct DesignSystemTests {

    // MARK: Paleta

    @Test func textColorsAreReadableInLightAndDark() {
        for (name, color) in ThemePalette.textColors {
            let onWhite = ThemeRGB.contrast(color.light, .white)
            let onCardLight = ThemeRGB.contrast(color.light, .cardLight)
            let onBlack = ThemeRGB.contrast(color.dark, .black)
            let onCardDark = ThemeRGB.contrast(color.dark, .cardDark)
            #expect(onWhite >= 4.5, "\(name) claro sobre blanco: \(onWhite)")
            #expect(onCardLight >= 4.0, "\(name) claro sobre tarjeta: \(onCardLight)")
            #expect(onBlack >= 4.5, "\(name) oscuro sobre negro: \(onBlack)")
            #expect(onCardDark >= 4.5, "\(name) oscuro sobre tarjeta: \(onCardDark)")
        }
    }

    @Test func accentCarriesWhiteLabelsInLightMode() {
        #expect(ThemeRGB.contrast(.white, ThemePalette.accent.light) >= 4.5)
        #expect(ThemeRGB.contrast(.white, ThemePalette.accent.dark) >= 3.0)
    }

    @Test func contrastMatchesKnownValues() {
        #expect(abs(ThemeRGB.contrast(.white, .black) - 21) < 0.001)
        #expect(abs(ThemeRGB.contrast(.white, .white) - 1) < 0.001)
    }

    @Test func rdqColorsNeverPureYellow() {
        for score in 0...6 {
            let spec = ThemePalette.rdq(score)
            for rgb in [spec.light, spec.dark] {
                let isYellow = rgb.r > 0.85 && rgb.g > 0.85 && rgb.b < 0.3
                #expect(!isYellow, "RDQ \(score) es amarillo puro")
            }
        }
        #expect(ThemePalette.rdq(0) == ThemePalette.successText)
        #expect(ThemePalette.rdq(1) == ThemePalette.successText)
        #expect(ThemePalette.rdq(2) == ThemePalette.warningText)
        #expect(ThemePalette.rdq(3) == ThemePalette.warningText)
        #expect(ThemePalette.rdq(4) == ThemePalette.rdqHigh)
        #expect(ThemePalette.rdq(5) == ThemePalette.dangerText)
        #expect(ThemePalette.rdq(6) == ThemePalette.dangerText)
    }

    @Test @MainActor func nativeSizes() {
        #expect(Theme.ctaHeight == 50)
        #expect(Theme.rowHeight == 44)
        #expect(Theme.ctaHeightOutdoor > Theme.ctaHeight)
    }

    // MARK: Botones

    @Test func buttonTitlesUseSentenceCase() {
        #expect(Theme.buttonTitle("EMPEZAR") == "Empezar")
        #expect(Theme.buttonTitle("SEGUIR") == "Seguir")
        #expect(Theme.buttonTitle("ENTENDIDO") == "Entendido")
        #expect(Theme.buttonTitle("Hacer la pausa") == "Hacer la pausa")
        #expect(Theme.buttonTitle("Cargar demo (Marco, día 2)") == "Cargar demo (Marco, día 2)")
        #expect(Theme.buttonTitle("OK") == "OK")
        #expect(Theme.buttonTitle("") == "")
    }

    // MARK: Chips

    private enum Zone: String, Identifiable, Hashable, CaseIterable {
        case cuello, lumbar, rodilla
        var id: String { rawValue }
    }

    @Test func multiChoiceTogglesAndKeepsOne() {
        typealias G = ChoiceChipGroup<Zone>
        var sel: Set<Zone> = [.lumbar]
        sel = G.toggled(sel, item: .cuello, allowsMultiple: true, requiresSelection: true)
        #expect(sel == [.lumbar, .cuello])
        sel = G.toggled(sel, item: .lumbar, allowsMultiple: true, requiresSelection: true)
        #expect(sel == [.cuello])
        // No queda vacía si se exige al menos una.
        sel = G.toggled(sel, item: .cuello, allowsMultiple: true, requiresSelection: true)
        #expect(sel == [.cuello])
        // Sin exigencia, sí puede quedar vacía.
        #expect(G.toggled([.cuello], item: .cuello, allowsMultiple: true, requiresSelection: false).isEmpty)
    }

    @Test func singleChoiceReplaces() {
        let sel = ChoiceChipGroup<Zone>.toggled([.lumbar, .cuello], item: .rodilla, allowsMultiple: false, requiresSelection: true)
        #expect(sel == [.rodilla])
    }

    // MARK: Barra de pestañas

    @Test func nextPauseAccessoryText() {
        #expect(NextPauseAccessory.text(for: .colacion, compact: false) == "Próxima: colación · \(Moment.colacion.minutes) min")
        #expect(NextPauseAccessory.text(for: .entrada, compact: false) == "Próxima: relevo de entrada · \(Moment.entrada.minutes) min")
        #expect(NextPauseAccessory.text(for: .campamento, compact: true) == "Campamento · \(Moment.campamento.minutes) min")
    }

    @Test func nextPauseOnlyOnTurnoWithoutPauseOutsideHome() {
        #expect(RootTabView.showsNextPause(isTurnoToday: true, pausedToday: false, tab: .stats))
        #expect(RootTabView.showsNextPause(isTurnoToday: true, pausedToday: false, tab: .profile))
        #expect(!RootTabView.showsNextPause(isTurnoToday: true, pausedToday: false, tab: .home))
        #expect(!RootTabView.showsNextPause(isTurnoToday: true, pausedToday: true, tab: .stats))
        #expect(!RootTabView.showsNextPause(isTurnoToday: false, pausedToday: false, tab: .stats))
    }

    @Test func rootTabArguments() {
        #expect(RootTab(argument: "home") == .home)
        #expect(RootTab(argument: "Hoy") == .home)
        #expect(RootTab(argument: "stats") == .stats)
        #expect(RootTab(argument: "estadísticas") == .stats)
        #expect(RootTab(argument: "perfil") == .profile)
        #expect(RootTab(argument: "otra") == nil)
    }

    // MARK: QA

    #if DEBUG
    @Test func qaLaunchParsesArguments() {
        let qa = QALaunch.parse(["/app", "-qa-seed", "-qa-tab", "stats", "-qa-outdoor"])
        #expect(qa.seed)
        #expect(qa.outdoor)
        #expect(qa.tab == .stats)
        #expect(!qa.gallery)
        #expect(qa.isActive)

        let gallery = QALaunch.parse(["/app", "-qa-gallery", "2"])
        #expect(gallery.gallery)
        #expect(gallery.galleryPage == 2)

        let galleryAll = QALaunch.parse(["/app", "-qa-gallery", "-qa-seed"])
        #expect(galleryAll.gallery)
        #expect(galleryAll.galleryPage == nil)
        #expect(galleryAll.seed)

        let none = QALaunch.parse(["/app", "-qa-tab", "nada"])
        #expect(none.tab == nil)
        #expect(!none.isActive)
    }

    @Test @MainActor func qaSeedLoadsDemoAndSkipsOnboarding() {
        let store = AppStore(inMemory: true)
        #expect(!store.profile.onboardingDone)
        QALaunch.parse(["/app", "-qa-seed", "-qa-outdoor"]).prepare(store)
        #expect(store.profile.onboardingDone)
        #expect(store.profile.name == "Marco")
        #expect(store.profile.outdoorMode)
        #expect(!store.data.sessions.isEmpty)
    }
    #endif
}
