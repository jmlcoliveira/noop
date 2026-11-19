"""Exercise the production backup modes, including legacy and mislabelled files."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

import pytest


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Strand/Data/CloudBackupCore"
SWIFTC = shutil.which("swiftc")
pytestmark = pytest.mark.skipif(sys.platform != "darwin" or not SWIFTC, reason="Requires Apple CryptoKit and Compression")

HARNESS = r'''
import Foundation

func expect(_ value: Bool) { precondition(value) }

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func file(_ name: String) -> URL { root.appendingPathComponent(name) }
let files = FileManager.default
let original = file("input.zip")
let compressed = file("compressed")
let expected = try CloudBackupEncryption.fileSHA256(original)
try CloudBackupCompression.compress(original, to: compressed)
let key = CloudBackupRecoveryKey.generate()

for mode in CloudBackupProtection.allCases {
    let payload = file(mode.rawValue)
    let decoded = file(mode.rawValue + "-decoded")
    let expanded = file(mode.rawValue + "-expanded")
    let selectedKey = mode.requiresRecoveryKey ? key : nil
    let stored = try CloudBackupPayload.prepare(compressed, to: payload, protection: mode, using: selectedKey)
    expect(stored.sha256 == (try CloudBackupEncryption.fileSHA256(payload)))
    let opened = try CloudBackupPayload.open(payload, to: decoded, sha256: stored.sha256,
                                           protection: mode, using: selectedKey)
    let archive = try CloudBackupCompression.expandIfNeeded(opened, to: expanded)
    expect(try CloudBackupEncryption.fileSHA256(archive) == expected)
    if mode == .account {
        expect(opened == payload && !files.fileExists(atPath: decoded.path))
        expect(try CloudBackupEncryption.fileSHA256(payload) == CloudBackupEncryption.fileSHA256(compressed))
    }
    let rejected = file(mode.rawValue + "-rejected")
    do {
        _ = try CloudBackupPayload.open(payload, to: rejected, sha256: String(repeating: "0", count: 64),
                                        protection: mode, using: selectedKey)
        fatalError("incorrect checksum accepted")
    } catch CloudBackupEncryption.Failure.checksumMismatch {}
    expect(!files.fileExists(atPath: rejected.path))

    let wrongMode: CloudBackupProtection = mode == .account ? .recoveryKey : .account
    do {
        _ = try CloudBackupPayload.open(payload, to: rejected, sha256: stored.sha256,
                                        protection: wrongMode, using: key)
        fatalError("declared protection was silently changed")
    } catch {}
    expect(!files.fileExists(atPath: rejected.path))
}

let output = file("must-not-exist")
do {
    _ = try CloudBackupPayload.prepare(compressed, to: output, protection: .recoveryKey, using: nil)
    fatalError("private backup created without a key")
} catch CloudBackupPayload.Failure.recoveryKeyRequired {}
expect(!files.fileExists(atPath: output.path))

let privatePayload = file("recoveryKey")
let privateSHA = try CloudBackupEncryption.fileSHA256(privatePayload)
do {
    _ = try CloudBackupPayload.open(privatePayload, to: output, sha256: privateSHA,
                                    protection: .recoveryKey, using: nil)
    fatalError("private backup opened without a key")
} catch CloudBackupPayload.Failure.recoveryKeyRequired {}

// An existing pre-compression recovery-key backup still opens through the same path.
let legacy = file("legacy")
let sealed = try CloudBackupEncryption.seal(original, to: legacy, using: key)
let opened = try CloudBackupPayload.open(legacy, to: output, sha256: sealed.sha256,
                                        protection: .recoveryKey, using: key)
let legacyZIP = try CloudBackupCompression.expandIfNeeded(opened, to: file("legacy-expanded"))
expect(legacyZIP == opened)
let legacyChecksum = try CloudBackupEncryption.fileSHA256(legacyZIP)
expect(legacyChecksum == expected)
try files.removeItem(at: output)

let sentinel = Data("existing destination".utf8)
try sentinel.write(to: output)
do {
    _ = try CloudBackupPayload.prepare(compressed, to: output, protection: .account, using: nil)
    fatalError("existing file overwritten")
} catch {}
expect(try Data(contentsOf: output) == sentinel)
try files.removeItem(at: output)

let sparse = file("oversized")
expect(files.createFile(atPath: sparse.path, contents: Data("PULSEZIP".utf8)))
let handle = try FileHandle(forWritingTo: sparse)
try handle.truncate(atOffset: UInt64(CloudBackupEncryption.maxCiphertextBytes) + 1)
try handle.close()
do {
    _ = try CloudBackupPayload.prepare(sparse, to: output, protection: .account, using: nil)
    fatalError("oversized account backup copied")
} catch CloudBackupEncryption.Failure.tooLarge {}
expect(!files.fileExists(atPath: output.path))
'''


def test_account_and_recovery_key_payloads_round_trip_and_cannot_fall_back():
    with tempfile.TemporaryDirectory(prefix="pulse-backup-payload-") as temporary:
        directory = Path(temporary)
        with zipfile.ZipFile(directory / "input.zip", "w", compression=zipfile.ZIP_STORED) as archive:
            archive.writestr("noop-backup.sqlite", b"synthetic historical records\0" * 50_000)
            archive.writestr("pulse-preferences.json", '{"profile.age":31}')
        main = directory / "main.swift"
        main.write_text(HARNESS)
        executable = directory / "verify"
        sources = [CORE / (name + ".swift") for name in (
            "CloudBackupProtection", "CloudBackupEncryption", "CloudBackupCompression", "CloudBackupPayload")]
        subprocess.run([SWIFTC, "-O", "-module-cache-path", str(directory / "modules"),
                        *map(str, sources), str(main), "-o", str(executable)], check=True,
                       capture_output=True, text=True)
        subprocess.run([str(executable), str(directory)], check=True, capture_output=True, text=True)
