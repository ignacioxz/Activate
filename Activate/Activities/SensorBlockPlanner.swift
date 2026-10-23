import Foundation

// Dueño: agente "activities".
// ARSession (cara) y AVCaptureSession (pose) no pueden compartir la cámara frontal: la pausa se
// ejecuta por bloques de sensor y `PauseCoordinator` detiene una fuente antes de arrancar la otra.

nonisolated enum SensorBlockPlanner {
    /// Orden fijo de ejecución: [pasos] → [cámara de cuerpo] → [cara] → [pantalla].
    static let blockOrder: [SensorBlock] = [.pedometer, .cameraPose, .face, .screen]

    /// Agrupa las actividades por bloque de sensor en `blockOrder`, conservando el orden interno.
    /// Los bloques sin actividades no aparecen.
    static func order(_ activities: [ActivityAssignment]) -> [[ActivityAssignment]] {
        blockOrder.compactMap { block in
            let group = activities.filter { $0.kind.sensorBlock == block }
            return group.isEmpty ? nil : group
        }
    }

    /// Aplana los grupos en una sola lista (orden de ejecución).
    static func flatten(_ groups: [[ActivityAssignment]]) -> [ActivityAssignment] {
        groups.flatMap { $0 }
    }

    /// Lista plana ya ordenada por bloque.
    static func ordered(_ activities: [ActivityAssignment]) -> [ActivityAssignment] {
        flatten(order(activities))
    }

    /// Bloques presentes, en orden de ejecución.
    static func blocks(_ activities: [ActivityAssignment]) -> [SensorBlock] {
        order(activities).compactMap { $0.first?.kind.sensorBlock }
    }

    /// Bloque de un grupo ya armado por `order`.
    static func block(of group: [ActivityAssignment]) -> SensorBlock? {
        group.first?.kind.sensorBlock
    }

    /// Entre `from` y `to` hay que soltar la cámara frontal (stop de una fuente antes del start de la otra).
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
