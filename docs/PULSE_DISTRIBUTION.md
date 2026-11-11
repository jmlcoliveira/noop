# Pulse iPhone distribution

Pulse's AltStore source is served from this repository's `main` branch:

`https://raw.githubusercontent.com/jmlcoliveira/noop/main/altstore-source.json`

The source uses `dev.pulse.companion.altstore`, and starts with `apps: []`, which AltStore's [source format supports](https://faq.altstore.io/developers/make-a-source). It does not point to NOOP's upstream releases or advertise an IPA that has not been verified and uploaded to the Pulse fork.

## Release workflow

`.github/workflows/pulse-release.yml` is manual-only. It builds the unsigned Release configuration for generic iPhone hardware with `BUNDLE_ID_PREFIX=dev.pulse.companion`, retains the `NOOPWidgets.appex` extension and its shared App Group, and packages the app with `Tools/prepare-ios-sideload-app.sh`.

Run it first with the default `publish: false`. That uploads a downloadable workflow artifact without creating a GitHub release or changing the AltStore source. Complete simulator review and collect feedback before selecting `publish: true` in a later manual run; the workflow requires a simulator feedback summary for that choice. Publishing is restricted to this fork's `main` branch. The publish job verifies that the release contains the exact IPA bytes before it updates the source.

Before each new public Pulse release, increment `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`project.yml`. Each published marketing version has an immutable `pulse-v<version>` release and IPA.
The source updater reads both values from the actual IPA. AltStore compares the first compatible
entry's version/build with the installed app; source dates alone do not trigger an update. See
[AltStore's update rules](https://faq.altstore.io/developers/updating-apps).

The first Pulse IPA still needs to be installed through the chosen sideloader before it can manage
subsequent updates. Changing this JSON does not enroll the existing Xcode-installed app by itself.

The workflow does not install anything on an iPhone. No signing identity, team, or signing secret is stored in the repository. The IPA remains unsigned for AltStore or another compatible sideloader to sign on the user's behalf.

## Local source updater

`Tools/update_pulse_altstore.py inspect <ipa>` reads the app and widget `Info.plist` files and signed entitlements directly from the IPA ZIP; it does not extract the archive. It rejects unexpected bundle IDs, App Group IDs, version/build mismatches, missing app/widget files, missing privacy descriptions, and unsigned or invalid entitlement data. The IPA's own size, minimum OS version and privacy usage strings populate the manifest.

After an IPA has been uploaded to a `pulse-v<version>` release on `jmlcoliveira/noop`, update the local manifest with:

```sh
Tools/update-altstore-source.sh update \
  --ipa Pulse-ios-unsigned-v<version>.ipa \
  --tag pulse-v<version> \
  --description "Release notes"
```

This command changes only the local JSON file. It never uploads, creates a release, pushes a commit, installs the IPA, or contacts AltStore. The old positional NOOP-release form is rejected because it could advertise an upstream asset from this Pulse source. Use the manual workflow so the release asset is checked before the source entry is prepared.

## Identifiers

- App: `dev.pulse.companion.noop`
- Widget: `dev.pulse.companion.noop.widgets`
- App Group: `group.dev.pulse.companion.noop.staging`
- Source: `dev.pulse.companion.altstore`

