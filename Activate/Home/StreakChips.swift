import SwiftUI

/// Dos cápsulas discretas de vidrio funcional sobre la pantalla Hoy:
/// "Días seguidos N" (llama, el único cobre de la pantalla) y "Comodín N" (protege la racha).
/// El comodín se llama `casco` en el código y en los datos; en la interfaz siempre es "comodín".
/// Tocar el comodín muestra qué es. Con Dynamic Type grande las cápsulas se apilan.
struct StreakChips: View {
    @Environment(GameStore.self) private var game
    @State private var showComodinInfo = false

    static let chipHeight: CGFloat = 38
    static let comodinSymbol = "shield.lefthalf.filled"

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    streakChip(singleLine: true)
                    comodinChip(singleLine: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    streakChip(singleLine: false)
                    comodinChip(singleLine: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: game.streak)
        .animation(.snappy, value: game.cascos)
    }

    private func streakChip(singleLine: Bool) -> some View {
        chipContent(symbol: "flame.fill",
                    symbolColor: game.streak > 0 ? Theme.copper : .secondary,
                    label: "Días seguidos",
                    value: game.streak,
                    singleLine: singleLine)
            .functionalGlass(in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Días seguidos con pausa: \(game.streak)")
    }

    private func comodinChip(singleLine: Bool) -> some View {
        Button {
            showComodinInfo = true
        } label: {
            chipContent(symbol: Self.comodinSymbol,
                        symbolColor: game.cascos > 0 ? Theme.accent : .secondary,
                        label: CelebrationCopy.comodinName,
                        value: game.cascos,
                        singleLine: singleLine)
                .functionalGlass(in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Comodín: \(game.cascos) disponible\(game.cascos == 1 ? "" : "s")")
        .accessibilityHint("Explica qué es el comodín")
        .popover(isPresented: $showComodinInfo, arrowEdge: .top) {
            ComodinInfo(available: game.cascos)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func chipContent(symbol: String, symbolColor: Color, label: String, value: Int, singleLine: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor)
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(singleLine ? 1 : nil)
                .fixedSize(horizontal: singleLine, vertical: !singleLine)
            Text("\(value)")
                .fontWeight(.bold)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: Self.chipHeight)
    }
}

/// Explicación breve del comodín (popover del chip).
private struct ComodinInfo: View {
    let available: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(CelebrationCopy.comodinName, systemImage: StreakChips.comodinSymbol)
                .font(.headline)
                .foregroundStyle(Theme.accent)
            Text(CelebrationCopy.comodinExplanation)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text(CelebrationCopy.comodinStatus(available: available))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
