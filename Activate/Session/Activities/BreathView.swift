import SwiftUI

// Dueño: paquete "stroop-breath".

/// Pantalla de respiración diafragmática (A8). Un círculo crece al tomar aire (4 s) y se achica
/// al soltarlo (6 s); la persona mantiene el dedo apoyado en el botón grande mientras suelta el
/// aire. Anima con `BreathVerifier.phase(at:)` sobre el reloj de `ScreenSource` y envía
/// `.touchDown` / `.touchUp` al verificador.
struct BreathView: View {
    let runner: any ActivityRunning
    let source: ScreenSource

    @Environment(\.outdoorMode) private var outdoor
    @State private var pressing = false

    private static let circleMax: CGFloat = 220
    private static let circleMinScale: CGFloat = 0.55
    /// Alto de la zona para mantener el dedo (crece con Dynamic Type).
    @ScaledMetric(relativeTo: .headline) private var holdButtonHeight: CGFloat = 80

    var body: some View {
        VStack(spacing: 24) {
            header
            TimelineView(.animation(minimumInterval: 1 / 30, paused: runner.outcome != nil)) { _ in
                let phase = BreathVerifier.phase(at: source.elapsedSeconds)
                breathCircle(phase)
            }
            Text("Mantenga el dedo mientras suelta el aire")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            holdButton
        }
        .padding()
        .appScreen()
        .task {
            if !runner.isRunning && runner.outcome == nil { runner.start() }
        }
        .onChange(of: runner.outcome) { _, outcome in
            if outcome != nil, pressing { release() }
        }
        .onDisappear { if pressing { release() } }
        .sensoryFeedback(.impact(weight: .medium), trigger: runner.progress.count)
    }

    // MARK: - Partes

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ActivityKind.respiracion.name).font(.title2.weight(.bold))
            Spacer()
            Text("\(runner.progress.count) de \(runner.progress.target)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(runner.progress.count) de \(runner.progress.target) ciclos")
        }
    }

    private func breathCircle(_ phase: BreathVerifier.Phase) -> some View {
        let finished = runner.outcome != nil
        let eased = Self.ease(phase.fraction)
        let scale: CGFloat = phase.leadIn
            ? Self.circleMinScale
            : (phase.inhaling
                ? Self.circleMinScale + (1 - Self.circleMinScale) * eased
                : 1 - (1 - Self.circleMinScale) * eased)
        let tint: Color = phase.inhaling ? Theme.sky : Theme.mint
        let label: String = finished ? "Listo." : (phase.leadIn ? "Prepárese" : (phase.inhaling ? "Tome aire" : "Suelte el aire"))
        return ZStack {
            Circle()
                .fill(tint.opacity(outdoor ? 0.5 : 0.25))
                .frame(width: Self.circleMax, height: Self.circleMax)
                .scaleEffect(finished ? 1 : scale)
            Circle()
                .stroke(tint, lineWidth: 6)
                .frame(width: Self.circleMax, height: Self.circleMax)
                .scaleEffect(finished ? 1 : scale)
            Text(label)
                .font(.title.weight(.bold))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.horizontal, 24)
        }
        .frame(height: Self.circleMax + 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var holdButton: some View {
        let finished = runner.outcome != nil
        return ZStack {
            Label(pressing ? "Mantenga" : "Apriete aquí", systemImage: "hand.tap.fill")
                .font(.headline)
                .foregroundStyle(pressing ? Theme.night : .primary)
        }
        .frame(maxWidth: .infinity, minHeight: holdButtonHeight)
        .contentShape(.rect)
        .functionalGlass(tint: pressing ? Theme.mint : nil, cornerRadius: Theme.cardRadius)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(pressing ? Theme.mint : Color.primary.opacity(0.15), lineWidth: pressing ? 4 : 1.5)
        )
        .opacity(finished ? 0.5 : 1)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressing && !finished { press() } }
                .onEnded { _ in if pressing { release() } },
            including: finished ? .none : .all
        )
        .accessibilityLabel("Mantenga apretado mientras suelta el aire")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Dedo

    private func press() {
        pressing = true
        source.push(.touchDown(t: source.elapsedSeconds))
    }

    private func release() {
        pressing = false
        source.push(.touchUp(t: source.elapsedSeconds))
    }

    /// Suavizado seno para el crecimiento del círculo.
    private static func ease(_ x: Double) -> CGFloat {
        let c = min(1, max(0, x))
        return CGFloat(0.5 - 0.5 * cos(c * .pi))
    }
}
