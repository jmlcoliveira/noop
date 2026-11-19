"""Verify the offline migration on a copied Pulse-shaped SQLite WAL database."""

from __future__ import annotations

from contextlib import closing
from datetime import datetime
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
from uuid import uuid4
import zipfile

import pytest


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "Tools" / "prepare_pulse_cloud_migration.py"
OUTPUT = ROOT / "build" / "cloud-migration"
PRODUCTS = ROOT / "build" / "macOS" / "Build" / "Products" / "Debug"
MIGRATIONS = ROOT / "Packages" / "WhoopStore" / "Sources" / "WhoopStore" / "Database.swift"
CORE = ROOT / "Strand" / "Data" / "CloudBackupCore"
CLOUD_SOURCES = [CORE / "CloudBackupEncryption.swift", CORE / "CloudBackupCompression.swift"]
CAPTURE_TIME = "2026-11-19T13:00:00Z"
pytestmark = pytest.mark.skipif(sys.platform != "darwin" or not (PRODUCTS / "GRDB.o").is_file(),
                                reason="Requires macOS and cached Strand macOS dependency objects")


@pytest.fixture
def run_tool():
    outputs = []

    def run(*args):
        name = "migration-test-" + uuid4().hex
        output = OUTPUT / name
        outputs.append(output)
        result = subprocess.run([
            sys.executable, TOOL, *args, "--app-version", "12.1.0", "--app-build", "439",
            "--captured-at", CAPTURE_TIME, "--output-name", name,
        ], capture_output=True, text=True)
        return result, output

    yield run
    for directory in outputs:
        if directory.exists():
            shutil.rmtree(directory)


def test_migration_restores_committed_wal_and_only_portable_settings(tmp_path, run_tool):
    original = tmp_path / "original.sqlite"
    copied = tmp_path / "copied.sqlite"
    copied_wal = tmp_path / "copied.sqlite-wal"
    migrations = re.findall(r'migrator\.registerMigration\("([^"]+)"\)', MIGRATIONS.read_text())
    assert migrations and migrations[0] == "v1"
    heart_rate = [("retained-device", ts, bpm) for ts, bpm in (
        (20, 71), (27, 67), (36, 69), (42, 86), (45, 74), (51, 75), (56, 73), (1001, 132), (2050, 64),
    )]
    rr_intervals = [("retained-device", 1019, 622), ("retained-device", 1021, 607)]
    with closing(sqlite3.connect(original)) as writer:
        writer.execute("PRAGMA journal_mode=WAL")
        writer.execute("PRAGMA wal_autocheckpoint=0")
        writer.executescript("""
            CREATE TABLE grdb_migrations(identifier TEXT PRIMARY KEY NOT NULL);
            CREATE TABLE pairedDevice(id TEXT PRIMARY KEY, peripheralId TEXT);
            CREATE TABLE cursors(name TEXT PRIMARY KEY, value INTEGER);
            CREATE TABLE workout(startTs INTEGER PRIMARY KEY, endTs INTEGER);
            CREATE TABLE sleepSession(startTs INTEGER PRIMARY KEY, endTs INTEGER);
            CREATE TABLE hrSample(deviceId TEXT, ts INTEGER, bpm INTEGER, PRIMARY KEY(deviceId, ts));
            CREATE TABLE rrInterval(deviceId TEXT, ts INTEGER, rrMs INTEGER, PRIMARY KEY(deviceId, ts, rrMs));
            CREATE TABLE event(kind TEXT, payloadJSON TEXT);
            INSERT INTO pairedDevice VALUES ('retained-device', 'device-local-peripheral');
            INSERT INTO cursors VALUES ('device-local-cursor', 123);
            INSERT INTO event VALUES ('health-export-ledger', 'retained-export-metadata');
        """)
        writer.executemany("INSERT INTO grdb_migrations VALUES (?)", [(name,) for name in migrations])
        writer.commit()
        writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        writer.execute("INSERT INTO workout VALUES (1000, 1200)")
        writer.execute("INSERT INTO sleepSession VALUES (2000, 4000)")
        writer.executemany("INSERT INTO hrSample VALUES (?, ?, ?)", heart_rate)
        writer.executemany("INSERT INTO rrInterval VALUES (?, ?, ?)", rr_intervals)
        writer.commit()
        shutil.copyfile(original, copied)
        shutil.copyfile(tmp_path / "original.sqlite-wal", copied_wal)
    originals = (copied.read_bytes(), copied_wal.read_bytes())

    preferences = tmp_path / "preferences.plist"
    dob = datetime(1990, 5, 24, 4, 5, 6)
    journal = json.dumps([
        {"canonical": "Kept behavior", "custom": True},
        {"canonical": "Default behavior", "custom": False},
    ]).encode()
    preferences.write_bytes(plistlib.dumps({
        "profile.hrMaxOverride": 188,
        "profile.dateOfBirth": dob,
        "theme.appearance": "light",
        "appIcon.alt": True,
        "profile.sex": "synthetic-profile",
        "noop.healthAnchor": b"secret-health-anchor",
        "journal.catalog.v2": journal,
    }, fmt=plistlib.FMT_BINARY))
    result, output = run_tool("--database", copied, "--preferences", preferences)
    assert result.returncode == 0, result.stderr
    assert (copied.read_bytes(), copied_wal.read_bytes()) == originals
    assert not (tmp_path / "copied.sqlite-shm").exists()
    assert set(path.name for path in output.iterdir()) == {"snapshot.pulsebackup", "manifest.json", "recovery-key.txt"}
    key = output / "recovery-key.txt"
    assert stat.S_IMODE(key.stat().st_mode) == 0o600
    assert key.read_text().startswith("PULSE1-")
    assert not any(secret in result.stdout + result.stderr for secret in (
        key.read_text().strip(), "synthetic-profile", "device-local-peripheral", "secret-health-anchor",
    ))
    manifest = json.loads((output / "manifest.json").read_bytes())
    assert manifest["capturedAt"] == "2026-11-19T13:00:00.000Z"
    assert manifest["recordCounts"]["workout"] == 1
    assert manifest["recordCounts"]["sleepSession"] == 1
    assert manifest["recordCounts"]["hrSample"] == len(heart_rate)
    assert manifest["recordCounts"]["rrInterval"] == len(rr_intervals)
    assert manifest["settingsCount"] == 3
    encrypted = output / "snapshot.pulsebackup"
    assert manifest["size"] == encrypted.stat().st_size
    assert manifest["sha256"] == hashlib.sha256(encrypted.read_bytes()).hexdigest()

    main = tmp_path / "main.swift"
    main.write_text("""
        import Foundation
        let args = CommandLine.arguments
        let recoveryCode = try String(contentsOfFile: args[2], encoding: .utf8)
        let payload = URL(fileURLWithPath: args[3])
        let archive = URL(fileURLWithPath: args[4])
        try CloudBackupEncryption.open(URL(fileURLWithPath: args[1]), to: payload,
                                       sha256: args[5], using: CloudBackupRecoveryKey(code: recoveryCode))
        let expanded = try CloudBackupCompression.expandIfNeeded(payload, to: archive)
        precondition(expanded == archive, "Expected a losslessly compressed cloud payload")
    """)
    verifier = tmp_path / "decrypt"
    subprocess.run(["/usr/bin/swiftc", "-module-cache-path", tmp_path / "modules", *CLOUD_SOURCES, main,
                    "-o", verifier], check=True, capture_output=True)
    payload = tmp_path / "snapshot.compressed"
    plaintext = tmp_path / "snapshot.noopbak"
    subprocess.run([verifier, encrypted, key, payload, plaintext, manifest["sha256"]], check=True, capture_output=True)
    migrated = tmp_path / "migrated.sqlite"
    legacy = tmp_path / "legacy.noopbak"
    with zipfile.ZipFile(plaintext) as archive:
        assert archive.testzip() is None
        assert archive.namelist() == ["noop-backup.sqlite", "settings.json", "pulse-preferences.json", "manifest.json"]
        assert all(entry.compress_type == zipfile.ZIP_STORED for entry in archive.infolist())
        migrated.write_bytes(archive.read("noop-backup.sqlite"))
        assert json.loads(archive.read("settings.json")) == {
            "profile.hrMax": 188,
            "profile.sex": "synthetic-profile",
            "journal.customBehaviors": "Kept behavior",
        }
        cloud_preferences = json.loads(archive.read("pulse-preferences.json"))
        assert cloud_preferences["today.dashboardCards"] is None
        assert {key: value for key, value in cloud_preferences.items() if value is not None} == {
            "appIcon.alt": True,
            "profile.dateOfBirth": (dob - datetime(2001, 1, 1)).total_seconds(),
            "profile.hrMaxOverride": 188,
            "profile.sex": "synthetic-profile",
            "theme.appearance": "light",
            "journal.catalog.v2": base64.b64encode(journal).decode(),
        }
        provenance = json.loads(archive.read("manifest.json"))
        assert provenance["appVersion"] == "12.1.0"
        assert provenance["appBuild"] == "439"
        assert provenance["platform"] == "apple"
        assert provenance["schemaVersion"] == manifest["schemaVersion"]
        with zipfile.ZipFile(legacy, "w", compression=zipfile.ZIP_DEFLATED) as old_archive:
            for name in archive.namelist():
                if name != "pulse-preferences.json":
                    old_archive.writestr(name, archive.read(name))
    with closing(sqlite3.connect(migrated)) as database:
        assert database.execute("PRAGMA quick_check").fetchone() == ("ok",)
        assert database.execute("PRAGMA journal_mode").fetchone() == ("delete",)
        assert database.execute("SELECT * FROM workout").fetchall() == [(1000, 1200)]
        assert database.execute("SELECT * FROM sleepSession").fetchall() == [(2000, 4000)]
        assert database.execute("SELECT * FROM hrSample ORDER BY ts").fetchall() == heart_rate
        assert database.execute("SELECT * FROM rrInterval ORDER BY ts").fetchall() == rr_intervals
        assert database.execute("SELECT COUNT(*) FROM cursors").fetchone() == (0,)
        assert database.execute("SELECT * FROM pairedDevice").fetchone() == ("retained-device", None)
        assert database.execute("SELECT payloadJSON FROM event").fetchone() == ("retained-export-metadata",)

    result, output = run_tool("--archive", legacy)
    assert result.returncode == 0, result.stderr
    restored_manifest = json.loads((output / "manifest.json").read_bytes())
    assert restored_manifest["recordCounts"] == manifest["recordCounts"]
    assert restored_manifest["settingsCount"] == manifest["settingsCount"]
    assert restored_manifest["sha256"] != manifest["sha256"]

    malformed = tmp_path / "malformed.noopbak"
    with zipfile.ZipFile(legacy) as existing, zipfile.ZipFile(malformed, "w") as bad_archive:
        for name in existing.namelist():
            bad_archive.writestr(name, existing.read(name))
        bad_archive.writestr("pulse-preferences.json", '{"profile.dateOfBirth":true}')
    result, output = run_tool("--archive", malformed)
    assert result.returncode == 1
    assert not output.exists()


def test_migration_refuses_a_wrong_database_or_missing_wal(tmp_path, run_tool):
    wrong = tmp_path / "foreign.sqlite"
    with closing(sqlite3.connect(wrong)) as database:
        database.execute("CREATE TABLE unrelated(id INTEGER)")
    result, output = run_tool("--database", wrong)
    assert result.returncode == 1
    assert "-wal" in result.stderr and not output.exists()

    result, output = run_tool("--database", wrong, "--checkpointed")
    assert result.returncode == 1
    assert "schema or SQLite integrity" in result.stderr and not output.exists()

    wrong.with_suffix(".sqlite-wal").write_bytes(b"truncated-wal")
    result, output = run_tool("--database", wrong)
    assert result.returncode == 1
    assert "WAL header" in result.stderr and not output.exists()
