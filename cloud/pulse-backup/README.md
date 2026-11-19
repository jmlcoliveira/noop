# Pulse Cloud Backup Worker

Pulse sends snapshots over HTTPS to `https://pulse.joliveira.xyz`. The Worker streams the upload to a private R2 bucket with R2's native SHA-256 verification. A SQLite-backed Durable Object per Firebase account commits backup metadata and coordinates ownership changes, upload finalization, retention, and deletion. Cloudflare supports this storage on Workers Free. [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/) · [R2 Workers API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)

Recovery-key protection (`recoveryKey`) encrypts the snapshot on the device with a recovery key that the service does not receive. Account protection (`account`) sends the compressed archive without that extra encryption and lets the owner restore by signing in. Cloudflare encrypts both modes at rest using Cloudflare-managed keys. The Worker and operators with storage access can read account-protected archives. [Cloudflare R2 data security](https://developers.cloudflare.com/r2/reference/data-security/)

## Deploy

1. Enable the password and Google providers in Firebase Authentication. Each invited account must present a Firebase ID token with a verified email before using cloud backup. Keep one Firebase account per email if both providers will be used.
2. Enable R2 and create a private Standard bucket named `pulse-backups` in the EU jurisdiction. Leave public bucket access disabled. This deployment uses `pulse.joliveira.xyz` as a Worker custom domain.
3. Set `FIREBASE_PROJECT_ID` to the Firebase project ID. Set `ALLOWED_FIREBASE_UIDS` or `ALLOWED_FIREBASE_EMAILS` to a comma-separated list of invited accounts. A signed, verified identity must match either list. Initial access can be granted to the owner's verified email before the Firebase UID exists. An empty allowlist denies all access.
4. Deploy from this directory with credentials for the Cloudflare account that owns the domain. Store the environment values as Worker secrets and keep the secrets file outside the repository.

```sh
wrangler r2 bucket create pulse-backups --jurisdiction eu
wrangler deploy --secrets-file /path/to/pulse-backup-secrets.env
curl -fsS https://pulse.joliveira.xyz/health
curl -i https://pulse.joliveira.xyz/v1/state
```

The smoke checks expect HTTP 200 for `/health` and HTTP 401 for the unauthenticated state request. The Worker uses the Google public certificate endpoint and its cache lifetime to verify Firebase tokens. The deployment uses an R2 binding and requires no Firebase service account or R2 access keys. Seven maximum-size snapshots occupy up to 3.5 GiB per account before temporary in-flight or cleanup objects. [Firebase token verification](https://firebase.google.com/docs/auth/admin/verify-id-tokens) · [R2 pricing](https://developers.cloudflare.com/r2/pricing/) · [Worker secrets](https://developers.cloudflare.com/workers/configuration/secrets/)

### Google sign-in configuration

Enable Google in Firebase Authentication and keep **Link accounts that use the same email** enabled
in Authentication settings. Add `https://pulse.joliveira.xyz/auth/google/callback` to the authorized
redirect URIs of Firebase's web OAuth client without removing its Firebase-hosted handler. The app
uses Firebase's REST authorization-code flow and the system authentication session. It does not
embed the web client's secret or depend on the original bundle identifier surviving re-signing.

The HTTPS callback accepts only a bounded, unambiguous authorization response and redirects to
the fixed native destination `pulseauth://google/callback`. The app validates Firebase's original
state and exchanges the response with the saved session ID. The route cannot redirect to arbitrary
hosts, and its responses are not cached. Testing the unauthenticated callback must not create a
Firebase user on behalf of the owner.

## API

Use HTTPS and `Authorization: Bearer <Firebase ID token>` with every `/v1/` request. Device mutations use `X-Pulse-Device-ID` for the installation's lowercase UUID and `X-Pulse-Device-Key` for its randomly generated 32-byte key encoded as lowercase hex. The server stores only a fingerprint of the device key.

| Method and path | Behavior |
| --- | --- |
| `GET /v1/state` | Returns `{activeDeviceId, generation, backups, maxBackupBytes, supportedBackupProtections}`. Protection support is `["recoveryKey", "account"]`; older services without this field support only recovery-key uploads. An account without a device starts with `activeDeviceId: null` and `generation: 0`. `backups` lists the latest seven successful snapshots, newest first, including a staged snapshot adopted for the verified address. |
| `POST /v1/device/claim` | Takes JSON `{expectedGeneration}` and the device headers. Returns the new state. Repeating a claim by the current device is idempotent. An explicit claim by another device advances the generation and invalidates the previous device's in-flight upload. |
| `PUT /v1/backups/{id}` | Takes the backup file as the body, a client-generated lowercase UUID in the path, the device headers, `Content-Length`, `X-Pulse-Generation`, and `X-Pulse-SHA256` in lowercase hex. The optional `X-Pulse-Backup-Protection` header accepts `account` or `recoveryKey`. Limit is 80 MiB. Replaying a retained ID with the same size, digest, and protection returns its original record. |
| `POST /v1/backups/{id}/parts` | Starts or resumes an upload of up to 512 MiB. Send `{size,sha256,protection}` for the full backup file along with the device headers and `X-Pulse-Generation`. The response contains `{partSize,totalParts,receivedParts}` and includes `backup` if the snapshot was already committed. |
| `PUT /v1/backups/{id}/parts/{index}` | Uploads one zero-based part. Send the device headers, `X-Pulse-Generation`, the part's `Content-Length`, and its `X-Pulse-SHA256`. Each part is 16 MiB except the final part, which may be smaller. Parts may arrive out of order. A verified part or its exact retry returns 204. |
| `POST /v1/backups/{id}/parts/complete` | Takes the device headers and `X-Pulse-Generation`. The Worker streams all the parts in order and verifies the whole-file SHA-256 before commit. Returns the normal backup record with HTTP 201 for a new commit or 200 on replay. |
| `DELETE /v1/backups/{id}/parts` | Takes the device headers and `X-Pulse-Generation`. Aborts the pending direct or multipart upload for that ID. Returns 204 on retries and leaves committed snapshots available. |
| `GET /v1/backups/{id}` | Streams the file with `Content-Length`, `X-Pulse-SHA256`, and `X-Pulse-Backup-Protection`. Any authorized installation can download it. Recovery-key backups also require the key to restore. |
| `DELETE /v1/backups` | Takes the device headers and `X-Pulse-Generation`. Removes backup records, advances the generation, and invalidates current or queued uploads from the previous generation. Returns 204 with the new `X-Pulse-Generation`. Repeating the same deletion preserves any newer backups. |
| `DELETE /v1/account` | Requires a Firebase login within the preceding five minutes. A formerly invited account can still request deletion. Removes backups and device ownership, and records an opaque tombstone to reject replayed Firebase tokens. Returns 204 on retries. The client then deletes the Firebase Authentication account. |

Backup records contain `{id, size, sha256, createdAt, protection}`. The timestamp uses ISO 8601 UTC with milliseconds. Missing upload protection and legacy records without `protection` imply `recoveryKey`. An upload retry with a different protection mode returns `409 backup_id_used`. Errors use `{error}` with a stable code. Common responses include `400 invalid_protection`, `401 unauthorized`, `403 email_not_verified`, `403 not_allowlisted`, `409 device_conflict`, `409 backup_id_used`, `409 upload_in_progress`, `410 account_deleted`, `413 backup_too_large`, and `422 checksum_mismatch`.

The account allows one pending upload at a time. A multipart upload lease expires 60 minutes after the last new part was verified, or 60 minutes after starting if no parts were received. Start the same ID again to reconcile verified part indexes after a lost response.

Retention and deletion immediately remove retired backups from the restore list. The Worker deletes their R2 objects and retries failed deletions through a durable alarm. An interrupted or invalidated write cannot finalize. If its R2 outcome is uncertain, the alarm sweeps its private objects after the upload lease expires.

## Stage a pre-account backup

With the owner's consent, an operator can stage an encrypted Pulse backup in the private R2 bucket before that owner creates a Firebase account. Use the production Pulse ciphertext format and preserve the corresponding recovery key with the owner. Use a fresh lowercase backup UUID and the SHA-256 digest of the ciphertext. The file limit is 80 MiB.

1. Upload the ciphertext to `migrations/objects/<backup-uuid>.bin` using authenticated R2 administration.
2. Compute the lowercase hex SHA-256 of the owner's UTF-8 email after trimming whitespace and lowercasing it. Upload the UTF-8 manifest to `migrations/inbox/<email-hash>.json` after the ciphertext upload succeeds. Use this shape, with the ciphertext size in bytes and an ISO 8601 UTC timestamp with milliseconds.

   ```json
   {
     "version": 1,
     "emailHash": "<email-hash>",
     "id": "<backup-uuid>",
     "size": 123456,
     "sha256": "<ciphertext-sha256>",
     "createdAt": "2026-01-01T00:00:00.000Z"
   }
   ```

3. Leave both objects immutable while the invited owner signs in. The first eligible state request verifies the ciphertext digest and commits the snapshot to the matching Firebase UID. A durable claim reserves each staged email for one UID, even across retries. The account removes the inbox manifest after committing the backup. The normal retention and deletion rules apply, including a backup or account deletion while adoption is in progress.

## Verify locally

Run `npm test` with Node 22 or later and OpenSSL. The suite uses generated test credentials and covers Firebase signature checks and invitation gates, upload verification, retention, device takeover, deletion, and cleanup retries. `wrangler deploy --dry-run` verifies the deployable bundle without publishing it.
