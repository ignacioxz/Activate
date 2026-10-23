import Foundation
import Observation
import SwiftUI
import UIKit

// Dueño: agente "integrity".
//
// Monitor mínimo de integridad de una pausa (MainActor). Mide la sesión con dos relojes y
// deja constancia, como `Anomaly`, de lo que no cuadra:
// - `clockDrift` (hard): |Δ pared − Δ monotónico| > `clockDriftToleranceSeconds`.
// - `systemClockChanged` (hard): el sistema cambió la hora durante la sesión.
// - `backgrounded` (soft, con t): la app pasó a segundo plano durante la sesión.
// Las anomalías viajan en `PauseSession.integrityFlags` dentro del payload firmado.

@Observable
@MainActor
final class IntegrityMonitor {
    nonisolated enum Flag {
        static let clockDrift = "clockDrift"
        static let systemClockChanged = "systemClockChanged"
        static let backgrounded = "backgrounded"
    }

    /// Tolerancia entre el reloj de pared y el monotónico al cerrar la sesión.
    nonisolated static let clockDriftToleranceSeconds: Double = 2

    private(set) var isRunning = false
    private(set) var wallStart: Date?
    private(set) var anomalies: [Anomaly] = []
    /// `true` mientras la app está en segundo plano durante la sesión.
    private(set) var isInBackground = false

    @ObservationIgnored private var monoStart: ContinuousClock.Instant?
    @ObservationIgnored private let observers = ObserverBox()
    /// Reloj de pared inyectable (tests de deriva).
    @ObservationIgnored var wallClock: () -> Date = { .now }

    init() {}

    deinit {
        observers.removeAll()
    }

    /// Segundos desde `begin()` medidos con `ContinuousClock` (0 si no corre).
    var monotonicSeconds: Double {
        guard let monoStart else { return 0 }
        return Self.seconds(monoStart.duration(to: .now))
    }

    /// Segundos desde `begin()` según el reloj de pared.
    var wallSeconds: Double {
        guard let wallStart else { return 0 }
        return wallClock().timeIntervalSince(wallStart)
    }

    var hasHardAnomaly: Bool { anomalies.contains { $0.severity == .hard } }

    // MARK: - Ciclo de vida

    /// Captura `Date.now` y `ContinuousClock.now` y empieza a observar cambios de hora y segundo plano.
    func begin() {
        if isRunning { _ = end(discarding: true) }
        wallStart = wallClock()
        monoStart = .now
        anomalies = []
        isInBackground = false
        isRunning = true
        subscribe()
    }

    /// Cierra la sesión, evalúa la deriva de relojes y devuelve todas las anomalías registradas.
    @discardableResult
    func end() -> [Anomaly] {
        end(discarding: false)
    }

    /// Cierra sin evaluar (pausa abandonada).
    func cancel() {
        _ = end(discarding: true)
    }

    private func end(discarding: Bool) -> [Anomaly] {
        defer {
            unsubscribe()
            isRunning = false
            isInBackground = false
            monoStart = nil
            wallStart = nil
        }
        guard isRunning else { return [] }
        if discarding {
            anomalies = []
            return []
        }
        let mono = monotonicSeconds
        let wall = wallSeconds
        let drift = wall - mono
        if drift.magnitude > Self.clockDriftToleranceSeconds {
            anomalies.append(Anomaly(kind: Flag.clockDrift, severity: .hard, at: mono,
                                     detail: String(format: "Δpared−Δmono = %.1f s", drift)))
        }
        return anomalies
    }

    // MARK: - Eventos

    /// El sistema cambió la hora (NSSystemClockDidChangeNotification).
    func noteSystemClockChanged() {
        guard isRunning else { return }
        anomalies.append(Anomaly(kind: Flag.systemClockChanged, severity: .hard, at: monotonicSeconds))
    }

    /// Transición a segundo plano (una sola anomalía por transición, aunque llegue por dos vías).
    func noteBackgrounded() {
        guard isRunning, !isInBackground else { return }
        isInBackground = true
        anomalies.append(Anomaly(kind: Flag.backgrounded, severity: .soft, at: monotonicSeconds))
    }

    func noteForegrounded() {
        isInBackground = false
    }

    /// Para engancharlo a `.onChange(of: scenePhase)` desde el flujo de pausa.
    func noteScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background: noteBackgrounded()
        case .active: noteForegrounded()
        default: break
        }
    }

    // MARK: - Notificaciones

    private func subscribe() {
        unsubscribe()
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.noteSystemClockChanged() }
        })
        observers.add(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.noteBackgrounded() }
        })
        observers.add(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.noteForegrounded() }
        })
    }

    private func unsubscribe() {
        observers.removeAll()
    }

    nonisolated static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

/// Tokens de NotificationCenter que se pueden soltar desde `deinit` (nonisolated).
nonisolated private final class ObserverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        lock.withLock { tokens.append(token) }
    }

    func removeAll() {
        let old = lock.withLock { () -> [NSObjectProtocol] in
            let t = tokens
            tokens.removeAll()
            return t
        }
        for o in old { NotificationCenter.default.removeObserver(o) }
    }
}
