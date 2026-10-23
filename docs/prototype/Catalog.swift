import Foundation

/// Actividades simples: movimientos grandes con el iPhone en las manos, más caminata y escaleras.
enum Catalog {
    static let brazos = Exercise(
        id: "brazos", name: "Brazos arriba",
        instructions: "Toma el iPhone con las dos manos frente al pecho, pantalla hacia ti. Estira los brazos por sobre la cabeza y vuelve al pecho.",
        symbol: "figure.arms.open", pattern: .pitch, target: 8, threshold: 35,
        prompt: "Brazos arriba", safeForHighPain: true, xp: 15)

    static let giro = Exercise(
        id: "giro", name: "Giro de tronco",
        instructions: "iPhone con las dos manos frente al pecho. Gira el tronco a la derecha y luego a la izquierda, sin mover los pies.",
        symbol: "arrow.left.and.right", pattern: .twist, target: 10, threshold: 25,
        prompt: "Gira hacia un lado", safeForHighPain: true, xp: 15)

    static let lateral = Exercise(
        id: "lateral", name: "Inclinación lateral",
        instructions: "iPhone con las dos manos frente al pecho. Inclina el cuerpo hacia un lado, vuelve y luego al otro lado.",
        symbol: "figure.cooldown", pattern: .sideBend, target: 10, threshold: 15,
        prompt: "Inclínate hacia un lado", safeForHighPain: true, xp: 15)

    static let sentadilla = Exercise(
        id: "sentadilla", name: "Sentadillas",
        instructions: "iPhone con las dos manos contra el pecho. Baja como si te sentaras, inclinando un poco el pecho hacia adelante, y vuelve a pararte.",
        symbol: "figure.cross.training", pattern: .pitch, target: 8, threshold: 15,
        prompt: "Baja", safeForHighPain: false, xp: 20)

    static let caminata = Exercise(
        id: "caminata", name: "Caminata",
        instructions: "Camina a paso firme. Puedes llevar el iPhone en el bolsillo o en la mano.",
        symbol: "figure.walk", pattern: .steps, target: 150, threshold: 0,
        prompt: "", safeForHighPain: true, xp: 20)

    static let escaleras = Exercise(
        id: "escaleras", name: "Escaleras",
        instructions: "Sube un piso de escaleras con calma, usando el pasamanos.",
        symbol: "figure.stairs", pattern: .stairs, target: 1, threshold: 0,
        prompt: "", safeForHighPain: false, xp: 30)

    static let units: [LessonUnit] = [
        LessonUnit(id: "u1", title: "Espalda baja",
                   subtitle: "Movilidad suave para la zona lumbar", colorName: "green", lessons: [
            Lesson(id: "l1", title: "Despertar la espalda", symbol: "sunrise.fill",
                   exercises: [brazos, giro]),
            Lesson(id: "l2", title: "Movilidad lumbar", symbol: "figure.cooldown",
                   exercises: [lateral, giro])
        ]),
        LessonUnit(id: "u2", title: "Carga segura",
                   subtitle: "Piernas fuertes para levantar sin dolor", colorName: "orange", lessons: [
            Lesson(id: "l3", title: "Piernas fuertes", symbol: "figure.cross.training",
                   exercises: [sentadilla]),
            Lesson(id: "l4", title: "Fuerza total", symbol: "shippingbox.fill",
                   exercises: [sentadilla.with(target: 10), brazos])
        ]),
        LessonUnit(id: "u3", title: "Faena en movimiento",
                   subtitle: "Pasos y escaleras durante el turno", colorName: "blue", lessons: [
            Lesson(id: "l5", title: "Caminata de turno", symbol: "figure.walk",
                   exercises: [caminata]),
            Lesson(id: "l6", title: "Escalera al cielo", symbol: "figure.stairs",
                   exercises: [escaleras, caminata.with(target: 100)])
        ])
    ]

    static var allLessons: [Lesson] { units.flatMap(\.lessons) }

    /// Pausa corta para cuando «no alcanzo»: se puede hacer en el camarín o la habitación.
    static let rescue = Lesson(id: "rescate", title: "Rescate de 60 s", symbol: "bolt.heart.fill",
                               exercises: [brazos.with(target: 6), giro.with(target: 6)])

    /// Adapta la pausa al dolor declarado. Con dolor 5/5 solo una caminata corta
    /// (caminar es lo más recomendado para el dolor lumbar).
    static func plan(for lesson: Lesson, pain: Int) -> [Exercise] {
        switch pain {
        case 5:
            return [caminata.with(target: 100)]
        case 4:
            let safe = lesson.exercises.filter(\.safeForHighPain)
            return safe.isEmpty ? [brazos.with(target: 6)] : safe
        default:
            return lesson.exercises
        }
    }
}
