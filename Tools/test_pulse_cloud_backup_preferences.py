"""Run the production cloud preferences codec against isolated defaults."""
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Strand" / "Data" / "CloudBackupCore"
SOURCES = [CORE / "CloudBackupPreferences.swift", CORE / "CloudBackupBackground.swift"]
SWIFTC = shutil.which("swiftc")
HARNESS = r"""
import Foundation

@main
struct Harness {
    static func main() throws {
        let dob = Date(timeIntervalSinceReferenceDate: -314_159_265.125)
        let avatar = Data([10, 20, 30])
        let journal = Data(#"[{"canonical":"Synthetic","kind":"number"}]"#.utf8)
        let sample: [String: Any] = [
            "profile.dateOfBirth": dob, "profile.age": 36, "profile.weightKg": 73.4,
            "theme.appearance": "light", "appIcon.alt": true, "today.sectionOrder": "sleep,recovery",
            "units.system": "metric", "hrv.window": "slowWave", "workoutKeepScreenOn": false,
            "notif.appPrefs": Data("{}".utf8), "behavior.smartAlarmWeekdays": [2, 4, 7],
            "ai.model": "synthetic-model", "journal.catalog.v2": journal,
            "journal.hiddenQuestions": ["Synthetic Hidden"], "profile.avatarImageData": avatar,
            "ai.dataConsent": true, "ai.customAuthHeader": "private",
            "ble.lastConnectedPeripheralUUID": "private", "hkAnchor.v1.test": Data([0]),
            "hkWorkoutExportLedger.v1": Data([0]), "noop.acceptedTermsVersion": "private",
            "profile.stepsCalibrationConfidence": 0.5, "pulse.cloud.activeDevice": "private",
            "alarm.rejectStreak": 2,
        ]
        let name = "PulsePreferencesTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.setPersistentDomain(sample, forName: name)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("source", isDirectory: true)
        let targetDirectory = directory.appendingPathComponent("target", isDirectory: true)
        let source = try CloudBackupPreferences.currentJSON(from: defaults, backgroundsAt: sourceDirectory)
        let direct = try CloudBackupPreferences.encode(from: sample)
        var currentObject = try JSONSerialization.jsonObject(with: source) as! [String: Any]
        currentObject.removeValue(forKey: "background")
        let directObject = try JSONSerialization.jsonObject(with: direct) as! NSDictionary
        precondition(directObject == currentObject as NSDictionary)
        let restored = try CloudBackupPreferences.decode(source)
        precondition(restored.count == 15)
        defaults.removePersistentDomain(forName: name)
        defaults.set("local", forKey: "ai.customAuthHeader")
        defaults.set("stale-cards", forKey: "today.dashboardCards")
        defaults.set("stale-accent", forKey: "accent.color")
        restored.apply(to: defaults)
        precondition(defaults.object(forKey: "profile.dateOfBirth") as? Date == dob)
        precondition(defaults.integer(forKey: "profile.age") == 36)
        precondition(defaults.double(forKey: "profile.weightKg") == 73.4)
        precondition(defaults.bool(forKey: "appIcon.alt"))
        precondition(defaults.object(forKey: "workoutKeepScreenOn") as? Bool == false)
        precondition(defaults.array(forKey: "behavior.smartAlarmWeekdays") as? [Int] == [2, 4, 7])
        precondition(defaults.stringArray(forKey: "journal.hiddenQuestions") == ["Synthetic Hidden"])
        precondition(defaults.data(forKey: "journal.catalog.v2") == journal)
        precondition(defaults.data(forKey: "profile.avatarImageData") == avatar)
        precondition(defaults.string(forKey: "ai.customAuthHeader") == "local")
        precondition(defaults.object(forKey: "ai.dataConsent") == nil)
        precondition(defaults.object(forKey: "today.dashboardCards") == nil)
        precondition(defaults.object(forKey: "accent.color") == nil)
        precondition(defaults.object(forKey: "hkWorkoutExportLedger.v1") == nil)

        let unchanged = try CloudBackupPreferences.currentJSON(from: defaults, backgroundsAt: sourceDirectory)
        precondition(source == unchanged)
        defaults.set("dark", forKey: "theme.appearance")
        let changed = try CloudBackupPreferences.currentJSON(from: defaults, backgroundsAt: sourceDirectory)
        precondition(source != changed)
        let future = try CloudBackupPreferences.decode(Data(#"{"future.setting":"value"}"#.utf8))
        precondition(future.count == 0)
        for invalid in [
            #"{bogus"#, #"[]"#, #"{"profile.dateOfBirth":true}"#, #"{"profile.dateOfBirth":1e99}"#,
            #"{"profile.age":45.1}"#, #"{"appIcon.alt":1}"#,
            #"{"notif.appPrefs":"not base64!"}"#, #"{"behavior.smartAlarmWeekdays":[true]}"#,
            #"{"behavior.smartAlarmWeekdays":[1,1]}"#, #"{"journal.hiddenQuestions":[1]}"#,
            #"{"background":{"enabled":true,"fillMode":"fill","image":"AQID"}}"#,
            #"{"background":{"enabled":1,"fillMode":"tile","image":null}}"#,
        ] {
            do {
                _ = try CloudBackupPreferences.decode(Data(invalid.utf8))
                preconditionFailure("Malformed preferences parsed")
            } catch {}
        }
        do {
            _ = try CloudBackupPreferences.decode(Data(repeating: 32, count: CloudBackupPreferences.maxBytes + 1))
            preconditionFailure("Oversized preferences parsed")
        } catch {}
        do {
            _ = try CloudBackupPreferences.encode(from: ["profile.avatarImageData": Data(count: 512 * 1024 + 1)])
            preconditionFailure("Oversized photo encoded")
        } catch {}

        let originalPhoto = try Data(contentsOf: sourceDirectory.appendingPathComponent("bg-123.jpg"))
        defaults.set("../outside.jpg,fit;bg-112.jpg,fit;bg-123.jpg,tile", forKey: "noop.backgroundRecents")
        defaults.set(true, forKey: "noop.backgroundImageEnabled")
        let withPhoto = try CloudBackupPreferences.currentJSON(from: defaults, backgroundsAt: sourceDirectory)
        precondition(!String(decoding: withPhoto, as: UTF8.self).contains("bg-123.jpg"))
        precondition(!String(decoding: withPhoto, as: UTF8.self).contains("outside.jpg"))
        let photoState = try CloudBackupPreferences.decode(withPhoto)
        let mergedPhoto = try CloudBackupPreferences.encode(from: sample, preservingBackgroundFrom: withPhoto)
        let withPhotoObject = try JSONSerialization.jsonObject(with: withPhoto) as! [String: Any]
        let mergedObject = try JSONSerialization.jsonObject(with: mergedPhoto) as! [String: Any]
        precondition(mergedObject["background"] as? NSDictionary == withPhotoObject["background"] as? NSDictionary)

        let staleURL = targetDirectory.appendingPathComponent("bg-456.jpg")
        let staleImage = Data([1, 2, 3])
        try staleImage.write(to: staleURL)
        defaults.set("bg-456.jpg,fit", forKey: "noop.backgroundRecents")
        defaults.set(false, forKey: "noop.backgroundImageEnabled")
        do {
            _ = try photoState.prepareBackgroundRestore(backgroundsAt: targetDirectory.appendingPathComponent("missing"))
            preconditionFailure("Write unexpectedly succeeded")
        } catch {}
        let prepared = try photoState.prepareBackgroundRestore(backgroundsAt: targetDirectory)!
        precondition(defaults.string(forKey: "noop.backgroundRecents") == "bg-456.jpg,fit")
        precondition(!defaults.bool(forKey: "noop.backgroundImageEnabled"))
        let previous = try Data(contentsOf: staleURL)
        precondition(previous == staleImage)
        let written = try Data(contentsOf: targetDirectory.appendingPathComponent(prepared.filename!))
        precondition(written == originalPhoto)

        photoState.apply(to: defaults)
        prepared.apply(to: defaults)
        precondition(defaults.string(forKey: "noop.backgroundRecents") == "\(prepared.filename!),tile")
        precondition(defaults.bool(forKey: "noop.backgroundImageEnabled"))
        precondition(defaults.bool(forKey: "noop.backgroundImagePresent"))
        let resnapshot = try CloudBackupPreferences.currentJSON(from: defaults, backgroundsAt: targetDirectory)
        precondition(resnapshot == withPhoto)

        let noPhoto = try restored.prepareBackgroundRestore(backgroundsAt: targetDirectory)!
        noPhoto.apply(to: defaults)
        precondition(defaults.string(forKey: "noop.backgroundRecents") == "")
        precondition(!defaults.bool(forKey: "noop.backgroundImageEnabled"))
        precondition(!defaults.bool(forKey: "noop.backgroundImagePresent"))
        let legacy = try CloudBackupPreferences.decode(direct)
        let noLegacyPhoto = try legacy.prepareBackgroundRestore(backgroundsAt: targetDirectory)
        precondition(noLegacyPhoto == nil)

        let oversized = sourceDirectory.appendingPathComponent("bg-999.jpg")
        try Data(count: 3 * 1024 * 1024 + 1).write(to: oversized)
        defaults.set("bg-999.jpg,fill", forKey: "noop.backgroundRecents")
        do {
            _ = try CloudBackupPreferences.currentJSON(from: defaults, backgroundsAt: sourceDirectory)
            preconditionFailure("Oversized background photo encoded")
        } catch CloudBackupBackground.Failure.photoTooLarge {}
    }
}
"""


@unittest.skipUnless(sys.platform == "darwin" and SWIFTC, "Requires Apple Foundation UserDefaults")
def test_production_preferences_codec(tmp_path):
    # Synthetic one-pixel RGB PNG. The app also reads fallback images by their bytes.
    def chunk(name, payload):
        field = name + payload
        return struct.pack(">I", len(payload)) + field + struct.pack(">I", zlib.crc32(field))

    image = (b"\x89PNG\r\n\x1a\n"
             + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
             + chunk(b"IDAT", zlib.compress(b"\0\xff\0\0"))
             + chunk(b"IEND", b""))
    source_dir = tmp_path / "source"
    source_dir.mkdir()
    (source_dir / "bg-123.jpg").write_bytes(image)
    (tmp_path / "target").mkdir()
    main = tmp_path / "Harness.swift"
    binary = tmp_path / "preferences"
    main.write_text(HARNESS, encoding="utf-8")
    subprocess.run(
        [SWIFTC, "-module-cache-path", str(tmp_path / "modules"), *SOURCES, str(main), "-o", str(binary)],
        check=True, timeout=180,
    )
    subprocess.run([binary, tmp_path], check=True, timeout=15)
