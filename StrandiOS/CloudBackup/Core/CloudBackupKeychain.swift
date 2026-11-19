import Foundation
import Security

enum CloudBackupKeychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".cloud-backup-recovery"

    static func load(accountID: String) throws -> CloudBackupRecoveryKey? {
        var query = attributes(accountID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data, let code = String(data: data, encoding: .utf8) else {
            throw CloudBackupEncryption.Failure.invalidRecoveryCode
        }
        return try CloudBackupRecoveryKey(code: code)
    }

    static func save(_ key: CloudBackupRecoveryKey, accountID: String) throws {
        let query = attributes(accountID)
        let data = Data(key.code.utf8)
        let add = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { old, _ in old }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary))
        } else {
            try check(status)
        }
    }

    static func remove(accountID: String) throws {
        let status = SecItemDelete(attributes(accountID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func attributes(_ accountID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: accountID,
         kSecAttrSynchronizable as String: false]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }

    private struct KeychainFailure: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            String(localized: "Pulse could not access the recovery key on this device (Keychain error \(status)).")
        }
    }
}
