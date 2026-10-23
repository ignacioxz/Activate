import Testing
import Foundation
import CryptoKit
@testable import Activate

struct SignerTests {
    // MARK: - Fixtures

    private static func sampleSession(seed: Int = 1) -> PauseSession {
        let started = Date(timeIntervalSince1970: 1_792_000_000 + Double(seed))
        let a1 = ActivityResult(kind: .pasos, target: 250, achieved: 262, durationSeconds: 181.249,
                                completed: true, level: .full,
                                metrics: .steps(count: 262, meanCadence: 101.37, walkingFraction: 0.9312, rmsPeak: 0.3141),
                                anomalies: [])
        let a2 = ActivityResult(kind: .cuello, target: 15, achieved: 15, durationSeconds: 62.5,
                                completed: true, level: .reduced,
                                metrics: .neck(rotations: 6, flexions: 5, tilts: 4, maxYaw: 41.26, maxPitch: 30.04, maxRoll: 22.75, cueMatches: 14, cueMismatches: 1),
                                anomalies: [Anomaly(kind: "faceLost", severity: .soft, at: 12.345, detail: "1.2 s")])
        let a3 = ActivityResult(kind: .stroop, target: 40, achieved: 40, durationSeconds: 60,
                                completed: true, level: .full,
                                metrics: .stroop(trials: 40, valid: 38, accuracy: 0.921, medianRTms: 612, medianCongruentRTms: 580, medianIncongruentRTms: 655, anticipations: 1, lapses: 1, seed: 987_654_321),
                                anomalies: [])
        return PauseSession(id: UUID(uuidString: "6B1F4E2A-0C7D-4B3E-9A1F-00000000000\(seed)")!,
                            workDayKey: "2026-10-13", turnoKey: "2026-10-12",
                            recipe: .colacion3, moment: .colacion,
                            startedAt: started, endedAt: started.addingTimeInterval(190),
                            monotonicSeconds: 189.731,
                            checkInScore: 3, checkInAnswers: [true, false, true, false, true, false],
                            zone: .lumbar, postResponse: .mejor,
                            activities: [a1, a2, a3],
                            counted: true, level: .reduced, simulated: false,
                            integrityFlags: [Anomaly(kind: "backgrounded", severity: .soft, at: 70.2)])
    }

    private static func makeSigner() -> SessionSigner {
        SessionSigner(store: InMemoryKeyStore(), forceBacking: .software)
    }

    // MARK: - Firma

    @Test func firmaVerifica() async throws {
        let signer = Self.makeSigner()
        let session = Self.sampleSession()
        let signed = try await signer.sign(session)

        #expect(signed.signature.count == SessionSigner.signatureLength)
        #expect(signed.keyID.count == SessionSigner.keyIDBytes * 2)
        let canonical = try CanonicalPayload.data(for: session)
        #expect(signed.payloadData == canonical)

        let stored = session.applying(signed)
        #expect(stored.isSigned)
        #expect(await signer.verify(stored))
    }

    @Test func payloadAlteradoNoVerifica() async throws {
        let signer = Self.makeSigner()
        let session = Self.sampleSession()
        let stored = session.applying(try await signer.sign(session))
        #expect(await signer.verify(stored))

        // Un byte distinto en el payload guardado.
        var tampered = stored
        var bytes = Data(tampered.payloadData!)
        let i = bytes.startIndex + bytes.count / 2
        bytes[i] ^= 0x01
        tampered.payloadData = bytes
        #expect(await signer.verify(tampered) == false)

        // Un byte distinto en la firma.
        var badSignature = stored
        var sig = Data(badSignature.signature!)
        sig[sig.startIndex + 3] ^= 0xFF
        badSignature.signature = sig
        #expect(await signer.verify(badSignature) == false)

        // Sin firma, sin payload o con keyID desconocido.
        var unsigned = stored
        unsigned.signature = nil
        #expect(await signer.verify(unsigned) == false)
        var unknownKey = stored
        unknownKey.keyID = "0000000000000000"
        #expect(await signer.verify(unknownKey) == false)
        #expect(await signer.verify(session) == false)
    }

    @Test func verifySoloUsaLosBytesGuardados() async throws {
        // Cambiar campos de la sesión en memoria no afecta la verificación: se verifica payloadData, no se re-codifica.
        let signer = Self.makeSigner()
        let session = Self.sampleSession()
        var stored = session.applying(try await signer.sign(session))
        stored.postResponse = .peor
        stored.xpEarned = 999
        #expect(await signer.verify(stored))
    }

    @Test func claveRotadaSigueVerificandoSesionesViejas() async throws {
        let store = InMemoryKeyStore()
        let signer = SessionSigner(store: store, forceBacking: .software)
        let old = Self.sampleSession(seed: 1).applying(try await signer.sign(Self.sampleSession(seed: 1)))
        let oldKeyID = try await signer.currentKey().keyID

        let newKeyID = try await signer.rotateKey()
        #expect(newKeyID != oldKeyID)
        let fresh = Self.sampleSession(seed: 2).applying(try await signer.sign(Self.sampleSession(seed: 2)))
        #expect(fresh.keyID == newKeyID)
        #expect(await signer.verify(old))
        #expect(await signer.verify(fresh))

        // Otra instancia sobre el mismo almacén (relanzar la app) conoce ambas claves públicas.
        let relaunched = SessionSigner(store: store, forceBacking: .software)
        #expect(await relaunched.verify(old))
        #expect(await relaunched.verify(fresh))
        #expect(try await relaunched.currentKey().keyID == newKeyID)
    }

    @Test func otroDispositivoNoVerifica() async throws {
        let a = Self.makeSigner()
        let b = Self.makeSigner()
        let stored = Self.sampleSession().applying(try await a.sign(Self.sampleSession()))
        #expect(await a.verify(stored))
        #expect(await b.verify(stored) == false)
    }

    @Test func keyIDEsHexDeSHA256DeLaClavePublica() async throws {
        let signer = Self.makeSigner()
        let key = try await signer.currentKey()
        let expected = SHA256.hash(data: key.publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
        #expect(key.keyID == expected)
        #expect(key.keyID == SessionSigner.keyID(forPublicKey: key.publicKey))
        #expect(key.backing == .software)
    }

    @Test func respaldoSoftwareCuandoNoHaySecureEnclave() async throws {
        // Sin Secure Enclave (simuladores sin emulación, tests) la clave P-256 es de software y se persiste igual.
        let store = InMemoryKeyStore()
        let signer = SessionSigner(store: store, forceBacking: .software)
        #expect(signer.availableBacking == .software)
        let session = Self.sampleSession(seed: 3)
        let signed = try await signer.sign(session)
        #expect(signed.backing == .software)
        #expect(try store.loadPrivateKey(backing: .software) != nil)
        #expect(try store.loadPrivateKey(backing: .secureEnclave) == nil)
        #expect(await signer.verify(session.applying(signed)))
    }

    @Test func respaldoRealDelDispositivo() async throws {
        // Camino real (Keychain del host de pruebas): el respaldo sigue a `SecureEnclave.isAvailable`
        // (el simulador de iOS 27 en Apple silicon lo emula; en otros simuladores es software).
        let expected: KeyBacking = SecureEnclave.isAvailable ? .secureEnclave : .software
        #expect(SessionSigner.shared.availableBacking == expected)
        let session = Self.sampleSession(seed: 4)
        let signed = try await SessionSigner.shared.sign(session)
        #expect(signed.backing == expected)
        let stored = session.applying(signed)
        #expect(await SessionSigner.shared.verify(stored))
        // Persiste entre instancias (relanzar la app): misma clave, misma verificación.
        let again = SessionSigner()
        #expect(await again.verify(stored))
        #expect(try await again.currentKey().keyID == signed.keyID)
    }

    // MARK: - Payload canónico

    @Test func canonicalPayloadDeterminista() throws {
        let session = Self.sampleSession()
        let a = try CanonicalPayload.data(for: session)
        let b = try CanonicalPayload.data(for: session)
        #expect(a == b)
        #expect(!a.isEmpty)

        // Los campos de firma y los que se completan después no cambian los bytes.
        var decorated = session
        decorated.payloadData = Data([1, 2, 3])
        decorated.signature = Data(repeating: 7, count: 64)
        decorated.keyID = "abcdef0123456789"
        decorated.backing = .secureEnclave
        decorated.xpEarned = 120
        decorated.coachNote = "Buena pausa, Marco."
        #expect(try CanonicalPayload.data(for: decorated) == a)

        // Cualquier cambio de contenido sí cambia los bytes.
        var changed = session
        changed.postResponse = .peor
        #expect(try CanonicalPayload.data(for: changed) != a)

        // Claves ordenadas, sin barras escapadas y decodificable.
        let text = String(decoding: a, as: UTF8.self)
        #expect(text.hasPrefix("{\"activities\":"))
        #expect(!text.contains("\\/"))
        let decoded = try CanonicalPayload.decode(a)
        #expect(decoded.id == session.id)
        #expect(decoded.monotonicMs == 189_731)
        #expect(decoded.activities.count == 3)
        #expect(decoded.checkIn?.score == 3)
        #expect(decoded.integrityFlags.first?.atMs == 70_200)
    }

    @Test func canonicalPayloadIncluyeZonasSoloSiExisten() throws {
        // Sesión antigua (sin selección múltiple): la clave "zones" no aparece, misma forma que v1.
        let legacy = Self.sampleSession()
        #expect(legacy.zones == nil)
        let legacyText = String(decoding: try CanonicalPayload.data(for: legacy), as: UTF8.self)
        #expect(!legacyText.contains("\"zones\""))
        #expect(legacyText.contains("\"zone\":\"lumbar\""))

        // Sesión nueva: van todas las zonas, normalizadas.
        var multi = Self.sampleSession()
        multi.setZones([.cuello, .lumbar])
        let data = try CanonicalPayload.data(for: multi)
        let decoded = try CanonicalPayload.decode(data)
        #expect(decoded.v == CanonicalPayload.currentVersion)
        #expect(decoded.checkIn?.zones == [.lumbar, .cuello])
        #expect(decoded.checkIn?.zone == .lumbar)
        #expect(data != (try CanonicalPayload.data(for: legacy)))

        // "No me duele": se firma la lista vacía tal cual, sin forzar una zona.
        var noPain = Self.sampleSession()
        noPain.setZones([])
        let noPainData = try CanonicalPayload.data(for: noPain)
        #expect(try CanonicalPayload.decode(noPainData).checkIn?.zones == [])
        let legacyData = try CanonicalPayload.data(for: legacy)
        #expect(noPainData != data && noPainData != legacyData)
    }

    @Test func sesionFirmadaSinZonasSigueVerificando() async throws {
        // Firmada antes de la selección múltiple; luego la app carga las zonas en memoria: se verifica con los bytes guardados.
        let signer = Self.makeSigner()
        let session = Self.sampleSession(seed: 5)
        var stored = session.applying(try await signer.sign(session))
        #expect(await signer.verify(stored))
        stored.setZones([.lumbar, .hombro])
        #expect(await signer.verify(stored))
        // El payload guardado sin `zones` se sigue decodificando.
        let old = try CanonicalPayload.decode(try #require(stored.payloadData))
        #expect(old.checkIn?.zones == nil)
    }

    @Test func canonicalPayloadSoloEnteros() throws {
        let data = try CanonicalPayload.data(for: Self.sampleSession())
        let json = try JSONSerialization.jsonObject(with: data)
        #expect(Self.allNumbersAreIntegers(json))
        // Las fechas van como texto ISO 8601.
        let dict = try #require(json as? [String: Any])
        let started = try #require(dict["startedAt"] as? String)
        #expect(started.hasSuffix("Z") && started.contains("T"))
    }

    nonisolated private static func allNumbersAreIntegers(_ value: Any) -> Bool {
        switch value {
        case let n as NSNumber:
            return n.doubleValue == n.doubleValue.rounded()
        case let array as [Any]:
            return array.allSatisfy(allNumbersAreIntegers)
        case let dict as [String: Any]:
            return dict.values.allSatisfy(allNumbersAreIntegers)
        default:
            return true
        }
    }

    // MARK: - IntegrityMonitor

    @Test @MainActor func monitorSinDerivaNoMarca() {
        let m = IntegrityMonitor()
        #expect(!m.isRunning)
        m.begin()
        #expect(m.isRunning)
        #expect(m.monotonicSeconds >= 0)
        let flags = m.end()
        #expect(flags.isEmpty)
        #expect(!m.isRunning)
        #expect(m.monotonicSeconds == 0)
    }

    @Test @MainActor func monitorDetectaDerivaDeReloj() {
        let m = IntegrityMonitor()
        let base = Date()
        m.wallClock = { base }
        m.begin()
        m.wallClock = { base.addingTimeInterval(IntegrityMonitor.clockDriftToleranceSeconds + 3) }
        let flags = m.end()
        #expect(flags.count == 1)
        #expect(flags.first?.kind == IntegrityMonitor.Flag.clockDrift)
        #expect(flags.first?.severity == .hard)
    }

    @Test @MainActor func monitorRegistraSegundoPlanoYCambioDeHora() {
        let m = IntegrityMonitor()
        m.begin()
        m.noteBackgrounded()
        m.noteBackgrounded() // misma transición por dos vías: una sola anomalía
        m.noteForegrounded()
        m.noteBackgrounded()
        m.noteSystemClockChanged()
        let flags = m.end()
        #expect(flags.filter { $0.kind == IntegrityMonitor.Flag.backgrounded }.count == 2)
        #expect(flags.filter { $0.kind == IntegrityMonitor.Flag.backgrounded }.allSatisfy { $0.severity == .soft && $0.at >= 0 })
        #expect(flags.contains { $0.kind == IntegrityMonitor.Flag.systemClockChanged && $0.severity == .hard })
        #expect(m.hasHardAnomaly)
    }

    @Test @MainActor func monitorIgnoraEventosFueraDeSesion() {
        let m = IntegrityMonitor()
        m.noteBackgrounded()
        m.noteSystemClockChanged()
        #expect(m.anomalies.isEmpty)
        #expect(m.end().isEmpty)
    }
}
