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
}
