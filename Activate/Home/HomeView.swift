import SwiftUI

/// Pantalla Hoy: saludo, racha y cascos, tira del turno, una sola acción para el momento actual
/// y dos secundarias ("Solo tengo 1 minuto", "Me duele ahora"). Todo plano; vidrio solo en controles.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(GameStore.self) private var game
    @Environment(CoachService.self) private var coach
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeMoment: Moment?
    @State private var showPainSheet = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .appScreen()
        .fullScreenCover(item: $activeMoment, onDismiss: { DailyNotice.refresh(store: store) }) { moment in
            PauseFlowView(moment: moment)
        }
        .sheet(isPresented: $showPainSheet) {
            PainNowSheet()
        }
        .sensoryFeedback(.success, trigger: painLogsToday)
        .task {
            await DailyNotice.schedule(for: store.profile, store: store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { DailyNotice.refresh(store: store) }
        }
    }

    private func content(now: Date) -> some View {
        let calendar = store.calendar
        let isRestDay = calendar.kind(for: now) == .descanso
        let moment = Moment.infer(date: now, shift: store.profile.shiftType)
        let recipe = Recipes.base(moment.recipe, demo: store.data.demo.shortTargets)

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StreakChips()

                Text(greeting(isRestDay: isRestDay))
                    .font(.largeTitle.weight(.heavy))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                ShiftStrip()

                MomentCard(moment: moment,
                           recipe: recipe,
                           pausedToday: game.pausedToday,
                           isRestDay: isRestDay) {
                    start(moment)
                }

                secondaryRow

                if let line = painLoggedLine(now: now) {
                    Label(line, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }

    private var secondaryRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                oneMinuteButton
                painNowButton
            }
            VStack(spacing: 12) {
                oneMinuteButton
                painNowButton
            }
        }
    }

    private var oneMinuteButton: some View {
        SecondaryButton(title: "Solo tengo 1 minuto", systemImage: "timer") {
            start(.entrada)
        }
    }

    private var painNowButton: some View {
        SecondaryButton(title: "Me duele ahora", systemImage: "bolt.heart.fill") {
            showPainSheet = true
        }
    }

    private func start(_ moment: Moment) {
        coach.prewarm()
        activeMoment = moment
    }

    private func greeting(isRestDay: Bool) -> String {
        let name = store.profile.name.trimmingCharacters(in: .whitespaces)
        let who = name.isEmpty ? "" : ", \(name)"
        return isRestDay ? "Buen descanso\(who)." : "Buen turno\(who)."
    }

    /// Registros "Me duele ahora" de hoy (dispara la háptica de confirmación al guardar).
    private var painLogsToday: Int {
        let todayKey = store.calendar.key(for: .now)
        return store.data.checkIns.filter { $0.source == .meDueleAhora && $0.workDayKey == todayKey }.count
    }

    private func painLoggedLine(now: Date) -> String? {
        let todayKey = store.calendar.key(for: now)
        guard let last = store.data.checkIns.last(where: { $0.source == .meDueleAhora && $0.workDayKey == todayKey }) else {
            return nil
        }
        if let context = last.context {
            return "Dolor registrado hoy · \(context.title)"
        }
        return "Dolor registrado hoy"
    }
}
