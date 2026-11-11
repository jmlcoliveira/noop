# Updating Pulse from upstream NOOP

Pulse retains NOOP's Git history. At the initial UI checkpoint (`4cfd6800`), the fork was one commit
ahead of `ryanbr/noop/main`, with no upstream commits missing. This makes synchronization manageable;
it does not guarantee that future changes merge without conflicts.

Most Bluetooth, protocol, storage and analytics files remain upstream code. Changes in those areas
are less likely to conflict with Pulse's appearance work. The main overlap is the shared screen and
design files, `project.yml`, the app build workflow and string catalogues. In particular, Pulse's
project deliberately builds only iPhone targets, while upstream also maintains Mac and Watch targets.

Keep Pulse's icon and `altstore-source.json` fork-owned when resolving conflicts. Upstream's release
entries refer to a different app identity and must not replace Pulse's release URLs. The separate
`pulse-release.yml` workflow keeps this distribution setup apart from upstream's release machinery.

## Safe synchronization loop

Start with a clean working tree. Add the remote once if it is not already configured:

```bash
git remote add upstream https://github.com/ryanbr/noop.git
```

Fetch and merge on a separate branch, leaving the reviewed `main` version available:

```bash
git fetch upstream main
git switch -c sync/upstream-YYYY-MM-DD main
git merge upstream/main
```

Resolve overlapping edits by preserving the upstream functional changes and Pulse's iPhone UI.
Regenerate `Strand.xcodeproj` from the resolved spec; never resolve the generated project by hand.
Keep `Config/BundleIdSecrets.xcconfig` local so signing identifiers and the team survive the merge.

Run the relevant package and Python tests, compile the iPhone simulator app and inspect the calendar,
metric details, Trends, More, Coach and the approved Sleep screen. Merge the verified synchronization
branch into `main` only after review. A Git merge does not install an app or publish an IPA: phone
installation and release publication remain separate actions requiring the owner's feedback.
