import SwiftUI

/// Pantalla Hoy, el tablero del turno: encabezado ("Día 2 de 7" + "Me duele ahora"), meta de hoy
/// (anillo con la racha, hito en juego, lo que gana y "Hacer la pausa"), momentos de hoy, camino del
/// turno con el comodín, nivel, insignias y su espalda hoy. Todo plano; vidrio solo en controles.
/// Cada cifra sale de `HoyProgress.snapshot` (datos reales del store), nunca de valores fijos.
/// Sin consentimiento, empezar una pausa abre primero el consentimiento y, al aceptar, sigue con la pausa.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(CoachService.self) private var coach
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeMoment: Moment?
    @State private var showPainSheet = false
    /// Reporte de Salud (para el kinesiólogo o la mutual), abierto desde Hoy.
    @State private var showHealthReport = false
    /// Pausa pedida sin consentimiento: se muestra `ConsentView` en una hoja.
    @State private var consentFor: Moment?
    /// Pausa que arranca cuando se cierra la hoja de consentimiento aceptado.
    @State private var startAfterConsent: Moment?
    /// "Le ayuda más": el libro mayor de estadísticas se arma una vez por día laboral (y por pausa nueva),
    /// no cada minuto del `TimelineView`.
    @State private var helpCache = PerDayCache<ActivityKind?>()

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .appScreen()
        .fullScreenCover(item: $activeMoment, onDismiss: {
            Diagnostics.log("Hoy: la pausa se cerró")
            DailyNotice.refresh(store: store)
        }) { moment in
            PauseFlowView(moment: moment)
        }
        .sheet(isPresented: $showPainSheet) {
            PainNowSheet()
        }
        .sheet(isPresented: $showHealthReport) {
            NavigationStack {
                KineSheetScreen()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cerrar") { showHealthReport = false }
                        }
                    }
            }
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
        let snapshot = HoyProgress.snapshot(data: store.data, calendar: calendar, now: now)
        let moment = Moment.infer(date: now, shift: store.profile.shiftType)
        let help = bestHelp(calendar: calendar, now: now)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HoyHeader(title: snapshot.title, subtitle: snapshot.subtitle) {
                    showPainSheet = true
                }

                HoyGoalCard(goal: snapshot.goal,
                            route: snapshot.route,
                            routeMinutes: snapshot.routeMinutes,
                            momentTitle: moment.title,
                            onStart: { requestStart(moment) })

                if let moments = snapshot.moments {
                    HoyMomentsCard(moments: moments)
                }

                TurnoPathCard(path: snapshot.path, cascos: store.profile.cascos)

                HealthReportRow { showHealthReport = true }

                LevelCard(level: snapshot.level)

                BadgesCard(badges: snapshot.badges, earned: snapshot.earnedBadges)

                BackCard(back: snapshot.back, help: help)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            // Al volver de la pausa: el anillo se cierra, la racha y el XP cuentan; sin confeti (ya lo hizo la celebración).
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5), value: snapshot.goal.done)
            .animation(reduceMotion ? nil : .snappy, value: snapshot.level.progress)
        }
        .defaultScrollAnchor(Self.initialAnchor)
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

    /// Ejercicio verificado que más se repite en pausas que terminaron "Mejor" (dato, sin premio).
    private func bestHelp(calendar: WorkCalendar, now: Date) -> ActivityKind? {
        let key = "\(calendar.key(for: now))#\(store.data.sessions.count)"
        return helpCache.value(for: key) {
            StatsEngine.mostHelpfulActivity(ledger: StatsLedger(data: store.data, calendar: calendar))
        }
    }

    /// Solo QA (DEBUG): `-qa-scroll-bottom` abre Hoy al final para la segunda captura.
    private static var initialAnchor: UnitPoint {
        #if DEBUG
        return QALaunch.current.scrollBottom ? .bottom : .top
        #else
        return .top
        #endif
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

    /// Registros "Me duele ahora" de hoy (dispara la háptica de confirmación al guardar).
    private var painLogsToday: Int {
        let todayKey = store.calendar.key(for: .now)
        return store.data.checkIns.filter { $0.source == .meDueleAhora && $0.workDayKey == todayKey }.count
    }

    // MARK: - Lógica pura

    /// La pausa usa la cámara y datos de salud: sin consentimiento expreso no se abre.
    nonisolated static func needsConsent(_ profile: PlayerProfile) -> Bool {
        !profile.consentGiven
    }
}
