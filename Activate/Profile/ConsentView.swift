import SwiftUI

// Dueño: paquete "profile-onboarding". Consentimiento expreso: datos de dolor y faciales son sensibles.

private struct ConsentPoint: Identifiable {
    let id: Int
    let symbol: String
    let title: String
    let text: String

    static let all: [ConsentPoint] = [
        ConsentPoint(
            id: 0, symbol: "list.clipboard",
            title: "Qué datos se usan",
            text: "Sus respuestas sobre el dolor de espalda (6 preguntas Sí/No), la zona que le duele, cómo queda después de cada pausa y las pausas que hace."),
        ConsentPoint(
            id: 1, symbol: "faceid",
            title: "Su cara y su cuerpo",
            text: "Para contar los ejercicios, la cámara frontal mira su cara y su postura en el momento. Son datos sensibles. No se graba video ni fotos: se usan números del momento y se descartan."),
        ConsentPoint(
            id: 2, symbol: "iphone",
            title: "Todo queda en su teléfono",
            text: "El cuestionario, los ejercicios y el coach con inteligencia artificial se procesan en este iPhone. Nada se envía a internet, a la empresa ni a la mutual."),
        ConsentPoint(
            id: 3, symbol: "paperplane",
            title: "Nada se comparte sin usted",
            text: "Si usted quiere, puede generar su Reporte de Salud para el kinesiólogo o la mutual y enviarlo usted mismo. Nadie más lo ve. Sus reflejos (Stroop) nunca van en el reporte salvo que usted lo pida."),
        ConsentPoint(
            id: 4, symbol: "arrow.uturn.backward",
            title: "Puede cambiar de idea",
            text: "Puede retirar este consentimiento en Perfil › Privacidad y borrar todo con Reiniciar. La app deja de usar la cámara hasta que vuelva a aceptar."),
        ConsentPoint(
            id: 5, symbol: "checkmark.shield",
            title: "La ley",
            text: "Los datos de salud y los datos de su cara son datos sensibles según la ley chilena de protección de datos personales (Ley 21.719). Esta app los trata solo con su consentimiento expreso."),
    ]
}

struct ConsentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Se llama después de aceptar (por ejemplo, para seguir el alta).
    var onAccept: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Antes de empezar")
                    .font(.largeTitle.weight(.bold))
                Text("Lea esto. Es corto y es importante.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                ForEach(ConsentPoint.all) { point in
                    ConsentCard(point: point)
                }
                statusCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .appScreen()
        .navigationTitle("Consentimiento")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: store.profile.consentGiven ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(store.profile.consentGiven ? Theme.mint : Theme.gold)
            Text(store.profile.consentGiven
                 ? "Usted ya aceptó. Puede retirarlo cuando quiera."
                 : "Al tocar Acepto, usted autoriza este uso de sus datos.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .flatCard()
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if store.profile.consentGiven {
                PrimaryButton(title: "Listo", systemImage: "checkmark") { dismiss() }
                Button("Retirar consentimiento", role: .destructive, action: withdraw)
                    .font(.headline)
                    .frame(minHeight: 44)
            } else {
                PrimaryButton(title: "Acepto", systemImage: "checkmark.seal", action: accept)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func accept() {
        store.mutate { $0.profile.consentGiven = true }
        onAccept?()
        dismiss()
    }

    private func withdraw() {
        store.mutate { $0.profile.consentGiven = false }
    }
}

private struct ConsentCard: View {
    let point: ConsentPoint

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: point.symbol)
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(point.title).font(.headline)
                Text(point.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .flatCard()
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        ConsentView()
    }
    .environment(AppStore(inMemory: true))
}
