import SwiftUI

/// Actividad de pantalla (Stroop A10 / respiración A8) dentro del flujo de pausa: encabezado de
/// posición, la vista especializada alimentando la `ScreenSource` del runner, "Saltar (no suma)" y
/// la entrega del `outcome` al coordinador con el mismo "Listo." que `ActivityRunView`.
struct ScreenActivityView: View {
    let runner: any ActivityRunning
    let source: ScreenSource
    let assignment: ActivityAssignment
    var position: Int = 1
    var total: Int = 1
    var onFinish: (ActivityOutcome) -> Void = { _ in }
    var onSkip: () -> Void = {}

    @State private var showDone = false
    @State private var delivered = false

    var body: some View {
        VStack(spacing: 0) {
            Text("ACTIVIDAD \(position) DE \(total)")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.copper)
                .padding(.top, 8)
            Group {
                switch assignment.kind {
                case .stroop:
                    StroopView(runner: runner, source: source)
                case .respiracion:
                    BreathView(runner: runner, source: source)
                default:
                    // Solo llega aquí un bloque de pantalla; cualquier otro usa la vista genérica.
                    ActivityRunView(runner: runner, assignment: assignment, position: position, total: total)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .overlay {
            if showDone { ActivityDoneOverlay() }
        }
        .onDisappear {
            if runner.isRunning && runner.outcome == nil { runner.stop(reason: .userStopped) }
        }
        .onChange(of: runner.outcome) { _, outcome in handle(outcome) }
        .sensoryFeedback(.success, trigger: showDone) { _, new in new }
    }

    private var footer: some View {
        Button(ActivityKind.skipLabel) { onSkip() }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .disabled(showDone || delivered)
            .padding(.horizontal)
            .padding(.bottom, 8)
    }

    private func handle(_ outcome: ActivityOutcome?) {
        guard let outcome, !delivered else { return }
        delivered = true
        if outcome.completed {
            withAnimation(.snappy) { showDone = true }
            Task {
                try? await Task.sleep(for: .seconds(ActivityRunView.handoffSeconds))
                onFinish(outcome)
            }
        } else {
            onFinish(outcome)
        }
    }
}
