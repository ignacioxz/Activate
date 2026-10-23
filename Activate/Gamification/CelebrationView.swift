import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Dueño: agente "design-celebration". Firma congelada: CelebrationView(reward:post:onClose:).
//
// Escalera sobria por hito (`CelebrationMilestone`):
//   notVerified → "Pausa terminada" + "No pude verificarla. Repita cuando pueda." (sin castigo)
//   day1 / pauseDone → "Pausa cumplida" · Día N de 7 con la casilla llenándose · XP compacto
//   doblete → "Doblete" grande: confeti + háptica AHAP fuerte + símbolo con bounce / drawOn
//   tiroLimpio → "Tiro limpio" + tarjeta para la familia (ImageRenderer → PNG + ShareLink)
// Vidrio solo en el símbolo de celebración, las insignias nuevas y el CTA (un GlassEffectContainer).
// Respeta Reduce Motion (sin confeti, sin bounce, transiciones de opacidad, vidrio `.materialize`) y modo exterior.
// Háptica: una sola por celebración. Pausa contada normal = `.success` (sensoryFeedback);
// Doblete / Tiro limpio = patrón AHAP fuerte de `Haptics.shared.celebrate(strong: true)` en el hito.
// Acento azul (`Theme.accent`) en el botón y las casillas; el cobre queda para la llama.

struct CelebrationView: View {
    let reward: SessionReward
    let post: PostResponse?
    let onClose: () -> Void

    @Environment(AppStore.self) private var store: AppStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var glassNamespace

    @State private var heroShown = false
    @State private var dayShown = 0
    @State private var todayFilled = false
    @State private var xpShown = 0
    @State private var bounceTick = 0
    @State private var confettiShown = false
    @State private var badgesShown = false
    @State private var hapticTick = 0
    @State private var familyCard: FamilyCard? = nil

    private var milestone: CelebrationMilestone { CelebrationMilestone.forReward(reward) }
    private var seed: Int { CelebrationCopy.seed(for: reward) }
    private var treatment: Treatment { store?.profile.treatment ?? .usted }
    private var workDays: Int { store?.profile.roster.workDays ?? 7 }

    /// Tiempos de la escalera (segundos). Con Reduce Motion todo aparece de inmediato.
    private enum Timing {
        static let hero: TimeInterval = 0.15
        static let day: TimeInterval = 0.55
        static let xp: TimeInterval = 0.9
        static let milestone: TimeInterval = 1.1
        static let badges: TimeInterval = 1.5
    }

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 20) {
                VStack(spacing: 20) {
                    hero
                    titleBlock
                    dayStrip
                    if let line = CelebrationCopy.postLine(post) {
                        FactRow(systemImage: postSymbol, text: line, note: CelebrationCopy.postNote(post), tint: Theme.sky)
                    }
                    verificationRow
                    if comodinUsedYesterday {
                        FactRow(systemImage: ComodinInfo.symbol,
                                text: CelebrationCopy.comodinUsedYesterdayLine,
                                tint: Theme.accent)
                    }
                    xpCard
                    if !reward.newBadges.isEmpty && badgesShown {
                        badgesBlock
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                    }
                    if milestone == .tiroLimpio {
                        familyCardBlock
                    }
                    PrimaryButton(title: CelebrationCopy.closeAction, systemImage: "checkmark", tint: Theme.accent) { onClose() }
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 32)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .appScreen()
        .overlay {
            if confettiShown && milestone.usesConfetti {
                ConfettiView(colors: colorScheme == .dark ? Theme.confettiColors : Theme.confettiColorsLight,
                             seed: UInt64(truncatingIfNeeded: abs(seed) + 11))
                    .ignoresSafeArea()
            }
        }
        .sensoryFeedback(.success, trigger: hapticTick) { _, new in new > 0 }
        .onAppear(perform: runLadder)
        .onDisappear { Haptics.shared.release() }
        .task(id: milestone) {
            guard milestone == .tiroLimpio else { return }
            familyCard = renderFamilyCard()
        }
        .accessibilityAction(.escape) { onClose() }
    }

    // MARK: - Escalera

    /// Una sola háptica por celebración: el hito fuerte (Doblete / Tiro limpio) usa el patrón AHAP
    /// y no dispara además el `.success`; la pausa contada normal usa solo el `.success`.
    private var usesStrongHaptic: Bool { CelebrationHaptic.isStrong(milestone) }

    private func runLadder() {
        if reduceMotion {
            heroShown = true
            dayShown = reward.dayInBlock
            todayFilled = reward.counted
            xpShown = reward.totalXP
            badgesShown = true
            if usesStrongHaptic {
                Haptics.shared.celebrate(strong: true)
            } else if reward.counted {
                hapticTick += 1
            }
            return
        }
        dayShown = max(1, reward.dayInBlock - 1)
        schedule(Timing.hero) {
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) { heroShown = true }
            bounceTick += 1
            if reward.counted && !usesStrongHaptic { hapticTick += 1 }
        }
        schedule(Timing.day) {
            withAnimation(.spring(duration: 0.6, bounce: 0.25)) {
                dayShown = reward.dayInBlock
                todayFilled = reward.counted
            }
        }
        schedule(Timing.xp) {
            withAnimation(.easeOut(duration: 0.7)) { xpShown = reward.totalXP }
        }
        if milestone.usesConfetti {
            schedule(Timing.milestone) {
                confettiShown = true
                bounceTick += 1
                if usesStrongHaptic { Haptics.shared.celebrate(strong: true) }
            }
        }
        schedule(Timing.badges) {
            withAnimation(.spring(duration: 0.5, bounce: 0.2)) { badgesShown = true }
        }
    }

    private func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }

    // MARK: - Bloques

    private var heroSymbol: String {
        switch milestone {
        case .tiroLimpio: Badge.tiroLimpio.symbol
        case .doblete: Badge.doblete.symbol
        case .notVerified: "pause.circle"
        case .activityDone, .day1, .pauseDone: "checkmark.circle.fill"
        }
    }

    private var heroColor: Color {
        switch milestone {
        case .tiroLimpio: Theme.gold
        case .doblete: Theme.copperDeep
        case .notVerified: .secondary
        case .activityDone, .day1, .pauseDone: Theme.mint
        }
    }

    private var heroSize: CGFloat { milestone.tier >= 2 ? 150 : 120 }

    /// El símbolo se dibuja (`drawOn`); con Reduce Motion solo aparece.
    private var heroTransition: AnyTransition {
        reduceMotion ? .opacity : AnyTransition(SymbolEffectTransition.symbolEffect(.drawOn))
    }

    private var hero: some View {
        ZStack {
            if heroShown {
                Image(systemName: heroSymbol)
                    .font(.system(size: heroSize * 0.5, weight: .bold))
                    .foregroundStyle(heroColor)
                    .symbolEffect(.bounce, options: .nonRepeating, value: bounceTick)
                    .transition(heroTransition)
            }
        }
        .frame(width: heroSize, height: heroSize)
        .functionalGlass(tint: heroColor, in: Circle())
        .glassEffectID("celebration-hero", in: glassNamespace)
        .glassEffectTransition(reduceMotion ? .materialize : .matchedGeometry)
        .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(CelebrationCopy.title(for: milestone))
                .font(milestone.tier >= 2 ? .system(.largeTitle, design: .rounded).weight(.black) : .largeTitle.weight(.heavy))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Ayer (día de turno) la racha la cuidó el comodín.
    private var comodinUsedYesterday: Bool {
        guard let store else { return false }
        return StreakEngine.usedCascoYesterday(days: store.data.workDays, calendar: store.calendar, at: .now)
    }

    private var subtitle: String {
        switch milestone {
        case .notVerified: CelebrationCopy.notVerifiedLine(treatment: treatment)
        default: CelebrationCopy.phrase(for: milestone, seed: seed)
        }
    }

    private var postSymbol: String {
        switch post {
        case .mejor: "arrow.down.right.circle.fill"
        case .igual: "equal.circle.fill"
        case .peor: "arrow.up.right.circle.fill"
        case nil: "circle"
        }
    }

    private var dayStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(CelebrationCopy.dayLine(dayInBlock: dayShown, workDays: workDays))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                if reward.counted {
                    StreakChip(streak: reward.streak)
                }
            }
            TurnoBoxStrip(days: dayStates, highlighted: reward.dayInBlock)
        }
        .flatCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(CelebrationCopy.dayLine(dayInBlock: reward.dayInBlock, workDays: workDays)). \(CelebrationCopy.streakLine(streak: reward.streak))")
    }

    /// Estado de cada casilla del turno: datos reales del `AppStore` si está en el entorno; si no, se infiere de la racha.
    private var dayStates: [TurnoBoxState] {
        let today = reward.dayInBlock
        var states = [TurnoBoxState](repeating: .pending, count: workDays)
        if let store {
            let turnoKey = store.calendar.turnoKey(for: .now)
            for day in store.data.workDays.values where day.turnoKey == turnoKey && day.kind == .turno {
                guard (1...workDays).contains(day.dayInBlock) else { continue }
                if day.countedPauses > 0 {
                    states[day.dayInBlock - 1] = .done
                } else if day.cascoUsed {
                    states[day.dayInBlock - 1] = .casco
                }
            }
        } else {
            let before = reward.counted ? reward.streak - 1 : reward.streak
            for i in 1..<max(1, today) where i > today - 1 - before {
                states[i - 1] = .done
            }
        }
        if (1...workDays).contains(today) {
            states[today - 1] = todayFilled ? .done : .pending
        }
        return states
    }

    private var verificationRow: some View {
        FactRow(
            systemImage: CelebrationCopy.verificationSymbol(counted: reward.counted, totalXP: reward.totalXP),
            text: CelebrationCopy.verificationLine(counted: reward.counted, totalXP: reward.totalXP, treatment: treatment),
            note: reward.counted ? nil : "No suma ni rompe la racha.",
            tint: reward.counted ? Theme.mint : .secondary
        )
    }

    private var xpCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("XP", systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(CelebrationCopy.xpLine(total: xpShown))
                    .font(.title2.weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(reward.totalXP > 0 ? Theme.gold : .secondary)
                    .contentTransition(.numericText())
            }
            if !reward.lines.isEmpty {
                Divider()
                ForEach(reward.lines) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.label)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Text("+\(line.xp)")
                            .font(.body.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.gold)
                    }
                }
            }
        }
        .flatCard()
        .accessibilityElement(children: .combine)
    }

    private var badgesBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: CelebrationCopy.newBadgeLine(count: reward.newBadges.count))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(reward.newBadges) { badge in
                        BadgeView(badge: badge, namespace: glassNamespace)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            ForEach(reward.newBadges) { badge in
                Text(badge.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Tarjeta para la familia (Tiro limpio)

    private var familyCardBlock: some View {
        VStack(spacing: 12) {
            if let familyCard {
                Image(uiImage: familyCard.image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: Theme.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    .accessibilityLabel("Tarjeta: \(CelebrationCopy.familyCardHeadline), \(CelebrationCopy.familyCardSubline)")
                ShareLink(item: familyCard,
                          preview: SharePreview(CelebrationCopy.familyCardHeadline, image: Image(uiImage: familyCard.image))) {
                    Label(CelebrationCopy.familyCardAction, systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .contentShape(.rect)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: Theme.cardRadius))
            } else {
                FamilyCardView(name: store?.profile.name ?? "", period: periodLabel)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: Theme.cardRadius))
            }
        }
    }

    private var periodLabel: String {
        guard let store else { return "" }
        let cal = store.calendar
        let now = Date.now
        guard let start = cal.date(forKey: cal.turnoKey(for: now)),
              let end = cal.calendar.date(byAdding: .day, value: cal.roster.workDays - 1, to: start) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_CL")
        f.dateFormat = "d MMM"
        return "Turno del \(f.string(from: start)) al \(f.string(from: end))"
    }

    /// `ImageRenderer` no es `Sendable`: se crea y se usa en el MainActor.
    private func renderFamilyCard() -> FamilyCard? {
        let content = FamilyCardView(name: store?.profile.name ?? "", period: periodLabel)
            .frame(width: FamilyCardView.width, height: FamilyCardView.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: FamilyCardView.width, height: FamilyCardView.height)
        guard let image = renderer.uiImage, let png = image.pngData() else { return nil }
        return FamilyCard(png: png, image: image)
    }
}

// MARK: - Fila de dato (plana)

/// Símbolo + texto principal + nota. La respuesta Mejor/Igual/Peor y el nivel de verificación se informan, no se premian.
private struct FactRow: View {
    let systemImage: String
    let text: String
    var note: String? = nil
    var tint: Color = Theme.accent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .flatCard(padding: 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Háptica del hito

/// Qué háptica corresponde a cada hito (lógica pura, testeable).
nonisolated enum CelebrationHaptic {
    /// Doblete y Tiro limpio usan el patrón AHAP fuerte (`Haptics.celebrate(strong: true)`).
    static func isStrong(_ milestone: CelebrationMilestone) -> Bool {
        milestone == .doblete || milestone == .tiroLimpio
    }
}

// MARK: - Casillas del turno

/// `casco` = día cubierto por el comodín (nombre interno).
nonisolated enum TurnoBoxState: Sendable, Hashable { case pending, done, casco }

/// Tira de casillas del turno (7 en 7×7). La del día se llena con animación.
private struct TurnoBoxStrip: View {
    let days: [TurnoBoxState]
    let highlighted: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, state in
                box(number: index + 1, state: state, isToday: index + 1 == highlighted)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func box(number: Int, state: TurnoBoxState, isToday: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(fill(for: state))
            RoundedRectangle(cornerRadius: 10)
                .stroke(isToday ? Theme.accent : Color.primary.opacity(0.15), lineWidth: isToday ? 2.5 : 1)
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark").font(.headline.weight(.heavy)).foregroundStyle(.white)
                case .casco:
                    Image(systemName: ComodinInfo.symbol).font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
                case .pending:
                    Text("\(number)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .scaleEffect(isToday && state == .done ? 1.08 : 1)
        .animation(.spring(duration: 0.5, bounce: 0.3), value: state)
    }

    private func fill(for state: TurnoBoxState) -> Color {
        switch state {
        case .done: Theme.accent
        case .casco: Theme.accent.opacity(0.15)
        case .pending: Color.primary.opacity(0.05)
        }
    }
}

// MARK: - Tarjeta compartible

/// PNG de la tarjeta "Tiro limpio" para compartir por WhatsApp (sin red, sin nube).
nonisolated struct FamilyCard: Transferable, Sendable {
    let png: Data
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { card in card.png }
            .suggestedFileName("tiro-limpio.png")
    }
}

/// Vista plana (sin vidrio: `ImageRenderer` no rasteriza materiales) de la tarjeta para la familia.
struct FamilyCardView: View {
    let name: String
    let period: String

    static let width: CGFloat = 360
    static let height: CGFloat = 450

    var body: some View {
        ZStack {
            Theme.night
            VStack(spacing: 18) {
                Text("ACTIVATE")
                    .font(.caption.weight(.heavy))
                    .tracking(3)
                    .foregroundStyle(Theme.sky)
                BadgeView(badge: .tiroLimpio, style: .flat, size: 120, showsTitle: false)
                VStack(spacing: 6) {
                    Text(CelebrationCopy.familyCardHeadline)
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text(CelebrationCopy.familyCardSubline)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.mint)
                }
                VStack(spacing: 4) {
                    if !name.isEmpty {
                        Text(name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    if !period.isEmpty {
                        Text(period)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                Spacer(minLength: 0)
                Text(CelebrationCopy.familyCardFooter)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(28)
        }
        .frame(width: Self.width, height: Self.height)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Previews

#Preview("Pausa cumplida · Día 3") {
    CelebrationView(
        reward: SessionReward(lines: [RewardLine(label: "Caminata verificada", xp: 20), RewardLine(label: "Cuello verificado", xp: 15)],
                              totalXP: 35, counted: true, streak: 3, dayInBlock: 3, isDoblete: false, isTiroLimpio: false, newBadges: []),
        post: .mejor
    ) {}
}

#Preview("Doblete") {
    CelebrationView(
        reward: SessionReward(lines: [RewardLine(label: "Stroop verificado", xp: 20), RewardLine(label: "Doblete ×2", xp: 20)],
                              totalXP: 40, counted: true, streak: 2, dayInBlock: 2, isDoblete: true, isTiroLimpio: false, newBadges: [.doblete]),
        post: .igual
    ) {}
}

#Preview("Tiro limpio") {
    CelebrationView(
        reward: SessionReward(lines: [RewardLine(label: "Campamento completo", xp: 50)],
                              totalXP: 50, counted: true, streak: 7, dayInBlock: 7, isDoblete: false, isTiroLimpio: true, newBadges: [.tiroLimpio, .rajoCompleto]),
        post: .mejor
    ) {}
}

#Preview("No verificada") {
    CelebrationView(
        reward: SessionReward(lines: [], totalXP: 0, counted: false, streak: 1, dayInBlock: 4, isDoblete: false, isTiroLimpio: false, newBadges: []),
        post: .peor
    ) {}
}
