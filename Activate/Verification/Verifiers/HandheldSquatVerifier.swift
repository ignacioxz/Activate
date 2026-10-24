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
// - Rep = el CUERPO baja ≥ 9 cm (sentadillas de 10 a 90 cm) y vuelve: para entrar cuenta el MENOR de los
//   descensos (teléfono y cara) y para salir el MAYOR, con un recorrido mínimo desde donde estaba de pie.
//   Los brazos no aportan: bajar el teléfono con los brazos deja la cara arriba (`armsOnly`); un cuarto de
//   sentadilla más brazos, o quedarse abajo bombeando el teléfono, no llega o no vuelve. Sin cara visible no
//   se entra ni se sale de la rep.
// - Las medidas horizontales (avance, atrás, de lado, recorrido) se toman desde el ANCLA de la rep (la cara
//   en su punto más alto justo antes de bajar), no desde la calibración: correrse de lugar entre reps o
//   inclinarse un poco antes de bajar no es trampa.
// - Anti-inclinarse (`HingeModel`): el giro del tronco se estima con lo que la cabeza mira más abajo (menos lo que
//   solo siguió al teléfono que cae, si el teléfono giró con el tronco) o lo que el teléfono cabecea, desde la
//   inclinación que ya traía al calibrar (cabeza muy abajo o teléfono muy acostado). Ese giro explica una parte
//   del descenso de la cara; las rodillas deben aportar el resto (≥ 8,5 cm y ≥ 40 %). Y la cara no puede avanzar
//   más de lo que permite una sentadilla (margen + la mitad de lo que bajó) salvo que el giro A LA VISTA lo
//   explique: si se esconde el giro (cuello que compensa, teléfono frente a la cara), mecerse sentado o bajar un
//   escalón hacia adelante avanzan de más. Si no → `torsoBend`. Para calibrar hay que estar con la cabeza
//   razonablemente derecha (≤ 50°, no sentado y doblado); subir a la cabina obliga a recalibrar.
// - Anti-escalón: la cara no puede irse atrás ni de lado (bajar de espaldas o de lado un escalón).
// - Persona viva: la cara debe tener micro-expresiones (`shapeEnergy`) y RELIEVE 3D en la TrueDepth;
//   una foto o una pantalla pegada al teléfono es un plano (< 8 mm) → `static` / `flatFace`. Sin una cara 3D
//   CONFIRMADA en la serie (sin profundidad) o con la cara inmóvil respecto del teléfono en todas las reps
//   (montaje pegado), la serie no llega a full.
// - Desafío: en una rep al azar aparece "Quédese abajo 2 segundos" (la vista lo muestra mientras esté armado,
//   con la barra de la pausa en `progress.live`); un vídeo o un mecanismo no lo sigue. Fallarlo solo es hard con
//   otra señal de trampa; con la cara 3D confirmada no baja el nivel (el usuario real casi nunca se quedaba abajo).
// - Sacudir = OSCILAR (muchas inversiones del movimiento por segundo que mueven de verdad el teléfono,
//   `OscillationDetector`), no "mucha aceleración": una sentadilla rápida y honda es una sola bajada suave y
//   cuenta, y el temblor de la mano (mm a 6-9 Hz) no mueve el teléfono. Ritmo de metrónomo y caminar →
//   anomalías. Altímetro como apoyo (escalera / ascensor).
// - Teléfono volteado o bajado hacia los muslos (cabeceo ≫ y la cara no bajó con él) → `phoneTilted`.
// - Sin seguimiento del mundo (cámara trasera tapada, equipo sin soporte): respaldo con la aceleración
//   vertical integrada para el teléfono (con el signo que entrega la fuente, aprendido del mundo cuando se ve) y,
//   para la CARA, su altura sobre el teléfono medida por la TrueDepth proyectada sobre la gravedad
//   (`HandheldSquatGeometry.faceAbovePhone`): bajar el teléfono con los brazos (recto o en arco hacia el cuerpo)
//   sube la cara en esa proyección y no entra. Sin el mundo no se ve el avance de la cara: se cuentan menos de la
//   mitad de las reps de la meta (pide "Sin tapar la cámara de atrás."), desde 16 cm, y el nivel de la fuente
//   baja a `.fallback` (reduced) aunque el resto fuera en vivo.
// - Postura de pie que cambia de lugar (se baja de la solera, baja una escalera): la referencia se
//   re-ancla cuando queda quieto ahí, con la cabeza y el teléfono como al calibrar y desplazado en
//   horizontal al menos lo que bajó (sentarse no es "otro lugar de pie"). No se re-ancla en el fondo de una
//   sentadilla (la pausa del desafío). Quedar un poco más abajo entre reps no la mueve: la rep se mide
//   desde donde empezó a bajar.

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
    /// Cabeceo de la CABEZA respecto de la gravedad (°): elevación del eje que sale de la cara (+Z del
    /// `ARFaceAnchor`). 0 = mira al horizonte, negativo = la cara apunta hacia abajo. nil sin cara.
    var headPitchDeg: Double? = nil
    /// Relieve 3D de la cara en el mapa de profundidad TrueDepth (m, ver `FaceReliefEstimator`): una cara
    /// real ≈ 1 cm, una foto o una pantalla ≈ 0. nil si este frame no trae profundidad utilizable.
    var faceRelief: Float? = nil
    /// Cabeceo de la cara respecto del teléfono (°): elevación de la mirada de la cara en el mundo (eje +z de
    /// `ARFaceAnchor`, hacia afuera de la cara) + cabeceo del teléfono. No cambia si cabeza y teléfono giran
    /// juntos (el tronco); sube si la cabeza se echa atrás más que el teléfono y baja si el teléfono gira y la
    /// cabeza no. nil sin cara o sin deviceMotion. Lo usa la extensión lumbar (no depende del mundo).
    var faceRelPitchDeg: Double? = nil
}

// MARK: - Umbrales (constantes nombradas; se calibran en el iPhone con el texto de depuración de la demo)

/// Valores más tolerantes (pedido del usuario tras probar en el iPhone: exigía la espalda muy derecha y no
/// mover el teléfono; después "amplía el rango de los 15 cm"). El anti-fraude principal sigue siendo que la
/// CARA baje con el cuerpo, la cara viva (micro-expresiones y relieve TrueDepth) y el desafío "Quédese abajo
/// 2 segundos". Calibrados con 59 intentos honestos reales (iPhone 17 Pro Max, 6 series: 17-83 cm, 0,9-4,8 s; ver
/// `RealSquatReplayTests`) y el modelo físico de `HandheldSquatAttackTests` (red team: cabina, bisagra, brazos,
/// escalón, foto/video, respaldo IMU).
nonisolated enum HandheldSquatTuning {
    // Calibración de pie
    /// Segundos de pie, quieto y con la cara visible para fijar la referencia.
    static let calibrationSeconds = 1.0
    /// Quieto = el teléfono no varía más que esto en altura / en horizontal (m) ni en cabeceo (°).
    static let calibrationMaxPhoneRangeY = 0.05
    static let calibrationMaxPhoneDriftXZ = 0.08
    static let calibrationMaxPitchRange = 10.0
    /// Quieto en respaldo: media de |aceleración vertical| (m/s²), |media| (m/s², lo que cambiaría la velocidad en el
    /// segundo) y RMS medio de userAccel (g). Reales de pie con el teléfono en las manos: |a| p50 0,1-0,34 y p90
    /// 0,6-2,2 m/s², RMS p50 0,02-0,12 g (con 0,45 m/s² y 0,08 g por muestra una serie real nunca calibraba).
    static let calibrationMaxVerticalAccel = 0.8
    static let calibrationMaxMeanVerticalAccel = 0.2
    static let calibrationMaxAccelRMS = 0.2
    /// Si el seguimiento del mundo nunca llega a `.normal` en este tiempo, se usa el respaldo IMU.
    static let initialWorldGraceSeconds = 3.0
    /// Cabeza razonablemente derecha para calibrar: |cabeceo de la cabeza| ≤ esto (°). Real de pie: −23..+11°;
    /// con lentes de lectura ≈ −45°; sentado a 40° con la cabeza siguiendo al tronco ≈ −68° (no calibra).
    static let calibrationMaxHeadPitch = 50.0

    // Señal y repetición
    /// Suavizado exponencial por muestra (≈ 60 Hz).
    static let emaAlpha = 0.3
    /// Entrar: el cuerpo (el menor entre teléfono y cara) baja ≥ esto (m); una sentadilla de 10 cm cuenta.
    static let enterDescent = 0.09
    /// Entrar en el respaldo IMU (m): sin el mundo no se ve el avance de la cara, y mecerse sentado desde 0-20° baja la
    /// cara 6-15 cm; las sentadillas reales bajan 17-85 cm (la integración lee 1-3 cm menos). Las más cortas piden bajar
    /// más o destapar la cámara.
    static let inertialEnterDescent = 0.16
    /// Salir: el mayor de los descensos vuelve a < esto (m); entre reps la persona no siempre se endereza del todo.
    static let exitDescent = 0.07
    /// Recorrido mínimo de la rep desde el nivel en que estaba antes de bajar (m): oscilar en un cuarto de sentadilla no es rep.
    static let minRepExcursion = 0.08
    /// La ventana de la rep se abre cuando el teléfono o la cara bajan más de esto (m).
    static let windowStartDescent = 0.03
    /// La rep empieza en el último instante a menos de esto (m) del mínimo previo (con 1 cm el temblor de pie dejaba una rep real de 1,7 s en 7,8 s).
    static let repStartBand = 0.03
    /// Ancla de la rep: la cara en su punto más alto de estos últimos segundos antes de abrir la ventana (s).
    static let anchorLookbackSeconds = 1.5
    /// Duración mínima medida (s, desde 3 cm sobre el mínimo hasta volver): reales ≥ 0,92 s; una sentadilla de 1 s mide ≈ 0,77 s; el montaje sacudido ≈ 0,45 s.
    static let minRepSeconds = 0.7
    /// Duración máxima (s): Marco lento, 3 s abajo + 3 s arriba + la pausa.
    static let maxRepSeconds = 8.0
    /// Margen extra antes de abortar una rep que no vuelve (s).
    static let abortGraceSeconds = 2.0
    /// La referencia de pie se adapta lento entre reps (deriva del mundo, cambio de postura).
    static let referenceTimeConstant = 3.0
    /// Con la cara más de esto (m) SOBRE la referencia (subió a la cabina o a una plataforma) se vuelve a calibrar.
    static let climbRecalibrateRise = 0.15
    /// Re-anclaje: con la ventana abierta (o al abortarla por larga), si teléfono y cara llevan este tiempo
    /// quietos (rango de altura < `reanchorStillRange`) la referencia pasa a esa postura.
    static let reanchorStillSeconds = 1.0
    static let reanchorStillRange = 0.02
    static let reanchorMinWindowSeconds = 1.0
    /// Solo se re-ancla quieto si además cambió de lugar (la cara se desplazó en horizontal: bajó de la
    /// solera, bajó una escalera): una pausa a mitad de la bajada, o quedar un poco más abajo entre reps,
    /// no mueve la referencia (la rep se mide desde donde empezó a bajar). Con la rep ya entrada se exige
    /// más desplazamiento: una sentadilla con el tronco inclinado adelanta la cara hasta ≈ 20 cm.
    static let reanchorMinShift = 0.15
    static let reanchorMinShiftEntered = 0.25
    /// La postura nueva debe cabecear (cabeza, °) como la de pie calibrada: el fondo inclinado o sentado y doblado no re-ancla.
    static let reanchorMaxHeadDelta = 20.0
    /// Ídem con el cabeceo del teléfono (°): bajar una escalera o la solera mirando el teléfono no lo cambia.
    static let reanchorMaxPitchDelta = 20.0
    /// Re-anclar más abajo exige desplazarse en horizontal ≥ esta fracción de lo que bajó la cara (escalera 1,65; solera 2; sentarse 0,35-0,67).
    static let reanchorMinShiftPerDrop = 1.0
    /// Bajadas de la cara de hasta esto (m) re-anclan sin exigir desplazamiento (deriva del mundo, quedar un poco más abajo).
    static let reanchorFreeDrop = 0.12
    /// Cara perdida más de estos frames: los suavizados de la cara se reinician (sin arrastre al volver).
    static let faceResetAfterLostFrames = 3
    /// "Abajo" para medir brazos / inclinación / la pausa: fracción de `enterDescent`.
    static let bottomZoneFraction = 0.75
    /// Un intento que no entró pero subió y bajó al menos esto (m) recibe "Baje un poco más" (también la rep `shallow`).
    static let shallowCueDescent = 0.05

    // Anti-brazos
    /// Un intento que no entró (el cuerpo no bajó) es `armsOnly` si el teléfono bajó la meta y la cara
    /// quedó más de esto arriba (m).
    static let armsOnlyMaxGap = 0.12
    /// La cara debe haber bajado al menos esta fracción de la meta (si no, fueron los brazos); en el respaldo, por la TrueDepth y la gravedad.
    static let faceDescentMinFraction = 0.7
    /// La 3ª vez que baja solo con los brazos la anomalía pasa a hard.
    static let armsOnlyHardAt = 3

    // Teléfono fuera del pecho
    /// Cabeceo del teléfono (°) que, con el teléfono bajando más que la cara, es teléfono volteado hacia los muslos (real: 77-80°; sentadilla con tronco a 45°: 45°).
    static let phoneTiltMaxPitchDelta = 60.0

    // Anti-inclinarse (bisagra de cintura)
    /// Cabeceo del teléfono (°): con los antebrazos pegados al pecho gira con el tronco, que en una
    /// sentadilla parcial se inclina hasta ≈ 25-30°.
    static let torsoMaxPitchDelta = 50.0
    /// Cabeceo de la cabeza respecto de la gravedad (°) en el fondo.
    static let headMaxPitchDelta = 50.0
    /// Avance de la cara desde el ancla ≤ el MAYOR entre (margen + fracción de lo que bajó) y (esta parte del avance que
    /// explica el giro del tronco que se ve en la cabeza o el teléfono) (m). Reales: avance ≤ 0,53 × descenso (de 21 a
    /// 78 cm). Mecerse sentado da avance/descenso = cot(inclinación media): ≥ 0,9 desde 35° o menos; bajar un escalón
    /// hacia adelante, huella/alto ≥ 1. Con el giro a la vista (cabeza o teléfono) avanza más, pero entonces la bisagra
    /// descuenta lo que bajó por girar.
    static let torsoForwardSlack = 0.05
    static let torsoForwardRatio = 0.5
    static let hingeForwardCredit = 0.8
    /// La cara no puede irse atrás más que esto desde el ancla (m): bajar de espaldas un escalón la lleva 15-25 cm; real ≤ 6 cm.
    static let maxFaceBackwardShift = 0.12
    /// De lado: margen + fracción de lo que bajó (m); bajar de lado un escalón la corre 25 cm; real ≤ 9 cm.
    static let maxFaceLateralShift = 0.12
    /// Lo que se suma al margen lateral por metro que baja la cara (en una sentadilla honda el balanceo crece).
    static let lateralPerDescent = 0.10
    /// Distancia horizontal cara-teléfono mínima para saber hacia dónde mira (m).
    static let minFacingDistance = 0.05
    /// Máximo de anomalías `torsoBend` registradas (todas soft).
    static let torsoBendMaxRecorded = 5
    /// Bisagra (`HingeModel`): radio cadera-cara (m; adulto 0,60-0,70, se usa el largo para no subestimar el giro).
    static let hingeRadius = 0.65
    /// Cabeceo de la cabeza de pie mirando el teléfono (°): lo que pase de esto al calibrar es tronco ya inclinado.
    static let hingeNeutralHeadPitch = -40.0
    /// Descuento de la cabeza que sigue al teléfono: a lo sumo esta fracción del cabeceo de la cabeza y estos grados.
    static let hingeGazeDiscountFraction = 0.5
    static let hingeMaxGazeDiscount = 10.0
    /// ... y solo si el teléfono giró al menos esto (°) con el tronco.
    static let hingeGazeMinPhoneTurn = 5.0
    /// Cabeceo del teléfono de pie (°, pantalla hacia arriba): lo que pase de esto al calibrar es tronco ya inclinado
    /// con el teléfono pegado al pecho (sentado y doblado en la cabina). Real de pie 0-15°; modelo 40°.
    static let hingeNeutralPhonePitch = 50.0
    /// Inclinación de partida máxima que se infiere de la cabeza al calibrar (°).
    static let hingeMaxStartLean = 60.0
    /// Las rodillas deben aportar al menos esto del descenso de la cara en el fondo (m): una sentadilla de 10 cm aporta
    /// 9,5-10,5 (con lentes y el tronco a 20°, 9,1); 7 cm de rodillas + cabecear 3 cm + los brazos, 8; 6,5 + 4, 7;
    /// hundirse 3-7 cm en el asiento y mecerse, 3-7; mecerse sentado con la cabeza siguiendo al tronco, 4-6...
    static let hingeMinKneeDescent = 0.085
    /// ... y esta fracción: sentadilla con tronco a 45° ≈ 50 %, reales ≈ 95 %; mecerse sentado o bisagra a 45°, 13-38 %.
    static let hingeMinKneeFraction = 0.4
    /// En el respaldo IMU no hay avance de la cara (la otra barrera contra la bisagra): se exige la mitad.
    static let hingeMinKneeFractionInertial = 0.5
    /// "En el fondo" para la bisagra: muestras con la cara a ≥ esta fracción de su descenso máximo.
    static let hingeBottomFraction = 0.9

    // Persona viva
    /// Media de `shapeEnergy` bajo la cual la cara no tiene micro-expresiones (mismo umbral que el cuello).
    static let liveFaceMinEnergy = 0.002
    static let staticWindowSeconds = 2.0
    static let staticMinSamples = 20
    /// Relieve 3D (TrueDepth): mediana de las lecturas de los últimos segundos bajo esto (m) = plano.
    /// Ruido del sensor sobre una pantalla o una foto ≈ 1-3 mm; una foto curvada sobre la mano ≈ 6-7 mm; caras
    /// reales en el iPhone 17 Pro Max: p5 ≥ 1,07 cm y mediana 1,8-2,7 cm en todas las series.
    static let flatFaceMaxRelief = 0.008
    /// Una cara 3D CONFIRMADA en la serie (la ventana de relieve con lecturas suficientes y mediana sobre el umbral
    /// durante al menos esto, s). Sin confirmar (sin profundidad, o siempre plana) la serie no llega a full.
    static let reliefConfirmSeconds = 1.0
    /// Geometría cara-teléfono rígida: en una persona la cara se mueve respecto del teléfono ≥ 3,4 cm por rep
    /// (reales: mediana 8,8 cm); una foto o una pantalla pegada al teléfono, 1-2 mm. Si TODAS las reps contadas
    /// cambian menos que esto (m), la serie no llega a full.
    static let rigidFaceMaxGeometryChange = 0.015
    static let reliefWindowSeconds = 3.0
    static let reliefMinReadings = 8
    /// La rep no cuenta si al menos esta fracción de sus muestras con cara vio una cara plana.
    static let flatFaceRepFraction = 0.3
    /// La 3ª rep rechazada por cara plana registra `flatFace` hard.
    static let flatFaceHardAt = 3
    /// Cara perdida más de esto con el gate listo → bloqueado.
    static let faceLostBlockSeconds = 1.5
    /// Fracción mínima de muestras de la rep con la cara seguida.
    static let minTrackedFraction = 0.7
    /// Distancia cara-teléfono aceptada (m): con los brazos frente al pecho ≈ 30-55 cm.
    static let faceDistanceMin = 0.18
    static let faceDistanceMax = 0.9

    // Desafío de ritmo
    /// "Abajo" para el desafío (m de la señal del cuerpo): la misma zona del fondo, así sirve con la sentadilla más corta que cuenta.
    static var holdMinDescent: Double { bottomZoneFraction * enterDescent }
    /// Quedarse abajo = la altura varía a lo sumo esto (m, máx − mín) durante la pausa...
    static let holdBandMin = 0.03
    /// ... o esta fracción del descenso de la rep si es mayor: en una bajada de 60 cm la persona sube y baja unos cm mientras aguanta.
    static let holdBandFraction = 0.12
    /// Pausa pedida en las manos (s): la barra se llena y dice "Ya. Suba."; reps reales sin pausa ≤ 0,9 s, pausas reales 1,1-2,9 s.
    static let holdRequiredSeconds = 1.0
    /// Tiempo extra permitido a la rep del desafío.
    static let holdExtraSeconds = 4.0

    // Sacudidas, caminar, desplazamiento
    /// Bombeo fuerte para la anomalía hard (g de RMS de userAccel; lo comparte la extensión lumbar).
    static let shakingAccelRMS = 0.6
    /// La sacudida debe sostenerse esto (s) para la anomalía hard.
    static let shakingSustainSeconds = 0.8
    /// Inversión de la aceleración vertical: pasa de > +umbral a < −umbral o al revés (m/s²)...
    static let shakeAccelThreshold = 3.0
    /// ... con un cambio de velocidad de al menos esto en el medio ciclo (m/s): el temblor de la mano (1-3 mm a 6-9 Hz,
    /// operadores mayores, frío, cansancio) llega a ±5 m/s² pero no mueve el teléfono; sacudirlo de verdad, sí.
    static let shakeMinDeltaV = 0.4
    /// Inversión de la posición del teléfono en un eje del mundo: zigzag con esta histéresis (m).
    static let shakePositionHysteresis = 0.02
    /// Ventana para contar inversiones (s).
    static let shakeWindowSeconds = 1.0
    /// Inversiones en esa ventana que rechazan la rep: honestas reales ≤ 3 aunque lleguen a 0,8 g; sacudir a 3-8 Hz, 6-16.
    static let shakeMinReversals = 5
    /// Inversiones en 1 s para la anomalía hard (caminar rápido da 3-4,5 y no debe dejar la pausa sospechosa).
    static let shakeHardMinReversals = 6
    /// Bombeo fuerte sostenido (montaje sacudido a ≈ 1,5 Hz): ventana para contar sus inversiones (s)...
    static let shakeSustainedWindowSeconds = 1.5
    /// ... y cuántas, con RMS ≥ `shakingAccelRMS` (una sentadilla rápida por segundo da 3).
    static let shakeSustainedMinReversals = 4
    static let walkingSteps = 8
    /// Recorrido horizontal del teléfono desde el ancla ≤ esto + fracción de lo que bajó (m): real ≤ 25 cm con 54 cm de bajada.
    static let maxRepHorizontalTravel = 0.35
    /// Lo que se suma al recorrido permitido por metro que baja el teléfono (en una sentadilla honda los brazos se adelantan).
    static let travelPerDescent = 0.5

    // Seguimiento del mundo
    /// Pérdidas más cortas (poca luz, pared lisa) congelan la rep sin cambiar de modo ni recalibrar.
    static let worldLossToFallbackSeconds = 1.2
    /// La rep no cuenta si más de esta fracción de sus frames fue sin seguimiento del mundo.
    static let maxWorldLostFraction = 0.3
    static let worldRecoverSeconds = 1.0
    /// Salto imposible entre dos frames (relocalización del mundo).
    static let maxPhoneJumpPerFrame = 0.10
    static let worldJumpDebounceSeconds = 1.0
    /// Paso máximo de integración (una pausa del stream no se integra entera).
    static let maxIntegrationStep = 0.1

    /// Avisa "Sin tapar la cámara de atrás." si el mundo se pierde más que esto (s) con el gate listo (antes de
    /// pasar al respaldo): los dedos sobre la cámara trasera son la causa más común.
    static let worldLossCueSeconds = 0.5

    // Respaldo IMU (doble integración con corrección de velocidad cero)
    /// Signo con que llega `verticalAccel` mientras no se aprenda del mundo. `HandheldSquatSource` lo entrega hoy
    /// INVERTIDO (CoreMotion da `userAcceleration` opuesta a la aceleración física y la fuente resta su
    /// proyección sobre la gravedad): r ≈ −0,99 contra la aceleración vertical del mundo en todas las
    /// grabaciones reales del iPhone. Si se corrige la fuente, este valor pasa a +1 (con el mundo visible el
    /// verificador lo aprende solo, ver `AccelSignEstimator`).
    static let recordedAccelSign = -1.0
    /// Aprender el signo: ventanas de 0,4 s con un cambio de velocidad del mundo ≥ 0,2 m/s; 12 votos con |r| ≥ 0,7.
    static let accelSignWindowSeconds = 0.4
    static let accelSignMinDeltaV = 0.2
    static let accelSignMinVotes = 12
    static let accelSignMinCorrelation = 0.7
    /// Quieto para el ZUPT: |a vertical| suavizada < esto durante `zuptSeconds` (de pie con el teléfono en las manos el
    /// IMU real tiembla 0,2-1 m/s²: con 0,15 m/s² el ZUPT nunca llegaba y la altura integrada derivaba 30-50 cm)...
    static let zuptAccel = 0.4
    static let zuptSeconds = 0.3
    /// ... y con la velocidad integrada baja (o quieto mucho más): a mitad de una bajada lenta y honda (3 s, 45 cm)
    /// la aceleración pasa ≈ 0,6 s por cero a 0,28 m/s; el ZUPT la frenaba ahí y una sentadilla contaba dos veces.
    static let zuptMaxVelocity = 0.08
    /// Quieto así de largo corrige la deriva aunque la velocidad integrada no sea baja: fuera de la rep (tras una rep
    /// honda la velocidad residual de 0,1 m/s bajaba la altura integrada 20 cm y abría una rep fantasma) y dentro.
    static let zuptIdleSeconds = 0.6
    static let zuptLongSeconds = 2.0
    /// Suavizado de la aceleración para el ZUPT (el ruido real del IMU en las manos llega a 1-2 m/s² por muestra).
    static let zuptSmoothAlpha = 0.3
    /// Al quedar quieto tras subir al menos esta fracción del descenso, se da por arriba (corrige la deriva).
    static let fallbackSnapAscentFraction = 0.6
    /// Sin el mundo, una bajada del teléfono de más de esto (m) es un ascensor o una escalera: se pide destapar la
    /// cámara. Reales hasta 0,87 m; un piso de ascensor integra ≥ 3 m (sin ZUPT a mitad del viaje).
    static let maxInertialDescent = 1.0
    // Con la cámara trasera tapada se cuentan menos de la mitad de las reps (`HandheldSquatVerifier.inertialRepCap`):
    // el respaldo no ve el avance de la cara y, sentado en la cabina, no distingue la bisagra ni los baches del
    // camión de una sentadilla. La serie no se puede terminar sin destaparla.
    /// Cambio máximo del altímetro dentro de una rep en respaldo (m): más es un ascensor.
    static let maxRepAltitudeChange = 1.0
    /// Salida en el respaldo: la cara (teléfono − lo que subió sobre él) vuelve a ≤ `exitDescent` + esto (m)...
    static let inertialExitFaceSlack = 0.03
    /// ... o a ≤ esta fracción de su descenso máximo: tras reps hondas los brazos quedan 4-7 cm distintos respecto de la cara.
    static let inertialExitFaceFraction = 0.4

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
    static let bendKnees = "Doble más las rodillas."
    static let stayInPlace = "Quédese en su lugar."
    static let noShake = "No sacuda el teléfono."
    static let phoneAtChest = "Mantenga el teléfono frente al pecho."
    static let uncoverCamera = "Destape la cámara de atrás."
    static let lookAtScreen = "Mire la pantalla."
    static let standUp = "Párese derecho y mire el teléfono."
    /// Bajo la consigna del desafío (la vista): antes de la pausa, mientras se llena la barra.
    static let holdBar = "Abajo, quieto hasta llenar la barra."
    static let holdKeep = "Quieto…"
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
    static let flatFace = "flatFace"
    /// Señales de trampa que, sumadas a fallar el desafío, lo dejan en hard. Quedan fuera las que produce un
    /// operador honesto (tronco inclinado, salto del seguimiento, caminar entre reps, respaldo IMU).
    static let challengeCorroborating: Set<String> = [armsOnly, flatFace, staticFace, tooRegular, shaking]
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
/// cuenta si se mantiene lo pedido (1,5 s; la sentadilla en las manos usa `HandheldSquatTuning.holdRequiredSeconds`).
/// Fallarlo 2 veces → `holdChallengeFailed` (hard) y el desafío se cierra; la sentadilla en las manos lo baja a
/// soft si no hubo otra señal de trampa (y limita el nivel a reduced solo sin una cara 3D confirmada por la TrueDepth,
/// `HandheldSquatVerifier.limitedSourceLevel`).
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
        return currentCue
    }

    /// La consigna vigente del desafío (la primera vez o tras un fallo).
    var currentCue: Cue { failures == 0 ? copy.cue : copy.missedCue }

    /// La próxima `announcement` vuelve a entregar la consigna (al recalibrar otra consigna la tapó).
    mutating func allowReannouncement() { announcedForFailures = nil }

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

    var band: Double
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

/// Sacudir = OSCILAR: muchas inversiones del movimiento en poco tiempo. Una sentadilla, aun rápida y honda, es
/// UNA bajada suave (acelera hacia abajo, frena, acelera hacia arriba, frena: 2 inversiones de la aceleración
/// y 1-2 de la posición por rep). Cuenta, con su instante: (a) las inversiones de la aceleración vertical con
/// histéresis (de > +umbral a < −umbral y al revés; no depende del signo ni del seguimiento del mundo) y (b) los
/// giros en zigzag de la posición del teléfono en cada eje del mundo (sacudidas de lado o adelante-atrás que la
/// vertical no ve). Vale el mayor de los conteos.
nonisolated struct OscillationDetector: Sendable, Hashable {
    /// Zigzag con histéresis de una coordenada: cuenta los giros (el primer sentido no cuenta).
    nonisolated struct Zigzag: Sendable, Hashable {
        private var direction = 0
        private var high = 0.0
        private var low = 0.0
        private var started = false

        /// true si `x` completó un giro.
        mutating func add(_ x: Double, hysteresis h: Double) -> Bool {
            guard started else {
                started = true
                high = x
                low = x
                return false
            }
            switch direction {
            case 1:
                if x > high {
                    high = x
                } else if high - x > h {
                    direction = -1
                    low = x
                    return true
                }
            case -1:
                if x < low {
                    low = x
                } else if x - low > h {
                    direction = 1
                    high = x
                    return true
                }
            default:
                high = max(high, x)
                low = min(low, x)
                if high - x > h {
                    direction = -1
                    low = x
                } else if x - low > h {
                    direction = 1
                    high = x
                }
            }
            return false
        }

        mutating func reset() { self = Zigzag() }
    }

    /// Tiempo que se guardan los instantes (≥ la ventana más larga que se consulta).
    static let memorySeconds = 2.0

    private var accelSign = 0
    /// Cambio de velocidad (m/s) desde la última inversión: cuánto se movió de verdad en ese medio ciclo.
    private var lobe = 0.0
    private var lastAccelT: Double?
    private(set) var accelFlips: [Double] = []
    private var axes = [Zigzag](repeating: Zigzag(), count: 3)
    private(set) var turns: [[Double]] = [[], [], []]

    /// `position` = teléfono en el mundo (nil sin seguimiento del mundo: el zigzag se reinicia).
    mutating func add(t: Double, verticalAccel: Double?, position: SIMD3<Double>?) {
        if let a = verticalAccel {
            let dt = lastAccelT.map { min(HandheldSquatTuning.maxIntegrationStep, max(0, t - $0)) } ?? 0
            lastAccelT = t
            lobe += a * dt
            let threshold = HandheldSquatTuning.shakeAccelThreshold
            let sign = a > threshold ? 1 : (a < -threshold ? -1 : 0)
            if sign != 0, sign != accelSign {
                // Solo cuenta si el medio ciclo movió el teléfono (temblor de la mano: 1,5 mm a 9 Hz es ±4,8 m/s² pero
                // cambia la velocidad 0,13 m/s; sacudir 2 cm a 3,5 Hz, 0,85 m/s).
                if accelSign != 0, abs(lobe) >= HandheldSquatTuning.shakeMinDeltaV { accelFlips.append(t) }
                accelSign = sign
                lobe = 0
            }
        }
        if let position {
            for i in 0..<3 where axes[i].add(position[i], hysteresis: HandheldSquatTuning.shakePositionHysteresis) {
                turns[i].append(t)
            }
        } else {
            for i in 0..<3 { axes[i].reset() }
        }
        let horizon = t - Self.memorySeconds
        accelFlips.removeAll { $0 < horizon }
        for i in 0..<3 { turns[i].removeAll { $0 < horizon } }
    }

    /// Inversiones en los últimos `seconds` (el mayor entre la aceleración vertical y cada eje).
    func reversals(within seconds: Double, at t: Double) -> Int {
        let from = t - seconds
        var best = accelFlips.reduce(0) { $0 + ($1 > from ? 1 : 0) }
        for axis in turns { best = max(best, axis.reduce(0) { $0 + ($1 > from ? 1 : 0) }) }
        return best
    }
}

/// Geometría cara-teléfono respecto de la GRAVEDAD sin seguimiento del mundo. `faceInPhone` viene en el
/// espacio de la cámara frontal de ARKit (`camera⁻¹ · face`, espejado): x a lo largo del lado largo hacia el
/// borde inferior, y hacia la derecha de la pantalla, z hacia adentro del teléfono (la cara está en −z). El
/// cabeceo y el giro (`phonePitchDeg`, `phoneRollDeg`) salen de la gravedad de CoreMotion, que no depende de
/// la cámara trasera. Verificado con el iPhone 17 Pro Max contra la altura cara − teléfono del mundo: |error|
/// mediana 2-6 mm, p90 ≤ 1,1 cm (11 769 frames de cuatro series reales).
nonisolated enum HandheldSquatGeometry {
    /// Altura de la cara sobre el teléfono (m, + = la cara más arriba), solo con la TrueDepth y la gravedad.
    static func faceAbovePhone(faceInPhone f: SIMD3<Double>, pitchDeg: Double, rollDeg: Double) -> Double {
        let p = pitchDeg * .pi / 180, r = rollDeg * .pi / 180
        return -f.y * cos(p) * sin(r) - f.x * cos(p) * cos(r) - f.z * sin(p)
    }

    /// Inversa para muestras sintéticas: `world` = cara − teléfono en el mundo (Y arriba, la persona mira hacia
    /// −Z, el teléfono frente a ella con la pantalla hacia +Z), teléfono cabeceado `pitchDeg` (pantalla hacia
    /// arriba > 0) y sin giro. Devuelve la cara en el espacio de la cámara frontal de ARKit.
    static func faceInPhone(world v: SIMD3<Double>, pitchDeg: Double) -> SIMD3<Double> {
        let p = pitchDeg * .pi / 180
        let up = SIMD3<Double>(0, cos(p), -sin(p))      // borde superior del teléfono
        let out = SIMD3<Double>(0, sin(p), cos(p))      // sale de la pantalla hacia la persona
        let right = SIMD3<Double>(1, 0, 0)
        return SIMD3(-simd_dot(v, up), simd_dot(v, right), -simd_dot(v, out))
    }
}

/// Bisagra sobre la cadera: cuánto baja la cara solo por girar el tronco (radio cadera-cara) de `start` a
/// `start + lean` grados. Una sentadilla baja la cadera doblando las rodillas; mecerse sentado en la cabina o
/// doblarse de pie con las rodillas rectas solo gira el tronco. El giro se estima con el cabeceo de la cabeza
/// (gira con el tronco salvo que el cuello compense) o del teléfono (antebrazos pegados al pecho), y la
/// inclinación de partida con lo que la cabeza ya miraba hacia abajo al calibrar más allá de lo normal.
nonisolated enum HingeModel {
    /// Inclinación del tronco al calibrar (°): lo que la cabeza mira hacia abajo más allá de lo normal, o lo que el
    /// teléfono (antebrazos al pecho, gira con el tronco) está más acostado que lo normal; vale la mayor.
    static func startLean(referenceHeadPitch head: Double?, referencePitch pitch: Double? = nil) -> Double {
        let fromHead = head.map { HandheldSquatTuning.hingeNeutralHeadPitch - $0 } ?? 0
        let fromPhone = pitch.map { $0 - HandheldSquatTuning.hingeNeutralPhonePitch } ?? 0
        return min(HandheldSquatTuning.hingeMaxStartLean, max(0, fromHead, fromPhone))
    }

    /// Descenso de la cara explicado por el giro del tronco (m).
    static func drop(startLean: Double, lean: Double) -> Double {
        let a = startLean * .pi / 180, b = (startLean + max(0, lean)) * .pi / 180
        return HandheldSquatTuning.hingeRadius * (cos(a) - cos(b))
    }

    /// Cuánto más abajo se ve el teléfono desde la cara que en la postura de pie (°, + = más abajo), con la TrueDepth y
    /// la gravedad (vale en los dos modos). nil sin cara.
    static func gazeDown(reference ref: HandheldSquatVerifier.Reference, faceAbove: Double?, faceInPhone: SIMD3<Double>?) -> Double? {
        guard let above = faceAbove, let fip = faceInPhone else { return nil }
        func elevation(_ above: Double, _ distance: Double) -> Double {
            let horizontal = max(0.01, (max(0, distance * distance - above * above)).squareRoot())
            return atan2(-above, horizontal) * 180 / .pi
        }
        return elevation(ref.faceAbove, simd_length(ref.faceInPhone)) - elevation(above, simd_length(fip))
    }

    /// Avance de la cara explicado por el giro del tronco (m), sin contar la cadera que se va atrás.
    static func forward(startLean: Double, lean: Double) -> Double {
        let a = startLean * .pi / 180, b = (startLean + max(0, lean)) * .pi / 180
        return HandheldSquatTuning.hingeRadius * (sin(b) - sin(a))
    }

    /// Lo que deben aportar las rodillas (m): 8,5 cm y el 40 % del descenso de la cara (50 % sin el mundo).
    static func minKneeDescent(faceDescent: Double, inertial: Bool) -> Double {
        let fraction = inertial ? HandheldSquatTuning.hingeMinKneeFractionInertial : HandheldSquatTuning.hingeMinKneeFraction
        return max(HandheldSquatTuning.hingeMinKneeDescent, fraction * faceDescent)
    }
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
    private var smoothed: Double?

    mutating func reset() { self = InertialHeightTracker() }

    /// `anchorAllowed`: de pie entre reps (se puede re-anclar a 0). `inRep`: ya bajó la meta (a mitad de una bajada lenta
    /// la aceleración pasa mucho rato por cero con la velocidad alta: ahí solo un quieto muy largo es quieto).
    mutating func step(accel a: Double, dt: Double, t: Double, anchorAllowed: Bool, inRep: Bool = false) {
        velocity += a * dt
        position += velocity * dt
        let s = smoothed.map { $0 + HandheldSquatTuning.zuptSmoothAlpha * (a - $0) } ?? a
        smoothed = s
        if abs(s) < HandheldSquatTuning.zuptAccel {
            if quietSince == nil { quietSince = t }
        } else {
            quietSince = nil
        }
        // Empieza a moverse: la suavizada sube o la cruda pasa el doble del umbral (sin perder el arranque de la bajada).
        let moving = abs(s) >= HandheldSquatTuning.zuptAccel || abs(a) >= 2 * HandheldSquatTuning.zuptAccel
        if stationary, moving {
            stationary = false
            segmentStart = t
        }
        // Quieto de verdad: aceleración baja y además velocidad integrada baja, o quieto mucho rato (la deriva).
        let quietFor = quietSince.map { t - $0 } ?? 0
        let settled = abs(a) < 2 * HandheldSquatTuning.zuptAccel && quietFor >= HandheldSquatTuning.zuptSeconds
            && (abs(velocity) <= HandheldSquatTuning.zuptMaxVelocity
                || quietFor >= (inRep ? HandheldSquatTuning.zuptLongSeconds : HandheldSquatTuning.zuptIdleSeconds))
        if !stationary, settled {
            let segment = max(0, t - (segmentStart ?? t))
            position -= velocity * segment / 2
            velocity = 0
            stationary = true
        }
        if stationary {
            velocity = 0
            // De pie entre reps: cerca del origen, o MÁS ARRIBA (deriva; nadie queda 10 cm sobre su postura de pie),
            // vuelve al origen. Quieto más abajo no (un cuarto de sentadilla no puede volverse el cero).
            if anchorAllowed, position > -HandheldSquatTuning.exitDescent { position = 0 }
        }
    }

    /// Da por terminada la subida (deriva residual): vuelve al origen.
    mutating func snapToTop() {
        position = 0
        velocity = 0
    }
}

/// Signo de `verticalAccel` respecto de la aceleración física (+ arriba). Hasta aprenderlo vale
/// `HandheldSquatTuning.recordedAccelSign` (lo que entrega hoy la fuente); con el mundo siguiendo al teléfono se
/// compara, en ventanas de 0,4 s, el cambio de velocidad vertical del mundo con la integral de la aceleración
/// grabada. Con 12 ventanas con movimiento y |r| ≥ 0,7 el signo queda fijo para la serie. Así el respaldo IMU
/// integra bien con la fuente de hoy y con una fuente corregida.
nonisolated struct AccelSignEstimator: Sendable, Hashable {
    private nonisolated struct Point: Sendable, Hashable {
        var t: Double
        var y: Double
        var a: Double
    }

    private var points: [Point] = []
    private var lastVoteAt = -Double.infinity
    private var sxy = 0.0
    private var sxx = 0.0
    private var syy = 0.0
    private(set) var votes = 0
    private(set) var learned: Double? = nil

    var sign: Double { learned ?? HandheldSquatTuning.recordedAccelSign }

    /// `worldY` = altura del teléfono en el mundo (nil sin seguimiento normal).
    mutating func add(t: Double, worldY: Double?, accel: Double?) {
        guard learned == nil else { return }
        guard let y = worldY, let a = accel else {
            points = []
            return
        }
        if let last = points.last, abs(y - last.y) > HandheldSquatTuning.maxPhoneJumpPerFrame || t <= last.t { points = [] }
        points.append(Point(t: t, y: y, a: a))
        let span = 0.1, window = HandheldSquatTuning.accelSignWindowSeconds
        while points.count > 2, points[1].t <= t - window - 2 * span { points.removeFirst() }
        guard let first = points.first, t - first.t >= window + span, t - lastVoteAt >= window / 2 else { return }
        // Velocidad del mundo (promedio de 0,1 s) al final y al principio de la ventana.
        func velocity(endingAt end: Double) -> Double? {
            guard let j = points.lastIndex(where: { $0.t <= end }), let i = points.lastIndex(where: { $0.t <= end - span }),
                  points[j].t - points[i].t > span / 2 else { return nil }
            return (points[j].y - points[i].y) / (points[j].t - points[i].t)
        }
        guard let v1 = velocity(endingAt: t), let v0 = velocity(endingAt: t - window) else { return }
        let dvWorld = v1 - v0
        guard abs(dvWorld) >= HandheldSquatTuning.accelSignMinDeltaV else { return }
        // Integral de la aceleración entre los centros de las dos velocidades.
        var dvAccel = 0.0
        for k in 1..<points.count where points[k].t > t - window - span / 2 && points[k].t <= t - span / 2 {
            dvAccel += points[k].a * (points[k].t - points[k - 1].t)
        }
        lastVoteAt = t
        sxy += dvWorld * dvAccel
        sxx += dvWorld * dvWorld
        syy += dvAccel * dvAccel
        votes += 1
        guard votes >= HandheldSquatTuning.accelSignMinVotes, sxx > 0, syy > 0 else { return }
        let r = sxy / (sxx * syy).squareRoot()
        if abs(r) >= HandheldSquatTuning.accelSignMinCorrelation { learned = r > 0 ? 1 : -1 }
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

// MARK: - Relieve 3D de la cara (TrueDepth)

/// Relieve de la cara en el mapa de profundidad de la cámara frontal. Puro: recibe la profundidad (m) por
/// píxel ya leída del `AVDepthData` (lo hace `HandheldSquatRelay`) y se prueba con mapas sintéticos.
///
/// Toma la zona MÁS CERCANA del centro del mapa (quien sostiene el teléfono a 25-60 cm tiene la cara ahí),
/// le ajusta un plano por mínimos cuadrados y devuelve el residuo RMS (m). Una cara real tiene nariz,
/// cuencas y mejillas que se curvan hacia atrás (≈ 1 cm de residuo); una foto o la pantalla de otro
/// teléfono es un plano (solo el ruido del sensor, ≈ 1-3 mm). nil si no hay suficientes puntos válidos
/// (sol directo, vidrio que no devuelve el patrón infrarrojo): sin dato no se decide nada.
nonisolated enum FaceReliefEstimator {
    /// Paso de la grilla de muestreo (píxeles).
    static let gridStep = 6
    /// Fracción central del mapa que se mira (ancho y alto).
    static let centralFraction = 0.7
    /// Profundidades válidas (m): más cerca es un dedo sobre el lente; más lejos, el fondo.
    static let minDepth: Float = 0.15
    static let maxDepth: Float = 1.0
    /// Percentil de lo más cercano (la punta de la nariz o el borde de la foto) y espesor de la zona
    /// cercana: de la nariz a las mejillas (m).
    static let nearPercentile = 0.05
    static let nearSpan: Float = 0.06
    /// Puntos mínimos en la zona cercana.
    static let minPoints = 120

    /// `depthAt(x, y)` = profundidad en metros del píxel (NaN, 0 o negativo = sin dato).
    static func relief(width: Int, height: Int, depthAt: (Int, Int) -> Float) -> Float? {
        guard width > 2 * gridStep, height > 2 * gridStep else { return nil }
        let margin = (1 - centralFraction) / 2
        let x0 = Int(Double(width) * margin), x1 = Int(Double(width) * (1 - margin))
        let y0 = Int(Double(height) * margin), y1 = Int(Double(height) * (1 - margin))
        let scale = Float(max(width, height))
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(((x1 - x0) / gridStep + 1) * ((y1 - y0) / gridStep + 1))
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let z = depthAt(x, y)
                if z.isFinite, z >= minDepth, z <= maxDepth {
                    points.append(SIMD3(Float(x - width / 2) / scale, Float(y - height / 2) / scale, z))
                }
                x += gridStep
            }
            y += gridStep
        }
        guard points.count >= minPoints else { return nil }
        let depths = points.map(\.z).sorted()
        let near = depths[min(depths.count - 1, Int(Double(depths.count) * nearPercentile))]
        let cluster = points.filter { $0.z <= near + nearSpan }
        guard cluster.count >= minPoints else { return nil }
        return planeResidualRMS(cluster)
    }

    /// RMS del residuo del plano z = a·u + b·v + c ajustado por mínimos cuadrados.
    static func planeResidualRMS(_ points: [SIMD3<Float>]) -> Float? {
        guard points.count >= 3 else { return nil }
        let n = Double(points.count)
        var mu = 0.0, mv = 0.0, mz = 0.0
        for p in points {
            mu += Double(p.x)
            mv += Double(p.y)
            mz += Double(p.z)
        }
        mu /= n
        mv /= n
        mz /= n
        var suu = 0.0, suv = 0.0, svv = 0.0, suz = 0.0, svz = 0.0
        for p in points {
            let u = Double(p.x) - mu, v = Double(p.y) - mv, z = Double(p.z) - mz
            suu += u * u
            suv += u * v
            svv += v * v
            suz += u * z
            svz += v * z
        }
        let det = suu * svv - suv * suv
        var a = 0.0, b = 0.0
        if abs(det) > 1e-12 {
            a = (suz * svv - svz * suv) / det
            b = (svz * suu - suz * suv) / det
        }
        var squares = 0.0
        for p in points {
            let r = (Double(p.z) - mz) - a * (Double(p.x) - mu) - b * (Double(p.y) - mv)
            squares += r * r
        }
        return Float((squares / n).squareRoot())
    }
}

// MARK: - Verificador

nonisolated struct HandheldSquatVerifier: ActivityVerifier, SourceLevelLimiting {
    typealias Sample = HandheldSquatSample
    private typealias K = HandheldSquatTuning
    private typealias Copy = HandheldSquatCopy

    /// Fuente de la señal de altura: el mundo (VIO) o el respaldo IMU.
    nonisolated enum Mode: String, Sendable, Hashable, Codable { case world, inertial }

    nonisolated enum Rejection: String, Sendable, Hashable, Codable {
        case tooFast, tooSlow, shaking, moved, faceMissing, trackingLost, notLive, flatFace, faceDistance, armsOnly,
             torsoBend, holdMissed, shallow, phoneTilted, inertialLimit
    }

    /// Lo medido en una rep o en un intento (tests y calibración en el dispositivo).
    nonisolated struct RepDiagnostics: Sendable, Hashable {
        var at: Double
        var mode: Mode
        var seconds: Double
        /// Descenso máximo del teléfono (m).
        var phoneDescent: Double
        /// Descenso máximo del cuerpo: la señal con la que se cuenta (m).
        var bodyDescent: Double
        var faceDescentAtPeak: Double?
        var maxFaceDescent: Double?
        /// Teléfono − cara con el teléfono abajo (m; + = el teléfono bajó más que la cara).
        var maxGap: Double
        /// Cambio de la cara en el espacio del teléfono (m) y de la distancia cara-teléfono (m).
        var geometryChange: Double
        var distanceChange: Double
        var pitchDelta: Double
        var headPitchDelta: Double?
        /// Avance de la cara desde el ancla − (margen + fracción de lo que bajó) (m; > 0 = bisagra).
        var forwardExcess: Double?
        /// Desplazamiento de la cara hacia atrás y de lado desde el ancla (m).
        var backwardShift: Double?
        var lateralShift: Double?
        var holdSeconds: Double
        var meanEnergy: Double
        var trackedFraction: Double
        var worldLostFraction: Double
        var flatFraction: Double
        var meanFaceDistance: Double?
        /// Recorrido horizontal del teléfono desde el ancla (m).
        var horizontalTravel: Double?
        var altitudeChange: Double
        var challengeArmed: Bool
        /// Recorrido de la señal desde el nivel en que estaba antes de bajar (m).
        var excursion: Double = 0
        /// Máximo de inversiones del movimiento en 1 s dentro de la ventana (≥ 5 = sacudida).
        var oscillation: Int = 0
        /// Descenso de la cara que NO explica el giro del tronco, en el fondo (m; ver `HingeModel`).
        var kneeDescent: Double? = nil
        /// El desafío estaba armado y en pantalla (barra en `progress.live`) al empezar el intento.
        var challengeShown: Bool = false
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
        /// Cabeceo de la cabeza de pie (nil si la fuente no lo entrega).
        var headPitch: Double? = nil
        /// Dirección horizontal cara → teléfono de pie (hacia dónde mira); nil si el teléfono está casi
        /// debajo de la cara.
        var facing: SIMD2<Double>? = nil
        /// Altura de la cara sobre el teléfono por la TrueDepth y la gravedad (m; respaldo IMU).
        var faceAbove: Double = 0
    }

    private nonisolated struct CalibrationPoint: Sendable, Hashable {
        var t: Double
        var phone: SIMD3<Double>
        var face: SIMD3<Double>
        var faceInPhone: SIMD3<Double>
        var pitch: Double
        var head: Double?
        var accel: Double
        var rms: Double?
        var faceAbove: Double = 0
    }

    /// Muestra de antes de abrir la ventana: el ancla de la rep y el nivel desde el que empezó a bajar.
    private nonisolated struct PreWindowPoint: Sendable, Hashable {
        var t: Double
        var signal: Double
        var face: SIMD3<Double>?
        var phone: SIMD3<Double>
    }

    /// Una muestra del fondo: descenso de la cara (desde la referencia), lo que no explica el giro del tronco
    /// (las rodillas), el avance de la cara desde el ancla (mundo) y el que explica el giro.
    private nonisolated struct HingePoint: Sendable, Hashable {
        var faceDescent: Double
        var knee: Double
        /// Avance y descenso de la cara desde el ancla (m; nil sin mundo).
        var forward: Double?
        var drop: Double?
        var hingeForward: Double
    }

    private nonisolated struct RepWindow: Sendable, Hashable {
        /// Cuándo se abrió la ventana (abortos, re-anclaje) y cuándo empezó a bajar (duración de la rep).
        var openedAt: Double
        var start: Double
        var challengeArmed: Bool
        /// El desafío estaba en pantalla al abrir la ventana.
        var challengeShown = false
        var mode: Mode
        var entered = false
        /// Mínimo de la señal antes de entrar, desde el nivel de pie previo (inicio y recorrido de la rep).
        var lowSignal = Double.infinity
        /// Mayor subida de la señal sobre ese mínimo (m): el recorrido de la rep.
        var maxRise = 0.0
        var peakDescent = 0.0
        var peakSignal = 0.0
        var faceDescentAtPeak: Double?
        var maxFaceDescent: Double?
        var maxGap = 0.0
        var maxGeometryChange = 0.0
        var maxDistanceChange = 0.0
        var maxPitchDelta = 0.0
        var maxHeadPitchDelta: Double?
        /// Ancla (mundo): cara y teléfono en el punto más alto de la cara antes de entrar, y hacia dónde mira.
        var anchorFace: SIMD3<Double>?
        var anchorPhone: SIMD3<Double>?
        var anchorFacing: SIMD2<Double>?
        /// Desde el ancla (m): avance, atrás y de lado de la cara, descenso de la cara y recorrido del teléfono.
        var bodyForward = 0.0
        var bodyBackward = 0.0
        var bodyLateral = 0.0
        var bodyDrop = 0.0
        var phoneTravel = 0.0
        var hold = PlateauTimer(band: HandheldSquatTuning.holdBandMin, floor: HandheldSquatTuning.holdMinDescent)
        var holdDoneAnnounced = false
        var energySum = 0.0
        var energyCount = 0
        var samples = 0
        var trackedSamples = 0
        var worldLostSamples = 0
        var flatSamples = 0
        var distanceSum = 0.0
        var distanceCount = 0
        var altitudeStart: Double?
        var maxAltitudeChange = 0.0
        var shaking = false
        var maxOscillation = 0
        var bottomSamples = 0
        var bottomFaceSamples = 0
        /// Muestras del fondo para la bisagra (`HingeModel`) y el avance de la cara.
        var hingePoints: [HingePoint] = []

        /// Avance de la cara desde el ancla − lo que permiten el giro del tronco y lo que bajaron las rodillas (m; > 0 =
        /// bisagra o escalón), en la muestra del fondo que MEJOR lo explica. nil sin ancla.
        var forwardExcess: Double? {
            guard anchorFace != nil else { return nil }
            guard let deepest = hingePoints.map(\.faceDescent).max(), deepest > 0 else {
                return bodyForward - (K.torsoForwardSlack + K.torsoForwardRatio * bodyDrop)
            }
            var best: Double?
            for p in hingePoints where p.faceDescent >= K.hingeBottomFraction * deepest {
                guard let forward = p.forward, let drop = p.drop else { continue }
                // Lo explica la geometría de una sentadilla (avance ≤ margen + fracción de lo que bajó) O el giro del
                // tronco que se VE (cabeza o teléfono); no la suma: si el giro se esconde (cuello, teléfono frente a la
                // cara), mecerse sentado avanza más de lo que una sentadilla permite.
                let allowed = max(K.torsoForwardSlack + K.torsoForwardRatio * drop, K.hingeForwardCredit * p.hingeForward)
                best = min(best ?? .infinity, forward - allowed)
            }
            return best ?? bodyForward - (K.torsoForwardSlack + K.torsoForwardRatio * bodyDrop)
        }

        /// La cara recorrió la geometría de una sentadilla desde el ancla (avance dentro de lo que permite el
        /// descenso, sin irse atrás ni de lado).
        var squatLike: Bool {
            guard anchorFace != nil else { return false }
            return (forwardExcess ?? 0) <= 0 && bodyBackward <= K.maxFaceBackwardShift
                && bodyLateral <= K.maxFaceLateralShift + K.lateralPerDescent * bodyDrop
        }
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
    private(set) var reanchorCount = 0
    private(set) var barometer = HandheldSquatBarometer()
    /// La TrueDepth ve un plano donde debería haber una cara (foto o pantalla pegada al teléfono).
    private(set) var faceLooksFlat = false
    /// Segundos con la ventana de relieve mostrando una cara 3D, y reps contadas con la cara moviéndose respecto del teléfono.
    private(set) var reliefLiveSeconds = 0.0
    private(set) var nonRigidReps = 0

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
    private var headSmooth = ExponentialSmoother(alpha: K.emaAlpha)
    /// Altura de la cara sobre el teléfono (TrueDepth + gravedad), suavizada.
    private var aboveSmooth = ExponentialSmoother(alpha: K.emaAlpha)
    private var oscillation = OscillationDetector()
    /// Esta muestra cae en una oscilación franca (≥ `shakeMinReversals` inversiones en 1 s).
    private var oscillatingNow = false
    private(set) var inertial = InertialHeightTracker()
    /// Signo de `verticalAccel` (la fuente de hoy lo invierte; se aprende con el mundo).
    private(set) var accelSign = AccelSignEstimator()
    private var calibration: [CalibrationPoint] = []
    /// Muestras recientes con cara y mundo (re-anclaje de la referencia).
    private var recent: [CalibrationPoint] = []
    /// Señal, cara y teléfono de los últimos segundos sin ventana: el ancla y el nivel de pie de la próxima rep.
    private var preWindow: [PreWindowPoint] = []
    private var window: RepWindow?
    /// Metrónomo: solo un ritmo de máquina (σ < 0,06 s y CV < 2 %). Una persona lenta y pareja varía más que
    /// eso y nunca debe quedar sospechosa (meta real de 10 reps).
    private var regularity = RegularityDetector(maxCoefficientOfVariation: 0.02, maxStandardDeviation: 0.06)
    /// Último descenso medido de la cara (se mantiene si la cara se pierde un momento).
    private var lastFaceDescent: Double?

    private var faceLostSince: Double?
    private var faceLostFrames = 0
    private var worldEverNormal = false
    private var worldBadSince: Double?
    private var worldGoodSince: Double?
    private var worldLossCued = false
    private var lastWorldJumpAt: Double?
    private var energyWindow: [(t: Double, e: Double)] = []
    private var energySum = 0.0
    private var reliefReadings: [(t: Double, r: Double)] = []
    private var reliefLiveNow = false
    private var lastReliefT: Double?
    private var staticReported = false
    private var shakingSince: Double?
    private var shakingReported = false
    private var walkingReported = false
    private var inertialReported = false
    private var armsOnlyCount = 0
    private var torsoBendCount = 0
    private var flatFaceCount = 0

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
    /// Hay un intento en curso (ventana abierta) y si ya entró a la rep (depuración y tests).
    var isAttemptOpen: Bool { window != nil }
    var isRepEntered: Bool { window?.entered ?? false }
    var minPeakDescent: Double? { repPeaks.min() }
    var meanRepSeconds: Double? { repSeconds.isEmpty ? nil : repSeconds.reduce(0, +) / Double(repSeconds.count) }

    /// Si alguna rep se midió con el respaldo IMU (sin seguimiento del mundo), la fuente no puede quedar
    /// `.live` aunque el resto de la serie lo fuera: tapar la cámara trasera solo en las reps baja a reduced.
    /// Tampoco sin una cara 3D confirmada por la TrueDepth (sin profundidad, o plana: un video o una foto) ni con la
    /// cara rígida respecto del teléfono en todas las reps (montaje pegado). Fallar el desafío "Quédese abajo" ya no
    /// baja el nivel por sí solo: el video sin profundidad queda en reduced por lo anterior, y una persona con la cara
    /// confirmada que no se quedó abajo (en el teléfono, casi siempre) queda en full.
    func limitedSourceLevel(_ declared: SourceLevel) -> SourceLevel {
        declared == .live && (inertialReps > 0 || !faceDepthConfirmed || rigidFaceSeries) ? .fallback : declared
    }

    /// La TrueDepth vio una cara 3D (relieve) al menos `reliefConfirmSeconds` en la serie.
    var faceDepthConfirmed: Bool { reliefLiveSeconds >= K.reliefConfirmSeconds }
    /// Todas las reps contadas con la cara inmóvil respecto del teléfono (foto, pantalla o máscara pegada).
    var rigidFaceSeries: Bool { count > 0 && nonRigidReps == 0 }

    /// Reps que se pueden contar con el respaldo IMU: menos de la mitad de la meta (al menos 1; meta 5 → 2, 10 → 4).
    /// Con la cámara trasera tapada no se cuenta ninguna sentadilla: sin el mundo no se distingue de alguien
    /// sentado meciéndose. La app pide destaparla.
    var inertialRepCap: Int { 0 }

    /// Se falló el desafío el máximo de veces sin cumplirlo.
    var challengeFailed: Bool { challenge.isEnabled && !challenge.passed && challenge.failures >= SquatHoldChallenge.maxFailures }

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
        trackRelief(s, t)
        updateMode(s, t, &events)
        accelSign.add(t: t, worldY: s.worldTrackingNormal ? Double(s.phonePos.y) : nil, accel: s.verticalAccel)
        if let a = physicalAccel(s) {
            inertial.step(accel: a, dt: dt, t: t, anchorAllowed: window == nil, inRep: window?.entered ?? false)
        }
        trackFace(s)
        pitchSmooth.update(s.phonePitchDeg)
        detectWorldJump(s, t, &events)
        updateFaceGate(s, t, &events)

        switch progress.gate {
        case .calibrating: calibrate(s, t, &events)
        case .ready: track(s, t, dt, &events)
        case .blocked: break
        }
        publishChallengeProgress()

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
        preWindow = []
        reps.reset()
        descent.reset()
    }

    /// Vuelve a calibrar de pie sin perder el conteo.
    private mutating func recalibrate(hint: String, _ events: inout [VerifierEvent]) {
        abortRep()
        calibration = []
        recent = []
        lastFaceDescent = nil
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

    /// Suavizados de la cara; si se perdió más de unos frames, se reinician (al volver no arrastran la
    /// posición vieja, que inventaría una brecha teléfono-cara).
    private mutating func trackFace(_ s: HandheldSquatSample) {
        guard s.faceTracked else {
            faceLostFrames += 1
            if faceLostFrames >= K.faceResetAfterLostFrames {
                faceSmooth.reset()
                fipSmooth.reset()
                headSmooth.reset()
                aboveSmooth.reset()
            }
            return
        }
        faceLostFrames = 0
        faceSmooth.update(Self.d3(s.facePos))
        fipSmooth.update(Self.d3(s.faceInPhone))
        aboveSmooth.update(Self.faceAbove(s))
        if let head = s.headPitchDeg { headSmooth.update(head) }
    }

    /// Aceleración vertical física (m/s², + arriba): la grabada por el signo aprendido (o el de la fuente de hoy).
    private func physicalAccel(_ s: HandheldSquatSample) -> Double? {
        s.verticalAccel.map { $0 * accelSign.sign }
    }

    private static func faceAbove(_ s: HandheldSquatSample) -> Double {
        HandheldSquatGeometry.faceAbovePhone(faceInPhone: d3(s.faceInPhone), pitchDeg: s.phonePitchDeg, rollDeg: s.phoneRollDeg)
    }

    // MARK: Mundo ↔ respaldo IMU

    private mutating func updateMode(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        if s.worldTrackingNormal {
            worldEverNormal = true
            worldBadSince = nil
            worldLossCued = false
            if worldGoodSince == nil { worldGoodSince = t }
        } else {
            worldGoodSince = nil
            if worldBadSince == nil { worldBadSince = t }
        }
        switch mode {
        case .world:
            let bad = t - (worldBadSince ?? t)
            // Datos reales: con los dedos sobre la cámara trasera nunca se decía qué pasaba.
            if worldEverNormal, worldBadSince != nil, bad >= K.worldLossCueSeconds, !worldLossCued, progress.gate == .ready {
                worldLossCued = true
                events.append(.cue(Cue(text: Copy.uncoverCamera, symbol: "camera.metering.unknown")))
            }
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
            recent = []
            lastFaceDescent = nil
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
        // Cabeza razonablemente derecha: sentado y doblado hacia adelante no se calibra.
        if let head = headSmooth.value ?? s.headPitchDeg, abs(head) > K.calibrationMaxHeadPitch {
            calibration = []
            progress.hint = Copy.standUp
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
                                            head: s.headPitchDeg, accel: physicalAccel(s) ?? 0, rms: s.userAccelRMS,
                                            faceAbove: Self.faceAbove(s)))
        while calibration.count > 1, calibration[1].t <= t - K.calibrationSeconds {
            calibration.removeFirst()
        }
        // Sin el mundo lo útil es destapar la cámara trasera (en el teléfono "Quieto un segundo." tapaba ese aviso).
        progress.hint = mode == .inertial ? Copy.uncoverCamera : Copy.holdStill
        guard let first = calibration.first, t - first.t >= K.calibrationSeconds * 0.95, isStill(calibration) else { return }

        reference = Self.reference(from: calibration)
        calibration = []
        recent = []
        lastFaceDescent = nil
        inertial.reset()
        abortRep()
        everReady = true
        setGate(.ready, &events)
        progress.hint = Copy.ready
        events.append(.cue(Cue(text: Copy.ready, symbol: "figure.cross.training")))
        // Datos reales: tras perder la cara y recalibrar, el desafío seguía armado sin consigna en pantalla
        // (47 s y 9 intentos). Se vuelve a anunciar.
        challenge.allowReannouncement()
        announceChallengeIfNeeded(&events)
    }

    /// Promedio de una postura quieta.
    private static func reference(from points: [CalibrationPoint]) -> Reference {
        let n = Double(max(1, points.count))
        let phone = points.map(\.phone).reduce(SIMD3<Double>(repeating: 0), +) / n
        let face = points.map(\.face).reduce(SIMD3<Double>(repeating: 0), +) / n
        let fip = points.map(\.faceInPhone).reduce(SIMD3<Double>(repeating: 0), +) / n
        let pitch = points.map(\.pitch).reduce(0, +) / n
        let heads = points.compactMap(\.head)
        let head: Double? = heads.isEmpty ? nil : heads.reduce(0, +) / Double(heads.count)
        let phoneXZ = SIMD2(phone.x, phone.z), faceXZ = SIMD2(face.x, face.z)
        let above = points.map(\.faceAbove).reduce(0, +) / n
        return Reference(phoneY: phone.y, faceY: face.y, phoneXZ: phoneXZ, faceXZ: faceXZ,
                         faceInPhone: fip, pitch: pitch, headPitch: head, facing: facing(face: faceXZ, phone: phoneXZ),
                         faceAbove: above)
    }

    /// Hacia dónde mira la persona (cara → teléfono en horizontal), si el teléfono no está casi debajo.
    private static func facing(face: SIMD2<Double>, phone: SIMD2<Double>) -> SIMD2<Double>? {
        let v = phone - face
        let length = simd_length(v)
        return length >= K.minFacingDistance ? v / length : nil
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
            // En las manos el IMU tiembla (|a| real de pie hasta 1-2 m/s² por muestra): se mira el promedio.
            let n = Double(max(1, points.count))
            let meanAbs = points.map { abs($0.accel) }.reduce(0, +) / n
            let mean = points.map(\.accel).reduce(0, +) / n
            let rms = points.map { $0.rms ?? 0 }.reduce(0, +) / n
            return meanAbs <= K.calibrationMaxVerticalAccel && abs(mean) <= K.calibrationMaxMeanVerticalAccel
                && rms <= K.calibrationMaxAccelRMS
        }
    }

    // MARK: Re-anclaje de la referencia

    private mutating func remember(_ p: CalibrationPoint, at t: Double) {
        recent.append(p)
        while recent.count > 1, recent[1].t <= t - K.reanchorStillSeconds {
            recent.removeFirst()
        }
    }

    /// Postura quieta reciente (≥ `reanchorStillSeconds`, teléfono y cara con rango de altura acotado) y
    /// con la cabeza derecha, igual que para calibrar (sentarse y doblarse no pasa a ser "de pie"). Además la
    /// cabeza y el teléfono deben cabecear como en la postura de pie calibrada: en el fondo de una sentadilla
    /// con el tronco a 35-40° (la pausa del desafío) la cabeza mira 35-40° más abajo, y sentado y doblado en la
    /// cabina también; bajar una escalera o la solera mirando el teléfono no cambia el cabeceo.
    private func stillReference() -> Reference? {
        guard mode == .world, let first = recent.first, let last = recent.last,
              last.t - first.t >= K.reanchorStillSeconds * 0.95 else { return nil }
        let phoneYs = recent.map(\.phone.y), faceYs = recent.map(\.face.y)
        guard let pMin = phoneYs.min(), let pMax = phoneYs.max(), pMax - pMin <= K.reanchorStillRange,
              let fMin = faceYs.min(), let fMax = faceYs.max(), fMax - fMin <= K.reanchorStillRange else { return nil }
        let candidate = Self.reference(from: recent)
        if let head = candidate.headPitch, abs(head) > K.calibrationMaxHeadPitch { return nil }
        if let current = reference {
            if let head = candidate.headPitch, let head0 = current.headPitch,
               abs(AngleMath.delta(head, head0)) > K.reanchorMaxHeadDelta { return nil }
            if abs(AngleMath.delta(candidate.pitch, current.pitch)) > K.reanchorMaxPitchDelta { return nil }
        }
        return candidate
    }

    /// Una postura quieta nueva es otro lugar de pie (y no sentarse o quedarse agachado) si la cara bajó poco o
    /// se desplazó en horizontal al menos `reanchorMinShiftPerDrop` de lo que bajó.
    private static func isRelocation(from ref: Reference, to still: Reference) -> Bool {
        let drop = ref.faceY - still.faceY
        guard drop > K.reanchorFreeDrop else { return true }
        return simd_length(still.faceXZ - ref.faceXZ) >= K.reanchorMinShiftPerDrop * drop
    }

    /// Nueva postura de pie de referencia. Solo se llega aquí quieto y MÁS ABAJO que la referencia vieja
    /// (o tras estar abajo más que una rep entera): desde ahí hay que bajar la meta completa otra vez.
    private mutating func reanchor(_ ref: Reference) {
        var updated = ref
        if updated.headPitch == nil { updated.headPitch = reference?.headPitch }
        reference = updated
        window = nil
        preWindow = []
        reps.reset()
        descent.reset()
        lastFaceDescent = nil
        recent = []
        reanchorCount += 1
    }

    // MARK: Conteo

    private mutating func track(_ s: HandheldSquatSample, _ t: Double, _ dt: Double, _ events: inout [VerifierEvent]) {
        guard var ref = reference else { return }
        let raw: Double
        switch mode {
        case .world:
            guard s.worldTrackingNormal else {
                // Pérdida corta del mundo: la rep queda congelada (sin medir) y se anota.
                window?.worldLostSamples += 1
                return
            }
            raw = ref.phoneY - Double(s.phonePos.y)
        case .inertial:
            guard s.verticalAccel != nil else { return }
            raw = -inertial.position
        }
        let d = descent.update(raw)
        let face = s.faceTracked ? faceSmooth.value : nil
        let fip = s.faceTracked ? fipSmooth.value : nil
        let pitch = pitchSmooth.value ?? s.phonePitchDeg
        let head = s.faceTracked ? headSmooth.value : nil
        let above = s.faceTracked ? aboveSmooth.value : nil

        // Cuerpo = la cara. En el mundo, su altura; en el respaldo IMU, el descenso del teléfono menos lo que la
        // cara subió sobre él (TrueDepth + gravedad): bajar el teléfono con los brazos, recto o en arco hacia el
        // cuerpo, deja la cara arriba. Si se pierde un momento, su último valor: sin cara no se entra ni se sale.
        let faceDescent: Double?
        switch mode {
        case .world: faceDescent = face.map { ref.faceY - $0.y }
        case .inertial: faceDescent = above.map { d - ($0 - ref.faceAbove) }
        }
        if let faceDescent { lastFaceDescent = faceDescent }
        let entered = window?.entered ?? false
        // Para entrar baja el MENOR (los brazos no aportan); para salir vuelve el MAYOR (la cara también sube).
        // En el respaldo la ventana la abre el teléfono y, para salir, basta que la cara haya vuelto casi arriba.
        let signal: Double
        let moved: Double
        if let body = lastFaceDescent {
            if !entered {
                signal = min(d, body)
            } else if mode == .inertial, let peak = window?.maxFaceDescent,
                      body <= max(K.exitDescent + K.inertialExitFaceSlack, K.inertialExitFaceFraction * peak) {
                signal = d
            } else {
                signal = max(d, body)
            }
            moved = mode == .inertial ? d : max(d, body)
        } else {
            signal = d
            moved = d
        }

        if mode == .world, s.faceTracked {
            remember(CalibrationPoint(t: t, phone: Self.d3(s.phonePos), face: Self.d3(s.facePos),
                                      faceInPhone: Self.d3(s.faceInPhone), pitch: s.phonePitchDeg,
                                      head: s.headPitchDeg, accel: 0, rms: nil, faceAbove: Self.faceAbove(s)), at: t)
        }

        if window == nil {
            preWindow.append(PreWindowPoint(t: t, signal: signal, face: mode == .world ? face : nil, phone: Self.d3(s.phonePos)))
            while let first = preWindow.first, first.t < t - K.anchorLookbackSeconds { preWindow.removeFirst() }
            guard moved > K.windowStartDescent else {
                // Subió mucho sobre la postura de pie (a la cabina, a una plataforma): no se sigue adaptando la referencia
                // hacia allá (llevaba a la postura sentada e inclinada sin pasar por la calibración): se vuelve a calibrar.
                if mode == .world, let faceDescent = lastFaceDescent, -faceDescent > K.climbRecalibrateRise {
                    recalibrate(hint: Copy.holdStill, &events)
                    return
                }
                adaptReference(&ref, s, face: face, fip: fip, pitch: pitch, head: head, dt: dt)
                reference = ref
                return
            }
            let armed = challenge.isArmed(nextRep: count + 1)
            reps.enterThreshold = mode == .inertial ? K.inertialEnterDescent : K.enterDescent
            var opened = RepWindow(openedAt: t, start: t, challengeArmed: armed, challengeShown: armed && progress.live != nil,
                                   mode: mode, altitudeStart: s.altitude)
            // Ancla: la cara en su punto más alto de los últimos segundos (antes de inclinarse o de bajar).
            var top: PreWindowPoint?
            for p in preWindow where p.face != nil {
                if (p.face?.y ?? 0) > (top?.face?.y ?? -.infinity) { top = p }
            }
            if let top, let topFace = top.face { setAnchor(&opened, face: topFace, phone: top.phone, ref: ref) }
            // El recorrido y el inicio se miden desde el nivel de pie de antes de abrir la ventana (que se abre a 3 cm).
            opened.lowSignal = preWindow.map(\.signal).min() ?? signal
            preWindow = []
            window = opened
        }
        guard var w = window else { return }

        // Medidas de esta muestra.
        let geometry = fip.map { simd_length($0 - ref.faceInPhone) }
        let distanceChange = fip.map { abs(simd_length($0) - simd_length(ref.faceInPhone)) }
        let pitchDelta = abs(AngleMath.delta(pitch, ref.pitch))
        let headDelta: Double? = head.flatMap { h in ref.headPitch.map { abs(AngleMath.delta(h, $0)) } }
        let bottom = signal >= K.bottomZoneFraction * K.enterDescent
        let phoneLow = d >= K.bottomZoneFraction * K.enterDescent

        w.samples += 1
        if s.faceTracked {
            w.trackedSamples += 1
            w.energySum += Double(s.shapeEnergy)
            w.energyCount += 1
            w.distanceSum += faceDistance(s)
            w.distanceCount += 1
            if faceLooksFlat { w.flatSamples += 1 }
        }
        // Sacudida = oscilación (no "mucha aceleración": una sentadilla rápida y honda es una sola bajada suave).
        if oscillatingNow { w.shaking = true }
        w.maxOscillation = max(w.maxOscillation, oscillation.reversals(within: K.shakeWindowSeconds, at: t))
        w.maxPitchDelta = max(w.maxPitchDelta, pitchDelta)
        var anchorForward: Double?
        var anchorDrop: Double?
        if mode == .world, let face {
            // Antes de entrar el ancla sube con la cara (se enderezó antes de bajar).
            if w.anchorFace == nil || (!w.entered && face.y > (w.anchorFace?.y ?? 0)) {
                setAnchor(&w, face: face, phone: Self.d3(s.phonePos), ref: ref)
            }
            if let a = w.anchorFace, let p = w.anchorPhone {
                let shift = SIMD2(face.x - a.x, face.z - a.z)
                if let facing = w.anchorFacing {
                    let forward = simd_dot(shift, facing)
                    anchorForward = forward
                    w.bodyForward = max(w.bodyForward, forward)
                    w.bodyBackward = max(w.bodyBackward, -forward)
                    w.bodyLateral = max(w.bodyLateral, abs(shift.x * facing.y - shift.y * facing.x))
                }
                anchorDrop = a.y - face.y
                w.bodyDrop = max(w.bodyDrop, a.y - face.y)
                w.phoneTravel = max(w.phoneTravel, simd_length(SIMD2(Double(s.phonePos.x) - p.x, Double(s.phonePos.z) - p.z)))
            }
        }
        if let altitude = s.altitude {
            if let start = w.altitudeStart {
                w.maxAltitudeChange = max(w.maxAltitudeChange, abs(altitude - start))
            } else {
                w.altitudeStart = altitude
            }
        }
        if !w.entered {
            w.lowSignal = min(w.lowSignal, signal)
            if signal <= w.lowSignal + K.repStartBand { w.start = t }
        }
        w.maxRise = max(w.maxRise, signal - w.lowSignal)
        if d > w.peakDescent {
            w.peakDescent = d
            w.faceDescentAtPeak = faceDescent ?? w.faceDescentAtPeak
        }
        w.peakSignal = max(w.peakSignal, signal)
        if let faceDescent { w.maxFaceDescent = max(w.maxFaceDescent ?? faceDescent, faceDescent) }
        if phoneLow {
            if let faceDescent { w.maxGap = max(w.maxGap, d - faceDescent) }
            if let geometry { w.maxGeometryChange = max(w.maxGeometryChange, geometry) }
            if let distanceChange { w.maxDistanceChange = max(w.maxDistanceChange, distanceChange) }
        }
        if bottom {
            w.bottomSamples += 1
            if s.faceTracked { w.bottomFaceSamples += 1 }
            if let headDelta { w.maxHeadPitchDelta = max(w.maxHeadPitchDelta ?? headDelta, headDelta) }
            if let faceDescent, faceDescent > 0 {
                // Bisagra: giro del tronco ≈ lo que la cabeza mira más abajo o lo que el teléfono (antebrazos
                // pegados al pecho) cabecea hacia arriba, desde la inclinación que ya traía al calibrar.
                // Con el teléfono girando con el tronco (antebrazos al pecho), la cabeza que además baja SIGUIENDO al
                // teléfono (que cae respecto de la cara al inclinarse) es cuello, no tronco: se descuenta lo que bajó la
                // mirada hacia el teléfono (con tope). Así Marco no paga una bisagra que no hizo. Sin giro del teléfono
                // no se descuenta (cabecear y bajar el teléfono con los brazos no puede esconder un cuarto de sentadilla).
                let rawHeadDown = head.flatMap { h in ref.headPitch.map { AngleMath.delta($0, h) } } ?? 0
                var headDown = rawHeadDown
                let phoneUp = AngleMath.delta(pitch, ref.pitch)
                if headDown > phoneUp, phoneUp >= K.hingeGazeMinPhoneTurn,
                   let gaze = HingeModel.gazeDown(reference: ref, faceAbove: above, faceInPhone: fip) {
                    headDown -= min(max(0, gaze), K.hingeGazeDiscountFraction * headDown, K.hingeMaxGazeDiscount)
                }
                let start = HingeModel.startLean(referenceHeadPitch: ref.headPitch, referencePitch: ref.pitch)
                let lean = max(0, headDown, phoneUp)
                let hinge = HingeModel.drop(startLean: start, lean: lean)
                // El avance que explica el giro se cuenta con todo lo que se vio girar (sin descontar el cuello).
                let seen = max(0, rawHeadDown, phoneUp)
                w.hingePoints.append(HingePoint(faceDescent: faceDescent, knee: faceDescent - hinge, forward: anchorForward,
                                                drop: anchorDrop, hingeForward: HingeModel.forward(startLean: start, lean: seen)))
            }
        }
        w.hold.band = max(K.holdBandMin, K.holdBandFraction * w.peakSignal)
        w.hold.add(signal, at: t)
        if w.challengeArmed, !w.holdDoneAnnounced, w.hold.best >= K.holdRequiredSeconds {
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

        switch reps.update(signal, at: t) {
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
            if !w.entered, moved <= K.windowStartDescent * 0.5 {
                window = w
                closeAttempt(at: t, &events)
                return
            }
            // Quieto en otro lugar y otro nivel (bajó de la solera, bajó una escalera): esa es la nueva postura
            // de pie. Una pausa en el mismo lugar no mueve la referencia, ni quedarse quieto en el fondo de una
            // sentadilla (la pausa del desafío, con el tronco inclinado la cara queda 25-30 cm adelante).
            let pausingAtBottom = w.entered && (w.challengeArmed || w.squatLike)
            if t - w.openedAt >= K.reanchorMinWindowSeconds, !pausingAtBottom, let still = stillReference(),
               simd_length(still.faceXZ - ref.faceXZ) >= (w.entered ? K.reanchorMinShiftEntered : K.reanchorMinShift),
               Self.isRelocation(from: ref, to: still) {
                reanchor(still)
                return
            }
            let limit = K.maxRepSeconds + (w.challengeArmed ? K.holdExtraSeconds : 0) + K.abortGraceSeconds
            if t - (w.entered ? w.start : w.openedAt) > limit {
                // Abajo demasiado rato (o de pie en otro nivel): se descarta sin contar; si está quieto en otro
                // lugar de pie, esa postura pasa a ser la referencia (bajó una escalera, se quedó en la calzada).
                // Sentarse baja la cara 45-78 cm casi sin moverla en horizontal: eso no es "otro lugar de pie".
                if w.entered { events.append(.cue(Cue(text: Copy.comeBackUp, symbol: "arrow.up"))) }
                if let still = stillReference(), Self.isRelocation(from: ref, to: still) {
                    reanchor(still)
                } else {
                    abortRep()
                }
                return
            }
        }
        window = w
    }

    /// Fija el ancla de la rep y reinicia lo medido desde ella.
    private func setAnchor(_ w: inout RepWindow, face: SIMD3<Double>, phone: SIMD3<Double>, ref: Reference) {
        w.anchorFace = face
        w.anchorPhone = phone
        w.anchorFacing = Self.facing(face: SIMD2(face.x, face.z), phone: SIMD2(phone.x, phone.z)) ?? ref.facing
        w.bodyForward = 0
        w.bodyBackward = 0
        w.bodyLateral = 0
        w.bodyDrop = 0
        w.phoneTravel = 0
    }

    private mutating func adaptReference(_ ref: inout Reference, _ s: HandheldSquatSample, face: SIMD3<Double>?,
                                         fip: SIMD3<Double>?, pitch: Double, head: Double?, dt: Double) {
        let k = min(1, dt / K.referenceTimeConstant)
        guard k > 0 else { return }
        if mode == .world, s.worldTrackingNormal {
            ref.phoneY += k * (Double(s.phonePos.y) - ref.phoneY)
            ref.phoneXZ += k * (SIMD2(Double(s.phonePos.x), Double(s.phonePos.z)) - ref.phoneXZ)
            if s.faceTracked, let face {
                ref.faceY += k * (face.y - ref.faceY)
                ref.faceXZ += k * (SIMD2(face.x, face.z) - ref.faceXZ)
            }
            ref.facing = Self.facing(face: ref.faceXZ, phone: ref.phoneXZ) ?? ref.facing
        }
        if s.faceTracked, let fip { ref.faceInPhone += k * (fip - ref.faceInPhone) }
        if s.faceTracked, let above = aboveSmooth.value { ref.faceAbove += k * (above - ref.faceAbove) }
        // La cabeza de referencia sigue derecha como al calibrar (no se adapta hacia una postura doblada).
        if s.faceTracked, let head, let head0 = ref.headPitch, abs(head) <= K.calibrationMaxHeadPitch {
            ref.headPitch = head0 + k * AngleMath.delta(head, head0)
        }
        ref.pitch += k * AngleMath.delta(pitch, ref.pitch)
    }

    /// Un intento que no llegó a entrar terminó (teléfono y cara volvieron arriba).
    private mutating func closeAttempt(at t: Double, _ events: inout [VerifierEvent]) {
        guard let w = window else { return }
        window = nil
        reps.reset()
        if w.peakDescent >= K.enterDescent, w.maxGap > K.armsOnlyMaxGap {
            // El teléfono llegó a la meta y la cara quedó arriba (en el mundo o, en el respaldo, sobre el
            // teléfono según la TrueDepth y la gravedad): bajó con los brazos.
            appendDiagnostics(w, at: t, rejection: .armsOnly)
            reject(.armsOnly, w, at: t, &events)
        } else if w.maxRise >= K.shallowCueDescent {
            // Bajó y subió sin llegar (no el final de la subida de la rep anterior, que no sube).
            events.append(.cue(Cue(text: Copy.lower, symbol: "arrow.down")))
        }
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
        let measured = w.samples + w.worldLostSamples
        let lost = measured > 0 ? Double(w.worldLostSamples) / Double(measured) : 0
        let flat = w.trackedSamples > 0 ? Double(w.flatSamples) / Double(w.trackedSamples) : 0
        let maxSeconds = K.maxRepSeconds + (w.challengeArmed ? K.holdExtraSeconds : 0)
        // Los brazos no hacen la rep: la cara debe haber bajado (en el respaldo, el teléfono menos lo que la cara
        // subió sobre él según la TrueDepth y la gravedad). La distancia cara-teléfono no se usa: en el iPhone real
        // cambia > 15 cm en sentadillas hondas (brazos adelante) y no ve un arco alrededor de la cara.
        let armsOnly = (w.maxFaceDescent ?? 0) < K.enterDescent * K.faceDescentMinFraction
        let hinge = Self.hingeAtBottom(w)
        let movedAway = w.mode == .world
            && (w.bodyBackward > K.maxFaceBackwardShift
                || w.bodyLateral > K.maxFaceLateralShift + K.lateralPerDescent * w.bodyDrop)

        var rejection: Rejection?
        if w.shaking {
            rejection = .shaking
        } else if w.maxPitchDelta > K.phoneTiltMaxPitchDelta, w.maxGap > K.armsOnlyMaxGap {
            // Teléfono volteado o bajado hacia los muslos: el teléfono bajó mucho más que la cara.
            rejection = .phoneTilted
        } else if w.maxRise < K.minRepExcursion {
            rejection = .shallow
        } else if w.mode == .world, w.phoneTravel > K.maxRepHorizontalTravel + K.travelPerDescent * w.peakDescent {
            rejection = .moved
        } else if w.mode == .inertial, w.peakDescent > K.maxInertialDescent || w.maxAltitudeChange > K.maxRepAltitudeChange {
            rejection = .moved
        } else if movedAway {
            rejection = .moved
        } else if tracked < K.minTrackedFraction || (w.bottomSamples > 0 && w.bottomFaceSamples == 0) {
            rejection = .faceMissing
        } else if lost > K.maxWorldLostFraction {
            rejection = .trackingLost
        } else if energy < K.liveFaceMinEnergy {
            rejection = .notLive
        } else if flat >= K.flatFaceRepFraction {
            rejection = .flatFace
        } else if let distance, distance < K.faceDistanceMin || distance > K.faceDistanceMax {
            rejection = .faceDistance
        } else if armsOnly {
            rejection = .armsOnly
        } else if w.maxPitchDelta > K.torsoMaxPitchDelta || (w.maxHeadPitchDelta ?? 0) > K.headMaxPitchDelta
                    || (w.forwardExcess ?? -1) > 0 || hinge.isHinge {
            rejection = .torsoBend
        } else if seconds < K.minRepSeconds {
            rejection = .tooFast
        } else if seconds > maxSeconds {
            rejection = .tooSlow
        } else if w.challengeArmed, w.hold.best < K.holdRequiredSeconds {
            rejection = .holdMissed
        } else if w.mode == .inertial, inertialReps >= inertialRepCap {
            // Con la cámara tapada no se termina la serie: hay que destaparla.
            rejection = .inertialLimit
        }

        appendDiagnostics(w, at: t, rejection: rejection)
        guard let rejection else {
            countRep(w, seconds: seconds, at: t, &events)
            return
        }
        reject(rejection, w, at: t, &events)
    }

    /// Bisagra en el fondo (muestras con la cara a ≥ 90 % de su descenso máximo): vale la que MÁS aporta de
    /// las rodillas (un instante con la cabeza agachada no rechaza una sentadilla). nil sin cara en el fondo.
    private static func hingeAtBottom(_ w: RepWindow) -> (isHinge: Bool, knee: Double?) {
        guard let deepest = w.hingePoints.map(\.faceDescent).max(), deepest > 0 else { return (false, nil) }
        var best: (margin: Double, knee: Double)?
        for p in w.hingePoints where p.faceDescent >= K.hingeBottomFraction * deepest {
            let margin = p.knee - HingeModel.minKneeDescent(faceDescent: p.faceDescent, inertial: w.mode == .inertial)
            if best.map({ margin > $0.margin }) ?? true { best = (margin, p.knee) }
        }
        guard let best else { return (false, nil) }
        return (best.margin < 0, best.knee)
    }

    private mutating func appendDiagnostics(_ w: RepWindow, at t: Double, rejection: Rejection?) {
        let tracked = w.samples > 0 ? Double(w.trackedSamples) / Double(w.samples) : 0
        let measured = w.samples + w.worldLostSamples
        diagnostics.append(RepDiagnostics(
            at: t, mode: w.mode, seconds: t - w.start, phoneDescent: w.peakDescent, bodyDescent: w.peakSignal,
            faceDescentAtPeak: w.faceDescentAtPeak, maxFaceDescent: w.maxFaceDescent, maxGap: w.maxGap,
            geometryChange: w.maxGeometryChange, distanceChange: w.maxDistanceChange, pitchDelta: w.maxPitchDelta,
            headPitchDelta: w.maxHeadPitchDelta, forwardExcess: w.forwardExcess,
            backwardShift: w.anchorFace == nil ? nil : w.bodyBackward,
            lateralShift: w.anchorFace == nil ? nil : w.bodyLateral, holdSeconds: w.hold.best,
            meanEnergy: w.energyCount > 0 ? w.energySum / Double(w.energyCount) : 0, trackedFraction: tracked,
            worldLostFraction: measured > 0 ? Double(w.worldLostSamples) / Double(measured) : 0,
            flatFraction: w.trackedSamples > 0 ? Double(w.flatSamples) / Double(w.trackedSamples) : 0,
            meanFaceDistance: w.distanceCount > 0 ? w.distanceSum / Double(w.distanceCount) : nil,
            horizontalTravel: w.anchorFace == nil ? nil : w.phoneTravel, altitudeChange: w.maxAltitudeChange,
            challengeArmed: w.challengeArmed, excursion: w.maxRise, oscillation: w.maxOscillation,
            kneeDescent: Self.hingeAtBottom(w).knee, challengeShown: w.challengeShown, rejection: rejection))
    }

    private mutating func countRep(_ w: RepWindow, seconds: Double, at t: Double, _ events: inout [VerifierEvent]) {
        count += 1
        if w.maxGeometryChange >= K.rigidFaceMaxGeometryChange { nonRigidReps += 1 }
        repPeaks.append(w.peakSignal)
        repSeconds.append(seconds)
        if w.challengeArmed {
            challenge.pass()
            // Saca de la pantalla el "Ya. Suba." de la pausa.
            if count < progress.target { events.append(.cue(Cue(text: Copy.ready, symbol: "figure.cross.training"))) }
        }
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
        case .flatFace:
            flatFaceCount += 1
            if flatFaceCount <= K.flatFaceHardAt {
                let severity: Anomaly.Severity = flatFaceCount == K.flatFaceHardAt ? .hard : .soft
                record(Anomaly(kind: HandheldSquatAnomaly.flatFace, severity: severity, at: t,
                               detail: "La cámara de profundidad ve un plano: foto o pantalla"), &events)
            }
            events.append(.cue(Cue(text: Copy.lookAtScreen, symbol: "face.smiling")))
        case .holdMissed:
            // Al 2º fallo el desafío se cierra. Solo es hard si además hubo otra señal de trampa (brazos, cara plana
            // o sin micro-movimiento, metrónomo, sacudidas); si no, soft. El nivel lo limita `limitedSourceLevel`
            // solo sin una cara 3D confirmada (el video sin profundidad no llega a full); una persona con la cara
            // confirmada por la TrueDepth que no lo logró queda en full.
            if var a = challenge.fail(at: t) {
                // Bajar el teléfono una vez con los brazos (soft) no agrava un desafío fallido; sí cuando ya es reiterado (hard).
                let corroborated = anomalies.contains {
                    HandheldSquatAnomaly.challengeCorroborating.contains($0.kind)
                        && ($0.kind != HandheldSquatAnomaly.armsOnly || $0.severity == .hard)
                }
                if !corroborated {
                    a.severity = .soft
                    a.detail = "No se quedó abajo cuando se le pidió (sin otra señal de trampa)"
                }
                record(a, &events)
            }
            if challenge.isFinished {
                // Cerrado: se sigue contando sin pausa.
                progress.hint = Copy.ready
                events.append(.cue(Cue(text: Copy.ready, symbol: "figure.cross.training")))
            } else {
                announceChallengeIfNeeded(&events)
            }
        case .shaking:
            events.append(.cue(Cue(text: Copy.noShake, symbol: "iphone.radiowaves.left.and.right")))
        case .phoneTilted:
            events.append(.cue(Cue(text: Copy.phoneAtChest, symbol: "iphone")))
        case .shallow:
            events.append(.cue(Cue(text: Copy.lower, symbol: "arrow.down")))
        case .moved where w.mode == .inertial:
            // Sin el mundo una sentadilla de más de 60 cm no se distingue de un ascensor: lo útil es destapar la cámara.
            events.append(.cue(Cue(text: Copy.uncoverCamera, symbol: "camera.metering.unknown")))
        case .moved:
            events.append(.cue(Cue(text: Copy.stayInPlace, symbol: "figure.stand")))
        case .faceMissing:
            events.append(.cue(Cue(text: Copy.keepFace, symbol: "face.dashed")))
        case .trackingLost, .inertialLimit:
            events.append(.cue(Cue(text: Copy.uncoverCamera, symbol: "camera.metering.unknown")))
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

    /// Mientras el desafío esté armado, la consigna queda en `progress.hint` y el avance de la pausa (0…1) en
    /// `progress.live`: la vista lo muestra siempre, aunque otra consigna o una recalibración pase por encima
    /// (en el teléfono el aviso se perdía y el desafío seguía armado sin verse). nil sin desafío armado.
    private mutating func publishChallengeProgress() {
        guard progress.gate == .ready, count < progress.target, challenge.isArmed(nextRep: count + 1) else {
            progress.live = nil
            return
        }
        let held = window.map { $0.challengeArmed ? $0.hold.best : 0 } ?? 0
        progress.live = min(1, held / K.holdRequiredSeconds)
        if !HoldChallengeCopy.allCueTexts.contains(progress.hint) { progress.hint = challenge.currentCue.text }
    }

    private mutating func record(_ a: Anomaly, _ events: inout [VerifierEvent]) {
        anomalies.append(a)
        events.append(.anomaly(a))
    }

    // MARK: Anomalías de fondo

    /// Sacudida = oscilación. ≥ 5 inversiones del movimiento en 1 s: la rep en curso no cuenta. ≥ 6 en 1 s, o
    /// bombeo fuerte (RMS ≥ 0,6 g) con ≥ 4 en 1,5 s, sostenido 0,8 s → `shaking` hard. Una sentadilla rápida y
    /// honda (una bajada suave, ≤ 3 por segundo aunque llegue a 0,8 g) no lo es.
    private mutating func detectShaking(_ s: HandheldSquatSample, _ t: Double, _ events: inout [VerifierEvent]) {
        let position: SIMD3<Double>? = s.worldTrackingNormal ? Self.d3(s.phonePos) : nil
        oscillation.add(t: t, verticalAccel: s.verticalAccel, position: position)
        let fast = oscillation.reversals(within: K.shakeWindowSeconds, at: t)
        oscillatingNow = fast >= K.shakeMinReversals
        let strong = (s.userAccelRMS ?? 0) >= K.shakingAccelRMS
        let pumping = strong && oscillation.reversals(within: K.shakeSustainedWindowSeconds, at: t) >= K.shakeSustainedMinReversals
        guard fast >= K.shakeHardMinReversals || pumping else {
            shakingSince = nil
            return
        }
        if shakingSince == nil { shakingSince = t }
        guard !shakingReported, t - (shakingSince ?? t) >= K.shakingSustainSeconds else { return }
        shakingReported = true
        record(Anomaly(kind: HandheldSquatAnomaly.shaking, severity: .hard, at: t,
                       detail: String(format: "Sacudida: %d inversiones en 1 s, %.1f g", fast, s.userAccelRMS ?? 0)), &events)
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

    /// Relieve 3D: mediana de las lecturas TrueDepth de los últimos segundos (sin lecturas no decide).
    private mutating func trackRelief(_ s: HandheldSquatSample, _ t: Double) {
        var changed = false
        if s.faceTracked, let r = s.faceRelief, r.isFinite {
            reliefReadings.append((t, Double(r)))
            changed = true
        }
        while let first = reliefReadings.first, first.t < t - K.reliefWindowSeconds {
            reliefReadings.removeFirst()
            changed = true
        }
        let dt = lastReliefT.map { min(K.maxIntegrationStep, max(0, t - $0)) } ?? 0
        lastReliefT = t
        if reliefLiveNow, s.faceTracked { reliefLiveSeconds += dt }
        guard changed else { return }
        guard reliefReadings.count >= K.reliefMinReadings else {
            faceLooksFlat = false
            reliefLiveNow = false
            return
        }
        let sorted = reliefReadings.map(\.r).sorted()
        faceLooksFlat = sorted[sorted.count / 2] < K.flatFaceMaxRelief
        reliefLiveNow = !faceLooksFlat
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
        /// Bisagra de cintura sin doblar rodillas: todo baja, la cara se adelanta mucho, el teléfono y la
        /// cabeza cabecean con el tronco.
        case torsoBend
        /// Foto o máscara pegada al teléfono: la "cara" baja con él, sin micro-expresiones ni relieve.
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
        /// Cabeceo de la cabeza de pie mirando el teléfono frente al pecho (°).
        var headPitch = -28.0
        /// Relieve TrueDepth cada `reliefEveryFrames` (≈ 15 Hz); false = sin profundidad (sol directo).
        var relief = true
        var reliefEveryFrames = 4

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
            var pitch = 4.0
            var head = options.headPitch
            switch style {
            case .squat:
                phone.y -= drop
                phone.z -= 0.02 * x
                face.y -= drop * 0.97
                face.z -= 0.04 * x
                pitch += 8 * x
                head -= 6 * x
            case .armsOnly:
                phone.y -= drop
                pitch += 15 * x
                head -= 8 * x
            case .torsoBend:
                phone.y -= drop
                phone.z -= 1.6 * drop
                face.y -= drop * 1.1
                face.z -= 2.0 * drop
                pitch -= 40 * x
                head -= 40 * x
            case .photo:
                phone.y -= drop
                face.y -= drop
            }

            if style != .photo {
                // Las manos no son un soporte: en el fondo el teléfono cae ≈ 2 cm respecto de la cara y se acerca al pecho
                // (reales: la cara se mueve ≥ 3,4 cm por rep respecto del teléfono). La foto pegada, no.
                phone += SIMD3(0.004 * sin(1.7 * t), -0.018 * x + 0.003 * sin(1.1 * t), 0.024 * x)
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
                accel += -options.shakeAmplitude * omega * omega * s
            }

            let n = options.positionNoise
            func jitter(_ v: SIMD3<Double>) -> SIMD3<Double> {
                v + SIMD3(rng.symmetric(n), rng.symmetric(n), rng.symmetric(n))
            }
            // La cara en el espacio de la cámara frontal de ARKit, desde las posiciones reales (sin el ruido ni la
            // basura del mundo tapado): la TrueDepth la ve aunque la cámara trasera no vea nada.
            let fip = HandheldSquatGeometry.faceInPhone(world: face - phone, pitchDeg: pitch)
            let photo = style == .photo
            let phoneWorld = options.world ? jitter(phone) : SIMD3(rng.symmetric(0.3), rng.symmetric(0.3), rng.symmetric(0.3))
            let faceWorld = options.world ? jitter(face) : SIMD3(0, 0, -0.45) + SIMD3(rng.symmetric(n), rng.symmetric(n), rng.symmetric(n))
            let faceInPhone = photo ? fip : jitter(fip)
            let energy = photo ? Float(rng.unit() * 0.0004) : max(0, options.shapeEnergy * Float(0.5 + rng.unit()))

            var rms: Double? = nil
            var vertical: Double? = nil
            if options.includeMotion {
                // Como la entrega la fuente de hoy (signo invertido, `HandheldSquatTuning.recordedAccelSign`).
                vertical = HandheldSquatTuning.recordedAccelSign * (accel + options.accelBias + rng.symmetric(options.accelNoise))
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

            var relief: Float? = nil
            if options.relief, i % max(1, options.reliefEveryFrames) == 0 {
                relief = photo ? Float(0.0015 + rng.unit() * 0.001) : Float(0.009 + rng.unit() * 0.004)
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
                steps: steps,
                headPitchDeg: head + rng.symmetric(1.0),
                faceRelief: relief))
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
