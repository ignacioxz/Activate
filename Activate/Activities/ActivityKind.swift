import Foundation

/// Bloque de sensor que necesita una actividad (ARSession y AVCaptureSession no pueden convivir).
nonisolated enum SensorBlock: String, Codable, Sendable { case pedometer, cameraPose, face, screen }

/// Catálogo del pitch (7 actividades). Contrato congelado: el agente de Activities agrega copy e
/// instrucciones largas con extensiones; no cambia los casos ni las propiedades de aquí.
nonisolated enum ActivityKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case extensionLumbar = "A1"
    case pasos = "A2"
    case sentadilla = "A3"
    case cuello = "A5"
    case respiracion = "A8"
    case ojos = "A9"
    case stroop = "A10"

    var id: String { rawValue }

    /// Orden fijo de ejecución en toda pausa (pedido del usuario), aunque la receta o las reglas
    /// descarten algunas: caminata → (pararse y sentarse) → sentadillas → movilidad cervical → Stroop
    /// → pestañeo → extensión lumbar.
    static let sessionOrder: [ActivityKind] = [.pasos, .sentadilla, .cuello, .stroop, .ojos, .extensionLumbar]

    /// Posición en `sessionOrder` (las retiradas van al final).
    var sessionRank: Int { Self.sessionOrder.firstIndex(of: self) ?? Self.sessionOrder.count }

    /// Retiradas del catálogo: no se ofrecen en ninguna pausa (se conservan para leer sesiones antiguas).
    var isRetired: Bool { self == .respiracion }

    /// Ordena según `sessionOrder` conservando el orden relativo de los empates.
    static func inSessionOrder<T>(_ items: [T], kind: (T) -> ActivityKind) -> [T] {
        items.enumerated()
            .sorted { (kind($0.element).sessionRank, $0.offset) < (kind($1.element).sessionRank, $1.offset) }
            .map(\.element)
    }

    var name: String {
        switch self {
        case .extensionLumbar: "Extensión lumbar"
        case .pasos: "Camine"
        case .sentadilla: "Sentadilla minera"
        case .cuello: "Movilidad cervical"
        case .respiracion: "Respire con la guata"
        case .ojos: "Pestañeo completo"
        case .stroop: "Reflejos 60"
        }
    }

    var symbol: String {
        switch self {
        case .extensionLumbar: "figure.flexibility"
        case .pasos: "figure.walk"
        case .sentadilla: "figure.cross.training"
        case .cuello: "face.smiling"
        case .respiracion: "wind"
        case .ojos: "eye"
        case .stroop: "brain.head.profile"
        }
    }

    var sensorBlock: SensorBlock {
        switch self {
        case .pasos: .pedometer
        case .extensionLumbar, .sentadilla: .cameraPose
        case .cuello, .ojos: .face
        case .respiracion, .stroop: .screen
        }
    }

    /// Unidad del contador.
    var unit: String {
        switch self {
        case .pasos: "pasos"
        case .extensionLumbar, .sentadilla: "reps"
        case .cuello: "movimientos"
        case .respiracion: "ciclos"
        case .ojos: "parpadeos"
        case .stroop: "ensayos"
        }
    }

    /// Meta real y meta corta de demo.
    var defaultTarget: Int {
        switch self {
        case .extensionLumbar: 10
        case .pasos: 250
        case .sentadilla: 10
        case .cuello: 15
        case .respiracion: 6
        case .ojos: 15
        case .stroop: 40
        }
    }

    var demoTarget: Int {
        switch self {
        case .extensionLumbar: 5
        case .pasos: 30
        case .sentadilla: 5
        case .cuello: 6
        case .respiracion: 3
        case .ojos: 8
        case .stroop: 20
        }
    }

    var baseXP: Int {
        switch self {
        case .pasos: 20
        case .sentadilla, .extensionLumbar: 15
        case .cuello, .ojos: 12
        case .stroop: 10
        case .respiracion: 8
        }
    }

    /// El teléfono debe estar apoyado (cámara de cuerpo entero).
    var requiresPhoneSupported: Bool { sensorBlock == .cameraPose }

    /// Verificación débil por naturaleza → nivel máximo `reduced`.
    var weakByNature: Bool { self == .respiracion }
}

nonisolated struct ActivityAssignment: Codable, Sendable, Hashable, Identifiable {
    var kind: ActivityKind
    var target: Int
    var id: String { kind.rawValue }
}

nonisolated struct Recipe: Sendable, Hashable, Codable {
    var kind: RecipeKind
    var activities: [ActivityAssignment]
    var title: String { kind.title }
    var minutes: Int { kind.minutes }
}

/// Parámetros de verificación por actividad (valores iniciales; se calibran en dispositivo).
nonisolated struct VerificationSpec: Sendable, Hashable, Codable {
    var kind: ActivityKind
    var target: Int
    var minDurationSeconds: Double
    var maxDurationSeconds: Double
    var demo: Bool

    static func standard(for kind: ActivityKind, target: Int? = nil, demo: Bool = false) -> VerificationSpec {
        let t = target ?? (demo ? kind.demoTarget : kind.defaultTarget)
        let minDur: Double
        let maxDur: Double
        switch kind {
        case .pasos: minDur = demo ? 10 : 100; maxDur = 600
        case .sentadilla, .extensionLumbar: minDur = Double(t) * 0.6; maxDur = 240
        case .cuello: minDur = Double(t) * 0.8; maxDur = 180
        case .ojos: minDur = demo ? 8 : 20; maxDur = 180
        case .stroop: minDur = demo ? 15 : 45; maxDur = 90
        case .respiracion: minDur = Double(t) * 8; maxDur = 240
        }
        return VerificationSpec(kind: kind, target: t, minDurationSeconds: minDur, maxDurationSeconds: maxDur, demo: demo)
    }
}
