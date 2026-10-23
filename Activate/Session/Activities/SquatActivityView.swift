import AVFoundation
import SwiftUI

/// A3 sentadilla parcial dentro del flujo de pausa: selector sobrio de modo ("En las manos" por defecto ·
/// "Apoyado"), instrucción corta, contador con anillo, consigna grande del desafío, gate visible, háptica
/// por rep y "Saltar (no suma)". No hay botón "hecho": solo el runner cierra la actividad.
/// En demo, una línea gris con lo que bajaron el teléfono y la cara (para calibrar en el iPhone).
struct SquatActivityView: View {
    let runner: SquatRunner
    let assignment: ActivityAssignment
    var position: Int = 1
    var total: Int = 1
    var onFinish: (ActivityOutcome) -> Void = { _ in }
    var onSkip: () -> Void = {}

    /// Segundos que se muestra "Listo." antes de pasar a la siguiente actividad.
    static let handoffSeconds: Double = 1.1
    /// Alto de la tarjeta del contador (con el preview de la cámara de fondo en el modo apoyado).
    static let cardHeight: CGFloat = 340

    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: SquatMode
    @State private var showDone = false
    @State private var delivered = false
    @State private var debugReference: HandheldSquatSample?
    @ScaledMetric(relativeTo: .largeTitle) private var counterSize: CGFloat = 76
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 220

    init(runner: SquatRunner, assignment: ActivityAssignment, position: Int = 1, total: Int = 1,
         onFinish: @escaping (ActivityOutcome) -> Void = { _ in }, onSkip: @escaping () -> Void = {}) {
        self.runner = runner
        self.assignment = assignment
        self.position = position
        self.total = total
        self.onFinish = onFinish
        self.onSkip = onSkip
        _mode = State(initialValue: runner.mode)
    }

    private var progress: VerifierProgress { runner.progress }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    modePicker
                    Text(mode.instructions)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    counterCard
                    challengeBanner
                    gateCopy
                    if store.data.demo.enabled { debugLine }
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
        .onChange(of: progress.gate) { _, gate in
            if gate == .ready { debugReference = runner.handheldTelemetry }
        }
        .onChange(of: progress.count) { _, _ in debugReference = runner.handheldTelemetry }
        .sensoryFeedback(.increase, trigger: progress.count) { old, new in new > old }
        .sensoryFeedback(.success, trigger: showDone) { _, new in new }
        .sensoryFeedback(.warning, trigger: isBlocked) { _, new in new }
        .sensoryFeedback(.impact(weight: .medium), trigger: challengeText) { _, new in new != nil }
    }

    // MARK: Encabezado y modo

    private var header: some View {
        VStack(spacing: 4) {
            Text("Actividad \(position) de \(total)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(assignment.kind.name)
                .font(.largeTitle.weight(.heavy))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modePicker: some View {
        Picker("Cómo hacerla", selection: $mode) {
            ForEach(SquatMode.allCases) { m in
                Label(m.title, systemImage: m.symbol).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .tint(Theme.accent)
        .disabled(!runner.canSwitchMode || showDone || delivered)
        .onChange(of: mode) { _, newMode in
            SquatWiring.store(newMode)
            runner.switchMode(newMode)
        }
        .accessibilityHint("Se puede cambiar antes de la primera repetición")
    }

    // MARK: Contador

    private var counterCard: some View {
        ZStack {
            if runner.mode == .supported {
                if let session = runner.captureSession {
                    CameraPreviewView(session: session)
                        .accessibilityLabel("Cámara frontal")
                } else {
                    Color(.secondarySystemBackground)
                        .overlay(alignment: .topLeading) {
                            Label("Cámara frontal", systemImage: "camera.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                }
            } else {
                Color(.secondarySystemBackground)
            }
            counterRing
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private var counterRing: some View {
        ZStack {
            ProgressRing(progress: progress.fraction, color: Theme.accent, lineWidth: 18)
            VStack(spacing: 2) {
                Image(systemName: assignment.kind.symbol)
                    .font(.title)
                    .foregroundStyle(Theme.accent)
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
        .padding(18)
        .functionalGlass(cornerRadius: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.count) de \(assignment.target) \(assignment.kind.unit)")
    }

    // MARK: Desafío y gate

    /// Consigna del desafío vigente ("Quédese abajo 2 segundos").
    private var challengeText: String? {
        guard progress.gate == .ready, let cue = runner.cue, SquatHoldChallenge.cueTexts.contains(cue.text) else { return nil }
        return cue.text
    }

    @ViewBuilder
    private var challengeBanner: some View {
        if let text = challengeText {
            Label(text, systemImage: "pause.circle.fill")
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(Theme.accent)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var isBlocked: Bool {
        if case .blocked = progress.gate { return true }
        return false
    }

    @ViewBuilder
    private var gateCopy: some View {
        VStack(spacing: 8) {
            switch progress.gate {
            case .calibrating:
                Label(progress.hint.isEmpty ? HandheldSquatCopy.holdStill : progress.hint, systemImage: "hourglass")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.secondary)
            case .blocked(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.danger)
            case .ready:
                if challengeText == nil, let cue = runner.cue {
                    Label(cue.text, systemImage: cue.symbol ?? "figure.cross.training")
                        .font(.title2.weight(.heavy))
                } else if challengeText == nil, !progress.hint.isEmpty {
                    Text(progress.hint).font(.title2.weight(.bold))
                }
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .contentTransition(.opacity)
        .animation(.smooth, value: progress.gate)
        .animation(.smooth, value: runner.cue)
    }

    // MARK: Depuración (solo demo)

    private var debugLine: some View {
        Group {
            if runner.mode == .handheld, let s = runner.handheldTelemetry {
                let ref = debugReference ?? s
                let phone = Double(ref.phonePos.y - s.phonePos.y) * 100
                let face = Double(ref.facePos.y - s.facePos.y) * 100
                let source = s.worldTrackingNormal ? "mundo" : "respaldo"
                Text(String(format: "Teléfono %.0f cm · cara %.0f cm · %@ · %.0f°", phone, face, source, s.phonePitchDeg))
            } else if runner.isReplay {
                Text("Depuración: simulado")
            } else {
                Text("Depuración: modo \(runner.mode.title.lowercased())")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.gray)
        .accessibilityHidden(true)
    }

    // MARK: Pie

    private var footer: some View {
        SecondaryButton(title: ActivityKind.skipLabel, systemImage: "forward.end") { onSkip() }
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
                try? await Task.sleep(for: .seconds(Self.handoffSeconds))
                onFinish(outcome)
            }
        } else {
            onFinish(outcome)
        }
    }
}
