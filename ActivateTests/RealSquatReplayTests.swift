import Foundation
import simd
#if !REPLAY_HARNESS
import Testing
@testable import Activate
#endif

// Replay de sentadillas REALES grabadas en el iPhone (`Documents/diagnostics/samples/*-A3.jsonl`, bajadas con
// `xcrun devicectl device copy from … --domain-type appDataContainer`). Cada línea es `{"t":…,"s":{muestra}}` o
// `{"t":…,"e":"evento"}`; el teléfono anota además `intento RepDiagnostics(…)` por cada intento que midió.
//
// Las grabaciones NO se versionan (repo público, cara y posición de una persona real): el test las lee en tiempo
// de ejecución desde `REAL_SQUATS_DIR` (con xcodebuild: `TEST_RUNNER_REAL_SQUATS_DIR=…`) o desde la carpeta de
// trabajo por defecto, y se SALTA si no hay grabaciones (CI, otro Mac).
//
// Imprime, por grabación y por modo del desafío "Quédese abajo 2 segundos", una tabla por intento (inicio, fin,
// contada o motivo del rechazo, y las medidas de `RepDiagnostics`) junto al resultado que dio el teléfono.
//
// Desafío: en la app la rep del desafío sale de `SquatHoldChallenge(seed:target:)` con una semilla aleatoria por
// sesión, que no se graba. Se reconstruye desde los intentos grabados (la primera rep armada = reps contadas antes
// + 1) y el replay corre en tres modos:
// - `disabled`: sin desafío (`SquatHoldChallenge.none`): solo el conteo.
// - `phone`: la MISMA rep que en el teléfono (p. ej. la 4ª).
// - `aligned`: armado en el MISMO intento físico en que el teléfono mostró el aviso: mide si las pausas que la
//   persona realmente hizo cumplen el desafío.

// MARK: - Datos

nonisolated enum RealSquatData {
    static let environmentKey = "REAL_SQUATS_DIR"
    /// Carpeta de trabajo donde se bajaron las grabaciones del iPhone del usuario (fuera del repo).
    static let defaultDirectory =
        "/private/tmp/claude-501/-Users-ignacio/d8f9d759-ca69-4c58-b5e8-2147015305ed/scratchpad/real-squats"

    static var directory: URL {
        let env = ProcessInfo.processInfo.environment[environmentKey].flatMap { $0.isEmpty ? nil : $0 }
        return URL(fileURLWithPath: env ?? defaultDirectory, isDirectory: true)
    }

    /// Grabaciones de la sentadilla en las manos (A3), en orden.
    static var files: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix("-A3.jsonl") }.sorted().map { directory.appendingPathComponent($0) }
    }

    static var available: Bool { files.contains { honest[$0.lastPathComponent] != nil } }

    /// Series honestas del usuario (iPhone 17 Pro Max, 23-10-2026, 42 intentos): TODAS las bajadas fueron
    /// sentadillas de pie con el teléfono frente al pecho (17-83 cm, de 0,9 a 4,8 s, muchas rápidas y profundas).
    /// Excepción: dos intentos de la segunda serie en que el teléfono se volteó hacia los muslos (cabeceo ≈ 80°, la
    /// cara bajó 21-36 cm y el teléfono 72-83 cm): pueden no contar, pero el motivo no puede ser "sacudir" (esa
    /// consigna no le sirve). Grabaciones nuevas de la carpeta solo se imprimen.
    nonisolated struct Expectation: Sendable {
        /// Intentos que midió el teléfono.
        var attempts: Int
        /// Inicio (s, ±0,5) de los intentos con el teléfono volteado hacia los muslos.
        var flippedStarts: [Double] = []
        /// Serie original (las dos primeras, 25 intentos).
        var original = false
    }

    static let honest: [String: Expectation] = [
        "20261023-145923-A3.jsonl": Expectation(attempts: 10, original: true),
        "20261023-150025-A3.jsonl": Expectation(attempts: 15, flippedStarts: [32.98, 47.62], original: true),
        "20261023-150241-A3.jsonl": Expectation(attempts: 8),
        "20261023-150720-A3.jsonl": Expectation(attempts: 9),
    ]

    /// Grabaciones con muestras suficientes para medir (una pausa saltada al instante deja < 1 s).
    static let minSamples = 120
}

/// Una grabación decodificada.
nonisolated struct RealSquatRecording: Sendable {
    /// Un intento tal como lo midió el teléfono (línea `intento RepDiagnostics(…)`).
    nonisolated struct PhoneAttempt: Sendable {
        var start: Double
        var end: Double
        /// nil = contado.
        var rejection: String?
        var challengeArmed: Bool
    }

    var name: String
    var target: Int
    var samples: [HandheldSquatSample]
    var phoneAttempts: [PhoneAttempt]

    /// Rep (1-based) que llevaba el desafío en el teléfono: reps contadas antes del primer intento armado + 1.
    var phoneChallengeRep: Int {
        guard let first = phoneAttempts.firstIndex(where: \.challengeArmed) else { return 0 }
        return phoneAttempts[..<first].filter { $0.rejection == nil }.count + 1
    }

    var firstArmedStart: Double? { phoneAttempts.first(where: \.challengeArmed)?.start }

    private nonisolated struct Line: Decodable {
        var t: Double?
        var s: HandheldSquatSample?
        var e: String?
        var kind: String?
        var target: Int?
    }

    static func load(_ url: URL) throws -> RealSquatRecording {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let text = try String(contentsOf: url, encoding: .utf8)
        var samples: [HandheldSquatSample] = []
        var attempts: [PhoneAttempt] = []
        var target = 5
        for raw in text.split(separator: "\n") {
            // Una línea cortada (la app se cerró escribiendo) se ignora.
            guard let data = raw.data(using: .utf8), let line = try? decoder.decode(Line.self, from: data) else { continue }
            if line.kind != nil, let header = line.target { target = header }
            if let s = line.s { samples.append(s) }
            if let e = line.e, e.hasPrefix("intento "), let attempt = parseAttempt(e) { attempts.append(attempt) }
        }
        return RealSquatRecording(name: url.lastPathComponent, target: target, samples: samples, phoneAttempts: attempts)
    }

    /// `intento RepDiagnostics(at: 5.04, mode: …, seconds: 1.63, …, challengeArmed: false, rejection: nil)`.
    static func parseAttempt(_ text: String) -> PhoneAttempt? {
        guard let at = field(text, "(at").flatMap(Double.init), let seconds = field(text, "seconds").flatMap(Double.init) else {
            return nil
        }
        var rejection = field(text, "rejection")
        if rejection == "nil" { rejection = nil }
        rejection = rejection.map { value in
            var inner = value.hasPrefix("Optional(") ? String(value.dropFirst("Optional(".count)) : value
            if inner.hasSuffix(")") { inner.removeLast() }
            return inner.split(separator: ".").last.map(String.init) ?? inner
        }
        return PhoneAttempt(start: at - seconds, end: at, rejection: rejection, challengeArmed: field(text, "challengeArmed") == "true")
    }

    /// Valor de `key: valor` hasta la coma o el paréntesis que cierra al mismo nivel.
    private static func field(_ text: String, _ key: String) -> String? {
        guard let range = text.range(of: key + ": ") else { return nil }
        var out = ""
        var depth = 0
        for ch in text[range.upperBound...] {
            if ch == "(" { depth += 1 }
            if ch == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            if ch == ",", depth == 0 { break }
            out.append(ch)
        }
        return out
    }
}

// MARK: - Replay

nonisolated enum RealSquatReplay {
    nonisolated enum ChallengeMode: String, CaseIterable, Sendable { case disabled, phone, aligned }

    nonisolated struct Result {
        var mode: ChallengeMode
        var challengeRep: Int
        var verifier: HandheldSquatVerifier
        var outcome: ActivityOutcome
        var cues: [String]
        /// Índice del intento del teléfono que corresponde a cada intento del replay (mayor solape en el tiempo).
        var matches: [Int?]

        var hardKinds: [String] { outcome.anomalies.filter { $0.severity == .hard }.map(\.kind) }

        /// Nivel que daría el runner con una fuente `.live` (aplica lo que el verificador limita).
        var level: VerificationLevel {
            VerificationPolicy.level(for: outcome, source: verifier.limitedSourceLevel(.live), kind: .sentadilla)
        }

        /// Intentos del teléfono que el replay contó.
        var countedPhoneAttempts: Set<Int> {
            Set(zip(verifier.diagnostics, matches).compactMap { d, m in d.rejection == nil ? m : nil })
        }

        /// Reps contadas que no corresponden a ningún intento del teléfono (doble conteo, ruido).
        var extraCounted: Int {
            zip(verifier.diagnostics, matches).filter { d, m in d.rejection == nil && m == nil }.count
        }

        /// Rechazos del replay que caen en el intento `i` del teléfono.
        func rejections(ofPhoneAttempt i: Int) -> [HandheldSquatVerifier.Rejection] {
            zip(verifier.diagnostics, matches).filter { $0.1 == i }.compactMap { $0.0.rejection }
        }
    }

    /// Semilla (la más chica) con la que `SquatHoldChallenge(seed:target:)` elige esa rep; nil si ninguna.
    static func seed(forRep rep: Int, target: Int) -> UInt64? {
        (UInt64(1)...20_000).first { SquatHoldChallenge.repNumber(seed: $0, target: target) == rep }
    }

    static func run(_ rec: RealSquatRecording, challengeRep: Int, target: Int) -> (HandheldSquatVerifier, [String]) {
        var v = HandheldSquatVerifier(target: target, challenge: SquatHoldChallenge(repNumber: challengeRep))
        v.start(at: 0)
        var cues: [String] = []
        for s in rec.samples {
            for case .cue(let c) in v.ingest(s, at: s.t) { cues.append(c.text) }
        }
        return (v, cues)
    }

    /// Meta grande: el teléfono se detiene al completar, el replay mide cada intento grabado.
    static func replay(_ rec: RealSquatRecording, mode: ChallengeMode, target: Int = 99) -> Result {
        let rep: Int
        switch mode {
        case .disabled:
            rep = 0
        case .phone:
            rep = rec.phoneChallengeRep
        case .aligned:
            if let start = rec.firstArmedStart {
                let pass = run(rec, challengeRep: 0, target: target).0
                rep = pass.diagnostics.filter { $0.rejection == nil && $0.at <= start + 0.05 }.count + 1
            } else {
                rep = 0
            }
        }
        var (v, cues) = run(rec, challengeRep: rep, target: target)
        let outcome = v.finish(at: rec.samples.last?.t ?? 0, reason: .timeout)
        let matches = v.diagnostics.map { match(start: $0.at - $0.seconds, end: $0.at, rec.phoneAttempts) }
        return Result(mode: mode, challengeRep: rep, verifier: v, outcome: outcome, cues: cues, matches: matches)
    }

    static func match(start: Double, end: Double, _ attempts: [RealSquatRecording.PhoneAttempt]) -> Int? {
        var best: (index: Int, overlap: Double)?
        for (i, a) in attempts.enumerated() {
            let overlap = min(end, a.end) - max(start, a.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (i, overlap) }
        }
        return best?.index
    }

    // MARK: Tabla

    static func table(_ rec: RealSquatRecording, _ r: Result) -> String {
        func n(_ v: Double?, _ w: Int = 6) -> String {
            let s = v.map { String(format: "%.2f", $0) } ?? "-"
            return String(repeating: " ", count: max(0, w - s.count)) + s
        }
        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
        var lines: [String] = []
        lines.append("== \(rec.name) [\(r.mode.rawValue)] muestras=\(rec.samples.count) metaTeléfono=\(rec.target) "
                     + "repDesafío=\(r.challengeRep) (teléfono: \(rec.phoneChallengeRep))")
        lines.append(" inicio    fin  seg.  tel.  cara   gap cabeceo cabeza avance  atrás  lado recorr  osc pausa arm resultado    | tel# teléfono")
        for (d, m) in zip(r.verifier.diagnostics, r.matches) {
            let phone = m.map { String(format: "%3d  %@", $0 + 1, rec.phoneAttempts[$0].rejection ?? "CONTADA") } ?? "   -"
            lines.append("\(n(d.at - d.seconds)) \(n(d.at)) \(n(d.seconds, 5)) \(n(d.phoneDescent, 5)) \(n(d.maxFaceDescent, 5)) "
                         + "\(n(d.maxGap, 5)) \(n(d.pitchDelta, 7)) \(n(d.headPitchDelta)) \(n(d.forwardExcess)) "
                         + "\(n(d.backwardShift)) \(n(d.lateralShift, 5)) \(n(d.horizontalTravel, 6)) \(String(format: "%4d", d.oscillation)) "
                         + "\(n(d.holdSeconds, 5)) \(d.challengeArmed ? (d.challengeShown ? " sí" : " ns") : " no") "
                         + "\(pad(d.rejection.map { "\($0)" } ?? "CONTADA", 12)) | \(phone)")
        }
        let phoneCounted = rec.phoneAttempts.filter { $0.rejection == nil }.count
        lines.append("   replay: \(r.countedPhoneAttempts.count)/\(rec.phoneAttempts.count) intentos contados "
                     + "(teléfono: \(phoneCounted)), reps=\(r.verifier.count), extra=\(r.extraCounted), nivel=\(r.level), "
                     + "hard=\(r.hardKinds), soft=\(r.outcome.anomalies.filter { $0.severity == .soft }.map(\.kind)), "
                     + "reanclajes=\(r.verifier.reanchorCount)")
        return lines.joined(separator: "\n")
    }

    /// Escribe el informe junto a las grabaciones (si se puede) y lo imprime.
    static func report(_ text: String) {
        print(text)
        let url = RealSquatData.directory.appendingPathComponent("replay-report.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Informe completo (los tres modos) y totales por modo.
    static func fullReport() throws -> (text: String, totals: [ChallengeMode: (counted: Int, attempts: Int, hard: [String])]) {
        var blocks: [String] = []
        var totals: [ChallengeMode: (counted: Int, attempts: Int, hard: [String])] = [:]
        for mode in ChallengeMode.allCases {
            var counted = 0, attempts = 0, phone = 0
            var hard: [String] = []
            var levels: [String] = []
            for url in RealSquatData.files {
                let rec = try RealSquatRecording.load(url)
                guard rec.samples.count >= RealSquatData.minSamples else { continue }
                let r = replay(rec, mode: mode)
                blocks.append(table(rec, r))
                counted += r.countedPhoneAttempts.count
                attempts += rec.phoneAttempts.count
                phone += rec.phoneAttempts.filter { $0.rejection == nil }.count
                hard += r.hardKinds
                levels.append("\(r.level)")
            }
            totals[mode] = (counted, attempts, hard)
            blocks.append("TOTAL [\(mode.rawValue)]: \(counted)/\(attempts) intentos contados (teléfono: \(phone)), "
                          + "hard=\(hard), niveles=\(levels)")
        }
        return (blocks.joined(separator: "\n"), totals)
    }
}

// MARK: - Tests

#if !REPLAY_HARNESS
@Suite(.enabled(if: RealSquatData.available, "Sin grabaciones reales en \(RealSquatData.directory.path)"))
struct RealSquatReplayTests {
    @Test func lasGrabacionesSeDecodificanCompletas() throws {
        for url in RealSquatData.files {
            let rec = try RealSquatRecording.load(url)
            // Las grabaciones nuevas (o cortas: una pausa saltada al instante) solo se informan.
            guard RealSquatData.honest[rec.name] != nil else {
                print("\(rec.name): \(rec.samples.count) muestras, \(rec.phoneAttempts.count) intentos (fuera del manifiesto)")
                continue
            }
            #expect(rec.samples.count >= 600, "\(rec.name): \(rec.samples.count) muestras")
            #expect(zip(rec.samples, rec.samples.dropFirst()).allSatisfy { $0.t <= $1.t }, "\(rec.name): tiempos desordenados")
            #expect(rec.samples.contains { $0.faceTracked && $0.worldTrackingNormal }, "\(rec.name): sin cara ni mundo")
            if let expected = RealSquatData.honest[rec.name] {
                #expect(rec.phoneAttempts.count == expected.attempts, "\(rec.name): intentos del teléfono")
            }
        }
    }

    @Test func laSemillaDelDesafioSeReconstruye() throws {
        // La rep del desafío es 2 + (primer número de FixtureRandom(seed)) % (n.º de reps posibles): con meta 5,
        // entre la 2ª y la 4ª. Ninguna semilla lo apaga (meta ≥ 2 → rep ≥ 2): se apaga con `.none`.
        var lines: [String] = []
        for url in RealSquatData.files {
            let rec = try RealSquatRecording.load(url)
            let rep = rec.phoneChallengeRep
            guard rep > 0 else { continue }
            let seed = RealSquatReplay.seed(forRep: rep, target: rec.target)
            #expect(seed != nil)
            if let seed { #expect(SquatHoldChallenge(seed: seed, target: rec.target).repNumber == rep) }
            lines.append("\(rec.name): desafío en la rep \(rep) de \(rec.target) (p. ej. semilla \(seed.map(String.init) ?? "-"))")
        }
        #expect(SquatHoldChallenge.none.isEnabled == false)
        print(lines.joined(separator: "\n"))
    }

    /// Tabla por intento en los tres modos del desafío (el informe; también en `replay-report.txt`).
    @Test func informePorIntento() throws {
        let report = try RealSquatReplay.fullReport()
        RealSquatReplay.report(report.text)
        #expect((report.totals[.disabled]?.attempts ?? 0) >= 25)
    }

    /// Las sentadillas honestas cuentan (sin desafío): todas, salvo las dos con el teléfono volteado hacia los
    /// muslos, que reciben una consigna útil (no "No sacuda el teléfono").
    @Test func sentadillasHonestasCuentan() throws {
        var original = (counted: 0, attempts: 0)
        for url in RealSquatData.files {
            guard let expected = RealSquatData.honest[url.lastPathComponent] else { continue }
            let rec = try RealSquatRecording.load(url)
            let r = RealSquatReplay.replay(rec, mode: .disabled)
            let counted = r.countedPhoneAttempts
            for (i, attempt) in rec.phoneAttempts.enumerated() {
                let flipped = expected.flippedStarts.contains { abs($0 - attempt.start) <= 0.5 }
                if flipped {
                    let rejections = r.rejections(ofPhoneAttempt: i)
                    #expect(!rejections.contains(.shaking), "\(rec.name) intento \(i + 1): \(rejections)")
                } else {
                    let start = String(format: "%.1f", attempt.start)
                    #expect(counted.contains(i), "\(rec.name) intento \(i + 1) (\(start) s) no contó: \(r.rejections(ofPhoneAttempt: i))")
                }
            }
            if expected.original {
                original.counted += counted.count
                original.attempts += rec.phoneAttempts.count
            }
            #expect(r.extraCounted == 0, "\(rec.name): reps contadas que no son intentos reales")
            #expect(r.hardKinds.isEmpty, "\(rec.name): \(r.hardKinds)")
            #expect(!r.cues.contains(HandheldSquatCopy.noShake), "\(rec.name): pidió no sacudir a un honesto")
        }
        print("Originales sin desafío: \(original.counted)/\(original.attempts)")
        #expect(original.attempts == 25)
        #expect(original.counted >= 23)
    }

    /// Con el desafío armado como en el teléfono (misma rep, o el mismo intento físico en que se vio el aviso):
    /// al menos 21 de los 25 intentos originales cuentan (todos salvo los dos volteados y las reps del desafío que
    /// de verdad no se quedaron abajo), y lo que la persona hizo (casi nunca se quedó abajo) no la deja sospechosa.
    /// En el teléfono, 3 de las 4 series quedaron `suspicious` solo por `holdChallengeFailed`.
    @Test(arguments: [RealSquatReplay.ChallengeMode.phone, .aligned])
    func elDesafioNoDejaSospechosoAlHonesto(mode: RealSquatReplay.ChallengeMode) throws {
        var original = (counted: 0, attempts: 0)
        var all = (counted: 0, attempts: 0)
        for url in RealSquatData.files {
            guard let expected = RealSquatData.honest[url.lastPathComponent] else { continue }
            let rec = try RealSquatRecording.load(url)
            let r = RealSquatReplay.replay(rec, mode: mode)
            #expect(r.hardKinds.isEmpty, "\(rec.name) rep del desafío \(r.challengeRep): \(r.hardKinds)")
            #expect(r.level != .suspicious, "\(rec.name): \(r.level)")
            // La TrueDepth confirmó una cara 3D (relieve real 1,8-2,7 cm) que se mueve respecto del teléfono: no quedarse
            // abajo ya no baja la serie a reduced (antes 4 de 6 series honestas).
            #expect(r.level == .full, "\(rec.name): \(r.level)")
            #expect(r.extraCounted == 0, "\(rec.name): reps contadas que no son intentos reales")
            // Sin otra razón, solo el desafío puede dejar una rep honesta sin contar.
            for (i, attempt) in rec.phoneAttempts.enumerated() where !expected.flippedStarts.contains(where: { abs($0 - attempt.start) <= 0.5 }) {
                let rejections = r.rejections(ofPhoneAttempt: i)
                #expect(r.countedPhoneAttempts.contains(i) || rejections.allSatisfy { $0 == .holdMissed },
                        "\(rec.name) intento \(i + 1): \(rejections)")
            }
            if expected.original {
                original.counted += r.countedPhoneAttempts.count
                original.attempts += rec.phoneAttempts.count
            }
            all.counted += r.countedPhoneAttempts.count
            all.attempts += rec.phoneAttempts.count
        }
        print("[\(mode.rawValue)] originales \(original.counted)/\(original.attempts), todas \(all.counted)/\(all.attempts)")
        // `phone` arma el desafío en intentos en que la persona nunca vio el aviso (contrafactual): solo se exige
        // que no quede sospechosa. `aligned` lo arma donde lo vio: sus pausas reales deben bastar.
        if mode == .aligned { #expect(original.counted >= 21) }
    }

    /// Respaldo IMU: la altura de la cara sobre el teléfono solo con la TrueDepth y la gravedad
    /// (`HandheldSquatGeometry.faceAbovePhone`) coincide con la del mundo en los frames reales.
    @Test func alturaDeLaCaraSobreElTelefonoSinElMundoCoincideConElMundo() throws {
        for url in RealSquatData.files where RealSquatData.honest[url.lastPathComponent] != nil {
            let rec = try RealSquatRecording.load(url)
            var errors: [Double] = []
            for s in rec.samples where s.faceTracked && s.worldTrackingNormal {
                let world = Double(s.facePos.y - s.phonePos.y)
                let projected = HandheldSquatGeometry.faceAbovePhone(faceInPhone: HandheldSquatVerifier.d3(s.faceInPhone),
                                                                     pitchDeg: s.phonePitchDeg, rollDeg: s.phoneRollDeg)
                errors.append(abs(projected - world))
            }
            errors.sort()
            guard !errors.isEmpty else { continue }
            let median = errors[errors.count / 2], p90 = errors[errors.count * 9 / 10]
            print("\(rec.name): |error| mediana \(String(format: "%.4f", median)) m, p90 \(String(format: "%.4f", p90)) m (\(errors.count) frames)")
            #expect(median < 0.01, "\(rec.name)")
            #expect(p90 < 0.025, "\(rec.name)")
        }
    }

    /// `verticalAccel` grabado contra la aceleración vertical del mundo (segunda derivada de la altura del teléfono):
    /// deben correlacionar fuerte. En el build del 23-10-2026 el signo sale INVERTIDO (r ≈ −0,99: CoreMotion entrega
    /// `userAcceleration` con el signo opuesto al que suma `HandheldMotionTap`). El verificador lo corrige
    /// (`HandheldSquatTuning.recordedAccelSign`) y, con el mundo visible, aprende el signo de la grabación.
    @Test func laAceleracionVerticalGrabadaSigueAlMundo() throws {
        for url in RealSquatData.files where RealSquatData.honest[url.lastPathComponent] != nil {
            let rec = try RealSquatRecording.load(url)
            let r = Self.accelCorrelation(rec.samples)
            print("\(rec.name): r(verticalAccel, mundo) = \(String(format: "%.3f", r))\(r < 0 ? " (signo invertido en la fuente)" : "")")
            #expect(abs(r) > 0.9, "\(rec.name): r = \(r)")
            let (v, _) = RealSquatReplay.run(rec, challengeRep: 0, target: 99)
            #expect(v.accelSign.learned == (r < 0 ? -1 : 1), "\(rec.name): aprendido \(String(describing: v.accelSign.learned))")
            #expect(v.accelSign.sign == HandheldSquatTuning.recordedAccelSign || r > 0)
        }
    }

    /// Temblor de la mano (±3-4 m/s² a 6-9 Hz sumado a la aceleración grabada): no es sacudida (antes: hard en 3-6 de 6
    /// series y ninguna rep contada) y cuentan las mismas reps.
    @Test func elTemblorDeLaManoNoEsSacudida() throws {
        for url in RealSquatData.files {
            guard RealSquatData.honest[url.lastPathComponent] != nil else { continue }
            let rec = try RealSquatRecording.load(url)
            let base = RealSquatReplay.run(rec, challengeRep: 0, target: 99).0.count
            for (amp, hz) in [(3.0, 6.0), (4.0, 9.0)] {
                var shaken = rec
                for i in shaken.samples.indices {
                    shaken.samples[i].verticalAccel = shaken.samples[i].verticalAccel.map { $0 + amp * sin(2 * .pi * hz * shaken.samples[i].t) }
                }
                var (v, cues) = RealSquatReplay.run(shaken, challengeRep: 0, target: 99)
                let outcome = v.finish(at: shaken.samples.last?.t ?? 0, reason: .timeout)
                #expect(!outcome.anomalies.contains { $0.kind == HandheldSquatAnomaly.shaking }, "\(rec.name) \(amp) m/s² \(hz) Hz")
                #expect(!cues.contains(HandheldSquatCopy.noShake), "\(rec.name) \(amp) \(hz)")
                #expect(v.count >= base - 1, "\(rec.name) \(amp) \(hz): \(v.count) de \(base)")
            }
        }
    }

    /// Con la cámara trasera tapada toda la serie (sin mundo) y la aceleración tal como la graba el teléfono (signo
    /// invertido; el verificador lo corrige), no se cuenta ninguna sentadilla: se pide destapar la cámara.
    /// "Solo brazos" solo en los intentos con el teléfono volteado o bajado hacia los muslos (cabeceo > 45°).
    @Test func conLaCamaraTraseraTapadaLasSentadillasRealesNoSonBrazos() throws {
        var counted = 0, attempts = 0
        for url in RealSquatData.files where RealSquatData.honest[url.lastPathComponent] != nil {
            var rec = try RealSquatRecording.load(url)
            for i in rec.samples.indices { rec.samples[i].worldTrackingNormal = false }
            let (v, _) = RealSquatReplay.run(rec, challengeRep: 0, target: 99)
            let rejections = v.diagnostics.compactMap(\.rejection)
            print("\(rec.name) tapada: \(v.count) de \(rec.phoneAttempts.count) contadas, rechazos \(rejections.map(\.rawValue))")
            #expect(v.mode == .inertial)
            #expect(v.diagnostics.filter { $0.rejection == .armsOnly }.allSatisfy { $0.pitchDelta > 45 }, "\(rec.name): \(rejections)")
            #expect(!rejections.contains(.shaking), "\(rec.name): \(rejections)")
            counted += v.count
            attempts += rec.phoneAttempts.count
        }
        // Regla nueva (pedido del usuario: correcciones simples): con la cámara trasera tapada no se cuenta ninguna
        // sentadilla; la app pide "Destape la cámara de atrás." (sin el mundo no se distingue de alguien sentado).
        #expect(counted == 0, "\(counted) de \(attempts)")
    }

    /// Correlación (con el mejor desfase de ±12 frames) entre `verticalAccel` suavizado y la segunda derivada de la
    /// altura del teléfono en el mundo, en tramos con seguimiento normal.
    static func accelCorrelation(_ samples: [HandheldSquatSample]) -> Double {
        let n = samples.count
        guard n > 300 else { return 0 }
        func smooth(_ x: [Double], _ k: Int) -> [Double] {
            (0..<x.count).map { i in
                let lo = max(0, i - k), hi = min(x.count, i + k + 1)
                return x[lo..<hi].reduce(0, +) / Double(hi - lo)
            }
        }
        let ys = smooth(samples.map { Double($0.phonePos.y) }, 6)
        let acc = smooth(samples.map { $0.verticalAccel ?? 0 }, 6)
        let ok = samples.map(\.worldTrackingNormal)
        let h = 6, dt = 1.0 / 60
        var best = 0.0
        for lag in -12...12 {
            var xs: [Double] = [], zs: [Double] = []
            for i in 100..<(n - 100) where ok[(i - 12)...(i + 12)].allSatisfy({ $0 }) {
                xs.append((ys[i + h] - 2 * ys[i] + ys[i - h]) / (Double(h) * dt * Double(h) * dt))
                zs.append(acc[i + lag])
            }
            guard xs.count > 10 else { continue }
            let mx = xs.reduce(0, +) / Double(xs.count), mz = zs.reduce(0, +) / Double(zs.count)
            var sxz = 0.0, sxx = 0.0, szz = 0.0
            for (x, z) in zip(xs, zs) {
                sxz += (x - mx) * (z - mz)
                sxx += (x - mx) * (x - mx)
                szz += (z - mz) * (z - mz)
            }
            guard sxx > 0, szz > 0 else { continue }
            let r = sxz / (sxx * szz).squareRoot()
            if abs(r) > abs(best) { best = r }
        }
        return best
    }
}
#endif
