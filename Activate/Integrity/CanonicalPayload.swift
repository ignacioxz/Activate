import Foundation

// Dueño: agente "integrity".
//
// Representación canónica de una `PauseSession` para firmar. Es lo que queda bajo la firma:
// nunca incluye `payloadData`, `signature`, `keyID` ni `backing`, ni campos que se completan
// después de firmar (`xpEarned`, `coachNote`). La codificación es determinista: claves
// ordenadas, barras sin escapar, fechas ISO 8601 (UTC) y, donde se puede, solo enteros
// (milisegundos, décimas, milésimas) para no depender del formato de los flotantes.

nonisolated struct CanonicalPayload: Codable, Sendable, Hashable {
    /// Versión del esquema del payload. Sube si cambia la forma; las sesiones viejas
    /// siguen verificando porque `verify` nunca re-codifica.
    /// v2: `checkIn.zones` (selección múltiple, opcional; ausente en payloads v1).
    static let currentVersion = 2

    var v: Int = CanonicalPayload.currentVersion
    var id: UUID
    var workDayKey: String
    var turnoKey: String
    var recipe: RecipeKind
    var moment: Moment
    var startedAt: Date
    var endedAt: Date?
    /// Duración medida con reloj monotónico (ContinuousClock), en milisegundos.
    var monotonicMs: Int
    var checkIn: CheckIn?
    var postResponse: PostResponse?
    var activities: [Activity]
    var counted: Bool
    var level: VerificationLevel
    var simulated: Bool
    var integrityFlags: [Flag]

    nonisolated struct CheckIn: Codable, Sendable, Hashable {
        var score: Int?
        var answers: [Bool]
        /// Zona principal (la primera marcada).
        var zone: PainZone
        /// Todas las zonas marcadas (v2). `nil` en sesiones sin selección múltiple: no se codifica,
        /// así sus bytes son los mismos que en v1.
        var zones: [PainZone]? = nil
    }

    nonisolated struct Flag: Codable, Sendable, Hashable {
        var kind: String
        var severity: Anomaly.Severity
        /// Milisegundos desde el inicio (reloj monotónico).
        var atMs: Int
        var detail: String?

        init(_ a: Anomaly) {
            kind = a.kind
            severity = a.severity
            atMs = CanonicalPayload.ms(a.at)
            detail = a.detail
        }
    }

    nonisolated struct Activity: Codable, Sendable, Hashable {
        var id: UUID
        var kind: ActivityKind
        var target: Int
        var achieved: Int
        var durationMs: Int
        var completed: Bool
        var skipped: Bool
        var level: VerificationLevel
        var metrics: Metrics
        var anomalies: [Flag]

        init(_ r: ActivityResult) {
            id = r.id
            kind = r.kind
            target = r.target
            achieved = r.achieved
            durationMs = CanonicalPayload.ms(r.durationSeconds)
            completed = r.completed
            skipped = r.skipped
            level = r.level
            metrics = Metrics(r.metrics)
            anomalies = r.anomalies.map(Flag.init)
        }
    }

    /// Métricas con números enteros: `Deci` = décimas, `Milli` = milésimas, `Ms` = milisegundos.
    nonisolated enum Metrics: Codable, Sendable, Hashable {
        case steps(count: Int, meanCadenceDeci: Int?, walkingMilli: Int?, rmsPeakMilli: Int?)
        case reps(count: Int, minDescentRatioMilli: Int?, meanRepMs: Int?)
        case neck(rotations: Int, flexions: Int, tilts: Int, maxYawDeci: Int, maxPitchDeci: Int, maxRollDeci: Int, cueMatches: Int, cueMismatches: Int)
        case eyes(completeBlinks: Int, partialBlinks: Int, blinksPerMinuteDeci: Int, farGazeMs: Int)
        case stroop(trials: Int, valid: Int, accuracyMilli: Int, medianRTms: Int, medianCongruentRTms: Int, medianIncongruentRTms: Int, anticipations: Int, lapses: Int, seed: UInt64)
        case breath(cycles: Int)
        case none

        init(_ m: ActivityMetrics) {
            switch m {
            case let .steps(count, cadence, walking, rms):
                self = .steps(count: count, meanCadenceDeci: cadence.map(CanonicalPayload.deci),
                              walkingMilli: walking.map(CanonicalPayload.milli), rmsPeakMilli: rms.map(CanonicalPayload.milli))
            case let .reps(count, ratio, repSeconds):
                self = .reps(count: count, minDescentRatioMilli: ratio.map(CanonicalPayload.milli), meanRepMs: repSeconds.map(CanonicalPayload.ms))
            case let .neck(rotations, flexions, tilts, yaw, pitch, roll, matches, mismatches):
                self = .neck(rotations: rotations, flexions: flexions, tilts: tilts,
                             maxYawDeci: CanonicalPayload.deci(yaw), maxPitchDeci: CanonicalPayload.deci(pitch), maxRollDeci: CanonicalPayload.deci(roll),
                             cueMatches: matches, cueMismatches: mismatches)
            case let .eyes(complete, partial, bpm, farGaze):
                self = .eyes(completeBlinks: complete, partialBlinks: partial,
                             blinksPerMinuteDeci: CanonicalPayload.deci(bpm), farGazeMs: CanonicalPayload.ms(farGaze))
            case let .stroop(trials, valid, accuracy, rt, rtC, rtI, anticipations, lapses, seed):
                self = .stroop(trials: trials, valid: valid, accuracyMilli: CanonicalPayload.milli(accuracy),
                               medianRTms: rt, medianCongruentRTms: rtC, medianIncongruentRTms: rtI,
                               anticipations: anticipations, lapses: lapses, seed: seed)
            case let .breath(cycles):
                self = .breath(cycles: cycles)
            case .none:
                self = .none
            }
        }
    }

    // MARK: - Construcción desde la sesión

    init(session s: PauseSession) {
        id = s.id
        workDayKey = s.workDayKey
        turnoKey = s.turnoKey
        recipe = s.recipe
        moment = s.moment
        startedAt = s.startedAt
        endedAt = s.endedAt
        monotonicMs = Self.ms(s.monotonicSeconds)
        checkIn = (s.checkInScore == nil && s.checkInAnswers.isEmpty)
            ? nil
            : CheckIn(score: s.checkInScore, answers: s.checkInAnswers, zone: s.zone,
                      zones: s.zones.map { PainZone.normalized($0, fallback: s.zone) })
        postResponse = s.postResponse
        activities = s.activities.map(Activity.init)
        counted = s.counted
        level = s.level
        simulated = s.simulated
        integrityFlags = s.integrityFlags.map(Flag.init)
    }

    // MARK: - Codificación determinista

    /// Bytes canónicos de la sesión: son los que se firman y los que se guardan en `payloadData`.
    static func data(for session: PauseSession) throws -> Data {
        try CanonicalPayload(session: session).encoded()
    }

    func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Decodifica un `payloadData` guardado (para mostrar el detalle auditado).
    static func decode(_ data: Data) throws -> CanonicalPayload {
        try makeDecoder().decode(CanonicalPayload.self, from: data)
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Enteros

    /// Segundos → milisegundos (redondeo al más cercano; valores no finitos → 0).
    static func ms(_ seconds: Double) -> Int { scaled(seconds, by: 1_000) }
    /// Valor → décimas.
    static func deci(_ value: Double) -> Int { scaled(value, by: 10) }
    /// Valor → milésimas.
    static func milli(_ value: Double) -> Int { scaled(value, by: 1_000) }

    private static func scaled(_ value: Double, by factor: Double) -> Int {
        guard value.isFinite else { return 0 }
        let r = (value * factor).rounded()
        guard r.magnitude < Double(Int.max / 2) else { return r < 0 ? Int.min / 2 : Int.max / 2 }
        return Int(r)
    }
}
