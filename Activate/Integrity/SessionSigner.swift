import Foundation
import CryptoKit
import Security

// Dueño: agente "integrity".
//
// Firma ECDSA P-256 de los bytes canónicos de cada `PauseSession` (ver `CanonicalPayload`).
// - Clave privada en Secure Enclave (`compactRepresentable`, `whenUnlockedThisDeviceOnly` +
//   `.privateKeyUsage`); su `dataRepresentation` se guarda en Keychain (`kSecUseDataProtectionKeychain`,
//   servicio "activate.signer").
// - Si el Secure Enclave no está (simulador), clave P-256 de software persistida igual y `backing = .software`.
// - `keyID` = hex de los primeros 8 bytes de SHA256(x963 de la clave pública). Las claves públicas se
//   guardan por `keyID` para poder rotar la clave y seguir verificando sesiones antiguas.
// - `verify` recomputa SOLO sobre `session.payloadData` (nunca re-codifica) con la clave pública del `keyID`.

nonisolated struct SignedPayload: Sendable, Codable, Hashable {
    var payloadData: Data
    var signature: Data
    var keyID: String
    var backing: KeyBacking
}

nonisolated enum SigningError: Error, Sendable, Equatable {
    case keychain(OSStatus)
    case keyUnavailable(String)
    case encoding(String)
}

// MARK: - Almacén de claves

/// Persistencia de la clave privada y del directorio de claves públicas. Keychain en la app;
/// memoria en los tests. Solo lo usa el actor `SessionSigner`.
nonisolated protocol SigningKeyStore: Sendable {
    /// Clave privada guardada para ese respaldo (`dataRepresentation` del SE o `rawRepresentation` software).
    func loadPrivateKey(backing: KeyBacking) throws -> Data?
    func savePrivateKey(_ data: Data, backing: KeyBacking) throws
    /// Directorio keyID → clave pública (x963).
    func loadPublicKeys() -> [String: Data]
    func savePublicKeys(_ keys: [String: Data]) throws
}

/// Keychain de protección de datos de este dispositivo (no se respalda ni migra).
nonisolated struct KeychainKeyStore: SigningKeyStore {
    static let service = "activate.signer"
    static let publicKeysAccount = "publicKeys"

    func loadPrivateKey(backing: KeyBacking) throws -> Data? {
        try read(account: Self.account(for: backing))
    }

    func savePrivateKey(_ data: Data, backing: KeyBacking) throws {
        try write(data, account: Self.account(for: backing))
    }

    func loadPublicKeys() -> [String: Data] {
        guard let raw = try? read(account: Self.publicKeysAccount),
              let dict = try? JSONDecoder().decode([String: Data].self, from: raw) else { return [:] }
        return dict
    }

    func savePublicKeys(_ keys: [String: Data]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(try encoder.encode(keys), account: Self.publicKeysAccount)
    }

    private static func account(for backing: KeyBacking) -> String {
        switch backing {
        case .secureEnclave: "private.secureEnclave"
        case .software: "private.software"
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SigningError.keychain(status) }
        return out as? Data
    }

    private func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SigningError.keychain(update) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SigningError.keychain(status) }
    }
}

/// Almacén volátil (tests y previews).
nonisolated final class InMemoryKeyStore: SigningKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var privateKeys: [KeyBacking: Data] = [:]
    private var publicKeys: [String: Data] = [:]

    init() {}

    func loadPrivateKey(backing: KeyBacking) throws -> Data? {
        lock.withLock { privateKeys[backing] }
    }

    func savePrivateKey(_ data: Data, backing: KeyBacking) throws {
        lock.withLock { privateKeys[backing] = data }
    }

    func loadPublicKeys() -> [String: Data] {
        lock.withLock { publicKeys }
    }

    func savePublicKeys(_ keys: [String: Data]) throws {
        lock.withLock { publicKeys = keys }
    }
}

// MARK: - Firmante

actor SessionSigner {
    static let shared = SessionSigner()

    /// Tamaño de la firma ECDSA P-256 en `rawRepresentation` (r ‖ s).
    nonisolated static let signatureLength = 64
    /// Bytes de SHA256(clave pública) que forman el `keyID` (16 caracteres hex).
    nonisolated static let keyIDBytes = 8

    nonisolated private enum PrivateKey {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var backing: KeyBacking {
            switch self {
            case .secureEnclave: .secureEnclave
            case .software: .software
            }
        }

        var publicKeyX963: Data {
            switch self {
            case .secureEnclave(let k): k.publicKey.x963Representation
            case .software(let k): k.publicKey.x963Representation
            }
        }

        var persistedRepresentation: Data {
            switch self {
            case .secureEnclave(let k): k.dataRepresentation
            case .software(let k): k.rawRepresentation
            }
        }

        func signature(for data: Data) throws -> P256.Signing.ECDSASignature {
            switch self {
            case .secureEnclave(let k): try k.signature(for: data)
            case .software(let k): try k.signature(for: data)
            }
        }
    }

    private let store: any SigningKeyStore
    /// `nil` → usa `SecureEnclave.isAvailable` (en tests se fuerza software).
    private let forcedBacking: KeyBacking?
    private var current: PrivateKey?
    private var currentKeyID: String?
    private var publicKeys: [String: Data]?

    init(store: any SigningKeyStore = KeychainKeyStore(), forceBacking: KeyBacking? = nil) {
        self.store = store
        self.forcedBacking = forceBacking
    }

    // MARK: API congelada

    /// Firma los bytes canónicos de la sesión (sin los campos de firma).
    func sign(_ session: PauseSession) async throws -> SignedPayload {
        let payload: Data
        do {
            payload = try CanonicalPayload.data(for: session)
        } catch {
            throw SigningError.encoding(String(describing: error))
        }
        let key = try loadOrCreateKey()
        let signature = try key.signature(for: payload)
        let keyID = try currentKeyIDValue()
        return SignedPayload(payloadData: payload, signature: signature.rawRepresentation, keyID: keyID, backing: key.backing)
    }

    /// Verifica que los bytes guardados corresponden a la firma y a la clave pública de este dispositivo.
    func verify(_ session: PauseSession) async -> Bool {
        guard let payload = session.payloadData, !payload.isEmpty,
              let rawSignature = session.signature, rawSignature.count == Self.signatureLength,
              let keyID = session.keyID, !keyID.isEmpty else { return false }
        return verify(payload: payload, signature: rawSignature, keyID: keyID)
    }

    // MARK: Extras (clave actual, rotación)

    /// Clave pública (x963) e identificador de la clave que firma hoy; la crea si no existe.
    func currentKey() throws -> (keyID: String, publicKey: Data, backing: KeyBacking) {
        let key = try loadOrCreateKey()
        return (try currentKeyIDValue(), key.publicKeyX963, key.backing)
    }

    /// Respaldo que usaría este dispositivo (sin crear la clave).
    nonisolated var availableBacking: KeyBacking {
        forcedBacking ?? (SecureEnclave.isAvailable ? .secureEnclave : .software)
    }

    /// Genera una clave nueva. La clave pública anterior sigue disponible para verificar sesiones viejas.
    @discardableResult
    func rotateKey() throws -> String {
        let key = try makeKey(backing: availableBacking)
        try store.savePrivateKey(key.persistedRepresentation, backing: key.backing)
        try adopt(key)
        return try currentKeyIDValue()
    }

    /// Clave pública guardada para un `keyID` (hex x963), si se conoce.
    func publicKey(for keyID: String) -> Data? {
        knownPublicKeys()[keyID]
    }

    /// Verificación directa sobre bytes (la usa `verify(_:)`).
    func verify(payload: Data, signature rawSignature: Data, keyID: String) -> Bool {
        guard let publicKeyData = knownPublicKeys()[keyID] ?? currentPublicKeyIfMatches(keyID),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: rawSignature) else { return false }
        return publicKey.isValidSignature(signature, for: payload)
    }

    // MARK: - Claves

    private func loadOrCreateKey() throws -> PrivateKey {
        if let current { return current }
        let backing = availableBacking
        if let stored = try store.loadPrivateKey(backing: backing), let key = Self.restoreKey(stored, backing: backing) {
            try adopt(key)
            return key
        }
        let key = try makeKey(backing: backing)
        try store.savePrivateKey(key.persistedRepresentation, backing: key.backing)
        try adopt(key)
        return key
    }

    private func makeKey(backing: KeyBacking) throws -> PrivateKey {
        switch backing {
        case .secureEnclave:
            guard SecureEnclave.isAvailable else { throw SigningError.keyUnavailable("Secure Enclave no disponible") }
            var cfError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                                                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                                .privateKeyUsage, &cfError) else {
                throw SigningError.keyUnavailable("SecAccessControl: \(cfError.map { String(describing: $0.takeRetainedValue()) } ?? "?")")
            }
            do {
                return .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: true, accessControl: access))
            } catch {
                throw SigningError.keyUnavailable("Secure Enclave: \(error)")
            }
        case .software:
            return .software(P256.Signing.PrivateKey(compactRepresentable: true))
        }
    }

    private static func restoreKey(_ data: Data, backing: KeyBacking) -> PrivateKey? {
        switch backing {
        case .secureEnclave:
            guard let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) else { return nil }
            return .secureEnclave(k)
        case .software:
            guard let k = try? P256.Signing.PrivateKey(rawRepresentation: data) else { return nil }
            return .software(k)
        }
    }

    /// Fija la clave activa y registra su clave pública en el directorio por `keyID`.
    private func adopt(_ key: PrivateKey) throws {
        let publicKeyData = key.publicKeyX963
        let keyID = Self.keyID(forPublicKey: publicKeyData)
        current = key
        currentKeyID = keyID
        var known = knownPublicKeys()
        if known[keyID] != publicKeyData {
            known[keyID] = publicKeyData
            publicKeys = known
            try store.savePublicKeys(known)
        }
    }

    private func currentKeyIDValue() throws -> String {
        guard let currentKeyID else { throw SigningError.keyUnavailable("Sin clave activa") }
        return currentKeyID
    }

    private func knownPublicKeys() -> [String: Data] {
        if let publicKeys { return publicKeys }
        let loaded = store.loadPublicKeys()
        publicKeys = loaded
        return loaded
    }

    private func currentPublicKeyIfMatches(_ keyID: String) -> Data? {
        guard let current, currentKeyID == keyID else { return nil }
        return current.publicKeyX963
    }

    /// Hex de los primeros `keyIDBytes` bytes de SHA256(x963 de la clave pública).
    nonisolated static func keyID(forPublicKey x963: Data) -> String {
        SHA256.hash(data: x963).prefix(keyIDBytes).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Conveniencias para la sesión

extension PauseSession {
    /// Copia de la sesión con los campos de firma rellenados.
    nonisolated func applying(_ signed: SignedPayload) -> PauseSession {
        var s = self
        s.payloadData = signed.payloadData
        s.signature = signed.signature
        s.keyID = signed.keyID
        s.backing = signed.backing
        return s
    }

    /// Tiene los tres campos necesarios para intentar una verificación.
    nonisolated var isSigned: Bool {
        !(payloadData?.isEmpty ?? true) && !(signature?.isEmpty ?? true) && !(keyID?.isEmpty ?? true)
    }

    /// SHA256 hex de los bytes firmados (para mostrar en el detalle; `nil` si no está firmada).
    nonisolated var payloadDigestHex: String? {
        guard let payloadData, !payloadData.isEmpty else { return nil }
        return SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
    }
}

extension SessionSigner {
    /// Firma la sesión y devuelve una copia con `payloadData`, `signature`, `keyID` y `backing`.
    func signed(_ session: PauseSession) async throws -> PauseSession {
        session.applying(try await sign(session))
    }
}
