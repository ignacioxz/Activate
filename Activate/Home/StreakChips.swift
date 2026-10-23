import SwiftUI

/// Dos cápsulas de vidrio funcional sobre la pantalla Hoy:
/// "Días seguidos N" (flama) y "Casco N" (cascos disponibles para salvar la racha).
struct StreakChips: View {
    @Environment(GameStore.self) private var game

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                chip(symbol: "flame.fill", color: Theme.copper, label: "Días seguidos",
                     value: game.streak, spoken: "Días seguidos con pausa")
                chip(symbol: "helmet.fill", color: .gray, label: "Casco",
                     value: game.cascos, spoken: "Cascos disponibles")
            }
        }
        .animation(.snappy, value: game.streak)
        .animation(.snappy, value: game.cascos)
    }

    private func chip(symbol: String, color: Color, label: String, value: Int, spoken: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(value)")
                .fontWeight(.heavy)
                .contentTransition(.numericText())
        }
        .font(.headline)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 48)
        .functionalGlass(cornerRadius: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spoken): \(value)")
    }
}
