import SwiftUI

// Dueño: agente "stats-ui" (enlace al Reporte de Salud: paquete kine-ai). Pestaña Estadísticas:
// "Este turno" arriba, dashboard histórico debajo. Todo el contenido es plano (flatCard).

struct StatsView: View {
    @Environment(AppStore.self) private var store
    @Environment(CoachService.self) private var coach

    @State private var computed: ComputedSummary?
    @State private var reading: [String]?
    @State private var readingLoading = false
    @State private var shownCacheText: String?
    @State private var scope: HistoryScope = .current

    /// Selector del dashboard histórico.
    nonisolated enum HistoryScope: String, CaseIterable, Identifiable, Sendable {
        case current, lastThree, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .current: "Este turno"
            case .lastThree: "Últimos 3"
            case .all: "Todo"
            }
        }
    }

    /// Cambia cuando cambian los datos que alimentan el resumen (no la caché de lecturas) o el día laboral.
    nonisolated struct RefreshKey: Hashable, Sendable {
        var data: Int
        var day: String
    }

    private struct ComputedSummary {
        var key: RefreshKey
        var summary: StatsSummary
    }

    // MARK: Datos

    private var todayKey: String { store.calendar.key(for: .now) }

    private var refreshKey: RefreshKey {
        var hasher = Hasher()
        hasher.combine(store.data.sessions)
        hasher.combine(store.data.checkIns)
        hasher.combine(store.data.workDays)
        hasher.combine(store.data.profile)
        return RefreshKey(data: hasher.finalize(), day: todayKey)
    }

    private func computeSummary() -> StatsSummary {
        StatsEngine.summary(data: store.data, calendar: store.calendar, now: .now)
    }

    /// Resumen memorizado; se recalcula solo cuando cambia `refreshKey`.
    private var summary: StatsSummary {
        if let computed, computed.key == refreshKey { return computed.summary }
        return computeSummary()
    }

    private var isRestDay: Bool { store.calendar.kind(for: .now) == .descanso }

    private var currentTurnoKey: String {
        summary.currentTurno?.turnoKey ?? store.calendar.turnoKey(for: .now)
    }

    nonisolated private static func digest(_ session: PauseSession) -> SessionDigest {
        SessionDigest(id: session.id, date: session.startedAt, workDayKey: session.workDayKey,
                      moment: session.moment, recipe: session.recipe, checkInScore: session.checkInScore,
                      post: session.postResponse, counted: session.counted, level: session.level,
                      activityKinds: session.activities.map(\.kind))
    }

    /// Pausas del turno actual con cierre, sin simuladas ni sospechosas (como los agregados del motor).
    private var currentTurnoDigests: [SessionDigest] {
        let key = currentTurnoKey
        return store.data.sessions
            .filter { $0.turnoKey == key && !$0.simulated && $0.level >= .reduced }
            .map(Self.digest)
    }

    private func scopedTurnos(_ summary: StatsSummary) -> [TurnoSummary] {
        let sorted = summary.turnos.sorted { $0.turnoKey < $1.turnoKey }
        switch scope {
        case .current:
            let pair = [summary.previousTurno, summary.currentTurno].compactMap { $0 }
            return pair.isEmpty ? Array(sorted.suffix(2)) : pair
        case .lastThree:
            return Array(sorted.suffix(3))
        case .all:
            return sorted
        }
    }

    /// Claves de turno que entran en la lista de pausas (nil = todas).
    private func scopedTurnoKeys() -> Set<String>? {
        switch scope {
        case .current:
            return [currentTurnoKey]
        case .lastThree:
            let keys = Set(store.data.sessions.map(\.turnoKey) + [currentTurnoKey]).sorted()
            return Set(keys.suffix(3))
        case .all:
            return nil
        }
    }

    private var scopedDigests: [SessionDigest] {
        let keys = scopedTurnoKeys()
        return store.data.sessions
            .filter { keys?.contains($0.turnoKey) ?? true }
            .map(Self.digest)
            .sorted { $0.date > $1.date }
    }

    private func turnoSubtitle(_ summary: StatsSummary) -> String {
        if isRestDay { return "Bajada · racha a salvo" }
        let day = store.calendar.dayInBlock(for: .now)
        var text = "Día \(day) de \(store.profile.roster.workDays)"
        if summary.streak > 0 { text += " · racha \(summary.streak) \(summary.streak == 1 ? "día" : "días")" }
        return text
    }

    // MARK: Vista

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    thisTurnoSection
                    historySection
                }
                .padding()
            }
            .appScreen()
            .navigationTitle("Estadísticas")
            .onChange(of: refreshKey, initial: true) { _, key in
                computed = ComputedSummary(key: key, summary: computeSummary())
            }
            .task(id: refreshKey) {
                await loadReading()
            }
        }
    }

    @ViewBuilder
    private var thisTurnoSection: some View {
        let summary = summary
        SectionTitle(title: "Este turno", subtitle: turnoSubtitle(summary))
        StatsTurnoStrip(days: summary.currentTurnoDays, restDay: isRestDay)
        TurnoTiles(summary: summary)
        chartCard(title: "Espalda por día", subtitle: "RDQ-6 · menos es mejor") {
            RDQByDayChart(days: summary.currentTurnoDays, previousMean: summary.previousTurno?.meanRDQ)
        }
        chartCard(title: "Después de cada pausa", subtitle: "Mejor, igual o peor que antes") {
            PostResponseChart(digests: currentTurnoDigests)
        }
        CoachReadingCard(
            sentences: reading ?? StatsCopy.templateSentences(summary, name: store.profile.name, isRestDay: isRestDay),
            isTemplate: reading == nil,
            isLoading: readingLoading)
        KineSheetLink()
    }

    @ViewBuilder
    private var historySection: some View {
        let summary = summary
        SectionTitle(title: "Historial", subtitle: "Turno a turno")
        Picker("Período", selection: $scope) {
            ForEach(HistoryScope.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        TurnoComparisonCard(current: summary.currentTurno, previous: summary.previousTurno)
        TurnoBarsCard(turnos: scopedTurnos(summary), currentKey: summary.currentTurno?.turnoKey)
        if !summary.worsensHints.isEmpty {
            hintsCard(summary.worsensHints)
        }
        SectionTitle(title: "Pausas", subtitle: scope.title)
        TurnoHistoryView(digests: scopedDigests)
    }

    private func chartCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
        .flatCard()
    }

    private func hintsCard(_ hints: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Qué lo empeora").font(.title3.weight(.bold))
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                Label(hint, systemImage: "arrow.turn.down.right")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .flatCard()
    }

    // MARK: Lectura del coach

    private static func split(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Usa la caché del día si es nueva para esta vista; si no (o si cambiaron los datos), pide la lectura
    /// al coach y la guarda en `statsReadingCache[todayKey]`.
    private func loadReading() async {
        let key = todayKey
        if let cached = store.data.statsReadingCache[key], !cached.isEmpty, cached != shownCacheText {
            reading = Self.split(cached)
            shownCacheText = cached
            readingLoading = false
            return
        }
        readingLoading = true
        let result = await coach.statsReading(summary, profile: store.profile)
        guard !Task.isCancelled else { return }
        readingLoading = false
        let sentences = result.sentences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return }
        reading = sentences
        let text = sentences.joined(separator: "\n")
        shownCacheText = text
        store.mutate { $0.statsReadingCache[key] = text }
    }
}

// MARK: - Lectura del coach

private struct CoachReadingCard: View {
    let sentences: [String]
    let isTemplate: Bool
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Lectura del coach", systemImage: "text.bubble.fill")
                    .font(.title3.weight(.bold))
                Spacer()
                if isLoading {
                    ProgressView()
                        .accessibilityLabel("Redactando la lectura")
                }
            }
            ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                Text(sentence)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isTemplate && isLoading {
                Text("Redactando en el teléfono…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .flatCard()
    }
}

// MARK: - Reporte de Salud (antes "Hoja para el kine")

/// Fila plana que abre `KineSheetScreen` (Apple Intelligence prepara la consulta; PNG o PDF).
private struct KineSheetLink: View {
    @Environment(CoachService.self) private var coach

    var body: some View {
        NavigationLink {
            KineSheetScreen()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "stethoscope")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.12), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(HealthReport.title)
                        .font(.headline)
                    Text(coach.kineModelReady
                         ? "\(HealthReport.audience). Prepárelo con Apple Intelligence."
                         : "\(HealthReport.audience), con sus cifras listas para compartir.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
            .flatCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Abre el Reporte de Salud para llevar a la consulta")
    }
}

#Preview {
    StatsView()
        .environment(AppStore(inMemory: true))
        .environment(CoachService())
}
