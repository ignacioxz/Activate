import SwiftUI

/// A3 sentadilla y A1 extensión lumbar con el teléfono en las manos, dentro del flujo de pausa: instrucción
/// corta, contador con anillo, consigna grande del desafío, gate visible, háptica por rep y "Saltar (no suma)".
/// Nunca se muestra la imagen de la cámara: ARKit mide por detrás. No hay botón "hecho": solo el runner
/// cierra la actividad. En demo, una línea gris de depuración (para calibrar en el iPhone).
struct HandheldActivityView: View {
    let runner: any ActivityRunning
    let assignment: ActivityAssignment
    var position: Int = 1
    var total: Int = 1
    var onFinish: (ActivityOutcome) -> Void = { _ in }
    var onSkip: () -> Void = {}

    /// Segundos que se muestra "Listo." antes de pasar a la siguiente actividad.
    static let handoffSeconds: Double = 1.1
    /// Alto de la tarjeta del contador.
    static let cardHeight: CGFloat = 300

    /// Ejercicios que se hacen con el teléfono en las dos manos frente al pecho.
    static func handles(_ kind: ActivityKind) -> Bool { kind == .sentadilla || kind == .extensionLumbar }

    /// Instrucción de 1-2 frases según el ejercicio.
    static func instructions(for kind: ActivityKind) -> String {
        kind == .extensionLumbar ? HandheldExtensionCopy.instructions : HandheldSquatCopy.instructions
    }

    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDone = false
    @State private var delivered = false
    @State private var debugReference: HandheldSquatSample?
    @ScaledMetric(relativeTo: .largeTitle) private var counterSize: CGFloat = 76
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 220

    private var progress: VerifierProgress { runner.progress }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    Text(Self.instructions(for: assignment.kind))
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
        .sensoryFeedback(.success, trigger: holdDone) { _, new in new }
    }

    // MARK: Encabezado

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

    // MARK: Contador (sin imagen de cámara)

    private var counterCard: some View {
        ZStack {
            Color(.secondarySystemBackground)
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

    /// Consigna del desafío vigente ("Quédese abajo / atrás 2 segundos"). La sentadilla la deja en `progress.hint`
    /// con el avance de la pausa en `progress.live` mientras esté armada (no se pierde bajo otra consigna ni al
    /// recalibrar); la extensión solo la anuncia como consigna.
    private var challengeText: String? {
        guard progress.gate == .ready else { return nil }
        if progress.live != nil, HoldChallengeCopy.allCueTexts.contains(progress.hint) { return progress.hint }
        guard let cue = runner.cue, HoldChallengeCopy.allCueTexts.contains(cue.text) else { return nil }
        return cue.text
    }

    /// Avance 0…1 de la pausa pedida (solo la sentadilla lo publica).
    private var holdFraction: Double? { challengeText == nil ? nil : progress.live }
    private var holdDone: Bool { (holdFraction ?? 0) >= 1 }

    @ViewBuilder
    private var challengeBanner: some View {
        if let text = challengeText {
            VStack(spacing: 12) {
                Label(text, systemImage: "pause.circle.fill")
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let holdFraction {
                    HoldMeter(fraction: holdFraction, animated: !reduceMotion)
                }
            }
            .padding(.vertical, 8)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// Bajo el desafío se sigue mostrando un rechazo ("Doble las rodillas…"), no el mismo desafío ni su "Ya. Suba.".
    private func showsBelowChallenge(_ cue: Cue) -> Bool {
        guard challengeText != nil else { return true }
        return !HoldChallengeCopy.allCueTexts.contains(cue.text) && cue.text != SquatHoldChallenge.doneCue.text
            && cue.text != HandheldSquatCopy.ready
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
                if let cue = runner.cue, showsBelowChallenge(cue) {
                    Label(cue.text, systemImage: cue.symbol ?? assignment.kind.symbol)
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
            if let debug = progress.debug, !debug.isEmpty {
                // Extensión: inclinación del teléfono, cara hacia atrás y encuadre (lo arma el verificador).
                Text(debug)
            } else if let s = runner.handheldTelemetry {
                let ref = debugReference ?? s
                let phone = Double(ref.phonePos.y - s.phonePos.y) * 100
                let face = Double(ref.facePos.y - s.facePos.y) * 100
                let source = s.worldTrackingNormal ? "mundo" : "respaldo"
                Text(String(format: "Teléfono %.0f cm · cara %.0f cm · %@ · %.0f°", phone, face, source, s.phonePitchDeg))
            } else if runner.isHandheldReplay {
                Text("Depuración: simulado")
            } else {
                Text("Depuración: sin datos")
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

/// Barra de la pausa del desafío: se llena mientras se queda abajo y entonces dice "Ya. Suba.". Sin ella, en el
/// iPhone el operador se quedaba ≈ 1 s sin saber cuánto faltaba.
private struct HoldMeter: View {
    let fraction: Double
    var animated = true

    private var clamped: Double { min(1, max(0, fraction)) }
    private var done: Bool { clamped >= 1 }
    private var caption: String {
        if done { return SquatHoldChallenge.doneCue.text }
        return clamped > 0 ? HandheldSquatCopy.holdKeep : HandheldSquatCopy.holdBar
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(done ? Theme.successText : Theme.accent)
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(height: 16)
            .animation(animated ? .linear(duration: 0.15) : nil, value: clamped)
            Text(caption)
                .font(done ? .title2.weight(.heavy) : .title3.weight(.semibold))
                .foregroundStyle(done ? Theme.successText : Color.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue("\(Int((clamped * 100).rounded())) por ciento")
    }
}
