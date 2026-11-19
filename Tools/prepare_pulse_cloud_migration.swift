import Darwin
import Foundation
import GRDB
import WhoopStore
import ZIPFoundation

private enum MigrationFailure: String, Error {
    case arguments = "Invalid migration arguments."
    case archive = "The source is not a complete Pulse backup archive."
    case preferences = "The supplied Pulse preferences could not be read."
    case database = "The snapshot failed Pulse's schema or SQLite integrity checks."
    case databaseTooLarge = "The database exceeds Pulse's uncompressed restore limit."
    case preparation = "Could not prepare and verify the encrypted migration files."
}

private struct MigrationManifest: Encodable {
    let id: String
    let createdAt: String
    let capturedAt: String
    let appVersion: String
    let appBuild: String
    let schemaVersion: Int
    let size: Int64
    let sha256: String
    let recordCounts: [String: Int]
    let settingsCount: Int
}

private struct JournalItem: Decodable {
    let canonical: String
    let custom: Bool
}

private enum PulseCloudMigration {
    static let databaseEntry = "noop-backup.sqlite"
    // These limits match DataBackup.extractCloudArchive.
    static let databaseLimit: Int64 = 2_147_483_648
    static let settingsLimit: Int64 = 1_048_576

    static func prepare(args: [String]) throws {
        guard args.count == 7, ["database", "archive"].contains(args[0]) else {
            throw MigrationFailure.arguments
        }
        let input = URL(fileURLWithPath: args[1])
        let work = URL(fileURLWithPath: args[2], isDirectory: true)
        let preferences = args[3].isEmpty ? nil : URL(fileURLWithPath: args[3])
        let appVersion = args[4]
        let appBuild = args[5]
        let capturedAt = args[6]
        let output = work.appendingPathComponent("output", isDirectory: true)
        let archive = work.appendingPathComponent("snapshot.noopbak")
        let payload = work.appendingPathComponent("snapshot.compressed")
        let database = work.appendingPathComponent("snapshot.sqlite")
        let createdAt = Date()
        let fm = FileManager.default

        var settings: [String: Any] = [:]
        var source = input
        if args[0] == "archive" {
            let extracted = work.appendingPathComponent("extracted", isDirectory: true)
            try fm.createDirectory(at: extracted, withIntermediateDirectories: false)
            let (extractedDatabase, extractedSettings) = try extract(input, into: extracted)
            source = extractedDatabase
            settings = extractedSettings.map(BackupSettings.decode) ?? [:]
        }
        if let preferences {
            try mergePreferences(from: preferences, into: &settings)
        }

        let counts: [String: Int]
        do {
            try CloudBackupDatabase.snapshot(from: source.path, to: database.path)
            guard DatabaseIntegrity.quickCheckFailure(atPath: database.path) == nil else {
                throw MigrationFailure.database
            }
            let latest = try CloudBackupDatabase.preparePortableCopy(at: database.path)
            guard latest != Int.max, DatabaseIntegrity.quickCheckFailure(atPath: database.path) == nil else {
                throw MigrationFailure.database
            }
            counts = try recordCounts(database)
        } catch {
            throw MigrationFailure.database
        }
        let size = try database.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= databaseLimit else { throw MigrationFailure.databaseTooLarge }

        let settingsJSON = BackupSettings.encode(settings)
        let schemaVersion = WhoopStoreInfo.schemaVersion
        let provenance = BackupManifest.json(appVersion: appVersion, appBuild: appBuild, platform: "apple",
                                             schemaVersion: schemaVersion,
                                             exportedAtMs: Int64(createdAt.timeIntervalSince1970 * 1000))
        try writeArchive(archive, database: database, settings: settingsJSON, provenance: Data(provenance.utf8))
        let archiveHash = try CloudBackupEncryption.fileSHA256(archive)
        let databaseHash = try CloudBackupEncryption.fileSHA256(database)
        try CloudBackupCompression.compress(archive, to: payload)
        try fm.removeItem(at: archive)
        try fm.removeItem(at: database)

        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let encrypted = output.appendingPathComponent("snapshot.pulsebackup")
        let key = CloudBackupRecoveryKey.generate()
        let sealed = try CloudBackupEncryption.seal(payload, to: encrypted, using: key)
        try fm.removeItem(at: payload)

        // Exercise the app's envelope and compression readers before publishing the recovery key.
        try CloudBackupEncryption.open(encrypted, to: payload, sha256: sealed.sha256, using: key)
        let verified = try CloudBackupCompression.expandIfNeeded(payload, to: archive)
        guard try CloudBackupEncryption.fileSHA256(verified) == archiveHash else {
            throw MigrationFailure.preparation
        }
        let checked = work.appendingPathComponent("verified", isDirectory: true)
        try fm.createDirectory(at: checked, withIntermediateDirectories: false)
        let (checkedDatabase, checkedSettings) = try extract(verified, into: checked)
        guard try CloudBackupEncryption.fileSHA256(checkedDatabase) == databaseHash,
              checkedSettings == settingsJSON else {
            throw MigrationFailure.preparation
        }

        let dateFormat = ISO8601DateFormatter()
        dateFormat.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let summary = MigrationManifest(id: UUID().uuidString.lowercased(), createdAt: dateFormat.string(from: createdAt),
                                        capturedAt: capturedAt, appVersion: appVersion, appBuild: appBuild,
                                        schemaVersion: schemaVersion, size: sealed.byteCount, sha256: sealed.sha256,
                                        recordCounts: counts, settingsCount: settingsJSON.map(BackupSettings.decode)?.count ?? 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: output.appendingPathComponent("manifest.json"))
        let keyFile = output.appendingPathComponent("recovery-key.txt")
        try Data((key.code + "\n").utf8).write(to: keyFile, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }

    private static func recordCounts(_ database: URL) throws -> [String: Int] {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: database.path, configuration: config)
        defer { try? queue.close() }
        return try queue.read { db in
            let tables = ["appleDaily", "appleStepHour", "dailyMetric", "event", "hrSample", "journal", "liftSession",
                          "metricSeries", "pairedDevice", "rawBatch", "rrInterval", "sleepSession", "stepSample", "workout"]
            var counts: [String: Int] = [:]
            for table in tables where try db.tableExists(table) {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
            }
            return counts
        }
    }

    private static func mergePreferences(from file: URL, into settings: inout [String: Any]) throws {
        guard let bytes = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil),
              let defaults = plist as? [String: Any] else { throw MigrationFailure.preferences }
        for (canonical, key) in BackupSettings.appleDefaultsKey {
            if let value = defaults[key] { settings[canonical] = value }
        }
        // Same portable journal names as DataBackup.currentSettingsJSON.
        if let blob = defaults["journal.catalog.v2"] as? Data,
           let items = try? JSONDecoder().decode([JournalItem].self, from: blob) {
            let names = items.filter(\.custom).map(\.canonical)
            if !names.isEmpty { settings["journal.customBehaviors"] = names.joined(separator: "\n") }
        }
    }

    private static func writeArchive(_ destination: URL, database: URL, settings: Data?, provenance: Data) throws {
        let archive = try Archive(url: destination, accessMode: .create)
        try archive.addEntry(with: databaseEntry, fileURL: database, compressionMethod: .none)
        if let settings {
            guard settings.count <= settingsLimit else { throw MigrationFailure.preferences }
            try add(settings, named: BackupSettings.entryName, to: archive, beside: destination)
        }
        try add(provenance, named: BackupManifest.entryName, to: archive, beside: destination)
    }

    private static func add(_ data: Data, named name: String, to archive: Archive, beside destination: URL) throws {
        let file = destination.deletingLastPathComponent().appendingPathComponent(name)
        try data.write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        try archive.addEntry(with: name, fileURL: file, compressionMethod: .none)
    }

    private static func extract(_ source: URL, into destination: URL) throws -> (URL, Data?) {
        do {
            let archive = try Archive(url: source, accessMode: .read)
            var accepted = Set<String>()
            for entry in archive where entry.type == .file {
                let name = (entry.path as NSString).lastPathComponent
                let limit: Int64
                switch name {
                case databaseEntry: limit = databaseLimit
                case BackupSettings.entryName: limit = settingsLimit
                default: continue
                }
                guard name == entry.path, accepted.insert(name).inserted,
                      entry.uncompressedSize <= UInt64(limit) else { throw MigrationFailure.archive }
                let file = destination.appendingPathComponent(name)
                try Data().write(to: file, options: .withoutOverwriting)
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                var written: Int64 = 0
                let checksum = try archive.extract(entry) { data in
                    written += Int64(data.count)
                    guard written <= limit else { throw MigrationFailure.archive }
                    try handle.write(contentsOf: data)
                }
                guard checksum == entry.checksum, UInt64(written) == entry.uncompressedSize else {
                    throw MigrationFailure.archive
                }
            }
            guard accepted.contains(databaseEntry) else { throw MigrationFailure.archive }
            let settings = accepted.contains(BackupSettings.entryName)
                ? try Data(contentsOf: destination.appendingPathComponent(BackupSettings.entryName))
                : nil
            return (destination.appendingPathComponent(databaseEntry), settings)
        } catch {
            throw MigrationFailure.archive
        }
    }
}

@main
private enum PreparePulseCloudMigration {
    static func main() {
        umask(0o077)
        do {
            try PulseCloudMigration.prepare(args: Array(CommandLine.arguments.dropFirst()))
        } catch {
            // SQLite/ZIP errors can contain arbitrary strings from the store. Keep them out of logs.
            let message = (error as? MigrationFailure)?.rawValue
                ?? (error as? CloudBackupEncryption.Failure)?.localizedDescription
                ?? MigrationFailure.preparation.rawValue
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }
}
