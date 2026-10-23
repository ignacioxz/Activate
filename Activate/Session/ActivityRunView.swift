import SwiftUI

/// Una actividad verificada: gating con copy en vivo, consigna grande, contador + anillo en el HUD de vidrio,
/// tick háptico por rep y "Listo." al completar. No hay botón "hecho": solo el runner cierra la actividad.
/// Nunca se muestra la imagen de la cámara: las fuentes de cara (ARKit) miden sin vista.
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
    @ScaledMetric(relativeTo: .largeTitle) private var compactCounterSize: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var compactRingSize: CGFloat = 136
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Opcional: previews y tests no lo inyectan.
    @Environment(AppStore.self) private var store: AppStore?

    private var progress: VerifierProgress { runner.progress }
    /// Cuello: la consigna manda; el contador va compacto y hay barra de avance en vivo.
    private var isNeck: Bool { assignment.kind == .cuello }
    private var showsDebug: Bool { store?.data.demo.enabled == true }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Actividad \(position) de \(total)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text(assignment.kind.name)
                        .font(.largeTitle.weight(.heavy))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if isNeck {
                        hud(compact: true)
                        NeckCuePanel(gate: progress.gate,
                                     cue: runner.cue,
                                     live: progress.live,
                                     hint: progress.hint,
                                     debug: showsDebug ? progress.debug : nil)
                    } else {
                        hud(compact: false)
                        gateCopy
                    }
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
        .sensoryFeedback(.increase, trigger: progress.count) { old, new in new > old }
        .sensoryFeedback(.success, trigger: showDone) { _, new in new }
        .sensoryFeedback(.warning, trigger: isBlocked) { _, new in new }
    }

    // MARK: HUD (vidrio funcional)

    private func hud(compact: Bool) -> some View {
        ZStack {
            ProgressRing(progress: progress.fraction, color: Theme.accent, lineWidth: compact ? 12 : 18)
            VStack(spacing: 2) {
                if !compact {
                    Image(systemName: assignment.kind.symbol)
                        .font(.title)
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.bounce, value: progress.count)
                }
                Text("\(progress.count)")
                    .font(.system(size: compact ? compactCounterSize : counterSize, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy, value: progress.count)
                Text("de \(assignment.target)\(compact ? "" : " \(assignment.kind.unit)")")
                    .font(compact ? .footnote : .subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: compact ? compactRingSize : ringSize, height: compact ? compactRingSize : ringSize)
        .padding(compact ? 16 : 22)
        .functionalGlass(cornerRadius: compact ? 32 : 40)
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

    // MARK: Pie

    private var footer: some View {
        VStack(spacing: 8) {
            Button("Saltar (no suma)") { onSkip() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .disabled(showDone || delivered)
        }
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

/// Cuello: consigna grande con su flecha, barra que se llena mientras gira y "Vuelva al centro" claro.
/// El texto de depuración (ángulos en vivo) solo aparece en modo demo.
struct NeckCuePanel: View {
    let gate: GateState
    let cue: Cue?
    let live: Double?
    let hint: String
    var debug: String? = nil

    @ScaledMetric(relativeTo: .largeTitle) private var arrowSize: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isReturn: Bool { cue?.text == NeckVerifier.cueReturn.text }
    private var fill: Double { min(1, max(0, live ?? 0)) }

    var body: some View {
        VStack(spacing: 14) {
            switch gate {
            case .calibrating:
                Image(systemName: "face.smiling")
                    .font(.system(size: arrowSize, weight: .regular))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
                Text(hint.isEmpty ? ActivityRunView.calibratingCopy : hint)
                    .font(.title2.weight(.bold))
            case .blocked(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: arrowSize * 0.8, weight: .bold))
                    .foregroundStyle(Theme.danger)
                Text(reason)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.danger)
            case .ready:
                if let cue {
                    Image(systemName: cue.symbol ?? "arrow.right")
                        .font(.system(size: arrowSize, weight: .bold))
                        .foregroundStyle(isReturn ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(height: arrowSize * 1.15)
                    Text(cue.text)
                        .font(.title.weight(.heavy))
                    LiveBar(fraction: fill, tint: isReturn ? Color.secondary : Theme.accent)
                    Text(isReturn ? "Cabeza al frente, mirando al teléfono" : "Lento, hasta llenar la barra")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if !hint.isEmpty {
                    Text(hint).font(.title2.weight(.bold))
                }
            }
            if let debug, !debug.isEmpty {
                Text(debug)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: cue)
        .animation(.smooth, value: gate)
        .accessibilityElement(children: .combine)
    }
}

/// Barra plana de avance en vivo (se llena con el ángulo, no con el tiempo).
private struct LiveBar: View {
    let fraction: Double
    let tint: Color
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, geo.size.width * fraction))
                    .opacity(fraction > 0.01 ? 1 : 0)
            }
        }
        .frame(height: height)
        .padding(.horizontal, 8)
        .animation(.linear(duration: 0.08), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Avance del movimiento")
        .accessibilityValue("\(Int((fraction * 100).rounded())) %")
    }
}

/// "Listo." sobre vidrio funcional; lo comparten la vista genérica y las de pantalla (Stroop / respiración).
struct ActivityDoneOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            if reduceMotion {
                doneCheck.transition(.opacity)
            } else {
                doneCheck.transition(.symbolEffect(.drawOn))
            }
            Text(ActivityRunView.doneCopy)
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
}
