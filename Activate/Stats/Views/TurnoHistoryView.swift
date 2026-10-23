import SwiftUI

// Dueño: agente "stats-ui". Lista plana de pausas agrupadas por día laboral → SessionDetailView.

/// Lista de sesiones (ya filtradas por el selector) agrupadas por día laboral, de la más reciente a la más antigua.
struct TurnoHistoryView: View {
    let digests: [SessionDigest]
    @Environment(AppStore.self) private var store

    private struct DayGroup: Identifiable {
        var key: String
        var title: String
        var subtitle: String?
        var digests: [SessionDigest]
        var id: String { key }
    }

    private var groups: [DayGroup] {
        let calendar = store.calendar
        let byDay = Dictionary(grouping: digests, by: \.workDayKey)
        return byDay.keys.sorted(by: >).map { key in
            let rows = (byDay[key] ?? []).sorted { $0.date > $1.date }
            guard let midnight = calendar.date(forKey: key),
                  let inside = calendar.calendar.date(byAdding: .hour, value: calendar.boundaryHour, to: midnight) else {
                return DayGroup(key: key, title: key, subtitle: nil, digests: rows)
            }
            let dateText = midnight.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            let title = calendar.kind(for: inside) == .turno
                ? "Día \(calendar.dayInBlock(for: inside)) de turno"
                : "Descanso"
            return DayGroup(key: key, title: title, subtitle: dateText, digests: rows)
        }
    }

    private var sessionsByID: [UUID: PauseSession] {
        Dictionary(store.data.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        if digests.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Sin pausas en este período.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .flatCard()
        } else {
            let sessions = sessionsByID
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(group.title).font(.title3.weight(.bold))
                            if let subtitle = group.subtitle {
                                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.bottom, 6)
                        ForEach(Array(group.digests.enumerated()), id: \.element.id) { index, digest in
                            if let session = sessions[digest.id] {
                                NavigationLink {
                                    SessionDetailView(session: session)
                                } label: {
                                    SessionRow(digest: digest, showsChevron: true)
                                }
                                .buttonStyle(.plain)
                            } else {
                                SessionRow(digest: digest, showsChevron: false)
                                    .opacity(0.6)
                            }
                            if index < group.digests.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .flatCard()
                }
            }
        }
    }
}

/// Fila de una pausa: momento, hora, nivel y cierre.
private struct SessionRow: View {
    let digest: SessionDigest
    var showsChevron: Bool

    private var subtitle: String {
        var parts = [digest.date.formatted(.dateTime.hour().minute()), digest.level.title]
        if let score = digest.checkInScore { parts.append("RDQ \(score)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: StatsLevelStyle.symbol(digest.level))
                .font(.title2)
                .foregroundStyle(StatsLevelStyle.color(digest.level))
                .frame(minWidth: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(digest.moment.title) · \(digest.recipe.minutes) min")
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !digest.activityKinds.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(digest.activityKinds.enumerated()), id: \.offset) { _, kind in
                            Image(systemName: kind.symbol)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(digest.activityKinds.map(\.name).joined(separator: ", "))
                }
            }
            Spacer(minLength: 8)
            if let post = digest.post {
                Text(post.title)
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(StatsLevelStyle.postColor(post).opacity(0.22), in: .capsule)
                    .accessibilityLabel("Después: \(post.title)")
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: Theme.rowHeight)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
