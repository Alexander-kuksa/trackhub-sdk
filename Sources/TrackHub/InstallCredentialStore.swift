import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

/// Keychain-backed storage for the opaque credential of one TrackHub install.
/// The credential is device-scoped, excluded from backup, and never logged.
@_spi(Testing) public enum InstallCredentialStore {
    private static let service = "com.trackhub.install-credential"

    public static func isValid(_ token: String) -> Bool {
        token.range(
            of: #"^thic_v1_[A-Za-z0-9_-]{43}$"#,
            options: .regularExpression
        ) != nil
    }

    public static func account(ingestToken: String, installUid: String) -> String {
        let material = Data("\(ingestToken)\u{0}\(installUid)".utf8)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(ingestToken: String, installUid: String) -> String? {
        #if canImport(Security)
        var query = baseQuery(ingestToken: ingestToken, installUid: installUid)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              isValid(token) else { return nil }
        return token
        #else
        return nil
        #endif
    }

    @discardableResult
    public static func save(_ token: String, ingestToken: String, installUid: String) -> Bool {
        guard isValid(token) else { return false }
        #if canImport(Security)
        let query = baseQuery(ingestToken: ingestToken, installUid: installUid)
        let value = Data(token.utf8)
        let update = [kSecValueData as String: value]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = value
        #if os(iOS)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    public static func delete(ingestToken: String, installUid: String) {
        #if canImport(Security)
        SecItemDelete(baseQuery(ingestToken: ingestToken, installUid: installUid) as CFDictionary)
        #endif
    }

    /// Privacy erasure must also remove credentials left under a rotated SDK
    /// key. The Keychain service is private to this app, so deleting the whole
    /// service is both narrower and safer than trying to rediscover old token
    /// hashes after rotation.
    public static func deleteAll() {
        #if canImport(Security)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        #endif
    }

    #if canImport(Security)
    private static func baseQuery(ingestToken: String, installUid: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(ingestToken: ingestToken, installUid: installUid),
        ]
    }
    #endif
}
