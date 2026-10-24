import SwiftUI

/// Flujo de la pausa (fullScreenCover): check-in → alarma? → plan → actividad(i) → cierre → premio.
/// Firma de entrada congelada: `PauseFlowView(moment:)`. Toma AppStore, GameStore y CoachService del entorno.
struct PauseFlowView: View {
    let moment: Moment

    @Environment(AppStore.self) private var store
    @Environment(GameStore.self) private var game
    @Environment(CoachService.self) private var coach
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator: PauseCoordinator?

    var body: some View {
        Group {
            if let coordinator {
                PauseFlowContent(coordinator: coordinator) { close() }
            } else {
                ProgressView()
            }
        }
        .appScreen()
        // Acento azul en todos los controles del flujo (el cobre queda solo para la llama de la racha).
        .tint(Theme.accent)
        .onAppear {
            if coordinator == nil {
                Diagnostics.log("pausa abierta momento=\(moment)")
                coordinator = PauseCoordinator(moment: moment, store: store, game: game, coach: coach)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Diagnostics.log("pausa escena=\(phase) etapa=\(String(describing: coordinator?.stage))")
            switch phase {
            case .background: coordinator?.appWentToBackground()
            case .active: coordinator?.appBecameActive()
            default: break
            }
        }
        .onDisappear {
            Diagnostics.log("pausa desaparece etapa=\(String(describing: coordinator?.stage))")
            coordinator?.cancel()
        }
        .interactiveDismissDisabled()
    }

    private func close() {
        coordinator?.cancel()
        dismiss()
    }
}

/// Contenido por etapa; separado para que el coordinador exista antes del primer render de la etapa.
private struct PauseFlowContent: View {
    let coordinator: PauseCoordinator
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// La X durante los ejercicios pide confirmación: con el teléfono en las manos o en el bolsillo
    /// es fácil tocarla sin querer, y salir pierde lo que lleva la pausa.
    @State private var confirmingClose = false

    /// Etapas en que salir pierde ejercicios ya hechos.
    static func closeNeedsConfirmation(_ stage: PauseCoordinator.Stage) -> Bool {
        switch stage {
        case .activity, .postCheck: true
        case .checkIn, .alarm, .stopped, .planning, .reward: false
        }
    }

    /// Cierre con origen anotado en el registro de diagnóstico.
    private func closing(_ origin: String) -> () -> Void {
        { [coordinator, onClose] in
            Diagnostics.log("cerrar desde \(origin) etapa=\(coordinator.stage)")
            onClose()
        }
    }

    private var name: String { coordinator.profileName }

    var body: some View {
        VStack(spacing: 0) {
            if coordinator.stage != .reward {
                header
            }
            stageView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Reduce Motion: sin deslizamientos ni animación entre etapas (solo aparece la nueva).
        .animation(reduceMotion ? nil : .smooth, value: coordinator.stage)
        .onChange(of: coordinator.stage) { old, new in
            Diagnostics.log("etapa \(old) → \(new)")
            if !Self.closeNeedsConfirmation(new) { confirmingClose = false }
        }
        .confirmationDialog("¿Salir de la pausa?", isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("Salir", role: .destructive) { closing("X confirmada")() }
            Button("Seguir con la pausa", role: .cancel) { Diagnostics.log("X: siguió con la pausa") }
        } message: {
            Text("Lo que lleva de esta pausa no se guarda.")
        }
    }

    // MARK: Encabezado: cerrar + barra de avance

    private var header: some View {
        HStack(spacing: 14) {
            Button("Cerrar", systemImage: "xmark") {
                if Self.closeNeedsConfirmation(coordinator.stage) {
                    Diagnostics.log("X tocada etapa=\(coordinator.stage): pide confirmación")
                    confirmingClose = true
                } else {
                    closing("X")()
                }
            }
                .labelStyle(.iconOnly)
                .font(.headline)
                .foregroundStyle(.primary)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .frame(minWidth: 44, minHeight: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(coordinator.effectiveMoment.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: max(8, geo.size.width * coordinator.progressFraction))
                    }
                }
                .frame(height: 6)
                .animation(reduceMotion ? nil : .spring(duration: 0.5), value: coordinator.progressFraction)
                .accessibilityElement()
                .accessibilityLabel("Avance de la pausa")
                .accessibilityValue("\(Int((coordinator.progressFraction * 100).rounded())) %")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    // MARK: Etapas

    private var stageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                           removal: .move(edge: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var stageView: some View {
        switch coordinator.stage {
        case .checkIn:
            CheckInView(name: name,
                        existing: coordinator.existingCheckIn,
                        initialZones: coordinator.usualZones,
                        initialMoment: coordinator.moment,
                        onSubmit: { answers, zones, moment in coordinator.submitCheckIn(answers: answers, zones: zones, moment: moment) },
                        onContinueExisting: { coordinator.continueWithExistingCheckIn() },
                        onAnswerAgain: { coordinator.answerAgain() })
                .id(coordinator.existingCheckIn?.id)
                .transition(stageTransition)

        case .alarm:
            AlarmView(name: name, score: coordinator.checkIn?.score ?? 0) { coordinator.submitAlarm(answers: $0) }
                .transition(stageTransition)

        case .stopped:
            StopCardView(name: name, reason: coordinator.decision?.reason, onClose: closing("tarjeta de alto"))
                .transition(stageTransition)

        case .planning:
            PlanView(name: name,
                     recipe: coordinator.recipeKind,
                     activities: coordinator.plan,
                     why: coordinator.coachWhy,
                     startMessage: coordinator.coachStartMessage,
                     gentle: coordinator.isGentle,
                     cameraBlocked: coordinator.cameraBlocked,
                     excluded: coordinator.excluded,
                     onStart: { coordinator.startActivities() },
                     onClose: closing("plan"))
                .transition(stageTransition)

        case .activity(let index):
            if let runner = coordinator.runner, coordinator.plan.indices.contains(index) {
                let assignment = coordinator.plan[index]
                if assignment.kind.sensorBlock == .screen, let source = runner.screenSource {
                    // Stroop / respiración: la vista alimenta la MISMA `ScreenSource` que consume el runner.
                    ScreenActivityView(runner: runner,
                                       source: source,
                                       assignment: assignment,
                                       position: index + 1,
                                       total: coordinator.plan.count,
                                       onFinish: { coordinator.activityFinished($0, at: index) },
                                       onSkip: { coordinator.skipCurrent() })
                        .id(coordinator.runnerGeneration)
                        .transition(stageTransition)
                } else if assignment.kind == .pararseSentarse {
                    // Teléfono en el bolsillo delantero del pantalón: contador y vibración, sin cámara.
                    SitToStandActivityView(runner: runner,
                                           assignment: assignment,
                                           position: index + 1,
                                           total: coordinator.plan.count,
                                           onFinish: { coordinator.activityFinished($0, at: index) },
                                           onSkip: { coordinator.skipCurrent() })
                        .id(coordinator.runnerGeneration)
                        .transition(stageTransition)
                } else if HandheldActivityView.handles(assignment.kind), runner.isHandheldRunner {
                    // Sentadilla y extensión lumbar en las manos: contador sin imagen de cámara.
                    HandheldActivityView(runner: runner,
                                         assignment: assignment,
                                         position: index + 1,
                                         total: coordinator.plan.count,
                                         onFinish: { coordinator.activityFinished($0, at: index) },
                                         onSkip: { coordinator.skipCurrent() })
                        .id(coordinator.runnerGeneration)
                        .transition(stageTransition)
                } else {
                    ActivityRunView(runner: runner,
                                    assignment: assignment,
                                    position: index + 1,
                                    total: coordinator.plan.count,
                                    onFinish: { coordinator.activityFinished($0, at: index) },
                                    onSkip: { coordinator.skipCurrent() })
                        .id(coordinator.runnerGeneration)
                        .transition(stageTransition)
                }
            } else {
                // Relevo entre bloques de sensor o runner aún no creado.
                ProgressView(coordinator.plan.indices.contains(index)
                             ? coordinator.plan[index].kind.sensorBlock.preparingCopy
                             : "Preparando sensor…")
                    .transition(.opacity)
            }

        case .postCheck:
            PostCheckView(name: name) { coordinator.submitPost($0) }
                .transition(stageTransition)

        case .reward:
            if let reward = coordinator.reward {
                CelebrationView(reward: reward, post: coordinator.post, onClose: closing("celebración"))
                    .safeAreaInset(edge: .top, spacing: 0) {
                        // Simulador: la pausa no usó sensores reales y no suma.
                        if coordinator.session?.simulated == true {
                            SimulatedNotice()
                                .padding(.top, 4)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .transition(.opacity)
            } else {
                ProgressView("Guardando…")
                    .transition(.opacity)
            }
        }
    }
}
