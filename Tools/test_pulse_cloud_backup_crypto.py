"""Run the production Pulse backup envelope and Apple Health restore policy on macOS."""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Strand" / "Data" / "CloudBackupCore"
SWIFTC = shutil.which("swiftc")
HARNESS = r"""
import Foundation

func expect(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

let key = CloudBackupRecoveryKey.generate()
let reentered = try CloudBackupRecoveryKey(code: " \(key.code.prefix(18))\n\(key.code.dropFirst(18)) ")
expect(reentered == key, "whitespace around the valid recovery code must round-trip")
do {
    _ = try CloudBackupRecoveryKey(code: key.code.dropLast() + "%")
    fatalError("malformed recovery code was accepted")
} catch CloudBackupEncryption.Failure.invalidRecoveryCode {}

let input = file("source")
let sealed = file("sealed")
let second = file("sealed-again")
let output = file("output")
let original = Data((0..<(2 * 1_024 * 1_024 + 53)).map { UInt8(truncatingIfNeeded: $0) })
try original.write(to: input)
let written = try CloudBackupEncryption.seal(input, to: sealed, using: key)
let observed = try CloudBackupEncryption.fileSHA256(sealed)
let stableLength = try sealed.resourceValues(forKeys: [.fileSizeKey]).fileSize
expect(written.sha256 == observed, "manifest checksum must cover the complete ciphertext")
expect(stableLength == Int(written.byteCount), "manifest length must match the file")
let secondWrite = try CloudBackupEncryption.seal(input, to: second, using: key)
expect(written.sha256 != secondWrite.sha256, "each backup must use a fresh salt")

try CloudBackupEncryption.open(sealed, to: output, sha256: observed, using: reentered)
let recovered = try Data(contentsOf: output)
expect(recovered == original, "multi-chunk payload failed to round-trip")
try FileManager.default.removeItem(at: output)

func reject(_ url: URL, sha: String, using key: CloudBackupRecoveryKey,
            is expected: CloudBackupEncryption.Failure) throws {
    do {
        try CloudBackupEncryption.open(url, to: output, sha256: sha, using: key)
        fatalError("invalid download was accepted")
    } catch let error as CloudBackupEncryption.Failure {
        expect(error == expected, "wrong failure classification \(error)")
    }
    expect(!FileManager.default.fileExists(atPath: output.path), "failed decrypt left staged plaintext")
}

try reject(sealed, sha: observed, using: .generate(), is: .authenticationFailed)
try reject(sealed, sha: String(repeating: "0", count: 64), using: key, is: .checksumMismatch)

let encrypted = try Data(contentsOf: sealed)
let corrupt = file("corrupt")
var modified = encrypted
modified[50] ^= 0x80
try modified.write(to: corrupt)
try reject(corrupt, sha: observed, using: key, is: .authenticationFailed)

modified = encrypted
modified[8] ^= 0x01
try modified.write(to: corrupt)
try reject(corrupt, sha: observed, using: key, is: .unsupportedVersion)

let recordBytes = 1_024 * 1_024 + 16
let start = 49
let secondStart = start + recordBytes
modified = encrypted.prefix(start)
modified.append(encrypted[secondStart..<(secondStart + recordBytes)])
modified.append(encrypted[start..<secondStart])
modified.append(encrypted.suffix(from: secondStart + recordBytes))
try modified.write(to: corrupt)
try reject(corrupt, sha: observed, using: key, is: .authenticationFailed)

try encrypted.dropLast().write(to: corrupt)
try reject(corrupt, sha: observed, using: key, is: .invalidFile)
try (encrypted + Data([0])).write(to: corrupt)
try reject(corrupt, sha: observed, using: key, is: .invalidFile)

let sparse = file("oversized")
_ = FileManager.default.createFile(atPath: sparse.path, contents: nil)
let handle = try FileHandle(forWritingTo: sparse)
try handle.truncate(atOffset: UInt64(CloudBackupEncryption.maxCiphertextBytes))
try handle.close()
do {
    _ = try CloudBackupEncryption.seal(sparse, to: output, using: key)
    fatalError("backup that exceeds the cap with encryption overhead was accepted")
} catch CloudBackupEncryption.Failure.tooLarge {}

let suite = "cloud-restore-test-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
expect(CloudBackupRestoreHealthPolicy.floor(in: defaults) == nil, "new installs should export normally")
CloudBackupRestoreHealthPolicy.protectRestoredWorkouts(latestStart: 99, at: Date(timeIntervalSince1970: 123.4),
                                                       in: defaults)
expect(CloudBackupRestoreHealthPolicy.floor(in: defaults) == 124, "all pre-restore workouts must remain protected")
CloudBackupRestoreHealthPolicy.protectRestoredWorkouts(latestStart: 150, at: Date(timeIntervalSince1970: 130),
                                                       in: defaults)
expect(CloudBackupRestoreHealthPolicy.floor(in: defaults) == 151, "a later workout in the restored snapshot must be protected")
CloudBackupRestoreHealthPolicy.protectRestoredWorkouts(latestStart: 99, at: Date(timeIntervalSince1970: 135),
                                                       in: defaults)
expect(CloudBackupRestoreHealthPolicy.floor(in: defaults) == 151, "restoring an older backup must not reenable replay")

func makeDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

func contents(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

let live = file("live")
let pending = file("pending")
let applied = file("completed")
let liveDB = live.appendingPathComponent("whoop.sqlite")
let liveWAL = live.appendingPathComponent("whoop.sqlite-wal")
let previous = pending.appendingPathComponent("previous")
let staged = pending.appendingPathComponent("restore.sqlite")
let restore = CloudBackupRestoreFiles(pending: pending, database: liveDB, staged: staged)
try makeDirectory(live)
try makeDirectory(previous)
try Data("original main".utf8).write(to: liveDB)
try Data("committed WAL changes".utf8).write(to: liveWAL)
try Data("validated database".utf8).write(to: staged)

// Simulate interruption after the main file moved and before the WAL moved.
try FileManager.default.moveItem(at: liveDB, to: previous.appendingPathComponent(liveDB.lastPathComponent))
// An occupied final location forces an interruption after staging the new main file.
try makeDirectory(applied)
var appliedSettings = 0
do {
    try restore.install(preservingPreviousAt: applied, createRollbackDirectory: makeDirectory) {
        appliedSettings += 1
    }
    fatalError("occupied destination was accepted")
} catch {}
let afterInterruption = try contents(liveDB)
expect(afterInterruption == "validated database", "validated file must be in place before settings apply")
let rolledBack = try restore.rollbackIfStaged()
expect(!rolledBack, "the complete installation must retain the receipt for retry")
try FileManager.default.removeItem(at: applied)
try restore.install(preservingPreviousAt: applied, createRollbackDirectory: makeDirectory) {
    appliedSettings += 1
}
let saved = applied.appendingPathComponent("previous")
let rollbackMain = try contents(saved.appendingPathComponent(liveDB.lastPathComponent))
let rollbackWAL = try contents(saved.appendingPathComponent(liveWAL.lastPathComponent))
expect(rollbackMain == "original main" && rollbackWAL == "committed WAL changes",
       "the complete original database and journal must survive")
expect(appliedSettings == 2 && !FileManager.default.fileExists(atPath: pending.path),
       "restore must finish cleanly after reapplying idempotent settings")

try makeDirectory(previous)
try FileManager.default.moveItem(at: liveDB, to: previous.appendingPathComponent(liveDB.lastPathComponent))
try Data("another backup".utf8).write(to: staged)
let rolledBackBeforeInstall = try restore.rollbackIfStaged()
let recoveredOriginal = try contents(liveDB)
expect(rolledBackBeforeInstall && recoveredOriginal == "validated database",
       "rollback must restore the original bytes after an interrupted move")
expect(!FileManager.default.fileExists(atPath: pending.path), "rolled-back request must be retired")

// A missing receipt before any live changes leaves the original database in place.
try makeDirectory(pending)
try Data("incoming with no receipt".utf8).write(to: staged)
let missingReceipt = try restore.readReceipt()
expect(missingReceipt == nil, "a missing receipt must be recoverable")
let pendingQuarantine = try restore.quarantineInvalidReceipt()
let unchanged = try contents(liveDB)
let uninstalled = try contents(pendingQuarantine.appendingPathComponent(staged.lastPathComponent))
expect(unchanged == "validated database" && uninstalled == "incoming with no receipt",
       "the unreadable request must be quarantined with its incoming data")

// Corruption after the new file landed keeps the rollback and incoming data intact.
try makeDirectory(previous)
try FileManager.default.moveItem(at: liveDB, to: previous.appendingPathComponent(liveDB.lastPathComponent))
try Data("old WAL".utf8).write(to: previous.appendingPathComponent(liveWAL.lastPathComponent))
try Data("another installed database".utf8).write(to: liveDB)
try Data().write(to: pending.appendingPathComponent("ready-to-install"))
let receiptURL = pending.appendingPathComponent(CloudBackupRestoreFiles.receiptName)
try Data("{".utf8).write(to: receiptURL)
let invalidReceipt = try restore.readReceipt()
expect(invalidReceipt == nil, "malformed receipt must be recoverable")
let interruptedQuarantine = try restore.quarantineInvalidReceipt()
let preservedIncoming = try contents(interruptedQuarantine.appendingPathComponent(staged.lastPathComponent))
let preservedOldDB = try contents(liveDB)
let preservedOldWAL = try contents(liveWAL)
expect(preservedIncoming == "another installed database" && preservedOldDB == "validated database"
       && preservedOldWAL == "old WAL", "receipt corruption must preserve both data versions")
expect(CloudBackupRestoreHealthPolicy.floor(in: defaults) == 151, "recovery must keep the Health export floor")

// A fresh install that was interrupted after its move can return to an empty state.
try FileManager.default.removeItem(at: liveDB)
try FileManager.default.removeItem(at: liveWAL)
try makeDirectory(pending)
try Data("first database".utf8).write(to: liveDB)
try Data().write(to: pending.appendingPathComponent("ready-to-install"))
try Data("{}".utf8).write(to: receiptURL)
let noVersion = try restore.readReceipt()
expect(noVersion == nil, "a receipt without a version must not activate incoming history")
let freshQuarantine = try restore.quarantineInvalidReceipt()
let quarantinedFirst = try contents(freshQuarantine.appendingPathComponent(staged.lastPathComponent))
expect(!FileManager.default.fileExists(atPath: liveDB.path) && quarantinedFirst == "first database",
       "a fresh install must keep the incoming database quarantined and remain launchable")

// File I/O failures are retried instead of being mistaken for malformed JSON.
try makeDirectory(receiptURL)
do {
    _ = try restore.readReceipt()
    fatalError("nonmissing receipt read error was swallowed")
} catch {}
expect(FileManager.default.fileExists(atPath: pending.path), "retryable read cannot discard the request")
try FileManager.default.removeItem(at: receiptURL)
let receipt = CloudBackupRestoreFiles.Receipt(latestWorkoutStart: 149)
try JSONEncoder().encode(receipt).write(to: receiptURL)
let validReceipt = try restore.readReceipt()
expect(validReceipt?.latestWorkoutStart == 149, "valid restore receipt must retain the Health export boundary")
"""


@unittest.skipUnless(sys.platform == "darwin" and SWIFTC, "Requires Apple's Swift CryptoKit")
class CloudBackupCryptoTests(unittest.TestCase):
    def test_envelope_restore_transaction_and_workout_protection(self):
        with tempfile.TemporaryDirectory(prefix="pulse-cloud-crypto-") as temporary:
            directory = Path(temporary)
            main = directory / "main.swift"
            main.write_text(HARNESS)
            executable = directory / "verify"
            subprocess.run(
                [
                    SWIFTC,
                    "-module-cache-path", str(directory / "modules"),
                    "-O",
                    str(CORE / "CloudBackupEncryption.swift"),
                    str(CORE / "CloudBackupRestoreHealthPolicy.swift"),
                    str(CORE / "CloudBackupRestoreFiles.swift"),
                    str(main),
                    "-o", str(executable),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run([str(executable), str(directory)], check=True)
