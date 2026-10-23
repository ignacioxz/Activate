import Foundation
import UserNotifications

/// Aviso local opt-in: como máximo 1 por día laboral, al inicio de la ventana campamento
/// (20:30 turno de día / 08:30 turno de noche), solo si ese día no tiene pausa contada.
/// Texto: "Le queda el campamento. Día N está a 5 minutos."
/// Funciona sin señal (se programa en el iPhone). Nunca toca avisos de otros módulos.
enum DailyNotice {
    nonisolated struct Notice: Sendable, Hashable, Identifiable {
        var id: String
        var workDayKey: String
        var dayInBlock: Int
        var fireDate: Date
        var title: String
        var body: String
    }

    nonisolated static let identifierPrefix = "daily-notice-"
    nonisolated static let threadIdentifier = "daily-notice"
    nonisolated static let title = "Le queda el campamento."

    /// Inicio de la ventana campamento (coincide con `Moment.infer`).
    nonisolated static let dayShiftNoticeHour = 20
    nonisolated static let dayShiftNoticeMinute = 30
    nonisolated static let nightShiftNoticeHour = 8
    nonisolated static let nightShiftNoticeMinute = 30

    /// Días hacia adelante que se dejan programados (el rajo no tiene señal; el aviso es local).
    nonisolated static let lookaheadDays = 7

    // MARK: - API

    /// Programa los avisos pendientes según el estado actual. Idempotente: reemplaza los suyos.
    static func schedule(for profile: PlayerProfile, store: AppStore) async {
        let center = UNUserNotificationCenter.current()
        let notices = plan(profile: profile, data: store.data, now: .now, calendar: WorkCalendar(profile: profile))
        await removeOwnPending(from: center)
        guard !notices.isEmpty else { return }
        guard await isAuthorized(center) else { return }

        let calendar = Calendar.current
        for notice in notices {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = .default
            content.threadIdentifier = threadIdentifier
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: notice.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: trigger))
        }
    }

    /// Reprograma en segundo plano (al cerrar una pausa, al volver a activo).
    static func refresh(store: AppStore) {
        let profile = store.profile
        Task { await schedule(for: profile, store: store) }
    }

    /// Quita todos los avisos de este módulo (opt-out, demo silenciada).
    static func cancelAll() {
        Task { await removeOwnPending(from: UNUserNotificationCenter.current()) }
    }

    // MARK: - Lógica pura (testeable)

    /// Instante del aviso para un día laboral (medianoche calendario de `workDate`).
    nonisolated static func fireDate(forWorkDate workDate: Date, shift: ShiftType, calendar: Calendar) -> Date? {
        switch shift {
        case .day:
            return calendar.date(bySettingHour: dayShiftNoticeHour, minute: dayShiftNoticeMinute, second: 0, of: workDate)
        case .night:
            guard let next = calendar.date(byAdding: .day, value: 1, to: workDate) else { return nil }
            return calendar.date(bySettingHour: nightShiftNoticeHour, minute: nightShiftNoticeMinute, second: 0, of: next)
        }
    }

    nonisolated static func body(dayInBlock: Int) -> String {
        "Día \(dayInBlock) está a 5 minutos."
    }

    /// La demo silencia los avisos solo mientras está activa: `notificationsMuted` vale `true`
    /// por defecto y, sin demo, no debe bloquear el aviso real.
    nonisolated static func isMutedByDemo(_ demo: DemoConfig) -> Bool {
        demo.enabled && demo.notificationsMuted
    }

    /// Avisos a programar: uno por día laboral de turno en los próximos `lookaheadDays`,
    /// solo si hay opt-in, la demo (activa) no los silencia, el instante es futuro y el día no tiene pausa contada.
    nonisolated static func plan(profile: PlayerProfile, data: SaveData, now: Date, calendar: WorkCalendar) -> [Notice] {
        guard profile.notificationsOptIn, !isMutedByDemo(data.demo) else { return [] }
        var seen: Set<String> = []
        var notices: [Notice] = []
        for offset in 0..<lookaheadDays {
            guard let probe = calendar.calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            guard calendar.kind(for: probe) == .turno else { continue }
            let key = calendar.key(for: probe)
            guard seen.insert(key).inserted else { continue }
            guard (data.workDays[key]?.countedPauses ?? 0) == 0 else { continue }
            guard let fire = fireDate(forWorkDate: calendar.workDate(for: probe), shift: profile.shiftType, calendar: calendar.calendar),
                  fire > now else { continue }
            let day = calendar.dayInBlock(for: probe)
            notices.append(Notice(id: identifierPrefix + key,
                                  workDayKey: key,
                                  dayInBlock: day,
                                  fireDate: fire,
                                  title: title,
                                  body: body(dayInBlock: day)))
        }
        return notices
    }

    // MARK: - UNUserNotificationCenter

    private static func removeOwnPending(from center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        guard !ours.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    private static func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
