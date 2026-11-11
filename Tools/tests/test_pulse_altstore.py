import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import update_pulse_altstore as pulse  # noqa: E402


def _signed_macho(entitlements):
    encoded = plistlib.dumps(entitlements, fmt=plistlib.FMT_XML)
    entitlement_blob = struct.pack(">II", pulse.CSMAGIC_EMBEDDED_ENTITLEMENTS, len(encoded) + 8) + encoded
    superblob_length = 20 + len(entitlement_blob)
    superblob = (
        struct.pack(">III", pulse.CSMAGIC_EMBEDDED_SIGNATURE, superblob_length, 1)
        + struct.pack(">II", pulse.CSSLOT_ENTITLEMENTS, 20)
        + entitlement_blob
    )
    data_offset = 48
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0, 0, 2, 1, 16, 0, 0)
    signature_command = struct.pack("<IIII", pulse.LC_CODE_SIGNATURE, 16, data_offset, len(superblob))
    return header + signature_command + superblob


def _info(bundle_id, executable, group, *, version="3.4.1", build="57", extra=None):
    result = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": executable,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "AppGroupIdentifier": group,
    }
    if extra:
        result.update(extra)
    return result


def make_ipa(
    tmp_path,
    *,
    app_overrides=None,
    widget_overrides=None,
    app_entitlement_overrides=None,
    widget_entitlement_overrides=None,
    omit=(),
    path_name="pulse-test.ipa",
):
    app_root = "Payload/Pulse.app"
    widget_root = f"{app_root}/PlugIns/NOOPWidgets.appex"
    app_info = _info(
        pulse.APP_BUNDLE_ID,
        "Pulse",
        pulse.APP_GROUP_ID,
        extra={
            "MinimumOSVersion": "17.0",
            "NSBluetoothAlwaysUsageDescription": "Reads your strap over Bluetooth on-device.",
            "NSHealthShareUsageDescription": "Reads Apple Health data on-device.",
        },
    )
    widget_info = _info(pulse.WIDGET_BUNDLE_ID, "NOOPWidgets", pulse.APP_GROUP_ID)
    app_info.update(app_overrides or {})
    widget_info.update(widget_overrides or {})
    app_entitlements = {
        "com.apple.security.application-groups": [pulse.APP_GROUP_ID],
        "com.apple.developer.healthkit": True,
    }
    widget_entitlements = {"com.apple.security.application-groups": [pulse.APP_GROUP_ID]}
    app_entitlements.update(app_entitlement_overrides or {})
    widget_entitlements.update(widget_entitlement_overrides or {})

    output = tmp_path / path_name
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        entries = {
            f"{app_root}/Info.plist": plistlib.dumps(app_info),
            f"{app_root}/Pulse": _signed_macho(app_entitlements),
            f"{widget_root}/Info.plist": plistlib.dumps(widget_info),
            f"{widget_root}/NOOPWidgets": _signed_macho(widget_entitlements),
        }
        for name, payload in entries.items():
            if name not in omit:
                archive.writestr(name, payload)
    return output


def test_source_keeps_pulse_identity_and_only_fork_release_urls():
    source = json.loads(pulse.SOURCE_PATH.read_text(encoding="utf-8"))

    assert source["name"] == "Pulse"
    assert source["identifier"] == "dev.pulse.companion.altstore"
    assert source["sourceURL"] == (
        "https://raw.githubusercontent.com/jmlcoliveira/noop/main/altstore-source.json"
    )
    assert source["iconURL"] == pulse.SOURCE_ICON
    assert source["website"] == "https://github.com/jmlcoliveira/noop"
    assert source["tintColor"] == "#D8AF50"
    assert isinstance(source["apps"], list)
    # Empty before the first approved release; publishing a valid release must not break this check.
    for app in source["apps"]:
        assert app["bundleIdentifier"] == pulse.APP_BUNDLE_ID
        assert app["versions"]
        for version in app["versions"]:
            assert version["downloadURL"].startswith(
                "https://github.com/jmlcoliveira/noop/releases/download/pulse-v"
            )
            assert version["size"] > 0
        assert app["downloadURL"] == app["versions"][0]["downloadURL"]


def test_inspect_ipa_reads_metadata_privacy_and_entitlements_without_extraction(tmp_path):
    ipa = make_ipa(tmp_path)

    metadata = pulse.inspect_ipa(ipa)

    assert metadata.version == "3.4.1"
    assert metadata.build_version == "57"
    assert metadata.min_os_version == "17.0"
    assert metadata.app_bundle_id == pulse.APP_BUNDLE_ID
    assert metadata.widget_bundle_id == pulse.WIDGET_BUNDLE_ID
    assert metadata.app_group_id == pulse.APP_GROUP_ID
    assert metadata.size == ipa.stat().st_size
    assert metadata.entitlements == (
        "com.apple.developer.healthkit",
        "com.apple.security.application-groups",
    )
    assert metadata.privacy == {
        "NSBluetoothAlwaysUsageDescription": "Reads your strap over Bluetooth on-device.",
        "NSHealthShareUsageDescription": "Reads Apple Health data on-device.",
    }
    assert not (tmp_path / "Payload").exists()


@pytest.mark.parametrize(
    ("app_overrides", "widget_overrides", "message"),
    [
        ({"CFBundleIdentifier": "com.noopapp.noop"}, None, "unexpected app bundle ID"),
        (None, {"CFBundleIdentifier": "dev.pulse.wrong.widgets"}, "unexpected widget bundle ID"),
        (None, {"CFBundleVersion": "58"}, "build versions do not match"),
        (None, {"CFBundleShortVersionString": "3.4.0"}, "marketing versions do not match"),
        (None, {"AppGroupIdentifier": "group.dev.pulse.wrong"}, "unexpected App Group IDs"),
        (None, {"MinimumOSVersion": "18.0"}, "minimum OS versions do not match"),
    ],
)
def test_inspect_rejects_identity_and_metadata_mismatches(
    tmp_path, app_overrides, widget_overrides, message
):
    ipa = make_ipa(tmp_path, app_overrides=app_overrides, widget_overrides=widget_overrides)

    with pytest.raises(pulse.UpdateError, match=message):
        pulse.inspect_ipa(ipa)


def test_inspect_rejects_missing_widget_or_entitlement_executable(tmp_path):
    widget_info = "Payload/Pulse.app/PlugIns/NOOPWidgets.appex/Info.plist"
    widget_executable = "Payload/Pulse.app/PlugIns/NOOPWidgets.appex/NOOPWidgets"
    missing_widget = make_ipa(tmp_path, omit=(widget_info,))
    with pytest.raises(pulse.UpdateError, match="expected one widget extension"):
        pulse.inspect_ipa(missing_widget)

    missing_binary = make_ipa(tmp_path, omit=(widget_executable,))
    with pytest.raises(pulse.UpdateError, match="missing executable"):
        pulse.inspect_ipa(missing_binary)


def test_inspect_rejects_app_group_missing_from_signed_entitlements(tmp_path):
    ipa = make_ipa(
        tmp_path,
        widget_entitlement_overrides={"com.apple.security.application-groups": []},
    )

    with pytest.raises(pulse.UpdateError, match="widget signed entitlements do not include"):
        pulse.inspect_ipa(ipa)


def test_update_adds_verified_asset_and_deduplicates_versions_and_legacy_fields(tmp_path):
    ipa = make_ipa(tmp_path, path_name="Pulse-ios-unsigned-v3.4.1.ipa")
    source_path = tmp_path / "altstore-source.json"
    source = json.loads(pulse.SOURCE_PATH.read_text(encoding="utf-8"))
    source["apps"] = [{
        "name": "Pulse",
        "bundleIdentifier": pulse.APP_BUNDLE_ID,
        "versions": [
            {"version": "3.4.1", "buildVersion": "56", "downloadURL": "old"},
            {"version": "3.4.1", "buildVersion": "55", "downloadURL": "duplicate"},
            {"version": "3.3.0", "buildVersion": "48", "downloadURL": "history"},
        ],
    }]
    source_path.write_text(json.dumps(source), encoding="utf-8")

    metadata = pulse.update_source(
        source_path,
        ipa,
        tag="pulse-v3.4.1",
        description="Simulator-reviewed release notes.",
        expected_version="3.4.1",
        asset_name=ipa.name,
        date="2026-11-11",
    )

    updated = json.loads(source_path.read_text(encoding="utf-8"))
    assert len(updated["apps"]) == 1
    app = updated["apps"][0]
    assert app["bundleIdentifier"] == pulse.APP_BUNDLE_ID
    assert len([item for item in app["versions"] if item["version"] == "3.4.1"]) == 1
    assert app["versions"][0] == {
        "version": "3.4.1",
        "buildVersion": "57",
        "date": "2026-11-11",
        "localizedDescription": "Simulator-reviewed release notes.",
        "downloadURL": (
            "https://github.com/jmlcoliveira/noop/releases/download/"
            "pulse-v3.4.1/Pulse-ios-unsigned-v3.4.1.ipa"
        ),
        "size": ipa.stat().st_size,
        "minOSVersion": "17.0",
    }
    assert any(item["version"] == "3.3.0" for item in app["versions"])
    assert app["appPermissions"]["privacy"] == metadata.privacy
    assert app["appPermissions"]["entitlements"] == list(metadata.entitlements)
    for key, value in {
        "version": "3.4.1",
        "buildVersion": "57",
        "versionDate": "2026-11-11",
        "versionDescription": "Simulator-reviewed release notes.",
        "downloadURL": app["versions"][0]["downloadURL"],
        "size": ipa.stat().st_size,
        "minOSVersion": "17.0",
    }.items():
        assert app[key] == value


def test_update_rejects_requested_version_mismatch_without_mutating_source(tmp_path):
    ipa = make_ipa(tmp_path)
    source_path = tmp_path / "altstore-source.json"
    original = pulse.SOURCE_PATH.read_text(encoding="utf-8")
    source_path.write_text(original, encoding="utf-8")

    with pytest.raises(pulse.UpdateError, match="version mismatch"):
        pulse.update_source(source_path, ipa, expected_version="3.4.0")

    assert source_path.read_text(encoding="utf-8") == original


def test_update_rejects_non_pulse_release_tags(tmp_path):
    ipa = make_ipa(tmp_path)
    source_path = tmp_path / "altstore-source.json"
    original = pulse.SOURCE_PATH.read_text(encoding="utf-8")
    source_path.write_text(original, encoding="utf-8")

    with pytest.raises(pulse.UpdateError, match="release tag mismatch"):
        pulse.update_source(source_path, ipa, tag="pulse-v3.4.2")
    with pytest.raises(pulse.UpdateError, match="release asset name mismatch"):
        pulse.update_source(source_path, ipa, asset_name="NOOP-ios-unsigned-v3.4.1.ipa")

    assert source_path.read_text(encoding="utf-8") == original
