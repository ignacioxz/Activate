import Foundation

/// Tipo de día según el sistema de turnos de la faena.
enum DayKind: String, Codable {
    case turno
    case descanso
}

/// Sistemas de turno habituales en minería.
enum Roster: String, Codable, CaseIterable, Identifiable {
    case sieteXSiete = "7x7"
    case cuatroXTres = "4x3"
    case diezXDiez = "10x10"
    case catorceXCatorce = "14x14"

    var id: String { rawValue }

    var workDays: Int {
        switch self {
        case .sieteXSiete: 7
        case .cuatroXTres: 4
        case .diezXDiez: 10
        case .catorceXCatorce: 14
        }
    }

    var restDays: Int {
        switch self {
        case .sieteXSiete: 7
        case .cuatroXTres: 3
        case .diezXDiez: 10
        case .catorceXCatorce: 14
        }
    }
}

/// Momento en que aparece el dolor, para dar recomendaciones específicas.
enum PainContext: String, Codable, CaseIterable, Identifiable {
    case general = "En general"
    case levantarCarga = "Al levantar carga"
    case peakTurno = "Peak del turno"
    case cabina = "En cabina / manejando"

    var id: String { rawValue }
}

struct PainEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var level: Int
    var context: PainContext
}

/// Registro diario de pausas.
struct DayRecord: Codable, Hashable {
    var pausesDone = 0
    /// El trabajador marcó «Hoy no alcancé» y usó un casco protector para salvar la racha.
    var usedShield = false
}

/// Cómo detecta el iPhone cada ejercicio. Los de movimiento se hacen con el iPhone
/// en las dos manos frente al pecho, mirando la pantalla.
enum MotionPattern: String, Codable {
    /// Giro de tronco a la derecha y a la izquierda (giroscopio).
    case twist
    /// Inclinación hacia un lado y al otro.
    case sideBend
    /// Inclinación del iPhone adelante/atrás, ida y vuelta (brazos arriba, sentadilla).
    case pitch
    /// Pasos del podómetro.
    case steps
    /// Pisos subidos (podómetro + barómetro de Apple).
    case stairs
}

struct Exercise: Identifiable, Hashable {
    let id: String
    let name: String
    let instructions: String
    let symbol: String
    let pattern: MotionPattern
    /// Repeticiones, pasos o pisos según el patrón.
    let target: Int
    /// Grados que hay que mover el iPhone para que cuente la repetición.
    let threshold: Double
    /// Indicación corta que se muestra al empezar.
    let prompt: String
    /// Puede hacerse con dolor 4–5/5.
    let safeForHighPain: Bool
    let xp: Int

    /// Ejercicio detectado por movimiento (no por podómetro).
    var usesMotion: Bool { pattern != .steps && pattern != .stairs }

    var unitLabel: String {
        switch pattern {
        case .steps: "pasos"
        case .stairs: "pisos"
        default: "reps"
        }
    }

    func with(target newTarget: Int) -> Exercise {
        Exercise(id: id, name: name, instructions: instructions, symbol: symbol, pattern: pattern,
                 target: newTarget, threshold: threshold, prompt: prompt, safeForHighPain: safeForHighPain, xp: xp)
    }
}

struct Lesson: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let exercises: [Exercise]
}

struct LessonUnit: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let colorName: String
    let lessons: [Lesson]
}

enum Badge: String, Codable, CaseIterable, Identifiable {
    case primeraPausa, doblete, racha5, diezPausas, escalador, caminante, honestidad, cuidado, rutaCompleta

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rutaCompleta: "Ruta completa"
        case .primeraPausa: "Primera pausa"
        case .doblete: "Doblete"
        case .racha5: "Racha de 5 turnos"
        case .diezPausas: "Espalda de acero"
        case .escalador: "Escalador de faena"
        case .caminante: "Caminante del rajo"
        case .honestidad: "Bitácora honesta"
        case .cuidado: "Me cuido"
        }
    }

    var detail: String {
        switch self {
        case .rutaCompleta: "Completaste las 3 paradas de la ruta del día."
        case .primeraPausa: "Completaste tu primera pausa activa."
        case .doblete: "Pausa activa dos días seguidos."
        case .racha5: "5 días de turno con pausa sin cortar la racha."
        case .diezPausas: "10 pausas activas completadas."
        case .escalador: "10 pisos de escalera en un día."
        case .caminante: "10.000 pasos en un día."
        case .honestidad: "Registraste tu dolor en 5 días distintos."
        case .cuidado: "Hiciste una pausa adaptada con dolor alto."
        }
    }

    var symbol: String {
        switch self {
        case .rutaCompleta: "map.fill"
        case .primeraPausa: "star.fill"
        case .doblete: "flame.fill"
        case .racha5: "calendar.badge.checkmark"
        case .diezPausas: "shield.lefthalf.filled"
        case .escalador: "figure.stairs"
        case .caminante: "figure.walk"
        case .honestidad: "book.closed.fill"
        case .cuidado: "heart.fill"
        }
    }
}

enum ActivityGoal: String, CaseIterable {
    case steps8000
    case floors10

    var title: String {
        switch self {
        case .steps8000: "8.000 pasos"
        case .floors10: "10 pisos"
        }
    }

    var target: Int {
        switch self {
        case .steps8000: 8000
        case .floors10: 10
        }
    }

    var xp: Int { 30 }
}

struct RewardLine: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let xp: Int
}

struct SessionReward {
    let lines: [RewardLine]
    let totalXP: Int
    let nuggets: Int
    let shieldEarned: Bool
    let newBadges: [Badge]
    let streak: Int
}
