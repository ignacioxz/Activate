import SwiftUI

/// Cierre de la pausa: "¿Y ahora la espalda?" Mejor / Igual / Peor. Una sola acción; nunca se premia la respuesta,
/// por eso los tres botones pesan igual.
struct PostCheckView: View {
    let name: String
    let onSelect: (PostResponse) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chosen: PostResponse? = nil

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Text("¿Y ahora la espalda?")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(name), comparado con antes de la pausa.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(PostResponse.allCases, id: \.self) { response in
                    SecondaryButton(title: response.title, systemImage: Self.symbol(for: response)) {
                        guard chosen == nil else { return }
                        chosen = response
                        onSelect(response)
                    }
                    .disabled(chosen != nil)
                    .opacity(chosen == nil || chosen == response ? 1 : 0.4)
                    .accessibilityAddTraits(chosen == response ? .isSelected : [])
                }
            }
            .padding(.top, 8)

            if chosen != nil {
                ProgressView("Guardando la pausa…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .animation(reduceMotion ? nil : .smooth, value: chosen)
        .sensoryFeedback(.selection, trigger: chosen)
    }

    static func symbol(for response: PostResponse) -> String {
        switch response {
        case .mejor: "arrow.up.circle.fill"
        case .igual: "equal.circle.fill"
        case .peor: "arrow.down.circle.fill"
        }
    }
}
