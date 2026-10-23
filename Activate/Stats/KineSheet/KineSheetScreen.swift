import SwiftUI

// Dueño: agente "kine-sheet".
// Pantalla "Hoja para el kine": toma AppStore y CoachService del entorno, calcula StatsSummary con
// StatsEngine, muestra la plantilla al instante (o la última hoja cacheada), pide la redacción al
// coach en .task y cachea el JSON en store.data.lastKineSheetJSON. Un solo CTA: Compartir (PNG).
// Se usa dentro del NavigationStack de Estadísticas (o en un sheet): no abre uno propio.

struct KineSheetScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(CoachService.self) private var coach

    @State private var summary: StatsSummary?
    @State private var sheet: KineSheet?
    @State private var isWriting = false
    @State private var generatedAt = Date.now

    init() {}

    private var alarmLines: [String] {
        KineSheetTable.alarmLines(checkIns: store.data.checkIns, calendar: store.calendar.calendar)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let summary, let sheet {
                    KineSheetView(sheet: sheet, summary: summary, profile: store.profile,
                                  extraAlerts: alarmLines, now: generatedAt)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                } else {
                    ProgressView("Preparando la hoja")
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .appScreen()
        .navigationTitle("Hoja para el kine")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { shareBar }
        .task { await load() }
    }

    // MARK: Compartir

    @ViewBuilder
    private var shareBar: some View {
        if let summary, let sheet {
            VStack(spacing: 10) {
                if isWriting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("El coach está redactando el texto.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                ShareLink(item: KineSheetPNG(sheet: sheet, summary: summary, profile: store.profile,
                                             extraAlerts: alarmLines, generatedAt: generatedAt),
                          preview: SharePreview("Hoja para el kine · \(store.profile.name)",
                                                image: Image(systemName: "doc.richtext"))) {
                    Label("Compartir", systemImage: "square.and.arrow.up")
                        .font(.title3.weight(.heavy))
                        .frame(maxWidth: .infinity, minHeight: Theme.ctaHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.roundedRectangle(radius: Theme.cardRadius))
                .tint(Theme.copper)
                .accessibilityHint("Comparte la hoja como imagen")

                ShareLink(item: KineSheetPDF(sheet: sheet, summary: summary, profile: store.profile,
                                             extraAlerts: alarmLines, generatedAt: generatedAt),
                          preview: SharePreview("Hoja para el kine · \(store.profile.name) (PDF)",
                                                image: Image(systemName: "doc"))) {
                    Label("Guardar como PDF", systemImage: "doc")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(.rect)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: Theme.cardRadius))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }

    // MARK: Carga

    private func load() async {
        let now = Date.now
        generatedAt = now
        let profile = store.profile
        let computed = StatsEngine.summary(data: store.data, calendar: store.calendar, now: now)
        let table = KineSheetTable.build(summary: computed, profile: profile, extraAlerts: alarmLines, now: now)
        let fallback = KineSheetFallback.sheet(summary: computed, profile: profile, table: table)

        summary = computed
        if let cached = KineSheetCache.decode(store.data.lastKineSheetJSON) {
            sheet = KineSheetFallback.merge(cached, fallback: fallback)
        } else {
            sheet = fallback
        }

        isWriting = true
        let fresh = await coach.kineSheet(computed, profile: profile)
        isWriting = false
        guard !Task.isCancelled else { return }

        let merged = KineSheetFallback.merge(fresh, fallback: fallback)
        sheet = merged
        if let json = KineSheetCache.encode(merged), json != store.data.lastKineSheetJSON {
            store.mutate { $0.lastKineSheetJSON = json }
        }
    }
}

#if DEBUG
#Preview("Hoja para el kine") {
    NavigationStack {
        KineSheetScreen()
    }
    .environment(AppStore(inMemory: true))
    .environment(CoachService())
    .fontDesign(.rounded)
    .tint(Theme.copper)
}
#endif
