import Foundation
import Observation
import UIKit
import UserNotifications

// Dueño: agente "steps". Fuente de muestras de la actividad A2 "Camina": combina los tres streams del
// `SensorHub` (podómetro, deviceMotion, clasificación de actividad) en un `AsyncStream<StepSample>`.
//
// Modo bolsillo: al arrancar desactiva el bloqueo por inactividad y activa el sensor de proximidad
// (pantalla negra, app en primer plano: los callbacks siguen llegando). Se revierte al parar.
// Watchdog: notificación local a la ETA (meta / cadencia + 20 s) por si igual se suspende la app;
// se cancela al parar. Al volver a `.active`, el runner llama `resumeReconciliation()`.

@Observable
final class StepSource: SampleSource {
    typealias Sample = StepSample

    /// Identificador fijo de la notificación watchdog (una sola pendiente a la vez).
    static let watchdogID = "walk.eta"
    /// Margen sobre la ETA.
    static let watchdogSlackSeconds: Double = 20
    /// Cadencia mínima informada para recalcular la ETA (pasos/s).
    static let watchdogMinCadence: Double = 0.3
    /// Solo se reprograma la notificación si la ETA cambia más que esto.
    static let watchdogRescheduleThresholdSeconds: Double = 15
    static let combinedBuffer = 512

    nonisolated enum Copy {
        static let watchdogTitle = "Activate"
        static let watchdogBody = "Ya debería ir llegando a la meta. Mire el teléfono."
    }

    private(set) var level: SourceLevel = .live
    private(set) var isRunning = false
    /// Fecha real de inicio de la caminata (para acreditar con la fecha real tras una suspensión).
    private(set) var walkStart: Date?
    private(set) var lastReconciliation: PedometerReconciliation?

    let target: Int
    let watchdogEnabled: Bool

    @ObservationIgnored private let hub: SensorHub
    @ObservationIgnored private let consumer = UUID()
    @ObservationIgnored private var origin: ContinuousClock.Instant?
    @ObservationIgnored private var continuation: AsyncStream<StepSample>.Continuation?
    @ObservationIgnored private var forwarders: [Task<Void, Never>] = []
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogFireAt: ContinuousClock.Instant?
    @ObservationIgnored private var previousIdleTimerDisabled = false

    init(hub: SensorHub, target: Int, watchdogEnabled: Bool = true) {
        self.hub = hub
        self.target = target
        self.watchdogEnabled = watchdogEnabled
    }

    convenience init(hub: SensorHub, spec: VerificationSpec, watchdogEnabled: Bool = true) {
        self.init(hub: hub, target: spec.target, watchdogEnabled: watchdogEnabled)
    }

    // MARK: SampleSource

    func start() throws -> AsyncStream<StepSample> {
        hub.refreshAvailability()
        guard hub.isPedometerAvailable else {
            throw VerificationError.sensorUnavailable("Este iPhone no cuenta pasos.")
        }
        if hub.isMotionDenied {
            throw VerificationError.permissionDenied("Active «Movimiento y estado físico» en Ajustes › Privacidad.")
        }
        stop()

        // Sin clasificador de actividad o sin deviceMotion faltan gates: la fuente se declara `fallback`.
        level = (hub.isActivityAvailable && hub.isDeviceMotionAvailable) ? .live : .fallback

        let origin = ContinuousClock.now
        let start = Date.now
        self.origin = origin
        walkStart = start
        lastReconciliation = nil

        let (stream, continuation) = AsyncStream.makeStream(of: StepSample.self, bufferingPolicy: .bufferingNewest(Self.combinedBuffer))
        self.continuation = continuation

        let pedometer = hub.startPedometer(for: consumer, from: start, origin: origin)
        let motion = hub.startMotion(for: consumer, origin: origin)
        let activity = hub.startActivity(for: consumer, origin: origin)

        forwarders = [
            Task { [weak self] in
                for await s in pedometer {
                    continuation.yield(.pedometer(s))
                    self?.noteCadence(s)
                }
            },
            Task.detached {
                for await s in motion { continuation.yield(.motion(s)) }
            },
            Task.detached {
                for await s in activity { continuation.yield(.activity(s)) }
            },
        ]

        enterPocketMode()
        if watchdogEnabled {
            scheduleWatchdog(after: Double(target) / PedometerVerifier.Tuning.nominalCadence + Self.watchdogSlackSeconds)
        }
        isRunning = true
        return stream
    }

    func stop() {
        guard isRunning || continuation != nil else { return }
        isRunning = false
        reconcileTask?.cancel()
        reconcileTask = nil
        forwarders.forEach { $0.cancel() }
        forwarders = []
        hub.stopAll(for: consumer)
        continuation?.finish()
        continuation = nil
        origin = nil
        cancelWatchdog()
        leavePocketMode()
    }

    // MARK: Reconciliación al volver a `.active`

    /// Consulta al coprocesador los pasos reales desde `walkStart` y los inyecta como muestra de podómetro.
    func resumeReconciliation() {
        guard isRunning, let walkStart, let origin, let continuation else { return }
        reconcileTask?.cancel()
        reconcileTask = Task { [hub] in
            let r = await hub.reconcile(from: walkStart, to: .now)
            guard !Task.isCancelled, isRunning else { return }
            lastReconciliation = PedometerReconciliation(steps: r.steps, walkingSegments: r.walkingSegments)
            continuation.yield(.pedometer(PedometerSample(t: SensorHub.seconds(since: origin), steps: r.steps, cadence: nil, distance: nil)))
        }
    }

    // MARK: Modo bolsillo

    private func enterPocketMode() {
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isProximityMonitoringEnabled = true
    }

    private func leavePocketMode() {
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        UIDevice.current.isProximityMonitoringEnabled = false
    }

    // MARK: Watchdog

    private func noteCadence(_ s: PedometerSample) {
        guard watchdogEnabled, isRunning, let cadence = s.cadence, cadence >= Self.watchdogMinCadence else { return }
        let remaining = Double(max(0, target - s.steps)) / cadence + Self.watchdogSlackSeconds
        if let fireAt = watchdogFireAt {
            // Segundos hasta el disparo programado (negativo si ya pasó).
            let scheduled = -SensorHub.seconds(since: fireAt)
            if abs(remaining - scheduled) < Self.watchdogRescheduleThresholdSeconds { return }
        }
        scheduleWatchdog(after: remaining)
    }

    private func scheduleWatchdog(after seconds: Double) {
        let interval = max(1, seconds)
        watchdogFireAt = ContinuousClock.now.advanced(by: .seconds(interval))
        let content = UNMutableNotificationContent()
        content.title = Copy.watchdogTitle
        content.body = Copy.watchdogBody
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: Self.watchdogID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func cancelWatchdog() {
        guard watchdogFireAt != nil else { return }
        watchdogFireAt = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.watchdogID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.watchdogID])
    }
}
