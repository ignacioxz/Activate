import Foundation

// Dueño: agente "integrity". Stub con firma congelada.

nonisolated struct SignedPayload: Sendable, Codable, Hashable {
    var payloadData: Data
    var signature: Data
    var keyID: String
    var backing: KeyBacking
}

actor SessionSigner {
    static let shared = SessionSigner()

    /// Firma los bytes canónicos de la sesión (sin los campos de firma).
    func sign(_ session: PauseSession) async throws -> SignedPayload {
        SignedPayload(payloadData: Data(), signature: Data(), keyID: "stub", backing: .software)
    }

    /// Verifica que los bytes guardados corresponden a la firma y a la clave pública de este dispositivo.
    func verify(_ session: PauseSession) async -> Bool { false }
}
