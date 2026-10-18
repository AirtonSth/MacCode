import CryptoKit
import Foundation
import Security

protocol RelayHostKeyStoring: Sendable {
    /// Returns the persisted Mac relay static key, creating it on first use.
    func loadOrCreate() throws -> Curve25519.KeyAgreement.PrivateKey
}

enum RelayHostKeyStoreError: Error {
    case keychain(OSStatus)
    case corrupt
}

final class KeychainRelayHostKeyStore: RelayHostKeyStoring, @unchecked Sendable {
    private let service = "io.remotecode.relay"
    private let account = "host-static-v1"
    private let lock = NSLock()

    func loadOrCreate() throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data,
                  let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
                throw RelayHostKeyStoreError.corrupt
            }
            return key
        }
        guard status == errSecItemNotFound else { throw RelayHostKeyStoreError.keychain(status) }
        let key = Curve25519.KeyAgreement.PrivateKey()
        var add = baseQuery
        add[kSecValueData as String] = key.rawRepresentation
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw RelayHostKeyStoreError.keychain(addStatus) }
        return key
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

final class InMemoryRelayHostKeyStore: RelayHostKeyStoring, @unchecked Sendable {
    private let key = Curve25519.KeyAgreement.PrivateKey()
    func loadOrCreate() throws -> Curve25519.KeyAgreement.PrivateKey { key }
}
