import Foundation

// Dueño: agente "activities".
// La pausa se ejecuta por bloques de sensor y `PauseCoordinator` detiene una fuente antes de arrancar la
// otra. Todas las actividades de cámara usan ARSession sin vista (bloque `face`): la sentadilla y la
// extensión lumbar en las manos comparten bloque con cuello y pestañeo, y entre ellas basta con que cada
// fuente pause su `ARSession` al terminar (no hay relevo `AVCaptureSession` ↔ `ARSession`).

nonisolated enum SensorBlockPlanner {
    /// Ordena según `ActivityKind.sessionOrder` (orden fijo pedido por el usuario) y agrupa en tramos
    /// consecutivos del mismo sensor; un mismo bloque puede repetirse (p. ej. cara → pantalla → cara).
    static func order(_ activities: [ActivityAssignment]) -> [[ActivityAssignment]] {
        var groups: [[ActivityAssignment]] = []
        for a in ordered(activities) {
            if let last = groups.last?.last, last.kind.sensorBlock == a.kind.sensorBlock {
                groups[groups.count - 1].append(a)
            } else {
                groups.append([a])
            }
        }
        return groups
    }

    /// Aplana los grupos en una sola lista (orden de ejecución).
    static func flatten(_ groups: [[ActivityAssignment]]) -> [ActivityAssignment] {
        groups.flatMap { $0 }
    }

    /// Lista plana en el orden fijo de la sesión (sin actividades retiradas).
    static func ordered(_ activities: [ActivityAssignment]) -> [ActivityAssignment] {
        ActivityKind.inSessionOrder(activities.filter { !$0.kind.isRetired }, kind: { $0.kind })
    }

    /// Bloques presentes, en orden de ejecución.
    static func blocks(_ activities: [ActivityAssignment]) -> [SensorBlock] {
        order(activities).compactMap { $0.first?.kind.sensorBlock }
    }

    /// Bloque de un grupo ya armado por `order`.
    static func block(of group: [ActivityAssignment]) -> SensorBlock? {
        group.first?.kind.sensorBlock
    }

    /// Entre `from` y `to` hay que esperar el relevo de la cámara frontal (dos bloques de cámara distintos).
    /// Con un solo bloque de cámara (`face`) nunca ocurre; se conserva la regla para el coordinador.
    static func needsCameraHandoff(from: SensorBlock, to: SensorBlock) -> Bool {
        from != to && from.usesFrontCamera && to.usesFrontCamera
    }

    /// Transiciones entre bloques consecutivos que requieren el estado "preparando cámara".
    static func cameraHandoffs(_ activities: [ActivityAssignment]) -> [(from: SensorBlock, to: SensorBlock)] {
        let present = blocks(activities)
        guard present.count > 1 else { return [] }
        return zip(present, present.dropFirst()).compactMap { pair in
            needsCameraHandoff(from: pair.0, to: pair.1) ? (from: pair.0, to: pair.1) : nil
        }
    }
}
