import Testing
import Foundation
@testable import Activate

struct PlanWhyTests {
    private func checkIn(_ answers: [Bool], zones: [PainZone]) -> DailyCheckIn {
        var c = DailyCheckIn(date: .now, workDayKey: "2026-10-23", turnoKey: "2026-10-22", source: .pausa,
                             answers: answers, zone: .lumbar)
        c.setZones(zones)
        return c
    }

    @Test func todoEnNoYSinDolorNoMencionaZonas() {
        let c = checkIn(Array(repeating: false, count: 6), zones: [])
        let d = SafetyRules.evaluate(checkIn: c)
        let why = PlanWhy.compose(decision: d, checkIn: c, cameraBlocked: false)
        #expect(why == PlanWhy.noPain)
        #expect(!why.lowercased().contains("espalda"))
    }

    @Test func puntajeCeroConZonaIgualEsSinMolestias() {
        let c = checkIn(Array(repeating: false, count: 6), zones: [.lumbar])
        let why = PlanWhy.compose(decision: SafetyRules.evaluate(checkIn: c), checkIn: c, cameraBlocked: false)
        #expect(why == PlanWhy.noPain)
    }

    @Test func evitaAgacharseLoDice() {
        let c = checkIn([false, false, false, true, false, false], zones: [.lumbar])
        let why = PlanWhy.compose(decision: SafetyRules.evaluate(checkIn: c), checkIn: c, cameraBlocked: false)
        #expect(why.hasPrefix(PlanWhy.noBending))
    }

    @Test func planSuaveTienePrioridad() {
        let c = checkIn([true, true, true, true, true, false], zones: [.lumbar, .cuello])
        let why = PlanWhy.compose(decision: SafetyRules.evaluate(checkIn: c), checkIn: c, cameraBlocked: false)
        #expect(why.hasPrefix(PlanWhy.gentle))
    }

    @Test func mensajeDelModeloConZonasSeDescarta() {
        #expect(PlanWhy.sanitizedStartMessage("Menos espalda baja hoy") == nil)
        #expect(PlanWhy.sanitizedStartMessage("Vamos, Marco. Tres minutos.") == "Vamos, Marco. Tres minutos.")
        #expect(PlanWhy.sanitizedStartMessage("") == nil)
    }
}
