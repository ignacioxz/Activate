import SwiftUI

// Dueño: agente "session". Placeholder con la firma de entrada congelada.
struct PauseFlowView: View {
    let moment: Moment
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Text(moment.title).font(.largeTitle.weight(.heavy))
            Text("Flujo de pausa en construcción").foregroundStyle(.secondary)
            PrimaryButton(title: "CERRAR") { dismiss() }
        }
        .padding()
        .appScreen()
    }
}
