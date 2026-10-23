import SwiftUI

/// Tarjeta única de Hoy: el momento inferido, sus minutos, qué incluye y el CTA "Hacer la pausa".
struct MomentCard: View {
    let moment: Moment
    let recipe: Recipe
    let pausedToday: Bool
    let isRestDay: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(moment.title, systemImage: Self.symbol(for: moment))
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(moment.minutes) min")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Theme.copper)
                    .accessibilityLabel("\(moment.minutes) minutos")
            }

            Text(Self.includesLine(for: recipe))
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(status)
                .font(.title3.weight(.semibold))
                .foregroundStyle(pausedToday ? Theme.mint : .primary)
                .fixedSize(horizontal: false, vertical: true)

            PrimaryButton(title: "Hacer la pausa", systemImage: "play.fill", action: onStart)
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

    /// Una línea con lo que incluye la receta: "Incluye: Cuello · Ojos".
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
        case .cuello: "Cuello"
        case .respiracion: "Respiración"
        case .ojos: "Ojos"
        case .stroop: "Reflejos"
        }
    }
}
