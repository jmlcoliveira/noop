# Pulse, Hevy, and Apple Health workouts

This note describes the current iPhone import path and a design for one canonical workout when
Hevy, Apple Health, Pulse, and manual entry describe the same session. It is an implementation plan;
current storage and deduplication are unchanged.

## Current import paths

Hevy writes a workout to Apple Health when its Apple Health option is enabled as the workout is
saved. Hevy documents the workout type as **Strength Training** and recommends checking that option
on the save screen if a workout is missing:
[Hevy: calories in a workout](https://help.hevyapp.com/hc/en-us/articles/34462684813079-How-to-see-the-calories-burned-in-a-workout-Apple-iOS-Android),
[Hevy: Apple Health troubleshooting](https://help.hevyapp.com/hc/en-us/articles/36957445562775-Hevy-Not-Syncing-to-Apple-Health-Step-by-Step-Troubleshooting-Guide).

In Pulse, use **More → Data → Apple Health → Enable Apple Health** and grant HealthKit access. Pulse
does not prompt at launch. It syncs on foreground, on HealthKit observer wakes, and from **Sync now**;
the default sync window is 30 days. HealthKit does not reveal read grants, so a successful request
can still yield no workouts if workout reads were declined. Builds without the HealthKit entitlement
use an Apple Health export or Shortcuts import instead.

The HealthKit importer excludes Pulse-authored workouts, maps known strength types to
`Strength Training`, and falls back to `Workout` for unknown types. Rows use the generic
`apple-health` source and do not retain the HealthKit UUID or originating app identity, so a Hevy
workout is indistinguishable from another Health app's workout.

Hevy CSV can also be imported manually through **Data Sources → Lifting log**. Those rows use source
`lifting`, sport `Strength Training`, and notes for volume-load; no strain is fabricated. Hevy API
parsers exist, but the app has no account connection or API sync.

## Suggestions and current duplicate handling

Auto-detection is opt-in and suggestion-only. It scans recent heart-rate data and skips saved or
imported spans. **Save it** creates a manual row with generic sport `Workout`; nothing is saved
automatically. Older detected rows remain readable, but current scoring no longer creates them.

The workout list reads Whoop/manual, Apple Health, lifting, and activity-file namespaces; drops
repeated union copies with the same `(startTs, endTs, sport, source)` key; filters dismissed
detections; then applies overlap handling in memory. This is **read-time duplicate suppression**,
not a stored canonical record or fieldwise merge:

- A legacy detected row is hidden when it overlaps any non-detected row by **more than half of the
  shorter interval**, regardless of sport.
- Other rows are grouped by a sport key that lowercases, removes whitespace, and splits camelCase.
  Two rows are considered duplicates only when these keys match and their intervals overlap by
  **strictly more than 50% of the shorter interval**. Exactly 50% does not match.
- Normalization handles case, whitespace, and camelCase, but not semantic aliases. `Strength` and
  `Strength Training` differ, as do a saved generic `Workout` suggestion and a later Hevy
  `Strength Training` row.
- Sources need not differ, so same-source rows can collapse too. For a match the code keeps one whole
  row by counting populated HR, strain, zones, distance, and energy fields; ties prefer a non-Apple
  source, then the longer interval. It does not fill fields from the discarded row.

Both source rows stay stored, but unique values and provenance from the losing row are missing from
the displayed row. Existing merge actions only handle eligible manual/detected rows. Apple Health
upserts use `(deviceId, startTs, sport)` and replace all fields on conflict; changed times or sport
can leave an earlier row behind because there is no stable HealthKit identity.

There is also a workout-only refresh gap. Foreground, Enable, and Sync now call `HealthKitBridge.sync`
through a coordinator that then calls `refreshAfterAppleHealthSync` and `Repository.refresh`. The
background HealthKit observer calls `sync(days:)` directly and has no refresh callback or workout
revision. Even after foreground `Repository.refresh`, its diff covers daily metrics, sleep, vitals,
baselines, and freshness—not workouts—and returns without bumping `refreshSeq` when those caches are
unchanged. Home's activity load and Workouts both key reads on `refreshSeq`, so a workout-only import
can leave both screens showing the old list until another data refresh or remount. A daily aggregate
change can mask the foreground gap by advancing `refreshSeq`.

## Plan for one canonical workout

Keep provider records and build a linked, fieldwise canonical read model (or an additive canonical
table), leaving originals intact. Use the HealthKit workout UUID and HealthKit source identity, plus
a Hevy workout ID when available, to make repeated syncs idempotent. For files without stable IDs,
retain import provenance and leave ambiguous matches separate.

Use Hevy/Health for the name or activity label, start, end, and duration when available. Pulse's
strap trace can enrich HR and calculated strain when coverage is adequate; retain provenance for each
field. Do not add calories from multiple sources or sum strain values. Keep provider values and
origins available for detail/debug views.

Match stable identity first, then a documented sport-alias map and time overlap. Map equivalent
strength labels such as `Strength Training` and `Strength` to one canonical key. Link a generic
`Workout` suggestion only to a single strong match; preserve ambiguous or adjacent sessions. When a
Hevy/Health record arrives for a saved suggestion, update its canonical label and bounds while
keeping explicit user edits as overrides.

Edits and deletion should act on the canonical activity, not provider originals. Store edits as
overrides so HealthKit refresh cannot undo them. A delete/dismiss hides the linked activity across
sources and remains effective after reimport; source records and provenance remain available.
Routes and details should resolve through canonical identity while retaining source keys.

Publish a dedicated workout revision after any foreground, observer, or file import changes the
canonical activity set, and key Home's activity list and Workouts reload to it. Do not bump it for an
idempotent re-import. This keeps workout-only updates visible when daily metrics and sleep did not
change.

## Regression tests before changing the model

- Import the same HealthKit UUID repeatedly and assert one canonical activity; change its times or
  metadata and assert the existing linked activity updates rather than duplicates.
- Import a workout by foreground sync and observer sync while daily metrics/sleep are unchanged;
  assert Home and Workouts reload once, then an idempotent re-import triggers no extra reload.
- Import one Hevy session through Apple Health and CSV; link both originals once, preserve
  provenance, and leave the originals unchanged.
- Exercise the alias map, generic suggestion match, distinct adjacent workouts, different sports,
  and overlap values below, exactly at, and just above 50%.
- Verify Hevy/Health name and times, Pulse HR/strain enrichment, complementary fields, and no
  calorie/strain summing.
- Edit and delete/dismiss a linked workout, then repeat HealthKit/import syncs and assert overrides
  remain and hidden activities do not reappear.
- Keep a same-source duplicate and a cross-source duplicate fixture so source identity does not
  accidentally become a prerequisite for detecting true duplicates.
