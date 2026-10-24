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
// 1. Subida real: en un mismo cuadro el teléfono sube ≥ 18 cm y la CARA ≥ 20 cm sobre el asiento de ESA rep
//    (referencias tomadas sentado y quieto justo antes de empezar; los brazos no levantan la cara), y después la
//    cara vuelve a ≤ 8 cm del asiento, quieta (o en una meseta de ≤ 2,5 cm: el cojín rebota) y sobre la silla;
//    1,2-15 s por rep. Desde la 3.ª rep, la subida de la cara también se compara con la de la persona (≥ 75 % de
//    su mediana): medias paradas tras reps enteras no cuentan. El asiento sube como mucho 2 cm por rep (sentarse
//    cada vez más alto no lo corre) y baja como mucho 5 cm por intento salvo al sentarse de verdad (la cara baja
//    más de lo que se mueve en horizontal): reclinada en el respaldo o inclinada de lado no es un asiento.
// 2. Anti-brazos: el teléfono no sube más que la cara (+10 cm, con signo: brazos cansados que bajan el
//    teléfono no son trampa) y la cara no se mueve respecto de él (±10 cm).
// 3. Cuerpo que se traslada: pararse adelanta la cara ≥ 10 cm (sobre los pies); un montaje rígido o un
//    ascensor no. Inclinarse sin pararse no cuenta (el teléfono baja > 12 cm o la cara se desplaza más
//    en horizontal que en vertical); enderezarse desde una postura encorvada tampoco (al llegar arriba
//    la cara no puede quedar atrás ni el teléfono girado > 30°), ni desde una inclinación lateral (la cara
//    corrida > 15 cm de lado o el teléfono girado > 25° de lado), ni desde reclinado (del despegue al pico la
//    cara avanza > 45 cm: pararse la lleva sobre los pies, 25-35 cm).
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
// despegar, reps de hasta 15 s sin apurarlo, empezar sentado o de pie (la primera postura sale con la cara
// quieta 0,5 s y sin esperar que el VIO se asiente), caminar hasta la silla antes de sentarse, sentadas cortas
// (0,6 s) que rebotan en el cojín, el teléfono en el regazo sentado y traído al pecho al pararse, otro agarre
// entre reps, sentarse a otra profundidad, en el borde o apoyado en el respaldo, el cojín que cede, re-anclaje
// si ARKit retoma con el origen corrido, quietud que tolera cuadros sueltos sin cara o sin tracking.

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

/// Rep = pararse del todo desde la silla y volver a sentarse, verificada con la pose del teléfono y la cara.
/// `kind` llega por init: la integración y los tests usan `.pararseSentarse`.
///
/// Máquina de estados (v2, calibrada con grabaciones reales del iPhone 17 Pro Max):
/// - La postura inicial puede ser sentado O de pie: basta la cara quieta 0,5 s (antes 1 s con el teléfono
///   quieto en 3D, que con el VIO asentándose o la persona meciéndose tardaba 6-15 s). Si en la historia previa
///   hubo una meseta de la que después subió la cara, se repasa con las mismas reglas: la rep que empezó
///   mientras ARKit arrancaba no se pierde.
/// - "Sentado" lo decide la CARA (altura y quietud, sobre el asiento), no el teléfono: sentado, la cara varía
///   ±2 cm entre reps y el teléfono va del regazo al pecho (±13 cm).
/// - Las referencias de cada intento (alturas del asiento, cara en el espacio del teléfono, cabeceo, alabeo,
///   dirección) se toman de los últimos cuadros quietos sentado justo antes del intento, no de la calibración:
///   cambiar el agarre sentado ya no da `armsOnly` ni `torsoOnly` en la rep siguiente.
/// - Cada intento cerrado (contado o no) deja sus medidas en `attempts` (`AttemptDiagnosticsProviding`): el
///   registro del teléfono las guarda junto a la grabación para calibrar con datos reales.
nonisolated struct SitToStandVerifier: ActivityVerifier {
    typealias Sample = SitStandSample

    // MARK: Constantes (calibradas con grabaciones reales; ver `SitToStandRealReplayTests`)

    // Postura inicial (sentado o de pie).
    /// Cara quieta este tiempo con el teléfono delante: primera postura (s).
    static let calibrationSeconds: Double = 0.5
    /// …con al menos estos cuadros con cara en la ventana (≈ 24 Hz efectivos).
    static let minCalibrationSamples = 12
    /// Rango de altura de la cara dentro de la ventana (m). Quieto (sentado o de pie) varía ±1 cm; el VIO que
    /// todavía se asienta corre el origen en HORIZONTAL (50 cm en 2 s en una grabación), y eso ya no reinicia.
    static let calibrationMaxDrift: Double = 0.04
    /// Las manos pueden moverse algo mientras tanto, no a velocidad de rep (m/s).
    static let calibrationMaxPhoneSpeed: Double = 0.25
    /// Distancia cara-teléfono plausible con el teléfono frente al pecho (m).
    static let faceDistanceRange: ClosedRange<Double> = 0.15...1.0
    /// El teléfono debe quedar delante de la cara en horizontal (m): define "hacia adelante".
    static let minForwardOffset: Double = 0.06
    /// Historia previa a la primera postura que se repasa (s).
    static let preHistorySeconds: Double = 8
    /// Meseta mínima de la historia previa que sirve de asiento (s).
    static let preSeatSeconds: Double = 0.15
    /// ARKit tarda ~1 s en pasar el world tracking a normal: mientras nunca estuvo normal, hasta esto desde el
    /// inicio no se bloquea con "Mueva el teléfono más despacio" (s).
    static let trackingWarmupSeconds: Double = 4

    // Repetición.
    /// Subida mínima del teléfono sobre el asiento de la rep (m). Silla alta de casino: la cadera sube 22 cm.
    static let standRise: Double = 0.18
    /// Subida mínima de la CARA en el mismo cuadro (m): los brazos suben el teléfono, no la cara. Real: 0,35-0,39.
    static let minFaceRise: Double = 0.20
    /// Desplazamiento horizontal mínimo de la cara durante la rep (m). Real: 0,10-0,47 (la menor, parándose rápido
    /// desde el borde de la silla, casi en vertical); un montaje rígido o un ascensor, ≤ 0,02.
    static let minFaceTravel: Double = 0.06
    /// Tras esta cantidad de reps contadas, la subida de la cara se compara también con la de ESTA persona…
    static let relativeRiseMinReps = 2
    /// …: menos que esta fracción de la mediana de las contadas es media parada (`partial`). Real: la menor es 0,92
    /// de la mediana; quedar suspendido 12 cm (límite aceptado) da 0,82; pararse a medias (20-24 cm) tras reps
    /// enteras (42 cm) da 0,5-0,6, y quedar cada vez 6 cm más alto sobre la silla, 0,74 a la tercera.
    static let relativeRiseFraction: Double = 0.75
    /// El teléfono que sube más que esto sobre el asiento abre un intento (brazos o pararse) (m).
    static let seatedBand: Double = 0.08
    /// "Sentado" = la cara a no más de esto sobre el asiento de la rep (m). Real: ±2 cm entre reps.
    static let seatFaceBand: Double = 0.08
    /// El asiento sube como mucho esto por rep (deriva de ARKit, cojín): sentarse cada vez más alto no lo corre (m).
    static let seatCreepMax: Double = 0.02
    /// El asiento baja como mucho esto por intento (cojín que cede, se acomodó más hundido) (m)…
    static let seatSinkMax: Double = 0.05
    /// …salvo al sentarse de verdad, que baja la cara MÁS de lo que la mueve en horizontal (fracción, m/m). Real: baja
    /// 0,35-0,42 m y va 0,10-0,30 m atrás. Reclinarse en el respaldo o inclinarse de lado mueven la cara más en
    /// horizontal que en vertical: esa postura no pasa a ser el asiento (desde ahí, enderezarse "subiría" 20-28 cm).
    static let sitDownMaxShiftRatio: Double = 1.0
    /// Una rep dura al menos esto (s): pararse y sentarse de verdad no baja de ~1,5 s.
    static let minRepSeconds: Double = 1.2
    /// Tolerante a repeticiones lentas de alguien con dolor (juntar fuerza inclinado, subir en 4 s, bajar en 5 s).
    static let maxRepSeconds: Double = 15
    /// La cara en el asiento y quieta esto, de vuelta sobre la silla: sentado (s). La prueba de 30 s se para a 0,4 s.
    static let seatedStillSeconds: Double = 0.2
    /// …o en una meseta: la altura de la cara varió a lo más `seatPlateauRange` en los últimos `seatPlateauSeconds`.
    /// Sentarse rápido rebota 2-3 cm en el cojín y la cara nunca queda quieta cuadro a cuadro (real: sentado 0,6 s,
    /// altura en ±1-1,6 cm); una bajada lenta con dolor (0,1 m/s) recorre 3 cm en ese tiempo.
    static let seatPlateauSeconds: Double = 0.3
    static let seatPlateauRange: Double = 0.025
    /// Se sentó más adelante en la silla: basta quedarse quieto esto (s)…
    static let seatSettleSeconds: Double = 1.5
    /// …sin quedar más adelante que esto (m): sentarse en el borde en vez de al fondo (0,20-0,25), o enderezarse
    /// después de apoyarse en el respaldo con el asiento tomado así (25-35° de tronco: 0,26-0,40)…
    static let seatMaxMove: Double = 0.40
    /// …ni con la cara más abajo que esto (inclinado sobre las rodillas no es sentarse) (m).
    static let seatSettleMaxDrop: Double = 0.06
    /// Teléfono quieto (m/s): cierra intentos sin pararse (brazos) y refresca la referencia.
    static let stillVerticalSpeed: Double = 0.06
    /// Cara quieta (m/s). Sentado meciéndose ±0,02-0,04; una bajada lenta con dolor (0,1 m/s) solo baja de esto
    /// en los últimos 2 cm.
    static let stillFaceSpeed: Double = 0.06
    /// Cara quieta en horizontal (m/s), para tomar como asiento una postura más adelantada en la silla. Al
    /// enderezar el tronco sentándose la cara va atrás a 0,3-0,7 m/s.
    static let stillFaceHSpeed: Double = 0.10
    /// Ventana para estimar la velocidad vertical (s).
    static let velocityLookbackSeconds: Double = 0.15
    /// Historia de alturas que se guarda para esa estimación (s).
    static let heightHistorySeconds: Double = 0.5
    /// EMA de alturas a ~60 Hz (constante de tiempo ≈ 40 ms).
    static let heightSmoothingAlpha: Double = 0.35
    /// Cuadros quietos sentado con que se refresca la referencia del próximo intento (s)…
    static let restWindowSeconds: Double = 0.4
    /// …y cuántos cuadros como mínimo.
    static let restMinFrames = 6
    /// Intento sin pararse con la cara sentada y quieta este tiempo (s): se cierra aunque el teléfono siga
    /// moviéndose o quede en otra altura (lo dejó en el regazo o en el pecho).
    static let phoneParkedSeconds: Double = 0.8
    /// Un intento sin pararse que sigue abierto más que esto se cierra sin aviso (s): la persona quedó quieta en
    /// una postura que no es el asiento (reclinada, corrida de lado) y la próxima parada no puede heredar ese reloj.
    static let openAttemptMaxSeconds: Double = 15
    /// Quieto fuera de la banda tras pararse (encorvado o con el teléfono alto): se orienta con un aviso.
    static let stuckCueSeconds: Double = 1.0
    /// Hueco sin pose confiable que reinicia suavizado e historiales (s).
    static let poseGapResetSeconds: Double = 0.25

    // Anti-brazos.
    /// Cuánto más que la cara puede subir el teléfono (m, con signo).
    static let armsMaxRiseGap: Double = 0.10
    /// La cara se movió respecto del teléfono (m)…
    static let armsMaxFaceInPhoneShift: Double = 0.10
    /// …y el teléfono no quedó por debajo de la cara más que esto (m).
    static let armsDriftMinGap: Double = -0.02
    /// La comparación se hace en la parte alta del movimiento (fracción de `standRise`).
    static let armsCheckFraction: Double = 0.5
    /// Con la cara ya arriba de verdad, por cada cm sobre `minFaceRise + armsBodyMargin` se tolera un cm más de
    /// teléfono sobre la cara (trae el teléfono del regazo al pecho al pararse) (m).
    static let armsBodyMargin: Double = 0.05
    /// Desde el tercer `armsOnly` la anomalía es hard.
    static let armsHardCount = 3

    // Inclinación y tronco.
    /// Cabeceo/alabeo máximo del teléfono durante la rep, contra el inicio de la rep (°).
    static let maxTiltDeltaDeg: Double = 60
    /// Arriba el tronco vuelve a estar derecho: el teléfono no puede seguir girado más que esto (°).
    static let maxPeakPitchDeltaDeg: Double = 30
    /// Arriba la cara no puede quedar más atrás que esto respecto de donde estaba sentada (m).
    static let maxBackShift: Double = 0.10
    /// Arriba la cara no puede quedar corrida DE LADO (perpendicular a "adelante") más que esto respecto del asiento
    /// (m). Real ≤ 0,084; enderezarse de una inclinación lateral de 45-50° la corre 0,48-0,54 (y sube la cara 20-25 cm).
    static let maxPeakLateral: Double = 0.15
    /// …ni el teléfono seguir girado de lado (alabeo) más que esto respecto del asiento (°). Real ≤ 7,4°.
    static let maxPeakRollDeltaDeg: Double = 25
    /// Del despegue (la cara todavía a la altura del asiento) al pico, la cara avanza a lo más esto (m). Pararse lleva
    /// la cadera sobre los pies (0,25-0,35) y el tronco que ya iba inclinado al despegar vuelve atrás: honesto ≤ 0,35.
    /// Enderezarse desde reclinado en el respaldo lo bastante para subir la cara 20 cm (≥ 50° de tronco) la adelanta
    /// ≥ 0,5 aunque las muñecas compensen el cabeceo y los brazos suban el teléfono.
    static let maxRiseForward: Double = 0.45
    /// "Adelante" para medir el corrimiento de lado sale del teléfono delante de la cara al menos esto (m). Sentado
    /// derecho: 0,22-0,37; inclinado 50° o con el teléfono en el regazo queda casi debajo (< 0,1).
    static let lateralForwardMinOffset: Double = 0.15
    /// Sin pararse, la cara bajó más que esto adelantándose: se inclinó (m). Antes era el teléfono: bajarlo al
    /// regazo daba "Teléfono 19 cm bajo la silla".
    static let torsoMaxDrop: Double = 0.12
    /// …o se movió en horizontal más que esta fracción de lo que se movió en vertical (inclinarse sin pararse).
    static let torsoHorizontalRatio: Double = 0.8
    /// Avance de la cara que ya es inclinarse (m): sentado abre un intento; sin pararse, cuenta como tronco.
    static let torsoMinHorizontal: Double = 0.12
    /// …y la cara bajó al menos esto (m): 15° de tronco la bajan 4,5 cm.
    static let torsoMinDrop: Double = 0.04
    /// La cara subió esto sin quedar de pie: "Suba hasta quedar de pie" (m). Más que `seatFaceBand`: enderezarse
    /// sentado (la cara sube 8-10 cm desde el respaldo) abre un intento, pero no es una parada a medias.
    static let partialFaceRise: Double = 0.12

    // Re-sentarse: empezó de pie y se sentó, o ARKit retomó con el origen corrido (poca luz).
    /// Quieto fuera del asiento este tiempo, sentado derecho sobre la silla: asiento nuevo (s).
    static let reseatSeconds: Double = 2
    /// Primera postura de pie y después se sentó (la cara bajó ≥ `minFaceRise` sin adelantarse): basta esto (s).
    static let firstSeatSeconds: Double = 0.3
    /// Con el origen corrido en horizontal: el cabeceo como al empezar el intento (°)…
    static let reseatMaxPitchDeltaDeg: Double = 15
    /// La cara no más adelante que esto del asiento: de vuelta sobre la silla, no de pie sobre los pies (m).
    static let reseatMaxForward: Double = 0.05
    /// …y la cara en el espacio del teléfono no cambió (m): con el origen corrido en horizontal no hay otra prueba.
    static let reseatMaxFaceInPhoneShift: Double = 0.05
    /// Origen corrido también en horizontal: quieto este tiempo con el agarre del inicio, se re-ancla sin contar (s).
    static let reseatShiftedSeconds: Double = 2.5

    // Persona viva y gates.
    /// Sin cara este tiempo: bloqueo "Mantenga la cara en la pantalla" (s).
    static let faceLostSeconds: Double = 1.5
    /// Hueco de cara que no reinicia la ventana de la primera postura (casco, lentes, poca luz).
    static let calibrationFaceGapSeconds: Double = 0.3
    /// Ventana de vida: con cara rastreada, < 10 % de cuadros vivos en 2 s → `static` (una foto con un cuadro de
    /// ruido cada tanto ya no reinicia la cuenta); vuelve a vigilar cuando hay > 50 % vivos.
    static let staticSeconds: Double = 2
    static let staticMaxLiveFraction: Double = 0.10
    static let staticRecoverLiveFraction: Double = 0.5
    /// Cuadros con cara mínimos en la ventana para juzgar (30 Hz × 1 s).
    static let staticMinSamples = 30
    /// Una rep exige cara viva en ≥ 20 % de los cuadros con cara del intento.
    static let minLiveFraction: Double = 0.20
    /// Energía de blendShapes bajo la que el cuadro se considera estático.
    static let staticEnergyThreshold: Float = FaceLivenessMonitor.staticEnergyThreshold
    /// Relieve 3D (TrueDepth): mediana de las lecturas de los últimos 3 s bajo esto (m) = plano. Ruido del sensor
    /// sobre una pantalla o una foto ≈ 1-3 mm; una cara real ≈ 1-2 cm (real: 1,2-2,0 cm).
    static let flatFaceMaxRelief: Double = 0.004
    /// Ventana del relieve (s) y lecturas mínimas para decidir (≈ 7 Hz en el iPhone: ≥ 1,1 s).
    static let reliefWindowSeconds: Double = 3
    static let reliefMinReadings = 8
    /// La rep no cuenta si ≥ 30 % de sus cuadros con cara vieron una cara plana; desde la 3.ª, `flatFace` hard.
    static let flatFaceRepFraction: Double = 0.3
    static let flatFaceHardCount = 3
    /// Tracking del mundo limitado este tiempo (ya arrancado): bloqueo "Mueva el teléfono más despacio" (s).
    static let trackingLimitedSeconds: Double = 0.5

    // Desafío.
    /// Se pide "2 segundos" y se acepta desde 1,5 s.
    static let holdSeconds: Double = 1.5
    /// "De pie" durante el desafío = la cara sobre esta fracción de `minFaceRise` (sin cara: el teléfono sobre
    /// esta fracción de `standRise`).
    static let holdStandFraction: Double = 0.8
    /// Desde el segundo desafío fallado la anomalía es hard y el desafío se retira.
    static let holdFailHardCount = 2
    /// Segundos extra permitidos en la rep del desafío.
    static let challengeExtraSeconds: Double = 3

    // Apoyo físico.
    /// Pasos durante la serie que ya son caminar (soft, con aviso).
    static let walkingSteps = 6
    /// Pasos nuevos en los últimos segundos = está caminando (el podómetro entrega cada ~2,5 s) (s). Antes de conocer
    /// el asiento, mientras camina, sentarse se mide desde donde está y no desde donde empezó.
    static let walkingRecentSeconds: Double = 3
    /// Sin pararse, la cara se movió en horizontal más que esto: caminó (o el VIO se corrió), no se inclinó: el
    /// tronco no lleva la cara más lejos que su largo (m).
    static let torsoMaxReach: Double = 0.8
    /// Pasos desde el inicio de la primera rep contada: ≥ max(8, 2,5 × reps) → `walking` hard (subir y bajar un
    /// escalón de pie). Un paso espurio por rep (el podómetro cuenta el impulso) o reacomodar los pies no llega.
    static let walkingHardMinSteps = 8
    static let walkingHardStepsPerRep: Double = 2.5
    /// Velocidad del teléfono no humana para este ejercicio (m/s). Real: máximo 0,86 m/s.
    static let shakeSpeed: Double = 3
    /// Intervalo mínimo y máximo entre posiciones para medir esa velocidad (s).
    static let shakeMinDt: Double = 0.025
    static let shakeMaxGap: Double = 0.25
    /// Picos sobre `shakeSpeed` dentro de la ventana para declarar sacudida. La posición pasa antes por una
    /// mediana de 3 cuadros: un salto de tracking de un cuadro (ida y vuelta) no genera picos.
    static let shakeMinPeaks = 4
    static let shakeMedianFrames = 3
    static let shakeWindowSeconds: Double = 2
    /// Historia de posiciones crudas para la velocidad de sacudida (s).
    static let rawHistorySeconds: Double = 0.3
    /// Tendencia barométrica que delata escalera o ascensor (señal de apoyo, no bloqueante) (m).
    static let altitudeDriftMeters: Double = 1.5
    /// Ritmo "perfecto" (vídeo en bucle, mecanismo): CV de intervalos bajo esto con ≥ 6 reps. Una persona se para
    /// con un ritmo muy parejo (CV ≈ 0,03-0,10) y sin metrónomo no baja del 1 %; un bucle da CV ≈ 0,003.
    static let regularityMaxCV: Double = 0.01
    static let regularityMinReps = RegularityDetector.defaultMinReps

    // MARK: Tipos

    nonisolated enum Phase: String, Sendable, Hashable, Codable {
        /// Esperando la primera postura quieta con la cara visible (sentado o de pie).
        case calibrating
        /// Tras un bloqueo: hay que volver a sentarse antes de contar.
        case awaitingSeat
        case seated
        /// Fuera del asiento (inclinándose, de pie o volviendo), o moviendo el teléfono.
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

    /// Postura "sentado" de referencia de un intento.
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

    /// Un intento: desde que deja el asiento (o mueve el teléfono) hasta que vuelve sentado y quieto.
    nonisolated struct Excursion: Sendable, Hashable {
        var startT: Double
        /// Dónde estaba la cara sentada antes del intento (horizontal).
        var anchorFaceXZ: SIMD2<Double>
        /// Asiento del intento (referencias tomadas justo antes de empezar).
        var seat: Reference
        var minRise: Double = .infinity
        var maxRise: Double = -.infinity
        var lastRise: Double = 0
        var peakPitchDelta: Double = 0
        var peakFaceForward: Double? = nil
        /// En el pico de la cara: corrimiento de lado (perpendicular a "adelante") desde donde la cara despegó del
        /// asiento, y alabeo contra el asiento.
        var peakLateral: Double = 0
        var peakRollDelta: Double = 0
        /// Último cuadro con la cara todavía a la altura del asiento (despegue) y "adelante" medido ahí: una silla
        /// giratoria o el VIO que se asienta corren la cara de lado ANTES de pararse, no al pararse.
        var departureFaceXZ: SIMD2<Double>? = nil
        var departureForward: SIMD2<Double>? = nil
        /// Avance de la cara del despegue al pico (m, con signo; nil sin dirección).
        var peakRiseForward: Double? = nil
        /// Último cuadro con la cara a la altura del asiento (± `seatFaceBand`) y "adelante" medido ahí. Si la primera
        /// postura fue de pie y caminó hasta la silla, sentarse se mide desde aquí, no desde donde empezó.
        var levelFaceXZ: SIMD2<Double>
        var levelForward: SIMD2<Double>?
        var maxPitchDelta: Double = 0
        var maxRollDelta: Double = 0
        var maxFaceShift: Double = 0
        var maxFaceLift: Double = 0
        /// Mayor avance de la cara (proyección hacia adelante) sobre el asiento.
        var maxFaceAhead: Double = -.infinity
        /// Mayor y menor subida de la cara (con signo) sobre el asiento.
        var maxFaceRise: Double = -.infinity
        var minFaceRise: Double = .infinity
        /// Mayor (subida del teléfono − subida de la cara), con signo.
        var maxRiseGap: Double = -.infinity
        var maxFaceInPhoneShift: Double = 0
        var upperFaceSamples = 0
        var faceSamples = 0
        var liveSamples = 0
        /// Cuadros con cara mientras el relieve TrueDepth la veía plana.
        var flatSamples = 0
        var samples = 0
        /// Pasos acumulados al empezar el intento.
        var stepsAtStart: Int? = nil
        /// Brazos en algún cuadro de la parte alta, con la holgura de la cara de ESE cuadro (avisa en el momento
        /// a quien sube el teléfono sin pararse).
        var armsFlag = false
        /// Mayor exceso de (teléfono − cara) o de cara-teléfono sobre lo tolerado sin holgura (m).
        var maxArmsExcess: Double = -.infinity
        /// Brazos en la rep completa: la holgura sale de la subida MÁXIMA de la cara. Quien trae el teléfono del
        /// regazo al pecho al pararse adelanta los brazos a mitad de camino; con la cara ≥ 25 cm arriba el
        /// cuerpo ya se paró (20 cm de cara cuentan sin brazos) y el teléfono de más no le suma nada a nadie.
        var armsOnRep: Bool {
            maxArmsExcess > max(0, maxFaceRise - (SitToStandVerifier.minFaceRise + SitToStandVerifier.armsBodyMargin))
        }
        var armsReported = false
        var stood = false
        var stoodAt: Double? = nil
        /// Último cuadro de pie (cara arriba): "aguantó de pie" para el diagnóstico.
        var lastStandingAt: Double? = nil
        var challenge: HoldChallenge.Kind? = nil
        var holdDone = false
        var holdFailed = false
        var touchedBand = false
        var restoodCued = false
        var stillSince: Double? = nil
        /// Desde cuándo la cara está quieta cuadro a cuadro en el asiento (sin la meseta): el instante del ritmo.
        var vyStillSince: Double? = nil
        var movedSeatSince: Double? = nil
        var seatConfirmedAt: Double? = nil
        /// Dónde quedó la cara al sentarse en el desafío sentado (x, y, z).
        var seatConfirmedFace: SIMD3<Double>? = nil
        var stuckSince: Double? = nil
        var stuckCued = false

        init(startT: Double, seat: Reference, stepsAtStart: Int? = nil) {
            self.startT = startT
            self.seat = seat
            anchorFaceXZ = seat.faceXZ
            departureForward = seat.forward
            levelFaceXZ = seat.faceXZ
            levelForward = seat.forward
            self.stepsAtStart = stepsAtStart
        }

        /// Segundos de pie desde que llegó arriba.
        var standSeconds: Double {
            guard let stoodAt, let last = lastStandingAt else { return 0 }
            return max(0, last - stoodAt)
        }
    }

    /// Medidas de un intento cerrado (contado o no), para el registro de diagnóstico del teléfono.
    nonisolated struct AttemptRecord: Sendable, Hashable, CustomStringConvertible {
        var index: Int
        /// Segundos desde el inicio de la actividad.
        var start: Double
        var end: Double
        /// Asiento de la rep (m, mundo).
        var seatPhoneY: Double
        var seatFaceY: Double
        /// Subidas máximas sobre el asiento (m).
        var phoneRise: Double
        var faceRise: Double
        /// Bajada máxima de la cara bajo el asiento (m, ≥ 0).
        var faceDrop: Double
        /// Teléfono − cara en la parte alta (m) y cambio de la cara en el espacio del teléfono contra el inicio
        /// de la rep (m).
        var riseGap: Double
        var faceInPhoneShift: Double
        /// Desplazamiento horizontal máximo de la cara, avance y corrimiento de lado en el pico (m).
        var faceTravel: Double
        var peakForward: Double?
        var peakLateral: Double
        /// Avance de la cara del despegue al pico (m).
        var riseForward: Double?
        /// Cabeceo máximo y en el pico, alabeo máximo y en el pico, contra el inicio de la rep (°).
        var pitchDelta: Double
        var peakPitchDelta: Double
        var rollDelta: Double
        var peakRollDelta: Double
        /// De pie desde que llegó arriba, y sentado en el desafío (s).
        var standSeconds: Double
        var seatHoldSeconds: Double
        var liveFraction: Double
        var flatFraction: Double
        var challenge: HoldChallenge.Kind?
        var stood: Bool
        /// Número de rep si contó.
        var rep: Int?
        var rejection: Rejection?

        var description: String {
            let outcome = rep.map { "rep \($0)" } ?? rejection?.rawValue ?? "acomodo"
            let forward = peakForward.map { String(format: "%+.2f", $0) } ?? "-"
            return String(format: "#%d %.2f-%.2f s %@ | asiento cara %+.3f tel %+.3f | sube cara %.3f tel %.3f baja cara %.3f"
                          + " | tel-cara %+.3f cara-tel %.3f | avance %.2f pico %@ al subir %@ lado %.2f"
                          + " | cabeceo %.0f° pico %.0f° alabeo %.0f° pico %.0f°"
                          + " | de pie %.1f s sentado %.1f s | viva %.0f%% plana %.0f%% | desafío %@%@",
                          index, start, end, outcome, seatFaceY, seatPhoneY, faceRise, phoneRise, faceDrop,
                          riseGap, faceInPhoneShift, faceTravel, forward, riseForward.map { String(format: "%+.2f", $0) } ?? "-",
                          peakLateral,
                          pitchDelta, peakPitchDelta, rollDelta, peakRollDelta,
                          standSeconds, seatHoldSeconds, liveFraction * 100, flatFraction * 100,
                          challenge?.rawValue ?? "-", stood ? " | de pie" : "")
        }
    }

    private nonisolated struct FaceReading: Sendable {
        var y: Double
        var xz: SIMD2<Double>
        var inPhone: SIMD3<Double>
    }

    private nonisolated struct Reading: Sendable {
        var t: Double
        var phone: SIMD3<Double>
        /// Altura suavizada del teléfono y su velocidad vertical.
        var phoneY: Double
        var vy: Double?
        var face: FaceReading?
        /// Velocidad vertical de la cara (suavizada); nil sin cara o recién aparecida.
        var faceVy: Double?
        /// Rapidez horizontal de la cara (m/s); nil sin cara o recién aparecida.
        var faceHSpeed: Double? = nil
        var pitch: Double
        var roll: Double
        var live: Bool

        var phoneXZ: SIMD2<Double> { SIMD2(phone.x, phone.z) }
        var isStill: Bool { vy.map { abs($0) < SitToStandVerifier.stillVerticalSpeed } ?? false }
        /// La cara quieta en vertical: true/false si se sabe, nil si no hay cara o velocidad.
        var faceStill: Bool? {
            guard face != nil, let faceVy else { return nil }
            return abs(faceVy) < SitToStandVerifier.stillFaceSpeed
        }
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

    /// Promedio de cuadros (calibración, historia previa y refresco sentado) → referencia.
    private nonisolated struct PoseAverage: Sendable {
        var start: Double? = nil
        var anchorFaceY = 0.0
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

        init(start: Double? = nil, anchorFaceY: Double = 0, firstPitch: Double = 0, firstRoll: Double = 0) {
            self.start = start
            self.anchorFaceY = anchorFaceY
            self.firstPitch = firstPitch
            self.firstRoll = firstRoll
        }

        mutating func add(_ r: Reading, _ face: FaceReading) {
            if n == 0, start == nil {
                start = r.t
                anchorFaceY = face.y
                firstPitch = r.pitch
                firstRoll = r.roll
            }
            n += 1
            phoneY += r.phoneY
            faceY += face.y
            faceXZ += face.xz
            faceInPhone += face.inPhone
            offset += r.phoneXZ - face.xz
            pitchDelta += AngleMath.delta(r.pitch, firstPitch)
            rollDelta += AngleMath.delta(r.roll, firstRoll)
        }

        /// `fallbackForward`: si el teléfono quedó casi bajo la cara (en el regazo), se conserva la dirección.
        func reference(fallbackForward: SIMD2<Double>? = nil) -> Reference? {
            guard n > 0 else { return nil }
            let d = Double(n)
            let meanOffset = offset / d
            let length = SitToStandVerifier.norm(meanOffset)
            return Reference(phoneY: phoneY / d, faceY: faceY / d, faceXZ: faceXZ / d, faceInPhone: faceInPhone / d,
                             pitch: AngleMath.wrap180(firstPitch + pitchDelta / d),
                             roll: AngleMath.wrap180(firstRoll + rollDelta / d),
                             forward: length >= SitToStandVerifier.minForwardOffset ? meanOffset / length : fallbackForward)
        }
    }

    // MARK: Estado

    let kind: ActivityKind
    let spec: VerificationSpec
    let seed: UInt64
    let challenge: HoldChallenge
    private(set) var progress: VerifierProgress
    private(set) var phase: Phase = .calibrating
    /// Asiento del próximo intento: se refresca sentado y quieto, y se congela al empezar cada intento.
    private(set) var reference: Reference? = nil
    /// Se vio a la persona sentada en ese asiento (tras una rep o al sentarse después de empezar de pie). Antes
    /// de eso, la primera postura es provisoria: puede haber sido de pie.
    private(set) var seatKnown = false
    private(set) var excursion: Excursion? = nil
    private(set) var anomalies: [Anomaly] = []
    private(set) var rejections: [RejectionRecord] = []
    /// Medidas de cada intento cerrado (diagnóstico; `AttemptDiagnosticsProviding`).
    private(set) var attempts: [AttemptRecord] = []
    /// Duración de cada rep contada (s).
    private(set) var repSeconds: [Double] = []
    /// Mayor subida del teléfono en una rep contada (m).
    private(set) var maxCountedRise: Double? = nil
    /// Subida máxima de la cara de cada rep contada (m): la referencia de `relativeRiseFraction`.
    private(set) var countedFaceRises: [Double] = []
    private(set) var challengeFailures = 0
    private(set) var challengePassed = false
    private(set) var challengeRetired = false
    private(set) var armsCount = 0
    private(set) var flatFaceCount = 0
    /// El relieve TrueDepth de los últimos segundos es el de una superficie plana (foto, pantalla).
    private(set) var faceLooksFlat = false
    /// Veces que el asiento se re-ancló fuera de la banda (se sentó más alto o más bajo, ARKit retomó corrido).
    private(set) var reanchorCount = 0
    /// Reps contadas al repasar la historia previa a la primera postura.
    private(set) var replayedReps = 0
    /// Velocidad máxima del teléfono observada (m/s), para diagnóstico.
    private(set) var peakPhoneSpeed: Double = 0
    /// Rango barométrico observado (m), señal de apoyo.
    private(set) var altitudeRange: ClosedRange<Double>? = nil

    private var started = false
    private var t0: Double = 0
    private var window = PoseAverage()
    private var phoneSmoother = ExponentialSmoother(alpha: SitToStandVerifier.heightSmoothingAlpha)
    private var faceSmoother = ExponentialSmoother(alpha: SitToStandVerifier.heightSmoothingAlpha)
    private var lastPoseAt: Double? = nil
    private var lastFaceReadAt: Double? = nil
    private var heightHistory: [TimedValue] = []
    private var faceHistory: [TimedValue] = []
    private var faceXZHistory: [TimedPoint] = []
    private var rawHistory: [TimedPoint] = []
    private var aboveShake = false
    private var shakePeaks: [Double] = []
    private var shakingReported = false
    private var lastFaceAt: Double = 0
    private var sawFace = false
    private var worldEverNormal = false
    private var liveWindow: [TimedFlag] = []
    private var liveWindowLive = 0
    private var liveWindowSince: Double? = nil
    private var staticReported = false
    private var reliefReadings: [TimedValue] = []
    private var rawRecent: [TimedPoint] = []
    private var limitedSince: Double? = nil
    private var seatStillSince: Double? = nil
    private var lowStillSince: Double? = nil
    /// Altura y posición de la cara al sentarse: límites del refresco sentado (no se corre inclinándose).
    /// Límites de la altura de la cara para el refresco sentado: a lo más `seatCreepMax` sobre el asiento de la
    /// rep anterior y `seatSinkMax` bajo donde se sentó. Y la posición de la cara al sentarse (no se adelanta).
    private var seatCeilingY: Double? = nil
    private var seatFloorY: Double? = nil
    private var seatAnchorFaceXZ: SIMD2<Double>? = nil
    /// Cuadros quietos sentado de los últimos `restWindowSeconds`.
    private var rest: [Reading] = []
    /// Lecturas previas a la primera postura (para no perder una rep que empezó antes).
    private var preHistory: [Reading] = []
    private var replaying = false
    private var stepsBase: Int? = nil
    private var lastSteps: Int? = nil
    /// Cuándo subió por última vez el podómetro.
    private var lastStepAt: Double? = nil
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
        if s.worldTrackingNormal {
            worldEverNormal = true
            limitedSince = nil
        } else if limitedSince == nil {
            // Arranque: ARKit tarda ~1 s en pasar a normal; eso no es "mover rápido" (antes bloqueaba a los 0,9 s).
            limitedSince = worldEverNormal ? t : max(t, t0 + Self.trackingWarmupSeconds)
        }
        let blocked = updateGate(at: t, &events)

        // Sin tracking normal la pose no es confiable: ese tramo no se mide ni se cuenta.
        guard s.worldTrackingNormal else { return events }
        let reading = read(s, at: t)
        detectShake(reading.phone, at: t, &events)
        guard !blocked else { return events }
        step(reading, at: t, &events)
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

    private mutating func step(_ r: Reading, at t: Double, _ events: inout [VerifierEvent]) {
        switch phase {
        case .calibrating: calibrate(r, at: t, &events)
        case .awaitingSeat: awaitSeat(r, at: t, &events)
        case .seated: watchSeated(r, at: t, &events)
        case .excursion: track(r, at: t, &events)
        case .done: break
        }
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
        var faceVy: Double? = nil
        var faceHSpeed: Double? = nil
        if s.faceTracked {
            if let last = lastFaceReadAt, t - last > Self.poseGapResetSeconds {
                faceSmoother.reset()
                faceHistory.removeAll()
                faceXZHistory.removeAll()
            }
            lastFaceReadAt = t
            let f = Self.double(s.facePos)
            let fy = faceSmoother.update(f.y)
            faceHistory.append(TimedValue(t: t, v: fy))
            while let first = faceHistory.first, first.t < t - Self.heightHistorySeconds { faceHistory.removeFirst() }
            if let past = faceHistory.last(where: { $0.t <= t - Self.velocityLookbackSeconds }), t > past.t {
                faceVy = (fy - past.v) / (t - past.t)
            }
            faceXZHistory.append(TimedPoint(t: t, p: SIMD3(f.x, 0, f.z)))
            while let first = faceXZHistory.first, first.t < t - Self.heightHistorySeconds { faceXZHistory.removeFirst() }
            if let past = faceXZHistory.last(where: { $0.t <= t - Self.velocityLookbackSeconds }), t > past.t {
                faceHSpeed = Self.norm(SIMD3(f.x, 0, f.z) - past.p) / (t - past.t)
            }
            face = FaceReading(y: fy, xz: SIMD2(f.x, f.z), inPhone: Self.double(s.faceInPhone))
        }
        return Reading(t: t, phone: phone, phoneY: y, vy: vy, face: face, faceVy: faceVy, faceHSpeed: faceHSpeed,
                       pitch: s.phonePitchDeg, roll: s.phoneRollDeg,
                       live: s.faceTracked && s.shapeEnergy >= Self.staticEnergyThreshold)
    }

    /// Podómetro (caminar) y barómetro (escalera / ascensor): señales de apoyo, nunca bloquean.
    private mutating func observeSupport(_ s: SitStandSample, at t: Double, _ events: inout [VerifierEvent]) {
        if let steps = s.steps {
            let base = stepsBase ?? steps
            stepsBase = base
            if let previous = lastSteps, steps > previous { lastStepAt = t }
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

    /// Cara visible (para el gate) y viva (micro-expresiones), medida por fracción en una ventana de 2 s.
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

    /// Velocidad del teléfono por encima de lo humano, repetida → sacudida (mediana de 3 cuadros antes).
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
        if phase == .excursion, let ex = excursion {
            reject(.interrupted, at: t)
            logAttempt(ex, at: t, rep: nil, rejection: .interrupted)
        }
        excursion = nil
        window = PoseAverage()
        preHistory.removeAll()
        rest.removeAll()
        seatStillSince = nil
        lowStillSince = nil
        phase = reference == nil ? .calibrating : .awaitingSeat
    }

    // MARK: Primera postura

    /// La primera postura quieta (sentado o de pie): la cara quieta `calibrationSeconds` con el teléfono delante.
    /// El teléfono puede moverse algo (manos) y el origen de ARKit correrse en horizontal mientras se asienta.
    private mutating func calibrate(_ r: Reading, at t: Double, _ events: inout [VerifierEvent]) {
        if !replaying {
            preHistory.append(r)
            while let first = preHistory.first, first.t < t - Self.preHistorySeconds { preHistory.removeFirst() }
        }
        guard let face = r.face else {
            // Cuadros sueltos sin cara (casco, lentes, poca luz) no reinician la ventana; un hueco largo sí.
            if lastFaceReadAt.map({ t - $0 > Self.calibrationFaceGapSeconds }) ?? true { window = PoseAverage() }
            return
        }
        let calm = r.vy.map { abs($0) < Self.calibrationMaxPhoneSpeed } ?? true
        guard Self.plausible(r, face), calm, r.faceStill != false else {
            window = PoseAverage()
            return
        }
        if window.start == nil || abs(face.y - window.anchorFaceY) > Self.calibrationMaxDrift {
            window = PoseAverage(start: t, anchorFaceY: face.y, firstPitch: r.pitch, firstRoll: r.roll)
        }
        window.add(r, face)
        guard let start = window.start, t - start >= Self.calibrationSeconds,
              window.n >= Self.minCalibrationSamples, let ref = window.reference() else { return }
        window = PoseAverage()
        progress.gate = .ready
        events.append(.gate(.ready))
        events.append(.cue(Cue(text: SitStandCopy.calibrated, symbol: "checkmark.circle.fill")))
        acquire(ref, windowStart: start, &events)
    }

    /// Cara a distancia de brazos y el teléfono delante de ella en horizontal.
    private static func plausible(_ r: Reading, _ face: FaceReading) -> Bool {
        faceDistanceRange.contains(norm(face.inPhone)) && norm(r.phoneXZ - face.xz) >= minForwardOffset
    }

    /// Toma la primera postura. Si en la historia previa hubo una meseta de la cara de la que después subió
    /// ≥ `minFaceRise` (venía sentado y se paró mientras ARKit arrancaba), se parte de esa meseta y se repasa la
    /// historia con las mismas reglas: esa rep no se pierde. Los avisos del repaso ya pasaron y no se muestran.
    private mutating func acquire(_ ref: Reference, windowStart: Double, _ events: inout [VerifierEvent]) {
        let history = preHistory
        preHistory.removeAll()
        guard let (seat, seatEnd) = Self.earlierSeat(in: history, before: windowStart) else {
            setSeat(ref)
            return
        }
        setSeat(seat)
        var replayed: [VerifierEvent] = []
        let before = progress.count
        replaying = true
        for h in history where h.t > seatEnd {
            step(h, at: h.t, &replayed)
        }
        replaying = false
        replayedReps += progress.count - before
        events += replayed.filter {
            switch $0 {
            case .rep, .progress, .completed, .anomaly: true
            case .cue, .gate: false
            }
        }
    }

    /// Primera meseta de la cara en la historia (quieta ≥ `preSeatSeconds`, a distancia plausible) desde la que
    /// la cara subió después ≥ `minFaceRise`.
    private static func earlierSeat(in history: [Reading], before end: Double) -> (Reference, Double)? {
        var run = PoseAverage()
        var runEnd = 0.0
        var lastFaceT: Double? = nil
        var candidates: [(PoseAverage, Double)] = []
        func close() {
            if let s = run.start, runEnd - s >= preSeatSeconds, run.n >= restMinFrames { candidates.append((run, runEnd)) }
            run = PoseAverage()
        }
        for r in history where r.t < end {
            guard let face = r.face else { continue }
            if let last = lastFaceT, r.t - last > calibrationFaceGapSeconds { close() }
            lastFaceT = r.t
            guard plausible(r, face), r.faceStill == true else {
                close()
                continue
            }
            if run.start != nil, abs(face.y - run.anchorFaceY) > calibrationMaxDrift { close() }
            run.add(r, face)
            runEnd = r.t
        }
        close()
        for (avg, endT) in candidates {
            guard let ref = avg.reference() else { continue }
            // Subió la cara ≥ `minFaceRise` y sin quedar atrás: pararse lleva la cara adelante, sobre los pies;
            // enderezarse desde una inclinación la lleva atrás (esa meseta no era el asiento).
            let rose = history.contains { r in
                guard r.t > endT, let f = r.face, f.y - ref.faceY >= minFaceRise else { return false }
                let shift = f.xz - ref.faceXZ
                return (ref.forward.map { dot(shift, $0) } ?? 0) >= 0
            }
            if rose { return (ref, endT) }
        }
        return nil
    }

    /// `ref` pasa a ser el asiento del próximo intento y el ancla del refresco sentado. `ceiling`: altura máxima
    /// de la cara para el refresco (por omisión `seatCreepMax` sobre `ref`).
    private mutating func setSeat(_ ref: Reference, known: Bool = false, ceiling: Double? = nil) {
        reference = ref
        seatCeilingY = ceiling ?? ref.faceY + Self.seatCreepMax
        seatFloorY = ref.faceY - Self.seatSinkMax
        seatAnchorFaceXZ = ref.faceXZ
        if known { seatKnown = true }
        rest.removeAll()
        excursion = nil
        seatStillSince = nil
        lowStillSince = nil
        phase = .seated
    }

    // MARK: Sentado

    /// Tras un bloqueo: vuelve a estar sentado cuando la cara está en el asiento y quieta.
    private mutating func awaitSeat(_ r: Reading, at t: Double, _ events: inout [VerifierEvent]) {
        guard let ref = reference else { return }
        if reseatIfNeeded(r, at: t, afterBlock: true, &events) { return }
        let plateau = facePlateau(at: t)
        guard let face = r.face, r.faceStill != nil || plateau else { return } // sin cara no se decide
        let still = r.faceStill == true || plateau
        // Más abajo que el asiento solo si es sentarse (o el origen saltó en vertical): reclinada o inclinada de lado
        // no se toma como asiento.
        // A la altura del asiento de antes (hasta `seatCreepMax` más arriba): tras un bloqueo el origen pudo correrse;
        // más arriba lo decide `reseatIfNeeded` con la cara quieta 2 s (asentarse tras el bajón de sentarse sube la
        // cara 3-4 cm y un asiento tomado antes quedaría bajo ella).
        let inSeat = face.y - ref.faceY <= Self.seatCreepMax && ahead(face.xz, from: ref.faceXZ, ref) <= Self.torsoMinHorizontal
            && (face.y >= ref.faceY - Self.seatSinkMax || Self.isSitDown(from: ref, to: face))
        guard inSeat, still else {
            seatStillSince = nil
            return
        }
        let since = plateau ? min(seatStillSince ?? t, t - Self.seatPlateauSeconds) : (seatStillSince ?? t)
        seatStillSince = since
        guard t - since >= Self.seatedStillSeconds else { return }
        var seat = Self.pose(r, face, fallbackForward: ref.forward)
        seat.faceY = min(seat.faceY, ref.faceY + Self.seatCreepMax)
        setSeat(seat)
    }

    /// Sentado: empieza un intento si la cara sube o se va adelante, o el teléfono sube. Mientras tanto, la
    /// referencia sigue a la postura quieta (teléfono del regazo al pecho, otro agarre, el cojín que cede).
    private mutating func watchSeated(_ r: Reading, at t: Double, _ events: inout [VerifierEvent]) {
        guard let ref = reference else { return }
        let rise = r.phoneY - ref.phoneY
        var leaning = false, faceMoved = false
        if let face = r.face {
            leaning = ahead(face.xz, from: ref.faceXZ, ref) > Self.torsoMinHorizontal
            let faceRise = face.y - ref.faceY
            faceMoved = faceRise > Self.seatFaceBand || faceRise < -Self.torsoMaxDrop
        }
        // Bajar el teléfono (al regazo) no es un intento: la referencia lo sigue cuando queda quieto.
        guard rise > Self.seatedBand || leaning || faceMoved else {
            refreshRest(r, at: t)
            return
        }
        rest.removeAll()
        excursion = Excursion(startT: t, seat: ref, stepsAtStart: lastSteps)
        phase = .excursion
        track(r, at: t, &events)
    }

    /// Sentado y quieto (cara y teléfono): la referencia es el promedio de los últimos cuadros así. La cara solo
    /// entre `seatFloorY` y `seatCeilingY`, y sin adelantarse: inclinarse o subir de a poco no corre el asiento.
    private mutating func refreshRest(_ r: Reading, at t: Double) {
        guard let ref = reference, let face = r.face, r.faceStill == true, r.vy.map({ abs($0) < Self.stillVerticalSpeed }) ?? false,
              Self.faceDistanceRange.contains(Self.norm(face.inPhone)) else { return }
        let anchorXZ = seatAnchorFaceXZ ?? ref.faceXZ
        guard face.y >= seatFloorY ?? ref.faceY - Self.seatSinkMax, face.y <= seatCeilingY ?? ref.faceY + Self.seatCreepMax,
              ahead(face.xz, from: anchorXZ, ref) <= Self.reseatMaxForward else { return }
        rest.append(r)
        while let first = rest.first, first.t < t - Self.restWindowSeconds { rest.removeFirst() }
        guard rest.count >= Self.restMinFrames else { return }
        var avg = PoseAverage()
        for frame in rest { if let f = frame.face { avg.add(frame, f) } }
        if let fresh = avg.reference(fallbackForward: ref.forward) { reference = fresh }
    }

    /// Referencia con la postura de un cuadro.
    private static func pose(_ r: Reading, _ face: FaceReading, fallbackForward: SIMD2<Double>?) -> Reference {
        var avg = PoseAverage()
        avg.add(r, face)
        return avg.reference(fallbackForward: fallbackForward)!
    }

    /// Proyección hacia adelante de `xz − from` (sin dirección conocida, la distancia).
    private func ahead(_ xz: SIMD2<Double>, from: SIMD2<Double>, _ ref: Reference) -> Double {
        let shift = xz - from
        return ref.forward.map { Self.dot(shift, $0) } ?? Self.norm(shift)
    }

    // MARK: Intento

    /// Un intento en curso: mide subida, cara, inclinación, desafío y la vuelta sentado, contra su propio asiento.
    private mutating func track(_ r: Reading, at t: Double, _ events: inout [VerifierEvent]) {
        guard var ex = excursion else { return }
        let ref = ex.seat
        let rise = r.phoneY - ref.phoneY
        let pitchDelta = abs(AngleMath.delta(r.pitch, ref.pitch))
        let rollDelta = abs(AngleMath.delta(r.roll, ref.roll))
        ex.samples += 1
        ex.minRise = min(ex.minRise, rise)
        ex.lastRise = rise
        ex.maxPitchDelta = max(ex.maxPitchDelta, pitchDelta)
        ex.maxRollDelta = max(ex.maxRollDelta, rollDelta)
        if r.live { ex.liveSamples += 1 }
        // Intento sin pararse abierto demasiado tiempo (quieta en una postura que no es el asiento): se cierra sin
        // aviso y con el mismo asiento; si sigue fuera, empieza otro con el reloj de nuevo.
        if !ex.stood, t - ex.startT > Self.openAttemptMaxSeconds {
            logAttempt(ex, at: t, rep: nil, rejection: nil)
            excursion = nil
            rest.removeAll()
            phase = .seated
            return
        }

        var faceForward: Double? = nil
        var faceRise: Double? = nil
        if let face = r.face {
            ex.faceSamples += 1
            if faceLooksFlat { ex.flatSamples += 1 }
            let fr = face.y - ref.faceY
            faceRise = fr
            let shift = face.xz - ex.anchorFaceXZ
            ex.maxFaceShift = max(ex.maxFaceShift, Self.norm(shift))
            ex.maxFaceLift = max(ex.maxFaceLift, abs(fr))
            ex.minFaceRise = min(ex.minFaceRise, fr)
            let forward = ref.forward.map { Self.dot(shift, $0) }
            faceForward = forward
            ex.maxFaceAhead = max(ex.maxFaceAhead, forward ?? Self.norm(shift))
            let offset = r.phoneXZ - face.xz
            let offsetLength = Self.norm(offset)
            // Solo caminando antes de conocer el asiento (empezó de pie y va hacia la silla): reclinarse o inclinarse de
            // lado también dejan la cara a esa altura un rato, pero sin pasos.
            let walking = !seatKnown && (lastStepAt.map { t - $0 <= Self.walkingRecentSeconds } ?? false)
            if walking, abs(fr) <= Self.seatFaceBand {
                ex.levelFaceXZ = face.xz
                if offsetLength >= Self.lateralForwardMinOffset { ex.levelForward = offset / offsetLength }
            }
            if fr < Self.seatFaceBand {
                // Todavía a la altura del asiento: aquí despega. "Adelante" solo con el teléfono bien delante de la
                // cara (inclinado 50° o con el teléfono en el regazo queda casi debajo y la dirección no vale).
                ex.departureFaceXZ = face.xz
                if offsetLength >= Self.lateralForwardMinOffset { ex.departureForward = offset / offsetLength }
            }
            if fr > ex.maxFaceRise {
                // El pico es el de la CARA: arriba el tronco vuelve a estar derecho (brazos cansados no lo corren).
                ex.maxFaceRise = fr
                ex.peakPitchDelta = pitchDelta
                ex.peakRollDelta = rollDelta
                if let forward { ex.peakFaceForward = forward }
                // De lado = la componente perpendicular a "adelante" desde el despegue (sin dirección, nada que medir).
                let side = face.xz - (ex.departureFaceXZ ?? ex.anchorFaceXZ)
                ex.peakLateral = ex.departureForward.map { abs(side.x * $0.y - side.y * $0.x) } ?? 0
                ex.peakRiseForward = ex.departureForward.map { Self.dot(side, $0) }
            }
            if rise >= Self.armsCheckFraction * Self.standRise {
                ex.upperFaceSamples += 1
                // Con signo: el ataque sube el teléfono MÁS que la cara; brazos cansados lo suben menos. Con la cara
                // ya arriba de verdad se tolera traer el teléfono del regazo al pecho.
                let gap = rise - fr
                let drift = Self.norm(face.inPhone - ref.faceInPhone)
                let slack = max(0, fr - (Self.minFaceRise + Self.armsBodyMargin))
                ex.maxRiseGap = max(ex.maxRiseGap, gap)
                ex.maxFaceInPhoneShift = max(ex.maxFaceInPhoneShift, drift)
                // Exceso sobre lo tolerado sin holgura (se decide al cerrar con la subida máxima de la cara).
                let excess = max(gap - Self.armsMaxRiseGap,
                                 gap > Self.armsDriftMinGap ? drift - Self.armsMaxFaceInPhoneShift : -.infinity)
                ex.maxArmsExcess = max(ex.maxArmsExcess, excess)
                if excess > slack { ex.armsFlag = true }
            }
        }
        ex.maxRise = max(ex.maxRise, rise)

        // De pie: el teléfono y la cara arriba en el mismo cuadro (los brazos no suben la cara; tapar la
        // cámara arriba tampoco sirve).
        if !ex.stood, rise >= Self.standRise, (faceRise ?? -1) >= Self.minFaceRise {
            ex.stood = true
            ex.stoodAt = t
            ex.lastStandingAt = t
            ex.challenge = activeChallenge?.kind
            switch ex.challenge {
            case .stand?: cue(SitStandCopy.holdStand, "figure.stand", &events)
            case .sit?: cue(SitStandCopy.sitThenHold, "chair.fill", &events)
            case nil: break
            }
        } else if ex.stood, ex.touchedBand, (faceRise ?? -1) >= Self.minFaceRise, rise >= Self.standRise, !ex.restoodCued {
            ex.restoodCued = true
            cue(SitStandCopy.notSeated, "chair.fill", &events)
        }
        let standing = faceRise.map { $0 >= Self.holdStandFraction * Self.minFaceRise }
            ?? (rise >= Self.holdStandFraction * Self.standRise)
        if ex.stood, standing, ex.stoodAt != nil, ex.seatConfirmedAt == nil, !ex.touchedBand { ex.lastStandingAt = t }

        // Teléfono arriba con la cara desfasada: brazos. Se decide al cerrar (sin pararse) o con la rep completa:
        // a mitad de una parada honesta los brazos pueden ir adelante de la cara (del regazo al pecho).

        // Desafío de pie: quedarse arriba ≥ 1,5 s desde que llegó.
        if ex.stood, ex.challenge == .stand, !ex.holdDone, !ex.holdFailed, let stoodAt = ex.stoodAt {
            if standing {
                if t - stoodAt >= Self.holdSeconds {
                    ex.holdDone = true
                    cue(SitStandCopy.holdOK, "checkmark.circle.fill", &events)
                }
            } else {
                ex.holdFailed = true
                failChallenge(at: t, &events)
            }
        }

        // En el asiento: la cara a no más de `seatFaceBand` sobre el asiento de la rep (sin cara, no se sabe).
        let inSeat: Bool? = faceRise.map { $0 <= Self.seatFaceBand }
        if ex.stood, inSeat == true { ex.touchedBand = true }

        // Desafío sentado en curso: debe quedarse en el asiento 1,5 s. Inclinarse para pararse (la cara se
        // adelanta o baja 12 cm) ya es dejarlo.
        if let confirmedAt = ex.seatConfirmedAt {
            // Contra donde se sentó (puede ser más adelante en la silla que al empezar la rep).
            let seatedFace = ex.seatConfirmedFace ?? SIMD3(ex.anchorFaceXZ.x, ref.faceY, ex.anchorFaceXZ.y)
            let leftSeat = inSeat == false
                || (r.face.map { $0.y - seatedFace.y < -Self.torsoMaxDrop } ?? false)
                || (r.face.map { ahead($0.xz, from: SIMD2(seatedFace.x, seatedFace.z), ref) > Self.torsoMinHorizontal } ?? false)
            if leftSeat {
                excursion = nil
                failChallenge(at: t, &events)
                reject(.holdChallengeFailed, at: t)
                logAttempt(ex, at: t, rep: nil, rejection: .holdChallengeFailed)
                // Ya se está levantando: empieza otro intento ahora mismo, desde ese asiento.
                excursion = Excursion(startT: t, seat: ex.seat, stepsAtStart: lastSteps)
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

        // Fase final sentado: la cara en el asiento, quieta y de vuelta sobre la silla. Sin pararse, además el
        // teléfono de vuelta en la banda (o quieto en otra altura: lo dejó en el pecho o en el regazo).
        // Empezó de pie (primera postura provisoria) y se está sentando: se espera el asiento nuevo, sin cerrar
        // el intento como inclinación.
        if !ex.stood, !seatKnown, let fr = faceRise, fr <= -Self.minFaceRise {
            excursion = ex
            _ = reseatIfNeeded(r, at: t, standingFrom: Self.levelSeat(ex), &events)
            return
        }
        let plateau = inSeat == true && facePlateau(at: t)
        if inSeat == true, r.faceStill == true || plateau {
            // Desde cuándo está sentado: en una meseta, desde que empezó (`seatPlateauSeconds` atrás). El desafío
            // sentado cuenta desde que se confirma (ahora), no desde el comienzo de la meseta: al final de la bajada la
            // cara ya está quieta a la altura del asiento mientras el tronco todavía se endereza.
            let stillSince = ex.stillSince ?? t
            ex.stillSince = stillSince
            if r.faceStill == true { ex.vyStillSince = ex.vyStillSince ?? t } else { ex.vyStillSince = nil }
            let since = plateau ? min(stillSince, t - Self.seatPlateauSeconds) : stillSince
            let forward = faceForward ?? 0
            let faceBack = forward <= Self.torsoMinHorizontal
            // Se sentó más adelante en la silla: la cara a la altura del asiento (no inclinada: no bajó más de
            // `torsoMinDrop`), hasta `seatMaxMove` adelante, y quieta también en horizontal (a media bajada la
            // cadera que baja y el tronco que se endereza se compensan en vertical, no en horizontal).
            let movedSeat = !faceBack && forward <= Self.seatMaxMove && (faceRise ?? -1) >= -Self.torsoMinDrop
                && (r.faceHSpeed.map { $0 < Self.stillFaceHSpeed } ?? false)
            if movedSeat { ex.movedSeatSince = ex.movedSeatSince ?? t } else if r.faceHSpeed != nil { ex.movedSeatSince = nil }
            let movedSettled = ex.movedSeatSince.map { t - $0 >= Self.seatedStillSeconds } ?? false
            // Quieto un rato con la cara a la altura del asiento, aunque parezca adelantada (el VIO corrió el origen
            // en horizontal o gira en una silla giratoria). Inclinado sobre las rodillas la cara queda más abajo.
            let settled = t - since >= Self.seatSettleSeconds && (faceRise ?? -1) >= -Self.seatSettleMaxDrop
            // Sin pararse (brazos, acomodo), además el teléfono de vuelta en la banda y quieto; o la cara sentada
            // y quieta `phoneParkedSeconds` aunque el teléfono siga moviéndose o quede en otra altura (regazo,
            // pecho): un intento abierto por el teléfono no se arrastra hasta la próxima rep (daría `tooSlow`).
            let phoneBack = abs(rise) < Self.seatedBand && (r.vy.map { abs($0) < Self.stillVerticalSpeed } ?? true)
            let ready = ex.stood || phoneBack || t - since >= Self.phoneParkedSeconds
            // Sin pararse, una postura más baja que el asiento que no es sentarse (reclinada, de lado) no cierra el
            // intento: no puede pasar a ser el asiento.
            let lowNotSeat = !ex.stood && (faceRise ?? 0) < -Self.seatSinkMax
                && !(r.face.map { Self.isSitDown(from: ref, to: $0) } ?? false)
            if ready, !lowNotSeat, (t - since >= Self.seatedStillSeconds && faceBack) || movedSettled || settled {
                if ex.stood, ex.challenge == .sit {
                    ex.seatConfirmedAt = t
                    ex.seatConfirmedFace = r.face.map { SIMD3($0.xz.x, $0.y, $0.xz.y) }
                    excursion = ex
                    return
                }
                // Sentado desde que la cara quedó quieta (o ahora, si solo hay meseta): el ritmo se mide aquí y un
                // instante nítido no se corre con el rebote del cojín.
                complete(ex, seatedAt: ex.vyStillSince ?? t, r, at: t, movedSeat: !faceBack, &events)
                return
            }
        } else if r.faceStill != nil || inSeat == false {
            // Sin cara o sin velocidad (hueco corto con poca luz) no se reinicia la quietud.
            ex.stillSince = nil
            ex.vyStillSince = nil
            ex.movedSeatSince = nil
        }

        // Quieto fuera del asiento tras pararse: encorvado, suspendido sobre la silla, o ARKit retomó con el
        // origen corrido. Se orienta una vez y, si está sentado derecho sobre la silla, se re-ancla y se cierra.
        if ex.stood, inSeat == false, r.faceStill == true, !standing {
            let since = ex.stuckSince ?? t
            ex.stuckSince = since
            let seatedLike = r.face.map { isSeatedLike(r, $0, ref, anchor: ex.anchorFaceXZ) } ?? false
            if !ex.stuckCued, !seatedLike, t - since >= Self.stuckCueSeconds {
                ex.stuckCued = true
                cue(SitStandCopy.sitUpright, "chair.fill", &events)
            }
            if t - since >= Self.reseatSeconds, seatedLike {
                excursion = ex
                complete(ex, seatedAt: since, r, at: t, reanchored: true, &events)
                return
            }
            // Origen corrido también en horizontal: no se puede confirmar que se sentó. Se re-ancla para no
            // quedar trabado, pero el intento no cuenta.
            if t - since >= Self.reseatShiftedSeconds, let face = r.face, isSeatedLike(r, face, ref, anchor: nil) {
                excursion = nil
                reject(.interrupted, at: t)
                logAttempt(ex, at: t, rep: nil, rejection: .interrupted)
                reanchored(Self.pose(r, face, fallbackForward: ref.forward), &events)
                return
            }
        } else if r.faceStill != nil {
            ex.stuckSince = nil
        }

        excursion = ex
        if !ex.stood { _ = reseatIfNeeded(r, at: t, standingFrom: Self.levelSeat(ex), &events) }
    }

    /// El asiento del intento visto desde donde la cara estuvo a su altura por última vez (posición y "adelante").
    private static func levelSeat(_ ex: Excursion) -> Reference {
        var seat = ex.seat
        seat.faceXZ = ex.levelFaceXZ
        seat.forward = ex.levelForward ?? ex.seat.forward
        return seat
    }

    /// La cara está en una meseta: su altura varió ≤ `seatPlateauRange` en los últimos `seatPlateauSeconds`.
    private func facePlateau(at t: Double) -> Bool {
        guard lastFaceReadAt == t, let first = faceHistory.first, t - first.t >= Self.seatPlateauSeconds else { return false }
        var lo = Double.infinity, hi = -Double.infinity
        for h in faceHistory where h.t >= t - Self.seatPlateauSeconds {
            lo = min(lo, h.v)
            hi = max(hi, h.v)
        }
        return hi - lo <= Self.seatPlateauRange
    }

    private func maxSeconds(_ ex: Excursion) -> Double {
        Self.maxRepSeconds + (ex.challenge == nil ? 0 : Self.challengeExtraSeconds)
    }

    /// Volvió sentado y quieto: decide si el intento cuenta. El asiento del próximo intento: la cara donde se
    /// sentó (sube como mucho `seatCreepMax` por rep) y el agarre del inicio de esta rep, hasta que el refresco
    /// sentado lo actualice (al confirmar, el tronco todavía se endereza y el teléfono va 5 cm más abajo).
    /// `reanchored`: quedó quieto fuera de la banda (suspendido sobre la silla u origen corrido) y se re-ancló.
    private mutating func complete(_ ex: Excursion, seatedAt: Double, _ r: Reading, at t: Double,
                                   movedSeat: Bool = false, reanchored: Bool = false, _ events: inout [VerifierEvent]) {
        excursion = nil
        let ceiling = ex.seat.faceY + Self.seatCreepMax
        if let face = r.face {
            var seat = ex.seat
            // Más abajo que el asiento sin haberse sentado (reclinada, de lado): esa posición no es el asiento, o la
            // bajada siguiente parecería vertical.
            let lowNotSeat = face.y < ex.seat.faceY - Self.seatSinkMax && !Self.isSitDown(from: ex.seat, to: face)
            if ex.stood {
                if !lowNotSeat { seat.faceXZ = face.xz }
                if reanchored {
                    reanchorCount += 1
                    seat = Self.pose(r, face, fallbackForward: ex.seat.forward)
                } else {
                    // Entre `seatSinkMax` bajo y `seatCreepMax` sobre el asiento anterior: una vez desplomado no
                    // deja la banda abajo, y sentarse cada vez más alto no la sube.
                    seat.faceY = min(max(face.y, ex.seat.faceY - Self.seatSinkMax), ceiling)
                }
            } else {
                // Sin pararse la persona no dejó la silla: la altura de la cara sigue en su asiento (solo puede
                // haber bajado, y no más que `seatSinkMax` salvo un salto vertical del origen: reclinada o
                // inclinada de lado no es el asiento); la posición, donde quedó (se acomodó, o el VIO corrió el
                // origen); el teléfono, donde lo dejó.
                seat = Self.pose(r, face, fallbackForward: ex.seat.forward)
                seat.faceY = min(face.y, ex.seat.faceY)
                if lowNotSeat {
                    seat.faceY = ex.seat.faceY - Self.seatSinkMax
                    seat.faceXZ = ex.seat.faceXZ
                }
            }
            setSeat(seat, known: ex.stood, ceiling: reanchored ? nil : ceiling)
        } else {
            setSeat(ex.seat)
        }
        guard ex.stood else {
            closeAttempt(ex, at: t, &events)
            return
        }
        let duration = seatedAt - ex.startT
        if let reason = rejection(for: ex, duration: duration) {
            reject(reason, at: t)
            logAttempt(ex, at: t, rep: nil, rejection: reason, seatHold: t - (ex.seatConfirmedAt ?? t))
            switch reason {
            case .tooFast: cue(SitStandCopy.tooFast, "tortoise", &events)
            case .tooSlow: cue(SitStandCopy.tooSlow, "clock", &events)
            case .faceNotSeen: cue(SitStandCopy.faceLost, "face.dashed", &events)
            case .notLive: cue(SitStandCopy.notLive, "face.dashed", &events)
            case .flatFace:
                flatFaceCount += 1
                record(Anomaly(kind: SitStandAnomaly.flatFace, severity: flatFaceCount >= Self.flatFaceHardCount ? .hard : .soft,
                               at: t - t0, detail: "Cara sin relieve 3D: foto o pantalla"), &events)
                cue(SitStandCopy.notLive, "face.dashed", &events)
            case .phoneTilted: cue(SitStandCopy.phoneTilted, "iphone", &events)
            case .noTravel: cue(SitStandCopy.noTravel, "figure.stand", &events)
            case .torsoOnly:
                let detail = leanedSideways(ex)
                    ? String(format: "Se enderezó de lado: cara %.0f cm corrida, alabeo %.0f°", ex.peakLateral * 100, ex.peakRollDelta)
                    : sitUpFromRecline(ex)
                    ? String(format: "Se enderezó desde reclinado: la cara avanzó %.0f cm al subir", (ex.peakRiseForward ?? 0) * 100)
                    : "Se enderezó sin pararse"
                record(Anomaly(kind: SitStandAnomaly.torsoOnly, severity: .soft, at: t - t0, detail: detail), &events)
                cue(SitStandCopy.torsoOnly, "figure.stand", &events)
            case .partial:
                cue(SitStandCopy.partial, "arrow.up", &events)
            case .armsOnly:
                if !ex.armsReported { reportArms(gap: ex.maxRiseGap, drift: ex.maxFaceInPhoneShift, at: t, &events) }
            case .holdChallengeFailed, .interrupted:
                break // ya avisado en el momento
            }
            return
        }

        progress.count += 1
        if stepsAtFirstRep == nil { stepsAtFirstRep = ex.stepsAtStart ?? lastSteps }
        repSeconds.append(duration)
        countedFaceRises.append(ex.maxFaceRise)
        maxCountedRise = max(maxCountedRise ?? ex.maxRise, ex.maxRise)
        if ex.challenge != nil { challengePassed = true }
        logAttempt(ex, at: t, rep: progress.count, rejection: nil, seatHold: t - (ex.seatConfirmedAt ?? t))
        events.append(.rep(progress.count))
        events.append(.progress(progress.fraction))
        // El ritmo se mide al sentarse (no al contar): el desafío sentado retrasa el conteo, no el movimiento.
        if let anomaly = regularity.recordRep(at: seatedAt - t0) { record(anomaly, &events) }
        if progress.count >= spec.target {
            checkStepsPerRep(at: t, &events)
            phase = .done
            events.append(.completed)
        }
    }

    private func rejection(for ex: Excursion, duration: Double) -> Rejection? {
        if duration < Self.minRepSeconds { return .tooFast }
        if duration > maxSeconds(ex) { return .tooSlow }
        if ex.armsOnRep { return .armsOnly }
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
        if leanedSideways(ex) || sitUpFromRecline(ex) { return .torsoOnly }
        if let forward = ex.peakFaceForward, forward < -Self.maxBackShift { return .torsoOnly }
        if ex.challenge == .stand, !ex.holdDone { return .holdChallengeFailed }
        if let usual = usualFaceRise, ex.maxFaceRise < Self.relativeRiseFraction * usual { return .partial }
        return nil
    }

    /// Arriba la cara quedó corrida de lado o el teléfono girado de lado: se enderezó de una inclinación lateral.
    private func leanedSideways(_ ex: Excursion) -> Bool {
        ex.peakLateral > Self.maxPeakLateral || ex.peakRollDelta > Self.maxPeakRollDeltaDeg
    }

    /// Del despegue al pico la cara avanzó más de lo que avanza al pararse: se enderezó desde reclinado.
    private func sitUpFromRecline(_ ex: Excursion) -> Bool {
        (ex.peakRiseForward ?? 0) > Self.maxRiseForward
    }

    /// Mediana de la subida de la cara en las reps contadas (desde `relativeRiseMinReps`): la de ESTA persona.
    private var usualFaceRise: Double? {
        guard countedFaceRises.count >= Self.relativeRiseMinReps else { return nil }
        let sorted = countedFaceRises.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Intento que nunca llegó de pie: brazos, inclinarse (tronco), quedarse a medias o acomodarse.
    private mutating func closeAttempt(_ ex: Excursion, at t: Double, _ events: inout [VerifierEvent]) {
        // El teléfono llegó arriba (≥ `standRise`) pero la cara no: brazos.
        if ex.armsFlag, ex.maxRise >= Self.standRise {
            if !ex.armsReported { reportArms(gap: ex.maxRiseGap, drift: ex.maxFaceInPhoneShift, at: t, &events) }
            reject(.armsOnly, at: t)
            logAttempt(ex, at: t, rep: nil, rejection: .armsOnly)
            return
        }
        // Inclinarse adelanta la cara Y la baja (40° de tronco: 45 cm y 21 cm). Un corrimiento horizontal sin
        // bajar es el VIO asentándose o acomodarse en la silla, no una inclinación.
        let forward = ex.maxFaceAhead >= Self.torsoMinHorizontal && ex.minFaceRise < -Self.torsoMinDrop
        let dropped = ex.minFaceRise < -Self.torsoMaxDrop
        let leaned = ex.maxFaceShift >= Self.torsoMinHorizontal
            && ex.maxFaceShift > Self.torsoHorizontalRatio * ex.maxFaceLift
        let walked = ex.maxFaceShift > Self.torsoMaxReach
        if forward, !walked, dropped || leaned {
            reject(.torsoOnly, at: t)
            logAttempt(ex, at: t, rep: nil, rejection: .torsoOnly)
            record(Anomaly(kind: SitStandAnomaly.torsoOnly, severity: .soft, at: t - t0,
                           detail: dropped ? String(format: "Cara %.0f cm más abajo, adelantada", -ex.minFaceRise * 100)
                                           : "Se inclinó sin pararse"), &events)
            cue(SitStandCopy.torsoOnly, "figure.stand", &events)
        } else if ex.maxFaceRise >= Self.partialFaceRise {
            reject(.partial, at: t)
            logAttempt(ex, at: t, rep: nil, rejection: .partial)
            cue(SitStandCopy.partial, "arrow.up", &events)
        } else {
            // Acomodarse en la silla o mover el teléfono: sin aviso.
            logAttempt(ex, at: t, rep: nil, rejection: nil)
        }
    }

    /// Fuera del asiento pero quieto y sentado derecho sobre la silla: empezó de pie y se sentó, se sentó más
    /// alto o más bajo, o ARKit retomó con el origen corrido (poca luz). Nuevo asiento.
    /// `afterBlock`: tras un bloqueo de tracking el origen pudo correrse también en horizontal; pasados
    /// `reseatShiftedSeconds` no se exige que la cara vuelva al ancla.
    /// `standingFrom`: el asiento visto desde donde la cara estuvo a su altura por última vez (caminó hasta la silla).
    private mutating func reseatIfNeeded(_ r: Reading, at t: Double, afterBlock: Bool = false, standingFrom: Reference? = nil,
                                         _ events: inout [VerifierEvent]) -> Bool {
        guard let ref = reference, let face = r.face, r.faceStill != nil || facePlateau(at: t) else {
            if r.face == nil { lowStillSince = nil }
            return false
        }
        let plateau = facePlateau(at: t)
        let still = r.faceStill == true || plateau
        let from = standingFrom ?? ref
        let faceRise = face.y - ref.faceY
        let notStanding = faceRise < Self.holdStandFraction * Self.minFaceRise
        // Empezó de pie: la cara bajó a una silla (sin adelantarse) desde donde estaba de pie.
        let satFromStanding = faceRise <= -Self.minFaceRise
        // Bajar el asiento exige que la cara baje más de lo que se mueve en horizontal (sentarse, no reclinarse).
        let seatedLike = isSeatedLike(r, face, from, anchor: from.faceXZ) && (!satFromStanding || Self.isSitDown(from: from, to: face))
        let shifted = afterBlock && notStanding && isSeatedLike(r, face, ref, anchor: nil)
        let outOfSeat = faceRise > (afterBlock ? Self.seatCreepMax : Self.seatFaceBand) || satFromStanding
        guard outOfSeat, still, seatedLike || shifted else {
            lowStillSince = nil
            return false
        }
        let since = plateau ? min(lowStillSince ?? t, t - Self.seatPlateauSeconds) : (lowStillSince ?? t)
        lowStillSince = since
        let needed = satFromStanding && !seatKnown && seatedLike ? Self.firstSeatSeconds
            : seatedLike ? Self.reseatSeconds : Self.reseatShiftedSeconds
        guard t - since >= needed else { return false }
        if let ex = excursion { logAttempt(ex, at: t, rep: nil, rejection: nil) }
        reanchored(Self.pose(r, face, fallbackForward: ref.forward), &events)
        return true
    }

    /// Bajada del asiento que es sentarse de verdad (o un salto vertical del origen de ARKit): la cara baja más de lo
    /// que se mueve en horizontal (`sitDownMaxShiftRatio`). Reclinarse en el respaldo o inclinarse de lado no.
    private static func isSitDown(from seat: Reference, to face: FaceReading) -> Bool {
        let drop = seat.faceY - face.y
        return drop > 0 && norm(face.xz - seat.faceXZ) <= sitDownMaxShiftRatio * drop
    }

    /// Asiento nuevo fuera de la banda: se avisa que ya puede pararse.
    private mutating func reanchored(_ seat: Reference, _ events: inout [VerifierEvent]) {
        reanchorCount += 1
        setSeat(seat, known: true)
        cue(SitStandCopy.reseated, "checkmark.circle.fill", &events)
    }

    /// Sentado derecho sobre la silla: la cara no adelantada respecto de `anchor` (de vuelta sobre la silla, no
    /// de pie sobre los pies ni inclinada). `anchor == nil` (origen corrido en horizontal): sin esa prueba, se
    /// exige además el agarre del inicio del intento (cabeceo y cara-teléfono): bajar o subir el teléfono con
    /// los brazos no re-ancla.
    private func isSeatedLike(_ r: Reading, _ face: FaceReading, _ ref: Reference, anchor: SIMD2<Double>?) -> Bool {
        guard let anchor else {
            return abs(AngleMath.delta(r.pitch, ref.pitch)) < Self.reseatMaxPitchDeltaDeg
                && Self.norm(face.inPhone - ref.faceInPhone) < Self.reseatMaxFaceInPhoneShift
        }
        return ahead(face.xz, from: anchor, ref) < Self.reseatMaxForward
    }

    // MARK: Desafío, anomalías, rechazos y diagnóstico

    private func cue(_ text: String, _ symbol: String, _ events: inout [VerifierEvent]) {
        events.append(.cue(Cue(text: text, symbol: symbol)))
    }

    private mutating func failChallenge(at t: Double, _ events: inout [VerifierEvent]) {
        challengeFailures += 1
        let hard = challengeFailures >= Self.holdFailHardCount
        let what = challenge.kind == .stand ? "de pie" : "sentado"
        record(Anomaly(kind: SitStandAnomaly.holdChallengeFailed, severity: hard ? .hard : .soft, at: t - t0,
                       detail: "No se quedó \(what) lo pedido (intento \(challengeFailures))"), &events)
        if hard { challengeRetired = true }
        cue(hard ? SitStandCopy.holdGiveUp : SitStandCopy.holdFailed, "timer", &events)
    }

    private mutating func reportArms(gap: Double, drift: Double, at t: Double, _ events: inout [VerifierEvent]) {
        armsCount += 1
        let hard = armsCount >= Self.armsHardCount
        record(Anomaly(kind: SitStandAnomaly.armsOnly, severity: hard ? .hard : .soft, at: t - t0,
                       detail: String(format: "Cara desfasada %.0f cm; cara-teléfono %.0f cm", gap * 100, drift * 100)),
               &events)
        cue(SitStandCopy.armsOnly, "figure.stand", &events)
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

    /// Anota las medidas de un intento cerrado.
    private mutating func logAttempt(_ ex: Excursion, at t: Double, rep: Int?, rejection: Rejection?, seatHold: Double = 0) {
        let faces = Double(max(1, ex.faceSamples))
        attempts.append(AttemptRecord(
            index: attempts.count + 1, start: ex.startT - t0, end: t - t0,
            seatPhoneY: ex.seat.phoneY, seatFaceY: ex.seat.faceY,
            phoneRise: ex.maxRise.isFinite ? ex.maxRise : 0, faceRise: ex.maxFaceRise.isFinite ? ex.maxFaceRise : 0,
            faceDrop: ex.minFaceRise.isFinite ? max(0, -ex.minFaceRise) : 0,
            riseGap: ex.maxRiseGap.isFinite ? ex.maxRiseGap : 0, faceInPhoneShift: ex.maxFaceInPhoneShift,
            faceTravel: ex.maxFaceShift, peakForward: ex.peakFaceForward, peakLateral: ex.peakLateral,
            riseForward: ex.peakRiseForward,
            pitchDelta: ex.maxPitchDelta, peakPitchDelta: ex.peakPitchDelta, rollDelta: ex.maxRollDelta,
            peakRollDelta: ex.peakRollDelta,
            standSeconds: ex.standSeconds, seatHoldSeconds: max(0, seatHold),
            liveFraction: Double(ex.liveSamples) / faces, flatFraction: Double(ex.flatSamples) / faces,
            challenge: ex.challenge, stood: ex.stood, rep: rep, rejection: rejection))
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

/// Las medidas de cada intento (rep contada o rechazada) van al registro del teléfono.
extension SitToStandVerifier: AttemptDiagnosticsProviding {
    var attemptCount: Int { attempts.count }
    func attemptLine(_ index: Int) -> String { attempts[index].description }
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
    /// Cabeceo extra del teléfono por las muñecas (cambiar el agarre sentado), grados.
    var gripPitch: Double = 0
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

    /// Se para desde la postura actual (la cadera puede estar más abajo o adelante: cojín, profundidad) hasta
    /// `rise` / `forward` sobre el asiento. `armsTo`: lleva los brazos a esa altura mientras sube (del regazo al
    /// pecho), al ritmo de la cadera.
    mutating func standUp(seconds: Double, rise: Double, forward: Double, leanDeg: Double, armsTo: Double? = nil) {
        let n = frames(seconds)
        let h0 = hipRise, f0 = hipForward, a0 = armsLift
        for i in 1...n {
            let u = Double(i) / Double(n)
            lean = leanDeg * (u < 0.4 ? (1 - cos(.pi * u / 0.4)) / 2 : (1 + cos(.pi * (u - 0.4) / 0.6)) / 2)
            let k = Self.smoothstep((u - 0.35) / 0.65)
            hipRise = h0 + (rise - h0) * k
            hipForward = f0 + (forward - f0) * Self.smoothstep((u - 0.2) / 0.8)
            if let armsTo { armsLift = a0 + (armsTo - a0) * k }
            standing = u > 0.7
            emit()
        }
        lean = 0
    }

    /// Se sienta hasta `toHip` / `toForward` (0 = el asiento de siempre; < 0 el cojín cede, > 0 más adelante en
    /// la silla). `armsTo`: deja el teléfono a esa altura de brazos al sentarse (en el regazo).
    mutating func sitDown(seconds: Double, leanDeg: Double, toHip: Double = 0, toForward: Double = 0, armsTo: Double? = nil) {
        let n = frames(seconds)
        let rise0 = hipRise, forward0 = hipForward, a0 = armsLift
        for i in 1...n {
            let u = Double(i) / Double(n)
            lean = leanDeg * (1 - cos(2 * .pi * u)) / 2
            hipRise = toHip + (rise0 - toHip) * (1 - Self.smoothstep(u / 0.85))
            hipForward = toForward + (forward0 - toForward) * (1 - Self.smoothstep(u))
            if let armsTo { armsLift = a0 + (armsTo - a0) * Self.smoothstep(u) }
            standing = u < 0.3
            emit()
        }
        lean = 0
        standing = false
    }

    /// Empieza de pie frente a la silla (la cadera arriba y adelante, sobre los pies).
    mutating func startStanding(rise: Double = Rep().rise, forward: Double = Rep().forward) {
        hipRise = rise
        hipForward = forward
        standing = true
    }

    /// Lleva la postura a otra en `seconds` (perfil suave): agarre del teléfono (brazos, alcance, cabeceo de las
    /// muñecas), profundidad en la silla o el cojín que cede. `nil` = la deja como está.
    mutating func shift(seconds: Double, hip: Double? = nil, forward: Double? = nil, arms: Double? = nil,
                        reach: Double? = nil, gripPitchDeg: Double? = nil) {
        let h0 = hipRise, f0 = hipForward, a0 = armsLift, r0 = armsForward, g0 = gripPitch
        let n = frames(seconds)
        for i in 1...n {
            let u = Self.smoothstep(Double(i) / Double(n))
            hipRise = h0 + ((hip ?? h0) - h0) * u
            hipForward = f0 + ((forward ?? f0) - f0) * u
            armsLift = a0 + ((arms ?? a0) - a0) * u
            armsForward = r0 + ((reach ?? r0) - r0) * u
            gripPitch = g0 + ((gripPitchDeg ?? g0) - g0) * u
            emit()
        }
    }

    /// Se mece sentado adelante y atrás (juntando impulso), `amplitudeDeg` de tronco a `hz`.
    mutating func rock(seconds: Double, amplitudeDeg: Double, hz: Double) {
        let start = t
        for _ in 0..<frames(seconds) {
            lean = amplitudeDeg * sin(2 * .pi * hz * (t - start))
            emit()
        }
        lean = 0
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

        let pitch = body.phonePitchDeg + gripPitch + body.pitchFollow * lean + rng.symmetric(noise.angleJitterDeg)
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
