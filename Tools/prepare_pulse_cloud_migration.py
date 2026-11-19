#!/usr/bin/env python3
"""Prepare a private, encrypted Pulse migration from an offline copy on macOS."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = ROOT / "build" / "cloud-migration"
PRODUCTS = ROOT / "build" / "macOS" / "Build" / "Products" / "Debug"
SWIFT = ROOT / "Tools" / "prepare_pulse_cloud_migration.swift"
CORE = ROOT / "Strand" / "Data" / "CloudBackupCore"
CLOUD_SOURCES = [
    CORE / "CloudBackupEncryption.swift",
    CORE / "CloudBackupCompression.swift",
    CORE / "CloudBackupPreferences.swift",
    CORE / "CloudBackupBackground.swift",
]
STORE = ROOT / "Packages" / "WhoopStore" / "Sources" / "WhoopStore"
CSQLITE = ROOT / "build" / "SourcePackages" / "checkouts" / "GRDB.swift" / "Sources" / "CSQLite"
DEPENDENCIES = ("GRDB", "ZIPFoundation", "WhoopProtocol", "OuraProtocol")


class MigrationError(Exception):
    pass


def metadata(path: Path) -> tuple[int, int, int, int]:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise MigrationError("Inputs must be regular, locally copied files.")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def stage_copy(inputs: dict[Path, Path]) -> None:
    before = {source: metadata(source) for source in inputs}
    for source, destination in inputs.items():
        shutil.copyfile(source, destination)
    if before != {source: metadata(source) for source in inputs}:
        raise MigrationError("A source file changed during copying. Recopy while Pulse is closed.")


def toolchain(products: Path) -> Path:
    if sys.platform != "darwin":
        raise MigrationError("Pulse migration requires macOS and Apple CryptoKit.")
    env = os.environ.copy()
    xcode = Path("/Applications/Xcode.app/Contents/Developer")
    if xcode.is_dir():
        env.setdefault("DEVELOPER_DIR", str(xcode))
    swiftc = ["/usr/bin/xcrun", "--sdk", "macosx", "swiftc"]
    objects = [products / f"{name}.o" for name in DEPENDENCIES]
    architecture = platform.machine()
    modules = [products / f"{name}.swiftmodule" / f"{architecture}-apple-macos.swiftmodule" for name in DEPENDENCIES]
    if not all(path.is_file() for path in objects + modules):
        raise MigrationError("Pass --macos-build-products with the dependency objects and Swift modules from a macOS Strand build.")
    if not (CSQLITE / "module.modulemap").is_file():
        raise MigrationError("The local GRDB checkout is missing from build/SourcePackages/checkouts.")
    store_sources = sorted(STORE.glob("*.swift"))
    compiler = subprocess.check_output([*swiftc, "--version"], env=env)
    digest = hashlib.sha256(compiler)
    digest.update(str(products).encode())
    for path in [*store_sources, SWIFT, *CLOUD_SOURCES, Path(__file__), CSQLITE / "module.modulemap"]:
        digest.update(path.read_bytes())
    for path in objects + modules:
        digest.update(str(metadata(path)).encode())
    executable = OUTPUT_ROOT / (".tool-" + digest.hexdigest()[:20])
    if executable.is_file():
        return executable

    with tempfile.TemporaryDirectory(prefix=".compiler-", dir=OUTPUT_ROOT) as directory:
        work = Path(directory)
        flags = ["-target", f"{architecture}-apple-macosx13.0", "-I", str(products), "-I", str(CSQLITE),
                 "-module-cache-path", str(work / "modules")]
        store_library = work / "libWhoopStore.a"
        subprocess.run([
            *swiftc, *flags, "-emit-library", "-emit-module", "-static", "-module-name", "WhoopStore",
            "-emit-module-path", str(work / "WhoopStore.swiftmodule"), *store_sources, "-o", store_library,
        ], env=env, check=True)
        binary = work / "prepare"
        subprocess.run([
            *swiftc, "-I", work, *flags, *CLOUD_SOURCES, SWIFT, store_library, *objects, "-o", binary,
        ], env=env, check=True)
        binary.replace(executable)
    return executable


def capture_date(value: str) -> str:
    try:
        parsed = datetime.fromisoformat(value)
        if parsed.tzinfo is None:
            raise ValueError
        return parsed.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    except ValueError as error:
        raise argparse.ArgumentTypeError("Use an ISO 8601 capture time with a time zone.") from error


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--database", type=Path, help="Copy of the Pulse SQLite database with its matching -wal beside it.")
    source.add_argument("--archive", type=Path, help="Copy of an existing .noopbak export.")
    parser.add_argument("--checkpointed", action="store_true", help="Confirm a database-only copy is fully checkpointed.")
    parser.add_argument("--preferences", type=Path, help="Copied Pulse UserDefaults plist for whitelisted cloud backup preferences.")
    parser.add_argument("--app-version", required=True, help="CFBundleShortVersionString of the source app.")
    parser.add_argument("--app-build", required=True, help="CFBundleVersion of the source app.")
    parser.add_argument("--captured-at", required=True, type=capture_date, help="When the source was copied or exported.")
    parser.add_argument("--output-name", required=True, help="New private subdirectory of build/cloud-migration.")
    parser.add_argument("--macos-build-products", type=Path, default=PRODUCTS,
                        help="macOS Strand build products used to link cached dependencies.")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", args.output_name):
        parser.error("Use a simple output name with letters, digits, underscores or hyphens.")
    if not all(re.fullmatch(r"\d+(?:\.\d+)*", value) for value in (args.app_version, args.app_build)):
        parser.error("Use the numeric source app version and build.")
    if args.archive and args.checkpointed:
        parser.error("Use --checkpointed only with --database.")
    return args


def prepare(args: argparse.Namespace) -> Path:
    OUTPUT_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    if OUTPUT_ROOT.resolve() != OUTPUT_ROOT or OUTPUT_ROOT.stat().st_uid != os.getuid():
        raise MigrationError("The migration output directory must be a local directory owned by you.")
    OUTPUT_ROOT.chmod(0o700)
    output = OUTPUT_ROOT / args.output_name
    if os.path.lexists(output):
        raise MigrationError("This output name already exists. Choose a new output name.")

    with tempfile.TemporaryDirectory(prefix=".work-", dir=OUTPUT_ROOT) as directory:
        work = Path(directory)
        if args.database:
            mode = "database"
            staged = work / "source.sqlite"
            sources = {args.database: staged}
            wal = args.database.with_name(args.database.name + "-wal")
            if os.path.lexists(wal):
                sources[wal] = work / "source.sqlite-wal"
            elif not args.checkpointed:
                raise MigrationError("Copy the matching SQLite -wal alongside the database, or confirm --checkpointed.")
            if os.path.lexists(args.database.with_name(args.database.name + "-journal")):
                raise MigrationError("The source has a SQLite rollback journal. Recopy a settled database.")
        else:
            mode = "archive"
            staged = work / "source.noopbak"
            sources = {args.archive: staged}
        preferences = work / "source.plist" if args.preferences else None
        if preferences:
            if args.preferences in sources:
                raise MigrationError("The database, WAL and preferences must be distinct files.")
            sources[args.preferences] = preferences
        stage_copy(sources)
        if mode == "database" and wal in sources:
            with sources[wal].open("rb") as handle:
                header = handle.read(32)
            if header and (len(header) != 32 or header[:4] not in (b"7\x7f\x06\x82", b"7\x7f\x06\x83")):
                raise MigrationError("The copied SQLite WAL header is incomplete or invalid.")
        executable = toolchain(args.macos_build_products.resolve())
        subprocess.run([
            executable, mode, staged, work, preferences or "", args.app_version, args.app_build, args.captured_at,
        ], check=True)
        (work / "output").rename(output)
    return output


def main() -> int:
    args = parse_args()
    os.umask(0o077)
    try:
        output = prepare(args)
        summary = json.loads((output / "manifest.json").read_bytes())
        print(json.dumps({**summary, "outputDirectory": str(output)}, indent=2, sort_keys=True))
    except MigrationError as error:
        print(error, file=sys.stderr)
        return 1
    except subprocess.CalledProcessError:
        print("Pulse migration failed.", file=sys.stderr)
        return 1
    except OSError:
        print("Could not read the copied inputs or write the private migration files.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
