import Foundation

// Dueño: agente "activities". Copy por actividad y por bloque de sensor.
// Español de Chile, de usted, frases cortas. Sin "po/cachai", sin tono infantil,
// nunca "trampa" ni "apto / no apto".

// MARK: - Copy por bloque de sensor

nonisolated extension SensorBlock {
    /// Nombre corto del bloque (para el HUD "preparando…").
    var title: String {
        switch self {
        case .pedometer: "Pasos"
        case .face: "Cámara frontal"
        case .screen: "Pantalla"
        }
    }

    /// Dónde va el teléfono durante el bloque.
    var placement: String {
        switch self {
        case .pedometer: "Guarde el teléfono en el bolsillo del pecho y camine"
        case .face: "Teléfono en la mano a distancia selfie"
        case .screen: "Pantalla en la mano"
        }
    }

    /// Pasos del gating en vivo, en orden. El último es el "listo".
    var gatingCopy: [String] {
        switch self {
        case .pedometer: ["Guarde el teléfono. Camine.", "No lo bloquee."]
        case .face: ["Sáquese casco y lentes.", "Mire al teléfono.", "Quieto un segundo."]
        case .screen: ["Pantalla en la mano.", "3 · 2 · 1"]
        }
    }

    /// Texto del estado "preparando" entre bloques (el coordinador detiene una fuente antes de arrancar la otra).
    var preparingCopy: String {
        switch self {
        case .pedometer: "Preparando el contador de pasos…"
        case .face: "Preparando cámara…"
        case .screen: "Preparando…"
        }
    }

    /// Usa la cámara frontal (ARSession sin vista). Es el único bloque de cámara: la app no abre ninguna
    /// `AVCaptureSession` ni muestra la imagen.
    var usesFrontCamera: Bool { self == .face }
}

// MARK: - Copy por actividad

nonisolated extension ActivityKind {
    /// Etiqueta del botón pequeño de saltar (la actividad saltada no suma).
    static let skipLabel = "Saltar (no suma)"

    /// Dos frases: qué hacer y cómo. Para leer en la pantalla previa a la actividad.
    var instructions: String {
        switch self {
        case .extensionLumbar:
            "Tome el teléfono con las dos manos frente al pecho y mírelo. Inclínese hacia atrás con todo el tronco, hasta donde no duela, y vuelva."
        case .pasos:
            "Guarde el teléfono en el bolsillo del pecho y camine a paso firme, sin apuro. El teléfono vibra al llegar a la meta."
        case .sentadilla:
            "Tome el teléfono con las dos manos frente al pecho y mírelo. Baje hasta la mitad, como si fuera a sentarse, y suba sin apuro."
        case .cuello:
            "Siga la flecha en pantalla: sí es asentir, no es girar, quizás es inclinar. Muévase lento hasta llenar la barra y vuelva al centro."
        case .respiracion:
            "Siéntese derecho, con una mano sobre la guata. Tome aire por la nariz en cuatro segundos y suéltelo en seis, con el dedo en la pantalla al exhalar."
        case .ojos:
            "Mire el teléfono y parpadee completo: cierre bien los dos ojos y ábralos. Los parpadeos a medias no cuentan, vaya sin apuro."
        case .stroop:
            "Toque el color de la tinta, no la palabra escrita. Responda rápido pero sin adivinar, durante un minuto."
        }
    }

    /// Dónde va el teléfono (texto del bloque de sensor).
    var placement: String {
        switch self {
        // En las manos (cámaras + sensores, sin mostrar la cámara).
        case .sentadilla, .extensionLumbar: "Teléfono en las dos manos, frente al pecho"
        default: sensorBlock.placement
        }
    }

    /// Pasos del gating en vivo; las actividades de pantalla afinan el del bloque.
    var gatingCopy: [String] {
        switch self {
        case .stroop: ["Pantalla en la mano.", "Toque el color, no la palabra.", "3 · 2 · 1"]
        case .sentadilla: ["Tome el teléfono frente al pecho y mírelo.", "Quieto un segundo.", "Baje como si se sentara."]
        case .extensionLumbar: ["Tome el teléfono frente al pecho y mírelo.", "Quieto un segundo.", "Inclínese hacia atrás."]
        case .respiracion: ["Pantalla en la mano.", "Dedo en el botón al exhalar."]
        case .ojos: ["Sáquese los lentes.", "Mire al teléfono.", "Cierre bien los ojos."]
        case .pasos, .cuello: sensorBlock.gatingCopy
        }
    }

    /// Una frase de evidencia (dosis de la librería clínica del plan).
    var evidenceNote: String {
        switch self {
        case .extensionLumbar:
            "El ejercicio regular baja más de un tercio las recaídas de dolor lumbar (Steffens 2016)."
        case .pasos:
            "Caminar seguido casi duplica el tiempo sin recaídas de dolor lumbar (Pocovi 2024)."
        case .sentadilla:
            "Diez minutos de fuerza en el trabajo reducen el dolor musculoesquelético (Jakobsen 2015)."
        case .cuello:
            "Dos minutos diarios de ejercicio bajan el dolor de cuello en el trabajo (Andersen 2011; Gross 2015)."
        case .respiracion:
            "Respirar lento baja la tensión muscular y cierra la pausa sin esfuerzo; cuenta como actividad suave."
        case .ojos:
            "Frente a una pantalla se parpadea hasta cinco veces menos y el ojo se seca (Patel 1991)."
        case .stroop:
            "La falta de sueño golpea primero la atención sostenida (Lim & Dinges 2010)."
        }
    }

    /// Cuándo no hacerla o detenerse.
    var contraindication: String {
        switch self {
        case .extensionLumbar: "No la haga si el dolor le baja a la pierna o si al estirarse se marea."
        case .pasos: "Si al caminar el dolor le aumenta o se marea, deténgase y siéntese."
        case .sentadilla: "No la haga si hoy evita agacharse o si le duele la rodilla."
        case .cuello: "Deténgase si se marea o si el dolor le baja al brazo."
        case .respiracion: "Si se marea, respire normal y siga cuando pase."
        case .ojos: "Si ve borroso o le duele la cabeza, cierre los ojos un momento."
        case .stroop: "Es solo para usted, no es un examen. Si ve borroso, sáltelo."
        }
    }

    /// Texto corto de la meta, p. ej. "250 pasos" / "10 reps".
    func goalCopy(target: Int) -> String { "\(target) \(unit)" }

    /// Actividades que se hacen de pie (las reglas de seguridad las acortan si "solo está de pie por períodos cortos").
    var isStanding: Bool {
        switch self {
        case .extensionLumbar, .pasos, .sentadilla: true
        case .cuello, .respiracion, .ojos, .stroop: false
        }
    }
}
