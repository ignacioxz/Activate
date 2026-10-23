import Foundation

// Dueño: agente "sit-to-stand". Máquina de estados pura para "Pararse y sentarse" (A4).
//
// Postura de la prueba clínica 30-second chair stand (Jones, Rikli y Beam 1999): sentado en una silla,
// se para del todo y vuelve a sentarse sin usar las manos. Aquí las manos sostienen el teléfono frente
// al pecho, mirando la pantalla: la cámara frontal TrueDepth ve la cara y el world tracking (cámara
// trasera + IMU) da la pose 6DOF del teléfono. Sin imports de ARKit/CoreMotion: consume `SitStandSample`,
// que la integración arma desde la ARSession de las sentadillas en mano
// (`ARFaceTrackingConfiguration` + `isWorldTrackingEnabled`, `worldAlignment = .gravity` → Y hacia arriba)
// más `CMAltimeter` y `CMPedometer`.
//
// Capas contra el engaño (cada una por sí sola no basta; juntas sí):
// 1. Subida real: en un mismo cuadro el teléfono sube ≥ 18 cm y la CARA ≥ 20 cm sobre la referencia
//    "sentado" (los brazos no levantan la cara), y después vuelve a < 8 cm con una fase final sentada y
//    quieta; 1,2-15 s por rep.
// 2. Anti-brazos: el teléfono no sube más que la cara (+10 cm, con signo: brazos cansados que bajan el
//    teléfono no son trampa) y la cara no se mueve respecto de él (±10 cm).
// 3. Cuerpo que se traslada: pararse adelanta la cara ≥ 10 cm (sobre los pies); un montaje rígido o un
//    ascensor no. Inclinarse sin pararse no cuenta (el teléfono baja > 12 cm o la cara se desplaza más
//    en horizontal que en vertical); enderezarse desde una postura encorvada tampoco (al llegar arriba
//    la cara no puede quedar atrás ni el teléfono girado > 30°).
// 4. Persona viva: cara rastreada con micro-expresiones (`shapeEnergy`) en ≥ 20 % de los cuadros de la
//    rep; < 10 % en una ventana de 2 s → `static` (foto, pantalla, aunque tenga ruido suelto). Cara con
//    relieve 3D en el mapa de profundidad TrueDepth: una foto o un vídeo en otra pantalla son planos
//    (`flatFace`), aunque el montaje se adelante para simular el traslado.
// 5. Desafío por semilla: en una rep aleatoria, "Quédese de pie / sentado 2 segundos".
// 6. Sacudidas (> 3 m/s, sin contar saltos de tracking de un cuadro), ritmo perfecto (vídeo en bucle),
//    pasos (≥ 2,5 por rep contada → hard: escalón), escalera o ascensor.
//
// Tolerancias para el operador real (dolor lumbar, silla alta, poca luz): silla alta (la cadera sube 22 cm)
// o quedar arriba con 15° de tronco, brazos cansados que bajan el teléfono, inclinación de hasta 60° al
// despegar, reps de hasta 15 s sin apurarlo, la rep cierra con la cara de vuelta sobre la silla y la
// referencia "sentado" solo se adapta con el tronco derecho, re-anclaje si ARKit retoma con el origen
// corrido, calibración y quietud que toleran cuadros sueltos sin cara o sin tracking.

// MARK: - Muestra de dominio

/// Lectura combinada ARKit (cara + mundo) + barómetro + podómetro, ya traducida a tipos puros.
nonisolated struct SitStandSample: Sendable, Codable, Hashable {
    /// Segundos desde el inicio de la actividad.
    var t: Double
    /// Posición del teléfono en el mundo (m; `worldAlignment = .gravity` → Y hacia arriba).
    var phonePos: SIMD3<Float>
    /// Actitud del teléfono respecto de la gravedad (grados). Solo se usan diferencias contra la calibración.
    var phonePitchDeg: Double
    var phoneRollDeg: Double
    /// La cámara frontal rastrea una cara en este cuadro.
    var faceTracked: Bool
    /// Posición de la cara en el mundo (m). Sin sentido si `faceTracked == false`.
    var facePos: SIMD3<Float>
    /// Cara expresada en el espacio del teléfono (m).
    var faceInPhone: SIMD3<Float>
    /// Suma de |Δ| de 8 blendShapes respecto de la muestra anterior (≈ 0 = imagen estática).
    var shapeEnergy: Float
    /// `ARCamera.trackingState == .normal`.
    var worldTrackingNormal: Bool
    /// Altura relativa del barómetro (m) desde el inicio, si hay.
    var altitude: Double? = nil
    /// Pasos acumulados del podómetro desde el inicio, si hay.
    var steps: Int? = nil
    /// Relieve 3D de la cara en el mapa de profundidad TrueDepth (m): una cara real ≈ 1 cm, una foto o una
    /// pantalla ≈ 0. nil si este cuadro no trae profundidad (≈ 7-15 Hz; con sol directo, nunca). Es el mismo
    /// `faceRelief` que mide la fuente de la sentadilla en las manos (`FaceReliefEstimator`).
    var faceRelief: Float? = nil
}

extension SitStandSample: TimedSample {}

// MARK: - Copy (usted, frases cortas)

nonisolated enum SitStandCopy {
    // Consignas (van en `progress.hint`).
    static let calibrate = "Siéntese con el teléfono frente al pecho"
    static let stand = "Párese"
    static let sit = "Siéntese"
    static let standThenHold = "Párese y quédese de pie 2 segundos"
    static let holdStand = "Quédese de pie 2 segundos"
    static let sitThenHold = "Siéntese y quédese sentado 2 segundos"
    static let holdSit = "Quédese sentado 2 segundos"
    static let done = "Listo"
    // Gates bloqueados.
    static let faceLost = "Mantenga la cara en la pantalla"
    static let trackingLimited = "Mueva el teléfono más despacio"
    // Avisos (van en `Cue`).
    static let calibrated = "Lo tengo. Párese sin usar las manos"
    static let reseated = "Ahora sí. Párese sin usar las manos"
    static let armsOnly = "Párese con las piernas, no suba solo el teléfono"
    static let noTravel = "Párese con el cuerpo, avanzando sobre los pies"
    static let torsoOnly = "Párese del todo, no solo incline el cuerpo"
    static let partial = "Suba hasta quedar de pie"
    static let tooFast = "Más lento"
    /// Solo al rechazar una rep de > 15 s. Nunca apura: con dolor lumbar el ritmo lo pone la persona.
    static let tooSlow = "Sin pausas largas, a su ritmo"
    static let notSeated = "Siéntese del todo antes de volver a pararse"
    static let sitUpright = "Siéntese derecho, con el teléfono frente al pecho"
    static let phoneTilted = "Mantenga el teléfono frente al pecho"
    static let holdOK = "Bien"
    static let holdFailed = "Le faltó aguantar. Probemos de nuevo"
    static let holdGiveUp = "Sigamos"
    static let notLive = "Necesito ver su cara en vivo"
    static let shaking = "No sacuda el teléfono"
    static let walking = "Quédese frente a la silla"

    /// Símbolo SF para una consigna (la vista lo pinta junto al texto grande).
    static func symbol(for hint: String) -> String {
        switch hint {
        case stand: "arrow.up"
        case sit: "arrow.down"
        case standThenHold, holdStand: "figure.stand"
        case sitThenHold, holdSit, calibrate: "chair.fill"
        case done: "checkmark.circle.fill"
        case faceLost: "face.dashed"
        case trackingLimited: "tortoise"
        default: "arrow.up.and.down"
        }
    }
}

/// Nombres de anomalía que produce este verificador.
nonisolated enum SitStandAnomaly {
    static let armsOnly = "armsOnly"
    static let torsoOnly = "torsoOnly"
    static let staticFace = "static"
    static let holdChallengeFailed = "holdChallengeFailed"
    static let shaking = "shaking"
    static let walking = "walking"
    static let tooRegular = RegularityDetector.anomalyKind
    static let altitudeDrift = "altitudeDrift"
    static let flatFace = "flatFace"
}

// MARK: - Verificador

/// Rep = pararse del todo y volver a sentarse, verificada con la pose del teléfono y la cara.
/// `kind` llega por init: la integración y los tests usan `.pararseSentarse`.
nonisolated struct SitToStandVerifier: ActivityVerifier {
    typealias Sample = SitStandSample

    // MARK: Constantes (valores iniciales; se calibran en el iPhone)

    // Calibración "sentado".
    static let calibrationSeconds: Double = 1.0
    static let minCalibrationSamples = 10
    /// El teléfono no puede moverse más que esto durante la ventana de calibración (m).
    static let calibrationMaxDrift: Double = 0.05
    /// Distancia cara-teléfono plausible con el teléfono frente al pecho (m).
    static let faceDistanceRange: ClosedRange<Double> = 0.15...1.0
    /// El teléfono debe quedar delante de la cara en horizontal (m): define "hacia adelante".
    static let minForwardOffset: Double = 0.06

    // Repetición.
    /// Subida mínima del teléfono sobre la referencia sentado (m). Sensible: silla alta de casino (la cadera
    /// sube 22 cm), o persona de 1,62 m que arriba queda con 10-15° de tronco (el teléfono, 30 cm delante del
    /// pecho, sube 21-24 cm aunque la cara suba 25-27). Lo que separa pararse de los brazos es `minFaceRise`.
    static let standRise: Double = 0.18
    /// Subida mínima de la CARA en el mismo cuadro (m): los brazos suben el teléfono, no la cara. Levantarse
    /// 18 cm y completar con los brazos no llega; la silla alta honesta de 22 cm sí (la cara sube con la cadera).
    static let minFaceRise: Double = 0.20
    /// Desplazamiento horizontal mínimo de la cara durante la rep (m): pararse lleva la cadera sobre los pies
    /// (honesto ≥ 0,2 m en todos los estilos medidos). Un montaje rígido o un ascensor no se trasladan.
    static let minFaceTravel: Double = 0.10
    /// Banda "sentado" alrededor de la referencia (m).
    static let seatedBand: Double = 0.08
    static let minRepSeconds: Double = 1.2
    /// Tolerante a repeticiones lentas de alguien con dolor (juntar fuerza inclinado, subir en 4 s, bajar en 5 s).
    static let maxRepSeconds: Double = 15
    /// Fase final sentada con velocidad vertical baja (la técnica de la prueba de 30 s se para a los 0,4 s),
    /// con la cara de vuelta sobre la silla (no > `torsoMinHorizontal` adelante: la cadera todavía se desliza
    /// hacia atrás). Si se sentó más adelante en la silla, basta quedarse quieto y derecho `seatSettleSeconds`.
    static let seatedStillSeconds: Double = 0.2
    static let seatSettleSeconds: Double = 1.5
    /// Sentado y quieto el teléfono se mueve < 1 cm/s; una bajada lenta con dolor va a ~0,1 m/s y no debe
    /// confundirse con "ya se sentó" (contaría a medio camino y rompería el desafío sentado).
    static let stillVerticalSpeed: Double = 0.06
    static let velocityLookbackSeconds: Double = 0.15
    static let heightHistorySeconds: Double = 0.5
    /// EMA de alturas a ~60 Hz (constante de tiempo ≈ 40 ms).
    static let heightSmoothingAlpha: Double = 0.35
    /// Tras cada rep contada, la referencia sentado se acerca a la postura actual (deriva de ARKit, cojín),
    /// solo si quedó derecho (cabeceo y cara como sentado): a media bajada inclinada la referencia derivaría.
    static let referenceAdaptation: Double = 0.5
    /// Quieto fuera de la banda tras pararse (encorvado o con el teléfono alto): se orienta con un aviso.
    static let stuckCueSeconds: Double = 1.0
    /// Hueco sin pose confiable que reinicia suavizado e historiales (s).
    static let poseGapResetSeconds: Double = 0.25

    // Anti-brazos.
    /// Cuánto más que la cara puede subir el teléfono (m, con signo).
    static let armsMaxRiseGap: Double = 0.10
    /// La cara se movió respecto del teléfono (m)…
    static let armsMaxFaceInPhoneShift: Double = 0.10
    /// …y el teléfono no quedó por debajo de la cara más que esto (m): brazos cansados que dejan caer el
    /// teléfono 10 cm mueven la cara en su espacio, pero el teléfono sube MENOS y eso no es trampa.
    static let armsDriftMinGap: Double = -0.02
    /// La comparación se hace en la parte alta del movimiento (fracción de `standRise`), no en la inclinación.
    static let armsCheckFraction: Double = 0.5
    static let armsHardCount = 3

    // Inclinación y tronco.
    /// Cabeceo/alabeo máximo del teléfono durante la rep (pararse exige inclinar el tronco; con dolor lumbar
    /// se usa más impulso y el teléfono acompaña: 50° de tronco con muñecas rígidas da ~46°).
    static let maxTiltDeltaDeg: Double = 60
    /// Arriba el tronco vuelve a estar derecho: el teléfono no puede seguir girado más que esto.
    static let maxPeakPitchDeltaDeg: Double = 30
    /// Arriba la cara no puede quedar más atrás que esto respecto de donde estaba sentada (m).
    static let maxBackShift: Double = 0.10
    static let torsoMaxDrop: Double = 0.12
    static let torsoHorizontalRatio: Double = 0.8
    static let torsoMinHorizontal: Double = 0.12

    // Re-sentarse: calibró de pie y después se sentó, o ARKit retomó con el origen corrido (poca luz).
    // Quieto 2 s fuera de la banda, derecho, con la cara sobre la silla y a la misma distancia del teléfono.
    static let reseatSeconds: Double = 2
    static let reseatMaxPitchDeltaDeg: Double = 15
    static let reseatMaxForward: Double = 0.05
    /// La cara en el espacio del teléfono no cambió (m): bajar o subir el teléfono con los brazos no re-ancla.
    static let reseatMaxFaceInPhoneShift: Double = 0.05
    /// Si ARKit corrió el origen también en horizontal, la cara parece adelantada y nunca "vuelve sobre la
    /// silla": tras este tiempo quieto, derecho, con la cara a la misma distancia del teléfono y sin estar a
    /// altura de pie, se re-ancla igual (después de un bloqueo; o tras pararse, cerrando el intento SIN
    /// contarlo) para no quedar trabado diciendo "Siéntese" a alguien sentado.
    static let reseatShiftedSeconds: Double = 2.5

    // Persona viva y gates.
    static let faceLostSeconds: Double = 1.5
    /// Hueco de cara que no reinicia la ventana de calibración (casco, lentes, poca luz: cuadros sueltos).
    static let calibrationFaceGapSeconds: Double = 0.3
    /// Ventana de vida: con cara rastreada, < 10 % de cuadros vivos en 2 s → `static` (una foto con un cuadro
    /// de ruido cada tanto ya no reinicia la cuenta); vuelve a vigilar cuando hay > 50 % vivos.
    static let staticSeconds: Double = 2
    static let staticMaxLiveFraction: Double = 0.10
    static let staticRecoverLiveFraction: Double = 0.5
    /// Cuadros con cara mínimos en la ventana para juzgar (30 Hz × 1 s).
    static let staticMinSamples = 30
    /// Una rep exige cara viva en ≥ 20 % de los cuadros con cara del intento.
    static let minLiveFraction: Double = 0.20
    static let staticEnergyThreshold: Float = FaceLivenessMonitor.staticEnergyThreshold
    /// Relieve 3D (TrueDepth): mediana de las lecturas de los últimos 3 s bajo esto (m) = plano. Ruido del
    /// sensor sobre una pantalla o una foto ≈ 1-3 mm; una cara real ≈ 1 cm (mismos valores que la sentadilla).
    static let flatFaceMaxRelief: Double = 0.004
    static let reliefWindowSeconds: Double = 3
    static let reliefMinReadings = 8
    /// La rep no cuenta si ≥ 30 % de sus cuadros con cara vieron una cara plana; desde la 3.ª, `flatFace` hard.
    static let flatFaceRepFraction: Double = 0.3
    static let flatFaceHardCount = 3
    static let trackingLimitedSeconds: Double = 0.5

    // Desafío.
    /// Se pide "2 segundos" y se acepta desde 1,5 s.
    static let holdSeconds: Double = 1.5
    /// "De pie" durante el desafío = subida ≥ esta fracción de `standRise`.
    static let holdStandFraction: Double = 0.8
    static let holdFailHardCount = 2
    /// Segundos extra permitidos en la rep del desafío.
    static let challengeExtraSeconds: Double = 3

    // Apoyo físico.
    static let walkingSteps = 6
    /// Pasos desde el inicio de la primera rep contada: ≥ max(8, 2,5 × reps) → `walking` hard (subir y bajar
    /// un escalón de pie). Un paso espurio por rep (el podómetro cuenta el impulso) o reacomodar los pies no
    /// llega; caminar hasta otra silla antes de empezar no cuenta (es antes de la primera rep).
    static let walkingHardMinSteps = 8
    static let walkingHardStepsPerRep: Double = 2.5
    /// Velocidad del teléfono no humana para este ejercicio (m/s).
    static let shakeSpeed: Double = 3
    static let shakeMinDt: Double = 0.025
    static let shakeMaxGap: Double = 0.25
    /// Picos sobre `shakeSpeed` dentro de la ventana para declarar sacudida. La posición pasa antes por una
    /// mediana de 3 cuadros: un salto de tracking de un cuadro (ida y vuelta) no genera picos.
    static let shakeMinPeaks = 4
    static let shakeMedianFrames = 3
    static let shakeWindowSeconds: Double = 2
    static let rawHistorySeconds: Double = 0.3
    /// Tendencia barométrica que delata escalera o ascensor (señal de apoyo, no bloqueante).
    static let altitudeDriftMeters: Double = 1.5
    /// Ritmo "perfecto" (vídeo en bucle, mecanismo): CV de intervalos bajo esto con ≥ 6 reps.
    /// Más estricto que el 0,04 general: una persona se para y se sienta con un ritmo muy parejo
    /// (CV ≈ 0,03-0,10; con 5 intervalos el CV muestral cae bajo 0,02 una de cada cinco veces) y sin
    /// metrónomo no baja del 1 %. Un bucle da CV ≈ 0,003 y el desafío aleatorio ya derrota a casi todos.
    static let regularityMaxCV: Double = 0.01
    static let regularityMinReps = RegularityDetector.defaultMinReps

    // MARK: Tipos

    nonisolated enum Phase: String, Sendable, Hashable, Codable {
        /// Esperando 1 s sentado y quieto con la cara visible.
        case calibrating
        /// Tras un bloqueo: hay que volver a sentarse antes de contar.
        case awaitingSeat
        case seated
        /// Fuera de la banda sentado (inclinándose, de pie o volviendo).
        case excursion
        case done
    }

    /// Por qué un intento no contó (diagnóstico y tests).
    nonisolated enum Rejection: String, Sendable, Hashable, Codable, CaseIterable {
        case tooFast, tooSlow, armsOnly, noTravel, torsoOnly, partial, phoneTilted, faceNotSeen, notLive, flatFace, holdChallengeFailed, interrupted
    }

    nonisolated struct RejectionRecord: Sendable, Hashable, Codable {
        var reason: Rejection
        var at: Double
    }

    /// Desafío de una rep elegida por semilla.
    nonisolated struct HoldChallenge: Sendable, Hashable, Codable {
        nonisolated enum Kind: String, Sendable, Hashable, Codable, CaseIterable { case stand, sit }
        var kind: Kind
        /// Rep (1-based) en la que se pide.
        var repIndex: Int
    }

    /// Postura "sentado" de referencia.
    nonisolated struct Reference: Sendable, Hashable {
        var phoneY: Double
        var faceY: Double
        var faceXZ: SIMD2<Double>
        var faceInPhone: SIMD3<Double>
        var pitch: Double
        var roll: Double
        /// Horizontal unitaria de la cara al teléfono ("hacia adelante" de la persona).
        var forward: SIMD2<Double>?
    }

    /// Un intento: desde que deja la banda sentado hasta que vuelve sentado y quieto.
    nonisolated struct Excursion: Sendable, Hashable {
        var startT: Double
        /// Dónde estaba la cara sentada antes del intento (horizontal).
        var anchorFaceXZ: SIMD2<Double>
        var minRise: Double = .infinity
        var maxRise: Double = -.infinity
        var peakPitchDelta: Double = 0
        var peakFaceForward: Double? = nil
        var maxPitchDelta: Double = 0
        var maxRollDelta: Double = 0
        var maxFaceShift: Double = 0
        var maxFaceLift: Double = 0
        /// Mayor subida de la cara (con signo) sobre la referencia.
        var maxFaceRise: Double = -.infinity
        /// Mayor (subida del teléfono − subida de la cara), con signo.
        var maxRiseGap: Double = -.infinity
        var maxFaceInPhoneShift: Double = 0
        var upperFaceSamples = 0
        var faceSamples = 0
        var liveSamples = 0
        /// Cuadros con cara mientras el relieve TrueDepth la veía plana.
        var flatSamples = 0
        /// Pasos acumulados al empezar el intento.
        var stepsAtStart: Int? = nil
        var armsFlag = false
        var armsReported = false
        var stood = false
        var stoodAt: Double? = nil
        var challenge: HoldChallenge.Kind? = nil
        var holdDone = false
        var holdFailed = false
        var touchedBand = false
        var restoodCued = false
        var stillSince: Double? = nil
        var seatConfirmedAt: Double? = nil
        var stuckSince: Double? = nil
        var stuckCued = false

        init(startT: Double, anchorFaceXZ: SIMD2<Double>, stepsAtStart: Int? = nil) {
            self.startT = startT
            self.anchorFaceXZ = anchorFaceXZ
            self.stepsAtStart = stepsAtStart
        }
    }

    private nonisolated struct FaceReading: Sendable {
        var y: Double
        var xz: SIMD2<Double>
        var inPhone: SIMD3<Double>
    }

    private nonisolated struct Reading: Sendable {
        var phone: SIMD3<Double>
        /// Altura suavizada del teléfono.
        var phoneY: Double
        var vy: Double?
        var face: FaceReading?
        var pitch: Double
        var roll: Double
        var live: Bool

        var phoneXZ: SIMD2<Double> { SIMD2(phone.x, phone.z) }
        var isStill: Bool { vy.map { abs($0) < SitToStandVerifier.stillVerticalSpeed } ?? false }
    }

    private nonisolated struct TimedValue: Sendable, Hashable {
        var t: Double
        var v: Double
    }

    private nonisolated struct TimedPoint: Sendable, Hashable {
        var t: Double
        var p: SIMD3<Double>
    }

    private nonisolated struct TimedFlag: Sendable, Hashable {
        var t: Double
        var on: Bool
    }

    private nonisolated struct CalibrationWindow: Sendable {
        var start: Double? = nil
        var anchor = SIMD3<Double>.zero
        var firstPitch = 0.0
        var firstRoll = 0.0
        var n = 0
        var phoneY = 0.0
        var faceY = 0.0
        var faceXZ = SIMD2<Double>.zero
        var faceInPhone = SIMD3<Double>.zero
        var offset = SIMD2<Double>.zero
        var pitchDelta = 0.0
        var rollDelta = 0.0

        mutating func add(_ r: Reading, _ face: FaceReading, offset o: SIMD2<Double>) {
            n += 1
            phoneY += r.phoneY
            faceY += face.y
            faceXZ += face.xz
            faceInPhone += face.inPhone
            offset += o
            pitchDelta += AngleMath.delta(r.pitch, firstPitch)
            rollDelta += AngleMath.delta(r.roll, firstRoll)
        }

        var reference: Reference? {
            guard n > 0 else { return nil }
            let d = Double(n)
            let meanOffset = offset / d
            let length = SitToStandVerifier.norm(meanOffset)
            return Reference(phoneY: phoneY / d, faceY: faceY / d, faceXZ: faceXZ / d, faceInPhone: faceInPhone / d,
                             pitch: AngleMath.wrap180(firstPitch + pitchDelta / d),
                             roll: AngleMath.wrap180(firstRoll + rollDelta / d),
                             forward: length > 0 ? meanOffset / length : nil)
        }
    }

    // MARK: Estado

    let kind: ActivityKind
    let spec: VerificationSpec
    let seed: UInt64
    let challenge: HoldChallenge
    private(set) var progress: VerifierProgress
    private(set) var phase: Phase = .calibrating
    private(set) var reference: Reference? = nil
    private(set) var excursion: Excursion? = nil
    private(set) var anomalies: [Anomaly] = []
    private(set) var rejections: [RejectionRecord] = []
    /// Duración de cada rep contada (s).
    private(set) var repSeconds: [Double] = []
    /// Mayor subida del teléfono en una rep contada (m).
    private(set) var maxCountedRise: Double? = nil
    private(set) var challengeFailures = 0
    private(set) var challengePassed = false
    private(set) var challengeRetired = false
    private(set) var armsCount = 0
    private(set) var flatFaceCount = 0
    /// El relieve TrueDepth de los últimos segundos es el de una superficie plana (foto, pantalla).
    private(set) var faceLooksFlat = false
    /// Veces que se re-ancló la referencia tras pararse (ARKit retomó con el origen corrido).
    private(set) var reanchorCount = 0
    /// Velocidad máxima del teléfono observada (m/s), para diagnóstico.
    private(set) var peakPhoneSpeed: Double = 0
    /// Rango barométrico observado (m), señal de apoyo.
    private(set) var altitudeRange: ClosedRange<Double>? = nil

    private var started = false
    private var t0: Double = 0
    private var window = CalibrationWindow()
    private var phoneSmoother = ExponentialSmoother(alpha: SitToStandVerifier.heightSmoothingAlpha)
    private var faceSmoother = ExponentialSmoother(alpha: SitToStandVerifier.heightSmoothingAlpha)
    private var lastPoseAt: Double? = nil
    private var lastFaceReadAt: Double? = nil
    private var heightHistory: [TimedValue] = []
    private var rawHistory: [TimedPoint] = []
    private var aboveShake = false
    private var shakePeaks: [Double] = []
    private var shakingReported = false
    private var lastFaceAt: Double = 0
    private var sawFace = false
    /// Cuadros con cara de los últimos `staticSeconds` (vivo o no) y desde cuándo la ventana está llena.
    private var liveWindow: [TimedFlag] = []
    private var liveWindowLive = 0
    private var liveWindowSince: Double? = nil
    private var staticReported = false
    private var reliefReadings: [TimedValue] = []
    /// Últimas posiciones crudas del teléfono para la mediana anti-glitch.
    private var rawRecent: [TimedPoint] = []
    private var limitedSince: Double? = nil
    private var seatStillSince: Double? = nil
    private var lowStillSince: Double? = nil
    private var restFaceXZ: SIMD2<Double>? = nil
    private var stepsBase: Int? = nil
    private var lastSteps: Int? = nil
    private var stepsAtFirstRep: Int? = nil
    private var walkingReported = false
    private var walkingHardReported = false
    private var altitudeBase: Double? = nil
    private var altitudeReported = false
    private var regularity = RegularityDetector(minReps: SitToStandVerifier.regularityMinReps,
                                                maxCoefficientOfVariation: SitToStandVerifier.regularityMaxCV)

    init(spec: VerificationSpec, kind: ActivityKind, seed: UInt64) {
        self.spec = spec
        self.kind = kind
        self.seed = seed
        var rng = FaceChallengeRNG(seed: seed)
        challenge = Self.makeChallenge(target: spec.target, using: &rng)
        progress = VerifierProgress(target: spec.target, gate: .calibrating, hint: SitStandCopy.calibrate)
    }

    /// Tipo y rep del desafío. Nunca en la primera rep (la persona todavía se acomoda).
    static func makeChallenge(target: Int, using rng: inout FaceChallengeRNG) -> HoldChallenge {
        let kind: HoldChallenge.Kind = Bool.random(using: &rng) ? .stand : .sit
        let lower = target >= 2 ? 2 : 1
        let upper = max(lower, target)
        return HoldChallenge(kind: kind, repIndex: Int.random(in: lower...upper, using: &rng))
    }

    var count: Int { progress.count }

    /// Desafío vigente para el próximo intento (nil si ya pasó, se retiró o no toca).
    var activeChallenge: HoldChallenge? {
        guard !challengePassed, !challengeRetired, progress.count + 1 == challenge.repIndex else { return nil }
        return challenge
    }

    // MARK: ActivityVerifier

    mutating func start(at t: Double) {
        self = SitToStandVerifier(spec: spec, kind: kind, seed: seed)
        started = true
        t0 = t
        lastFaceAt = t
    }

    mutating func ingest(_ s: SitStandSample, at t: Double) -> [VerifierEvent] {
        if !started { start(at: t) }
        var events: [VerifierEvent] = []
        progress.elapsed = max(0, t - t0)
        guard phase != .done else { return events }
        defer { progress.hint = currentHint() }

        observeSupport(s, at: t, &events)
        observeFace(s, at: t, &events)
        trackRelief(s, at: t)
        limitedSince = s.worldTrackingNormal ? nil : (limitedSince ?? t)
        let blocked = updateGate(at: t, &events)

        // Sin tracking normal la pose no es confiable: ese tramo no se mide ni se cuenta.
        guard s.worldTrackingNormal else { return events }
        let reading = read(s, at: t)
        detectShake(reading.phone, at: t, &events)
        guard !blocked else { return events }

        switch phase {
        case .calibrating: calibrate(reading, at: t, &events)
        case .awaitingSeat: awaitSeat(reading, at: t, &events)
        case .seated: watchSeated(reading, at: t, &events)
        case .excursion: track(reading, at: t, &events)
        case .done: break
        }
        return events
    }

    mutating func finish(at t: Double, reason: FinishReason) -> ActivityOutcome {
        progress.elapsed = max(0, t - t0)
        var ignored: [VerifierEvent] = []
        checkStepsPerRep(at: t, &ignored)
        let mean = repSeconds.isEmpty ? nil : repSeconds.reduce(0, +) / Double(repSeconds.count)
        return ActivityOutcome(
            kind: kind,
            target: spec.target,
            achieved: progress.count,
            completed: progress.count >= spec.target,
            durationSeconds: max(0, t - t0),
            metrics: .reps(count: progress.count, minDescentRatio: maxCountedRise, meanRepSeconds: mean),
            anomalies: anomalies,
            reason: reason)
    }

    // MARK: Lectura y señales de apoyo

    private mutating func read(_ s: SitStandSample, at t: Double) -> Reading {
        let phone = Self.double(s.phonePos)
        if let last = lastPoseAt, t - last > Self.poseGapResetSeconds {
            phoneSmoother.reset()
            heightHistory.removeAll()
            rawHistory.removeAll()
            rawRecent.removeAll()
            aboveShake = false
        }
        lastPoseAt = t
        let y = phoneSmoother.update(phone.y)
        heightHistory.append(TimedValue(t: t, v: y))
        while let first = heightHistory.first, first.t < t - Self.heightHistorySeconds {
            heightHistory.removeFirst()
        }
        var vy: Double? = nil
        if let past = heightHistory.last(where: { $0.t <= t - Self.velocityLookbackSeconds }), t > past.t {
            vy = (y - past.v) / (t - past.t)
        }

        var face: FaceReading? = nil
        if s.faceTracked {
            if let last = lastFaceReadAt, t - last > Self.poseGapResetSeconds { faceSmoother.reset() }
            lastFaceReadAt = t
            let f = Self.double(s.facePos)
            face = FaceReading(y: faceSmoother.update(f.y), xz: SIMD2(f.x, f.z), inPhone: Self.double(s.faceInPhone))
        }
        return Reading(phone: phone, phoneY: y, vy: vy, face: face,
                       pitch: s.phonePitchDeg, roll: s.phoneRollDeg,
                       live: s.faceTracked && s.shapeEnergy >= Self.staticEnergyThreshold)
    }

    /// Podómetro (caminar) y barómetro (escalera / ascensor): señales de apoyo, nunca bloquean.
    private mutating func observeSupport(_ s: SitStandSample, at t: Double, _ events: inout [VerifierEvent]) {
        if let steps = s.steps {
            let base = stepsBase ?? steps
            stepsBase = base
            lastSteps = steps
            if !walkingReported, steps - base >= Self.walkingSteps {
                walkingReported = true
                record(Anomaly(kind: SitStandAnomaly.walking, severity: .soft, at: t - t0,
                               detail: "\(steps - base) pasos durante la serie"), &events)
                events.append(.cue(Cue(text: SitStandCopy.walking, symbol: "figure.walk")))
            }
        }
        if let altitude = s.altitude {
            let base = altitudeBase ?? altitude
            altitudeBase = base
            altitudeRange = altitudeRange.map { min($0.lowerBound, altitude)...max($0.upperBound, altitude) } ?? altitude...altitude
            if !altitudeReported, abs(altitude - base) > Self.altitudeDriftMeters {
                altitudeReported = true
                record(Anomaly(kind: SitStandAnomaly.altitudeDrift, severity: .soft, at: t - t0,
                               detail: String(format: "Barómetro %+.1f m", altitude - base)), &events)
            }
        }
    }

    /// Cara visible (para el gate) y viva (micro-expresiones), medida por fracción en una ventana de 2 s:
    /// una foto con un cuadro de ruido cada tanto (luz, reflejo) ya no reinicia la cuenta.
    private mutating func observeFace(_ s: SitStandSample, at t: Double, _ events: inout [VerifierEvent]) {
        guard s.faceTracked else { return }
        lastFaceAt = t
        defer { sawFace = true }
        // La primera muestra trae energía 0 por construcción (no hay muestra anterior).
        guard sawFace else { return }
        while let first = liveWindow.first, first.t < t - Self.staticSeconds {
            if first.on { liveWindowLive -= 1 }
            liveWindow.removeFirst()
        }
        // Tras un hueco de cara de 2 s o más, la ventana vuelve a llenarse desde cero.
        if liveWindow.isEmpty { liveWindowSince = t }
        let live = s.shapeEnergy >= Self.staticEnergyThreshold
        liveWindow.append(TimedFlag(t: t, on: live))
        if live { liveWindowLive += 1 }
        guard let since = liveWindowSince, t - since >= Self.staticSeconds,
              liveWindow.count >= Self.staticMinSamples else { return }
        let fraction = Double(liveWindowLive) / Double(liveWindow.count)
        if fraction > Self.staticRecoverLiveFraction { staticReported = false }
        guard !staticReported, fraction < Self.staticMaxLiveFraction else { return }
        staticReported = true
        record(Anomaly(kind: SitStandAnomaly.staticFace, severity: .hard, at: t - t0,
                       detail: String(format: "Cara viva en %.0f %% de los cuadros de %.0f s",
                                      fraction * 100, Self.staticSeconds)), &events)
        events.append(.cue(Cue(text: SitStandCopy.notLive, symbol: "face.dashed")))
    }

    /// Relieve 3D: mediana de las lecturas TrueDepth de los últimos segundos (sin lecturas no decide).
    private mutating func trackRelief(_ s: SitStandSample, at t: Double) {
        var changed = false
        if s.faceTracked, let r = s.faceRelief, r.isFinite {
            reliefReadings.append(TimedValue(t: t, v: Double(r)))
            changed = true
        }
        while let first = reliefReadings.first, first.t < t - Self.reliefWindowSeconds {
            reliefReadings.removeFirst()
            changed = true
        }
        guard changed else { return }
        guard reliefReadings.count >= Self.reliefMinReadings else {
            faceLooksFlat = false
            return
        }
        let sorted = reliefReadings.map(\.v).sorted()
        faceLooksFlat = sorted[sorted.count / 2] < Self.flatFaceMaxRelief
    }

    /// Velocidad del teléfono por encima de lo humano, repetida → sacudida. La posición pasa por una mediana
    /// de 3 cuadros: un salto de tracking de un cuadro (ida y vuelta) desaparece; una sacudida real no.
    private mutating func detectShake(_ raw: SIMD3<Double>, at t: Double, _ events: inout [VerifierEvent]) {
        rawRecent.append(TimedPoint(t: t, p: raw))
        if rawRecent.count > Self.shakeMedianFrames { rawRecent.removeFirst() }
        let p = rawRecent.count < Self.shakeMedianFrames ? raw : Self.median3(rawRecent.map(\.p))
        defer {
            rawHistory.append(TimedPoint(t: t, p: p))
            while let first = rawHistory.first, first.t < t - Self.rawHistorySeconds { rawHistory.removeFirst() }
        }
        guard let past = rawHistory.last(where: { $0.t <= t - Self.shakeMinDt }),
              t > past.t, t - past.t <= Self.shakeMaxGap else {
            aboveShake = false
            return
        }
        let speed = Self.norm(p - past.p) / (t - past.t)
        peakPhoneSpeed = max(peakPhoneSpeed, speed)
        guard speed > Self.shakeSpeed else {
            aboveShake = false
            return
        }
        guard !aboveShake else { return }
        aboveShake = true
        shakePeaks.append(t)
        shakePeaks.removeAll { $0 < t - Self.shakeWindowSeconds }
        guard !shakingReported, shakePeaks.count >= Self.shakeMinPeaks else { return }
        shakingReported = true
        record(Anomaly(kind: SitStandAnomaly.shaking, severity: .hard, at: t - t0,
                       detail: String(format: "Teléfono a %.1f m/s", speed)), &events)
        events.append(.cue(Cue(text: SitStandCopy.shaking, symbol: "iphone.gen3.radiowaves.left.and.right")))
    }

    // MARK: Gate

    private static func isBlocked(_ gate: GateState) -> Bool {
        if case .blocked = gate { return true }
        return false
    }

    /// Tracking limitado sostenido > cara perdida > calibrando / listo. Devuelve si quedó bloqueado.
    private mutating func updateGate(at t: Double, _ events: inout [VerifierEvent]) -> Bool {
        let gate: GateState
        if let since = limitedSince, t - since >= Self.trackingLimitedSeconds {
            gate = .blocked(reason: SitStandCopy.trackingLimited)
        } else if t - lastFaceAt > Self.faceLostSeconds {
            gate = .blocked(reason: SitStandCopy.faceLost)
        } else {
            gate = reference == nil ? .calibrating : .ready
        }
        guard gate != progress.gate else { return Self.isBlocked(gate) }
        let wasBlocked = Self.isBlocked(progress.gate)
        progress.gate = gate
        events.append(.gate(gate))
        if Self.isBlocked(gate) {
            if !wasBlocked { interrupt(at: t) }
        } else if wasBlocked {
            phase = reference == nil ? .calibrating : .awaitingSeat
        }
        return Self.isBlocked(gate)
    }

    /// Se perdió la cara o el tracking: el intento en curso no cuenta y hay que volver a sentarse.
    private mutating func interrupt(at t: Double) {
        if phase == .excursion, excursion != nil { reject(.interrupted, at: t) }
        excursion = nil
        window = CalibrationWindow()
        seatStillSince = nil
        lowStillSince = nil
        phase = reference == nil ? .calibrating : .awaitingSeat
    }

    // MARK: Fases

    private mutating func calibrate(_ r: Reading, at t: Double, _ events: inout [VerifierEvent]) {
        guard let face = r.face else {
            // Cuadros sueltos sin cara (casco, lentes, poca luz) no reinician la ventana; un hueco largo sí.
            if lastFaceReadAt.map({ t - $0 > Self.calibrationFaceGapSeconds }) ?? true { window = CalibrationWindow() }
            return
        }
        let offset = r.phoneXZ - face.xz
        let still = r.vy.map { abs($0) < Self.stillVerticalSpeed } ?? true
        guard Self.faceDistanceRange.contains(Self.norm(face.inPhone)),
              Self.norm(offset) >= Self.minForwardOffset, still else {
            window = CalibrationWindow()
            return
        }
        if window.start == nil || Self.norm(r.phone - window.anchor) > Self.calibrationMaxDrift {
            window = CalibrationWindow(start: t, anchor: r.phone, firstPitch: r.pitch, firstRoll: r.roll)
        }
        window.add(r, face, offset: offset)
        guard let start = window.start, t - start >= Self.calibrationSeconds,
              window.n >= Self.minCalibrationSamples, let ref = window.reference else { return }
        reference = ref
        restFaceXZ = ref.faceXZ
        window = CalibrationWindow()
        phase = .seated
        progress.gate = .ready
        events.append(.gate(.ready))
        events.append(.cue(Cue(text: SitStandCopy.calibrated, symbol: "checkmark.circle.fill")))
    }

    private mutating func awaitSeat(_ r: Reading, at t: Double, _ events: inout [VerifierEvent]) {
        guard let ref = reference else { return }
        if reseatIfNeeded(r, at: t, afterBlock: true, &events) { return }
        let inBand = abs(r.phoneY - ref.phoneY) < Self.seatedBand
        // `vy` desconocido (hueco corto de tracking con poca luz) dentro de la banda no reinicia la quietud.
        if inBand, r.vy == nil { return }
        guard inBand, r.isStill else {
            seatStillSince = nil
            return
        }
        let since = seatStillSince ?? t
        seatStillSince = since
        guard t - since >= Self.seatedStillSeconds else { return }
        seatStillSince = nil
        enterSeated(r, upright: isUpright(r, anchor: restFaceXZ ?? ref.faceXZ))
    }

    /// Sentado. La posición de la cara "en reposo" solo se actualiza con el tronco derecho.
    private mutating func enterSeated(_ r: Reading, upright: Bool) {
        phase = .seated
        if upright, let face = r.face { restFaceXZ = face.xz }
    }

    /// Postura de sentado derecho: cabeceo como en la calibración y la cara no adelantada respecto de `anchor`.
    /// A media bajada, con el tronco todavía inclinado, no lo es.
    private func isUpright(_ r: Reading, anchor: SIMD2<Double>) -> Bool {
        guard let ref = reference, let face = r.face else { return false }
        let pitchDelta = abs(AngleMath.delta(r.pitch, ref.pitch))
        let ahead = ref.forward.map { Self.dot(face.xz - anchor, $0) } ?? 0
        return pitchDelta < Self.reseatMaxPitchDeltaDeg && ahead < Self.reseatMaxForward
    }

    /// Sentado: empieza un intento si el teléfono sale de la banda o la cara se va hacia adelante.
    private mutating func watchSeated(_ r: Reading, at t: Double, _ events: inout [VerifierEvent]) {
        guard let ref = reference else { return }
        let anchor = restFaceXZ ?? ref.faceXZ
        let rise = r.phoneY - ref.phoneY
        var leaning = false
        if let face = r.face {
            let shift = face.xz - anchor
            // Solo hacia adelante: enderezarse (cara hacia atrás) no es un intento.
            let ahead = ref.forward.map { Self.dot(shift, $0) } ?? Self.norm(shift)
            leaning = ahead > Self.torsoMinHorizontal
        }
        guard abs(rise) > Self.seatedBand || leaning else { return }
        excursion = Excursion(startT: t, anchorFaceXZ: anchor, stepsAtStart: lastSteps)
        phase = .excursion
        track(r, at: t, &events)
    }

    /// Un intento en curso: mide subida, cara, inclinación, desafío y la vuelta sentado.
    private mutating func track(_ r: Reading, at t: Double, _ events: inout [VerifierEvent]) {
        guard var ex = excursion, let ref = reference else { return }
        let rise = r.phoneY - ref.phoneY
        let pitchDelta = abs(AngleMath.delta(r.pitch, ref.pitch))
        let rollDelta = abs(AngleMath.delta(r.roll, ref.roll))
        ex.minRise = min(ex.minRise, rise)
        ex.maxPitchDelta = max(ex.maxPitchDelta, pitchDelta)
        ex.maxRollDelta = max(ex.maxRollDelta, rollDelta)
        if r.live { ex.liveSamples += 1 }

        var faceForward: Double? = nil
        var faceRise = -Double.infinity
        if let face = r.face {
            ex.faceSamples += 1
            if faceLooksFlat { ex.flatSamples += 1 }
            faceRise = face.y - ref.faceY
            let shift = face.xz - ex.anchorFaceXZ
            ex.maxFaceShift = max(ex.maxFaceShift, Self.norm(shift))
            ex.maxFaceLift = max(ex.maxFaceLift, abs(faceRise))
            ex.maxFaceRise = max(ex.maxFaceRise, faceRise)
            faceForward = ref.forward.map { Self.dot(shift, $0) }
            if rise >= Self.armsCheckFraction * Self.standRise {
                ex.upperFaceSamples += 1
                // Con signo: el ataque sube el teléfono MÁS que la cara; brazos cansados lo suben menos y
                // eso nunca infla una rep.
                let gap = rise - faceRise
                let drift = Self.norm(face.inPhone - ref.faceInPhone)
                ex.maxRiseGap = max(ex.maxRiseGap, gap)
                ex.maxFaceInPhoneShift = max(ex.maxFaceInPhoneShift, drift)
                if gap > Self.armsMaxRiseGap || (drift > Self.armsMaxFaceInPhoneShift && gap > Self.armsDriftMinGap) {
                    ex.armsFlag = true
                }
            }
        }
        if rise > ex.maxRise {
            ex.maxRise = rise
            ex.peakPitchDelta = pitchDelta
            if let faceForward { ex.peakFaceForward = faceForward }
        }

        // De pie: el teléfono y la cara arriba en el mismo cuadro (los brazos no suben la cara; tapar la
        // cámara arriba tampoco sirve).
        if !ex.stood, rise >= Self.standRise, faceRise >= Self.minFaceRise {
            ex.stood = true
            ex.stoodAt = t
            ex.challenge = activeChallenge?.kind
            switch ex.challenge {
            case .stand?: events.append(.cue(Cue(text: SitStandCopy.holdStand, symbol: "figure.stand")))
            case .sit?: events.append(.cue(Cue(text: SitStandCopy.sitThenHold, symbol: "chair.fill")))
            case nil: break
            }
        } else if ex.stood, ex.touchedBand, rise >= Self.standRise, !ex.restoodCued {
            ex.restoodCued = true
            events.append(.cue(Cue(text: SitStandCopy.notSeated, symbol: "chair.fill")))
        }
        // Teléfono arriba con la cara desfasada: brazos, aunque la cara nunca llegue arriba.
        if rise >= Self.standRise, ex.armsFlag, !ex.armsReported {
            ex.armsReported = true
            reportArms(gap: ex.maxRiseGap, drift: ex.maxFaceInPhoneShift, at: t, &events)
        }

        // Desafío de pie: quedarse arriba ≥ 1,5 s desde que llegó.
        if ex.stood, ex.challenge == .stand, !ex.holdDone, !ex.holdFailed, let stoodAt = ex.stoodAt {
            if rise >= Self.holdStandFraction * Self.standRise {
                if t - stoodAt >= Self.holdSeconds {
                    ex.holdDone = true
                    events.append(.cue(Cue(text: SitStandCopy.holdOK, symbol: "checkmark.circle.fill")))
                }
            } else {
                ex.holdFailed = true
                failChallenge(at: t, &events)
            }
        }

        let inBand = abs(rise) < Self.seatedBand
        if ex.stood, inBand { ex.touchedBand = true }

        // Desafío sentado en curso: debe quedarse en la banda 1,5 s.
        if let confirmedAt = ex.seatConfirmedAt {
            if !inBand {
                excursion = nil
                failChallenge(at: t, &events)
                reject(.holdChallengeFailed, at: t)
                // Ya se está levantando: empieza otro intento ahora mismo.
                excursion = Excursion(startT: t, anchorFaceXZ: ex.anchorFaceXZ, stepsAtStart: lastSteps)
                phase = .excursion
                return
            }
            if t - confirmedAt >= Self.holdSeconds {
                complete(ex, seatedAt: confirmedAt, r, at: t, &events)
            } else {
                excursion = ex
            }
            return
        }

        // Fase final sentado: en la banda, con velocidad vertical baja y la cara de vuelta sobre la silla.
        if inBand, r.isStill {
            let since = ex.stillSince ?? t
            ex.stillSince = since
            let faceBack = (faceForward ?? 0) <= Self.torsoMinHorizontal
            let settled = t - since >= Self.seatSettleSeconds
                && abs(AngleMath.delta(r.pitch, ref.pitch)) < Self.reseatMaxPitchDeltaDeg
            if (t - since >= Self.seatedStillSeconds && faceBack) || settled {
                if ex.stood, ex.challenge == .sit {
                    ex.seatConfirmedAt = since
                    excursion = ex
                    return
                }
                complete(ex, seatedAt: since, r, at: t, movedSeat: !faceBack, &events)
                return
            }
        } else if !(inBand && r.vy == nil) {
            // `vy` desconocido (hueco corto de tracking con poca luz) dentro de la banda no reinicia la quietud.
            ex.stillSince = nil
        }

        // Quieto fuera de la banda tras pararse: encorvado, con el teléfono alto, o ARKit retomó con el origen
        // corrido. Se orienta una vez y, si está sentado derecho como al calibrar (cabeceo, cara-teléfono y la
        // cara de vuelta sobre la silla), se re-ancla la referencia y se cierra la rep.
        if ex.stood, !inBand, r.isStill, rise < Self.holdStandFraction * Self.standRise {
            let since = ex.stuckSince ?? t
            ex.stuckSince = since
            let seatedLike = r.face.map { isSeatedLike(r, $0, anchor: ex.anchorFaceXZ) } ?? false
            // Si ya está sentado derecho (solo corrió el origen), no hay nada que corregir: se re-ancla a los 2 s.
            if !ex.stuckCued, !seatedLike, t - since >= Self.stuckCueSeconds {
                ex.stuckCued = true
                events.append(.cue(Cue(text: SitStandCopy.sitUpright, symbol: "chair.fill")))
            }
            if t - since >= Self.reseatSeconds, seatedLike, let face = r.face {
                reanchor(r, face)
                complete(ex, seatedAt: since, r, at: t, &events)
                return
            }
            // Origen corrido también en horizontal: no se puede confirmar que se sentó. Se re-ancla para no
            // quedar trabado, pero el intento no cuenta.
            if t - since >= Self.reseatShiftedSeconds, let face = r.face, isSeatedLike(r, face, anchor: nil) {
                reanchor(r, face, horizontal: true)
                excursion = nil
                phase = .seated
                reject(.interrupted, at: t)
                events.append(.cue(Cue(text: SitStandCopy.reseated, symbol: "checkmark.circle.fill")))
                return
            }
        } else {
            ex.stuckSince = nil
        }

        excursion = ex
        if !ex.stood { _ = reseatIfNeeded(r, at: t, &events) }
    }

    private func maxSeconds(_ ex: Excursion) -> Double {
        Self.maxRepSeconds + (ex.challenge == nil ? 0 : Self.challengeExtraSeconds)
    }

    /// Volvió sentado y quieto: decide si el intento cuenta.
    /// `movedSeat`: se sentó derecho pero más adelante en la silla; la cara de reposo pasa a ser la actual.
    private mutating func complete(_ ex: Excursion, seatedAt: Double, _ r: Reading, at t: Double,
                                   movedSeat: Bool = false, _ events: inout [VerifierEvent]) {
        excursion = nil
        let upright = isUpright(r, anchor: ex.anchorFaceXZ)
        enterSeated(r, upright: upright || movedSeat)
        guard ex.stood else {
            closeAttempt(ex, at: t, &events)
            return
        }
        let duration = seatedAt - ex.startT
        if let reason = rejection(for: ex, duration: duration) {
            reject(reason, at: t)
            switch reason {
            case .tooFast:
                events.append(.cue(Cue(text: SitStandCopy.tooFast, symbol: "tortoise")))
            case .tooSlow:
                events.append(.cue(Cue(text: SitStandCopy.tooSlow, symbol: "clock")))
            case .faceNotSeen:
                events.append(.cue(Cue(text: SitStandCopy.faceLost, symbol: "face.dashed")))
            case .notLive:
                events.append(.cue(Cue(text: SitStandCopy.notLive, symbol: "face.dashed")))
            case .flatFace:
                flatFaceCount += 1
                record(Anomaly(kind: SitStandAnomaly.flatFace, severity: flatFaceCount >= Self.flatFaceHardCount ? .hard : .soft,
                               at: t - t0, detail: "Cara sin relieve 3D: foto o pantalla"), &events)
                events.append(.cue(Cue(text: SitStandCopy.notLive, symbol: "face.dashed")))
            case .phoneTilted:
                events.append(.cue(Cue(text: SitStandCopy.phoneTilted, symbol: "iphone")))
            case .noTravel:
                events.append(.cue(Cue(text: SitStandCopy.noTravel, symbol: "figure.stand")))
            case .torsoOnly:
                record(Anomaly(kind: SitStandAnomaly.torsoOnly, severity: .soft, at: t - t0,
                               detail: "Se enderezó sin pararse"), &events)
                events.append(.cue(Cue(text: SitStandCopy.torsoOnly, symbol: "figure.stand")))
            case .armsOnly, .holdChallengeFailed, .partial, .interrupted:
                break // ya avisado en el momento
            }
            return
        }

        progress.count += 1
        if stepsAtFirstRep == nil { stepsAtFirstRep = ex.stepsAtStart ?? lastSteps }
        repSeconds.append(duration)
        maxCountedRise = max(maxCountedRise ?? ex.maxRise, ex.maxRise)
        if ex.challenge != nil { challengePassed = true }
        events.append(.rep(progress.count))
        events.append(.progress(progress.fraction))
        // El ritmo se mide al sentarse (no al contar): el desafío sentado retrasa el conteo, no el movimiento.
        if let anomaly = regularity.recordRep(at: seatedAt - t0) { record(anomaly, &events) }
        // A media bajada, con el tronco todavía inclinado, la referencia no se adapta (derivaría hacia abajo).
        if upright { adaptReference(r) }
        if progress.count >= spec.target {
            checkStepsPerRep(at: t, &events)
            phase = .done
            events.append(.completed)
        }
    }

    private func rejection(for ex: Excursion, duration: Double) -> Rejection? {
        if duration < Self.minRepSeconds { return .tooFast }
        if duration > maxSeconds(ex) { return .tooSlow }
        if ex.armsFlag { return .armsOnly }
        if ex.maxFaceShift < Self.minFaceTravel { return .noTravel }
        if ex.upperFaceSamples == 0 { return .faceNotSeen }
        if ex.liveSamples == 0 || Double(ex.liveSamples) < Self.minLiveFraction * Double(ex.faceSamples) {
            return .notLive
        }
        if ex.flatSamples > 0, Double(ex.flatSamples) >= Self.flatFaceRepFraction * Double(ex.faceSamples) {
            return .flatFace
        }
        if ex.maxPitchDelta > Self.maxTiltDeltaDeg || ex.maxRollDelta > Self.maxTiltDeltaDeg { return .phoneTilted }
        if ex.peakPitchDelta > Self.maxPeakPitchDeltaDeg { return .torsoOnly }
        if let forward = ex.peakFaceForward, forward < -Self.maxBackShift { return .torsoOnly }
        if ex.challenge == .stand, !ex.holdDone { return .holdChallengeFailed }
        return nil
    }

    /// Intento que nunca llegó de pie: inclinarse (tronco) o quedarse a medias.
    private mutating func closeAttempt(_ ex: Excursion, at t: Double, _ events: inout [VerifierEvent]) {
        // El teléfono llegó arriba pero la cara no: brazos (ya avisado y anotado al llegar arriba).
        if ex.armsReported {
            reject(.armsOnly, at: t)
            return
        }
        let dropped = ex.minRise < -Self.torsoMaxDrop
        let leaned = ex.maxFaceShift >= Self.torsoMinHorizontal
            && ex.maxFaceShift > Self.torsoHorizontalRatio * ex.maxFaceLift
        if dropped || leaned {
            reject(.torsoOnly, at: t)
            record(Anomaly(kind: SitStandAnomaly.torsoOnly, severity: .soft, at: t - t0,
                           detail: dropped ? String(format: "Teléfono %.0f cm bajo la silla", -ex.minRise * 100)
                                           : "Se inclinó sin pararse"), &events)
            events.append(.cue(Cue(text: SitStandCopy.torsoOnly, symbol: "figure.stand")))
        } else if ex.maxRise >= Self.armsCheckFraction * Self.standRise {
            reject(.partial, at: t)
            events.append(.cue(Cue(text: SitStandCopy.partial, symbol: "arrow.up")))
        }
        // Si no, fue un acomodo en la silla: sin aviso.
    }

    /// Fuera de la banda pero sentado, quieto y derecho como al calibrar: calibró de pie y se sentó, se
    /// acomodó más abajo, o ARKit retomó con el origen corrido (poca luz). Nueva referencia.
    /// `afterBlock`: tras un bloqueo de tracking el origen pudo correrse también en horizontal; pasados
    /// `reseatShiftedSeconds` no se exige que la cara vuelva al ancla.
    private mutating func reseatIfNeeded(_ r: Reading, at t: Double, afterBlock: Bool = false,
                                         _ events: inout [VerifierEvent]) -> Bool {
        guard let ref = reference, let face = r.face else {
            lowStillSince = nil
            return false
        }
        let rise = r.phoneY - ref.phoneY
        let seatedLike = isSeatedLike(r, face, anchor: ref.faceXZ)
        let shifted = afterBlock && rise < Self.holdStandFraction * Self.standRise && isSeatedLike(r, face, anchor: nil)
        guard abs(rise) > Self.seatedBand, r.isStill, seatedLike || shifted else {
            lowStillSince = nil
            return false
        }
        let since = lowStillSince ?? t
        lowStillSince = since
        guard t - since >= (seatedLike ? Self.reseatSeconds : Self.reseatShiftedSeconds) else { return false }
        lowStillSince = nil
        let offset = r.phoneXZ - face.xz
        let length = Self.norm(offset)
        reference = Reference(phoneY: r.phoneY, faceY: face.y, faceXZ: face.xz, faceInPhone: face.inPhone,
                              pitch: r.pitch, roll: r.roll,
                              forward: length >= Self.minForwardOffset ? offset / length : ref.forward)
        excursion = nil
        seatStillSince = nil
        phase = .seated
        restFaceXZ = face.xz
        events.append(.cue(Cue(text: SitStandCopy.reseated, symbol: "checkmark.circle.fill")))
        return true
    }

    /// Como al calibrar: cabeceo, cara a la misma distancia del teléfono (no lo movió con los brazos) y la
    /// cara no adelantada respecto de `anchor` (de vuelta sobre la silla, no de pie sobre los pies).
    /// `anchor == nil`: no se mira la posición horizontal (origen de ARKit corrido).
    private func isSeatedLike(_ r: Reading, _ face: FaceReading, anchor: SIMD2<Double>?) -> Bool {
        guard let ref = reference else { return false }
        let pitchDelta = abs(AngleMath.delta(r.pitch, ref.pitch))
        let ahead = anchor.flatMap { a in ref.forward.map { Self.dot(face.xz - a, $0) } } ?? 0
        return pitchDelta < Self.reseatMaxPitchDeltaDeg
            && Self.norm(face.inPhone - ref.faceInPhone) < Self.reseatMaxFaceInPhoneShift
            && ahead < Self.reseatMaxForward
    }

    /// Re-ancla la altura de referencia (teléfono y cara) en la postura actual, conservando la dirección;
    /// con `horizontal`, también la posición de la cara sentada (origen corrido en horizontal).
    private mutating func reanchor(_ r: Reading, _ face: FaceReading, horizontal: Bool = false) {
        guard var ref = reference else { return }
        ref.phoneY = r.phoneY
        ref.faceY = face.y
        if horizontal {
            ref.faceXZ = face.xz
            restFaceXZ = face.xz
        }
        reference = ref
        reanchorCount += 1
    }

    private mutating func adaptReference(_ r: Reading) {
        guard var ref = reference else { return }
        let a = Self.referenceAdaptation
        ref.phoneY += a * (r.phoneY - ref.phoneY)
        if let face = r.face {
            ref.faceY += a * (face.y - ref.faceY)
            ref.faceInPhone += a * (face.inPhone - ref.faceInPhone)
        }
        reference = ref
    }

    // MARK: Desafío, anomalías y rechazos

    private mutating func failChallenge(at t: Double, _ events: inout [VerifierEvent]) {
        challengeFailures += 1
        let hard = challengeFailures >= Self.holdFailHardCount
        let what = challenge.kind == .stand ? "de pie" : "sentado"
        record(Anomaly(kind: SitStandAnomaly.holdChallengeFailed, severity: hard ? .hard : .soft, at: t - t0,
                       detail: "No se quedó \(what) lo pedido (intento \(challengeFailures))"), &events)
        if hard { challengeRetired = true }
        events.append(.cue(Cue(text: hard ? SitStandCopy.holdGiveUp : SitStandCopy.holdFailed, symbol: "timer")))
    }

    private mutating func reportArms(gap: Double, drift: Double, at t: Double, _ events: inout [VerifierEvent]) {
        armsCount += 1
        let hard = armsCount >= Self.armsHardCount
        record(Anomaly(kind: SitStandAnomaly.armsOnly, severity: hard ? .hard : .soft, at: t - t0,
                       detail: String(format: "Cara desfasada %.0f cm; cara-teléfono %.0f cm", gap * 100, drift * 100)),
               &events)
        events.append(.cue(Cue(text: SitStandCopy.armsOnly, symbol: "figure.stand")))
    }

    /// Muchos pasos por rep contada → no fue pararse de una silla (subir y bajar un escalón de pie).
    private mutating func checkStepsPerRep(at t: Double, _ events: inout [VerifierEvent]) {
        guard !walkingHardReported, progress.count > 0, let first = stepsAtFirstRep, let last = lastSteps else { return }
        let steps = last - first
        let limit = max(Self.walkingHardMinSteps,
                        Int((Self.walkingHardStepsPerRep * Double(progress.count)).rounded(.up)))
        guard steps >= limit else { return }
        walkingHardReported = true
        record(Anomaly(kind: SitStandAnomaly.walking, severity: .hard, at: t - t0,
                       detail: "\(steps) pasos en \(progress.count) repeticiones"), &events)
    }

    private mutating func reject(_ reason: Rejection, at t: Double) {
        rejections.append(RejectionRecord(reason: reason, at: t - t0))
    }

    private mutating func record(_ anomaly: Anomaly, _ events: inout [VerifierEvent]) {
        anomalies.append(anomaly)
        events.append(.anomaly(anomaly))
    }

    // MARK: Consigna

    private func currentHint() -> String {
        if case .blocked(let reason) = progress.gate { return reason }
        let standPrompt = activeChallenge?.kind == .stand ? SitStandCopy.standThenHold : SitStandCopy.stand
        switch phase {
        case .calibrating: return SitStandCopy.calibrate
        case .awaitingSeat: return SitStandCopy.sit
        case .seated: return standPrompt
        case .done: return SitStandCopy.done
        case .excursion:
            guard let ex = excursion, ex.stood else { return standPrompt }
            switch ex.challenge {
            case .stand?: return ex.holdDone || ex.holdFailed ? SitStandCopy.sit : SitStandCopy.holdStand
            case .sit?: return ex.seatConfirmedAt == nil ? SitStandCopy.sitThenHold : SitStandCopy.holdSit
            case nil: return SitStandCopy.sit
            }
        }
    }

    // MARK: Vectores

    static func double(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }

    static func norm(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }
    static func norm(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }
    static func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a * b).sum() }

    /// Mediana por componente de tres puntos.
    static func median3(_ p: [SIMD3<Double>]) -> SIMD3<Double> {
        func m(_ a: Double, _ b: Double, _ c: Double) -> Double { max(min(a, b), min(max(a, b), c)) }
        return SIMD3(m(p[0].x, p[1].x, p[2].x), m(p[0].y, p[1].y, p[2].y), m(p[0].z, p[1].z, p[2].z))
    }
}

// MARK: - Fixtures sintéticas (simulador y tests)

/// Cinemática plausible de pararse y sentarse con el teléfono en las dos manos frente al pecho.
///
/// Modelo: el tronco (con el teléfono y la cara) gira sobre la cadera (`lean`) y la cadera sube y avanza
/// al pararse (fase de impulso con el tronco inclinado, despegue de la silla, extensión). Ruido realista:
/// jitter de ARKit, balanceo sentado y de pie, temblor de manos, energía facial viva y barómetro a 1 Hz.
/// Determinista por semilla.
nonisolated struct SitStandSynth: Sendable {
    nonisolated struct Body: Sendable, Hashable {
        /// Altura de la cadera sentado (m).
        var seatHipY: Double = 0.50
        /// Teléfono: a lo largo del tronco desde la cadera y delante del pecho (m).
        var trunkToPhone: Double = 0.40
        var phoneAhead: Double = 0.30
        /// Cara: a lo largo del tronco desde la cadera y delante del eje (m).
        var trunkToFace: Double = 0.70
        var faceAhead: Double = 0.08
        var phonePitchDeg: Double = 35
        var phoneRollDeg: Double = 2
        /// Fracción de la inclinación del tronco que sigue el teléfono (el resto lo compensan las muñecas).
        var pitchFollow: Double = 0.8
        /// Hacia dónde mira la persona en el mundo (la verificación no depende de esto).
        var headingDeg: Double = 30

        init() {}
    }

    nonisolated struct Noise: Sendable, Hashable {
        var phoneJitter: Double = 0.0015
        var faceJitter: Double = 0.003
        var faceInPhoneJitter: Double = 0.004
        var angleJitterDeg: Double = 1.5
        var seatedSway: Double = 0.004
        var standingSway: Double = 0.010
        var tremor: Double = 0.001
        var liveEnergy: ClosedRange<Double> = 0.008...0.06
        var altitudeNoise: Double = 0.08

        init() {}
    }

    /// Una rep: pararse, quedarse de pie, sentarse y quedarse sentado.
    nonisolated struct Rep: Sendable, Hashable {
        var riseSeconds: Double = 1.3
        var standSeconds: Double = 0.6
        var sitSeconds: Double = 1.5
        var seatedSeconds: Double = 1.0
        /// Subida de la cadera (= del teléfono con el tronco derecho), m.
        var rise: Double = 0.42
        /// Avance de la cadera al pararse (de la silla a sobre los pies), m.
        var forward: Double = 0.30
        var leanDeg: Double = 38
        var sitLeanDeg: Double = 30

        init() {}
    }

    /// Segundos que se queda de pie o sentado cuando cumple el desafío ("2 segundos").
    static let challengeHoldSeconds: Double = 2.3

    let fps: Double
    var body: Body
    var noise: Noise
    private(set) var samples: [SitStandSample] = []
    private(set) var t: Double = 0

    // Estado del cuerpo.
    var hipRise: Double = 0
    var hipForward: Double = 0
    var lean: Double = 0
    var armsLift: Double = 0
    var armsForward: Double = 0
    var standing = false
    var faceTracked = true
    var worldTrackingNormal = true
    var liveFace = true
    var steps: Int? = 0
    var barometer = true
    /// Relieve TrueDepth cada `reliefEveryFrames` cuadros (≈ 15 Hz a 60 Hz); false = sin profundidad.
    var depth = true
    var reliefEveryFrames = 4
    /// Cara plana para TrueDepth (foto o pantalla). Una foto (`liveFace == false`) también lo es.
    var flatFace = false

    private var rng: FixtureRandom
    /// Generador aparte para el relieve: no altera la secuencia del resto del ruido.
    private var reliefRNG: FixtureRandom
    private var walked = SIMD2<Double>.zero
    private var bob: Double = 0
    private var shakeOffset = SIMD3<Double>.zero
    private var origin: SIMD3<Double>? = nil
    private var altitudeHeld: Double? = nil
    private var nextAltitudeAt: Double = 0
    private let swayPhase: SIMD3<Double>

    init(seed: UInt64, body: Body = Body(), noise: Noise = Noise(), fps: Double = 60) {
        var rng = FixtureRandom(seed: seed)
        swayPhase = SIMD3(rng.unit(), rng.unit(), rng.unit()) * (2 * .pi)
        self.rng = rng
        reliefRNG = FixtureRandom(seed: seed ^ 0x5EED_DEE9)
        self.body = body
        self.noise = noise
        self.fps = max(1, fps)
    }

    // MARK: Movimientos

    mutating func hold(_ seconds: Double) {
        for _ in 0..<frames(seconds) { emit() }
    }

    mutating func standUp(seconds: Double, rise: Double, forward: Double, leanDeg: Double) {
        let n = frames(seconds)
        for i in 1...n {
            let u = Double(i) / Double(n)
            lean = leanDeg * (u < 0.4 ? (1 - cos(.pi * u / 0.4)) / 2 : (1 + cos(.pi * (u - 0.4) / 0.6)) / 2)
            hipRise = rise * Self.smoothstep((u - 0.35) / 0.65)
            hipForward = forward * Self.smoothstep((u - 0.2) / 0.8)
            standing = u > 0.7
            emit()
        }
        lean = 0
    }

    mutating func sitDown(seconds: Double, leanDeg: Double) {
        let n = frames(seconds)
        let rise0 = hipRise, forward0 = hipForward
        for i in 1...n {
            let u = Double(i) / Double(n)
            lean = leanDeg * (1 - cos(2 * .pi * u)) / 2
            hipRise = rise0 * (1 - Self.smoothstep(u / 0.85))
            hipForward = forward0 * (1 - Self.smoothstep(u))
            standing = u < 0.3
            emit()
        }
        lean = 0
        standing = false
    }

    mutating func rep(_ r: Rep) {
        standUp(seconds: r.riseSeconds, rise: r.rise, forward: r.forward, leanDeg: r.leanDeg)
        hold(r.standSeconds)
        sitDown(seconds: r.sitSeconds, leanDeg: r.sitLeanDeg)
        hold(r.seatedSeconds)
    }

    /// Inclinarse adelante sin pararse y volver.
    mutating func leanForward(seconds: Double, leanDeg: Double, holdSeconds: Double) {
        let n = frames(seconds)
        for i in 1...n {
            lean = leanDeg * (1 - cos(.pi * Double(i) / Double(n))) / 2
            emit()
        }
        hold(holdSeconds)
        for i in 1...n {
            lean = leanDeg * (1 + cos(.pi * Double(i) / Double(n))) / 2
            emit()
        }
        lean = 0
    }

    /// Subir el teléfono con los brazos (la cara se queda) y bajarlo.
    mutating func armsRaise(seconds: Double, lift: Double, holdSeconds: Double) {
        let n = frames(seconds)
        for i in 1...n {
            armsLift = lift * (1 - cos(.pi * Double(i) / Double(n))) / 2
            emit()
        }
        hold(holdSeconds)
        for i in 1...n {
            armsLift = lift * (1 + cos(.pi * Double(i) / Double(n))) / 2
            emit()
        }
        armsLift = 0
    }

    /// Sacudir el teléfono (sobre todo en vertical).
    mutating func shake(seconds: Double, amplitude: Double, hz: Double) {
        let start = t
        for _ in 0..<frames(seconds) {
            let w = 2 * .pi * hz * (t - start)
            shakeOffset = SIMD3(0.3 * amplitude * sin(w + 1), amplitude * sin(w), 0.2 * amplitude * cos(w))
            emit()
        }
        shakeOffset = .zero
    }

    /// Caminar hacia adelante con el teléfono en las manos.
    mutating func walk(seconds: Double, speed: Double, cadence: Double) {
        let start = t
        var lastStep = t
        standing = true
        for _ in 0..<frames(seconds) {
            walked.y += speed / fps
            bob = 0.02 * sin(2 * .pi * cadence * (t - start))
            if t - lastStep >= 1 / cadence {
                lastStep = t
                steps = (steps ?? 0) + 1
            }
            emit()
        }
        bob = 0
    }

    /// Rep con la variación natural de una persona (`jitter` 0 = idéntica a `base`). No varía la subida.
    mutating func naturalRep(_ base: Rep = Rep(), jitter: Double = 1) -> Rep {
        var r = base
        r.riseSeconds *= 1 + rng.symmetric(0.15 * jitter)
        r.standSeconds = max(0.3, base.standSeconds + rng.symmetric(0.25 * jitter))
        r.sitSeconds *= 1 + rng.symmetric(0.15 * jitter)
        r.seatedSeconds = max(0.6, base.seatedSeconds + rng.symmetric(0.4 * jitter))
        r.leanDeg += rng.symmetric(4 * jitter)
        r.sitLeanDeg += rng.symmetric(4 * jitter)
        return r
    }

    /// `count` reps naturales; si `comply`, cumple el desafío en su rep.
    mutating func series(count: Int, challenge: SitToStandVerifier.HoldChallenge?, base: Rep = Rep(),
                         jitter: Double = 1, comply: Bool = true) {
        guard count > 0 else { return }
        for i in 1...count {
            var r = naturalRep(base, jitter: jitter)
            if comply, let c = challenge, c.repIndex == i {
                switch c.kind {
                case .stand: r.standSeconds = max(r.standSeconds, Self.challengeHoldSeconds)
                case .sit: r.seatedSeconds = max(r.seatedSeconds, Self.challengeHoldSeconds)
                }
            }
            rep(r)
        }
    }

    /// Fixture de replay que completa la actividad del verificador (cumple su desafío).
    static func completing(_ verifier: SitToStandVerifier, seed: UInt64 = 11) -> [SitStandSample] {
        var synth = SitStandSynth(seed: seed)
        synth.hold(1.6)
        synth.series(count: verifier.spec.target, challenge: verifier.challenge)
        synth.hold(1)
        return synth.samples
    }

    // MARK: Muestra

    mutating func emit() {
        let th = lean * .pi / 180
        let sway = standing ? noise.standingSway : noise.seatedSway
        let sx = sway * sin(2 * .pi * 0.23 * t + swayPhase.x)
        let sy = 0.4 * sway * sin(2 * .pi * 0.37 * t + swayPhase.y)
        let sz = sway * sin(2 * .pi * 0.29 * t + swayPhase.z)
        let hipY = body.seatHipY + hipRise
        // Ejes locales: x lateral, y arriba, z hacia adelante.
        var phone = SIMD3<Double>(
            sx + walked.x,
            hipY + body.trunkToPhone * cos(th) - body.phoneAhead * sin(th) + armsLift + sy + bob,
            hipForward + body.trunkToPhone * sin(th) + body.phoneAhead * cos(th) + armsForward + sz + walked.y)
        let face = SIMD3<Double>(
            sx + walked.x,
            hipY + body.trunkToFace * cos(th) - body.faceAhead * sin(th) + sy + bob,
            hipForward + body.trunkToFace * sin(th) + body.faceAhead * cos(th) + sz + walked.y)
        let tremor = noise.tremor * sin(2 * .pi * 8 * t)
        phone += SIMD3(tremor, tremor, 0.5 * tremor) + shakeOffset

        let pitch = body.phonePitchDeg + body.pitchFollow * lean + rng.symmetric(noise.angleJitterDeg)
        let roll = body.phoneRollDeg + rng.symmetric(noise.angleJitterDeg)
        // Cara en el espacio del teléfono: rotación inversa del cabeceo sobre el eje lateral.
        let p = pitch * .pi / 180
        let d = face - phone
        let inPhone = SIMD3<Double>(d.x, d.y * cos(p) + d.z * sin(p), -d.y * sin(p) + d.z * cos(p))
            + jitter(noise.faceInPhoneJitter)

        let o = origin ?? phone
        origin = o
        let phoneWorld = world(phone - o) + jitter(noise.phoneJitter)
        let faceWorld = world(face - o) + jitter(noise.faceJitter)

        var altitude: Double? = nil
        if barometer {
            if t >= nextAltitudeAt {
                altitudeHeld = (phone.y - o.y) + rng.symmetric(noise.altitudeNoise)
                nextAltitudeAt = t + 1
            }
            altitude = altitudeHeld
        }
        let span = noise.liveEnergy.upperBound - noise.liveEnergy.lowerBound
        let energy = faceTracked && liveFace ? Float(noise.liveEnergy.lowerBound + rng.unit() * span) : 0
        var relief: Float? = nil
        if depth, faceTracked, samples.count % max(1, reliefEveryFrames) == 0 {
            relief = flatFace || !liveFace ? Float(0.0015 + reliefRNG.unit() * 0.001) : Float(0.009 + reliefRNG.unit() * 0.004)
        }

        samples.append(SitStandSample(
            t: t,
            phonePos: Self.float(phoneWorld),
            phonePitchDeg: pitch,
            phoneRollDeg: roll,
            faceTracked: faceTracked,
            facePos: faceTracked ? Self.float(faceWorld) : .zero,
            faceInPhone: faceTracked ? Self.float(inPhone) : .zero,
            shapeEnergy: energy,
            worldTrackingNormal: worldTrackingNormal,
            altitude: altitude,
            steps: steps,
            faceRelief: relief))
        t += 1 / fps
    }

    // MARK: Utilidades

    private func frames(_ seconds: Double) -> Int { max(1, Int((seconds * fps).rounded())) }

    private mutating func jitter(_ amplitude: Double) -> SIMD3<Double> {
        SIMD3(rng.symmetric(amplitude), rng.symmetric(amplitude), rng.symmetric(amplitude))
    }

    /// Local (x lateral, z adelante) → mundo, girando sobre la vertical según `headingDeg`.
    private func world(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let h = body.headingDeg * .pi / 180
        return SIMD3(v.x * cos(h) + v.z * sin(h), v.y, -v.x * sin(h) + v.z * cos(h))
    }

    static func smoothstep(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }

    static func float(_ v: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3(Float(v.x), Float(v.y), Float(v.z))
    }
}
