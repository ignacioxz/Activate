import SwiftUI

/// Pantalla Hoy: saludo, racha y comodín, tira del turno, una sola acción para el momento actual
/// y dos secundarias ("Solo tengo 1 minuto", "Me duele ahora"). Todo plano; vidrio solo en controles.
/// Sin consentimiento, empezar una pausa abre primero el consentimiento y, al aceptar, sigue con la pausa.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(GameStore.self) private var game
    @Environment(CoachService.self) private var coach
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeMoment: Moment?
    @State private var showPainSheet = false
    /// Pausa pedida sin consentimiento: se muestra `ConsentView` en una hoja.
    @State private var consentFor: Moment?
    /// Pausa que arranca cuando se cierra la hoja de consentimiento aceptado.
    @State private var startAfterConsent: Moment?

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
        // Acento azul en toda la pantalla y en lo que presenta (pausa, hojas): el cobre queda solo para la llama.
        .tint(Theme.accent)
    }

    private func content(now: Date) -> some View {
        let calendar = store.calendar
        let isRestDay = calendar.kind(for: now) == .descanso
        let moment = Moment.infer(date: now, shift: store.profile.shiftType)
        let recipe = Recipes.base(moment.recipe, demo: store.data.demo.shortTargets)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(greeting(isRestDay: isRestDay))
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    StreakChips()
                }

                ShiftStrip()

                MomentCard(moment: moment,
                           recipe: recipe,
                           pausedToday: game.pausedToday,
                           isRestDay: isRestDay) {
                    requestStart(moment)
                }

                secondaryRow

                if let line = painLoggedLine(now: now) {
                    Label(line, systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheet(item: $consentFor, onDismiss: startPendingPause) { moment in
            NavigationStack {
                ConsentView(onAccept: { startAfterConsent = moment })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cerrar") { consentFor = nil }
                        }
                    }
            }
        }
    }

    /// Dos acciones secundarias compactas (cápsulas de vidrio) bajo la tarjeta; se apilan con letra grande.
    private var secondaryRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                oneMinuteButton(fill: false)
                painNowButton(fill: false)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 8) {
                oneMinuteButton(fill: true)
                painNowButton(fill: true)
            }
        }
    }

    private func oneMinuteButton(fill: Bool) -> some View {
        QuickActionButton(title: "Solo tengo 1 minuto", systemImage: "timer", fill: fill) {
            requestStart(.entrada)
        }
    }

    private func painNowButton(fill: Bool) -> some View {
        QuickActionButton(title: "Me duele ahora", systemImage: "bolt.heart", fill: fill) {
            showPainSheet = true
        }
    }

    /// Sin consentimiento no se abre la pausa (usa la cámara y datos de salud): primero el consentimiento.
    private func requestStart(_ moment: Moment) {
        if Self.needsConsent(store.profile) {
            consentFor = moment
        } else {
            start(moment)
        }
    }

    /// Al cerrarse la hoja: si se aceptó, arranca la pausa pedida (después de cerrar, para no
    /// presentar la pausa mientras la hoja todavía se está yendo).
    private func startPendingPause() {
        guard let moment = startAfterConsent else { return }
        startAfterConsent = nil
        guard store.profile.consentGiven else { return }
        start(moment)
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

    // MARK: - Lógica pura

    /// La pausa usa la cámara y datos de salud: sin consentimiento expreso no se abre.
    nonisolated static func needsConsent(_ profile: PlayerProfile) -> Bool {
        !profile.consentGiven
    }
}

/// Acción secundaria compacta de Hoy: cápsula de vidrio funcional, texto `.subheadline` y símbolo en el acento.
/// Más liviana que `SecondaryButton` para no competir con "Hacer la pausa" (una acción principal por pantalla).
/// Usa `functionalGlass`, así degrada a superficie opaca en modo exterior y con Reducir transparencia.
private struct QuickActionButton: View {
    let title: String
    let systemImage: String
    /// `true` ocupa todo el ancho (versión apilada); `false` usa su ancho natural (versión en fila).
    var fill: Bool = false
    let action: () -> Void

    static let height: CGFloat = 48

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(fill ? nil : 1)
                    .fixedSize(horizontal: !fill, vertical: fill)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: fill ? .infinity : nil, minHeight: Self.height)
            .contentShape(.capsule)
        }
        .buttonStyle(QuickActionStyle())
    }
}

private struct QuickActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .functionalGlass(in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
