import CryptoKit
import Foundation
import WhoopStore

enum CloudBackupFiles {
    private static let protectedAttributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        .posixPermissions: 0o700,
    ]

    static func root() throws -> URL {
        let applicationSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                             appropriateFor: nil, create: true)
        return applicationSupport.appendingPathComponent("PulseCloudBackup", isDirectory: true)
    }

    static func makeWorkingDirectory() throws -> URL {
        let root = try root()
        try makeProtectedDirectory(root)
        let work = root.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try makeProtectedDirectory(work)
        return work
    }

    static func pendingDirectory() throws -> URL {
        try root().appendingPathComponent("pending-restore", isDirectory: true)
    }

    static func makeProtectedDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: protectedAttributes)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

enum CloudBackupSnapshot {
    struct Prepared: Sendable {
        let fileURL: URL
        let byteCount: Int64
        let sha256: String
        let fingerprint: String
    }

    enum RestoreOutcome: Equatable {
        case restored
        case failed(String)
    }

    private enum Failure: LocalizedError {
        case restorePending
        case missingDatabase
        case invalidWorkoutDate

        var errorDescription: String? {
            switch self {
            case .restorePending: String(localized: "Fully quit and reopen Pulse to finish restoring this backup.")
            case .missingDatabase: String(localized: "There is no Pulse database to back up yet.")
            case .invalidWorkoutDate: String(localized: "The backup contains an invalid workout date.")
            }
        }
    }

    // Store path resolution is shared by BLE and the main app. Both must observe the same
    // launch result, and neither may open SQLite while the pending restore moves its files.
    private static let restoreLock = NSLock()
    private static var settledThisLaunch = false
    private static var queuedThisLaunch = false
    private static var outcome: RestoreOutcome?

    static var lastRestoreOutcome: RestoreOutcome? {
        restoreLock.withLock { outcome }
    }

    static var hasPendingRestore: Bool {
        guard let pending = try? CloudBackupFiles.pendingDirectory() else { return false }
        return FileManager.default.fileExists(atPath: pending.path)
    }

    static func prepareIfChanged(in directory: URL, using recoveryKey: CloudBackupRecoveryKey,
                                 previousFingerprint: String?) throws -> Prepared? {
        guard !hasPendingRestore else { throw Failure.restorePending }
        let sourcePath = try StorePaths.defaultDatabasePath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else { throw Failure.missingDatabase }

        let database = directory.appendingPathComponent("snapshot.sqlite")
        let archive = directory.appendingPathComponent("snapshot.noopbak")
        let compressed = directory.appendingPathComponent("snapshot.compressed")
        let encrypted = directory.appendingPathComponent("snapshot.pulsebackup")
        defer {
            for url in [database, archive, compressed] { try? fm.removeItem(at: url) }
        }
        try CloudBackupDatabase.snapshot(from: sourcePath, to: database.path)
        _ = try CloudBackupDatabase.preparePortableCopy(at: database.path)

        let settings = DataBackup.currentSettingsJSON()
        let databaseHash = try CloudBackupEncryption.fileSHA256(database)
        let settingsHash = CloudBackupEncryption.hex(SHA256.hash(data: settings ?? Data()))
        let fingerprint = CloudBackupEncryption.hex(SHA256.hash(data: Data((databaseHash + settingsHash).utf8)))
        guard fingerprint != previousFingerprint else { return nil }

        try DataBackup.writeCloudArchive(database: database, settingsJSON: settings, to: archive)
        try fm.removeItem(at: database)
        try CloudBackupCompression.compress(archive, to: compressed)
        try fm.removeItem(at: archive)
        let sealed = try CloudBackupEncryption.seal(compressed, to: encrypted, using: recoveryKey)
        return Prepared(fileURL: encrypted, byteCount: sealed.byteCount, sha256: sealed.sha256, fingerprint: fingerprint)
    }

    /// Authenticate and validate before publishing a restore request. The current process
    /// keeps its store open. A later process installs the staged copy before opening SQLite.
    static func stageRestore(from fileURL: URL, sha256: String, using recoveryKey: CloudBackupRecoveryKey) throws {
        let fm = FileManager.default
        let working = try CloudBackupFiles.makeWorkingDirectory()
        defer { try? fm.removeItem(at: working) }
        let decrypted = working.appendingPathComponent("snapshot.payload")
        let expanded = working.appendingPathComponent("snapshot.noopbak")
        let staged = working.appendingPathComponent("staged", isDirectory: true)
        try CloudBackupFiles.makeProtectedDirectory(staged)

        try CloudBackupEncryption.open(fileURL, to: decrypted, sha256: sha256, using: recoveryKey)
        let archive = try CloudBackupCompression.expandIfNeeded(decrypted, to: expanded)
        if archive != decrypted { try fm.removeItem(at: decrypted) }
        let database = try DataBackup.extractCloudArchive(archive, into: staged)
        try fm.removeItem(at: archive)
        let latestWorkout = try CloudBackupDatabase.preparePortableCopy(at: database.path)
        guard latestWorkout != Int.max else { throw Failure.invalidWorkoutDate }
        if DatabaseIntegrity.quickCheckFailure(atPath: database.path) != nil {
            throw CocoaError(.fileReadCorruptFile)
        }
        let receipt = CloudBackupRestoreFiles.Receipt(latestWorkoutStart: latestWorkout)
        let receiptURL = staged.appendingPathComponent(CloudBackupRestoreFiles.receiptName)
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        try Task.checkCancellation()
        try restoreLock.withLock {
            let pending = try CloudBackupFiles.pendingDirectory()
            guard !fm.fileExists(atPath: pending.path) else { throw Failure.restorePending }
            try fm.moveItem(at: staged, to: pending)
            queuedThisLaunch = true
        }
    }

    /// Runs before AppModel reads its profile defaults. StorePaths also runs the same gate,
    /// so a launch interrupted by iOS data protection can retry before any handle opens.
    static func applyPendingRestoreAtLaunch() {
        if hasPendingRestore { _ = try? StorePaths.defaultDatabasePath() }
        if let root = try? CloudBackupFiles.root(),
           let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let abandoned = entries.filter { $0.lastPathComponent.hasPrefix("work-") }
            Task.detached(priority: .utility) {
                for entry in abandoned { try? FileManager.default.removeItem(at: entry) }
            }
        }
    }

    static func applyPendingRestoreBeforeOpeningStore(at database: URL) throws {
        try restoreLock.withLock {
            guard !settledThisLaunch, !queuedThisLaunch else { return }
            let fm = FileManager.default
            let pending = try CloudBackupFiles.pendingDirectory()
            guard fm.fileExists(atPath: pending.path) else {
                settledThisLaunch = true
                return
            }

            let staged = pending.appendingPathComponent(DataBackup.backupEntryName)
            let transaction = CloudBackupRestoreFiles(pending: pending, database: database, staged: staged)
            let receipt: CloudBackupRestoreFiles.Receipt
            do {
                guard let loaded = try transaction.readReceipt() else {
                    // Preserve both database versions. Without a valid receipt the incoming
                    // history must never become active or enter the HealthKit write window.
                    outcome = .failed(CloudBackupRestoreFiles.Incomplete().localizedDescription)
                    try transaction.quarantineInvalidReceipt()
                    settledThisLaunch = true
                    return
                }
                receipt = loaded
            } catch {
                // Data protection can temporarily make a valid receipt unreadable.
                outcome = .failed(error.localizedDescription)
                throw error
            }
            let completed = pending.deletingLastPathComponent()
                .appendingPathComponent("rollback-\(UUID().uuidString)", isDirectory: true)
            do {
                try transaction.install(preservingPreviousAt: completed,
                                        createRollbackDirectory: CloudBackupFiles.makeProtectedDirectory) {
                    DataBackup.applyExtractedSettings(from: pending)
                    CloudBackupRestoreHealthPolicy.protectRestoredWorkouts(latestStart: receipt.latestWorkoutStart)
                    HealthKitBridge.resetReadAnchorsAfterCloudRestore()
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.lastRestoreAt")
                }
                settledThisLaunch = true
                outcome = .restored
                cleanup(keeping: completed)
            } catch {
                outcome = .failed(error.localizedDescription)
                if try transaction.rollbackIfStaged() {
                    settledThisLaunch = true
                    return
                }
                throw error
            }
        }
    }

    private static func cleanup(keeping completed: URL) {
        let fm = FileManager.default
        let root = completed.deletingLastPathComponent()
        if let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix("rollback-") && entry.path != completed.path {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
