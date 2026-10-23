import SwiftUI

/// Check-in RDQ-6 (versión chilena del Roland-Morris, 6 ítems textuales). Una vez por día laboral;
/// si ya existe, muestra el puntaje con "Volver a responder". Sin caritas, sin premio por responder.
/// "¿Dónde le duele?" es de selección múltiple, con la opción "No me duele" (sin zonas). No se prellena:
/// una zona supuesta contamina el registro y al coach (caso real: todo "No" + "Espalda baja" prellenada).
struct CheckInView: View {
    let name: String
    let existing: DailyCheckIn?
    let initialZones: [PainZone]
    let initialMoment: Moment
    let onSubmit: (_ answers: [Bool], _ zones: [PainZone], _ moment: Moment) -> Void
    let onContinueExisting: () -> Void
    let onAnswerAgain: () -> Void

    /// Ancla de la sección de zonas (capturas de QA).
    static let zonesAnchor = "checkin-zones"

    @Environment(\.qaScrollTarget) private var qaScrollTarget
    @State private var answers: [Bool?] = Array(repeating: nil, count: RDQ6.items.count)
    @State private var zones: [PainZone]? = nil
    @State private var moment: Moment? = nil

    /// `nil` = aún no elige; `[]` = "No me duele".
    private var chosenZones: [PainZone] { zones ?? [] }
    private var zoneChosen: Bool { zones != nil }
    private var chosenMoment: Moment { moment ?? initialMoment }
    private var allAnswered: Bool { answers.allSatisfy { $0 != nil } }
    private var answeredCount: Int { answers.compactMap { $0 }.count }

    private var zonesBinding: Binding<[PainZone]> {
        Binding(get: { chosenZones }, set: { zones = $0.isEmpty ? nil : PainZone.ordered($0) })
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let existing {
                        existingCard(existing)
                    } else {
                        questionnaire
                    }
                }
                .padding()
                .padding(.bottom, 8)
            }
            .task {
                guard let target = qaScrollTarget, existing == nil else { return }
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo(target, anchor: .top)
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    // MARK: Ya respondido hoy

    private func existingCard(_ c: DailyCheckIn) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "\(name), su espalda hoy", subtitle: "Ya respondió el cuestionario de hoy.")
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(c.score)")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.rdqColor(c.score))
                    Text("de \(RDQ6.maxScore)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Label(PainZone.listTitle(c.allZones), systemImage: "figure.stand")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .flatCard()
            if c.score > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Marcó Sí en:").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(zip(RDQ6.items, c.answers).enumerated()), id: \.offset) { _, pair in
                        if pair.1 {
                            Label(pair.0, systemImage: "checkmark")
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .flatCard()
            }
            SecondaryButton(title: "Volver a responder", systemImage: "arrow.counterclockwise") { onAnswerAgain() }
        }
    }

    // MARK: Cuestionario

    private var questionnaire: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "\(name), su espalda hoy", subtitle: "Cuestionario Roland-Morris · 6 frases")
            Text(RDQ6.instruction)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(RDQ6.stem)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(RDQ6.items.indices, id: \.self) { i in
                YesNoRow(text: "\(i + 1). \(RDQ6.items[i])", answer: $answers[i])
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "¿Dónde le duele?", subtitle: "Marque una o más zonas, o «No me duele».")
                SelectionChip(title: PainZone.noPainOption, isSelected: zones == [], systemImage: "checkmark.seal") {
                    zones = []
                }
                .accessibilityHint("Desmarca todas las zonas.")
                MultiSelectChips(items: PainZone.allCases, selection: zonesBinding, title: { $0.title }, minimum: 0)
            }
            .padding(.top, 8)
            .id(Self.zonesAnchor)

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Momento")
                SessionChipRow(items: Moment.allCases, selected: chosenMoment, title: { $0.title }) { moment = $0 }
            }
            .padding(.top, 4)

            Text(RDQ6.citation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .sensoryFeedback(.selection, trigger: answeredCount)
    }

    // MARK: Pie

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 6) {
            if existing != nil {
                PrimaryButton(title: "Seguir", systemImage: "arrow.right") { onContinueExisting() }
            } else {
                if !allAnswered {
                    Text("Faltan \(RDQ6.items.count - answeredCount) de \(RDQ6.items.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !zoneChosen {
                    Text("Falta: ¿dónde le duele?")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                PrimaryButton(title: "Seguir", systemImage: "arrow.right", isEnabled: allAnswered && zoneChosen) {
                    onSubmit(answers.compactMap { $0 }, chosenZones, chosenMoment)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

#Preview("Check-in") {
    CheckInView(name: "Marco", existing: nil, initialZones: [.lumbar, .cuello], initialMoment: .colacion,
                onSubmit: { _, _, _ in }, onContinueExisting: {}, onAnswerAgain: {})
}
