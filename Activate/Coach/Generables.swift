import Foundation
#if canImport(FoundationModels)
import FoundationModels

// Dueño: agente "coach". Salidas estructuradas del modelo local (nombres cortos: presupuesto de tokens).

/// Ejercicio propuesto por el modelo. `.anyOf` exige un literal: va la lista fija de los 7 ids
/// del catálogo (`CatalogIDs.all`) y `PlanValidator` filtra después contra los permitidos del día.
@Generable(description: "Un ejercicio del catálogo con su meta")
nonisolated struct EjercicioAsignado {
    @Guide(description: "Id del ejercicio del catálogo", .anyOf(["A1", "A2", "A3", "A5", "A8", "A9", "A10"]))
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
    @Guide(description: "Máximo 8 palabras, con el nombre de pila. Ejemplo: Vamos, Marco. Un minuto.")
    var mensajeInicio: String
}

@Generable(description: "Lectura breve de las estadísticas del turno")
nonisolated struct LecturaDatos {
    @Guide(description: "Exactamente 3 frases cortas, de usted, con las cifras recibidas", .count(3))
    var frases: [String]
    @Guide(description: "Tendencia del RDQ frente al turno anterior", .anyOf(["mejorando", "estable", "empeorando", "sinDatos"]))
    var tendencia: String
}

@Generable(description: "Hoja breve para el kinesiólogo o la mutual, en tercera persona")
nonisolated struct HojaKine {
    @Guide(description: "Cuándo le duele: momento del turno, zona y día del turno. Máximo 40 palabras")
    var cuandoLeDuele: String
    @Guide(description: "Qué ejercicios hizo, solo los verificados, con cifras. Máximo 40 palabras")
    var queHizo: String
    @Guide(description: "Qué lo empeora según las correlaciones recibidas. Máximo 40 palabras")
    var queLoEmpeora: String
    @Guide(description: "Cómo va: RDQ por turno, porcentaje de Mejor, adherencia. Máximo 40 palabras")
    var comoVa: String
    @Guide(description: "Alertas: puntajes altos o nada que informar. Máximo 30 palabras")
    var alertas: String
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
#endif
