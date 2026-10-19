// UI-5: Keychain wrapper via the Security framework (generic password).
// The LAN-access API key lives here, it never lands in config.json
// (Config.swift: «the key is in Keychain, JSON holds only the lan_access flag»).
//
// Generic password, not a data-protection keychain: ad-hoc signed dev builds
// without entitlements work with the login keychain; items created by the
// binary are read by the same binary without a prompt (ACL by creator).
import Foundation
import Security

public enum BMemKeychain {
    /// The service is bound to the bundle: the dev build (com.bmem.app.dev) and
    /// production BMem.app live in separate keychain records and do not overwrite
    /// each other. In the test binary (xctest) it has its own value — the production record stays.
    public static var service: String {
        (Bundle.main.bundleIdentifier ?? "com.bmem.tests") + ".lan"
    }
    /// LAN key account (the only facade secret so far).
    public static let lanKeyAccount = "lan-api-key"

    public enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus, String)
        public var description: String {
            switch self {
            case let .unexpectedStatus(status, op):
                let msg = SecCopyErrorMessageString(status, nil).map { String($0) } ?? "no description"
                return "keychain \(op) failed: OSStatus \(status) (\(msg))"
            }
        }
    }

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Save (add, update when the item exists).
    public static func save(account: String, value: String) throws {
        var q = query(account: account)
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let add = q.merging(attrs) { _, new in new }
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(q as CFDictionary,
                                   [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status, "save")
        }
        _ = q
    }

    /// Read; nil — no item (not an error).
    public static func read(account: String) throws -> String? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw KeychainError.unexpectedStatus(status, "read")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Delete; true — the item existed and was deleted, false — there was no item.
    @discardableResult
    public static func delete(account: String) throws -> Bool {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status, "delete")
        }
        return true
    }

    /// API key: 40 hex characters (20 bytes of entropy from SecRandomCopyBytes).
    public static func generateAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // The fallback must not crash the UI: take a UUID, entropy is plenty anyway.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
