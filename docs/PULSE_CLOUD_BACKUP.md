# Pulse account and cloud backup

Pulse supports optional automatic backup and explicit restore for one active iPhone installation.
The app continues to record, calculate scores and read screens from its local SQLite database.
This is a deliberate owner-authorized exception to upstream NOOP's account/cloud restrictions.
There is no continuous record synchronization or server-side score calculation.

## Components

| Component | Responsibility |
| --- | --- |
| Firebase Authentication | Google and email/password sign-in, email verification, password reset and session tokens |
| `https://pulse.joliveira.xyz` | Authenticated Cloudflare Worker API |
| Private EU R2 bucket | Full-history archives with Cloudflare encryption at rest |
| One SQLite Durable Object per account | Device ownership, completed backup index, deletion fencing and retention |
| Existing iPhone SQLite database | Collection, history and calculations |

Firestore is not required for this backup-only design. Google and email/password sign-in use the
same Firebase identity when the verified email matches. A provider collision requires proof of the
existing account; backup ownership always uses the Firebase UID rather than a client-supplied email.
The deployment initially permits only the owner's verified account. Public source or IPA access
does not grant backup-service access.

## Setup on the iPhone

1. Open **More → Pulse Account & Backup** and continue with Google or create an email/password account.
2. For email/password accounts, verify the email, then refresh verification in Pulse.
3. Review any existing backups before choosing to back up this iPhone. A fresh installation does
   not automatically replace the previous installation's cloud history.
4. Choose **Account protected** or **Recovery code protected**. Account protection lets you
   restore after signing in without a separate code and lets the backup service read your backup.
   Recovery-code protection encrypts the backup on your iPhone. Save the generated code separately
   and confirm it during setup. You need the original code after a reinstall or device loss.
5. Enable automatic backup. Wi-Fi-only is the default. **Back up now** is also available.

Upgrading from a version with only recovery-code protection keeps that mode. You can explicitly
change protection for new backups in **Pulse Account & Backup**. Existing archives keep their
original mode and still need their original recovery code if they had one.

Automatic work is roughly daily when data has changed and the phone is connected to power. It
defers during active workouts, strap offloads, rescoring, Low Power Mode and serious thermal pressure.
iOS controls background execution;
the last-success timestamp is the evidence that a backup completed. Compression and any client encryption
run away from the main actor. File-backed background URLSession transfers can continue while the
app is suspended, subject to iOS/network constraints. Force-quitting can cancel background transfers.

## Data format and security

- `CloudBackupDatabase.snapshot` uses SQLite's backup API to capture a committed view including WAL
  pages while recording can continue. It does not copy a live main database file after a checkpoint.
- The portable copy retains stored history, runs supported schema migrations in staging, and clears
  source-device cursors and peripheral pairing identifiers. The cloud archive includes
  `pulse-preferences.json` for portable preferences such as profile details (including date of
  birth), appearance and layouts, and workout and notification settings. Sign-in state, credentials,
  device and recovery keys, operating system permissions, and sync cursors are excluded.
  The selected custom background photo, enable switch and fill mode are also carried; photo recents
  remain local. Photo staging leaves the current background intact until the database restore commits.
- Cloud archives use lossless compression. All measured history, database indexes
  and portable settings are retained; no heart-rate sampling, index deletion or `VACUUM` is performed.
  Manual `.noopbak` exports retain their existing ZIP format. Cloud restore also accepts the earlier
  encrypted ZIP payloads.
- Each archive carries its protection mode. **Account protected** uploads the compressed archive
  without client-side encryption. The Pulse backup service can read it. **Recovery code protected**
  wraps the compressed archive on the iPhone in AES-256-GCM using 1 MiB chunks, a fresh 32-byte salt
  and an HKDF-SHA256 per-file key. Each chunk authenticates the header and its position. The
  recovery key contains 256 random bits and stays with the owner. Pulse stores it in ThisDeviceOnly
  Keychain storage. Its copy action uses a local-only clipboard with a short expiry.
- Both modes use HTTPS, private R2 storage with Cloudflare-managed AES-256 encryption at rest,
  and account and device authorization. The service receives the file and metadata including account
  identity, protection mode, timestamps, size and SHA-256 checksum. Legacy backups with no mode
  metadata are recovery-code protected. [Cloudflare R2 data security](https://developers.cloudflare.com/r2/reference/data-security/)
- The archive limit is 512 MiB. Files through 80 MiB use a direct upload. Larger files use resumable
  16 MiB parts. The service verifies every part and the complete file before a backup is visible.
  Interrupted uploads resume from server-confirmed parts and retain device and generation fencing.

The Worker verifies Firebase RS256 signatures against Google's cached public certificates and checks
issuer, audience, expiry, authentication time, verified email, provider and invitation. It needs no
Firebase service-account private key. The R2 binding needs no access key embedded in the app.
Firebase's client API key identifies the project; Authentication and the backend's authorization
checks protect data. Keep the local configuration ignored despite that key not being a server secret.

Google sign-in opens the system authentication session, uses Firebase's one-time authorization flow,
and validates the expected state on return. The fixed HTTPS callback redirects only to Pulse's
registered native URL. Google client secrets remain in Firebase's provider configuration, not in
the app or Worker. Recovery-code-protected backups always require their original code.

## Migration before account creation

With explicit owner consent, a consistent offline snapshot can be encrypted locally and staged in
private R2 before an account exists. Only ciphertext and a small migration manifest are uploaded.
The recovery key stays with the owner and is never stored in R2 or the manifest.

The manifest is reserved for a SHA-256 hash of the intended normalized email. After sign-in with
that verified address, a Durable Object binds the staged backup to exactly one Firebase UID.
Subsequent access uses that UID. A later UID cannot claim the same migration, and deletion fences
prevent the migration from bringing back data the account already deleted. There is no public
administrative upload endpoint. See the Worker README for the private staging procedure.

## Completion, retention and deletion

Each installation has a UUID and a random ThisDeviceOnly device secret. An explicit takeover
advances an account generation; old installations and already queued writes cannot finalize under
the previous generation. The server stores only a fingerprint of the device secret.

An immutable upload UUID, exact size, protection mode and native R2 SHA-256 verification identify each backup.
Only fully stored, verified uploads enter the restore list. Replaying the same retained upload is
idempotent, including after a lost HTTP response. The latest seven successful backups are retained.
Failed writes and retired archives enter a durable cleanup queue; R2 failures are retried by alarm.

Deleting backups turns off automatic backup, advances the generation and invalidates queued writes.
Deleting the account requires recent authentication and deletes its backups before Firebase identity
deletion. A minimal opaque tombstone prevents still-valid older tokens from recreating deleted data.
Signing out is separate from deleting stored cloud copies.

## Restore and Apple Health

Restore downloads into protected staging and verifies the file before expanding the archive.
Recovery-code-protected restores decrypt the file first. Both modes validate the archive and
SQLite contents and check schema compatibility before requesting installation. The current process
keeps its existing database open and reports that a full quit/reopen is needed. Readings collected
after the restore was prepared can be replaced by the chosen historical snapshot.

On the next launch, before any database handle opens, a recoverable file transaction installs the
staged database. The previous database and any WAL/SHM files are preserved together as a local
rollback copy. A crash during file movement is recoverable on the next attempt.

Apple Health may already contain exports from the original installation. The restore establishes a
monotonic export boundary that prevents automatic historical workout/calorie saves and orphan
deletions. Newly recorded workouts can continue exporting. Imported Health query anchors are
device-local and are refreshed rather than restored. Cloud restore does not write a copied archive
directly into Apple Health.

## Build and deploy

Copy `Config/PulseCloudSecrets.example.xcconfig` to the ignored local
`Config/PulseCloudSecrets.xcconfig` and set the Firebase client key/project identifier. The iOS
Info.plist receives `PulseFirebaseAPIKey`. An unconfigured build shows backup as unavailable.
Account and backup state must not be populated from real credentials in simulator fixtures.

See [Worker deployment and API](../cloud/pulse-backup/README.md). Deploy with only the necessary
Worker and route permissions. Cloudflare currently requires `workers:write` for Wrangler's R2 bucket
lookup/binding in addition to script/route deployment; certificate-writing scopes are not needed.
Keep Worker environment values in a private secrets file outside the repository. Bucket public
access stays disabled. The EU restriction applies to R2 object storage, not a promise that all
Firebase identity or global Worker metadata processing occurs in the EU.

## Validation

Acceptance checks cover consistent snapshots during WAL writes, protection choices and legacy defaults,
corruption, wrong-key and size rejection, interrupted restore and rollback, stale-device fencing,
immutable upload replay, seven-copy retention, deletion races, lost responses, token verification,
and absence of uploads before consent.
Backend tests and local Workerd use synthetic identities and payloads. A simulator build and UI
review precede any physical-iPhone update; installation requires the owner's explicit approval.
