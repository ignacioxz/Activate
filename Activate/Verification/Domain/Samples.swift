import Foundation
import simd

// MARK: - Muestras de dominio (sin imports de ARKit/Vision/CoreMotion). Contrato congelado.
// `t` = segundos desde el inicio de la actividad, medidos con ContinuousClock en la fuente.

nonisolated enum JointKey: String, Codable, Sendable, CaseIterable {
    case nose, neck, root, leftShoulder, rightShoulder, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

nonisolated struct JointPoint: Sendable, Codable, Hashable {
    /// Normalizados 0-1, origen abajo-izquierda (convención Vision).
    var x: Double
    var y: Double
    var confidence: Float
}

nonisolated struct PoseSample: Sendable, Codable, Hashable {
    var t: Double
    var joints: [JointKey: JointPoint]
    var fps: Double
}

nonisolated struct FaceSample: Sendable, Codable, Hashable {
    var t: Double
    var isTracked: Bool
    /// Grados, relativos al sistema de mundo (la calibración neutra la hace el verificador).
    var yaw: Double
    var pitch: Double
    var roll: Double
    /// Posición de la cara en el mundo (m) y posición de la cámara expresada en el espacio de la cara (m).
    var position: SIMD3<Float>
    var cameraInFace: SIMD3<Float>
    var lookAt: SIMD3<Float>
    var blinkL: Float
    var blinkR: Float
    /// Suma de |Δ| de 8 blendShapes respecto de la muestra anterior (≈0 = imagen estática).
    var shapeEnergy: Float
}

nonisolated struct MotionSample: Sendable, Codable, Hashable {
    var t: Double
    var userAccel: SIMD3<Double>
    var gravity: SIMD3<Double>
    var rotationRate: SIMD3<Double>
}

nonisolated struct PedometerSample: Sendable, Codable, Hashable {
    var t: Double
    /// Acumulado desde el inicio de la actividad (coprocesador).
    var steps: Int
    var cadence: Double?
    var distance: Double?
}

nonisolated struct ActivitySample: Sendable, Codable, Hashable {
    var t: Double
    var walking: Bool
    var running: Bool
    var stationary: Bool
    var automotive: Bool
    var unknown: Bool
    /// 0 low, 1 medium, 2 high.
    var confidence: Int
}

/// Muestra combinada para la actividad de pasos.
nonisolated enum StepSample: Sendable, Codable, Hashable {
    case pedometer(PedometerSample)
    case motion(MotionSample)
    case activity(ActivitySample)
}

nonisolated struct StroopTrial: Sendable, Codable, Hashable {
    var index: Int
    /// Índice de la palabra y del color de la tinta (0..<4).
    var word: Int
    var ink: Int
    var congruent: Bool
    var isiMs: Int
    var shownAtMs: Int
    var answeredAtMs: Int?
    var answer: Int?
}

/// Interacción de pantalla (Stroop, respiración).
nonisolated enum ScreenSample: Sendable, Codable, Hashable {
    case stroopAnswer(trialIndex: Int, answer: Int, atMs: Int)
    case stroopShown(trialIndex: Int, atMs: Int)
    case touchDown(t: Double)
    case touchUp(t: Double)
}
