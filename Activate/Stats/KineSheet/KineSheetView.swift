import SwiftUI

// Dueño: agente "kine-sheet". Placeholder con firma congelada.
struct KineSheetView: View {
    let sheet: KineSheet
    let summary: StatsSummary
    let profile: PlayerProfile
    var body: some View {
        Text("Hoja para el kine en construcción").foregroundStyle(.secondary)
    }
}
