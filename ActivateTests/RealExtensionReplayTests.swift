import Foundation
import Testing
@testable import Activate

/// Repite grabaciones reales de la extensión lumbar (registro de diagnóstico del iPhone) contra el verificador.
/// Las grabaciones no van al repo (es público): se leen del scratchpad local y la prueba se salta si no están.
@MainActor
struct RealExtensionReplayTests {
    nonisolated static let folder = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-ignacio/d8f9d759-ca69-4c58-b5e8-2147015305ed/scratchpad/real-extension")
    nonisolated static let firstSession = folder.appending(path: "20261023-155934-A1.jsonl")

    nonisolated static var hasRecording: Bool { FileManager.default.fileExists(atPath: firstSession.path) }

    private struct Line: Decodable { let t: Double?; let s: HandheldSquatSample? }

    nonisolated static let secondSession = folder.appending(path: "20261023-160129-A1.jsonl")
    nonisolated static var hasSecondRecording: Bool { FileManager.default.fileExists(atPath: secondSession.path) }
    nonisolated static let thirdSession = folder.appending(path: "20261023-161037-A1.jsonl")
    nonisolated static var hasThirdRecording: Bool { FileManager.default.fileExists(atPath: thirdSession.path) }

    static func samples(_ url: URL) throws -> [HandheldSquatSample] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return text.split(separator: "\n").compactMap { line in
            (try? decoder.decode(Line.self, from: Data(line.utf8)))?.s
        }
    }

    /// 15:59: calibración con movimiento, luego una extensión de 47° (teléfono 37,6 cm atrás) y otra de 28°
    /// con los brazos adelante (cara 44 cm atrás, teléfono 26 cm, 11 s con 2 s sostenido). Antes: 0 de 2.
    @Test(.enabled(if: RealExtensionReplayTests.hasRecording))
    func extensionesRealesAmpliasCuentan() throws {
        let samples = try Self.samples(Self.firstSession)
        #expect(samples.count > 1000)
        var verifier = HandheldExtensionVerifier(target: 5, demo: true)
        verifier.start(at: 0)
        var reps = 0
        var rejections: [String] = []
        for s in samples {
            for event in verifier.ingest(s, at: s.t) {
                if case .rep = event { reps += 1 }
            }
        }
        for d in verifier.diagnostics { if let r = d.rejection { rejections.append("\(r)") } }
        let outcome = verifier.finish(at: (samples.last?.t ?? 0) + 0.1, reason: .userStopped)
        #expect(reps >= 2, "extensiones reales rechazadas: \(rejections)")
        #expect(outcome.anomalies.allSatisfy { $0.severity != .hard })
    }

    /// 16:01: dos extensiones de 22-23° con la cara 31-34 cm atrás. Antes: 1 de 2 ("solo muñecas").
    @Test(.enabled(if: RealExtensionReplayTests.hasSecondRecording))
    func segundaSerieRealCuenta() throws {
        let samples = try Self.samples(Self.secondSession)
        var verifier = HandheldExtensionVerifier(target: 5, demo: true)
        verifier.start(at: 0)
        var reps = 0
        for s in samples { for event in verifier.ingest(s, at: s.t) { if case .rep = event { reps += 1 } } }
        let detail = verifier.diagnostics.map { "\(String(format: "%.0f", $0.peakTilt))° tang \(String(format: "%.3f", $0.tangentialChange)) \($0.rejection.map { "\($0)" } ?? "ok")" }
        #expect(reps >= 2, "intentos: \(detail)")
    }

    /// 16:10: la cara salió del encuadre 9 veces (1,5-3,4 s) al echarse atrás; antes cada salida bloqueaba,
    /// recalibraba y perdía la rep. Se cuentan las reps y se listan los intentos.
    @Test(.enabled(if: RealExtensionReplayTests.hasThirdRecording))
    func terceraSerieConLaCaraFueraCuenta() throws {
        let samples = try Self.samples(Self.thirdSession)
        var verifier = HandheldExtensionVerifier(target: 20, demo: false)
        verifier.start(at: 0)
        var reps = 0
        var blocks = 0
        for s in samples {
            for event in verifier.ingest(s, at: s.t) {
                if case .rep = event { reps += 1 }
                if case .gate(.blocked) = event { blocks += 1 }
            }
        }
        let detail = verifier.diagnostics.map { "\(String(format: "%.0f", $0.peakTilt))° cara \(String(format: "%.0f", $0.trackedFraction * 100))% \($0.rejection.map { "\($0)" } ?? "ok")" }
        for d in verifier.diagnostics { print("REAL3D \(String(format: "%.1f", d.at)) tilt=\(String(format: "%.0f", d.peakTilt)) s=\(String(format: "%.1f", d.seconds)) mode=\(d.mode) trk=\(String(format: "%.2f", d.trackedFraction)) tang=\(String(format: "%.3f", d.tangentialChange)) retr=\(String(format: "%.3f", d.radialRetreat)) appr=\(String(format: "%.3f", d.radialApproach)) dir=\(String(format: "%.1f", d.directionChange)) fBack=\(d.faceBackward.map { String(format: "%.3f", $0) } ?? "-") pBack=\(d.phoneBackward.map { String(format: "%.3f", $0) } ?? "-") head=\(d.headTurn.map { String(format: "%.0f", $0) } ?? "-") desc=\(d.phoneDescent.map { String(format: "%.3f", $0) } ?? "-") rej=\(d.rejection.map { "\($0)" } ?? "ok")") }
        print("REAL3 reps=\(reps) bloqueos=\(blocks) intentos=\(detail)")
        // Dos intentos de 13° ocurrieron sin el mundo (cámara trasera sin seguimiento): sin prueba de tronco no cuentan.
        #expect(reps >= 8, "intentos: \(detail)")
    }
}
