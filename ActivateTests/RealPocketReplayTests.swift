import Foundation
import Testing
@testable import Activate

// Replay de "Pararse y sentarse" (A4) con el teléfono en el bolsillo, grabado en el iPhone real
// (23-10-2026, 70 s, 50 Hz). La app de entonces contó 0.
//
// La grabación NO se versiona (repo público, datos de una persona real): el test la lee en tiempo de
// ejecución desde `REAL_POCKET_FILE` (con xcodebuild: `TEST_RUNNER_REAL_POCKET_FILE=…`) o desde la carpeta de
// trabajo por defecto, y se SALTA si no está (CI, otro Mac).
//
// Contenido físico de la grabación (ángulo de la gravedad y desplazamiento meseta a meseta): 13 transiciones
// honestas (sentado ≈ 4 s → de pie, …, de pie hasta 19,6 s; fuera del bolsillo 20,4-26,8 s; de pie 27,7 s
// → sentado, …, de pie a los 48,5 s). Eso son 6 ciclos completos más media transición sin pareja (la subida
// de los 17 s, antes de sacar el teléfono), así que con rep = ciclo completo el máximo honesto es 6.

nonisolated enum RealPocketData {
    static let environmentKey = "REAL_POCKET_FILE"
    static let defaultFile =
        "/private/tmp/claude-501/-Users-ignacio/d8f9d759-ca69-4c58-b5e8-2147015305ed/scratchpad/real-pocket/20261023-214738-A4.jsonl"

    static var url: URL {
        let env = ProcessInfo.processInfo.environment[environmentKey].flatMap { $0.isEmpty ? nil : $0 }
        return URL(fileURLWithPath: env ?? defaultFile)
    }

    static var available: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Ciclos completos que contiene la grabación (ver arriba).
    static let completeCycles = 6

    private nonisolated struct Line: Decodable {
        var t: Double?
        var s: PocketSitStandSample?
    }

    static func samples() throws -> [PocketSitStandSample] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            guard raw.contains("\"s\"") else { return nil }
            return (try? decoder.decode(Line.self, from: Data(raw.utf8)))?.s
        }
    }
}

@Suite("Replay real: pararse y sentarse en el bolsillo")
struct RealPocketReplayTests {
    @Test(.enabled(if: RealPocketData.available, "Sin la grabación real del bolsillo (no se versiona)"))
    func cuentaLosCiclosRealesDelBolsillo() throws {
        let samples = try RealPocketData.samples()
        #expect(samples.count > 3000)

        let spec = VerificationSpec.standard(for: .pararseSentarse, target: 10, demo: false)
        var verifier = PocketSitStandVerifier(spec: spec, kind: .pararseSentarse)
        var reps = 0
        for s in samples {
            for event in verifier.ingest(s, at: s.t) {
                if case .rep = event { reps += 1 }
            }
        }
        let outcome = verifier.finish(at: samples.last?.t ?? 0, reason: .userStopped)
        let level = verifier.limitedSourceLevel(.live)

        print("RealPocket: reps=\(verifier.progress.count) nivel=\(level) intentos=\(verifier.attemptCount)")
        for i in 0..<verifier.attemptCount { print("RealPocket: " + verifier.attemptLine(i)) }

        // Todos los ciclos completos de la grabación cuentan, una sola vez cada uno.
        #expect(verifier.progress.count == RealPocketData.completeCycles)
        #expect(reps == verifier.progress.count)
        #expect(outcome.achieved == RealPocketData.completeCycles)
        // Ninguna transición honesta se rechaza (en particular, ninguna como "solo giro").
        let rejected = verifier.diagnostics.filter { !$0.counted }
        #expect(rejected.isEmpty, "\(rejected)")
        // Giro y desplazamiento coinciden en cada transición contada.
        for attempt in verifier.diagnostics where attempt.counted {
            #expect(attempt.first.motionAgrees && attempt.second?.motionAgrees == true, "\(attempt)")
            #expect(attempt.first.rotationDeg >= 45 && (attempt.second?.rotationDeg ?? 0) >= 45, "\(attempt)")
        }
        // El barómetro del bolsillo no concluye: el nivel sale de giro + desplazamiento.
        #expect(level == .live)
    }

    /// Girar el teléfono 55° "con la mano" (misma gravedad que la grabación, sin mover el bolsillo) no cuenta.
    @Test(.enabled(if: RealPocketData.available, "Sin la grabación real del bolsillo (no se versiona)"))
    func soloGiroSinDesplazamientoNoCuenta() throws {
        let samples = try RealPocketData.samples()
        let spec = VerificationSpec.standard(for: .pararseSentarse, target: 10, demo: false)
        var verifier = PocketSitStandVerifier(spec: spec, kind: .pararseSentarse)
        // Misma secuencia de gravedad y proximidad, pero sin aceleración del usuario: solo giro.
        for var s in samples {
            s.userAccel = SIMD3(0.01, -0.01, 0.01)
            _ = verifier.ingest(s, at: s.t)
        }
        print("RealPocket soloGiro: reps=\(verifier.progress.count)")
        for i in 0..<verifier.attemptCount { print("RealPocket soloGiro: " + verifier.attemptLine(i)) }
        #expect(verifier.progress.count == 0)
        let soloGiro = verifier.diagnostics.filter { $0.rejection == "soloGiro" }
        #expect(!soloGiro.isEmpty)
    }
}
