import SwiftUI

// Dueño: paquete "profile-onboarding". Alta en 3 pantallas (< 60 s): nombre y trato · turno · zona + consentimiento.

/// Puerta de entrada: muestra el alta si falta y luego el contenido.
/// HomeView NO la usa; la integración la cablea en RootTabView: `RootGate { RootTabView() }`.
struct RootGate<Content: View>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            if store.profile.onboardingDone {
                content()
                    .transition(.opacity)
            } else {
                OnboardingView(onDone: {})
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: store.profile.onboardingDone)
        // Solo DEBUG: argumentos de lanzamiento para capturas de QA (ver QALaunch.swift).
        .qaLaunchHook()
    }
}

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    private let onDone: () -> Void

    private static let stepCount = 3

    @State private var step = 0
    @State private var name = ""
    @State private var treatment: Treatment = .usted
    @State private var roster: Roster = .sieteXSiete
    @State private var rosterStart = Calendar.current.startOfDay(for: .now)
    @State private var shiftType: ShiftType = .day
    @State private var zones: [PainZone] = [.lumbar]
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepIndicator
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                ZStack {
                    ScrollView {
                        Group {
                            switch step {
                            case 0: nameStep
                            case 1: shiftStep
                            default: zoneStep
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .id(step)
                    .transition(stepTransition)
                }
                // Reduce Motion: sin deslizamiento ni animación entre pasos.
                .animation(reduceMotion ? nil : .snappy, value: step)
            }
            .safeAreaInset(edge: .bottom) { footer }
            .appScreen()
            .toolbar {
                if step > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Atrás", systemImage: "chevron.left", action: back)
                    }
                }
            }
            .onAppear(perform: prefill)
        }
        .tint(Theme.accent)
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                           removal: .move(edge: .leading).combined(with: .opacity))
    }

    // MARK: - Indicador y pie

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.stepCount, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Theme.accent : Color.primary.opacity(0.12))
                    .frame(height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Paso \(step + 1) de \(Self.stepCount)")
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if step < Self.stepCount - 1 {
                PrimaryButton(title: "Seguir", systemImage: "arrow.right", isEnabled: canContinue, action: next)
            } else {
                PrimaryButton(title: "Acepto y empiezo", systemImage: "checkmark", action: finish)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var canContinue: Bool {
        step != 0 || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Paso 1: nombre y trato

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hola.")
                .font(.largeTitle.weight(.bold))
            Text("Activate le ayuda a hacer la pausa en el turno y a saber si la espalda va mejor. Partamos por su nombre.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("Su nombre de pila").font(.headline)
                TextField("Nombre", text: $name)
                    .font(.title3.weight(.semibold))
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($nameFocused)
                    .onSubmit { if canContinue { next() } }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
                    .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 14))
            }
            .flatCard()
            VStack(alignment: .leading, spacing: 10) {
                Text("¿Cómo le hablamos?").font(.headline)
                ProfileChoiceRow(
                    items: [
                        .init(value: Treatment.usted, title: "De usted"),
                        .init(value: Treatment.tu, title: "De tú"),
                    ],
                    selection: $treatment)
            }
            .flatCard()
        }
    }

    // MARK: - Paso 2: turno

    private var shiftStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Su turno")
                .font(.largeTitle.weight(.bold))
            Text("Con esto la app sabe qué día del turno es y cuida su racha en la bajada.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("Sistema").font(.headline)
                ProfileChoiceRow(
                    items: Roster.allCases.map { .init(value: $0, title: $0.rawValue) },
                    selection: $roster,
                    columns: 4)
            }
            .flatCard()
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Día que subo", selection: $rosterStart, displayedComponents: .date)
                    .font(.headline)
                    .frame(minHeight: Theme.rowHeight)
                Text("Si está de bajada, ponga el próximo día que sube.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .flatCard()
            VStack(alignment: .leading, spacing: 10) {
                Text("Horario").font(.headline)
                ProfileChoiceRow(
                    items: [
                        .init(value: ShiftType.day, title: "Día", symbol: "sun.max.fill"),
                        .init(value: ShiftType.night, title: "Noche", symbol: "moon.fill"),
                    ],
                    selection: $shiftType)
            }
            .flatCard()
            Label(previewLine, systemImage: "calendar")
                .font(.headline)
                .foregroundStyle(Theme.accent)
        }
    }

    private var previewLine: String {
        let calendar = WorkCalendar(roster: roster, rosterStart: rosterStart, boundaryHour: shiftType.dayBoundaryHour)
        let n = calendar.dayInBlock(for: .now)
        switch calendar.kind(for: .now) {
        case .turno: return "Hoy: día \(n) de \(roster.workDays) de turno."
        case .descanso: return "Hoy: bajada, día \(n) de \(roster.restDays)."
        }
    }

    // MARK: - Paso 3: zona + consentimiento

    private var zoneStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("¿Dónde le duele?")
                .font(.largeTitle.weight(.bold))
            Text("Marque una o más zonas. En cada pausa puede cambiarlas.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ProfilePainZonePicker(selection: $zones)
                .flatCard()
            VStack(alignment: .leading, spacing: 10) {
                Label("Sus datos quedan en el teléfono", systemImage: "lock.shield.fill")
                    .font(.headline)
                Text("Sus respuestas sobre el dolor y los datos de su cara son sensibles. Se procesan solo en este iPhone. Nada se comparte sin que usted lo decida.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink {
                    ConsentView()
                } label: {
                    HStack {
                        Text("Leer el consentimiento completo").font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .flatCard()
        }
    }

    // MARK: - Acciones

    private func prefill() {
        let profile = store.profile
        name = profile.name
        treatment = profile.treatment
        roster = profile.roster
        rosterStart = profile.rosterStart
        shiftType = profile.shiftType
        zones = profile.allUsualZones
    }

    private func next() {
        nameFocused = false
        step = min(Self.stepCount - 1, step + 1)
    }

    private func back() {
        step = max(0, step - 1)
    }

    private func finish() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = Calendar.current.startOfDay(for: rosterStart)
        store.mutate { data in
            if !trimmed.isEmpty { data.profile.name = trimmed }
            data.profile.treatment = treatment
            data.profile.roster = roster
            data.profile.rosterStart = start
            data.profile.shiftType = shiftType
            data.profile.setUsualZones(zones)
            data.profile.consentGiven = true
            data.profile.onboardingDone = true
        }
        onDone()
    }
}

#Preview("Onboarding") {
    OnboardingView(onDone: {})
        .environment(AppStore(inMemory: true))
}

#Preview("RootGate") {
    let store = AppStore(inMemory: true)
    RootGate {
        Text("Contenido")
    }
    .environment(store)
}
