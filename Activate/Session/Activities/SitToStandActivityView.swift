import SwiftUI

// Dueño: agente "sit-to-stand".

/// "Pararse y sentarse" (A4): sentado en una silla con el teléfono en las dos manos frente al pecho,
/// mirando la pantalla. Instrucción breve, consigna grande (la del verificador), contador con anillo azul,
/// gate visible, tick háptico por rep y "Saltar (no suma)". No hay botón "hecho": solo el runner cierra.
struct SitToStandActivityView: View {
    let runner: any ActivityRunning
    let assignment: ActivityAssignment
    var position: Int = 1
    var total: Int = 1
    var onFinish: (ActivityOutcome) -> Void = { _ in }
    var onSkip: () -> Void = {}

    static let title = ActivityKind.pararseSentarse.name
    static let instruction = ActivityKind.pararseSentarse.instructions
    static let placement = ActivityKind.pararseSentarse.placement
    static let unit = ActivityKind.pararseSentarse.unit
    /// Segundos que se muestra un aviso del verificador antes de desaparecer.
    static let feedbackSeconds: Double = 3

    @State private var showDone = false
    @State private var delivered = false
    @State private var feedback: Cue?
    @ScaledMetric(relativeTo: .largeTitle) private var counterSize: CGFloat = 76
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 210
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: VerifierProgress { runner.progress }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    instructionCard
                    hud
                    command
                    feedbackLine
                }
                .padding()
            }
            footer
        }
        .overlay {
            if showDone { ActivityDoneOverlay() }
        }
        .task(id: ObjectIdentifier(runner)) {
            if !runner.isRunning && runner.outcome == nil { runner.start() }
        }
        .onDisappear {
            if runner.isRunning && runner.outcome == nil { runner.stop(reason: .userStopped) }
        }
        .onChange(of: runner.outcome) { _, outcome in handle(outcome) }
        .onChange(of: runner.cue) { _, cue in
            withAnimation(.smooth) { feedback = cue }
        }
        .task(id: feedback) {
            guard feedback != nil else { return }
            try? await Task.sleep(for: .seconds(Self.feedbackSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { feedback = nil }
        }
        .sensoryFeedback(.increase, trigger: progress.count) { old, new in new > old }
        .sensoryFeedback(.success, trigger: showDone) { _, new in new }
        .sensoryFeedback(.warning, trigger: isBlocked) { _, new in new }
    }

    // MARK: Encabezado e instrucción

    private var header: some View {
        VStack(spacing: 4) {
            Text("Actividad \(position) de \(total)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(Self.title)
                .font(.largeTitle.weight(.heavy))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.instruction)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Label(Self.placement, systemImage: "iphone")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .flatCard()
    }

    // MARK: HUD (vidrio funcional)

    private var hud: some View {
        ZStack {
            ProgressRing(progress: progress.fraction, color: Theme.accent, lineWidth: 18)
            VStack(spacing: 2) {
                Image(systemName: "chair.fill")
                    .font(.title)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: progress.count)
                Text("\(progress.count)")
                    .font(.system(size: counterSize, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy, value: progress.count)
                Text("de \(assignment.target) \(Self.unit)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: ringSize, height: ringSize)
        .padding(22)
        .functionalGlass(cornerRadius: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.count) de \(assignment.target) \(Self.unit)")
    }

    // MARK: Consigna y gate

    private var isBlocked: Bool {
        if case .blocked = progress.gate { return true }
        return false
    }

    @ViewBuilder
    private var command: some View {
        Group {
            switch progress.gate {
            case .calibrating:
                Label(progress.hint.isEmpty ? SitStandCopy.calibrate : progress.hint, systemImage: "hourglass")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.secondary)
            case .blocked(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.danger)
            case .ready:
                HStack(spacing: 12) {
                    Image(systemName: SitStandCopy.symbol(for: progress.hint))
                        .font(.largeTitle)
                        .foregroundStyle(Theme.accent)
                    Text(progress.hint)
                        .font(.largeTitle.weight(.heavy))
                }
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .contentTransition(.opacity)
        .animation(.smooth, value: progress.gate)
        .animation(.smooth, value: progress.hint)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Aviso transitorio del verificador ("Más lento", "Párese con las piernas…").
    @ViewBuilder
    private var feedbackLine: some View {
        if let feedback, feedback.text != progress.hint {
            Label(feedback.text, systemImage: feedback.symbol ?? "info.circle")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }

    // MARK: Pie

    private var footer: some View {
        SecondaryButton(title: ActivityKind.skipLabel, systemImage: "forward.fill") { onSkip() }
            .disabled(showDone || delivered)
            .padding()
    }

    // MARK: Listo.

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

#Preview {
    let assignment = ActivityAssignment(kind: .pararseSentarse, target: 8)
    SitToStandActivityView(runner: PlaceholderRunner(assignment: assignment), assignment: assignment)
}
