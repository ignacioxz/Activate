import Foundation
import simd

// Dueño: agente "squats". A3 sentadilla parcial con el teléfono EN LAS MANOS (modo principal).
//
// Marco sostiene el iPhone con las dos manos frente al pecho, pantalla hacia él, y hace sentadillas.
// `HandheldSquatSource` (ARKit) entrega en cada ARFrame la pose del teléfono en el mundo (seguimiento 6DOF
// con la cámara trasera + IMU, eje Y hacia arriba) y la cara (TrueDepth) en el mundo y en el espacio del
// teléfono. Esta máquina de estados es pura (sin ARKit/CoreMotion) y se prueba con muestras sintéticas.
//
// Por qué no se puede falsear con el teléfono en la mano:
// - Rep = el TELÉFONO baja ≥ 18 cm en el mundo y vuelve (no basta inclinarlo: hay que desplazarlo).
// - Anti-brazos: la CARA debe bajar lo mismo que el teléfono y la geometría cara-teléfono debe quedarse
//   quieta. Bajar el teléfono con los brazos deja la cara arriba → `armsOnly`.
// - Anti-inclinarse: si el teléfono cabecea > 25° o la cara se adelanta más de lo que baja, fue una
//   bisagra de cintura sin doblar rodillas → `torsoBend`.
// - Persona viva: la cara debe tener micro-expresiones (`shapeEnergy`); una foto o máscara pegada al
//   teléfono baja junto con él pero no se mueve → `static`.
// - Desafío: en una rep al azar aparece "Quédese abajo 2 segundos"; un vídeo o un mecanismo no lo sigue.
// - Sacudidas, ritmo de metrónomo y caminar → anomalías. Altímetro como apoyo (escalera / ascensor).
// - Sin seguimiento del mundo (cámara trasera tapada, equipo sin soporte): respaldo con la aceleración
//   vertical integrada + estabilidad de la cara en el encuadre; la fuente se declara `.fallback` (reduced).

// MARK: - Muestra de dominio

/// Una muestra por ARFrame (≈ 60 Hz). Unidades: metros, grados, m/s², g. Convertida en la cola del delegate.
nonisolated struct HandheldSquatSample: Sendable, Codable, Hashable, TimedSample {
    var t: Double
    /// Posición del teléfono en el mundo (m). Eje Y hacia arriba (`worldAlignment = .gravity`).
    var phonePos: SIMD3<Float>
    /// Actitud del teléfono respecto de la gravedad: cabeceo (pantalla hacia arriba > 0) y giro en su plano.
    var phonePitchDeg: Double
    var phoneRollDeg: Double
    /// Cara seguida por TrueDepth en este frame.
    var faceTracked: Bool
    /// Posición de la cara en el mundo (m).
    var facePos: SIMD3<Float>
    /// Cara en el espacio del teléfono (m): `camera⁻¹ · face`. Su norma es la distancia cara-teléfono.
    var faceInPhone: SIMD3<Float>
    /// Suma de |Δ| de 8 blendShapes respecto del frame anterior (≈ 0 = foto o máscara).
    var shapeEnergy: Float
    /// `camera.trackingState == .normal` con el seguimiento del mundo activo.
    var worldTrackingNormal: Bool
    /// Altura barométrica relativa (m), si hay altímetro y permiso.
    var altitude: Double? = nil
    /// RMS de |userAcceleration| en los últimos 0,5 s (g), si hay deviceMotion.
    var userAccelRMS: Double? = nil
    /// Aceleración vertical sin gravedad (m/s², + arriba), promedio desde la muestra anterior (respaldo IMU).
    var verticalAccel: Double? = nil
    /// Pasos del podómetro acumulados desde el inicio de la serie.
    var steps: Int? = nil
}

// MARK: - Umbrales (constantes nombradas; se calibran en el iPhone con el texto de depuración de la demo)

nonisolated enum HandheldSquatTuning {
    // Calibración de pie
    /// Segundos de pie, quieto y con la cara visible para fijar la referencia.
    static let calibrationSeconds = 1.0
    /// Quieto = el teléfono no varía más que esto en altura / en horizontal (m) ni en cabeceo (°).
    static let calibrationMaxPhoneRangeY = 0.03
    static let calibrationMaxPhoneDriftXZ = 0.05
    static let calibrationMaxPitchRange = 6.0
    /// Quieto en respaldo: |aceleración vertical| máxima (m/s²) y RMS de userAccel (g).
    static let calibrationMaxVerticalAccel = 0.45
    static let calibrationMaxAccelRMS = 0.08
    /// Si el seguimiento del mundo nunca llega a `.normal` en este tiempo, se usa el respaldo IMU.
    static let initialWorldGraceSeconds = 3.0

    // Señal y repetición
    /// Suavizado exponencial por muestra (≈ 60 Hz).
    static let emaAlpha = 0.3
    /// Sentadilla parcial: el teléfono baja ≥ 18 cm y vuelve a < 6 cm de la altura de pie.
    static let enterDescent = 0.18
    static let exitDescent = 0.06
    /// La ventana de la rep se abre cuando el teléfono baja más de esto (m).
    static let windowStartDescent = 0.03
    /// Duración de la rep completa (desde que empieza a bajar hasta que vuelve arriba).
    static let minRepSeconds = 0.8
    static let maxRepSeconds = 6.0
    /// Margen extra antes de abortar una rep que no vuelve (s).
    static let abortGraceSeconds = 2.0
    /// La referencia de pie se adapta lento entre reps (deriva del mundo, cambio de postura).
    static let referenceTimeConstant = 3.0
    /// "Abajo" para medir brazos / inclinación: fracción de `enterDescent`.
    static let bottomZoneFraction = 0.75
    /// Una bajada que no llega a la meta pero pasa de esto recibe "Baje un poco más".
    static let shallowCueDescent = 0.10

    // Anti-brazos
    /// Diferencia máxima entre lo que baja el teléfono y lo que baja la cara (m).
    static let armsOnlyMaxGap = 0.08
    /// Cambio máximo de la cara en el espacio del teléfono (m).
    static let faceGeometryMaxChange = 0.08
    /// La 3ª vez que baja solo con los brazos la anomalía pasa a hard.
    static let armsOnlyHardAt = 3

    // Anti-inclinarse (bisagra de cintura)
    static let torsoMaxPitchDelta = 25.0
    /// La cara puede adelantarse a lo sumo lo que baja + este margen (m).
    static let torsoForwardSlack = 0.02
    /// Máximo de anomalías `torsoBend` registradas (todas soft).
    static let torsoBendMaxRecorded = 5

    // Persona viva
    /// Media de `shapeEnergy` bajo la cual la cara no tiene micro-expresiones (mismo umbral que el cuello).
    static let liveFaceMinEnergy = 0.002
    static let staticWindowSeconds = 2.0
    static let staticMinSamples = 20
    /// Cara perdida más de esto con el gate listo → bloqueado.
    static let faceLostBlockSeconds = 1.5
    /// Fracción mínima de muestras de la rep con la cara seguida.
    static let minTrackedFraction = 0.7
    /// Distancia cara-teléfono aceptada (m): con los brazos frente al pecho ≈ 30-55 cm.
    static let faceDistanceMin = 0.18
    static let faceDistanceMax = 0.9

    // Desafío de ritmo
    /// "Abajo" para el desafío (m de descenso del teléfono).
    static let holdMinDescent = 0.12
    /// Quedarse abajo = la altura varía a lo sumo esto (m, máx − mín) durante la pausa. Una sentadilla a
    /// ritmo normal pasa por el fondo en < 1,5 s; solo una pausa de verdad suma el tiempo pedido.
    static let holdBand = 0.03
    /// Tiempo extra permitido a la rep del desafío.
    static let holdExtraSeconds = 4.0

    // Sacudidas, caminar, desplazamiento
    static let shakingAccelRMS = 0.6
    static let shakingSustainSeconds = 0.8
    static let walkingSteps = 8
    /// El teléfono no debe recorrer más que esto en horizontal durante una rep (m).
    static let maxRepHorizontalTravel = 0.45

    // Seguimiento del mundo
    static let worldLossToFallbackSeconds = 0.5
    static let worldRecoverSeconds = 1.0
    /// Salto imposible entre dos frames (relocalización del mundo).
    static let maxPhoneJumpPerFrame = 0.10
    static let worldJumpDebounceSeconds = 1.0
    /// Paso máximo de integración (una pausa del stream no se integra entera).
    static let maxIntegrationStep = 0.1

    // Respaldo IMU (doble integración con corrección de velocidad cero)
    /// Quieto para el ZUPT: |a vertical| < esto durante `zuptSeconds`.
    static let zuptAccel = 0.15
    static let zuptSeconds = 0.3
    /// Al quedar quieto tras subir al menos esta fracción del descenso, se da por arriba (corrige la deriva).
    static let fallbackSnapAscentFraction = 0.6

    // Barómetro (apoyo físico independiente; peso documentado en `HandheldSquatBarometer`)
    static let barometerTrendMeters = 1.5
    static let barometerTrendReadings = 3
    static let barometerMinSeconds = 8.0
    static let barometerMinReadingGap = 0.5

    /// Para que la métrica `minDescentRatio` sea comparable con las sesiones antiguas de cámara apoyada
    /// (descenso / estatura en el cuadro ≈ cuello-tobillo de un adulto).
    static let descentRatioReferenceMeters = 1.40
}

/// Copy en vivo (usted, frases cortas).
nonisolated enum HandheldSquatCopy {
    static let instructions = "Tome el teléfono con las dos manos frente al pecho y mírelo. Baje como si se sentara y vuelva a subir."
    static let takePhone = "Tome el teléfono frente al pecho y mírelo."
    static let holdStill = "Quieto un segundo."
    static let ready = "Baje como si se sentara y vuelva a subir."
    static let keepFace = "Mantenga la cara en la pantalla"
    static let tooClose = "Aleje un poco el teléfono."
    static let tooFar = "Acerque un poco el teléfono."
    static let lower = "Baje un poco más."
    static let slower = "Más lento."
    static let quicker = "Suba sin quedarse tanto abajo."
    static let comeBackUp = "Vuelva arriba."
    static let useLegs = "Baje con las piernas, no con los brazos."
    static let bendKnees = "Doble las rodillas, espalda derecha."
    static let stayInPlace = "Quédese en su lugar."
    static let noShake = "No sacuda el teléfono."
    static let uncoverCamera = "Sin tapar la cámara de atrás."
    static let lookAtScreen = "Mire la pantalla."
}

/// Nombres de anomalía de este verificador.
nonisolated enum HandheldSquatAnomaly {
    static let armsOnly = "armsOnly"
    static let torsoBend = "torsoBend"
    static let staticFace = "static"
    static let holdChallengeFailed = SquatHoldChallenge.anomalyKind
    static let shaking = "shaking"
    static let tooRegular = RegularityDetector.anomalyKind
    static let walking = "walking"
    static let barometerTrend = "barometerTrend"
    static let inertialFallback = "inertialFallback"
    static let worldJump = "worldJump"
}

// MARK: - Desafío de pausa (sentadilla "Quédese abajo", extensión lumbar "Quédese atrás")

/// Consigna del desafío según el ejercicio: misma regla, distinto texto.
nonisolated enum HoldChallengeCopy: String, Sendable, Hashable, Codable, CaseIterable {
    case squat
    case backExtension

    var cue: Cue {
        switch self {
        case .squat: Cue(text: "Quédese abajo 2 segundos", symbol: "pause.circle")
        case .backExtension: Cue(text: "Quédese atrás 2 segundos", symbol: "pause.circle")
        }
    }

    var missedCue: Cue {
        switch self {
        case .squat: Cue(text: "No contó. Quédese abajo 2 segundos", symbol: "pause.circle")
        case .backExtension: Cue(text: "No contó. Quédese atrás 2 segundos", symbol: "pause.circle")
        }
    }

    var doneCue: Cue {
        switch self {
        case .squat: Cue(text: "Ya. Suba.", symbol: "arrow.up")
        case .backExtension: Cue(text: "Ya. Vuelva derecho.", symbol: "figure.stand")
        }
    }

    var failureDetail: String {
        switch self {
        case .squat: "No se quedó abajo cuando se le pidió"
        case .backExtension: "No se quedó atrás cuando se le pidió"
        }
    }

    /// Textos que la vista muestra como consigna grande (todas las variantes).
    static var allCueTexts: Set<String> { Set(allCases.flatMap { [$0.cue.text, $0.missedCue.text] }) }
}

/// El desafío lo comparten la sentadilla y la extensión lumbar en las manos.
typealias HoldChallenge = SquatHoldChallenge

/// En una rep elegida al azar (semilla por sesión) la consigna pide quedarse abajo (o atrás); la rep solo
/// cuenta si se mantiene ≥ 1,5 s. Fallarlo 2 veces → `holdChallengeFailed` (hard) y el desafío se cierra.
nonisolated struct SquatHoldChallenge: Sendable, Hashable, Codable {
    static let anomalyKind = "holdChallengeFailed"
    static let requiredSeconds = 1.5
    static let maxFailures = 2
    /// La rep del desafío se elige entre la 2ª y esta (si la meta alcanza).
    static let latestRep = 6
    static let cue = HoldChallengeCopy.squat.cue
    static let missedCue = HoldChallengeCopy.squat.missedCue
    static let doneCue = HoldChallengeCopy.squat.doneCue
    /// Textos de la sentadilla que la vista muestra como consigna grande.
    static var cueTexts: Set<String> { [cue.text, missedCue.text] }

    /// Número (1-based) de la rep que lleva el desafío; 0 = sin desafío.
    let repNumber: Int
    /// Texto de las consignas (sentadilla por defecto).
    let copy: HoldChallengeCopy
    private(set) var failures = 0
    private(set) var passed = false
    private var announcedForFailures: Int? = nil

    init(repNumber: Int, copy: HoldChallengeCopy = .squat) {
        self.repNumber = max(0, repNumber)
        self.copy = copy
    }

    init(seed: UInt64, target: Int, copy: HoldChallengeCopy = .squat) {
        self.init(repNumber: Self.repNumber(seed: seed, target: target), copy: copy)
    }

    static let none = SquatHoldChallenge(repNumber: 0)

    /// El mismo desafío sin intentos (al reiniciar la actividad).
    var restarted: SquatHoldChallenge { SquatHoldChallenge(repNumber: repNumber, copy: copy) }

    var isEnabled: Bool { repNumber > 0 }
    var isFinished: Bool { !isEnabled || passed || failures >= Self.maxFailures }

    /// La próxima rep (`nextRep`, 1-based) debe incluir la pausa abajo.
    func isArmed(nextRep: Int) -> Bool { !isFinished && nextRep == repNumber }

    /// Consigna a mostrar (una vez por intento) cuando el desafío queda armado.
    mutating func announcement(nextRep: Int) -> Cue? {
        guard isArmed(nextRep: nextRep), announcedForFailures != failures else { return nil }
        announcedForFailures = failures
        return failures == 0 ? copy.cue : copy.missedCue
    }

    mutating func pass() { passed = true }

    /// Registra un intento sin pausa; al llegar al máximo devuelve la anomalía hard.
    mutating func fail(at t: Double) -> Anomaly? {
        guard !isFinished else { return nil }
        failures += 1
        guard failures >= Self.maxFailures else { return nil }
        return Anomaly(kind: Self.anomalyKind, severity: .hard, at: t, detail: copy.failureDetail)
    }

    /// Rep del desafío para una meta: entre la 2ª y la penúltima (máx. `latestRep`), determinista por semilla.
    static func repNumber(seed: UInt64, target: Int) -> Int {
        guard target >= 1 else { return 0 }
        let lower = min(2, target)
        let upper = max(lower, min(target - 1, latestRep))
        var rng = FixtureRandom(seed: seed)
        return lower + Int(rng.next() % UInt64(upper - lower + 1))
    }
}

// MARK: - Política del nivel de la fuente

/// El nivel `.live` exige seguimiento del mundo sostenido; si no, la fuente se declara `.fallback`
/// (las reps se midieron con el respaldo IMU) y la política deja la actividad en `reduced`.
nonisolated enum HandheldSquatSourcePolicy {
    /// Fracción mínima de frames (con cara) en seguimiento normal desde que el mundo arrancó.
    static let minWorldFraction = 0.8
    static let minFramesForDecision = 60

    nonisolated struct Stats: Sendable, Hashable, Codable {
        var everNormal = false
        var normalFrames = 0
        var countedFrames = 0
    }

    static func level(worldTrackingSupported: Bool, stats: Stats) -> SourceLevel {
        guard worldTrackingSupported, stats.everNormal else { return .fallback }
        guard stats.countedFrames >= minFramesForDecision else { return .live }
        return Double(stats.normalFrames) / Double(stats.countedFrames) >= minWorldFraction ? .live : .fallback
    }
}

// MARK: - Piezas puras

/// Tiempo "quieto abajo": el tramo reciente más largo en que la señal se mantiene sobre `floor` y su
/// rango (máx − mín) no supera `band`. Las muestras viejas salen solo lo necesario (ventana deslizante),
/// así el ruido en el borde de la banda no reinicia una pausa real.
nonisolated struct PlateauTimer: Sendable, Hashable {
    nonisolated struct Point: Sendable, Hashable {
        var t: Double
        var v: Double
    }

    let band: Double
    let floor: Double
    private(set) var points: [Point] = []
    /// Mejor pausa vista (s).
    private(set) var best = 0.0

    init(band: Double, floor: Double) {
        self.band = band
        self.floor = floor
    }

    /// Duración de la pausa en curso (s).
    var current: Double {
        guard let first = points.first, let last = points.last else { return 0 }
        return last.t - first.t
    }

    mutating func add(_ v: Double, at t: Double) {
        guard v >= floor else {
            points = []
            return
        }
        points.append(Point(t: t, v: v))
        while points.count > 1 {
            var lo = Double.infinity, hi = -Double.infinity
            for p in points {
                lo = min(lo, p.v)
                hi = max(hi, p.v)
            }
            guard hi - lo > band else { break }
            points.removeFirst()
        }
        best = max(best, current)
    }
}

/// Suavizado exponencial de un vector.
nonisolated struct VectorSmoother: Sendable, Hashable {
    var alpha: Double
    private(set) var value: SIMD3<Double>? = nil

    init(alpha: Double) { self.alpha = min(1, max(0.0001, alpha)) }

    @discardableResult
    mutating func update(_ x: SIMD3<Double>) -> SIMD3<Double> {
        let v = value.map { $0 + alpha * (x - $0) } ?? x
        value = v
        return v
    }

    mutating func reset() { value = nil }
}

/// Respaldo IMU: doble integración de la aceleración vertical con corrección de velocidad cero (ZUPT).
/// Al quedar quieto se quita la deriva lineal de velocidad del tramo (p −= v·T/2) y v = 0; de pie y
/// cerca del origen se re-ancla la posición a 0.
nonisolated struct InertialHeightTracker: Sendable, Hashable {
    private(set) var velocity = 0.0
    /// Posición vertical relativa a la referencia de pie (m, + arriba).
    private(set) var position = 0.0
    private(set) var stationary = true
    private var segmentStart: Double?
    private var quietSince: Double?

    mutating func reset() { self = InertialHeightTracker() }

    /// `anchorAllowed`: de pie entre reps (se puede re-anclar a 0).
    mutating func step(accel a: Double, dt: Double, t: Double, anchorAllowed: Bool) {
        velocity += a * dt
        position += velocity * dt
        if abs(a) < HandheldSquatTuning.zuptAccel {
            if quietSince == nil { quietSince = t }
        } else {
            quietSince = nil
            if stationary {
                stationary = false
                segmentStart = t
            }
        }
        if !stationary, let quiet = quietSince, t - quiet >= HandheldSquatTuning.zuptSeconds {
            let segment = max(0, t - (segmentStart ?? t))
            position -= velocity * segment / 2
            velocity = 0
            stationary = true
        }
        if stationary {
            velocity = 0
            if anchorAllowed, abs(position) < HandheldSquatTuning.exitDescent { position = 0 }
        }
    }

    /// Da por terminada la subida (deriva residual): vuelve al origen.
    mutating func snapToTop() {
        position = 0
        velocity = 0
    }
}

/// Altímetro como apoyo físico independiente.
///
/// Peso documentado: el barómetro NUNCA cuenta ni descuenta una rep ni decide el nivel. Solo puede:
/// (a) registrar `barometerTrend` (soft) si la altura sube o baja > 1,5 m durante la serie (escalera,
/// ascensor: no se queda en el mismo lugar), y (b) entregar la correlación altura barométrica ↔ altura
/// del teléfono para la revisión del kine y la depuración. Razón: la presión del campamento cambia con
/// puertas, viento y climatización; una sentadilla de 20 cm está cerca de la resolución del sensor.
nonisolated struct HandheldSquatBarometer: Sendable, Hashable {
    nonisolated struct Reading: Sendable, Hashable {
        var t: Double
        var altitude: Double
        var phoneHeight: Double?
    }

    private(set) var readings: [Reading] = []
    private(set) var trendReported = false

    mutating func add(altitude: Double, phoneHeight: Double?, at t: Double) {
        if let last = readings.last {
            guard altitude != last.altitude || t - last.t >= 1 else { return }
            guard t - last.t >= HandheldSquatTuning.barometerMinReadingGap else { return }
        }
        readings.append(Reading(t: t, altitude: altitude, phoneHeight: phoneHeight))
    }

    /// |media de las últimas n − media de las primeras n| (m).
    var trend: Double? {
        let n = HandheldSquatTuning.barometerTrendReadings
        guard readings.count >= 2 * n else { return nil }
        let first = readings.prefix(n).map(\.altitude).reduce(0, +) / Double(n)
        let last = readings.suffix(n).map(\.altitude).reduce(0, +) / Double(n)
        return abs(last - first)
    }

    var span: Double {
        guard let a = readings.first, let b = readings.last else { return 0 }
        return b.t - a.t
    }

    /// Correlación de Pearson entre la altura barométrica y la del teléfono (≥ 6 lecturas con mundo).
    var correlation: Double? {
        let pairs = readings.compactMap { r in r.phoneHeight.map { (r.altitude, $0) } }
        guard pairs.count >= 6 else { return nil }
        let n = Double(pairs.count)
        let mx = pairs.map(\.0).reduce(0, +) / n
        let my = pairs.map(\.1).reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in pairs {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
            syy += (y - my) * (y - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// Devuelve la anomalía soft (una vez) si hay tendencia de escalera / ascensor.
    mutating func checkTrend(at t: Double) -> Anomaly? {
        guard !trendReported, span >= HandheldSquatTuning.barometerMinSeconds, let trend,
              trend > HandheldSquatTuning.barometerTrendMeters else { return nil }
        trendReported = true
        return Anomaly(kind: HandheldSquatAnomaly.barometerTrend, severity: .soft, at: t,
                       detail: String(format: "La presión cambió %.1f m: escalera o ascensor", trend))
    }
}

// MARK: - Verificador

nonisolated struct HandheldSquatVerifier: ActivityVerifier {
    typealias Sample = HandheldSquatSample
    private typealias K = HandheldSquatTuning
    private typealias Copy = HandheldSquatCopy

    /// Fuente de la señal de altura: el mundo (VIO) o el respaldo IMU.
    nonisolated enum Mode: String, Sendable, Hashable, Codable { case world, inertial }

    nonisolated enum Rejection: String, Sendable, Hashable, Codable {
        case tooFast, tooSlow, shaking, moved, faceMissing, notLive, faceDistance, armsOnly, torsoBend, holdMissed
    }

    /// Lo medido en una rep (tests y calibración en el dispositivo).
    nonisolated struct RepDiagnostics: Sendable, Hashable {
        var at: Double
        var mode: Mode
        var seconds: Double
        var phoneDescent: Double
        var faceDescentAtPeak: Double?
        var maxGap: Double
        var geometryChange: Double
        var pitchDelta: Double
        var forwardExcess: Double?
        var holdSeconds: Double
        var meanEnergy: Double
        var trackedFraction: Double
        var meanFaceDistance: Double?
        var horizontalTravel: Double?
        var challengeArmed: Bool
        var rejection: Rejection?
    }

    /// Postura de pie de referencia.
    nonisolated struct Reference: Sendable, Hashable {
        var phoneY: Double
        var faceY: Double
        var phoneXZ: SIMD2<Double>
        var faceXZ: SIMD2<Double>
        var faceInPhone: SIMD3<Double>
        var pitch: Double
    }

    private nonisolated struct CalibrationPoint: Sendable, Hashable {
        var t: Double
        var phone: SIMD3<Double>
        var face: SIMD3<Double>
        var faceInPhone: SIMD3<Double>
        var pitch: Double
        var accel: Double
        var rms: Double?
    }

    private nonisolated struct RepWindow: Sendable, Hashable {
        var start: Double
        var challengeArmed: Bool
        var mode: Mode
        var entered = false
        var peakDescent = 0.0
        var faceDescentAtPeak: Double?
        var maxGap = 0.0
        var maxGeometryChange = 0.0
        var maxPitchDelta = 0.0
        var maxForwardExcess: Double?
        var hold = PlateauTimer(band: HandheldSquatTuning.holdBand, floor: HandheldSquatTuning.holdMinDescent)
        var holdDoneAnnounced = false
        var energySum = 0.0
        var energyCount = 0
        var samples = 0
        var trackedSamples = 0
        var distanceSum = 0.0
        var distanceCount = 0
        var maxHorizontalTravel: Double?
        var shaking = false
        var bottomSamples = 0
        var bottomFaceSamples = 0
    }

    let kind: ActivityKind = .sentadilla
    let spec: VerificationSpec
    private(set) var progress: VerifierProgress
    private(set) var challenge: SquatHoldChallenge
    private(set) var mode: Mode = .world
    private(set) var reference: Reference?
    private(set) var count = 0
    private(set) var anomalies: [Anomaly] = []
    private(set) var diagnostics: [RepDiagnostics] = []
    private(set) var repPeaks: [Double] = []
    private(set) var repSeconds: [Double] = []
    private(set) var inertialReps = 0
    private(set) var barometer = HandheldSquatBarometer()

    private var startT: Double?
    private var lastT: Double?
    private var lastSample: HandheldSquatSample?
    private var everReady = false
    private var completedEmitted = false
    private var reps = RepMachine(enterThreshold: K.enterDescent, exitThreshold: K.exitDescent,
                                  minRepSeconds: 0, maxRepSeconds: 3600)
    private var descent = ExponentialSmoother(alpha: K.emaAlpha)
    private var faceSmooth = VectorSmoother(alpha: K.emaAlpha)
    private var fipSmooth = VectorSmoother(alpha: K.emaAlpha)
    private var pitchSmooth = ExponentialSmoother(alpha: K.emaAlpha)
    private var inertial = InertialHeightTracker()
    private var calibration: [CalibrationPoint] = []
    private var window: RepWindow?
    private var regularity = RegularityDetector()

    private var faceLostSince: Double?
    private var worldEverNormal = false
    private var worldBadSince: Double?
    private var worldGoodSince: Double?
    private var lastWorldJumpAt: Double?
    private var energyWindow: [(t: Double, e: Double)] = []
    private var energySum = 0.0
    private var staticReported = false
    private var shakingSince: Double?
    private var shakingReported = false
    private var walkingReported = false
    private var inertialReported = false
    private var armsOnlyCount = 0
    private var torsoBendCount = 0

    init(spec: VerificationSpec, challenge: SquatHoldChallenge = .none) {
        self.spec = spec
        self.challenge = challenge
        progress = VerifierProgress(target: spec.target, hint: Copy.takePhone)
    }

    init(target: Int? = nil, demo: Bool = false, challenge: SquatHoldChallenge = .none) {
        self.init(spec: .standard(for: .sentadilla, target: target, demo: demo), challenge: challenge)
    }

    // MARK: Lecturas

    var isLive: Bool { !staticReported }
    var minPeakDescent: Double? { repPeaks.min() }
    var meanRepSeconds: Double? { repSeconds.isEmpty ? nil : repSeconds.reduce(0, +) / Double(repSeconds.count) }

    // MARK: ActivityVerifier

    mutating func start(at t: Double) {
        let fresh = HandheldSquatVerifier(spec: spec, challenge: challenge.restarted)
        self = fresh
        startT = t
    }

    mutating func ingest(_ s: HandheldSquatSample, at t: Double) -> [VerifierEvent] {
        var events: [VerifierEvent] = []
        if startT == nil { startT = t }
        let dt = lastT.map { min(K.maxIntegrationStep, max(0, t - $0)) } ?? 0
        lastT = t

        detectShaking(s, t, &events)
        detectWalking(s, t, &events)
        trackBarometer(s, t, &events)
        trackLiveness(s, t, &events)
        updateMode(s, t, &events)
        if let a = s.verticalAccel {
            inertial.step(accel: a, dt: dt, t: t, anchorAllowed: window == nil)
        }
        if s.faceTracked {
            faceSmooth.update(Self.d3(s.facePos))
            fipSmooth.update(Self.d3(s.faceInPhone))
        }
        pitchSmooth.update(s.phonePitchDeg)
        detectWorldJump(s, t, &events)
        updateFaceGate(s, t, &events)

        switch progress.gate {
        case .calibrating: calibrate(s, t, &events)
        case .ready: track(s, t, dt, &events)
        case .blocked: break
        }

        progress.count = count
        progress.elapsed = max(0, t - (startT ?? t))
        lastSample = s
        return events
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        if let a = barometer.checkTrend(at: t) { anomalies.append(a) }
        let ratio = minPeakDescent.map { $0 / K.descentRatioReferenceMeters }
        return ActivityOutcome(
            kind: kind,
            target: progress.target,
            achieved: count,
            completed: count >= progress.target,
            durationSeconds: max(0, t - (startT ?? t)),
            metrics: .reps(count: count, minDescentRatio: ratio, meanRepSeconds: meanRepSeconds),
            anomalies: anomalies.sorted { $0.at < $1.at },
            reason: reason)
    }

    // MARK: Gate

    private mutating func setGate(_ gate: GateState, _ events: inout [VerifierEvent]) {
        guard progress.gate != gate else { return }
        progress.gate = gate
        events.append(.gate(gate))
    }

    private mutating func abortRep() {
        window = nil
        reps.reset()
        descent.reset()
    }

    /// Vuelve a calibrar de pie sin perder el conteo.
    private mutating func recalibrate(hint: String, _ events: inout [VerifierEvent]) {
        abortRep()
        calibration = []
        setGate(.calibrating, &events)
        progress.hint = hint
    }

    private mutating func updateFaceGate(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        if s.faceTracked {
            faceLostSince = nil
            if case .blocked(let reason) = progress.gate, reason == Copy.keepFace {
                recalibrate(hint: Copy.holdStill, &events)
            }
            return
        }
        if faceLostSince == nil { faceLostSince = t }
        let lost = t - (faceLostSince ?? t)
        switch progress.gate {
        case .ready where lost >= K.faceLostBlockSeconds:
            abortRep()
            setGate(.blocked(reason: Copy.keepFace), &events)
            progress.hint = Copy.keepFace
        case .calibrating:
            calibration = []
            progress.hint = everReady ? Copy.keepFace : Copy.takePhone
        default:
            break
        }
    }

    // MARK: Mundo ↔ respaldo IMU

    private mutating func updateMode(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        if s.worldTrackingNormal {
            worldEverNormal = true
            worldBadSince = nil
            if worldGoodSince == nil { worldGoodSince = t }
        } else {
            worldGoodSince = nil
            if worldBadSince == nil { worldBadSince = t }
        }
        switch mode {
        case .world:
            let bad = t - (worldBadSince ?? t)
            let lostAfterNormal = worldEverNormal && worldBadSince != nil && bad >= K.worldLossToFallbackSeconds
            let neverStarted = !worldEverNormal && t - (startT ?? t) >= K.initialWorldGraceSeconds
            guard lostAfterNormal || neverStarted else { return }
            mode = .inertial
            switchedMode(&events)
        case .inertial:
            guard let good = worldGoodSince, t - good >= K.worldRecoverSeconds else { return }
            mode = .world
            switchedMode(&events)
        }
    }

    private mutating func switchedMode(_ events: inout [VerifierEvent]) {
        inertial.reset()
        if progress.gate == .ready {
            recalibrate(hint: mode == .inertial ? Copy.uncoverCamera : Copy.holdStill, &events)
        } else {
            calibration = []
        }
    }

    private mutating func detectWorldJump(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        guard mode == .world, s.worldTrackingNormal, let last = lastSample, last.worldTrackingNormal else { return }
        let jump = simd_distance(Self.d3(s.phonePos), Self.d3(last.phonePos))
        guard jump > K.maxPhoneJumpPerFrame else { return }
        if progress.gate == .ready {
            if lastWorldJumpAt.map({ t - $0 >= K.worldJumpDebounceSeconds }) ?? true {
                lastWorldJumpAt = t
                let a = Anomaly(kind: HandheldSquatAnomaly.worldJump, severity: .soft, at: t,
                                detail: String(format: "El seguimiento saltó %.0f cm", jump * 100))
                anomalies.append(a)
                events.append(.anomaly(a))
            }
            recalibrate(hint: Copy.holdStill, &events)
        } else {
            calibration = []
        }
    }

    // MARK: Calibración de pie

    private func faceDistance(_ s: HandheldSquatSample) -> Double { Double(simd_length(s.faceInPhone)) }

    private mutating func calibrate(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        guard s.faceTracked else { return }
        let distance = faceDistance(s)
        if distance < K.faceDistanceMin || distance > K.faceDistanceMax {
            calibration = []
            progress.hint = distance < K.faceDistanceMin ? Copy.tooClose : Copy.tooFar
            return
        }
        switch mode {
        case .world:
            guard s.worldTrackingNormal else {
                calibration = []
                return
            }
        case .inertial:
            guard s.verticalAccel != nil else {
                calibration = []
                progress.hint = Copy.uncoverCamera
                return
            }
        }
        calibration.append(CalibrationPoint(t: t, phone: Self.d3(s.phonePos), face: Self.d3(s.facePos),
                                            faceInPhone: Self.d3(s.faceInPhone), pitch: s.phonePitchDeg,
                                            accel: s.verticalAccel ?? 0, rms: s.userAccelRMS))
        while calibration.count > 1, calibration[1].t <= t - K.calibrationSeconds {
            calibration.removeFirst()
        }
        progress.hint = Copy.holdStill
        guard let first = calibration.first, t - first.t >= K.calibrationSeconds * 0.95, isStill(calibration) else { return }

        let n = Double(calibration.count)
        let phone = calibration.map(\.phone).reduce(SIMD3<Double>(repeating: 0), +) / n
        let face = calibration.map(\.face).reduce(SIMD3<Double>(repeating: 0), +) / n
        let fip = calibration.map(\.faceInPhone).reduce(SIMD3<Double>(repeating: 0), +) / n
        let pitch = calibration.map(\.pitch).reduce(0, +) / n
        reference = Reference(phoneY: phone.y, faceY: face.y,
                              phoneXZ: SIMD2(phone.x, phone.z), faceXZ: SIMD2(face.x, face.z),
                              faceInPhone: fip, pitch: pitch)
        calibration = []
        inertial.reset()
        abortRep()
        everReady = true
        setGate(.ready, &events)
        progress.hint = Copy.ready
        events.append(.cue(Cue(text: Copy.ready, symbol: "figure.cross.training")))
        announceChallengeIfNeeded(&events)
    }

    private func isStill(_ points: [CalibrationPoint]) -> Bool {
        let pitches = points.map(\.pitch)
        guard let pMin = pitches.min(), let pMax = pitches.max(), pMax - pMin <= K.calibrationMaxPitchRange else { return false }
        switch mode {
        case .world:
            let ys = points.map(\.phone.y)
            guard let yMin = ys.min(), let yMax = ys.max(), yMax - yMin <= K.calibrationMaxPhoneRangeY else { return false }
            let mean = points.map(\.phone).reduce(SIMD3<Double>(repeating: 0), +) / Double(points.count)
            return points.allSatisfy { simd_length(SIMD2($0.phone.x - mean.x, $0.phone.z - mean.z)) <= K.calibrationMaxPhoneDriftXZ }
        case .inertial:
            guard points.allSatisfy({ abs($0.accel) <= K.calibrationMaxVerticalAccel }) else { return false }
            return points.allSatisfy { ($0.rms ?? 0) <= K.calibrationMaxAccelRMS }
        }
    }

    // MARK: Conteo

    private mutating func track(_ s: HandheldSquatSample, _ t: Double, _ dt: Double, _ events: inout [VerifierEvent]) {
        guard var ref = reference else { return }
        let raw: Double
        switch mode {
        case .world:
            guard s.worldTrackingNormal else { return }
            raw = ref.phoneY - Double(s.phonePos.y)
        case .inertial:
            guard s.verticalAccel != nil else { return }
            raw = -inertial.position
        }
        let d = descent.update(raw)
        let face = faceSmooth.value
        let fip = fipSmooth.value
        let pitch = pitchSmooth.value ?? s.phonePitchDeg

        if window == nil {
            if d > K.windowStartDescent {
                window = RepWindow(start: t, challengeArmed: challenge.isArmed(nextRep: count + 1), mode: mode)
            } else {
                adaptReference(&ref, s, face: face, fip: fip, pitch: pitch, dt: dt)
                reference = ref
                return
            }
        }
        guard var w = window else { return }

        // Medidas de esta muestra.
        let faceDescent: Double? = (mode == .world && s.faceTracked) ? face.map { ref.faceY - $0.y } : nil
        let geometry = (s.faceTracked ? fip : nil).map { simd_length($0 - ref.faceInPhone) }
        let pitchDelta = abs(AngleMath.delta(pitch, ref.pitch))
        let bottom = d >= K.bottomZoneFraction * K.enterDescent

        w.samples += 1
        if s.faceTracked {
            w.trackedSamples += 1
            w.energySum += Double(s.shapeEnergy)
            w.energyCount += 1
            w.distanceSum += faceDistance(s)
            w.distanceCount += 1
        }
        if let rms = s.userAccelRMS, rms >= K.shakingAccelRMS { w.shaking = true }
        w.maxPitchDelta = max(w.maxPitchDelta, pitchDelta)
        if mode == .world {
            let travel = simd_length(SIMD2(Double(s.phonePos.x), Double(s.phonePos.z)) - ref.phoneXZ)
            w.maxHorizontalTravel = max(w.maxHorizontalTravel ?? 0, travel)
        }
        if d > w.peakDescent {
            w.peakDescent = d
            w.faceDescentAtPeak = faceDescent ?? w.faceDescentAtPeak
        }
        if bottom {
            w.bottomSamples += 1
            if s.faceTracked { w.bottomFaceSamples += 1 }
            if let faceDescent { w.maxGap = max(w.maxGap, abs(d - faceDescent)) }
            if let geometry { w.maxGeometryChange = max(w.maxGeometryChange, geometry) }
            if mode == .world, s.faceTracked, let face, let faceDescent {
                let forward = simd_length(SIMD2(face.x, face.z) - ref.faceXZ)
                let excess = forward - faceDescent
                w.maxForwardExcess = max(w.maxForwardExcess ?? excess, excess)
            }
        }
        w.hold.add(d, at: t)
        if w.challengeArmed, !w.holdDoneAnnounced, w.hold.best >= SquatHoldChallenge.requiredSeconds {
            w.holdDoneAnnounced = true
            events.append(.cue(SquatHoldChallenge.doneCue))
        }

        // Respaldo: quieto tras subir lo suficiente = arriba (corrige la deriva residual de la integración).
        if mode == .inertial, w.entered, inertial.stationary,
           w.peakDescent - d >= K.fallbackSnapAscentFraction * w.peakDescent {
            inertial.snapToTop()
            descent.reset()
            descent.update(0)
            window = w
            closeWindow(at: t, &events)
            return
        }

        switch reps.update(d, at: t) {
        case .entered:
            w.entered = true
        case .rep:
            window = w
            closeWindow(at: t, &events)
            return
        case .rejected:
            window = nil
            reps.reset()
            return
        case .idle:
            if !w.entered, d <= K.windowStartDescent * 0.5 {
                if w.peakDescent >= K.shallowCueDescent {
                    events.append(.cue(Cue(text: Copy.lower, symbol: "arrow.down")))
                }
                window = nil
                return
            }
            let limit = K.maxRepSeconds + (w.challengeArmed ? K.holdExtraSeconds : 0) + K.abortGraceSeconds
            if t - w.start > limit {
                // Abajo demasiado rato (o de pie un poco más bajo que la referencia): se descarta sin contar.
                if w.entered { events.append(.cue(Cue(text: Copy.comeBackUp, symbol: "arrow.up"))) }
                abortRep()
                return
            }
        }
        window = w
    }

    private mutating func adaptReference(_ ref: inout Reference, _ s: HandheldSquatSample, face: SIMD3<Double>?,
                                         fip: SIMD3<Double>?, pitch: Double, dt: Double) {
        let k = min(1, dt / K.referenceTimeConstant)
        guard k > 0 else { return }
        if mode == .world, s.worldTrackingNormal {
            ref.phoneY += k * (Double(s.phonePos.y) - ref.phoneY)
            ref.phoneXZ += k * (SIMD2(Double(s.phonePos.x), Double(s.phonePos.z)) - ref.phoneXZ)
            if s.faceTracked, let face {
                ref.faceY += k * (face.y - ref.faceY)
                ref.faceXZ += k * (SIMD2(face.x, face.z) - ref.faceXZ)
            }
        }
        if s.faceTracked, let fip { ref.faceInPhone += k * (fip - ref.faceInPhone) }
        ref.pitch += k * AngleMath.delta(pitch, ref.pitch)
    }

    /// La señal volvió arriba: evalúa la ventana y cuenta o rechaza.
    private mutating func closeWindow(at t: Double, _ events: inout [VerifierEvent]) {
        guard let w = window else { return }
        window = nil
        reps.reset()
        let seconds = t - w.start
        let tracked = w.samples > 0 ? Double(w.trackedSamples) / Double(w.samples) : 0
        let energy = w.energyCount > 0 ? w.energySum / Double(w.energyCount) : 0
        let distance = w.distanceCount > 0 ? w.distanceSum / Double(w.distanceCount) : nil
        let maxSeconds = K.maxRepSeconds + (w.challengeArmed ? K.holdExtraSeconds : 0)

        var rejection: Rejection?
        if w.shaking {
            rejection = .shaking
        } else if let travel = w.maxHorizontalTravel, travel > K.maxRepHorizontalTravel {
            rejection = .moved
        } else if tracked < K.minTrackedFraction || (w.bottomSamples > 0 && w.bottomFaceSamples == 0) {
            rejection = .faceMissing
        } else if energy < K.liveFaceMinEnergy {
            rejection = .notLive
        } else if let distance, distance < K.faceDistanceMin || distance > K.faceDistanceMax {
            rejection = .faceDistance
        } else if w.maxGap > K.armsOnlyMaxGap || w.maxGeometryChange > K.faceGeometryMaxChange {
            rejection = .armsOnly
        } else if w.maxPitchDelta > K.torsoMaxPitchDelta || (w.maxForwardExcess ?? -1) > K.torsoForwardSlack {
            rejection = .torsoBend
        } else if seconds < K.minRepSeconds {
            rejection = .tooFast
        } else if seconds > maxSeconds {
            rejection = .tooSlow
        } else if w.challengeArmed, w.hold.best < SquatHoldChallenge.requiredSeconds {
            rejection = .holdMissed
        }

        diagnostics.append(RepDiagnostics(
            at: t, mode: w.mode, seconds: seconds, phoneDescent: w.peakDescent, faceDescentAtPeak: w.faceDescentAtPeak,
            maxGap: w.maxGap, geometryChange: w.maxGeometryChange, pitchDelta: w.maxPitchDelta,
            forwardExcess: w.maxForwardExcess, holdSeconds: w.hold.best, meanEnergy: energy, trackedFraction: tracked,
            meanFaceDistance: distance, horizontalTravel: w.maxHorizontalTravel, challengeArmed: w.challengeArmed,
            rejection: rejection))

        guard let rejection else {
            countRep(w, seconds: seconds, at: t, &events)
            return
        }
        reject(rejection, w, at: t, &events)
    }

    private mutating func countRep(_ w: RepWindow, seconds: Double, at t: Double, _ events: inout [VerifierEvent]) {
        count += 1
        repPeaks.append(w.peakDescent)
        repSeconds.append(seconds)
        if w.challengeArmed { challenge.pass() }
        if w.mode == .inertial {
            inertialReps += 1
            if !inertialReported {
                inertialReported = true
                record(Anomaly(kind: HandheldSquatAnomaly.inertialFallback, severity: .soft, at: t,
                               detail: "Contado con el acelerómetro: sin seguimiento del mundo"), &events)
            }
        }
        events.append(.rep(count))
        events.append(.progress(min(1, Double(count) / Double(max(1, progress.target)))))
        if let a = regularity.recordRep(at: t) { record(a, &events) }
        progress.count = count
        if count >= progress.target {
            if !completedEmitted {
                completedEmitted = true
                events.append(.completed)
            }
            return
        }
        progress.hint = Copy.ready
        announceChallengeIfNeeded(&events)
    }

    private mutating func reject(_ rejection: Rejection, _ w: RepWindow, at t: Double, _ events: inout [VerifierEvent]) {
        switch rejection {
        case .armsOnly:
            armsOnlyCount += 1
            let severity: Anomaly.Severity = armsOnlyCount == K.armsOnlyHardAt ? .hard : .soft
            record(Anomaly(kind: HandheldSquatAnomaly.armsOnly, severity: severity, at: t,
                           detail: String(format: "Bajó el teléfono %.0f cm y la cara %.0f cm: con los brazos",
                                          w.peakDescent * 100, (w.faceDescentAtPeak ?? 0) * 100)), &events)
            events.append(.cue(Cue(text: Copy.useLegs, symbol: "figure.cross.training")))
        case .torsoBend:
            torsoBendCount += 1
            if torsoBendCount <= K.torsoBendMaxRecorded {
                record(Anomaly(kind: HandheldSquatAnomaly.torsoBend, severity: .soft, at: t,
                               detail: "Se inclinó de cintura sin doblar las rodillas"), &events)
            }
            events.append(.cue(Cue(text: Copy.bendKnees, symbol: "figure.cross.training")))
        case .holdMissed:
            if let a = challenge.fail(at: t) { record(a, &events) }
            announceChallengeIfNeeded(&events)
        case .shaking:
            events.append(.cue(Cue(text: Copy.noShake, symbol: "iphone.radiowaves.left.and.right")))
        case .moved:
            events.append(.cue(Cue(text: Copy.stayInPlace, symbol: "figure.stand")))
        case .faceMissing:
            events.append(.cue(Cue(text: Copy.keepFace, symbol: "face.dashed")))
        case .notLive:
            events.append(.cue(Cue(text: Copy.lookAtScreen, symbol: "face.smiling")))
        case .faceDistance:
            let close = (w.distanceCount > 0 ? w.distanceSum / Double(w.distanceCount) : 0) < K.faceDistanceMin
            events.append(.cue(Cue(text: close ? Copy.tooClose : Copy.tooFar, symbol: "iphone")))
        case .tooFast:
            events.append(.cue(Cue(text: Copy.slower, symbol: "tortoise")))
        case .tooSlow:
            events.append(.cue(Cue(text: Copy.quicker, symbol: "arrow.up")))
        }
    }

    private mutating func announceChallengeIfNeeded(_ events: inout [VerifierEvent]) {
        guard progress.gate == .ready, let cue = challenge.announcement(nextRep: count + 1) else { return }
        events.append(.cue(cue))
        progress.hint = cue.text
    }

    private mutating func record(_ a: Anomaly, _ events: inout [VerifierEvent]) {
        anomalies.append(a)
        events.append(.anomaly(a))
    }

    // MARK: Anomalías de fondo

    private mutating func detectShaking(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        guard let rms = s.userAccelRMS, rms >= K.shakingAccelRMS else {
            shakingSince = nil
            return
        }
        if shakingSince == nil { shakingSince = t }
        guard !shakingReported, t - (shakingSince ?? t) >= K.shakingSustainSeconds else { return }
        shakingReported = true
        record(Anomaly(kind: HandheldSquatAnomaly.shaking, severity: .hard, at: t,
                       detail: String(format: "Sacudida de %.1f g", rms)), &events)
        events.append(.cue(Cue(text: Copy.noShake, symbol: "iphone.radiowaves.left.and.right")))
        if window != nil { abortRep() }
    }

    private mutating func detectWalking(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        guard !walkingReported, let steps = s.steps, steps >= K.walkingSteps else { return }
        walkingReported = true
        record(Anomaly(kind: HandheldSquatAnomaly.walking, severity: .soft, at: t,
                       detail: "\(steps) pasos durante la serie"), &events)
        events.append(.cue(Cue(text: Copy.stayInPlace, symbol: "figure.stand")))
    }

    private mutating func trackBarometer(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        guard let altitude = s.altitude else { return }
        let height: Double? = (mode == .world && s.worldTrackingNormal) ? Double(s.phonePos.y) : nil
        barometer.add(altitude: altitude, phoneHeight: height, at: t)
        if let a = barometer.checkTrend(at: t) { record(a, &events) }
    }

    /// Persona viva: media de `shapeEnergy` en los últimos 2 s con la cara seguida.
    private mutating func trackLiveness(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        guard s.faceTracked else { return }
        let e = Double(s.shapeEnergy)
        energyWindow.append((t, e))
        energySum += e
        while let first = energyWindow.first, first.t < t - K.staticWindowSeconds {
            energySum -= first.e
            energyWindow.removeFirst()
        }
        guard !staticReported, energyWindow.count >= K.staticMinSamples,
              let first = energyWindow.first, t - first.t >= K.staticWindowSeconds * 0.95 else { return }
        let mean = energySum / Double(energyWindow.count)
        guard mean < K.liveFaceMinEnergy else { return }
        staticReported = true
        record(Anomaly(kind: HandheldSquatAnomaly.staticFace, severity: .hard, at: t,
                       detail: "Cara sin micro-movimiento: foto o máscara"), &events)
        events.append(.cue(Cue(text: Copy.lookAtScreen, symbol: "face.smiling")))
    }

    // MARK: Utilidades

    static func d3(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
}

// MARK: - Muestras sintéticas (replay en simulador y tests)

/// Generador determinista de series con el teléfono en las manos (≈ 60 Hz, ruido de VIO, IMU y blendShapes).
/// Mundo: Y arriba; la persona mira hacia −Z; el teléfono va frente al pecho y la cara 35 cm más arriba
/// y 38 cm más atrás (+Z).
nonisolated enum HandheldSquatSynth {
    nonisolated enum Style: String, Sendable, Hashable, Codable {
        /// Sentadilla real: teléfono y cara bajan juntos, la geometría cara-teléfono se mantiene.
        case squat
        /// Solo los brazos bajan el teléfono (y lo inclinan para seguir mirándolo); la cara se queda.
        case armsOnly
        /// Bisagra de cintura sin doblar rodillas: todo baja, la cara se adelanta mucho, el teléfono cabecea.
        case torsoBend
        /// Foto o máscara pegada al teléfono: la "cara" baja con él, sin micro-expresiones.
        case photo
    }

    nonisolated struct Rep: Sendable, Hashable {
        var depth = 0.22
        var downSeconds = 1.0
        var holdSeconds = 0.25
        var upSeconds = 1.0
        var restSeconds = 0.8
        var style: Style = .squat

        init(depth: Double = 0.22, downSeconds: Double = 1.0, holdSeconds: Double = 0.25, upSeconds: Double = 1.0,
             restSeconds: Double = 0.8, style: Style = .squat) {
            self.depth = depth
            self.downSeconds = downSeconds
            self.holdSeconds = holdSeconds
            self.upSeconds = upSeconds
            self.restSeconds = restSeconds
            self.style = style
        }
    }

    nonisolated struct Options: Sendable, Hashable {
        var fps = 60.0
        var seed: UInt64 = 1
        var leadInSeconds = 1.8
        var trailSeconds = 1.0
        /// `false` = seguimiento del mundo limitado (cámara trasera tapada): posiciones sin sentido.
        var world = true
        var positionNoise = 0.0015
        var shapeEnergy: Float = 0.02
        var includeMotion = true
        var accelNoise = 0.04
        var accelBias = 0.0
        var altitude: Double? = 0
        var altitudeNoise = 0.05
        /// Escalera / ascensor: metros por segundo de altura barométrica.
        var altitudeTrendPerSecond = 0.0
        /// Caminar después del lead-in.
        var walkSpeed = 0.0
        var stepsPerSecond = 0.0
        var walkBobAmplitude = 0.025
        /// Sacudir el teléfono después del lead-in.
        var shakeAmplitude = 0.0
        var shakeHz = 6.0
        var shakeRMS = 1.2

        init() {}
    }

    static let standingPhone = SIMD3<Double>(0, 1.20, 0)
    static let standingFace = SIMD3<Double>(0, 1.55, 0.38)

    /// Perfil de mínimo jerk 0 → 1 y su segunda derivada por unidad de τ².
    static func minJerk(_ tau: Double) -> Double {
        let x = min(1, max(0, tau))
        return x * x * x * (10 - 15 * x + 6 * x * x)
    }

    static func minJerkAccel(_ tau: Double) -> Double {
        guard tau > 0, tau < 1 else { return 0 }
        return 60 * tau - 180 * tau * tau + 120 * tau * tau * tau
    }

    nonisolated private struct Segment {
        var start: Double
        var rep: Rep
        var end: Double { start + rep.downSeconds + rep.holdSeconds + rep.upSeconds }
    }

    /// Serie de reps (con su descanso) tras `leadInSeconds` de pie quieto.
    static func samples(reps: [Rep], options: Options = Options()) -> [HandheldSquatSample] {
        var rng = FixtureRandom(seed: options.seed)
        var segments: [Segment] = []
        var cursor = options.leadInSeconds
        for rep in reps {
            segments.append(Segment(start: cursor, rep: rep))
            cursor += rep.downSeconds + rep.holdSeconds + rep.upSeconds + rep.restSeconds
        }
        let total = cursor + options.trailSeconds
        let dt = 1 / max(1, options.fps)
        let frames = Int((total / dt).rounded(.up))
        var out: [HandheldSquatSample] = []
        out.reserveCapacity(frames + 1)
        var altitude = options.altitude
        var nextAltitudeAt = 0.0
        let fip0 = standingFace - standingPhone

        for i in 0...frames {
            let t = Double(i) * dt
            var x = 0.0
            var accel = 0.0
            var style: Style = .squat
            var depth = 0.0
            if let seg = segments.last(where: { $0.start <= t }), t < seg.end {
                let r = seg.rep
                style = r.style
                depth = r.depth
                let local = t - seg.start
                if local < r.downSeconds {
                    let tau = local / r.downSeconds
                    x = minJerk(tau)
                    accel = -depth * minJerkAccel(tau) / (r.downSeconds * r.downSeconds)
                } else if local < r.downSeconds + r.holdSeconds {
                    x = 1
                } else {
                    let tau = (local - r.downSeconds - r.holdSeconds) / r.upSeconds
                    x = 1 - minJerk(tau)
                    accel = depth * minJerkAccel(tau) / (r.upSeconds * r.upSeconds)
                }
            }
            let drop = depth * x

            var phone = standingPhone
            var face = standingFace
            var fip = fip0
            var pitch = 4.0
            switch style {
            case .squat:
                phone.y -= drop
                phone.z -= 0.02 * x
                face.y -= drop * 0.97
                face.z -= 0.04 * x
                pitch += 8 * x
            case .armsOnly:
                phone.y -= drop
                fip.y += drop
                pitch += 15 * x
            case .torsoBend:
                phone.y -= drop
                phone.z -= 1.6 * drop
                face.y -= drop * 1.1
                face.z -= 2.0 * drop
                pitch -= 35 * x
            case .photo:
                phone.y -= drop
                face.y -= drop
            }

            let walking = options.walkSpeed > 0 && t >= options.leadInSeconds
            if walking {
                let w = t - options.leadInSeconds
                let bob = options.walkBobAmplitude * sin(2 * .pi * options.stepsPerSecond * w)
                phone.z -= options.walkSpeed * w
                face.z -= options.walkSpeed * w
                phone.y += bob
                face.y += bob
                let omega = 2 * .pi * options.stepsPerSecond
                accel += -options.walkBobAmplitude * omega * omega * sin(omega * w)
            }
            let shaking = options.shakeAmplitude > 0 && t >= options.leadInSeconds
            if shaking {
                let omega = 2 * .pi * options.shakeHz
                let s = sin(omega * (t - options.leadInSeconds))
                phone.y += options.shakeAmplitude * s
                phone.x += options.shakeAmplitude * 0.6 * s
                fip.y -= options.shakeAmplitude * s
                accel += -options.shakeAmplitude * omega * omega * s
            }

            let n = options.positionNoise
            func jitter(_ v: SIMD3<Double>) -> SIMD3<Double> {
                v + SIMD3(rng.symmetric(n), rng.symmetric(n), rng.symmetric(n))
            }
            let photo = style == .photo
            let phoneWorld = options.world ? jitter(phone) : SIMD3(rng.symmetric(0.3), rng.symmetric(0.3), rng.symmetric(0.3))
            let faceWorld = options.world ? jitter(face) : SIMD3(0, 0, -0.45) + SIMD3(rng.symmetric(n), rng.symmetric(n), rng.symmetric(n))
            let faceInPhone = photo ? fip : jitter(fip)
            let energy = photo ? Float(rng.unit() * 0.0004) : max(0, options.shapeEnergy * Float(0.5 + rng.unit()))

            var rms: Double? = nil
            var vertical: Double? = nil
            if options.includeMotion {
                vertical = accel + options.accelBias + rng.symmetric(options.accelNoise)
                let base = walking ? 0.25 : 0.02
                rms = shaking ? options.shakeRMS + rng.symmetric(0.1) : (base * base + (accel / 9.80665) * (accel / 9.80665)).squareRoot()
            }
            var steps: Int? = nil
            if options.stepsPerSecond > 0 {
                steps = walking ? Int(options.stepsPerSecond * (t - options.leadInSeconds)) : 0
            }
            if let a0 = options.altitude, t >= nextAltitudeAt {
                nextAltitudeAt = t + 1
                altitude = a0 + options.altitudeTrendPerSecond * t + (phone.y - standingPhone.y) + rng.symmetric(options.altitudeNoise)
            }

            out.append(HandheldSquatSample(
                t: t,
                phonePos: SIMD3<Float>(phoneWorld),
                phonePitchDeg: pitch + rng.symmetric(0.4),
                phoneRollDeg: rng.symmetric(0.5),
                faceTracked: true,
                facePos: SIMD3<Float>(faceWorld),
                faceInPhone: SIMD3<Float>(faceInPhone),
                shapeEnergy: energy,
                worldTrackingNormal: options.world,
                altitude: altitude,
                userAccelRMS: rms,
                verticalAccel: vertical,
                steps: steps))
        }
        return out
    }

    /// Duraciones variadas (una persona no es un metrónomo).
    static let downVariation = [1.1, 1.3, 1.0, 1.4, 1.2, 1.05, 1.35, 1.15, 1.25, 1.0, 1.3, 1.2]
    static let upVariation = [1.0, 1.2, 1.1, 1.3, 0.95, 1.15, 1.25, 1.05, 1.2, 1.1, 1.0, 1.3]
    static let restVariation = [0.8, 1.1, 0.9, 1.3, 0.7, 1.0, 1.2, 0.85, 1.05, 0.95, 1.15, 0.75]
    static let depthVariation = [0.22, 0.24, 0.21, 0.25, 0.23, 0.22, 0.26, 0.21, 0.24, 0.23, 0.22, 0.25]

    /// `count` sentadillas reales variadas; la rep `holdAtRep` (1-based) se queda abajo 2,2 s.
    static func squatReps(count: Int, holdAtRep: Int? = nil, style: Style = .squat) -> [Rep] {
        (0..<max(0, count)).map { i in
            let k = i % downVariation.count
            return Rep(depth: depthVariation[k], downSeconds: downVariation[k],
                       holdSeconds: (i + 1) == holdAtRep ? 2.2 : 0.25,
                       upSeconds: upVariation[k], restSeconds: restVariation[k], style: style)
        }
    }

    /// Serie completa para el replay del simulador: la meta con el desafío respetado.
    static func replay(target: Int, challengeRep: Int, seed: UInt64 = 11) -> [HandheldSquatSample] {
        var options = Options()
        options.seed = seed
        return samples(reps: squatReps(count: target, holdAtRep: challengeRep), options: options)
    }
}
