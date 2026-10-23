import Foundation

// Dueño: agente "runtime".
//
// Detectores puros y reutilizables para las máquinas de estado de verificación.
// Todos son `nonisolated struct` sin imports de ARKit/Vision/CoreMotion: se usan dentro de
// `ActivityVerifier.ingest(_:at:)` (que corre en MainActor dentro de `ActivityRunner`) y se
// prueban con fixtures. El tiempo `t` siempre es "segundos desde el inicio de la actividad".
//
// Umbrales: valores iniciales como constantes nombradas; se calibran en el iPhone en la fase 2.

// MARK: - Utilidades de ángulos

nonisolated enum AngleMath {
    /// Normaliza un ángulo en grados a (-180, 180].
    static func wrap180(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Diferencia angular más corta `a - b`, en grados, en (-180, 180].
    static func delta(_ a: Double, _ b: Double) -> Double { wrap180(a - b) }
}

// MARK: - Suavizado exponencial (EMA)

/// Media móvil exponencial para señales ruidosas (descenso de cadera, blendShapes, |accel|).
nonisolated struct ExponentialSmoother: Sendable, Hashable, Codable {
    /// Peso de la muestra nueva (0 < alpha ≤ 1). 1 = sin suavizado.
    var alpha: Double
    private(set) var value: Double? = nil

    init(alpha: Double) {
        self.alpha = min(1, max(0.0001, alpha))
    }

    @discardableResult
    mutating func update(_ x: Double) -> Double {
        let v = value.map { $0 + alpha * (x - $0) } ?? x
        value = v
        return v
    }

    mutating func reset() { value = nil }
}

// MARK: - RepMachine

/// Contador genérico de repeticiones con histéresis.
///
/// Una repetición es: la señal sube de `enterThreshold` (fase activa), y luego vuelve a bajar
/// de `exitThreshold` (`exitThreshold < enterThreshold`). La duración de la fase activa debe estar
/// en `[minRepSeconds, maxRepSeconds]`; si no, la repetición se rechaza (ruido o postura mantenida).
/// Para señales que "bajan" (p. ej. un ángulo que disminuye) basta negar la señal y los umbrales.
///
/// Ejemplo (sentadilla): señal = descenso vertical de la cadera / estatura en píxeles;
/// `enter = 0.12`, `exit = 0.04`, `minRep = 0.6 s`, `maxRep = 6 s`.
nonisolated struct RepMachine: Sendable, Hashable, Codable {
    nonisolated enum Phase: String, Sendable, Hashable, Codable { case rest, active }

    nonisolated enum Rejection: String, Sendable, Hashable, Codable {
        /// La fase activa duró menos de `minRepSeconds` (ruido, rebote).
        case tooShort
        /// La fase activa duró más de `maxRepSeconds` (postura mantenida, tracking pegado).
        case tooLong
        /// Entró antes de `minRestSeconds` desde la última repetición.
        case tooSoon
    }

    nonisolated enum Event: Sendable, Hashable {
        /// Nada que informar.
        case idle
        /// La señal cruzó `enterThreshold`: empezó una repetición.
        case entered(at: Double)
        /// Repetición válida; `seconds` = duración de la fase activa; `peak` = máximo de la señal.
        case rep(count: Int, seconds: Double, peak: Double)
        case rejected(Rejection, at: Double)
    }

    var enterThreshold: Double
    var exitThreshold: Double
    var minRepSeconds: Double
    var maxRepSeconds: Double
    /// Descanso mínimo entre el fin de una repetición y el inicio de la siguiente (0 = sin límite).
    var minRestSeconds: Double

    private(set) var phase: Phase = .rest
    private(set) var count: Int = 0
    private(set) var enteredAt: Double? = nil
    private(set) var lastRepAt: Double? = nil
    private(set) var peak: Double = 0
    private(set) var rejectedCount: Int = 0
    /// Duración y pico de cada repetición válida, en orden.
    private(set) var repSeconds: [Double] = []
    private(set) var repPeaks: [Double] = []
    private(set) var repTimestamps: [Double] = []

    init(enterThreshold: Double, exitThreshold: Double, minRepSeconds: Double, maxRepSeconds: Double, minRestSeconds: Double = 0) {
        precondition(exitThreshold < enterThreshold, "RepMachine: exitThreshold debe ser menor que enterThreshold (histéresis)")
        precondition(minRepSeconds <= maxRepSeconds, "RepMachine: minRepSeconds debe ser ≤ maxRepSeconds")
        self.enterThreshold = enterThreshold
        self.exitThreshold = exitThreshold
        self.minRepSeconds = minRepSeconds
        self.maxRepSeconds = maxRepSeconds
        self.minRestSeconds = max(0, minRestSeconds)
    }

    var meanRepSeconds: Double? {
        repSeconds.isEmpty ? nil : repSeconds.reduce(0, +) / Double(repSeconds.count)
    }

    var minPeak: Double? { repPeaks.min() }

    /// Fracción (0-1) de la repetición en curso respecto del umbral de entrada, para pintar un anillo.
    func liveFraction(for signal: Double) -> Double {
        guard enterThreshold != 0 else { return 0 }
        return min(1, max(0, signal / enterThreshold))
    }

    @discardableResult
    mutating func update(_ signal: Double, at t: Double) -> Event {
        switch phase {
        case .rest:
            guard signal >= enterThreshold else { return .idle }
            if let last = lastRepAt, minRestSeconds > 0, t - last < minRestSeconds {
                rejectedCount += 1
                return .rejected(.tooSoon, at: t)
            }
            phase = .active
            enteredAt = t
            peak = signal
            return .entered(at: t)

        case .active:
            peak = max(peak, signal)
            guard signal <= exitThreshold else { return .idle }
            let start = enteredAt ?? t
            let seconds = t - start
            phase = .rest
            enteredAt = nil
            if seconds < minRepSeconds {
                rejectedCount += 1
                return .rejected(.tooShort, at: t)
            }
            if seconds > maxRepSeconds {
                rejectedCount += 1
                return .rejected(.tooLong, at: t)
            }
            count += 1
            lastRepAt = t
            repSeconds.append(seconds)
            repPeaks.append(peak)
            repTimestamps.append(t)
            return .rep(count: count, seconds: seconds, peak: peak)
        }
    }

    mutating func reset() {
        phase = .rest
        count = 0
        enteredAt = nil
        lastRepAt = nil
        peak = 0
        rejectedCount = 0
        repSeconds = []
        repPeaks = []
        repTimestamps = []
    }
}

// MARK: - StaticSignalDetector

/// Detecta una señal "muerta": varianza < `epsilon` durante `windowSeconds` → anomalía `static` (hard).
/// Sirve para la foto frente a la cámara (`shapeEnergy` ≈ 0, cadera inmóvil) y para un sensor pegado.
/// Dispara una vez por episodio y se rearma cuando la señal vuelve a moverse.
nonisolated struct StaticSignalDetector: Sendable, Hashable, Codable {
    static let anomalyKind = "static"
    static let defaultWindowSeconds: Double = 3
    /// Umbral de varianza; depende de la escala de la señal (0-1 normalizada → 1e-6 es "quieto del todo").
    static let defaultEpsilon: Double = 1e-6
    static let defaultMinSamples = 4

    nonisolated struct Point: Sendable, Hashable, Codable {
        var t: Double
        var v: Double
    }

    var windowSeconds: Double
    var epsilon: Double
    var minSamples: Int

    private var buffer: [Point] = []
    private var fired = false
    /// Instante del último disparo (nil si nunca).
    private(set) var lastFiredAt: Double? = nil

    init(windowSeconds: Double = StaticSignalDetector.defaultWindowSeconds,
         epsilon: Double = StaticSignalDetector.defaultEpsilon,
         minSamples: Int = StaticSignalDetector.defaultMinSamples) {
        self.windowSeconds = max(0.001, windowSeconds)
        self.epsilon = epsilon
        self.minSamples = max(2, minSamples)
    }

    /// Varianza poblacional de la ventana actual (nil si no hay muestras suficientes).
    var variance: Double? {
        guard buffer.count >= 2 else { return nil }
        let n = Double(buffer.count)
        let mean = buffer.reduce(0) { $0 + $1.v } / n
        return buffer.reduce(0) { $0 + ($1.v - mean) * ($1.v - mean) } / n
    }

    /// Segundos cubiertos por la ventana actual.
    var span: Double {
        guard let first = buffer.first, let last = buffer.last else { return 0 }
        return last.t - first.t
    }

    @discardableResult
    mutating func ingest(_ value: Double, at t: Double) -> Anomaly? {
        buffer.append(Point(t: t, v: value))
        // Conserva una muestra en el borde para que la ventana cubra `windowSeconds` completos.
        while buffer.count > 1, buffer[1].t <= t - windowSeconds {
            buffer.removeFirst()
        }
        guard buffer.count >= minSamples, span >= windowSeconds, let variance else { return nil }
        if variance < epsilon {
            guard !fired else { return nil }
            fired = true
            lastFiredAt = t
            return Anomaly(kind: Self.anomalyKind, severity: .hard, at: t,
                           detail: "Señal sin cambios durante \(Int(windowSeconds.rounded())) s")
        } else {
            fired = false
            return nil
        }
    }

    mutating func reset() {
        buffer = []
        fired = false
        lastFiredAt = nil
    }
}

// MARK: - RegularityDetector

/// Detecta repeticiones demasiado perfectas (vídeo en bucle, señal sintética):
/// coeficiente de variación de los intervalos entre reps < `maxCoefficientOfVariation` con
/// ≥ `minReps` repeticiones → anomalía `tooRegular` (hard). Dispara una sola vez.
nonisolated struct RegularityDetector: Sendable, Hashable, Codable {
    static let anomalyKind = "tooRegular"
    static let defaultMinReps = 6
    static let defaultMaxCoefficientOfVariation: Double = 0.04
    /// Cuántos intervalos recientes se consideran (una persona también se vuelve regular con el tiempo).
    static let defaultWindow = 12

    var minReps: Int
    var maxCoefficientOfVariation: Double
    var window: Int

    private var timestamps: [Double] = []
    private(set) var fired = false

    init(minReps: Int = RegularityDetector.defaultMinReps,
         maxCoefficientOfVariation: Double = RegularityDetector.defaultMaxCoefficientOfVariation,
         window: Int = RegularityDetector.defaultWindow) {
        self.minReps = max(3, minReps)
        self.maxCoefficientOfVariation = maxCoefficientOfVariation
        self.window = max(2, window)
    }

    var repCount: Int { timestamps.count }

    /// Intervalos entre repeticiones consecutivas (los últimos `window`).
    var intervals: [Double] {
        guard timestamps.count >= 2 else { return [] }
        let all = zip(timestamps.dropFirst(), timestamps).map { $0 - $1 }
        return Array(all.suffix(window))
    }

    /// std / mean de los intervalos (nil si hay menos de 2 intervalos o media ≤ 0).
    var coefficientOfVariation: Double? {
        let xs = intervals
        guard xs.count >= 2 else { return nil }
        let n = Double(xs.count)
        let mean = xs.reduce(0, +) / n
        guard mean > 0 else { return nil }
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        return variance.squareRoot() / mean
    }

    @discardableResult
    mutating func recordRep(at t: Double) -> Anomaly? {
        timestamps.append(t)
        guard !fired, timestamps.count >= minReps, let cv = coefficientOfVariation else { return nil }
        guard cv < maxCoefficientOfVariation else { return nil }
        fired = true
        return Anomaly(kind: Self.anomalyKind, severity: .hard, at: t,
                       detail: String(format: "CV de intervalos %.3f en %d reps", cv, timestamps.count))
    }

    mutating func reset() {
        timestamps = []
        fired = false
    }
}

// MARK: - TrackingDropDetector

/// Detecta saltos angulares imposibles para una cabeza (o un cuerpo) real:
/// |Δángulo| / Δt > `maxDegreesPerSecond` → anomalía `trackingJump` (soft).
/// Un salto así suele ser un cambio de cara/vídeo o una pérdida de tracking; por sí solo no
/// invalida la actividad (soft), pero varios seguidos sí deberían (lo decide el verificador).
nonisolated struct TrackingDropDetector: Sendable, Hashable, Codable {
    static let anomalyKind = "trackingJump"
    static let defaultMaxDegreesPerSecond: Double = 240
    /// Mínimo entre dos anomalías emitidas (evita inundar con un salto largo).
    static let defaultCooldownSeconds: Double = 0.5
    /// Un hueco mayor entre muestras no se evalúa (fue pérdida de tracking, no un salto).
    static let defaultMaxGapSeconds: Double = 0.5

    nonisolated struct Angles: Sendable, Hashable, Codable {
        var t: Double
        var yaw: Double
        var pitch: Double
        var roll: Double
    }

    var maxDegreesPerSecond: Double
    var cooldownSeconds: Double
    var maxGapSeconds: Double

    private var last: Angles? = nil
    private var lastFiredAt: Double? = nil
    private(set) var jumpCount: Int = 0
    /// Velocidad angular máxima observada (°/s), para diagnóstico.
    private(set) var peakRate: Double = 0

    init(maxDegreesPerSecond: Double = TrackingDropDetector.defaultMaxDegreesPerSecond,
         cooldownSeconds: Double = TrackingDropDetector.defaultCooldownSeconds,
         maxGapSeconds: Double = TrackingDropDetector.defaultMaxGapSeconds) {
        self.maxDegreesPerSecond = maxDegreesPerSecond
        self.cooldownSeconds = max(0, cooldownSeconds)
        self.maxGapSeconds = max(0, maxGapSeconds)
    }

    /// Ángulos en grados (yaw/pitch/roll). Devuelve la anomalía si alguno saltó más de lo permitido.
    @discardableResult
    mutating func ingest(yaw: Double, pitch: Double, roll: Double, at t: Double) -> Anomaly? {
        let now = Angles(t: t, yaw: yaw, pitch: pitch, roll: roll)
        defer { last = now }
        guard let prev = last else { return nil }
        let dt = t - prev.t
        guard dt > 0, dt <= maxGapSeconds else { return nil }
        let rate = max(abs(AngleMath.delta(yaw, prev.yaw)),
                       abs(AngleMath.delta(pitch, prev.pitch)),
                       abs(AngleMath.delta(roll, prev.roll))) / dt
        peakRate = max(peakRate, rate)
        guard rate > maxDegreesPerSecond else { return nil }
        jumpCount += 1
        if let lastFiredAt, t - lastFiredAt < cooldownSeconds { return nil }
        lastFiredAt = t
        return Anomaly(kind: Self.anomalyKind, severity: .soft, at: t,
                       detail: "Salto de \(Int(rate.rounded())) °/s")
    }

    /// Variante para una sola señal angular.
    @discardableResult
    mutating func ingest(angle: Double, at t: Double) -> Anomaly? {
        ingest(yaw: angle, pitch: 0, roll: 0, at: t)
    }

    /// Llamar cuando se pierde el tracking: el próximo valor no se compara con el anterior.
    mutating func reset() {
        last = nil
    }

    mutating func resetAll() {
        last = nil
        lastFiredAt = nil
        jumpCount = 0
        peakRate = 0
    }
}
