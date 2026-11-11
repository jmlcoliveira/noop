#!/usr/bin/env python3
"""Validate a Pulse sideload IPA and prepare its AltStore source entry.

This tool only edits the local JSON source. Release assets must already exist on
the Pulse fork before ``update`` is used; publication is handled separately.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import struct
import sys
import zipfile
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = REPO_ROOT / "altstore-source.json"
APP_BUNDLE_ID = "dev.pulse.companion.noop"
WIDGET_BUNDLE_ID = "dev.pulse.companion.noop.widgets"
APP_GROUP_ID = "group.dev.pulse.companion.noop.staging"
SOURCE_IDENTIFIER = "dev.pulse.companion.altstore"
GITHUB_OWNER = "jmlcoliveira"
GITHUB_REPO = "noop"
SOURCE_URL = "https://raw.githubusercontent.com/jmlcoliveira/noop/main/altstore-source.json"
SOURCE_WEBSITE = "https://github.com/jmlcoliveira/noop"
SOURCE_ICON = (
    "https://raw.githubusercontent.com/jmlcoliveira/noop/main/"
    "StrandiOS/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
)
SOURCE_TINT = "#D8AF50"
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSSLOT_ENTITLEMENTS = 5


class UpdateError(ValueError):
    """Raised when an IPA or source cannot safely produce a Pulse entry."""


@dataclass(frozen=True)
class IPAMetadata:
    version: str
    build_version: str
    min_os_version: str
    app_bundle_id: str
    widget_bundle_id: str
    app_group_id: str
    size: int
    entitlements: tuple[str, ...]
    privacy: dict[str, str]


def _required_string(plist: dict[str, Any], key: str, context: str) -> str:
    value = plist.get(key)
    if not isinstance(value, (str, int)) or not str(value).strip():
        raise UpdateError(f"{context} is missing {key}")
    return str(value).strip()


def _read_plist(archive: zipfile.ZipFile, member: str) -> dict[str, Any]:
    try:
        value = plistlib.loads(archive.read(member))
    except KeyError as exc:
        raise UpdateError(f"IPA is missing {member}") from exc
    except (zipfile.BadZipFile, OSError, RuntimeError) as exc:
        raise UpdateError(f"cannot read IPA member {member}: {exc}") from exc
    except (plistlib.InvalidFileException, ValueError) as exc:
        raise UpdateError(f"IPA contains an invalid plist at {member}") from exc
    if not isinstance(value, dict):
        raise UpdateError(f"IPA plist at {member} is not a dictionary")
    return value


def _macho_slices(data: bytes, context: str) -> list[bytes]:
    """Return thin Mach-O slices from an executable, including fat executables."""
    if len(data) < 4:
        raise UpdateError(f"{context} is not a Mach-O executable")
    magic_be = struct.unpack_from(">I", data)[0]
    if magic_be in (0xCAFEBABE, 0xCAFEBABF, 0xBEBAFECA, 0xBFBAFECA):
        endian = ">" if magic_be in (0xCAFEBABE, 0xCAFEBABF) else "<"
        is_64 = magic_be in (0xCAFEBABF, 0xBFBAFECA)
        if len(data) < 8:
            raise UpdateError(f"{context} has a truncated universal Mach-O header")
        count = struct.unpack_from(f"{endian}I", data, 4)[0]
        stride = 32 if is_64 else 20
        if count > 64 or 8 + count * stride > len(data):
            raise UpdateError(f"{context} has an invalid universal Mach-O header")
        slices: list[bytes] = []
        for index in range(count):
            offset = 8 + index * stride
            if is_64:
                slice_offset, slice_size = struct.unpack_from(f"{endian}QQ", data, offset + 8)
            else:
                slice_offset, slice_size = struct.unpack_from(f"{endian}II", data, offset + 8)
            if slice_offset + slice_size > len(data):
                raise UpdateError(f"{context} has an out-of-range universal Mach-O slice")
            slices.append(data[slice_offset : slice_offset + slice_size])
        if not slices:
            raise UpdateError(f"{context} has no universal Mach-O slices")
        return slices

    return [data]


def _slice_entitlements(data: bytes, context: str) -> dict[str, Any]:
    if len(data) < 28:
        raise UpdateError(f"{context} has a truncated Mach-O header")
    magic_le = struct.unpack_from("<I", data)[0]
    magic_be = struct.unpack_from(">I", data)[0]
    if magic_le == 0xFEEDFACF:
        endian, header_size = "<", 32
    elif magic_be == 0xFEEDFACF:
        endian, header_size = ">", 32
    elif magic_le == 0xFEEDFACE:
        endian, header_size = "<", 28
    elif magic_be == 0xFEEDFACE:
        endian, header_size = ">", 28
    else:
        raise UpdateError(f"{context} is not a supported Mach-O executable")

    ncmds = struct.unpack_from(f"{endian}I", data, 16)[0]
    if ncmds > 100_000:
        raise UpdateError(f"{context} has an invalid Mach-O load-command count")
    cursor = header_size
    signature: tuple[int, int] | None = None
    for _ in range(ncmds):
        if cursor + 8 > len(data):
            raise UpdateError(f"{context} has a truncated Mach-O load command")
        command, command_size = struct.unpack_from(f"{endian}II", data, cursor)
        if command_size < 8 or cursor + command_size > len(data):
            raise UpdateError(f"{context} has an invalid Mach-O load command")
        if command == LC_CODE_SIGNATURE:
            if command_size < 16:
                raise UpdateError(f"{context} has an invalid code-signature command")
            signature = struct.unpack_from(f"{endian}II", data, cursor + 8)
            break
        cursor += command_size
    if signature is None:
        raise UpdateError(f"{context} has no embedded code signature")

    offset, size = signature
    if size < 12 or offset + size > len(data):
        raise UpdateError(f"{context} has an out-of-range code signature")
    blob = data[offset : offset + size]
    magic, blob_length, count = struct.unpack_from(">III", blob)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE or blob_length > len(blob) or count > 4096:
        raise UpdateError(f"{context} has an invalid code-signature superblob")
    if 12 + count * 8 > blob_length:
        raise UpdateError(f"{context} has a truncated code-signature index")

    for index in range(count):
        slot, item_offset = struct.unpack_from(">II", blob, 12 + index * 8)
        if slot != CSSLOT_ENTITLEMENTS:
            continue
        if item_offset + 8 > blob_length:
            raise UpdateError(f"{context} has an out-of-range entitlements blob")
        entitlements_magic, entitlements_length = struct.unpack_from(">II", blob, item_offset)
        if entitlements_magic != CSMAGIC_EMBEDDED_ENTITLEMENTS:
            raise UpdateError(f"{context} has an unsupported entitlements format")
        if entitlements_length < 8 or item_offset + entitlements_length > blob_length:
            raise UpdateError(f"{context} has a truncated entitlements blob")
        try:
            value = plistlib.loads(blob[item_offset + 8 : item_offset + entitlements_length])
        except (plistlib.InvalidFileException, ValueError) as exc:
            raise UpdateError(f"{context} has invalid signed entitlements") from exc
        if not isinstance(value, dict):
            raise UpdateError(f"{context} entitlements are not a dictionary")
        return value
    raise UpdateError(f"{context} has no signed entitlements")


def _read_entitlements(archive: zipfile.ZipFile, member: str) -> dict[str, Any]:
    try:
        executable = archive.read(member)
    except KeyError as exc:
        raise UpdateError(f"IPA is missing executable {member}") from exc
    except (zipfile.BadZipFile, OSError, RuntimeError) as exc:
        raise UpdateError(f"cannot read IPA executable {member}: {exc}") from exc
    slices = _macho_slices(executable, member)
    entitlements = [_slice_entitlements(item, member) for item in slices]
    first = entitlements[0]
    if any(candidate != first for candidate in entitlements[1:]):
        raise UpdateError(f"{member} has different entitlements across architectures")
    return first


def inspect_ipa(ipa_path: Path) -> IPAMetadata:
    """Inspect the app and widget directly from the IPA ZIP; never extracts files."""
    if not ipa_path.is_file():
        raise UpdateError(f"IPA not found: {ipa_path}")
    if ipa_path.stat().st_size <= 0:
        raise UpdateError(f"IPA is empty: {ipa_path}")
    try:
        archive = zipfile.ZipFile(ipa_path)
    except (OSError, zipfile.BadZipFile) as exc:
        raise UpdateError(f"not a valid IPA ZIP: {ipa_path}") from exc

    with archive:
        members = set(archive.namelist())
        app_infos = sorted(
            member for member in members
            if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", member)
        )
        if len(app_infos) != 1:
            raise UpdateError(f"expected one Payload/*.app/Info.plist, found {len(app_infos)}")
        app_info_path = app_infos[0]
        app_root = app_info_path.rsplit("/", 1)[0]
        app_info = _read_plist(archive, app_info_path)

        widget_infos = sorted(
            member for member in members
            if member.startswith(f"{app_root}/PlugIns/") and member.endswith(".appex/Info.plist")
        )
        if len(widget_infos) != 1:
            raise UpdateError(f"expected one widget extension Info.plist, found {len(widget_infos)}")
        widget_info_path = widget_infos[0]
        widget_root = widget_info_path.rsplit("/", 1)[0]
        widget_info = _read_plist(archive, widget_info_path)

        app_bundle_id = _required_string(app_info, "CFBundleIdentifier", "app Info.plist")
        widget_bundle_id = _required_string(widget_info, "CFBundleIdentifier", "widget Info.plist")
        if app_bundle_id != APP_BUNDLE_ID:
            raise UpdateError(f"unexpected app bundle ID: {app_bundle_id}")
        if widget_bundle_id != WIDGET_BUNDLE_ID:
            raise UpdateError(f"unexpected widget bundle ID: {widget_bundle_id}")

        version = _required_string(app_info, "CFBundleShortVersionString", "app Info.plist")
        build_version = _required_string(app_info, "CFBundleVersion", "app Info.plist")
        if _required_string(widget_info, "CFBundleShortVersionString", "widget Info.plist") != version:
            raise UpdateError("app and widget marketing versions do not match")
        if _required_string(widget_info, "CFBundleVersion", "widget Info.plist") != build_version:
            raise UpdateError("app and widget build versions do not match")

        app_group = _required_string(app_info, "AppGroupIdentifier", "app Info.plist")
        widget_group = _required_string(widget_info, "AppGroupIdentifier", "widget Info.plist")
        if app_group != APP_GROUP_ID or widget_group != APP_GROUP_ID:
            raise UpdateError(f"unexpected App Group IDs: app={app_group}, widget={widget_group}")
        if app_group != widget_group:
            raise UpdateError("app and widget App Group IDs do not match")

        min_os_version = _required_string(app_info, "MinimumOSVersion", "app Info.plist")
        widget_min_os = widget_info.get("MinimumOSVersion")
        if widget_min_os is not None and str(widget_min_os) != min_os_version:
            raise UpdateError("app and widget minimum OS versions do not match")
        app_executable = _required_string(app_info, "CFBundleExecutable", "app Info.plist")
        widget_executable = _required_string(widget_info, "CFBundleExecutable", "widget Info.plist")
        for context, executable in (("app", app_executable), ("widget", widget_executable)):
            if Path(executable).name != executable or "/" in executable or "\\" in executable:
                raise UpdateError(f"{context} executable name is invalid")
        app_entitlements = _read_entitlements(archive, f"{app_root}/{app_executable}")
        widget_entitlements = _read_entitlements(archive, f"{widget_root}/{widget_executable}")

        for context, entitlements in (("app", app_entitlements), ("widget", widget_entitlements)):
            groups = entitlements.get("com.apple.security.application-groups")
            if not isinstance(groups, list) or APP_GROUP_ID not in groups:
                raise UpdateError(f"{context} signed entitlements do not include {APP_GROUP_ID}")

        privacy: dict[str, str] = {}
        for plist in (app_info, widget_info):
            for key, value in plist.items():
                if key.endswith("UsageDescription") and isinstance(value, str) and value:
                    if key in privacy and privacy[key] != value:
                        raise UpdateError(f"app and widget privacy descriptions differ for {key}")
                    privacy[key] = value
        if not privacy:
            raise UpdateError("app Info.plist has no UsageDescription privacy strings")

        entitlement_keys = set(app_entitlements) | set(widget_entitlements)
        entitlement_keys.difference_update({"application-identifier", "com.apple.developer.team-identifier"})

    return IPAMetadata(
        version=version,
        build_version=build_version,
        min_os_version=min_os_version,
        app_bundle_id=app_bundle_id,
        widget_bundle_id=widget_bundle_id,
        app_group_id=app_group,
        size=ipa_path.stat().st_size,
        entitlements=tuple(sorted(entitlement_keys)),
        privacy=dict(sorted(privacy.items())),
    )


def _description(version: str, supplied: str | None) -> str:
    value = supplied.strip() if supplied else ""
    return value or f"Pulse {version}. See the release notes for what changed."


def _release_url(tag: str, asset_name: str) -> str:
    if not re.fullmatch(r"pulse-v[0-9A-Za-z.+-]+", tag):
        raise UpdateError("release tag must start with pulse-v")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.ipa", asset_name):
        raise UpdateError("asset name must be a plain .ipa filename")
    return f"https://github.com/{GITHUB_OWNER}/{GITHUB_REPO}/releases/download/{tag}/{asset_name}"


def _base_app() -> dict[str, Any]:
    return {
        "name": "Pulse",
        "bundleIdentifier": APP_BUNDLE_ID,
        "developerName": "Pulse",
        "subtitle": "An offline-first companion for your WHOOP strap.",
        "localizedDescription": (
            "Pulse is an independent iPhone companion for a WHOOP strap you own. "
            "Strap metrics are computed and stored on-device, without a Pulse account or "
            "Pulse-operated cloud service. Optional integrations may contact services you "
            "configure. Pulse is not affiliated with WHOOP. "
            "Source: https://github.com/jmlcoliveira/noop"
        ),
        "iconURL": SOURCE_ICON,
        "tintColor": SOURCE_TINT,
        "category": "lifestyle",
        "screenshots": [],
        "versions": [],
    }


def update_source(
    source_path: Path,
    ipa_path: Path,
    *,
    tag: str | None = None,
    description: str | None = None,
    expected_version: str | None = None,
    asset_name: str | None = None,
    date: str | None = None,
) -> IPAMetadata:
    """Prepend validated IPA metadata to a local source manifest."""
    metadata = inspect_ipa(ipa_path)
    if expected_version and expected_version != metadata.version:
        raise UpdateError(
            f"version mismatch: requested {expected_version}, IPA contains {metadata.version}"
        )
    tag = tag or f"pulse-v{metadata.version}"
    expected_tag = f"pulse-v{metadata.version}"
    if tag != expected_tag:
        raise UpdateError(f"release tag mismatch: expected {expected_tag}, received {tag}")
    expected_filename = f"Pulse-ios-unsigned-v{metadata.version}.ipa"
    filename = asset_name or ipa_path.name
    if filename != expected_filename:
        raise UpdateError(f"release asset name mismatch: expected {expected_filename}, received {filename}")
    url = _release_url(tag, filename)
    release_date = date or datetime.now(timezone.utc).date().isoformat()
    try:
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", release_date):
            raise ValueError("date format")
        datetime.strptime(release_date, "%Y-%m-%d")
    except ValueError as exc:
        raise UpdateError("release date must use YYYY-MM-DD") from exc
    localized_description = _description(metadata.version, description)

    try:
        source = json.loads(source_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise UpdateError(f"cannot read AltStore source {source_path}: {exc}") from exc
    if (not isinstance(source, dict)
            or source.get("identifier") != SOURCE_IDENTIFIER
            or source.get("sourceURL") != SOURCE_URL
            or source.get("website") != SOURCE_WEBSITE):
        raise UpdateError("source manifest is not the Pulse AltStore source")

    existing_apps = source.get("apps", [])
    if not isinstance(existing_apps, list):
        raise UpdateError("source apps must be an array")
    existing_app = next(
        (item for item in existing_apps
         if isinstance(item, dict) and item.get("bundleIdentifier") == APP_BUNDLE_ID),
        None,
    )
    app = _base_app()
    if existing_app:
        # Preserve app-curated fields such as screenshots while refreshing identity and metadata.
        app.update(existing_app)
        app.update(_base_app())
        app["screenshots"] = existing_app.get("screenshots", [])
        app["versions"] = existing_app.get("versions", [])

    entry = {
        "version": metadata.version,
        "buildVersion": metadata.build_version,
        "date": release_date,
        "localizedDescription": localized_description,
        "downloadURL": url,
        "size": metadata.size,
        "minOSVersion": metadata.min_os_version,
    }
    versions = app.get("versions", [])
    if not isinstance(versions, list):
        raise UpdateError("app versions must be an array")
    if any(not isinstance(item, dict) for item in versions):
        raise UpdateError("each existing app version must be an object")
    app["versions"] = [entry] + [
        item for item in versions
        if item.get("version") != metadata.version and item.get("buildVersion") != metadata.build_version
    ]

    app["appPermissions"] = {
        "entitlements": list(metadata.entitlements),
        "privacy": metadata.privacy,
    }
    # Legacy top-level fields remain for older AltStore/SideStore clients.
    app.update({
        "version": metadata.version,
        "buildVersion": metadata.build_version,
        "versionDate": release_date,
        "versionDescription": localized_description,
        "downloadURL": url,
        "size": metadata.size,
        "minOSVersion": metadata.min_os_version,
    })
    source["apps"] = [app]

    temp = source_path.with_suffix(source_path.suffix + ".tmp")
    try:
        temp.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temp.replace(source_path)
    except OSError:
        temp.unlink(missing_ok=True)
        raise
    return metadata


def _print_metadata(metadata: IPAMetadata) -> None:
    print(json.dumps(asdict(metadata), indent=2, ensure_ascii=False))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect_parser = commands.add_parser("inspect", help="validate and print IPA metadata")
    inspect_parser.add_argument("ipa", type=Path)
    update_parser = commands.add_parser("update", help="update a local source after a release asset exists")
    update_parser.add_argument("--ipa", type=Path, required=True)
    update_parser.add_argument("--source", type=Path, default=SOURCE_PATH)
    update_parser.add_argument("--tag")
    update_parser.add_argument("--asset-name")
    update_parser.add_argument("--version", dest="expected_version")
    update_parser.add_argument("--description")
    update_parser.add_argument("--date")
    args = parser.parse_args(argv)

    try:
        if args.command == "inspect":
            metadata = inspect_ipa(args.ipa)
            _print_metadata(metadata)
        else:
            metadata = update_source(
                args.source,
                args.ipa,
                tag=args.tag,
                description=args.description,
                expected_version=args.expected_version,
                asset_name=args.asset_name,
                date=args.date,
            )
            print(f"Updated {args.source} for Pulse {metadata.version} ({metadata.build_version}).")
            print("This changed the local source only; it did not upload or publish anything.")
    except UpdateError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
