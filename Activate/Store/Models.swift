import Foundation

// MARK: - Contrato de datos (congelado). Todo Codable, Sendable y nonisolated.
// Los agentes agregan comportamiento con extensiones en sus propios archivos; no editan este.

nonisolated enum ShiftType: String, Codable, CaseIterable, Sendable {
    case day, night
    /// Hora local a la que empieza el "día laboral".
    var dayBoundaryHour: Int { self == .day ? 4 : 12 }
    var title: String { self == .day ? "Turno de día" : "Turno de noche" }
}

nonisolated enum Roster: String, Codable, CaseIterable, Sendable, Identifiable {
    case sieteXSiete = "7x7", cuatroXTres = "4x3", diezXDiez = "10x10", catorceXCatorce = "14x14"
    var id: String { rawValue }
    var workDays: Int { switch self { case .sieteXSiete: 7; case .cuatroXTres: 4; case .diezXDiez: 10; case .catorceXCatorce: 14 } }
    var restDays: Int { switch self { case .sieteXSiete: 7; case .cuatroXTres: 3; case .diezXDiez: 10; case .catorceXCatorce: 14 } }
}

nonisolated enum DayKind: String, Codable, Sendable { case turno, descanso }

nonisolated enum Treatment: String, Codable, Sendable { case usted, tu }

nonisolated enum PainZone: String, Codable, CaseIterable, Sendable, Identifiable {
    case lumbar, cuello, hombro, otra
    var id: String { rawValue }
    var title: String { switch self { case .lumbar: "Espalda baja"; case .cuello: "Cuello"; case .hombro: "Hombro"; case .otra: "Otra zona" } }
}

/// Dónde le dolió (registro rápido "Me duele ahora").
nonisolated enum PainContext: String, Codable, CaseIterable, Sendable, Identifiable {
    case enCabina, alBajar, enElBus, enCasa
    var id: String { rawValue }
    var title: String { switch self { case .enCabina: "En cabina"; case .alBajar: "Al bajar"; case .enElBus: "En el bus"; case .enCasa: "En casa" } }
}

nonisolated enum PostResponse: String, Codable, CaseIterable, Sendable {
    case mejor, igual, peor
    var title: String { switch self { case .mejor: "Mejor"; case .igual: "Igual"; case .peor: "Peor" } }
}

nonisolated enum CheckInSource: String, Codable, Sendable { case pausa, meDueleAhora }

/// Cuestionario Roland-Morris chileno abreviado (Guic, Galdames y Rebolledo, Rev Med Chile 2014; 142: 716-722).
/// Frases e instrucción textuales del Anexo 1. No modificar el texto.
nonisolated enum RDQ6 {
    static let instruction = "A continuación hay algunas frases usadas por las personas para describir lo que sienten cuando tienen dolor de espalda. Sólo marque SÍ cuando esté seguro que esa frase describe lo que usted siente hoy."
    static let stem = "Debido a su dolor de espalda:"
    static let items: [String] = [
        "Camina más lentamente que lo habitual.",
        "Trata de que otras personas hagan cosas por usted.",
        "Sólo está de pie por períodos corto de tiempo.",
        "Trata de no agacharse o arrodillarse.",
        "Sólo camina distancias cortas.",
        "Evita hacer trabajos pesados en la casa.",
    ]
    /// Índices útiles para las reglas de seguridad.
    static let itemWalksSlower = 0, itemOthersDoThings = 1, itemStandsShortPeriods = 2, itemAvoidsBending = 3, itemWalksShortDistances = 4, itemAvoidsHeavyWork = 5
    static let alarmQuestions: [String] = [
        "¿El dolor le baja a la pierna con hormigueo o pérdida de fuerza?",
        "¿Tiene problemas nuevos para orinar o controlar el intestino?",
        "¿Tuvo un golpe o caída reciente, fiebre o baja de peso sin explicación?",
    ]
    static let citation = "Guic E, Galdames S, Rebolledo P. Adaptación cultural y validación de la versión chilena del Cuestionario de Discapacidad Roland-Morris. Rev Med Chile 2014; 142: 716-722."
    static let maxScore = 6
    /// Puntaje desde el cual el plan pasa a "suave".
    static let gentlePlanThreshold = 5
}

nonisolated struct DailyCheckIn: Codable, Identifiable, Sendable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var workDayKey: String
    var turnoKey: String
    var source: CheckInSource
    /// 6 respuestas en el orden de `RDQ6.items` (vacío en registros "Me duele ahora").
    var answers: [Bool]
    /// Respuestas a `RDQ6.alarmQuestions` cuando se preguntaron (vacío si no).
    var alarmAnswers: [Bool] = []
    /// Zona principal (la primera marcada). Se mantiene por compatibilidad con datos antiguos.
    var zone: PainZone
    /// Todas las zonas marcadas (selección múltiple). `nil` en registros antiguos: usar `allZones`.
    var zones: [PainZone]? = nil
    var moment: Moment?
    var context: PainContext?

    var score: Int { answers.filter { $0 }.count }
    var hasAlarm: Bool { alarmAnswers.contains(true) }
}

nonisolated enum VerificationLevel: Int, Codable, Comparable, Sendable, CaseIterable {
    case simulated = 0, suspicious = 1, reduced = 2, full = 3
    nonisolated static func < (a: VerificationLevel, b: VerificationLevel) -> Bool { a.rawValue < b.rawValue }
    var title: String {
        switch self {
        case .full: "Verificada"
        case .reduced: "Contada"
        case .suspicious: "No pude verificarla"
        case .simulated: "Simulada"
        }
    }
}

nonisolated struct Anomaly: Codable, Sendable, Hashable {
    nonisolated enum Severity: String, Codable, Sendable { case soft, hard }
    var kind: String
    var severity: Severity
    /// Segundos desde el inicio de la actividad (reloj monotónico).
    var at: Double
    var detail: String? = nil
}

nonisolated enum ActivityMetrics: Codable, Sendable, Hashable {
    case steps(count: Int, meanCadence: Double?, walkingFraction: Double?, rmsPeak: Double?)
    case reps(count: Int, minDescentRatio: Double?, meanRepSeconds: Double?)
    case neck(rotations: Int, flexions: Int, tilts: Int, maxYaw: Double, maxPitch: Double, maxRoll: Double, cueMatches: Int, cueMismatches: Int)
    case eyes(completeBlinks: Int, partialBlinks: Int, blinksPerMinute: Double, farGazeSeconds: Double)
    case stroop(trials: Int, valid: Int, accuracy: Double, medianRTms: Int, medianCongruentRTms: Int, medianIncongruentRTms: Int, anticipations: Int, lapses: Int, seed: UInt64)
    case breath(cycles: Int)
    case none
}

nonisolated struct ActivityResult: Codable, Identifiable, Sendable, Hashable {
    var id: UUID = UUID()
    var kind: ActivityKind
    var target: Int
    var achieved: Int
    var durationSeconds: Double
    var completed: Bool
    var level: VerificationLevel
    var metrics: ActivityMetrics
    var anomalies: [Anomaly]
    var skipped: Bool = false
}

nonisolated enum KeyBacking: String, Codable, Sendable { case secureEnclave, software }

nonisolated enum RecipeKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case relevo60, colacion3, campamento5
    var id: String { rawValue }
    var title: String { switch self { case .relevo60: "Relevo · 1 min"; case .colacion3: "Colación · 3 min"; case .campamento5: "Campamento · 5 min" } }
    var minutes: Int { switch self { case .relevo60: 1; case .colacion3: 3; case .campamento5: 5 } }
}

nonisolated struct PauseSession: Codable, Identifiable, Sendable, Hashable {
    var id: UUID = UUID()
    var workDayKey: String
    var turnoKey: String
    var recipe: RecipeKind
    var moment: Moment
    var startedAt: Date
    var endedAt: Date? = nil
    var monotonicSeconds: Double = 0
    var checkInScore: Int? = nil
    var checkInAnswers: [Bool] = []
    var zone: PainZone = .lumbar
    /// Todas las zonas del check-in (selección múltiple). `nil` en sesiones antiguas: usar `allZones`.
    var zones: [PainZone]? = nil
    var postResponse: PostResponse? = nil
    var activities: [ActivityResult] = []
    /// Vale para racha / Doblete / Tiro limpio.
    var counted: Bool = false
    var level: VerificationLevel = .simulated
    var simulated: Bool = false
    var payloadData: Data? = nil
    var signature: Data? = nil
    var keyID: String? = nil
    var backing: KeyBacking? = nil
    var coachNote: String? = nil
    var integrityFlags: [Anomaly] = []
    var xpEarned: Int = 0
}

nonisolated struct WorkDay: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var id: String { key }
    var kind: DayKind
    var dayInBlock: Int
    var turnoKey: String
    var countedPauses: Int = 0
    var cascoUsed: Bool = false
}

nonisolated enum Badge: String, Codable, CaseIterable, Sendable, Identifiable {
    case primeraPausa, doblete, relevoCumplido, rajoCompleto, tiroLimpio, caminanteDelRajo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .primeraPausa: "Primera pausa"
        case .doblete: "Doblete"
        case .relevoCumplido: "Relevo cumplido"
        case .rajoCompleto: "Rajo completo"
        case .tiroLimpio: "Tiro limpio 7/7"
        case .caminanteDelRajo: "Caminante del rajo"
        }
    }
    var detail: String {
        switch self {
        case .primeraPausa: "Hizo su primera pausa verificada."
        case .doblete: "Dos días seguidos con pausa."
        case .relevoCumplido: "Cinco pausas de relevo verificadas."
        case .rajoCompleto: "Pausa de 5 minutos completa en el campamento."
        case .tiroLimpio: "Los 7 días del turno con pausa."
        case .caminanteDelRajo: "2.500 pasos verificados en pausas."
        }
    }
    var symbol: String {
        switch self {
        case .primeraPausa: "star.fill"
        case .doblete: "flame.fill"
        case .relevoCumplido: "clock.badge.checkmark"
        case .rajoCompleto: "mountain.2.fill"
        case .tiroLimpio: "checkmark.seal.fill"
        case .caminanteDelRajo: "figure.walk"
        }
    }
}

nonisolated struct PlayerProfile: Codable, Sendable, Hashable {
    var name: String = "Marco"
    var treatment: Treatment = .usted
    var roster: Roster = .sieteXSiete
    var rosterStart: Date
    var shiftType: ShiftType = .day
    var usualZone: PainZone = .lumbar
    /// Zonas habituales (selección múltiple). `nil` en perfiles antiguos: usar `allUsualZones`.
    var usualZones: [PainZone]? = nil
    var xp: Int = 0
    var cascos: Int = 1
    var badges: Set<Badge> = []
    var outdoorMode: Bool = false
    var consentGiven: Bool = false
    var notificationsOptIn: Bool = false
    var onboardingDone: Bool = false
}

nonisolated enum CoachOverride: String, Codable, CaseIterable, Sendable { case auto, rules, ai }

nonisolated struct DemoConfig: Codable, Sendable, Hashable {
    var enabled: Bool = false
    var shortTargets: Bool = false
    var coachOverride: CoachOverride = .auto
    var notificationsMuted: Bool = true
}

nonisolated struct SaveData: Codable, Sendable {
    var version: Int = 1
    var profile: PlayerProfile
    var workDays: [String: WorkDay] = [:]
    var checkIns: [DailyCheckIn] = []
    var sessions: [PauseSession] = []
    var demo: DemoConfig = DemoConfig()
    /// Lectura del coach cacheada por día laboral (texto ya redactado).
    var statsReadingCache: [String: String] = [:]
    var lastKineSheetJSON: String? = nil
}


// MARK: - Zonas múltiples (compatibles con datos guardados antes de la selección múltiple)

extension PainZone {
    /// Normaliza una selección: sin duplicados y en el orden de `allCases`; nunca vacía.
    nonisolated static func normalized(_ zones: [PainZone], fallback: PainZone = .lumbar) -> [PainZone] {
        let set = Set(zones)
        let ordered = PainZone.allCases.filter { set.contains($0) }
        return ordered.isEmpty ? [fallback] : ordered
    }

    /// "Espalda baja y cuello", "Espalda baja, cuello y hombro".
    nonisolated static func listTitle(_ zones: [PainZone]) -> String {
        let titles = normalized(zones).map(\.title)
        guard titles.count > 1 else { return titles.first ?? "" }
        return titles.dropLast().joined(separator: ", ") + " y " + (titles.last ?? "")
    }
}

extension DailyCheckIn {
    var allZones: [PainZone] { PainZone.normalized(zones ?? [zone], fallback: zone) }
    /// Asigna la selección completa y deja `zone` como la primera.
    mutating func setZones(_ newValue: [PainZone]) {
        let n = PainZone.normalized(newValue, fallback: zone)
        zones = n
        zone = n[0]
    }
}

extension PauseSession {
    var allZones: [PainZone] { PainZone.normalized(zones ?? [zone], fallback: zone) }
    mutating func setZones(_ newValue: [PainZone]) {
        let n = PainZone.normalized(newValue, fallback: zone)
        zones = n
        zone = n[0]
    }
}

extension PlayerProfile {
    var allUsualZones: [PainZone] { PainZone.normalized(usualZones ?? [usualZone], fallback: usualZone) }
    mutating func setUsualZones(_ newValue: [PainZone]) {
        let n = PainZone.normalized(newValue, fallback: usualZone)
        usualZones = n
        usualZone = n[0]
    }
}
