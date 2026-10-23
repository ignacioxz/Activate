import SwiftUI
import UserNotifications

// Dueño: paquete "profile-onboarding". Perfil: nombre y trato, turno, zona, pantalla, insignias, rango y Demo.

/// Rangos del prototipo, solo como etiqueta en Perfil (sin ligas ni rankings).
enum ProfileRank {
    static let xpPerLevel = 150
    static let names = ["Aprendiz", "Operador", "Operador experto", "Capataz", "Jefe de turno", "Superintendente"]

    static func level(xp: Int) -> Int { max(0, xp) / xpPerLevel + 1 }

    static func title(xp: Int) -> String {
        names[min(names.count - 1, (level(xp: xp) - 1) / 2)]
    }

    /// Avance dentro del nivel actual (0...1).
    static func progress(xp: Int) -> Double {
        Double(max(0, xp) % xpPerLevel) / Double(xpPerLevel)
    }
}

/// Perfil de Marco. Todo cambio pasa por `store.mutate`.
struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(GameStore.self) private var game
    @Environment(CoachService.self) private var coach
    @State private var draftName = ""
    @State private var confirmReset = false
    @State private var notificationsDenied = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    rankCard
                    identityCard
                    shiftCard
                    painCard
                    screenCard
                    badgesCard
                    demoCard
                    privacyCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .appScreen()
            .navigationTitle("Perfil")
            .onAppear {
                draftName = store.profile.name
                coach.override = store.data.demo.coachOverride
            }
            .onChange(of: nameFocused) { _, focused in
                if !focused { commitName() }
            }
            .confirmationDialog("¿Borrar todo?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Borrar todo", role: .destructive, action: resetAll)
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se borran su perfil, sus pausas y sus registros de dolor. No se puede deshacer.")
            }
        }
    }

    // MARK: - Rango

    private var rankCard: some View {
        let xp = store.profile.xp
        let cascos = store.profile.cascos
        return HStack(spacing: 16) {
            ZStack {
                ProgressRing(progress: ProfileRank.progress(xp: xp), color: Theme.gold, lineWidth: 8)
                Text("\(ProfileRank.level(xp: xp))")
                    .font(.title2.weight(.heavy))
                    .contentTransition(.numericText())
            }
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.profile.name)
                    .font(.title.weight(.heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(ProfileRank.title(xp: xp))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.copper)
                Text("\(xp) XP · \(game.streak) días seguidos · \(cascos) \(cascos == 1 ? "casco" : "cascos")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .flatCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(store.profile.name), nivel \(ProfileRank.level(xp: xp)), \(ProfileRank.title(xp: xp)), \(xp) XP")
    }

    // MARK: - Nombre y trato

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Su nombre", subtitle: "Así le hablamos en la app.")
            TextField("Nombre de pila", text: $draftName)
                .font(.title3.weight(.semibold))
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .onSubmit(commitName)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
                .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 14))
            Text("¿Cómo le hablamos?").font(.headline)
            ProfileChoiceRow(
                items: [
                    .init(value: Treatment.usted, title: "De usted"),
                    .init(value: Treatment.tu, title: "De tú"),
                ],
                selection: profileBinding(\.treatment)
            )
        }
        .flatCard()
    }

    // MARK: - Turno

    private var shiftCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Su turno", subtitle: todayLine)
            Text("Sistema").font(.headline)
            ProfileChoiceRow(
                items: Roster.allCases.map { .init(value: $0, title: $0.rawValue) },
                selection: profileBinding(\.roster),
                columns: 4
            )
            DatePicker("Día que subo", selection: rosterStartBinding, displayedComponents: .date)
                .font(.headline)
                .frame(minHeight: Theme.rowHeight)
            Text("Horario").font(.headline)
            ProfileChoiceRow(
                items: [
                    .init(value: ShiftType.day, title: "Día", symbol: "sun.max.fill"),
                    .init(value: ShiftType.night, title: "Noche", symbol: "moon.fill"),
                ],
                selection: profileBinding(\.shiftType)
            )
            Text("El día laboral cambia a las \(store.profile.shiftType.dayBoundaryHour):00. La bajada no corta su racha.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .flatCard()
    }

    private var todayLine: String {
        let calendar = store.calendar
        let n = calendar.dayInBlock(for: .now)
        switch calendar.kind(for: .now) {
        case .turno: return "Hoy: día \(n) de \(store.profile.roster.workDays) de turno."
        case .descanso: return "Hoy: bajada, día \(n) de \(store.profile.roster.restDays)."
        }
    }

    // MARK: - Dolor

    private var painCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Dónde le duele", subtitle: "Zona habitual. En cada pausa puede cambiarla.")
            ProfilePainZonePicker(selection: profileBinding(\.usualZone), showsSilhouette: false)
        }
        .flatCard()
    }

    // MARK: - Pantalla y avisos

    private var screenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Pantalla y avisos")
            Toggle(isOn: profileBinding(\.outdoorMode)) {
                toggleLabel("Modo exterior", detail: "Para el sol: fondos opacos y controles grandes.", symbol: "sun.max.trianglebadge.exclamationmark")
            }
            .frame(minHeight: Theme.rowHeight)
            Divider()
            Toggle(isOn: notificationsBinding) {
                toggleLabel("Aviso diario", detail: "Uno por día de turno, al llegar al campamento, solo si no hizo la pausa.", symbol: "bell.badge")
            }
            .frame(minHeight: Theme.rowHeight)
            if notificationsDenied {
                Text("Los avisos están apagados en Ajustes del iPhone.")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }
        }
        .flatCard()
    }

    private func toggleLabel(_ title: String, detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.copper)
        }
    }

    // MARK: - Insignias

    private var badgesCard: some View {
        let earned = store.profile.badges
        return VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Insignias", subtitle: "\(earned.count) de \(Badge.allCases.count) ganadas")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 16) {
                ForEach(Badge.allCases) { badge in
                    ProfileBadgeTile(badge: badge, earned: earned.contains(badge))
                }
            }
        }
        .flatCard()
    }

    // MARK: - Demo

    private var demoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Demo", subtitle: "Solo para el pitch.")
            Toggle("Modo demo", isOn: demoBinding(\.enabled))
                .font(.headline)
                .frame(minHeight: 56)
            Toggle("Metas cortas", isOn: demoBinding(\.shortTargets))
                .font(.headline)
                .frame(minHeight: 56)
            Toggle("Avisos silenciados", isOn: demoBinding(\.notificationsMuted))
                .font(.headline)
                .frame(minHeight: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text("Coach").font(.headline)
                Picker("Coach", selection: coachOverrideBinding) {
                    Text("Auto").tag(CoachOverride.auto)
                    Text("Reglas").tag(CoachOverride.rules)
                    Text("IA").tag(CoachOverride.ai)
                }
                .pickerStyle(.segmented)
                Text(coachLine).font(.footnote).foregroundStyle(.secondary)
            }
            Divider()
            NavigationLink {
                DemoPreflightView()
            } label: {
                HStack {
                    Label("Chequeo previo", systemImage: "checklist").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .frame(minHeight: 56)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            SecondaryButton(title: "Cargar demo (Marco, día 2)", systemImage: "square.and.arrow.down", action: loadDemo)
            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Label("Reiniciar todo", systemImage: "trash")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(.rect)
            }
            .buttonStyle(.bordered)
        }
        .flatCard()
    }

    private var coachLine: String {
        let backend = coach.backend == .foundationModels ? "IA local" : "reglas"
        switch coach.availability {
        case .available: return "Ahora: \(backend). Apple Intelligence disponible."
        case .deviceNotEligible: return "Ahora: \(backend). Este equipo no tiene Apple Intelligence."
        case .notEnabled: return "Ahora: \(backend). Apple Intelligence apagada en Ajustes."
        case .modelNotReady: return "Ahora: \(backend). El modelo aún se descarga."
        case .localeUnsupported: return "Ahora: \(backend). Idioma no soportado: use Español (Chile)."
        case .unknown: return "Ahora: \(backend)."
        }
    }

    // MARK: - Privacidad

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Privacidad", subtitle: "Nada sale del teléfono.")
            NavigationLink {
                ConsentView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: store.profile.consentGiven ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(store.profile.consentGiven ? Theme.mint : Theme.copper)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Consentimiento").font(.headline)
                        Text(store.profile.consentGiven ? "Aceptado" : "Pendiente")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .frame(minHeight: 56)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Divider()
            Text("Cuestionario de espalda").font(.headline)
            Text(RDQ6.citation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .flatCard()
    }

    // MARK: - Bindings y acciones

    private func profileBinding<T>(_ keyPath: WritableKeyPath<PlayerProfile, T>) -> Binding<T> {
        Binding(
            get: { store.profile[keyPath: keyPath] },
            set: { value in store.mutate { $0.profile[keyPath: keyPath] = value } }
        )
    }

    private func demoBinding<T>(_ keyPath: WritableKeyPath<DemoConfig, T>) -> Binding<T> {
        Binding(
            get: { store.data.demo[keyPath: keyPath] },
            set: { value in store.mutate { $0.demo[keyPath: keyPath] = value } }
        )
    }

    private var rosterStartBinding: Binding<Date> {
        Binding(
            get: { store.profile.rosterStart },
            set: { date in store.mutate { $0.profile.rosterStart = Calendar.current.startOfDay(for: date) } }
        )
    }

    private var coachOverrideBinding: Binding<CoachOverride> {
        Binding(
            get: { store.data.demo.coachOverride },
            set: { value in
                store.mutate { $0.demo.coachOverride = value }
                coach.override = value
            }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { store.profile.notificationsOptIn },
            set: { enable in
                guard enable else {
                    store.mutate { $0.profile.notificationsOptIn = false }
                    return
                }
                Task { await enableNotifications() }
            }
        )
    }

    private func enableNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        notificationsDenied = !granted
        store.mutate { $0.profile.notificationsOptIn = granted }
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draftName = store.profile.name
            return
        }
        guard trimmed != store.profile.name else { return }
        store.mutate { $0.profile.name = trimmed }
    }

    /// Semilla "Marco, día 2" (paquete store): reemplaza todo el estado y deja el alta hecha.
    private func loadDemo() {
        DemoSeed.load(into: store, now: .now)
        draftName = store.profile.name
        coach.override = store.data.demo.coachOverride
        notificationsDenied = false
    }

    private func resetAll() {
        let fresh = SaveData(profile: PlayerProfile(rosterStart: Calendar.current.startOfDay(for: .now)))
        store.replace(with: fresh)
        draftName = fresh.profile.name
        coach.override = fresh.demo.coachOverride
        notificationsDenied = false
    }
}

// MARK: - Componentes compartidos del paquete (Perfil y Onboarding)

/// Botones grandes (64 pt) para elegir una opción con guantes.
struct ProfileChoiceRow<Option: Hashable>: View {
    struct Item: Identifiable {
        var value: Option
        var title: String
        var symbol: String? = nil
        var id: Option { value }
    }

    var items: [Item]
    @Binding var selection: Option
    var columns: Int = 2

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: max(1, columns)), spacing: 10) {
            ForEach(items) { item in
                let selected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    HStack(spacing: 8) {
                        if let symbol = item.symbol {
                            Image(systemName: symbol)
                        }
                        Text(item.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
                    .contentShape(.rect)
                }
                .buttonStyle(.bordered)
                .tint(selected ? Theme.copper : .gray)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Zona de dolor: silueta simple con marcador y 4 botones grandes.
struct ProfilePainZonePicker: View {
    @Binding var selection: PainZone
    var showsSilhouette = true

    var body: some View {
        VStack(spacing: 14) {
            if showsSilhouette {
                ProfileSilhouette(zone: selection)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
            }
            ProfileChoiceRow(
                items: PainZone.allCases.map { .init(value: $0, title: $0.title, symbol: Self.symbol(for: $0)) },
                selection: $selection
            )
        }
    }

    static func symbol(for zone: PainZone) -> String {
        switch zone {
        case .lumbar: "figure.walk"
        case .cuello: "person.bust"
        case .hombro: "figure.arms.open"
        case .otra: "circle.dashed"
        }
    }
}

/// Silueta de pie con un punto cobre en la zona elegida.
struct ProfileSilhouette: View {
    let zone: PainZone

    /// Posición relativa (x, y) del marcador sobre la figura.
    private var marker: CGPoint? {
        switch zone {
        case .cuello: CGPoint(x: 0.5, y: 0.2)
        case .hombro: CGPoint(x: 0.62, y: 0.3)
        case .lumbar: CGPoint(x: 0.5, y: 0.5)
        case .otra: nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(systemName: "figure.stand")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary.opacity(0.6))
                    .frame(width: geo.size.width, height: geo.size.height)
                if let marker {
                    Circle()
                        .fill(Theme.copper)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Theme.copper.opacity(0.35), lineWidth: 10))
                        .position(x: geo.size.width * marker.x, y: geo.size.height * marker.y)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: zone)
        }
        .accessibilityHidden(true)
    }
}

private struct ProfileBadgeTile: View {
    let badge: Badge
    let earned: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: badge.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(earned ? Color.white : Color.secondary)
                .frame(width: 60, height: 60)
                .background(earned ? AnyShapeStyle(Theme.copper) : AnyShapeStyle(.quaternary), in: .circle)
            Text(badge.title)
                .font(.caption.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(earned ? "Ganada" : "Pendiente")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .opacity(earned ? 1 : 0.65)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(badge.title): \(badge.detail) \(earned ? "Ganada." : "Pendiente.")")
    }
}

#Preview {
    let store = AppStore(inMemory: true)
    ProfileView()
        .environment(store)
        .environment(GameStore(store: store))
        .environment(CoachService())
        .environment(SensorHub())
}
