import Foundation
import Observation

// Dueño: agente "gamification". Stub con firma congelada.

nonisolated struct RewardLine: Sendable, Hashable, Identifiable, Codable {
    var id: UUID = UUID()
    var label: String
    var xp: Int
}

nonisolated struct SessionReward: Sendable, Hashable, Codable {
    var lines: [RewardLine]
    var totalXP: Int
    var counted: Bool
    var streak: Int
    var dayInBlock: Int
    var isDoblete: Bool
    var isTiroLimpio: Bool
    var newBadges: [Badge]
}

/// Racha por día laboral, casco automático, XP e insignias sobre `AppStore`.
@Observable
final class GameStore {
    private let store: AppStore
    init(store: AppStore) { self.store = store }

    var calendar: WorkCalendar { store.calendar }
    var todayKey: String { calendar.key(for: .now) }
    var streak: Int { 0 }
    var cascos: Int { store.data.profile.cascos }
    var xp: Int { store.data.profile.xp }
    var pausedToday: Bool { (store.data.workDays[todayKey]?.countedPauses ?? 0) > 0 }

    /// Cierra días laborales pasados sin pausa (casco automático). Llamar al arrancar y al volver a activo.
    func applyDayRollover(now: Date = .now) {}

    /// Registra la sesión, calcula XP, racha, Doblete, insignias y la guarda en el store.
    func record(_ session: PauseSession) -> SessionReward {
        SessionReward(lines: [], totalXP: 0, counted: session.counted, streak: 0, dayInBlock: calendar.dayInBlock(for: .now), isDoblete: false, isTiroLimpio: false, newBadges: [])
    }
}
