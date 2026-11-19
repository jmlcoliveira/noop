import Foundation
import GRDB

/// SQLite operations for a portable Pulse backup. The local store schema is unchanged.
public enum CloudBackupDatabase {
    /// Copy one committed database view, including pages in the WAL. Other connections
    /// may keep reading and recording while SQLite reads the source transaction.
    public static func snapshot(from sourcePath: String, to destinationPath: String) throws {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(5)
        let source = try DatabaseQueue(path: sourcePath, configuration: config)
        let destination = try DatabaseQueue(path: destinationPath)
        try source.backup(to: destination)
        try destination.close()
        try source.close()
    }

    /// Check that the database can open on this version and apply pending migrations while it
    /// is still staged. Remove phone-local state before the staged file becomes portable.
    public static func preparePortableCopy(at path: String) throws -> Int? {
        let database = try DatabaseQueue(path: path)
        let migrator = WhoopStore.makeMigrator()
        try database.read { db in
            let applied = try migrator.appliedIdentifiers(db)
            guard !applied.isEmpty, applied == Set(migrator.migrations.prefix(applied.count)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        try migrator.migrate(database)
        let latestWorkoutStart = try database.write { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "UPDATE pairedDevice SET peripheralId = NULL WHERE peripheralId IS NOT NULL")
            try db.execute(sql: "DELETE FROM cursors")
            return try Int.fetchOne(db, sql: "SELECT MAX(startTs) FROM workout")
        }
        // The staged database must be standalone when it is moved into place.
        try database.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
        }
        try database.close()
        return latestWorkoutStart
    }
}
