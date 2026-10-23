import SwiftUI

// Dueño: paquete "stroop-breath".

/// Pantalla del test de Stroop (A10). Un ensayo a la vez: palabra grande pintada con la tinta,
/// cuatro botones de color de 64 pt. Habla con `StroopVerifier` a través de `runner.cue`
/// (formato documentado en StroopVerifier.swift) y de `source.push(_:)`.
/// Los tiempos se miden con `ScreenSource.elapsedMs` (ContinuousClock) en el instante en que se
/// cambia el estado a "estímulo" y en el toque; el render del frame siguiente añade < 1 cuadro.
struct StroopView: View {
    let runner: any ActivityRunning
    let source: ScreenSource

    @Environment(\.outdoorMode) private var outdoor
    @State private var stage: Stage = .intro
    @State private var pacer: Task<Void, Never>? = nil
    @State private var answeredCount = 0

    private enum Stage: Equatable {
        case intro
        case armed
        case blank(StroopCue)
        case stimulus(StroopCue)
        case answered
        case done
    }

    /// Alto mínimo de la tarjeta del estímulo; crece con Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var stimulusHeight: CGFloat = 200
    /// Tamaño de la palabra, relativo a `.largeTitle` (crece con Dynamic Type; se achica si no cabe).
    @ScaledMetric(relativeTo: .largeTitle) private var wordSize: CGFloat = 64
    /// Alto mínimo de las teclas de color.
    @ScaledMetric(relativeTo: .headline) private var keyHeight: CGFloat = 64

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                stimulusCard
                keypad
            }
            .padding()
        }
        .scrollBounceBehavior(.basedOnSize)
        .appScreen()
        .task {
            if !runner.isRunning && runner.outcome == nil { runner.start() }
        }
        .onChange(of: runner.cue) { _, cue in
            if let cue { handle(cue) }
        }
        .onChange(of: runner.outcome) { _, outcome in
            if outcome != nil {
                pacer?.cancel()
                stage = .done
            }
        }
        .onDisappear { pacer?.cancel() }
        .sensoryFeedback(.selection, trigger: answeredCount)
    }

    // MARK: - Partes

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ActivityKind.stroop.name).font(.title2.weight(.bold))
            Spacer()
            Text("\(runner.progress.count) de \(runner.progress.target)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(runner.progress.count) de \(runner.progress.target) ensayos")
        }
    }

    @ViewBuilder
    private var stimulusCard: some View {
        ZStack {
            switch stage {
            case .intro:
                VStack(spacing: 14) {
                    Text("Toque el color, no lo que dice")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("No la palabra.").font(.title3).foregroundStyle(.secondary)
                    PrimaryButton(title: "Empezar", systemImage: "play.fill") { ready() }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .frame(minHeight: stimulusHeight)
                .flatCard(padding: 0)
            case .armed, .blank, .answered:
                darkCard {
                    Text("+")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .accessibilityHidden(true)
                }
            case .stimulus(let cue):
                darkCard {
                    Text(cue.wordText)
                        .font(.system(size: wordSize, weight: .black, design: .rounded))
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                        .foregroundStyle(Self.inkColor(cue.ink))
                        .padding(.horizontal, 12)
                        .accessibilityLabel("Palabra \(cue.wordText), escrita en color \(cue.inkText)")
                }
            case .done:
                darkCard {
                    Text(runner.progress.hint.isEmpty ? "Listo." : runner.progress.hint)
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 12)
                }
            }
        }
        .animation(nil, value: stage)
    }

    private func darkCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(minHeight: stimulusHeight)
            .background(Theme.night, in: .rect(cornerRadius: Theme.cardRadius))
    }

    private var keypad: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        let enabled: Bool = { if case .stimulus = stage { return true } else { return false } }()
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(0..<StroopVerifier.colorCount, id: \.self) { k in
                Button { tap(k) } label: {
                    Text(StroopVerifier.colorNames[k].capitalized)
                        .font(.headline)
                        .foregroundStyle(Self.labelColor(k))
                        .frame(maxWidth: .infinity, minHeight: keyHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(Self.inkColor(k).opacity(enabled ? 1 : 0.45), in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(outdoor ? 0.35 : 0.12), lineWidth: 1.5))
                .disabled(!enabled)
                .accessibilityLabel(StroopVerifier.colorNames[k].capitalized)
            }
        }
    }

    // MARK: - Protocolo con el verificador

    private func ready() {
        guard stage == .intro else { return }
        stage = .armed
        source.push(.touchUp(t: source.elapsedSeconds))
    }

    private func handle(_ cue: Cue) {
        guard let trial = StroopCue(cue: cue) else { return }
        pacer?.cancel()
        stage = .blank(trial)
        pacer = Task {
            try? await Task.sleep(for: .milliseconds(trial.isiMs))
            guard !Task.isCancelled else { return }
            present(trial)
            try? await Task.sleep(for: .milliseconds(StroopVerifier.lapseMs))
            guard !Task.isCancelled, stage == .stimulus(trial) else { return }
            // Sin respuesta: lapso.
            source.push(.stroopAnswer(trialIndex: trial.index, answer: StroopVerifier.noResponse, atMs: source.elapsedMs))
            stage = .answered
        }
    }

    private func present(_ trial: StroopCue) {
        let shownAt = source.elapsedMs
        stage = .stimulus(trial)
        source.push(.stroopShown(trialIndex: trial.index, atMs: shownAt))
    }

    private func tap(_ key: Int) {
        guard case .stimulus(let trial) = stage else { return }
        let answeredAt = source.elapsedMs
        pacer?.cancel()
        stage = .answered
        answeredCount += 1
        source.push(.stroopAnswer(trialIndex: trial.index, answer: key, atMs: answeredAt))
    }

    // MARK: - Colores (mismo orden que `StroopVerifier.colorNames`)

    static func inkColor(_ index: Int) -> Color {
        switch index {
        case 0: .red
        case 1: .green
        case 2: .blue
        default: .yellow
        }
    }

    private static func labelColor(_ index: Int) -> Color {
        index == 3 ? Theme.night : .white
    }
}
