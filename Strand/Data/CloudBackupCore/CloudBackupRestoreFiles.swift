import Foundation

/// Installs a validated, standalone SQLite file before any store connections open.
/// All paths are on the same filesystem. The pending directory records enough state
/// to resume after interruption while preserving the original database and journal files.
struct CloudBackupRestoreFiles {
    let pending: URL
    let database: URL
    let staged: URL

    private var rollback: URL { pending.appendingPathComponent("previous", isDirectory: true) }
    private var ready: URL { pending.appendingPathComponent("ready-to-install") }
    private static let sidecarSuffixes = ["", "-wal", "-shm", "-journal"]
    static let receiptName = "receipt.json"

    struct Receipt: Codable {
        let version: Int
        let latestWorkoutStart: Int?

        init(latestWorkoutStart: Int?) {
            version = 1
            self.latestWorkoutStart = latestWorkoutStart
        }
    }

    struct Incomplete: LocalizedError {
        var errorDescription: String? {
            String(localized: "Pulse could not finish restoring the local database.")
        }
    }

    func readReceipt() throws -> Receipt? {
        let receipt = pending.appendingPathComponent(Self.receiptName)
        do {
            let decoded = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receipt))
            guard decoded.version == 1, decoded.latestWorkoutStart != Int.max else { return nil }
            return decoded
        } catch is DecodingError {
            return nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    /// A missing or malformed receipt cannot install. Reclaim the original database
    /// and keep the staged copy, including one moved into place before interruption.
    @discardableResult
    func quarantineInvalidReceipt() throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: ready.path), !fm.fileExists(atPath: staged.path),
           fm.fileExists(atPath: database.path) {
            try fm.moveItem(at: database, to: staged)
        }
        try moveDatabaseFiles(from: rollback, to: database.deletingLastPathComponent())
        let quarantine = pending.deletingLastPathComponent()
            .appendingPathComponent("quarantine-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: pending, to: quarantine)
        return quarantine
    }

    func install(preservingPreviousAt completed: URL,
                 createRollbackDirectory: (URL) throws -> Void,
                 applySettings: () -> Void) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: ready.path) {
            guard fm.fileExists(atPath: staged.path) else { throw Incomplete() }
            try createRollbackDirectory(rollback)
            try moveDatabaseFiles(from: database.deletingLastPathComponent(), to: rollback)
            // Once marked, a missing staged file means the new live file already landed.
            try Data().write(to: ready, options: .atomic)
        }
        if fm.fileExists(atPath: staged.path) { try fm.moveItem(at: staged, to: database) }
        guard fm.fileExists(atPath: database.path) else { throw Incomplete() }

        applySettings()
        try fm.moveItem(at: pending, to: completed)
    }

    /// Before the new file lands safely abandon the request by restoring any original
    /// files already moved. After the move, keep the receipt for an idempotent retry.
    func rollbackIfStaged() throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: staged.path) else { return false }
        try moveDatabaseFiles(from: rollback, to: database.deletingLastPathComponent())
        let discarded = pending.deletingLastPathComponent()
            .appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: pending, to: discarded)
        try? fm.removeItem(at: discarded)
        return true
    }

    private func moveDatabaseFiles(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        for suffix in Self.sidecarSuffixes {
            let filename = database.lastPathComponent + suffix
            let src = source.appendingPathComponent(filename)
            let dest = destination.appendingPathComponent(filename)
            if fm.fileExists(atPath: src.path) {
                guard !fm.fileExists(atPath: dest.path) else { throw Incomplete() }
                try fm.moveItem(at: src, to: dest)
            }
        }
    }
}
