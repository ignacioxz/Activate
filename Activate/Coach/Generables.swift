import Foundation
#if canImport(FoundationModels)
import FoundationModels

// Dueño: agente "coach" (hoja del kine: paquete kine-ai). Salidas estructuradas del modelo local
// (nombres cortos: presupuesto de tokens).

/// Ejercicio propuesto por el modelo. `.anyOf` exige un literal: va la lista fija de los 7 ids
/// vigentes del catálogo (`CatalogIDs.all`, sin la respiración retirada) y `PlanValidator` filtra
/// después contra los permitidos del día.
@Generable(description: "Un ejercicio del catálogo con su meta")
nonisolated struct EjercicioAsignado {
    @Guide(description: "Id del ejercicio del catálogo", .anyOf(["A1", "A2", "A3", "A4", "A5", "A9", "A10"]))
    var id: String
    @Guide(description: "Meta: repeticiones, pasos, movimientos, parpadeos, ciclos o ensayos", .range(1...300))
    var reps: Int
}

@Generable(description: "La pausa activa de hoy")
nonisolated struct PausaDelDia {
    @Guide(description: "Máximo 2 frases: qué cambia respecto de la receta base y por qué")
    var razonamiento: String
    @Guide(description: "Ejercicios de hoy en orden, solo ids permitidos", .count(1...5))
    var ejercicios: [EjercicioAsignado]
    @Guide(description: "Máximo 8 palabras, de usted. Ejemplo: Hoy sin sentadilla: espalda cargada.")
    var porQue: String
    @Guide(description: "Máximo 8 palabras, con el nombre de pila. Ejemplo: Vamos, Marco. La ruta completa.")
    var mensajeInicio: String
}

@Generable(description: "Lectura breve de las estadísticas del turno")
nonisolated struct LecturaDatos {
    @Guide(description: "Exactamente 3 frases cortas, de usted, con las cifras recibidas", .count(3))
    var frases: [String]
    @Guide(description: "Tendencia del RDQ frente al turno anterior", .anyOf(["mejorando", "estable", "empeorando", "sinDatos"]))
    var tendencia: String
}

// MARK: - Consulta con el kine (consulta-kine-v1)
// `.anyOf` exige un literal: va la lista fija de ids de `KineFactID.all` (los tests comparan ambas).
// El modelo ve solo los hechos presentes en el prompt; `KineConsultRules.validate` descarta el resto.

@Generable(description: "Un hecho de la lista, elegido y explicado para el kinesiólogo")
nonisolated struct Hallazgo {
    @Guide(description: "Id del hecho elegido, tal como aparece en la lista", .anyOf(["rdq_tendencia", "peor_fase_turno", "contexto_dominante", "mejora_post", "adherencia", "item_frecuente", "ejercicio_que_ayuda", "alertas"]))
    var datoId: String
    @Guide(description: "Una frase de máximo 20 palabras, en tercera persona (el paciente), que dice con otras palabras lo que dice el resumen de ese hecho. Sin números.")
    var frase: String
}

@Generable(description: "Preparación de la próxima consulta con el kinesiólogo")
nonisolated struct ConsultaKine {
    @Guide(description: "Los 3 hechos más útiles para el kinesiólogo, sin repetir", .count(3))
    var hallazgos: [Hallazgo]
    @Guide(description: "3 preguntas que el paciente le hará al kinesiólogo, en primera persona, máximo 18 palabras cada una", .count(3))
    var preguntas: [String]
    @Guide(description: "Una frase: en qué conviene trabajar en la próxima sesión, sin diagnosticar")
    var foco: String
}

@Generable(description: "Resumen de lo que el paciente quiere contarle al kinesiólogo")
nonisolated struct NotaPaciente {
    @Guide(description: "1 o 2 frases en tercera persona (el paciente), máximo 40 palabras, solo con lo que dice el texto")
    var resumen: String
    @Guide(description: "Zonas del cuerpo que menciona: lumbar (espalda baja, cintura), cuello, hombro u otra", .maximumCount(4), .element(.anyOf(["lumbar", "cuello", "hombro", "otra"])))
    var zonas: [String]
    @Guide(description: "Momentos del turno que menciona: entrada (al empezar), colacion (almuerzo), salida (al terminar o bajar del camión), campamento (después del turno)", .maximumCount(4), .element(.anyOf(["entrada", "colacion", "salida", "campamento"])))
    var momentos: [String]
}

// MARK: - Conversión a dominio (texto limpiado y acotado; la validación de ids vive en PlanValidator)

extension PausaDelDia {
    var proposal: [ProposedExercise] { ejercicios.map { ProposedExercise(id: $0.id, reps: $0.reps) } }
}

extension LecturaDatos {
    var trendValue: StatsReading.Trend? {
        StatsReading.Trend(rawValue: tendencia.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension ConsultaKine {
    var proposal: KineConsultRules.Proposal {
        KineConsultRules.Proposal(findings: hallazgos.map { KineFinding(factID: $0.datoId, sentence: $0.frase) },
                                  questions: preguntas, focus: foco)
    }
}

extension ConsultaKine.PartiallyGenerated {
    /// Lo que llegó hasta ahora, en tipos de la app (Sendable).
    var draft: KineConsultDraft {
        KineConsultDraft(findings: (hallazgos ?? []).map { KineConsultDraft.Finding(factID: $0.datoId, sentence: $0.frase) },
                         questions: preguntas ?? [],
                         focus: foco)
    }
}
#endif
