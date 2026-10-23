import SwiftUI

/// Una actividad verificada: gating con copy en vivo, consigna grande, contador + anillo en el HUD de vidrio,
/// tick háptico por rep y "Listo." al completar. No hay botón "hecho": solo el runner cierra la actividad.
struct ActivityRunView: View {
    let runner: any ActivityRunning
    let assignment: ActivityAssignment
    var position: Int = 1
    var total: Int = 1
    var onFinish: (ActivityOutcome) -> Void = { _ in }
    var onSkip: () -> Void = {}

    /// Segundos que se muestra "Listo." antes de pasar a la siguiente actividad.
    static let handoffSeconds: Double = 1.1
    /// Copy de gating.
    static let calibratingCopy = "Quieto un segundo."
    static let doneCopy = "Listo."

    @State private var showDone = false
    @State private var delivered = false
    @ScaledMetric(relativeTo: .largeTitle) private var counterSize: CGFloat = 84
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 236
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: VerifierProgress { runner.progress }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    Text("ACTIVIDAD \(position) DE \(total)")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.copper)
                    Text(assignment.kind.name)
                        .font(.largeTitle.weight(.heavy))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if assignment.kind.sensorBlock == .cameraPose {
                        cameraPlaceholder
                    }

                    hud
                    gateCopy
                }
                .padding()
            }
            footer
        }
        .overlay {
            if showDone { doneOverlay }
        }
        .task(id: ObjectIdentifier(runner)) {
            if !runner.isRunning && runner.outcome == nil { runner.start() }
        }
        .onDisappear {
            if runner.isRunning && runner.outcome == nil { runner.stop(reason: .userStopped) }
        }
        .onChange(of: runner.outcome) { _, outcome in handle(outcome) }
        .sensoryFeedback(.increase, trigger: progress.count) { old, new in new > old }
        .sensoryFeedback(.success, trigger: showDone) { _, new in new }
        .sensoryFeedback(.warning, trigger: isBlocked) { _, new in new }
    }

    // MARK: HUD (vidrio funcional)

    private var hud: some View {
        ZStack {
            ProgressRing(progress: progress.fraction, lineWidth: 18)
            VStack(spacing: 2) {
                Image(systemName: assignment.kind.symbol)
                    .font(.title)
                    .foregroundStyle(Theme.copper)
                    .symbolEffect(.bounce, value: progress.count)
                Text("\(progress.count)")
                    .font(.system(size: counterSize, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy, value: progress.count)
                Text("de \(assignment.target) \(assignment.kind.unit)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: ringSize, height: ringSize)
        .padding(22)
        .functionalGlass(cornerRadius: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.count) de \(assignment.target) \(assignment.kind.unit)")
    }

    // MARK: Gating y consigna

    private var isBlocked: Bool {
        if case .blocked = progress.gate { return true }
        return false
    }

    @ViewBuilder
    private var gateCopy: some View {
        VStack(spacing: 8) {
            switch progress.gate {
            case .calibrating:
                Label(Self.calibratingCopy, systemImage: "hourglass")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.secondary)
            case .blocked(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.danger)
            case .ready:
                if let cue = runner.cue {
                    HStack(spacing: 10) {
                        if let symbol = cue.symbol {
                            Image(systemName: symbol).font(.largeTitle)
                        }
                        Text(cue.text).font(.largeTitle.weight(.heavy))
                    }
                } else if !progress.hint.isEmpty {
                    Text(progress.hint).font(.title2.weight(.bold))
                }
            }
            if progress.gate == .ready, runner.cue != nil, !progress.hint.isEmpty {
                Text(progress.hint).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .contentTransition(.opacity)
        .animation(.smooth, value: progress.gate)
        .animation(.smooth, value: runner.cue)
    }

    // MARK: Cámara (cuerpo entero)

    /// INTEGRACIÓN: reemplazar por `CameraPreviewView` (paquete camera-pose) cuando exista en el proyecto.
    private var cameraPlaceholder: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius)
            .fill(Color(.secondarySystemBackground))
            .frame(maxWidth: .infinity)
            .frame(height: 170)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "camera.fill").font(.title)
                    Text("Cámara frontal").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }

    // MARK: Pie

    private var footer: some View {
        VStack(spacing: 8) {
            if assignment.kind.requiresPhoneSupported {
                Label(PlanRow.placement(for: .cameraPose), systemImage: "iphone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Saltar (no suma)") { onSkip() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .disabled(showDone || delivered)
        }
        .padding()
    }

    // MARK: Listo.

    private var doneOverlay: some View {
        VStack(spacing: 10) {
            if reduceMotion {
                doneCheck.transition(.opacity)
            } else {
                doneCheck.transition(.symbolEffect(.drawOn))
            }
            Text(Self.doneCopy)
                .font(.largeTitle.weight(.heavy))
        }
        .padding(32)
        .functionalGlass(tint: Theme.mint, cornerRadius: 32)
        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
    }

    private var doneCheck: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 72))
            .foregroundStyle(Theme.mint)
    }

    private func handle(_ outcome: ActivityOutcome?) {
        guard let outcome, !delivered else { return }
        delivered = true
        if outcome.completed {
            withAnimation(.snappy) { showDone = true }
            Task {
                try? await Task.sleep(for: .seconds(Self.handoffSeconds))
                onFinish(outcome)
            }
        } else {
            onFinish(outcome)
        }
    }
}
