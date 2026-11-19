import Foundation

/// Missing protection metadata on an older backup always means recovery-key encryption.
enum CloudBackupProtection: String, Codable, CaseIterable, Sendable {
    case account
    case recoveryKey

    var requiresRecoveryKey: Bool { self == .recoveryKey }
}
