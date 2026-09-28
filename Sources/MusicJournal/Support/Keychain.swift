import Foundation
import Security

/// Minimal generic-password Keychain wrapper: the journal's key and the Spotify token.
enum Keychain {
    static let service = "MusicJournal"

    /// Earlier builds stored items under a service ending in one of these (found by that
    /// ending, never by a full name). Nothing is adopted from them automatically: any app can
    /// create an item with such a name, so only the journal uses them, and only for a key
    /// that proves itself by opening the existing journal (see `JournalCipher.loadKey`).
    static let legacyServiceSuffixes = [".spothelper", ".musicjournal"]

    static func set(_ value: String, for account: String) {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    enum ReadError: Error {
        /// The item exists but couldn't be read (e.g. access was denied after a rebuild).
        case unreadable(OSStatus)
    }

    /// Like `get`, but tells "not stored" (nil) apart from "stored but unreadable" (throws).
    static func read(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw ReadError.unreadable(status)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw ReadError.unreadable(status)
        }
    }

    /// Values stored for `account` under earlier service names. Untrusted: the caller must
    /// check each one before using it. Throws only if matches exist but none could be read.
    static func legacyValues(_ account: String) throws -> [String] {
        let search: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var found: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess,
              let items = found as? [[String: Any]] else { return [] }
        let services = items.compactMap { $0[kSecAttrService as String] as? String }
            .filter { name in name != service && legacyServiceSuffixes.contains { name.hasSuffix($0) } }
        var values: [String] = []
        var denied: OSStatus?
        for legacy in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacy,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
                values.append(value)
            } else if status != errSecItemNotFound {
                denied = status
            }
        }
        if values.isEmpty, let denied { throw ReadError.unreadable(denied) }
        return values
    }

    static func get(_ account: String) -> String? {
        (try? read(account)) ?? nil
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
