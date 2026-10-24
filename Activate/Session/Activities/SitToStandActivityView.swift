import SwiftUI

// Dueño: agente "sit-to-stand".

/// "Pararse y sentarse" (A4) con el teléfono en el bolsillo delantero del pantalón. Sin cámara ni cara: la
/// pantalla se apaga sola por el sensor de proximidad y todo se siente en la vibración. Contador grande con
/// anillo, instrucción breve, tick háptico por rep, vibración fuerte al cumplir la meta (la misma de la
/// caminata) y "Saltar (no suma)". No hay botón "hecho": solo el runner cierra.
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
    static let pocketCopy = PocketSitStandCopy.pocket
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
        // En el bolsillo la pantalla está apagada: la vibración es la confirmación.
        .onChange(of: progress.count) { old, new in
            if new > old, new < assignment.target { Haptics.shared.pocketTick() }
        }
        .onChange(of: progress.gate) { old, new in
            if new == .ready, old == .calibrating { Haptics.shared.success() }
            if case .blocked = new { Haptics.shared.warning() }
        }
        .task(id: feedback) {
            guard feedback != nil else { return }
            try? await Task.sleep(for: .seconds(Self.feedbackSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { feedback = nil }
        }
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
            Label(Self.pocketCopy, systemImage: "iphone.gen3")
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.instruction)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Label("Vibra en cada vez y vibra fuerte al terminar.", systemImage: "iphone.radiowaves.left.and.right")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .flatCard()
    }

    // MARK: HUD

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

    @ViewBuilder
    private var command: some View {
        Group {
            switch progress.gate {
            case .calibrating:
                Label(progress.hint.isEmpty ? Self.pocketCopy : progress.hint, systemImage: "hourglass")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.secondary)
            case .blocked(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.danger)
            case .ready:
                Label(progress.hint, systemImage: "arrow.up.and.down")
                    .font(.title.weight(.heavy))
                    .foregroundStyle(.primary)
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

    /// Aviso transitorio del verificador ("Más lento", "Párese del todo…").
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
            // Vibración fuerte (la de la meta de pasos): se siente con el teléfono en el bolsillo.
            Haptics.shared.goalReached()
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
