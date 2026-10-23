import Foundation
import UserNotifications

/// Una parada de la ruta diaria (≈3 minutos).
struct RouteStop: Identifiable, Hashable {
    let index: Int
    let dayKey: String
    let title: String
    let symbol: String
    /// Hora sugerida en minutos desde la medianoche.
    let minutes: Int
    let lesson: Lesson

    var id: String { "\(dayKey)-\(index)" }
    var timeText: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

/// Genera una ruta realizable cada día: 3 paradas cortas repartidas en el turno.
/// Los ejercicios rotan día a día para dar variedad.
enum DailyRoute {
    static let defaultTimes = [8 * 60 + 30, 13 * 60, 18 * 60 + 30]

    private static let stopInfo = [
        ("Inicio de turno", "sunrise.fill"),
        ("Colación", "fork.knife"),
        ("Fin de turno", "moon.stars.fill")
    ]

    private static let pools: [[[Exercise]]] = [
        [
            [Catalog.brazos.with(target: 8), Catalog.giro.with(target: 8)],
            [Catalog.lateral.with(target: 8), Catalog.brazos.with(target: 6)],
            [Catalog.giro.with(target: 10)]
        ],
        [
            [Catalog.caminata.with(target: 300)],
            [Catalog.caminata.with(target: 200)],
            [Catalog.caminata.with(target: 250)]
        ],
        [
            [Catalog.sentadilla.with(target: 8), Catalog.lateral.with(target: 8)],
            [Catalog.giro.with(target: 10), Catalog.brazos.with(target: 6)],
            [Catalog.sentadilla.with(target: 6), Catalog.giro.with(target: 8)]
        ]
    ]

    static func stops(for date: Date, kind: DayKind, times: [Int]) -> [RouteStop] {
        let key = GameStore.dayKey(date)
        if kind == .descanso {
            let lesson = Lesson(id: "route-\(key)-0", title: "Caminata libre", symbol: "beach.umbrella.fill",
                                exercises: [Catalog.caminata.with(target: 500)])
            return [RouteStop(index: 0, dayKey: key, title: "Caminata libre", symbol: "beach.umbrella.fill",
                              minutes: 11 * 60, lesson: lesson)]
        }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        return (0..<3).map { i in
            let pool = pools[i]
            let (title, symbol) = stopInfo[i]
            let lesson = Lesson(id: "route-\(key)-\(i)", title: title, symbol: symbol,
                                exercises: pool[(day + i) % pool.count])
            let minutes = i < times.count ? times[i] : defaultTimes[i]
            return RouteStop(index: i, dayKey: key, title: title, symbol: symbol, minutes: minutes, lesson: lesson)
        }
    }
}

/// Recordatorios locales de la ruta. Se programan en el iPhone, así que funcionan
/// sin señal en la faena (no dependen de un servidor).
enum NotificationScheduler {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func reschedule(for store: GameStore) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard store.data.notificationsEnabled else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let streak = store.streak

        // 7 días × 4 avisos = 28, bajo el límite de 64 notificaciones pendientes de iOS.
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  store.dayKind(for: day) == .turno else { continue }
            let stops = store.route(for: day)

            for stop in stops where !store.isDone(stop) {
                guard let fire = calendar.date(byAdding: .minute, value: stop.minutes, to: day), fire > now else { continue }
                let content = UNMutableNotificationContent()
                content.title = "⛑️ \(stop.title): pausa de 3 min"
                content.body = streak > 0
                    ? "Mantén tu racha de \(streak) 🔥. Guarda el iPhone en el bolsillo y sigue la voz."
                    : "Tu espalda te lo agradece. Guarda el iPhone en el bolsillo y sigue la voz."
                content.sound = .default
                await add(id: "stop-\(stop.id)", content: content, date: fire, center: center)
            }

            // Aviso de rescate una hora después de la última parada, si ese día no hubo pausa.
            let pausedThatDay = store.record(for: day).pausesDone > 0 || store.record(for: day).usedShield
            if !pausedThatDay, let last = stops.last,
               let fire = calendar.date(byAdding: .minute, value: last.minutes + 60, to: day), fire > now {
                let content = UNMutableNotificationContent()
                content.title = "¿No alcanzaste hoy?"
                content.body = "Haz el rescate de 60 s en tu habitación o usa un casco 🪖 para salvar tu racha."
                content.sound = .default
                await add(id: "rescue-\(GameStore.dayKey(day))", content: content, date: fire, center: center)
            }
        }
    }

    private static func add(id: String, content: UNMutableNotificationContent, date: Date,
                            center: UNUserNotificationCenter) async {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
