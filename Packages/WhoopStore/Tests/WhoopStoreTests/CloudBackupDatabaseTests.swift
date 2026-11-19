import GRDB
import XCTest
@testable import WhoopStore

final class CloudBackupDatabaseTests: XCTestCase {
    func testSnapshotReadsCommittedWALWhileWriterIsActive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite").path
        let copied = directory.appendingPathComponent("copy.sqlite").path
        let secondCopy = directory.appendingPathComponent("second-copy.sqlite").path
        let pool = try DatabasePool(path: source)
        try await pool.write { db in
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (42)")
        }

        let writerStarted = DispatchSemaphore(value: 0)
        let allowCommit = DispatchSemaphore(value: 0)
        let writer = Task.detached {
            try pool.write { db in
                try db.execute(sql: "INSERT INTO t VALUES (43)")
                writerStarted.signal()
                _ = allowCommit.wait(timeout: .now() + 10)
            }
        }
        defer { allowCommit.signal() }
        XCTAssertEqual(writerStarted.wait(timeout: .now() + 5), .success)
        try CloudBackupDatabase.snapshot(from: source, to: copied)
        try CloudBackupDatabase.snapshot(from: source, to: secondCopy)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copied)),
                       try Data(contentsOf: URL(fileURLWithPath: secondCopy)))
        let queue = try DatabaseQueue(path: copied)
        let snapshotValues = try await queue.read { try Int.fetchAll($0, sql: "SELECT v FROM t ORDER BY v") }
        XCTAssertEqual(snapshotValues, [42])
        allowCommit.signal()
        try await writer.value
        let liveValues = try await pool.read { try Int.fetchAll($0, sql: "SELECT v FROM t ORDER BY v") }
        XCTAssertEqual(liveValues, [42, 43])
    }

    func testPortableCopyStripsLocalPairingAndCursorsOnlyFromCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite").path
        let copied = directory.appendingPathComponent("copy.sqlite").path
        let store = try await WhoopStore(path: source)
        try await store.registryWriter.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET peripheralId = 'local-phone' WHERE id = 'my-whoop'")
            try db.execute(sql: "INSERT INTO cursors VALUES ('strap_trim', 7)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', 1000, 70)")
            try db.execute(sql: """
                INSERT INTO workout (deviceId, startTs, endTs, sport, source)
                VALUES ('my-whoop', 1200, 1300, 'running', 'manual')
                """)
        }

        try CloudBackupDatabase.snapshot(from: source, to: copied)
        XCTAssertEqual(try CloudBackupDatabase.preparePortableCopy(at: copied), 1200)
        let repeated = directory.appendingPathComponent("repeated.sqlite")
        try CloudBackupDatabase.snapshot(from: source, to: repeated.path)
        XCTAssertEqual(try CloudBackupDatabase.preparePortableCopy(at: repeated.path), 1200)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copied)), try Data(contentsOf: repeated))
        let portable = try DatabaseQueue(path: copied)
        let local = store.registryWriter
        for (database, expectedPeripheral, expectedCursor) in [
            (portable as any DatabaseReader, nil as String?, nil as Int?),
            (local as any DatabaseReader, "local-phone", 7),
        ] {
            let (peripheral, cursor, heartRate) = try await database.read { db in
                let peripheral = try String.fetchOne(db, sql: "SELECT peripheralId FROM pairedDevice WHERE id = 'my-whoop'")
                let cursor = try Int.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = 'strap_trim'")
                let heartRate = try Int.fetchOne(db, sql: "SELECT bpm FROM hrSample WHERE ts = 1000")
                return (peripheral, cursor, heartRate)
            }
            XCTAssertEqual(peripheral, expectedPeripheral)
            XCTAssertEqual(cursor, expectedCursor)
            XCTAssertEqual(heartRate, 70)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied + "-wal"))
        XCTAssertNil(DatabaseIntegrity.quickCheckFailure(atPath: copied))
    }
}
