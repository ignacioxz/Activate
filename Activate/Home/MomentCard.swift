import SwiftUI

/// Tarjeta única de Hoy: el momento inferido, sus minutos, qué incluye y el CTA "Hacer la pausa".
/// Jerarquía sobria: título del momento, una línea de detalle, el estado de hoy y un solo botón
/// del sistema de diseño con el acento azul (el cobre queda solo para la llama de la racha).
struct MomentCard: View {
    let moment: Moment
    let recipe: Recipe
    let pausedToday: Bool
    let isRestDay: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(moment.title)
                } icon: {
                    Image(systemName: Self.symbol(for: moment))
                        .foregroundStyle(Theme.accent)
                }
                .font(.title3.weight(.bold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(moment.minutes) min")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(moment.minutes) minutos")
            }

            Text(Self.includesLine(for: recipe))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            // El verde va solo en el símbolo: el texto queda en `.primary` para leerse al sol.
            Label {
                Text(status)
            } icon: {
                Image(systemName: pausedToday ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(pausedToday ? Theme.mint : .secondary)
            }
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)

            PrimaryButton(title: "Hacer la pausa", systemImage: "play.fill", tint: Theme.accent, action: onStart)
                .padding(.top, 4)
                .accessibilityHint("\(moment.title), \(moment.minutes) minutos")
        }
        .flatCard()
    }

    private var status: String {
        if pausedToday { return "Pausa cumplida hoy · ¿Otra? Suma XP" }
        if isRestDay { return "Bajada: pausa opcional." }
        return "Hoy aún sin pausa."
    }

    // MARK: - Lógica pura

    nonisolated static func symbol(for moment: Moment) -> String {
        switch moment {
        case .entrada: "sunrise.fill"
        case .colacion: "fork.knife"
        case .salida: "sunset.fill"
        case .campamento: "house.fill"
        }
    }

    /// Una línea con lo que incluye la receta: "Incluye: Cuello · Pestañeo".
    nonisolated static func includesLine(for recipe: Recipe) -> String {
        let names = recipe.activities.map { shortName($0.kind) }
        guard !names.isEmpty else { return "Incluye: lo que alcance." }
        return "Incluye: " + names.joined(separator: " · ")
    }

    /// Nombres cortos para la línea de resumen (los nombres largos viven en ActivityKind.name).
    nonisolated static func shortName(_ kind: ActivityKind) -> String {
        switch kind {
        case .extensionLumbar: "Espalda"
        case .pasos: "Pasos"
        case .sentadilla: "Sentadillas"
        case .cuello: "Cervical"
        case .respiracion: "Respiración"
        case .ojos: "Pestañeo"
        case .stroop: "Reflejos"
        }
    }
}
