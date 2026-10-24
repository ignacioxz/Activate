import SwiftUI

/// Fila plana del Reporte de Salud (en Hoy, sobre la barra de nivel). Toca para abrir el reporte.
struct HealthReportRow: View {
    @Environment(CoachService.self) private var coach
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "stethoscope")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.12), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(HealthReport.title)
                        .font(.headline)
                    Text(coach.kineModelReady
                         ? "\(HealthReport.audience). Prepárelo con Apple Intelligence."
                         : "\(HealthReport.audience), con sus cifras listas para compartir.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
            .flatCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Abre el Reporte de Salud para llevar a la consulta")
    }
}
