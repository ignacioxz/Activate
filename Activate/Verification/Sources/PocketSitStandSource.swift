import Foundation
import UIKit

// Dueño: agente "sit-to-stand". Fuente en vivo de A4 "Pararse y sentarse" con el teléfono en el bolsillo
// delantero del pantalón: combina deviceMotion (50 Hz), altímetro y podómetro del `SensorHub` y el sensor de
// proximidad en un `AsyncStream<PocketSitStandSample>` (una muestra por lectura de deviceMotion).
//
// Modo bolsillo, igual que la caminata (`StepSource`): al arrancar desactiva el bloqueo por inactividad y
// activa el sensor de proximidad (pantalla negra, app en primer plano: los callbacks siguen llegando); al
// parar lo revierte. Sin cámara.

@MainActor
final class PocketSitStandSource: SampleSource {
    typealias Sample = PocketSitStandSample

    static let bufferedSamples = 512

    private(set) var level: SourceLevel = .live

    private let hub: SensorHub?
    private let consumer = UUID()
    private var continuation: AsyncStream<PocketSitStandSample>.Continuation?
    private var forwarders: [Task<Void, Never>] = []
    private var latestSteps: Int?
    private var pendingAltitude: Double?
    private var proximitySupported = false
    private var previousIdleTimerDisabled = false
    private var running = false

    init(hub: SensorHub?) {
        self.hub = hub
    }

    func start() throws -> AsyncStream<PocketSitStandSample> {
        guard let hub else { throw VerificationError.sensorUnavailable("Sin sensores de movimiento.") }
        hub.refreshAvailability()
        guard hub.isDeviceMotionAvailable else {
            throw VerificationError.sensorUnavailable("Este iPhone no entrega el movimiento del teléfono.")
        }
        if hub.isMotionDenied {
            throw VerificationError.permissionDenied("Active «Movimiento y estado físico» en Ajustes › Privacidad.")
        }
        stop()

        let (stream, continuation) = AsyncStream.makeStream(of: PocketSitStandSample.self,
                                                            bufferingPolicy: .bufferingNewest(Self.bufferedSamples))
        self.continuation = continuation
        latestSteps = nil
        pendingAltitude = nil

        let origin = ContinuousClock.now
        let motion = hub.startMotion(for: consumer, origin: origin)
        let altitude = hub.startRelativeAltitude(for: consumer, origin: origin)
        let pedometer = hub.startPedometer(for: consumer, from: .now, origin: origin)

        enterPocketMode()
        // El barómetro solo corrobora: sin él, el verificador decide el nivel con giro + desplazamiento
        // (`PocketSitStandVerifier.limitedSourceLevel`).
        level = .live

        forwarders = [
            Task { [weak self] in
                for await m in motion {
                    guard let self else { break }
                    continuation.yield(self.sample(from: m))
                }
                continuation.finish()
            },
            Task { [weak self] in
                for await a in altitude { self?.pendingAltitude = a.relativeAltitude }
            },
            Task { [weak self] in
                for await p in pedometer { self?.latestSteps = p.steps }
            },
        ]
        running = true
        return stream
    }

    func stop() {
        guard running || continuation != nil else { return }
        running = false
        forwarders.forEach { $0.cancel() }
        forwarders = []
        hub?.stopAll(for: consumer)
        continuation?.finish()
        continuation = nil
        leavePocketMode()
    }

    private func sample(from m: MotionSample) -> PocketSitStandSample {
        let altitude = pendingAltitude
        pendingAltitude = nil
        let covered: Bool? = proximitySupported ? UIDevice.current.proximityState : nil
        return PocketSitStandSample(t: m.t,
                                    userAccel: m.userAccel,
                                    gravity: m.gravity,
                                    rotationRate: m.rotationRate,
                                    altitude: altitude,
                                    steps: latestSteps,
                                    proximityCovered: covered)
    }

    // MARK: Modo bolsillo

    private func enterPocketMode() {
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isProximityMonitoringEnabled = true
        // Si el equipo no tiene sensor de proximidad, la propiedad vuelve a `false`.
        proximitySupported = UIDevice.current.isProximityMonitoringEnabled
    }

    private func leavePocketMode() {
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        UIDevice.current.isProximityMonitoringEnabled = false
    }
}
