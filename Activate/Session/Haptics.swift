import CoreHaptics
import UIKit

/// Háptica de la pausa: tick por repetición, confirmación y celebración con un patrón AHAP simple.
/// Un solo motor por app. Si el hardware no soporta háptica (simulador, iPad), todo es no-op.
/// En la mina no hay voz: la háptica es la confirmación que sí se siente con guantes y ruido.
@MainActor
final class Haptics {
    static let shared = Haptics()

    /// Intensidades y tiempos del patrón (valores iniciales; se ajustan en dispositivo).
    enum Pattern {
        static let tapIntensities: [Float] = [0.55, 0.75, 1.0]
        static let tapSharpness: [Float] = [0.35, 0.55, 0.8]
        static let tapSpacingSeconds: TimeInterval = 0.12
        static let swellDelaySeconds: TimeInterval = 0.45
        static let swellDurationSeconds: TimeInterval = 0.35
        static let swellIntensity: Float = 0.8
        static let swellSharpness: Float = 0.3
        /// Segundo "golpe" del Doblete / Tiro limpio.
        static let encoreDelaySeconds: TimeInterval = 1.0
    }

    let supportsHaptics: Bool
    private var engine: CHHapticEngine?
    private var engineRunning = false
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    private init() {
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    // MARK: Motor

    /// Crea y arranca el motor. Llamar al entrar a la pausa: tapa la latencia del primer uso.
    func prepare() {
        guard supportsHaptics else { return }
        impact.prepare()
        notification.prepare()
        if engine == nil {
            do {
                let e = try CHHapticEngine()
                e.playsHapticsOnly = true
                e.resetHandler = { @Sendable [weak self] in
                    Task { @MainActor in self?.restartEngine() }
                }
                e.stoppedHandler = { @Sendable [weak self] _ in
                    Task { @MainActor in self?.engineRunning = false }
                }
                engine = e
            } catch {
                engine = nil
                return
            }
        }
        startEngineIfNeeded()
    }

    /// Detiene el motor (al cerrar la pausa; ahorra batería).
    func release() {
        engine?.stop(completionHandler: nil)
        engineRunning = false
    }

    private func startEngineIfNeeded() {
        guard let engine, !engineRunning else { return }
        do {
            try engine.start()
            engineRunning = true
        } catch {
            engineRunning = false
        }
    }

    private func restartEngine() {
        engineRunning = false
        startEngineIfNeeded()
    }

    // MARK: Helpers (UIKit, sin motor)

    /// Tick de una repetición contada.
    func tick() {
        guard supportsHaptics else { return }
        impact.impactOccurred(intensity: 0.7)
    }

    /// Actividad completada / pausa registrada.
    func success() {
        guard supportsHaptics else { return }
        notification.notificationOccurred(.success)
    }

    /// Gate bloqueado, anomalía o derivación.
    func warning() {
        guard supportsHaptics else { return }
        notification.notificationOccurred(.warning)
    }

    // MARK: Celebración (AHAP)

    /// Celebración sobria al cerrar la pausa; `strong` = Doblete / Tiro limpio (segundo golpe).
    func celebrate(strong: Bool) {
        guard supportsHaptics else { return }
        prepare()
        guard let engine, engineRunning else {
            success()
            return
        }
        do {
            let pattern = try Self.celebrationPattern(strong: strong)
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            success()
        }
    }

    /// Patrón AHAP (diccionario con las claves de `CHHapticPattern.Key`): tres toques ascendentes y una onda corta;
    /// con `strong`, el mismo bloque se repite un segundo después.
    static func celebrationPattern(strong: Bool) throws -> CHHapticPattern {
        var events: [[CHHapticPattern.Key: Any]] = []
        func block(at offset: TimeInterval) {
            for (i, intensity) in Pattern.tapIntensities.enumerated() {
                events.append(transient(at: offset + Double(i) * Pattern.tapSpacingSeconds,
                                        intensity: intensity, sharpness: Pattern.tapSharpness[i]))
            }
            events.append(continuous(at: offset + Pattern.swellDelaySeconds, duration: Pattern.swellDurationSeconds,
                                     intensity: Pattern.swellIntensity, sharpness: Pattern.swellSharpness))
        }
        block(at: 0)
        if strong { block(at: Pattern.encoreDelaySeconds) }
        let ahap: [CHHapticPattern.Key: Any] = [
            .version: 1.0,
            .pattern: events,
        ]
        do {
            return try CHHapticPattern(dictionary: ahap)
        } catch {
            // Respaldo programático equivalente por si el diccionario no se acepta en esta versión.
            return try CHHapticPattern(events: fallbackEvents(strong: strong), parameters: [])
        }
    }

    private static func transient(at time: TimeInterval, intensity: Float, sharpness: Float) -> [CHHapticPattern.Key: Any] {
        let event: [CHHapticPattern.Key: Any] = [
            .eventType: CHHapticEvent.EventType.hapticTransient,
            .time: time,
            .eventParameters: [
                [CHHapticPattern.Key.parameterID: CHHapticEvent.ParameterID.hapticIntensity, CHHapticPattern.Key.parameterValue: intensity],
                [CHHapticPattern.Key.parameterID: CHHapticEvent.ParameterID.hapticSharpness, CHHapticPattern.Key.parameterValue: sharpness],
            ],
        ]
        return [.event: event]
    }

    private static func continuous(at time: TimeInterval, duration: TimeInterval, intensity: Float, sharpness: Float) -> [CHHapticPattern.Key: Any] {
        let event: [CHHapticPattern.Key: Any] = [
            .eventType: CHHapticEvent.EventType.hapticContinuous,
            .time: time,
            .eventDuration: duration,
            .eventParameters: [
                [CHHapticPattern.Key.parameterID: CHHapticEvent.ParameterID.hapticIntensity, CHHapticPattern.Key.parameterValue: intensity],
                [CHHapticPattern.Key.parameterID: CHHapticEvent.ParameterID.hapticSharpness, CHHapticPattern.Key.parameterValue: sharpness],
            ],
        ]
        return [.event: event]
    }

    private static func fallbackEvents(strong: Bool) -> [CHHapticEvent] {
        var events: [CHHapticEvent] = []
        func block(at offset: TimeInterval) {
            for (i, intensity) in Pattern.tapIntensities.enumerated() {
                events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Pattern.tapSharpness[i]),
                ], relativeTime: offset + Double(i) * Pattern.tapSpacingSeconds))
            }
            events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Pattern.swellIntensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Pattern.swellSharpness),
            ], relativeTime: offset + Pattern.swellDelaySeconds, duration: Pattern.swellDurationSeconds))
        }
        block(at: 0)
        if strong { block(at: Pattern.encoreDelaySeconds) }
        return events
    }
}
