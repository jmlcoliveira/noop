import CoreFoundation
import Foundation

/// The iPhone cloud archive's private settings entry. A key's declared type is part of
/// the format. Dates are finite seconds from the Foundation reference date; blobs are base64.
struct CloudBackupPreferences {
    static let entryName = "pulse-preferences.json"
    static let maxBytes = 6 * 1024 * 1024
    private static let maxStringBytes = 65_536

    private enum Kind {
        case bool, int, double, string, date, strings, weekdays, data(Int)
    }

    private static let keys: [String: Kind] = [
        // Profile and scoring
        "profile.dateOfBirth": .date, "profile.age": .int, "profile.sex": .string,
        "profile.weightKg": .double, "profile.heightCm": .double, "profile.waistCm": .double,
        "profile.hrMaxOverride": .int, "profile.hrZoneThresholds": .string,
        "profile.stepTicksPerStep": .double, "profile.stepsCalibrationManual": .bool,
        "profile.stepsManualCoefficient": .double, "profile.avatarImageData": .data(512 * 1024),
        "noopBanisterEffort": .bool, "noopExperimentalSleepV2": .bool, "noopHrvReadiness": .bool,
        "noopMotionAwareWake": .bool, "noopStressPersonalBaseline": .bool,
        "units.system": .string, "units.distance": .string, "units.temperature": .string,
        "units.skinTempDisplay": .string, "effort.scale": .string, "hrv.window": .string,
        "noop.dayCycleMode": .string, "noopCycleAwareness": .bool, "noopCycleAwarenessHidden": .bool,
        // Appearance and layouts
        "theme.appearance": .string, "clockFormatPreference": .string, "accent.color": .string, "accent.customHex": .string,
        "chart.style": .string, "sleep.chart.style": .string, "trend.chart.style": .string,
        "noop.appLanguage": .string, "appIcon.alt": .bool, "noop.quietMotion": .bool,
        "noop.showDayCycleBackground": .bool, "noop.skyBehindCards": .bool, "noop.cardOpacityPercent": .int,
        "noop.bottomBarAutoHide": .bool, "noop.liquidTodayEnabled": .bool,
        "today.dashboardCards": .string, "today.hostedCards": .string,
        "today.keyMetrics": .string, "today.keyMetricsDetailed": .bool, "today.keyMetricsWindowDays": .int,
        "today.sectionOrder": .string, "today.hiddenSections": .string,
        "sleep.sectionOrder": .string, "sleep.hiddenSections": .string,
        "more.expandedSections": .string, "settingsAdvancedOpen": .bool,
        "compare.rangeRaw": .string, "compare.selectedIds": .string,
        // Wrist notification and haptic preferences. OS permissions live outside this snapshot.
        "notif.masterEnabled": .bool, "notif.onlyWhenWorn": .bool, "notif.quietHoursEnabled": .bool,
        "notif.quietStartMinutes": .int, "notif.quietEndMinutes": .int, "notif.appPrefs": .data(64 * 1024),
        "behavior.smartAlarmEnabled": .bool, "behavior.smartAlarmMinutes": .int,
        "behavior.smartAlarmWeekdays": .weekdays, "behavior.illnessWatch": .bool,
        "behavior.doubleTapAction": .string, "behavior.doubleTapShortcut": .string,
        "behavior.wristOffShortcut": .string, "behavior.wristOnShortcut": .string,
        "behavior.autoLockOnWristOff": .bool, "behavior.zoneCoaching": .bool,
        "behavior.batteryAlerts": .bool, "behavior.batteryPredictiveAlerts": .bool,
        "behavior.strainTargetNudge": .bool,
        "inactivity.enabled": .bool, "inactivity.thresholdMinutes": .int, "inactivity.reNudgeMinutes": .int,
        "inactivity.buzzLoops": .int, "inactivity.activeHoursEnabled": .bool,
        "inactivity.activeStartMinutes": .int, "inactivity.activeEndMinutes": .int,
        "biofeedback.stressCheckIn": .bool, "biofeedback.stressAutoNudge": .bool,
        "biofeedback.stressQuietHours": .bool, "biofeedback.stressUseResonancePace": .bool,
        "haptics.breathing": .bool, "haptics.intervals": .bool, "haptics.liftRest": .bool,
        "haptics.liveSession": .bool, "haptics.workout": .bool, "breathe.audioCues": .bool,
        // Settings that control workouts and on-device signal collection
        "workoutKeepScreenOn": .bool, "workout.recentSports": .string, "noopAutoDetectWorkouts": .bool,
        "syncKeepScreenOn": .bool, "noop.liveSessionsBeta": .bool, "liveActivity.enabled": .bool,
        "liveActivity.sync.enabled": .bool, "liveActivity.lift.enabled": .bool,
        "noopContinuousHrv": .bool, "noopContinuousHrvOvernightOnly": .bool,
        "noopSpo2CandidateDisplay": .bool, "noopLowRefresh": .bool, "noopPowerSaving": .bool,
        "noopPowerSavingBatteryPct": .int, "updates.autoCheck": .bool, "noopPowerSavingPauseHrvDisabled": .bool,
        // Coach and journal. Provider connection configuration and consent remain local.
        "noop.coachEnabled": .bool, "ai.provider": .string, "ai.model": .string,
        "ai.includeOnDeviceSignals": .bool, "ai.multimodalChartEnabled": .bool, "ai.systemPrompt": .string,
        "journal.catalog.v2": .data(256 * 1024), "journal.customQuestions": .strings,
        "journal.hiddenQuestions": .strings, "journal.collapsedGroups": .string, "noopJournalReminder": .bool,
        "noop.hydrationTracking": .bool, "noop.hydrationCustomSizeML": .int,
        "noop.caffeine.cutoffNudge": .bool, "noop.caffeine.bedtimeMinutes": .int,
        "noop.experiment.behaviour": .string, "noop.experiment.startedDay": .string, "noop.experiment.outcome": .string,
        "noop.experiment.durationDays": .int, "noop.experiment.baselineDays": .int,
    ]

    private let values: [String: Any]
    private let background: CloudBackupBackground?
    var count: Int { values.values.filter { !($0 is NSNull) }.count }

    static func currentJSON(from defaults: UserDefaults = .standard, backgroundsAt directory: URL? = nil) throws -> Data {
        let background = try CloudBackupBackground.snapshot(from: defaults, backgroundsAt: directory)
        return try encode(background: background) { defaults.object(forKey: $0) }
    }

    static func encode(from source: [String: Any], preservingBackgroundFrom previous: Data? = nil) throws -> Data {
        let background = try previous.flatMap { try decode($0).background }
        return try encode(background: background) { source[$0] }
    }

    private static func encode(background: CloudBackupBackground? = nil, get: (String) -> Any?) throws -> Data {
        var values: [String: Any] = [:]
        for (key, kind) in keys {
            guard let raw = get(key) else {
                // Explicitly reset preferences the source left at their app default.
                values[key] = NSNull()
                continue
            }
            guard let value = convert(raw, kind: kind, fromJSON: false) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            values[key] = value
        }
        if let background { values[CloudBackupBackground.field] = background.json }
        let bytes = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return bytes
    }

    static func decode(_ bytes: Data) throws -> Self {
        let corrupt = CocoaError(.fileReadCorruptFile)
        guard bytes.count <= maxBytes,
              let encoded = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { throw corrupt }
        var values: [String: Any] = [:]
        for (key, raw) in encoded {
            // Older readers can restore the preferences they recognize.
            guard let kind = keys[key] else { continue }
            if raw is NSNull {
                values[key] = raw
                continue
            }
            guard let value = convert(raw, kind: kind, fromJSON: true) else { throw corrupt }
            values[key] = value
        }
        let background = try encoded[CloudBackupBackground.field].map(CloudBackupBackground.decode)
        return Self(values: values, background: background)
    }

    func prepareBackgroundRestore(backgroundsAt directory: URL? = nil) throws -> CloudBackupBackground.Prepared? {
        try background?.prepareRestore(backgroundsAt: directory)
    }

    func apply(to defaults: UserDefaults) {
        for (key, value) in values {
            if value is NSNull {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }
    }

    private static func convert(_ raw: Any, kind: Kind, fromJSON: Bool) -> Any? {
        switch kind {
        case .bool:
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        case .int:
            return integer(raw)
        case .double:
            return number(raw)
        case .string:
            guard let string = raw as? String, string.utf8.count <= maxStringBytes else { return nil }
            return string
        case .date:
            if fromJSON {
                guard let seconds = number(raw), abs(seconds) <= 12_622_780_800 else { return nil }
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            guard let date = raw as? Date, abs(date.timeIntervalSinceReferenceDate) <= 12_622_780_800 else { return nil }
            return date.timeIntervalSinceReferenceDate
        case .strings:
            guard let strings = raw as? [String], strings.count <= 1024,
                  strings.allSatisfy({ $0.utf8.count <= 4096 }) else { return nil }
            return strings
        case .weekdays:
            guard let array = raw as? [Any], array.count <= 7 else { return nil }
            let days = array.compactMap(integer)
            guard days.count == array.count, Set(days).count == days.count,
                  days.allSatisfy({ (1...7).contains($0) }) else { return nil }
            return days
        case .data(let limit):
            if fromJSON {
                guard let string = raw as? String, string.utf8.count <= ((limit + 2) / 3) * 4,
                      let data = Data(base64Encoded: string), data.count <= limit else { return nil }
                return data
            }
            guard let data = raw as? Data, data.count <= limit else { return nil }
            return data.base64EncodedString()
        }
    }

    private static func number(_ raw: Any) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func integer(_ raw: Any) -> Int? {
        guard let value = number(raw), abs(value) <= Double(Int32.max) else { return nil }
        return Int(exactly: value)
    }
}
