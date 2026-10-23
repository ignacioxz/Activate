import Testing
import Foundation
@testable import Activate

/// Distribución de las tarjetas de Hoy con letra grande y colores de las insignias en Hoy:
/// hitos del camino que no se pisan, momentos que pasan a lista si "Campamento" no cabe y
/// insignias ganadas sin cobre ni oro (el cobre es solo de la llama).
struct HoyLayoutTests {
    /// Ancho del contenido de una tarjeta en un iPhone de 393 pt (16 de margen + 16 de relleno por lado).
    private let cardWidth: CGFloat = 393 - 32 - 32

    private typealias Item = MilestoneRowMetrics.Item

    // MARK: Hitos del camino del turno

    @Test func hitosCabenBajoSuDiaConLetraNormal() {
        // Anchos medidos a letra Large (caption2 semibold, 11 pt).
        let labels = [Item(column: 0, width: 33), Item(column: 1, width: 42), Item(column: 6, width: 57)]
        let minimum = MilestoneRowMetrics.minimumWidth(labels, columns: 7, spacing: 8)
        #expect(minimum <= cardWidth)
        // En el ancho mínimo ninguna se pisa ni se sale.
        let lefts = labels.map { MilestoneRowMetrics.leading($0, columns: 7, total: minimum) }
        #expect(lefts[0] == 0)
        #expect(lefts[1] >= lefts[0] + 33 + 8 - 0.001)
        #expect(lefts[2] >= lefts[1] + 42 + 8 - 0.001)
        #expect(abs(lefts[2] + 57 - minimum) < 0.001)
    }

    @Test func hitosConLetraGrandeNoCabenYPasanALaLinea() {
        // xxLarge (caption2 15 pt): "Partió" y "Doblete" se pegaban ("PartióDoblete").
        let labels = [Item(column: 0, width: 46), Item(column: 1, width: 58), Item(column: 6, width: 78)]
        #expect(MilestoneRowMetrics.minimumWidth(labels, columns: 7, spacing: 8) > cardWidth)
    }

    @Test func hitoDelMedioNoSeSaleDeLaTarjeta() {
        // Centrada en la columna 1 de 7: su mitad izquierda (30) debe caber en 1,5 columnas.
        let minimum = MilestoneRowMetrics.minimumWidth([Item(column: 1, width: 60)], columns: 7, spacing: 8)
        #expect(abs(minimum - 30 / (1.5 / 7)) < 0.001)
        #expect(MilestoneRowMetrics.leading(Item(column: 1, width: 60), columns: 7, total: minimum) >= -0.001)
    }

    @Test func hitoUnicoYSinHitos() {
        #expect(MilestoneRowMetrics.minimumWidth([], columns: 7, spacing: 8) == 0)
        #expect(MilestoneRowMetrics.minimumWidth([Item(column: 0, width: 40)], columns: 7, spacing: 8) == 40)
        #expect(MilestoneRowMetrics.leading(Item(column: 6, width: 57), columns: 7, total: 300) == 243)
    }

    // MARK: Momentos de hoy

    @Test func momentosPasanALaListaSiCampamentoNoCabe() {
        // Columnas: Entrada, Colación, Salida, Campamento (más el ícono de 42 pt).
        // Large: "Campamento" ~70 pt cabe en columnas de ~82 pt.
        #expect(EqualColumnsMetrics.idealWidth(columnWidths: [48, 53, 40, 70], minimumScale: 0.85) <= cardWidth)
        // xxxLarge: ~105 pt no cabe ni encogido al 85 %: la lista vertical.
        #expect(EqualColumnsMetrics.idealWidth(columnWidths: [72, 80, 60, 105], minimumScale: 0.85) > cardWidth)
        // Sin texto que encoja, manda la columna más ancha.
        #expect(EqualColumnsMetrics.idealWidth(columnWidths: [42, 42, 42, 42]) == 168)
        #expect(EqualColumnsMetrics.idealWidth(columnWidths: []) == 0)
        #expect(EqualColumnsMetrics.idealWidth(columnWidths: [10, 20], minimumScale: 2) == 40)
    }

    // MARK: Insignias en Hoy

    @Test func insigniasDeHoySinCobreNiOro() {
        for badge in Badge.allCases {
            let palette = badge.hoyPalette
            #expect(palette != ThemePalette.gold, "\(badge) en oro")
            // Frías: más azul que rojo, en claro y en oscuro (el cobre y el oro tienen r ≫ b).
            #expect(palette.light.b > palette.light.r, "\(badge) claro no es frío")
            #expect(palette.dark.b > palette.dark.r, "\(badge) oscuro no es frío")
            // El hexágono se dibuja con la variante clara: el símbolo blanco se lee (≥ 3:1, objeto gráfico).
            #expect(ThemeRGB.contrast(palette.light, .white) >= 3, "\(badge) sin contraste con el blanco")
        }
        #expect(Badge.doblete.hoyPalette == ThemePalette.accent)
        #expect(Badge.tiroLimpio.hoyPalette == ThemePalette.sky)
    }
}
