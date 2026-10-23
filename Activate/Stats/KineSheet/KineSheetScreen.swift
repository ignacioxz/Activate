import SwiftUI
import UIKit

// Dueño: paquete "kine-ai".
// "Reporte de Salud" (antes "Hoja para el kine"), para el kinesiólogo o la mutual: Apple Intelligence
// como asistente que PREPARA LA CONSULTA, anclado a datos. Swift calcula los hechos (KineFacts), el
// nivel por pausas completas (LevelProgress) y la tabla; la persona toca "Preparar con Apple Intelligence"
// y ve cómo el modelo elige los 3 hechos más relevantes, los explica, propone 3 preguntas y un foco
// (streaming). Todo texto es editable antes de compartir; la cifra de cada hallazgo la pone Swift.
// Sin Apple Intelligence: hechos + preguntas de plantilla y el botón deshabilitado con la razón.
// Se usa dentro del NavigationStack de Estadísticas: no abre uno propio.

struct KineSheetScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(CoachService.self) private var coach

    @State private var loaded = false
    @State private var summary: StatsSummary?
    @State private var facts: [KineFact] = []
    @State private var level: LevelProgress?
    @State private var sheet: KineSheet?
    @State private var draft: KineConsultDraft?
    @State private var noteText = ""
    @State private var phase: Phase = .idle
    @State private var modelFailed = false
    @State private var noteFailed = false
    @State private var dataChanged = false
    @State private var generatedAt = Date.now
    @State private var confirmRedo = false
    @State private var showAllFacts = false
    @FocusState private var focus: Field?

    nonisolated enum Phase: Equatable, Sendable { case idle, writing, summarizing }
    nonisolated enum Field: Hashable, Sendable { case finding(Int), question(Int), focus, note, noteSummary }

    /// Símbolo de Apple Intelligence si el sistema lo trae; si no, destellos.
    static let aiSymbol = UIImage(systemName: "apple.intelligence") != nil ? "apple.intelligence" : "sparkles"
    /// Alto de los botones de compartir (compactos: la barra no tapa el contenido).
    static let shareButtonHeight: CGFloat = 50

    /// Solo QA: prepara al abrir (como si tocara el botón) y/o parte con una nota escrita.
    private var qaAutoPrepare = false

    init() {}

    #if DEBUG
    init(qaAutoPrepare: Bool, qaNote: String = "") {
        self.qaAutoPrepare = qaAutoPrepare
        _noteText = State(initialValue: qaNote)
    }
    #endif

    // MARK: Derivados

    private var alarmLines: [String] {
        KineSheetTable.alarmLines(checkIns: store.data.checkIns, calendar: store.calendar.calendar)
    }

    private var trimmedNote: String { KineConsultRules.trimmedNote(noteText) }

    private var isPrepared: Bool { sheet?.consult.backend == .foundationModels }

    /// Resumen vigente: existe y corresponde al texto actual.
    private var currentSummary: PatientNote? {
        guard let n = sheet?.note, n.original == trimmedNote, !trimmedNote.isEmpty,
              !n.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return n
    }


    private var content: KineSheetContent? {
        guard var s = sheet, let summary else { return nil }
        s.note = Self.resolvedNote(s, noteText: noteText)
        return KineSheetContent(sheet: s, facts: facts, summary: summary, profile: store.profile,
                                extraAlerts: alarmLines, generatedAt: generatedAt, level: level)
    }

    // MARK: Vista

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let sheet, summary != nil {
                    Text("\(HealthReport.audience). Usted decide cuándo compartirlo.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    levelCard
                    assistantCard(sheet)
                    consultSection(sheet)
                    noteSection
                    factsSection(sheet)
                    previewLink
                } else {
                    ProgressView("Preparando el reporte")
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .appScreen()
        .navigationTitle(HealthReport.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Listo") { focus = nil }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if focus == nil { shareBar }
        }
        .task {
            load()
            if qaAutoPrepare && !isPrepared { prepare() }
        }
        .onChange(of: focus) { _, new in
            if new == nil { save() }
        }
        .onChange(of: noteText) { _, new in
            if new.count > PatientNote.maxCharacters { noteText = String(new.prefix(PatientNote.maxCharacters)) }
        }
        .onDisappear { save() }
        .confirmationDialog("¿Preparar de nuevo?", isPresented: $confirmRedo, titleVisibility: .visible) {
            Button("Preparar de nuevo") { prepare() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se reemplazan los textos que editó.")
        }
    }

    // MARK: Nivel por pausas completas (Swift; va en el reporte)

    @ViewBuilder
    private var levelCard: some View {
        if let level, level.daysWithPause > 0 {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chart.bar.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(level.levelLine).font(.headline)
                    ProgressView(value: level.fractionToNext)
                        .tint(Theme.accent)
                        .accessibilityHidden(true)
                    Text(level.fullDaysLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let today = level.todayLine {
                        Text(today)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("Cada día con la pausa completa sube un nivel; una pausa incompleta suma su parte.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .flatCard()
        }
    }

    // MARK: Asistente (Apple Intelligence)

    @ViewBuilder
    private func assistantCard(_ sheet: KineSheet) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: Self.aiSymbol)
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, isActive: phase != .idle)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(assistantTitle).font(.headline)
                    Text(assistantSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if phase != .idle { ProgressView() }
            }
            .accessibilityElement(children: .combine)

            if phase == .idle {
                if facts.isEmpty || !coach.kineModelReady {
                    PrimaryButton(title: "Preparar con Apple Intelligence", systemImage: Self.aiSymbol,
                                  tint: Theme.accent, isEnabled: false) {}
                } else if isPrepared {
                    SecondaryButton(title: "Preparar de nuevo", systemImage: "arrow.clockwise") {
                        if sheet.edited { confirmRedo = true } else { prepare() }
                    }
                } else {
                    PrimaryButton(title: modelFailed ? "Intentar de nuevo" : "Preparar con Apple Intelligence",
                                  systemImage: Self.aiSymbol, tint: Theme.accent) { prepare() }
                }
            }
        }
        .flatCard()
    }

    private var assistantTitle: String {
        switch phase {
        case .writing: return "Escribiendo en su iPhone"
        case .summarizing: return "Resumiendo sus palabras"
        case .idle: return isPrepared ? "Reporte listo para la consulta" : "Prepare su Reporte de Salud"
        }
    }

    private var assistantSubtitle: String {
        switch phase {
        case .writing: return "Apple Intelligence elige los datos más importantes del reporte y redacta las preguntas."
        case .summarizing: return "Apple Intelligence ordena lo que escribió para el reporte."
        case .idle:
            if facts.isEmpty { return "Aún no hay datos suficientes para el reporte. Haga algunas pausas y vuelva." }
            if isPrepared {
                var text = "Reporte redactado en su iPhone con Apple Intelligence. Revíselo antes de compartir."
                if dataChanged { text += " Hay datos nuevos desde que lo preparó." }
                return text
            }
            if let reason = coach.kineUnavailableReason {
                return reason + " Mientras tanto, el reporte usa una plantilla con sus cifras."
            }
            if modelFailed { return "Apple Intelligence no pudo redactar esta vez. El reporte muestra la plantilla con sus cifras." }
            return "Apple Intelligence elige los 3 datos más importantes para su reporte y le sugiere preguntas para el kine. Todo queda en su iPhone."
        }
    }

    // MARK: Para la consulta

    @ViewBuilder
    private func consultSection(_ sheet: KineSheet) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Para la consulta",
                         subtitle: phase == .writing ? "Apple Intelligence está eligiendo entre sus datos."
                             : isPrepared ? "Elegido con Apple Intelligence. Puede editar cada texto."
                             : "Plantilla con sus cifras. Puede editar cada texto.")
            if phase == .writing, let draft {
                ForEach(0..<KineConsultRules.findingsCount, id: \.self) { i in
                    draftFinding(draft.findings.indices.contains(i) ? draft.findings[i] : nil)
                }
            } else if sheet.consult.findings.isEmpty {
                Text("Cuando registre pausas y cuestionarios, aquí aparecen los datos más importantes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .flatCard()
            } else {
                ForEach(Array(sheet.consult.findings.enumerated()), id: \.offset) { i, finding in
                    if let fact = facts.first(where: { $0.id == finding.factID }) {
                        FindingCard(fact: fact) {
                            TextField("Qué muestra este dato", text: findingBinding(i), axis: .vertical)
                                .focused($focus, equals: .finding(i))
                        }
                    }
                }
            }

            questionsCard(sheet)
            focusCard(sheet)
        }
    }

    @ViewBuilder
    private func draftFinding(_ finding: KineConsultDraft.Finding?) -> some View {
        let fact = finding?.factID.flatMap { id in facts.first { $0.id == id } }
        if let fact {
            FindingCard(fact: fact) {
                Text(finding?.sentence ?? " ")
                    .foregroundStyle(.primary)
            }
        } else {
            FindingCard(fact: KineFact(id: "", title: "Eligiendo un dato", value: "· · ·", detail: "")) {
                Text("Apple Intelligence está leyendo sus cifras.")
            }
            .redacted(reason: .placeholder)
        }
    }

    private func questionsCard(_ sheet: KineSheet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Preguntas para el kine", systemImage: "questionmark.bubble")
                .font(.headline)
            if phase == .writing, let draft {
                ForEach(0..<KineConsultRules.questionsCount, id: \.self) { i in
                    questionRow(i) {
                        Text(draft.questions.indices.contains(i) ? draft.questions[i] : "…")
                            .foregroundStyle(draft.questions.indices.contains(i) ? .primary : .tertiary)
                    }
                }
            } else {
                ForEach(sheet.consult.questions.indices, id: \.self) { i in
                    questionRow(i) {
                        TextField("Pregunta", text: questionBinding(i), axis: .vertical)
                            .focused($focus, equals: .question(i))
                    }
                }
            }
        }
        .flatCard()
    }

    private func questionRow<Content: View>(_ index: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index + 1)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            content()
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func focusCard(_ sheet: KineSheet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("En qué trabajar la próxima sesión", systemImage: "scope")
                .font(.headline)
            if phase == .writing, let draft {
                Text(draft.focus ?? "…")
                    .foregroundStyle(draft.focus == nil ? .tertiary : .primary)
            } else {
                TextField("Foco de la próxima sesión", text: focusBinding, axis: .vertical)
                    .focused($focus, equals: .focus)
            }
        }
        .font(.body)
        .flatCard()
    }

    // MARK: En sus palabras

    @ViewBuilder
    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "En sus palabras",
                         subtitle: "Opcional. Lo que quiere contarle al kine; va en el reporte.")
            VStack(alignment: .trailing, spacing: 6) {
                TextField("Por ejemplo: me duele la espalda al bajar del camión y de noche me cuesta dormir.",
                          text: $noteText, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focus, equals: .note)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(noteText.count)/\(PatientNote.maxCharacters)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .flatCard()

            if let note = currentSummary {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Resumen para el kine", systemImage: Self.aiSymbol)
                        .font(.headline)
                    TextField("Resumen", text: noteSummaryBinding, axis: .vertical)
                        .focused($focus, equals: .noteSummary)
                    let tags = note.zones.map(\.title) + note.moments.map(\.title)
                    if !tags.isEmpty {
                        FlowRows(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Theme.accent.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
                .flatCard()
            } else if !trimmedNote.isEmpty && coach.kineModelReady && phase == .idle {
                SecondaryButton(title: "Resumir con Apple Intelligence", systemImage: Self.aiSymbol) { summarizeNote() }
                if noteFailed {
                    Text("No se pudo resumir esta vez. En el reporte va su texto tal cual.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Datos de la app

    @ViewBuilder
    private func factsSection(_ sheet: KineSheet) -> some View {
        if !facts.isEmpty {
            let chosen = Set(sheet.consult.findings.map(\.factID))
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy) { showAllFacts.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Datos calculados por la app").font(.headline)
                            Text("\(facts.count) \(facts.count == 1 ? "dato" : "datos") con cifras de sus registros")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showAllFacts ? 180 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(showAllFacts ? "Abierto" : "Cerrado")
                if showAllFacts {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(facts) { fact in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: chosen.contains(fact.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(fact.id) ? Theme.accent : Color.secondary)
                                    .accessibilityLabel(chosen.contains(fact.id) ? "En la consulta" : "No elegido")
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(fact.title).font(.subheadline.weight(.semibold))
                                        Spacer(minLength: 6)
                                        Text(fact.value)
                                            .font(.subheadline.weight(.semibold))
                                            .monospacedDigit()
                                            .multilineTextAlignment(.trailing)
                                    }
                                    Text(fact.detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 14)
                    .transition(.opacity)
                }
            }
            .flatCard()
        }
    }

    // MARK: Vista previa y compartir

    @ViewBuilder
    private var previewLink: some View {
        if let content {
            NavigationLink {
                KineSheetPreviewScreen(content: content)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ver el reporte completo").font(.headline)
                        Text("Así lo recibe el kinesiólogo o la mutual, con las cifras por turno.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
            .disabled(phase != .idle)
        }
    }

    @ViewBuilder
    private var shareBar: some View {
        if let content, phase == .idle {
            KineShareButtons(content: content, prominent: isPrepared || !coach.kineModelReady || facts.isEmpty || (sheet?.edited ?? false))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    // MARK: Bindings (editar marca el reporte como editado)

    private func findingBinding(_ i: Int) -> Binding<String> {
        Binding(get: { sheet?.consult.findings.indices.contains(i) == true ? sheet!.consult.findings[i].sentence : "" },
                set: { value in
                    guard sheet?.consult.findings.indices.contains(i) == true else { return }
                    sheet?.consult.findings[i].sentence = value
                    sheet?.edited = true
                })
    }

    private func questionBinding(_ i: Int) -> Binding<String> {
        Binding(get: { sheet?.consult.questions.indices.contains(i) == true ? sheet!.consult.questions[i] : "" },
                set: { value in
                    guard sheet?.consult.questions.indices.contains(i) == true else { return }
                    sheet?.consult.questions[i] = value
                    sheet?.edited = true
                })
    }

    private var focusBinding: Binding<String> {
        Binding(get: { sheet?.consult.focus ?? "" },
                set: { value in
                    sheet?.consult.focus = value
                    sheet?.edited = true
                })
    }

    private var noteSummaryBinding: Binding<String> {
        Binding(get: { sheet?.note?.summary ?? "" },
                set: { value in
                    sheet?.note?.summary = value
                    sheet?.edited = true
                })
    }

    // MARK: Carga, generación y caché

    private func load() {
        guard !loaded else { return }
        loaded = true
        let now = Date.now
        generatedAt = now
        let computed = StatsEngine.summary(data: store.data, calendar: store.calendar, now: now)
        let built = KineFacts.build(data: store.data, summary: computed, calendar: store.calendar.calendar)
        let signature = KineConsultRules.signature(built)
        summary = computed
        facts = built
        level = LevelProgress.compute(sessions: store.data.sessions, calendar: store.calendar, now: now)
        if let cached = KineSheetCache.decode(store.data.lastKineSheetJSON), KineSheetCache.usable(cached, facts: built) {
            sheet = cached
            if let original = cached.note?.original, !original.isEmpty { noteText = original }
            dataChanged = cached.factsSignature != signature
        } else {
            sheet = KineSheet(consult: KineConsultRules.template(built, profile: store.profile), note: nil,
                              factsSignature: signature, preparedAt: now)
        }
    }

    /// La generación puede terminar con la pantalla ya cerrada: el `Task` no lee `@Environment` ni
    /// `@State` al final; trabaja con copias locales y guarda con el store capturado al empezar.
    private func prepare() {
        guard phase == .idle, !facts.isEmpty, coach.kineModelReady else { return }
        focus = nil
        let facts = self.facts
        let store = self.store
        let coach = self.coach
        let profile = store.profile
        let text = trimmedNote
        let previous = sheet
        modelFailed = false
        noteFailed = false
        draft = KineConsultDraft()
        phase = .writing
        Task {
            let consult = await coach.kineConsult(facts, profile: profile) { partial in
                draft = partial
            }
            var note = previous?.note
            var failedNote = false
            if !text.isEmpty, note?.original != text || (note?.summary.isEmpty ?? true) {
                phase = .summarizing
                let fresh = await coach.patientNote(text, profile: profile)
                failedNote = fresh.backend != .foundationModels
                if fresh.backend == .foundationModels || note?.original != text { note = fresh }
            }
            var next = previous
            if consult.backend == .foundationModels {
                next = KineSheet(consult: consult, note: note, factsSignature: KineConsultRules.signature(facts),
                                 preparedAt: .now, edited: false)
            } else {
                // El modelo falló: se conserva lo que había (plantilla o una preparación anterior).
                next?.note = note
            }
            draft = nil
            sheet = next
            modelFailed = consult.backend != .foundationModels
            noteFailed = failedNote
            if consult.backend == .foundationModels { dataChanged = false }
            phase = .idle
            if let next { Self.persist(next, noteText: text, store: store) }
        }
    }

    private func summarizeNote() {
        let text = trimmedNote
        guard !text.isEmpty, phase == .idle, coach.kineModelReady else { return }
        focus = nil
        noteFailed = false
        phase = .summarizing
        let store = self.store
        let coach = self.coach
        let profile = store.profile
        let previous = sheet
        Task {
            let fresh = await coach.patientNote(text, profile: profile)
            var next = previous
            next?.note = fresh
            sheet = next
            noteFailed = fresh.backend != .foundationModels
            phase = .idle
            if let next { Self.persist(next, noteText: text, store: store) }
        }
    }

    /// Cachea lo preparado o editado (la plantilla sin cambios no se guarda: se recalcula).
    private func save() {
        guard let s = sheet, phase == .idle else { return }
        Self.persist(s, noteText: noteText, store: store)
    }

    /// Nota que va en el reporte: el resumen si corresponde al texto actual; si no, el texto tal cual.
    static func resolvedNote(_ sheet: KineSheet, noteText: String) -> PatientNote? {
        let text = KineConsultRules.trimmedNote(noteText)
        guard !text.isEmpty else { return nil }
        if let n = sheet.note, n.original == text { return n }
        return KineConsultRules.noteTemplate(text)
    }

    static func persist(_ sheet: KineSheet, noteText: String, store: AppStore) {
        var s = sheet
        s.note = resolvedNote(s, noteText: noteText)
        guard s.consult.backend == .foundationModels || s.edited || s.note != nil,
              let json = KineSheetCache.encode(s), json != store.data.lastKineSheetJSON else { return }
        store.setKineSheetJSON(json)
    }
}

// MARK: - Piezas

/// Tarjeta de un hallazgo: título del hecho, cifra de Swift en un chip y la frase (editable o en vivo).
private struct FindingCard<Content: View>: View {
    let fact: KineFact
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fact.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(fact.value)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .fixedSize()
                    .accessibilityLabel("Cifra: \(fact.value)")
            }
            content
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !fact.detail.isEmpty {
                Text(fact.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Detalle: \(fact.detail)")
            }
        }
        .flatCard(padding: 16)
    }
}

/// Compartir el Reporte de Salud: imagen (WhatsApp) y PDF. Vidrio solo en estos controles.
struct KineShareButtons: View {
    let content: KineSheetContent
    var prominent: Bool = true

    /// "Reporte de Salud - Marco" (mismo nombre que el archivo).
    private var title: String { KineSheetExport.fileStem(for: content.profile) }

    var body: some View {
        HStack(spacing: 10) {
            if prominent {
                imageLink.buttonStyle(.glassProminent)
            } else {
                imageLink.buttonStyle(.glass)
            }
            ShareLink(item: KineSheetPDF(content: content),
                      preview: SharePreview("\(title) (PDF)", image: Image(systemName: "doc"))) {
                Label("PDF", systemImage: "doc")
                    .font(.headline)
                    .padding(.horizontal, 6)
                    .frame(minHeight: KineSheetScreen.shareButtonHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("\(HealthReport.title) en PDF")
            .accessibilityHint("Guarda el reporte como PDF")
        }
        .buttonBorderShape(.capsule)
        .tint(Theme.accent)
    }

    private var imageLink: some View {
        ShareLink(item: KineSheetPNG(content: content),
                  preview: SharePreview(title, image: Image(systemName: "doc.richtext"))) {
            Label("Compartir reporte", systemImage: "square.and.arrow.up")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: KineSheetScreen.shareButtonHeight)
                .contentShape(.rect)
        }
        .accessibilityHint("Comparte el Reporte de Salud como imagen")
    }
}

/// El Reporte de Salud tal como lo recibe el kine o la mutual (papel plano) con los mismos botones de compartir.
struct KineSheetPreviewScreen: View {
    let content: KineSheetContent

    var body: some View {
        ScrollView {
            KineSheetView(content: content)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .padding(16)
        }
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
        .navigationTitle("Vista previa")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            KineShareButtons(content: content)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }
}

#if DEBUG
#Preview("Reporte de Salud") {
    KineSheetQARoot()
}

#Preview("Vista previa") {
    NavigationStack {
        KineSheetPreviewScreen(content: KineSheetSample.content)
    }
}
#endif
