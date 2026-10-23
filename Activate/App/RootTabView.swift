import SwiftUI

/// Pestañas de la app (también las usa el arranque de QA: `-qa-tab home|stats|profile`).
nonisolated enum RootTab: String, Hashable, CaseIterable, Sendable {
    case home, stats, profile

    /// Acepta el nombre en inglés o en español ("hoy", "estadisticas", "perfil").
    init?(argument: String) {
        switch argument.lowercased().folding(options: .diacriticInsensitive, locale: nil) {
        case "home", "hoy": self = .home
        case "stats", "estadisticas": self = .stats
        case "profile", "perfil": self = .profile
        default: return nil
        }
    }
}

/// Tres pestañas: Hoy · Estadísticas · Perfil. La pausa corre en fullScreenCover sin tab bar.
/// En día de turno sin pausa contada, un accesorio discreto sobre la barra recuerda la próxima pausa
/// (fuera de Hoy, que ya la muestra en su tarjeta).
struct RootTabView: View {
    @Environment(AppStore.self) private var store
    @Environment(GameStore.self) private var game
    @Environment(CoachService.self) private var coach
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: RootTab

    init(initialTab: RootTab = .home) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Hoy", systemImage: "sun.max.fill", value: RootTab.home) { HomeView() }
            Tab("Estadísticas", systemImage: "chart.bar.fill", value: RootTab.stats) { StatsView() }
            Tab("Perfil", systemImage: "person.fill", value: RootTab.profile) { ProfileView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: showsNextPause) {
            NextPauseAccessory { selection = .home }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                game.applyDayRollover()
                coach.refreshAvailability()
            }
        }
        .task {
            game.applyDayRollover()
            coach.refreshAvailability()
        }
    }

    /// Solo en día de turno, sin pausa contada y fuera de Hoy.
    private var showsNextPause: Bool {
        Self.showsNextPause(isTurnoToday: game.isTurnoToday, pausedToday: game.pausedToday, tab: selection)
    }

    nonisolated static func showsNextPause(isTurnoToday: Bool, pausedToday: Bool, tab: RootTab) -> Bool {
        isTurnoToday && !pausedToday && tab != .home
    }
}

/// "Próxima: colación · 3 min". Tocarlo lleva a Hoy, donde está el botón de la pausa.
struct NextPauseAccessory: View {
    @Environment(AppStore.self) private var store
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let onTap: () -> Void

    var body: some View {
        TimelineView(.everyMinute) { context in
            let moment = Moment.infer(date: context.date, shift: store.profile.shiftType)
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: MomentCard.symbol(for: moment))
                        .foregroundStyle(Theme.accent)
                    Text(NextPauseAccessory.text(for: moment, compact: placement == .inline))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Próxima pausa: \(moment.title), \(moment.minutes) minutos")
            .accessibilityHint("Abre Hoy")
        }
    }

    /// "Próxima: relevo de entrada · 1 min" (compacto: "Relevo de entrada · 1 min").
    nonisolated static func text(for moment: Moment, compact: Bool) -> String {
        let title = moment.title
        if compact { return "\(title) · \(moment.minutes) min" }
        let lowered = title.prefix(1).lowercased() + title.dropFirst()
        return "Próxima: \(lowered) · \(moment.minutes) min"
    }
}
