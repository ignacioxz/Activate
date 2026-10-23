import SwiftUI

/// Check-in RDQ-6 (versión chilena del Roland-Morris, 6 ítems textuales). Una vez por día laboral;
/// si ya existe, muestra el puntaje con "Volver a responder". Sin caritas, sin premio por responder.
struct CheckInView: View {
    let name: String
    let existing: DailyCheckIn?
    let initialZone: PainZone
    let initialMoment: Moment
    let onSubmit: (_ answers: [Bool], _ zone: PainZone, _ moment: Moment) -> Void
    let onContinueExisting: () -> Void
    let onAnswerAgain: () -> Void

    @State private var answers: [Bool?] = Array(repeating: nil, count: RDQ6.items.count)
    @State private var zone: PainZone? = nil
    @State private var moment: Moment? = nil

    private var chosenZone: PainZone { zone ?? initialZone }
    private var chosenMoment: Moment { moment ?? initialMoment }
    private var allAnswered: Bool { answers.allSatisfy { $0 != nil } }
    private var answeredCount: Int { answers.compactMap { $0 }.count }

    var body: some View {
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
        .safeAreaInset(edge: .bottom) { footer }
    }

    // MARK: Ya respondido hoy

    private func existingCard(_ c: DailyCheckIn) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "\(name), su espalda hoy", subtitle: "Ya respondió el cuestionario de hoy.")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(c.score)")
                    .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.rdqColor(c.score))
                Text("de \(RDQ6.maxScore)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Label(c.zone.title, systemImage: "figure.stand")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .flatCard()
            if c.score > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Marcó SÍ en:").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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

            SectionTitle(title: "Dónde le duele")
            SessionChipRow(items: PainZone.allCases, selected: chosenZone, title: { $0.title }) { zone = $0 }

            SectionTitle(title: "Momento")
            SessionChipRow(items: Moment.allCases, selected: chosenMoment, title: { $0.title }) { moment = $0 }

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
                PrimaryButton(title: "SEGUIR", systemImage: "arrow.right") { onContinueExisting() }
            } else {
                if !allAnswered {
                    Text("Faltan \(RDQ6.items.count - answeredCount) de \(RDQ6.items.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                PrimaryButton(title: "SEGUIR", systemImage: "arrow.right", isEnabled: allAnswered) {
                    onSubmit(answers.compactMap { $0 }, chosenZone, chosenMoment)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// Fila de chips de selección única (zona, momento). Controles de 48 pt para guantes.
struct SessionChipRow<Item: Identifiable & Hashable>: View {
    let items: [Item]
    let selected: Item
    let title: (Item) -> String
    let onSelect: (Item) -> Void

    /// Altura mínima del chip.
    static var chipHeight: CGFloat { 48 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        Text(title(item))
                            .font(.headline)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Self.chipHeight)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(item == selected ? Theme.copper : .gray)
                    .accessibilityAddTraits(item == selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}
