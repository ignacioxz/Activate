import Foundation

// Dueño: agente "stats-engine". Stub con firma congelada.

nonisolated enum StatsEngine {
    static func summary(data: SaveData, calendar: WorkCalendar, now: Date) -> StatsSummary {
        StatsSummary(currentTurno: nil, previousTurno: nil, turnos: [], streak: 0, totalCountedPauses: 0,
                     todayRDQ: nil, recentSessions: [], worsensHints: [], historyLines: [], currentTurnoDays: [])
    }
}
