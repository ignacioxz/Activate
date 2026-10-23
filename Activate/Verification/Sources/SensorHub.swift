import Foundation
import Observation
import CoreMotion

// Dueño: agente "steps". Único dueño de CMMotionManager / CMPedometer / CMMotionActivityManager / CMAltimeter
// (el altímetro lo agregó el agente "squats": apoyo físico de la sentadilla en las manos).
//
// Reglas:
// - Los handlers de CoreMotion corren en colas propias; nunca tocan estado MainActor. Convierten en el
//   límite a structs de dominio Sendable (`MotionSample`, `PedometerSample`, `ActivitySample`) y los
//   publican por `AsyncStream` a través de un fan-out protegido por lock.
// - `t` de cada muestra = segundos desde `origin` (ContinuousClock) medidos en la fuente.
// - start/stop por consumidor: el sensor físico arranca con el primer consumidor y se apaga con el último.
//   El podómetro es exclusivo (un solo `startUpdates(from:)` a la vez): arrancar uno nuevo cierra el anterior.

/// Reparte una muestra a todos los consumidores suscritos. Seguro desde cualquier cola.
nonisolated final class SampleFanout<S: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<S>.Continuation] = [:]

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return continuations.isEmpty
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return continuations.count
    }

    func add(_ id: UUID, _ continuation: AsyncStream<S>.Continuation) {
        lock.lock()
        let previous = continuations.updateValue(continuation, forKey: id)
        lock.unlock()
        previous?.finish()
    }

    func remove(_ id: UUID) {
        lock.lock()
        let previous = continuations.removeValue(forKey: id)
        lock.unlock()
        previous?.finish()
    }

    func removeAll() {
        lock.lock()
        let all = continuations.values
        continuations.removeAll()
        lock.unlock()
        all.forEach { $0.finish() }
    }

    func publish(_ sample: S) {
        lock.lock()
        let all = continuations.values
        lock.unlock()
        for c in all { c.yield(sample) }
    }
}

/// Altura barométrica relativa desde que arrancó el altímetro (m) y presión (kPa).
nonisolated struct AltitudeSample: Sendable, Codable, Hashable {
    var t: Double
    var relativeAltitude: Double
    var pressureKPa: Double
}

/// Resultado de la reconciliación tras una suspensión de la app.
nonisolated struct PedometerReconciliation: Sendable, Hashable, Codable {
    var steps: Int
    var walkingSegments: Int
}

@Observable
final class SensorHub {
    // MARK: Disponibilidad (firma congelada + extras)

    private(set) var isPedometerAvailable = false
    private(set) var isMotionAuthorized = false
    private(set) var isCadenceAvailable = false
    private(set) var isDistanceAvailable = false
    private(set) var isActivityAvailable = false
    private(set) var isDeviceMotionAvailable = false
    /// Altímetro barométrico (requiere el permiso "Movimiento y estado físico").
    private(set) var isAltimeterAvailable = false
    private(set) var authorizationStatus: CMAuthorizationStatus = .notDetermined

    /// Permiso "Movimiento y estado físico" rechazado o restringido.
    var isMotionDenied: Bool { authorizationStatus == .denied || authorizationStatus == .restricted }

    // MARK: Constantes

    /// Frecuencia de deviceMotion (Hz).
    static let deviceMotionHz: Double = 50
    /// Búfer de muestras de movimiento por consumidor (≈ 5 s a 50 Hz); si el consumidor se atrasa se pierden las más viejas.
    static let motionBuffer = 256
    static let pedometerBuffer = 16
    static let altitudeBuffer = 16

    // MARK: Sensores (un solo ejemplar de cada uno por app)

    @ObservationIgnored private let motionManager = CMMotionManager()
    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private let activityManager = CMMotionActivityManager()
    @ObservationIgnored private let altimeter = CMAltimeter()

    @ObservationIgnored private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "cl.activate.sensorhub.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    @ObservationIgnored private let activityQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "cl.activate.sensorhub.activity"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    @ObservationIgnored private let altitudeQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "cl.activate.sensorhub.altitude"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    @ObservationIgnored private let motionFanout = SampleFanout<MotionSample>()
    @ObservationIgnored private let activityFanout = SampleFanout<ActivitySample>()
    @ObservationIgnored private let pedometerFanout = SampleFanout<PedometerSample>()
    @ObservationIgnored private let altitudeFanout = SampleFanout<AltitudeSample>()

    @ObservationIgnored private var motionConsumers: Set<UUID> = []
    @ObservationIgnored private var activityConsumers: Set<UUID> = []
    @ObservationIgnored private var pedometerConsumer: UUID?
    @ObservationIgnored private var motionRunning = false
    @ObservationIgnored private var activityRunning = false
    @ObservationIgnored private var altitudeConsumers: Set<UUID> = []
    @ObservationIgnored private var altitudeRunning = false

    init() {
        motionManager.deviceMotionUpdateInterval = 1.0 / Self.deviceMotionHz
        refreshAvailability()
    }

    // MARK: Disponibilidad y permiso

    func refreshAvailability() {
        isPedometerAvailable = CMPedometer.isStepCountingAvailable()
        isCadenceAvailable = CMPedometer.isCadenceAvailable()
        isDistanceAvailable = CMPedometer.isDistanceAvailable()
        isActivityAvailable = CMMotionActivityManager.isActivityAvailable()
        isDeviceMotionAvailable = motionManager.isDeviceMotionAvailable
        isAltimeterAvailable = CMAltimeter.isRelativeAltitudeAvailable()
        authorizationStatus = CMPedometer.authorizationStatus()
        isMotionAuthorized = authorizationStatus == .authorized
    }

    /// Dispara el diálogo de "Movimiento y estado físico" con una consulta corta al podómetro
    /// (CoreMotion no tiene API explícita de permiso). Pedirlo desde Perfil, nunca a mitad de la pausa.
    func requestAuthorization() async {
        refreshAvailability()
        guard isPedometerAvailable || isActivityAvailable, authorizationStatus == .notDetermined else { return }
        let end = Date.now
        _ = await queryPedometer(from: end.addingTimeInterval(-60), to: end)
        refreshAvailability()
    }

    // MARK: Device motion (50 Hz)

    /// Entrega `MotionSample` (userAccel y gravity en g, rotationRate en rad/s) hasta `stopMotion(for:)`.
    func startMotion(for consumer: UUID, origin: ContinuousClock.Instant) -> AsyncStream<MotionSample> {
        let (stream, continuation) = AsyncStream.makeStream(of: MotionSample.self, bufferingPolicy: .bufferingNewest(Self.motionBuffer))
        motionFanout.add(consumer, continuation)
        motionConsumers.insert(consumer)
        if !motionRunning, motionManager.isDeviceMotionAvailable {
            motionRunning = true
            let fanout = motionFanout
            motionManager.startDeviceMotionUpdates(to: motionQueue) { @Sendable motion, _ in
                guard let motion else { return }
                let a = motion.userAcceleration, g = motion.gravity, r = motion.rotationRate
                fanout.publish(MotionSample(
                    t: SensorHub.seconds(since: origin),
                    userAccel: SIMD3(a.x, a.y, a.z),
                    gravity: SIMD3(g.x, g.y, g.z),
                    rotationRate: SIMD3(r.x, r.y, r.z)))
            }
        }
        return stream
    }

    func stopMotion(for consumer: UUID) {
        motionFanout.remove(consumer)
        motionConsumers.remove(consumer)
        if motionConsumers.isEmpty, motionRunning {
            motionRunning = false
            motionManager.stopDeviceMotionUpdates()
        }
    }

    // MARK: Podómetro (acumulado desde `start`)

    /// Entrega `PedometerSample` con `steps` acumulados desde `start` (coprocesador, callbacks cada ~2-3 s).
    /// Exclusivo: un nuevo consumidor cierra el stream del anterior.
    func startPedometer(for consumer: UUID, from start: Date, origin: ContinuousClock.Instant) -> AsyncStream<PedometerSample> {
        if let previous = pedometerConsumer, previous != consumer {
            pedometerFanout.remove(previous)
        }
        pedometer.stopUpdates()
        let (stream, continuation) = AsyncStream.makeStream(of: PedometerSample.self, bufferingPolicy: .bufferingNewest(Self.pedometerBuffer))
        pedometerFanout.add(consumer, continuation)
        pedometerConsumer = consumer
        guard CMPedometer.isStepCountingAvailable() else { return stream }
        let fanout = pedometerFanout
        pedometer.startUpdates(from: start) { @Sendable data, _ in
            guard let data else { return }
            fanout.publish(PedometerSample(
                t: SensorHub.seconds(since: origin),
                steps: data.numberOfSteps.intValue,
                cadence: data.currentCadence?.doubleValue,
                distance: data.distance?.doubleValue))
        }
        return stream
    }

    func stopPedometer(for consumer: UUID) {
        guard pedometerConsumer == consumer else { return }
        pedometerFanout.remove(consumer)
        pedometerConsumer = nil
        pedometer.stopUpdates()
    }

    // MARK: Actividad (walking / running / stationary…)

    /// Entrega `ActivitySample` solo cuando cambia la clasificación ("best effort"), más una inicial.
    func startActivity(for consumer: UUID, origin: ContinuousClock.Instant) -> AsyncStream<ActivitySample> {
        let (stream, continuation) = AsyncStream.makeStream(of: ActivitySample.self, bufferingPolicy: .unbounded)
        activityFanout.add(consumer, continuation)
        activityConsumers.insert(consumer)
        if !activityRunning, CMMotionActivityManager.isActivityAvailable() {
            activityRunning = true
            let fanout = activityFanout
            activityManager.startActivityUpdates(to: activityQueue) { @Sendable activity in
                guard let activity else { return }
                fanout.publish(SensorHub.sample(from: activity, t: SensorHub.seconds(since: origin)))
            }
        }
        return stream
    }

    func stopActivity(for consumer: UUID) {
        activityFanout.remove(consumer)
        activityConsumers.remove(consumer)
        if activityConsumers.isEmpty, activityRunning {
            activityRunning = false
            activityManager.stopActivityUpdates()
        }
    }

    // MARK: Altímetro (altura barométrica relativa)

    /// Entrega `AltitudeSample` (altura relativa desde el arranque, ~1 Hz) hasta `stopRelativeAltitude(for:)`.
    /// No pide permiso: si "Movimiento y estado físico" no está autorizado, el stream queda vacío
    /// (el permiso se pide desde Perfil, nunca a mitad de la pausa).
    func startRelativeAltitude(for consumer: UUID, origin: ContinuousClock.Instant) -> AsyncStream<AltitudeSample> {
        let (stream, continuation) = AsyncStream.makeStream(of: AltitudeSample.self, bufferingPolicy: .bufferingNewest(Self.altitudeBuffer))
        altitudeFanout.add(consumer, continuation)
        altitudeConsumers.insert(consumer)
        let authorized = CMAltimeter.authorizationStatus() == .authorized
        if !altitudeRunning, authorized, CMAltimeter.isRelativeAltitudeAvailable() {
            altitudeRunning = true
            let fanout = altitudeFanout
            altimeter.startRelativeAltitudeUpdates(to: altitudeQueue) { @Sendable data, _ in
                guard let data else { return }
                fanout.publish(AltitudeSample(
                    t: SensorHub.seconds(since: origin),
                    relativeAltitude: data.relativeAltitude.doubleValue,
                    pressureKPa: data.pressure.doubleValue))
            }
        }
        return stream
    }

    func stopRelativeAltitude(for consumer: UUID) {
        altitudeFanout.remove(consumer)
        altitudeConsumers.remove(consumer)
        if altitudeConsumers.isEmpty, altitudeRunning {
            altitudeRunning = false
            altimeter.stopRelativeAltitudeUpdates()
        }
    }

    /// Cierra todos los streams de un consumidor.
    func stopAll(for consumer: UUID) {
        stopMotion(for: consumer)
        stopPedometer(for: consumer)
        stopActivity(for: consumer)
        stopRelativeAltitude(for: consumer)
    }

    // MARK: Reconciliación (app suspendida a mitad de la caminata)

    /// Pasos del coprocesador entre `start` y `end` (7 días de historial) y número de tramos
    /// walking/running con confianza ≥ media según `CMMotionActivityManager`.
    func reconcile(from start: Date, to end: Date) async -> (steps: Int, walkingSegments: Int) {
        let steps = await queryPedometer(from: start, to: end)
        let segments = await queryWalkingSegments(from: start, to: end)
        return (steps, segments)
    }

    private func queryPedometer(from start: Date, to end: Date) async -> Int {
        guard CMPedometer.isStepCountingAvailable() else { return 0 }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            pedometer.queryPedometerData(from: start, to: end) { @Sendable data, _ in
                continuation.resume(returning: data?.numberOfSteps.intValue ?? 0)
            }
        }
    }

    private func queryWalkingSegments(from start: Date, to end: Date) async -> Int {
        guard CMMotionActivityManager.isActivityAvailable() else { return 0 }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            activityManager.queryActivityStarting(from: start, to: end, to: activityQueue) { @Sendable activities, _ in
                var segments = 0
                var inside = false
                for a in activities ?? [] {
                    let moving = (a.walking || a.running) && a.confidence != .low
                    if moving && !inside { segments += 1 }
                    inside = moving
                }
                continuation.resume(returning: segments)
            }
        }
    }

    // MARK: Conversión

    nonisolated static func seconds(since origin: ContinuousClock.Instant) -> Double {
        let d = origin.duration(to: ContinuousClock.now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }

    nonisolated static func sample(from activity: CMMotionActivity, t: Double) -> ActivitySample {
        let confidence: Int
        switch activity.confidence {
        case .low: confidence = 0
        case .medium: confidence = 1
        case .high: confidence = 2
        @unknown default: confidence = 0
        }
        return ActivitySample(
            t: t,
            walking: activity.walking,
            running: activity.running,
            stationary: activity.stationary,
            automotive: activity.automotive,
            unknown: activity.unknown,
            confidence: confidence)
    }
}
