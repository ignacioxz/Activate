import SwiftUI

/// Flujo de una pausa activa: chequeo de dolor → ejercicios verificados → premio.
struct SessionView: View {
    let lesson: Lesson

    @Environment(GameStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable {
        case checkIn
        case exercise(Int)
        case reward
    }

    @State private var stage: Stage = .checkIn
    @State private var plan: [Exercise] = []
    @State private var painLevel = 2
    @State private var painContext: PainContext = .general
    @State private var earnedXP = 0
    @State private var reward: SessionReward?

    var body: some View {
        VStack(spacing: 0) {
            header
            switch stage {
            case .checkIn:
                checkIn
            case .exercise(let index):
                ExerciseRunView(exercise: plan[index], position: index + 1, total: plan.count) { completed in
                    finishExercise(index, completed: completed)
                }
                .id(index)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            case .reward:
                if let reward {
                    RewardView(reward: reward) { dismiss() }
                } else {
                    noRewardView
                }
            }
        }
        .animation(.smooth, value: stage)
        .background(AppBackground())
        .preferredColorScheme(.dark)
        .fontDesign(.rounded)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button("Cerrar", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.headline)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.lime, .mint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(14, geo.size.width * sessionProgress))
                        .shadow(color: Theme.lime.opacity(0.6), radius: 6)
                }
            }
            .frame(height: 14)
            .animation(.spring, value: sessionProgress)
        }
        .padding()
    }

    private var sessionProgress: Double {
        switch stage {
        case .checkIn: 0
        case .exercise(let i): Double(i) / Double(max(1, plan.count))
        case .reward: 1
        }
    }

    // MARK: Chequeo de dolor

    private var checkIn: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Image(systemName: lesson.symbol)
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.copper.gradient)
                    Text(lesson.title).font(.largeTitle.weight(.heavy))
                    Text("¿Cómo está tu espalda ahora?").font(.title3).foregroundStyle(.secondary)
                }
                .padding(.top)

                HStack(spacing: 8) {
                    ForEach(1...5, id: \.self) { level in
                        Button {
                            withAnimation(.snappy) { painLevel = level }
                        } label: {
                            VStack(spacing: 4) {
                                Text(face(level)).font(.system(size: 34))
                                Text("\(level)").font(.headline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 84)
                            .glassEffect(painLevel == level ? .regular.tint(Theme.painColor(level).opacity(0.5)).interactive()
                                                            : .regular.interactive(),
                                         in: .rect(cornerRadius: 18))
                            .scaleEffect(painLevel == level ? 1.06 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dolor \(level) de 5")
                        .accessibilityAddTraits(painLevel == level ? .isSelected : [])
                    }
                }
                .sensoryFeedback(.selection, trigger: painLevel)

                if painLevel >= 3 {
                    HStack {
                        Text("¿Cuándo aparece?").font(.subheadline.weight(.semibold))
                        Spacer()
                        Picker("¿Cuándo aparece?", selection: $painContext) {
                            ForEach(PainContext.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    .glassCard(cornerRadius: 18)
                }

                painAdvice

                PrimaryButton(title: "COMENZAR", systemImage: "play.fill") { start() }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var painAdvice: some View {
        switch painLevel {
        case 5:
            Label("Dolor 5/5: hoy no fuerces. Haremos solo una caminata suave. Si el dolor sigue o baja a la pierna, avisa a tu supervisor y acude al policlínico de faena.",
                  systemImage: "cross.case.fill")
                .font(.subheadline)
                .glassCard(cornerRadius: 18, tint: .red)
        case 4:
            Label("Dolor alto: adaptamos la pausa con ejercicios suaves. Cuidarte también da XP.",
                  systemImage: "heart.fill")
                .font(.subheadline)
                .glassCard(cornerRadius: 18, tint: Theme.copper)
        default:
            if painContext == .levantarCarga && painLevel >= 3 {
                Label("Tip: al levantar carga, acércala al cuerpo y haz la fuerza con las piernas. Practícalo en «Carga segura».",
                      systemImage: "shippingbox.fill")
                    .font(.subheadline)
                    .glassCard(cornerRadius: 18, tint: Theme.sky)
            }
        }
    }

    private func face(_ level: Int) -> String {
        ["😀", "🙂", "😐", "😣", "😫"][level - 1]
    }

    // MARK: Flujo

    private func start() {
        store.logPain(level: painLevel, context: painLevel >= 3 ? painContext : .general)
        plan = Catalog.plan(for: lesson, pain: painLevel)
        stage = .exercise(0)
    }

    private func finishExercise(_ index: Int, completed: Bool) {
        if completed { earnedXP += plan[index].xp }
        if index + 1 < plan.count {
            stage = .exercise(index + 1)
        } else {
            if earnedXP > 0 {
                reward = store.completeSession(lessonID: lesson.id, baseXP: earnedXP,
                                               adaptedForPain: painLevel >= 4)
            }
            stage = .reward
        }
    }

    private var noRewardView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "figure.stand").font(.system(size: 70)).foregroundStyle(.secondary)
            Text("Sin ejercicios completados").font(.title2.weight(.bold))
            Text("No pasa nada. Vuelve cuando tengas un minuto.").foregroundStyle(.secondary)
            Spacer()
            PrimaryButton(title: "VOLVER", tint: .gray) { dismiss() }
                .padding()
        }
    }
}

/// Un ejercicio con detección en vivo: guardas el iPhone, te mueves y la voz cuenta.
struct ExerciseRunView: View {
    let position: Int
    let total: Int
    let onFinish: (Bool) -> Void
    @State private var tracker: ExerciseTracker

    init(exercise: Exercise, position: Int, total: Int, onFinish: @escaping (Bool) -> Void) {
        self.position = position
        self.total = total
        self.onFinish = onFinish
        self.tracker = ExerciseTracker(exercise: exercise)
    }

    private var exercise: Exercise { tracker.exercise }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    Text("EJERCICIO \(position) DE \(total)")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.copper)
                    Text(exercise.name)
                        .font(.largeTitle.weight(.heavy))
                        .multilineTextAlignment(.center)

                    counter

                    if tracker.hasStarted {
                        Text(tracker.status)
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)
                            .contentTransition(.opacity)
                            .animation(.smooth, value: tracker.status)
                        if exercise.usesMotion && tracker.phase == .running {
                            motionGauge
                        }
                    } else {
                        Text(exercise.instructions)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        if exercise.usesMotion {
                            Label("Sube el volumen: la voz cuenta cada repetición.", systemImage: "speaker.wave.2.fill")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            footer
        }
        .onDisappear { tracker.stop() }
        .sensoryFeedback(.increase, trigger: Int(tracker.count))
        .sensoryFeedback(.success, trigger: tracker.isCompleted)
    }

    private var counter: some View {
        ZStack {
            ProgressRing(progress: tracker.progress, lineWidth: 20)
            VStack(spacing: 2) {
                Image(systemName: exercise.symbol)
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.lime.gradient)
                    .symbolEffect(.bounce, value: Int(tracker.count))
                Text("\(Int(tracker.count))")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: Int(tracker.count))
                Text("de \(exercise.target) \(exercise.unitLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 230, height: 230)
        .padding(.vertical, 6)
    }

    /// Barra en vivo: cuánto te has movido y la marca que hay que pasar.
    private var motionGauge: some View {
        let maxAngle = exercise.threshold * 1.6
        let reached = tracker.liveAngle >= exercise.threshold
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Movimiento").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text(reached ? "¡Cuenta!" : "Llega a la marca")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(reached ? Theme.lime : .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(reached ? Theme.lime.gradient : Theme.copper.gradient)
                        .frame(width: max(14, geo.size.width * min(1, tracker.liveAngle / maxAngle)))
                    Rectangle()
                        .fill(.white)
                        .frame(width: 3)
                        .offset(x: geo.size.width * exercise.threshold / maxAngle)
                }
            }
            .frame(height: 18)
            .animation(.linear(duration: 0.1), value: tracker.liveAngle)
        }
        .glassCard(cornerRadius: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reached ? "Movimiento suficiente" : "Sigue moviéndote hasta la marca")
    }

    @ViewBuilder
    private var footer: some View {
        if tracker.isCompleted {
            VStack(alignment: .leading, spacing: 12) {
                Label("¡Excelente! +\(exercise.xp) XP", systemImage: "checkmark.seal.fill")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Theme.lime)
                PrimaryButton(title: "CONTINUAR") { onFinish(true) }
            }
            .glassCard(cornerRadius: 30, tint: Theme.lime)
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            VStack(spacing: 10) {
                if !tracker.hasStarted {
                    PrimaryButton(title: "EMPEZAR", systemImage: "play.fill") {
                        withAnimation(.smooth) { tracker.start() }
                    }
                }
                #if targetEnvironment(simulator)
                if tracker.hasStarted {
                    Button("Completar (solo simulador)") { tracker.completeForSimulator() }
                        .buttonStyle(.glass)
                }
                #endif
                Button("Saltar ejercicio") { onFinish(false) }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

/// Pantalla de premio al terminar la pausa.
struct RewardView: View {
    let reward: SessionReward
    let onClose: () -> Void
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Theme.gold.opacity(0.5), .clear],
                                             center: .center, startRadius: 10, endRadius: 120))
                        .frame(width: 240, height: 240)
                        .scaleEffect(appeared ? 1.1 : 0.6)
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(LinearGradient(colors: [Theme.gold, Theme.copper],
                                                        startPoint: .top, endPoint: .bottom))
                        .symbolEffect(.bounce, value: appeared)
                        .scaleEffect(appeared ? 1 : 0.3)
                }
                .animation(.spring(duration: 0.7, bounce: 0.5), value: appeared)

                Text("¡Pausa completada!").font(.largeTitle.weight(.heavy))

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        pill("bolt.fill", "+\(reward.totalXP) XP", Theme.gold)
                        pill("diamond.fill", "+\(reward.nuggets)", Theme.copper)
                        pill("flame.fill", "\(reward.streak)", .orange)
                    }
                }

                VStack(spacing: 10) {
                    ForEach(reward.lines) { line in
                        HStack {
                            Text(line.label)
                            Spacer()
                            Text("+\(line.xp) XP").fontWeight(.bold).foregroundStyle(Theme.gold)
                        }
                    }
                }
                .glassCard()

                if reward.shieldEarned {
                    Label("¡Ganaste un casco protector! Úsalo el día que no alcances.", systemImage: "shield.fill")
                        .glassCard(cornerRadius: 18, tint: Theme.sky)
                }

                ForEach(reward.newBadges) { badge in
                    Label("Nueva insignia: \(badge.title)", systemImage: badge.symbol)
                        .font(.headline)
                        .glassCard(cornerRadius: 18, tint: .purple)
                }

                PrimaryButton(title: "VOLVER A FAENA") { onClose() }
            }
            .padding()
        }
        .onAppear { appeared = true }
        .sensoryFeedback(.success, trigger: appeared)
    }

    private func pill(_ symbol: String, _ text: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect()
    }
}

#Preview {
    SessionView(lesson: Catalog.units[0].lessons[0])
        .environment(GameStore(inMemory: true))
}
