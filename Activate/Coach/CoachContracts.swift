import Foundation

// MARK: - Contrato del coach (congelado salvo la hoja del kine, rediseñada en la ronda kine-ai).

nonisolated enum CoachBackend: String, Sendable, Codable { case foundationModels, rules }

nonisolated struct CoachInput: Sendable, Hashable {
    var profileName: String
    var treatment: Treatment
    var checkIn: DailyCheckIn?
    var moment: Moment
    var minutesAvailable: Int
    var baseRecipe: Recipe
    var allowedKinds: [ActivityKind]
    /// ≤ 10 líneas preformateadas por StatsEngine.
    var historyLines: [String]
    var gentle: Bool
}

nonisolated struct PausePlan: Sendable, Codable, Hashable {
    var activities: [ActivityAssignment]
    var reasoning: String
    /// ≤ 8 palabras, p. ej. "Hoy sin sentadilla: espalda cargada."
    var why: String
    /// ≤ 8 palabras, p. ej. "Vamos, Marco. La ruta completa."
    var startMessage: String
    var backend: CoachBackend
}

nonisolated struct StatsReading: Sendable, Codable, Hashable {
    nonisolated enum Trend: String, Codable, Sendable { case mejorando, estable, empeorando, sinDatos }
    var sentences: [String]
    var trend: Trend
    var backend: CoachBackend
}

// MARK: - Hoja para el kine: Apple Intelligence prepara la consulta, anclado a datos de Swift.
// Swift calcula los hechos (con sus cifras); el modelo solo elige los 3 más relevantes, los explica,
// propone 3 preguntas y un foco. La cifra de cada hallazgo la pone siempre la app.

/// Un hecho calculado por Swift a partir de los registros. `id` es estable (ver `KineFactID`).
nonisolated struct KineFact: Sendable, Codable, Hashable, Identifiable {
    var id: String
    /// Etiqueta corta: "Espalda turno a turno (RDQ-6)".
    var title: String
    /// Cifra corta para el chip: "3,6 → 3,0".
    var value: String
    /// Frase completa con las cifras (va siempre en letra chica bajo el hallazgo).
    var detail: String
    /// La misma idea en palabras simples y sin cifras (tercera persona). Es lo que lee el modelo y el
    /// texto de plantilla del hallazgo.
    var gist: String = ""
    /// Pregunta de plantilla (primera persona) que el paciente puede llevar sobre este hecho.
    var question: String = ""
    /// Foco de plantilla (una frase) si este hecho es el más relevante.
    var focus: String = ""
    /// Va siempre entre los hallazgos (p. ej. una respuesta de alarma), lo elija o no el modelo.
    var mustInclude: Bool = false
}

/// Un hecho elegido y explicado en una frase (tercera persona, sin cifras nuevas).
nonisolated struct KineFinding: Sendable, Codable, Hashable {
    var factID: String
    var sentence: String
}

/// Lo que se lleva a la consulta: 3 hallazgos, 3 preguntas (primera persona) y un foco.
nonisolated struct KineConsult: Sendable, Codable, Hashable {
    var findings: [KineFinding]
    var questions: [String]
    var focus: String
    var backend: CoachBackend
}

/// "En palabras de Marco": lo que escribió (≤ 280 caracteres) y, con IA, un resumen en tercera
/// persona con las zonas y momentos que menciona. Sin IA, `summary` queda vacío y se muestra `original`.
nonisolated struct PatientNote: Sendable, Codable, Hashable {
    static let maxCharacters = 280
    var original: String
    var summary: String
    var zones: [PainZone]
    var moments: [Moment]
    var backend: CoachBackend
}

/// Borrador mientras el modelo escribe (streaming). Todo opcional: llega por partes.
nonisolated struct KineConsultDraft: Sendable, Hashable {
    nonisolated struct Finding: Sendable, Hashable {
        var factID: String?
        var sentence: String?
    }
    var findings: [Finding] = []
    var questions: [String] = []
    var focus: String? = nil
}

/// Documento que se cachea en `SaveData.lastKineSheetJSON` y se exporta (PNG/PDF).
nonisolated struct KineSheet: Sendable, Codable, Hashable {
    /// Formato del JSON cacheado (el formato 1, de 5 bloques en prosa, se ignora al decodificar).
    static let currentFormat = 2
    var format: Int = KineSheet.currentFormat
    var consult: KineConsult
    var note: PatientNote?
    /// Firma de los hechos con que se preparó (avisa si hay datos nuevos desde entonces).
    var factsSignature: String
    var preparedAt: Date
    /// La persona editó algún texto antes de compartir.
    var edited: Bool = false
}

nonisolated protocol Coach: Sendable {
    var backend: CoachBackend { get }
    func plan(_ input: CoachInput) async throws -> PausePlan
    func statsReading(_ summary: StatsSummary, profile: PlayerProfile) async throws -> StatsReading
    func kineConsult(_ facts: [KineFact], profile: PlayerProfile) async throws -> KineConsult
    func patientNote(_ text: String, profile: PlayerProfile) async throws -> PatientNote
}
