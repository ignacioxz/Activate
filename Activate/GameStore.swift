import Foundation
import Observation

/// Datos persistidos del jugador.
struct SaveData: Codable {
    var xp = 0
    var nuggets = 0
    var shields = 1
    var totalPauses = 0
    var completedLessons: [String: Int] = [:]
    var days: [String: DayRecord] = [:]
    var pain: [PainEntry] = []
    var badges: Set<Badge> = []
    var claimedGoals: Set<String> = []
    var roster: Roster = .sieteXSiete
    var rosterStart: Date = Calendar.current.startOfDay(for: .now)
    var completedStops: Set<String> = []
    var notificationsEnabled = false
    /// Horas de las 3 paradas, en minutos desde la medianoche.
    var stopTimes: [Int] = DailyRoute.defaultTimes
}

/// Lógica de gamificación: XP, racha por turnos, cascos protectores e insignias.
@Observable
final class GameStore {
    static let maxShields = 3
    static let xpPerLevel = 150
    private static let storageKey = "pausaminera.save.v2"

    private(set) var data: SaveData {
        didSet { if persists { save() } }
    }

    @ObservationIgnored private let persists: Bool
    private let calendar = Calendar.current

    init(inMemory: Bool = false) {
        persists = !inMemory
        if !inMemory,
           let raw = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(SaveData.self, from: raw) {
            data = saved
        } else {
            data = SaveData()
        }
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(raw, forKey: Self.storageKey)
        }
    }

    // MARK: - Fechas y turnos

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func record(for date: Date) -> DayRecord {
        data.days[Self.dayKey(date)] ?? DayRecord()
    }

    private func cycleIndex(for date: Date) -> Int {
        let start = calendar.startOfDay(for: data.rosterStart)
        let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
        let cycle = data.roster.workDays + data.roster.restDays
        return ((days % cycle) + cycle) % cycle
    }

    func dayKind(for date: Date) -> DayKind {
        cycleIndex(for: date) < data.roster.workDays ? .turno : .descanso
    }

    /// Número de día dentro del bloque actual (turno o descanso), empezando en 1.
    func blockDayNumber(for date: Date) -> Int {
        let index = cycleIndex(for: date)
        return index < data.roster.workDays ? index + 1 : index - data.roster.workDays + 1
    }

    private func previousDay(_ date: Date) -> Date {
        calendar.date(byAdding: .day, value: -1, to: date) ?? date
    }

    // MARK: - Progreso

    var level: Int { data.xp / Self.xpPerLevel + 1 }

    var levelProgress: Double {
        Double(data.xp % Self.xpPerLevel) / Double(Self.xpPerLevel)
    }

    var rankName: String {
        let ranks = ["Aprendiz", "Operador", "Operador experto", "Capataz", "Jefe de turno", "Superintendente"]
        return ranks[min(ranks.count - 1, (level - 1) / 2)]
    }

    /// Racha de días de turno con pausa. Los días de descanso no cortan ni suman,
    /// y los días con casco protector mantienen la racha sin sumar.
    var streak: Int {
        var date = Date.now
        if record(for: date).pausesDone == 0 { date = previousDay(date) }
        var count = 0
        for _ in 0..<400 {
            if dayKind(for: date) == .turno {
                let r = record(for: date)
                if r.pausesDone > 0 {
                    count += 1
                } else if !r.usedShield {
                    break
                }
            }
            date = previousDay(date)
        }
        return count
    }

    var pausedToday: Bool { record(for: .now).pausesDone > 0 }

    /// Ayer hubo pausa y hoy aún no: la próxima pausa es un «Doblete» con XP x2.
    var dobleteAvailable: Bool {
        !pausedToday && record(for: previousDay(.now)).pausesDone > 0
    }

    func isCompleted(_ lesson: Lesson) -> Bool {
        (data.completedLessons[lesson.id] ?? 0) > 0
    }

    func isUnlocked(_ lesson: Lesson) -> Bool {
        let all = Catalog.allLessons
        guard let index = all.firstIndex(of: lesson), index > 0 else { return true }
        return isCompleted(all[index - 1])
    }

    // MARK: - Ruta diaria

    func route(for date: Date) -> [RouteStop] {
        DailyRoute.stops(for: date, kind: dayKind(for: date), times: data.stopTimes)
    }

    var todayRoute: [RouteStop] { route(for: .now) }

    func isDone(_ stop: RouteStop) -> Bool {
        data.completedStops.contains(stop.id)
    }

    /// Primera parada pendiente de hoy (la que se destaca en la ruta).
    var nextStop: RouteStop? {
        todayRoute.first { !isDone($0) }
    }

    func setNotifications(_ enabled: Bool) {
        data.notificationsEnabled = enabled
    }

    func setStopTime(index: Int, minutes: Int) {
        guard data.stopTimes.indices.contains(index) else { return }
        data.stopTimes[index] = minutes
    }

    // MARK: - Acciones

    func completeSession(lessonID: String, baseXP: Int, adaptedForPain: Bool) -> SessionReward {
        var d = data
        let todayKey = Self.dayKey(.now)
        var today = d.days[todayKey] ?? DayRecord()
        let firstToday = today.pausesDone == 0
        let yesterdayDone = record(for: previousDay(.now)).pausesDone > 0

        var lines = [RewardLine(label: "Ejercicios", xp: baseXP)]
        var total = baseXP
        if firstToday {
            lines.append(RewardLine(label: "Primera pausa del día", xp: 10))
            total += 10
        }
        if adaptedForPain {
            lines.append(RewardLine(label: "Te cuidaste con dolor", xp: 5))
            total += 5
        }
        let isDoblete = firstToday && yesterdayDone
        if isDoblete {
            lines.append(RewardLine(label: "¡Doblete! Dos días seguidos (x2)", xp: total))
            total *= 2
        }

        // Paradas de la ruta diaria: se marcan y, si es la última, dan bonus.
        var routeCompleted = false
        if lessonID.hasPrefix("route-") {
            d.completedStops.insert(String(lessonID.dropFirst("route-".count)))
            let route = todayRoute
            routeCompleted = route.allSatisfy { d.completedStops.contains($0.id) }
            if routeCompleted {
                lines.append(RewardLine(label: "¡Ruta del día completa!", xp: 30))
                total += 30
            }
        } else {
            d.completedLessons[lessonID, default: 0] += 1
        }

        today.pausesDone += 1
        d.days[todayKey] = today
        d.totalPauses += 1
        d.xp += total
        let nuggets = max(1, total / 5)
        d.nuggets += nuggets

        var shieldEarned = false
        if d.totalPauses % 3 == 0 && d.shields < Self.maxShields {
            d.shields += 1
            shieldEarned = true
        }

        var newBadges: [Badge] = []
        func unlock(_ badge: Badge, if condition: Bool) {
            if condition && d.badges.insert(badge).inserted { newBadges.append(badge) }
        }
        unlock(.primeraPausa, if: d.totalPauses >= 1)
        unlock(.diezPausas, if: d.totalPauses >= 10)
        unlock(.doblete, if: isDoblete)
        unlock(.cuidado, if: adaptedForPain)
        unlock(.rutaCompleta, if: routeCompleted)
        data = d
        unlock(.racha5, if: streak >= 5)
        data.badges = d.badges

        return SessionReward(lines: lines, totalXP: total, nuggets: nuggets, shieldEarned: shieldEarned,
                             newBadges: newBadges, streak: streak)
    }

    /// «Hoy no alcancé»: usa un casco protector para no perder la racha.
    @discardableResult
    func useShield() -> Bool {
        let key = Self.dayKey(.now)
        var today = data.days[key] ?? DayRecord()
        guard data.shields > 0, today.pausesDone == 0, !today.usedShield else { return false }
        today.usedShield = true
        var d = data
        d.days[key] = today
        d.shields -= 1
        data = d
        return true
    }

    func logPain(level: Int, context: PainContext, date: Date = .now) {
        var d = data
        d.pain.append(PainEntry(date: date, level: level, context: context))
        let distinctDays = Set(d.pain.map { Self.dayKey($0.date) })
        if distinctDays.count >= 5 { d.badges.insert(.honestidad) }
        data = d
    }

    func maxPain(on date: Date) -> Int? {
        let key = Self.dayKey(date)
        return data.pain.filter { Self.dayKey($0.date) == key }.map(\.level).max()
    }

    func isClaimed(_ goal: ActivityGoal) -> Bool {
        data.claimedGoals.contains("\(goal.rawValue)-\(Self.dayKey(.now))")
    }

    /// Entrega el premio de una meta diaria de pasos o pisos.
    func claim(_ goal: ActivityGoal, steps: Int, floors: Int) {
        guard !isClaimed(goal) else { return }
        var d = data
        d.claimedGoals.insert("\(goal.rawValue)-\(Self.dayKey(.now))")
        d.xp += goal.xp
        d.nuggets += goal.xp / 5
        if steps >= 10_000 { d.badges.insert(.caminante) }
        if floors >= 10 { d.badges.insert(.escalador) }
        data = d
    }

    func setRoster(_ roster: Roster, start: Date) {
        data.roster = roster
        data.rosterStart = calendar.startOfDay(for: start)
    }

    func reset() {
        var d = SaveData()
        d.notificationsEnabled = data.notificationsEnabled
        d.stopTimes = data.stopTimes
        data = d
    }

    /// Clave que cambia cuando hay que reprogramar los recordatorios.
    var notificationKey: String {
        let today = record(for: .now)
        return "\(data.notificationsEnabled)-\(data.stopTimes)-\(data.roster.rawValue)-\(data.rosterStart.timeIntervalSince1970)-\(data.completedStops.count)-\(today.pausesDone)-\(today.usedShield)"
    }

    /// Carga la semana de ejemplo del caso de dolor lumbar:
    /// D1 pausa sí · D2 «Hoy no alcancé» · D3 dolor al levantar carga 4/5 ·
    /// D5 peak de dolor 5/5 · D7 bajada a Antofagasta (descanso). Hoy es D7.
    func loadDemoWeek() {
        var d = SaveData()
        let today = calendar.startOfDay(for: .now)
        func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n - 7, to: today) ?? today }
        func at(_ n: Int, hour: Int) -> Date { calendar.date(byAdding: .hour, value: hour, to: day(n)) ?? day(n) }

        d.roster = .sieteXSiete
        d.rosterStart = calendar.date(byAdding: .day, value: -1, to: day(1)) ?? today
        d.days[Self.dayKey(day(1))] = DayRecord(pausesDone: 1)
        d.days[Self.dayKey(day(2))] = DayRecord(pausesDone: 0, usedShield: true)
        d.days[Self.dayKey(day(4))] = DayRecord(pausesDone: 1)
        d.pain = [
            PainEntry(date: at(1, hour: 9), level: 3, context: .general),
            PainEntry(date: at(3, hour: 11), level: 4, context: .levantarCarga),
            PainEntry(date: at(5, hour: 16), level: 5, context: .peakTurno)
        ]
        d.totalPauses = 2
        d.xp = 95
        d.nuggets = 19
        d.shields = 0
        d.completedLessons = ["l1": 1]
        d.completedStops = ["\(Self.dayKey(day(1)))-0", "\(Self.dayKey(day(4)))-1"]
        d.badges = [.primeraPausa]
        d.notificationsEnabled = data.notificationsEnabled
        d.stopTimes = data.stopTimes
        data = d
    }
}
