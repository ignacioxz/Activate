import SwiftUI

/// Tres preguntas de alarma (solo con RDQ ≥ `RDQ6.gentlePlanThreshold`). Cualquier Sí → `StopCardView`.
struct AlarmView: View {
    let name: String
    let score: Int
    let onSubmit: ([Bool]) -> Void

    @State private var answers: [Bool?] = Array(repeating: nil, count: RDQ6.alarmQuestions.count)

    private var allAnswered: Bool { answers.allSatisfy { $0 != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "Tres preguntas más",
                             subtitle: "\(name), hoy marcó \(score) de \(RDQ6.maxScore). Antes de seguir:")
                ForEach(RDQ6.alarmQuestions.indices, id: \.self) { i in
                    YesNoRow(text: RDQ6.alarmQuestions[i], answer: $answers[i])
                }
                Text("Si responde Sí a alguna, hoy no hacemos ejercicio.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Seguir", systemImage: "arrow.right", isEnabled: allAnswered) {
                onSubmit(answers.compactMap { $0 })
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

/// Tarjeta "cuándo parar": derivación al policlínico de faena. Termina la pausa sin ejercicio.
struct StopCardView: View {
    let name: String
    let reason: String?
    let onClose: () -> Void

    /// Señales de alarma que se muestran siempre (clínicas, fijas; nunca redactadas por el LLM).
    static let signs: [String] = [
        "Dolor que baja a la pierna, con hormigueo o pérdida de fuerza.",
        "Problemas nuevos para orinar o controlar el intestino.",
        "Golpe o caída reciente, fiebre o baja de peso sin explicación.",
        "Mareo o falta de aire en altura.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "cross.case.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.danger)
                        .accessibilityHidden(true)
                    Text("Hoy no haga ejercicio.")
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(name), con estas señales la pausa no ayuda. Avise a su supervisor y vaya al policlínico de faena hoy.")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason, !reason.isEmpty {
                    Text(reason)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Cuándo parar").font(.headline)
                    ForEach(Self.signs, id: \.self) { sign in
                        Label(sign, systemImage: "exclamationmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .flatCard()
                Label("Sus respuestas quedaron guardadas.", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Entendido") { onClose() }
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }
}
