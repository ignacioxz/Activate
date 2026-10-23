import Foundation
import Observation
#if os(iOS)
import AVFoundation
import CoreMotion
import UIKit
#endif

/// Voz guía. Con el iPhone en el bolsillo la pantalla se apaga (sensor de proximidad),
/// así que las señales y la retroalimentación se entregan por audio.
final class VoiceCoach {
    #if os(iOS)
    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "es-CL") ?? AVSpeechSynthesisVoice(language: "es-ES")
    #endif

    func activate() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    func say(_ text: String) {
        #if os(iOS)
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = 0.52
        synthesizer.speak(utterance)
        #endif
    }

    func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// Detecta un ejercicio de forma simple, con el iPhone en las dos manos frente al pecho:
/// - Al empezar hay una cuenta regresiva y se guarda la posición inicial.
/// - Giro: giroscopio alrededor del eje vertical. Cuenta cada lado alcanzado.
/// - Inclinación lateral: ángulo de la gravedad en el plano de la pantalla. Cuenta cada lado.
/// - Brazos arriba / sentadilla: inclinación adelante-atrás. Cuenta al ir y volver.
/// - Caminata y escaleras: podómetro de Apple.
@Observable
final class ExerciseTracker {
    enum Phase: Equatable {
        case notStarted, countdown, running, completed, unavailable
    }

    let exercise: Exercise

    private(set) var phase: Phase = .notStarted
    private(set) var count: Double = 0
    private(set) var status = ""
    /// Cuánto se ha movido el iPhone desde la posición inicial (grados, siempre positivo).
    private(set) var liveAngle: Double = 0

    var isCompleted: Bool { phase == .completed }
    var hasStarted: Bool { phase != .notStarted }
    var progress: Double { min(1, count / Double(max(1, exercise.target))) }

    @ObservationIgnored private let voice = VoiceCoach()
    #if os(iOS)
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let pedometer = CMPedometer()
    #endif
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    // Estado del detector.
    @ObservationIgnored private var baselineRoll: Double?
    @ObservationIgnored private var baselinePitch: Double?
    @ObservationIgnored private var yaw = 0.0
    @ObservationIgnored private var lastTimestamp: TimeInterval?
    @ObservationIgnored private var lastSide = 0
    @ObservationIgnored private var reachedPeak = false
    @ObservationIgnored private var lastRepTime: TimeInterval = 0

    init(exercise: Exercise) {
        self.exercise = exercise
    }

    // MARK: - Ciclo de vida

    func start() {
        voice.activate()
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        switch exercise.pattern {
        case .steps: startSteps()
        case .stairs: startStairs()
        default: startMotion()
        }
        #else
        phase = .unavailable
        status = "Sensores no disponibles en este dispositivo."
        #endif
    }

    func stop() {
        countdownTask?.cancel()
        #if os(iOS)
        motion.stopDeviceMotionUpdates()
        pedometer.stopUpdates()
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        voice.deactivate()
    }

    /// Solo para el simulador, que no tiene sensores.
    func completeForSimulator() {
        countdownTask?.cancel()
        count = Double(exercise.target)
        complete()
    }

    private func complete() {
        guard phase != .completed else { return }
        phase = .completed
        status = "¡Logrado!"
        voice.say("¡Excelente! Lo lograste.")
        #if os(iOS)
        motion.stopDeviceMotionUpdates()
        pedometer.stopUpdates()
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    private func addRep(nextHint: String) {
        count += 1
        if count >= Double(exercise.target) {
            complete()
        } else {
            voice.say("\(Int(count))")
            status = nextHint
        }
    }

    #if os(iOS)
    // MARK: - Ejercicios de movimiento

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            phase = .unavailable
            status = "Este dispositivo no tiene sensores de movimiento."
            return
        }
        phase = .countdown
        status = "Toma el iPhone con las dos manos frente al pecho"
        voice.say("Toma el iPhone con las dos manos frente al pecho.")

        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        motion.startDeviceMotionUpdates(to: .main) { @Sendable [weak self] sample, _ in
            guard let sample else { return }
            MainActor.assumeIsolated {
                self?.process(sample)
            }
        }

        // Cuenta regresiva; al terminar se toma la posición actual como punto de partida.
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            for n in [3, 2, 1] {
                guard !Task.isCancelled else { return }
                self?.status = "\(n)"
                self?.voice.say("\(n)")
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self else { return }
            self.baselineRoll = nil
            self.baselinePitch = nil
            self.yaw = 0
            self.phase = .running
            self.status = self.exercise.prompt
            self.voice.say("¡Ya! \(self.exercise.prompt)")
        }
    }

    /// Diferencia de ángulos normalizada a −180…180.
    private func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = a - b
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    private func process(_ sample: CMDeviceMotion) {
        let t = sample.timestamp
        let dt = lastTimestamp.map { min(0.1, t - $0) } ?? 0
        lastTimestamp = t
        guard phase == .running else { return }

        let g = sample.gravity
        let r = sample.rotationRate
        // Inclinación lateral (giro en el plano de la pantalla) y adelante-atrás, en grados.
        let roll = atan2(g.x, -g.y) * 180 / .pi
        let pitch = atan2(-g.z, -g.y) * 180 / .pi
        if baselineRoll == nil { baselineRoll = roll }
        if baselinePitch == nil { baselinePitch = pitch }

        switch exercise.pattern {
        case .twist:
            // Velocidad de giro alrededor de la vertical (proyección sobre la gravedad).
            let length = max(1e-6, (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot())
            let yawRate = -(r.x * g.x + r.y * g.y + r.z * g.z) / length
            yaw += yawRate * dt
            countAlternating(yaw * 180 / .pi, t: t)
        case .sideBend:
            countAlternating(angleDelta(roll, baselineRoll ?? roll), t: t)
        case .pitch:
            countOutAndBack(abs(angleDelta(pitch, baselinePitch ?? pitch)), t: t)
        case .steps, .stairs:
            break
        }
    }

    /// Cuenta una repetición cada vez que llegas a un lado distinto al anterior.
    private func countAlternating(_ degrees: Double, t: TimeInterval) {
        liveAngle = abs(degrees)
        let threshold = exercise.threshold
        guard t - lastRepTime > 0.4 else { return }
        if degrees > threshold && lastSide != 1 {
            lastSide = 1
            lastRepTime = t
            addRep(nextHint: "¡Bien! Ahora al otro lado")
        } else if degrees < -threshold && lastSide != -1 {
            lastSide = -1
            lastRepTime = t
            addRep(nextHint: "¡Bien! Ahora al otro lado")
        }
    }

    /// Cuenta una repetición al superar el umbral y volver cerca del inicio.
    private func countOutAndBack(_ degrees: Double, t: TimeInterval) {
        liveAngle = degrees
        if !reachedPeak && degrees > exercise.threshold {
            reachedPeak = true
            status = "¡Eso! Ahora vuelve"
        } else if reachedPeak && degrees < exercise.threshold * 0.4 && t - lastRepTime > 0.4 {
            reachedPeak = false
            lastRepTime = t
            addRep(nextHint: exercise.prompt)
        }
    }

    // MARK: - Caminata y escaleras

    private func startSteps() {
        guard CMPedometer.isStepCountingAvailable() else {
            phase = .unavailable
            status = "Este dispositivo no cuenta pasos."
            return
        }
        phase = .running
        status = "¡A caminar! Los pasos aparecen cada pocos segundos"
        voice.say("A caminar. Te aviso cuando completes la meta.")
        startPedometer()
    }

    private func startStairs() {
        guard CMPedometer.isFloorCountingAvailable() else {
            phase = .unavailable
            status = "Este dispositivo no cuenta pisos."
            return
        }
        phase = .running
        status = "Sube con calma usando el pasamanos"
        voice.say("Sube las escaleras con calma. Te aviso al completar el piso.")
        startPedometer()
    }

    private func startPedometer() {
        if CMPedometer.authorizationStatus() == .denied || CMPedometer.authorizationStatus() == .restricted {
            phase = .unavailable
            status = "Activa «Movimiento y estado físico» en Ajustes › Privacidad."
            return
        }
        pedometer.startUpdates(from: .now) { @Sendable [weak self] data, _ in
            let steps = data?.numberOfSteps.intValue ?? 0
            let floors = data?.floorsAscended?.intValue ?? 0
            DispatchQueue.main.async {
                self?.applyPedometer(steps: steps, floors: floors)
            }
        }
    }

    private func applyPedometer(steps: Int, floors: Int) {
        guard phase == .running else { return }
        count = Double(exercise.pattern == .steps ? steps : floors)
        if exercise.pattern == .stairs {
            status = "\(steps) pasos en la escalera"
        }
        if count >= Double(exercise.target) { complete() }
    }
    #endif
}

/// Pasos y pisos del día completo, para las metas diarias.
@Observable
final class DailyActivity {
    private(set) var steps = 0
    private(set) var floors = 0
    private(set) var distanceKm = 0.0
    private(set) var isAvailable = true

    #if os(iOS)
    @ObservationIgnored private let pedometer = CMPedometer()
    #endif

    func start() {
        #if os(iOS)
        guard CMPedometer.isStepCountingAvailable() else {
            isAvailable = false
            return
        }
        let startOfDay = Calendar.current.startOfDay(for: .now)
        pedometer.startUpdates(from: startOfDay) { @Sendable [weak self] data, _ in
            let steps = data?.numberOfSteps.intValue ?? 0
            let floors = data?.floorsAscended?.intValue ?? 0
            let meters = data?.distance?.doubleValue ?? 0
            DispatchQueue.main.async {
                self?.steps = steps
                self?.floors = floors
                self?.distanceKm = meters / 1000
            }
        }
        #else
        isAvailable = false
        #endif
    }
}
