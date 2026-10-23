import SwiftUI
import AVFoundation
import CoreMotion
import ARKit
import UserNotifications

// Dueño: paquete "profile-onboarding". Chequeo previo a la demo: todo verde antes de subir al escenario.
// Los permisos se piden aquí, nunca a mitad de la demo.

/// Umbrales iniciales (se calibran en el iPhone de demo).
private enum PreflightThresholds {
    static let batteryGood: Float = 0.5
    static let batteryLow: Float = 0.2
    static let coachLatencyMaxMs = 3500
    static let pedometerPromptSeconds = 1.5
}

private struct PreflightCheck: Identifiable {
    enum Status {
        case ok, warning, failed, unknown

        var symbol: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failed: "xmark.circle.fill"
            case .unknown: "questionmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .ok: Theme.mint
            case .warning: Theme.gold
            case .failed: Theme.danger
            case .unknown: .secondary
            }
        }

        var label: String {
            switch self {
            case .ok: "listo"
            case .warning: "revisar"
            case .failed: "falla"
            case .unknown: "sin dato"
            }
        }
    }

    enum Group: String, CaseIterable {
        case coach = "Coach"
        case permissions = "Permisos"
        case device = "Equipo"
        case demo = "Demo"
    }

    let id: String
    var group: Group
    var title: String
    var detail: String
    var status: Status
}

struct DemoPreflightView: View {
    @Environment(AppStore.self) private var store
    @Environment(CoachService.self) private var coach
    @Environment(SensorHub.self) private var sensors
    @Environment(\.scenePhase) private var scenePhase
    @State private var checks: [PreflightCheck] = []
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var busy = false
    @State private var lastTest: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCard
                ForEach(PreflightCheck.Group.allCases, id: \.rawValue) { group in
                    let rows = checks.filter { $0.group == group }
                    if !rows.isEmpty {
                        groupCard(group, rows: rows)
                    }
                }
                actionsCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .appScreen()
        .navigationTitle("Chequeo previo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Actualizar", systemImage: "arrow.clockwise") { Task { await refreshAll() } }
                    .disabled(busy)
            }
        }
        .task { await refreshAll() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshAll() } }
        }
        .onChange(of: store.data.demo) { _, _ in refresh() }
    }

    // MARK: - Tarjetas

    private var summaryCard: some View {
        let total = checks.count
        let ready = checks.filter { $0.status == .ok }.count
        let failed = checks.filter { $0.status == .failed }.count
        return HStack(spacing: 16) {
            ZStack {
                ProgressRing(progress: total == 0 ? 0 : Double(ready) / Double(total),
                             color: failed > 0 ? Theme.copper : Theme.mint, lineWidth: 8)
                Text("\(ready)")
                    .font(.title2.weight(.heavy))
                    .contentTransition(.numericText())
            }
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ready) de \(total) listos").font(.title2.weight(.bold))
                Text(failed > 0 ? "\(failed) con falla. Revise antes de la demo." : "Sin fallas. Revise los amarillos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .flatCard()
        .accessibilityElement(children: .combine)
    }

    private func groupCard(_ group: PreflightCheck.Group, rows: [PreflightCheck]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: group.rawValue)
            ForEach(rows) { check in
                PreflightRow(check: check)
                if check.id != rows.last?.id { Divider() }
            }
        }
        .flatCard()
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Acciones", subtitle: "Pida los permisos aquí, no en el escenario.")
            PrimaryButton(title: "Pedir permisos ahora", systemImage: "hand.raised.fill", isEnabled: !busy) {
                Task { await requestPermissions() }
            }
            SecondaryButton(title: "Precalentar coach", systemImage: "flame") {
                coach.prewarm()
                refresh()
            }
            .disabled(busy)
            SecondaryButton(title: "Probar coach", systemImage: "stopwatch") {
                Task { await testCoach() }
            }
            .disabled(busy)
            if busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Trabajando…").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let lastTest {
                Text(lastTest)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .flatCard()
    }

    // MARK: - Chequeos

    private func refreshAll() async {
        coach.refreshAvailability()
        sensors.refreshAvailability()
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        refresh()
    }

    private func refresh() {
        var list: [PreflightCheck] = []

        // Coach
        let availability = coach.availability
        list.append(PreflightCheck(
            id: "ai", group: .coach, title: "Apple Intelligence",
            detail: Self.describe(availability),
            status: availability == .available ? .ok : (availability == .unknown ? .unknown : .failed)))
        let usingAI = coach.backend == .foundationModels
        let rulesOnPurpose = coach.override == .rules
        list.append(PreflightCheck(
            id: "backend", group: .coach, title: "Coach en uso",
            detail: usingAI ? "IA local" : (rulesOnPurpose ? "Reglas (elegido en Demo)" : "Reglas (plantilla de respaldo)"),
            status: usingAI || rulesOnPurpose ? .ok : .warning))
        if let ms = coach.lastLatencyMs {
            list.append(PreflightCheck(
                id: "ttft", group: .coach, title: "Primera respuesta (TTFT)",
                detail: "\(ms) ms · límite \(PreflightThresholds.coachLatencyMaxMs) ms",
                status: ms <= PreflightThresholds.coachLatencyMaxMs ? .ok : .warning))
        } else {
            list.append(PreflightCheck(
                id: "ttft", group: .coach, title: "Primera respuesta (TTFT)",
                detail: "Sin probar. Toque Probar coach.", status: .unknown))
        }
        let locale = Locale.current
        let language = locale.language.languageCode?.identifier ?? "?"
        let region = locale.region?.identifier ?? "?"
        let localeOK = language == "es" && region == "CL"
        list.append(PreflightCheck(
            id: "locale", group: .coach, title: "Idioma del sistema",
            detail: "\(locale.identifier) · se requiere es_CL (Español, Chile)",
            status: localeOK ? .ok : (language == "es" ? .warning : .failed)))

        // Permisos
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        list.append(PreflightCheck(
            id: "camera", group: .permissions, title: "Cámara frontal",
            detail: Self.describe(camera), status: Self.status(camera)))
        let motion = CMPedometer.authorizationStatus()
        list.append(PreflightCheck(
            id: "motion", group: .permissions, title: "Movimiento y actividad",
            detail: Self.describe(motion), status: Self.status(motion)))
        list.append(PreflightCheck(
            id: "notifPermission", group: .permissions, title: "Permiso de avisos",
            detail: Self.describe(notificationStatus), status: .ok))

        // Equipo
        let faceOK = ARFaceTrackingConfiguration.isSupported
        list.append(PreflightCheck(
            id: "face", group: .device, title: "Seguimiento de cara (ARKit)",
            detail: faceOK ? "Disponible" : "No disponible en este equipo (cuello y ojos no verifican)",
            status: faceOK ? .ok : .failed))
        let stepsOK = CMPedometer.isStepCountingAvailable()
        list.append(PreflightCheck(
            id: "pedometer", group: .device, title: "Podómetro",
            detail: stepsOK ? "Disponible" : "No disponible en este equipo (pasos no verifican)",
            status: stepsOK ? .ok : .failed))
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        if level < 0 {
            list.append(PreflightCheck(id: "battery", group: .device, title: "Batería", detail: "Sin dato (simulador)", status: .unknown))
        } else {
            let percent = Int((level * 100).rounded())
            let charging = device.batteryState == .charging || device.batteryState == .full
            let status: PreflightCheck.Status = level >= PreflightThresholds.batteryGood ? .ok
                : (level >= PreflightThresholds.batteryLow ? .warning : .failed)
            list.append(PreflightCheck(
                id: "battery", group: .device, title: "Batería",
                detail: "\(percent) %\(charging ? " · cargando" : "") · mínimo \(Int(PreflightThresholds.batteryGood * 100)) %",
                status: charging ? .ok : status))
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        list.append(PreflightCheck(
            id: "lowPower", group: .device, title: "Modo de bajo consumo",
            detail: lowPower ? "Activado: apáguelo, frena al coach y a la cámara" : "Apagado",
            status: lowPower ? .failed : .ok))

        // Demo
        let demo = store.data.demo
        list.append(PreflightCheck(
            id: "demoEnabled", group: .demo, title: "Modo demo",
            detail: demo.enabled ? "Activo" : "Apagado: actívelo en Perfil › Demo",
            status: demo.enabled ? .ok : .warning))
        list.append(PreflightCheck(
            id: "shortTargets", group: .demo, title: "Metas cortas",
            detail: demo.shortTargets ? "30 pasos · 5 sentadillas · 8 parpadeos · Stroop 20" : "Metas reales (la pausa dura más)",
            status: demo.shortTargets ? .ok : .warning))
        let silenced = demo.notificationsMuted || !store.profile.notificationsOptIn
        list.append(PreflightCheck(
            id: "muted", group: .demo, title: "Avisos silenciados",
            detail: silenced ? "Ningún aviso durante la demo" : "Podría llegar un aviso en medio de la demo",
            status: silenced ? .ok : .warning))
        list.append(PreflightCheck(
            id: "coachOverride", group: .demo, title: "Coach elegido",
            detail: Self.describe(demo.coachOverride), status: .ok))

        checks = list
    }

    // MARK: - Acciones

    private func requestPermissions() async {
        busy = true
        defer { busy = false }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        await sensors.requestAuthorization()
        if CMPedometer.authorizationStatus() == .notDetermined {
            await briefPedometerPrompt()
        }
        if notificationStatus == .notDetermined && store.profile.notificationsOptIn {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        await refreshAll()
    }

    /// Arranque breve del podómetro solo para que iOS muestre el permiso de movimiento.
    private func briefPedometerPrompt() async {
        let pedometer = CMPedometer()
        pedometer.startUpdates(from: .now) { _, _ in }
        try? await Task.sleep(for: .seconds(PreflightThresholds.pedometerPromptSeconds))
        pedometer.stopUpdates()
    }

    /// Generación de prueba con la receta corta; mide el tiempo total y lee `coach.lastLatencyMs` (TTFT).
    private func testCoach() async {
        busy = true
        defer { busy = false }
        let profile = store.profile
        let input = CoachInput(
            profileName: profile.name,
            treatment: profile.treatment,
            checkIn: nil,
            moment: Moment.infer(date: .now, shift: profile.shiftType),
            minutesAvailable: RecipeKind.relevo60.minutes,
            baseRecipe: Recipes.base(.relevo60, demo: true),
            allowedKinds: ActivityKind.allCases,
            historyLines: [],
            gentle: false)
        let clock = ContinuousClock()
        let start = clock.now
        let plan = await coach.plan(input)
        let totalMs = Int((clock.now - start) / .milliseconds(1))
        let ttft = coach.lastLatencyMs.map { "TTFT \($0) ms" } ?? "TTFT sin dato"
        let backend = plan.backend == .foundationModels ? "IA local" : "reglas"
        lastTest = "\(ttft) · total \(totalMs) ms · \(backend) · \(plan.activities.count) actividades"
        refresh()
    }

    // MARK: - Descripciones

    private static func describe(_ availability: CoachService.Availability) -> String {
        switch availability {
        case .available: "Disponible"
        case .deviceNotEligible: "Este equipo no tiene Apple Intelligence"
        case .notEnabled: "Apagada: Ajustes › Apple Intelligence y Siri"
        case .modelNotReady: "El modelo aún se descarga; espere con wifi"
        case .localeUnsupported: "Idioma no soportado: use Español (Chile)"
        case .unknown: "Sin dato aún"
        }
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "Permitida"
        case .notDetermined: "Sin pedir todavía"
        case .denied: "Denegada: Ajustes › Activate › Cámara"
        case .restricted: "Restringida por el equipo"
        @unknown default: "Sin dato"
        }
    }

    private static func status(_ status: AVAuthorizationStatus) -> PreflightCheck.Status {
        switch status {
        case .authorized: .ok
        case .notDetermined: .warning
        case .denied, .restricted: .failed
        @unknown default: .unknown
        }
    }

    private static func describe(_ status: CMAuthorizationStatus) -> String {
        switch status {
        case .authorized: "Permitido"
        case .notDetermined: "Sin pedir todavía"
        case .denied: "Denegado: Ajustes › Activate › Movimiento y actividad"
        case .restricted: "Restringido por el equipo"
        @unknown default: "Sin dato"
        }
    }

    private static func status(_ status: CMAuthorizationStatus) -> PreflightCheck.Status {
        switch status {
        case .authorized: .ok
        case .notDetermined: .warning
        case .denied, .restricted: .failed
        @unknown default: .unknown
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: "Permitido (solo se usa si usted activa el aviso diario)"
        case .notDetermined: "Sin pedir (no hace falta para la demo)"
        case .denied: "Denegado (no afecta la demo)"
        @unknown default: "Sin dato"
        }
    }

    private static func describe(_ override: CoachOverride) -> String {
        switch override {
        case .auto: "Auto: IA si está disponible, si no reglas"
        case .rules: "Reglas (sin IA)"
        case .ai: "IA forzada (falla si no está disponible)"
        }
    }
}

private struct PreflightRow: View {
    let check: PreflightCheck

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: check.status.symbol)
                .font(.title2)
                .foregroundStyle(check.status.color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.headline)
                Text(check.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.title): \(check.status.label). \(check.detail)")
    }
}

#Preview {
    let store = AppStore(inMemory: true)
    NavigationStack {
        DemoPreflightView()
    }
    .environment(store)
    .environment(GameStore(store: store))
    .environment(CoachService())
    .environment(SensorHub())
}
