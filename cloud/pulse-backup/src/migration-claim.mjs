import { DIRECT_BACKUP_BYTES, SHA256, UUID } from "./backup-account.mjs";
import { APIError, bytesToHex, errorResponse, json, noContent, smallJSON } from "./http.mjs";

const migrationUnavailable = () => new APIError(503, "migration_unavailable");

async function readManifest(object, emailHash) {
  if (!object.body || object.size < 1 || object.size > 512) throw migrationUnavailable();
  let manifest;
  try {
    manifest = await smallJSON(object);
  } catch {
    throw migrationUnavailable();
  }
  const { version, id, size, sha256, createdAt } = manifest ?? {};
  if (version !== 1 || manifest.emailHash !== emailHash || typeof id !== "string" || !UUID.test(id)
      || !Number.isSafeInteger(size) || size < 1 || size > DIRECT_BACKUP_BYTES
      || typeof sha256 !== "string" || !SHA256.test(sha256)
      || typeof createdAt !== "string" || !Number.isFinite(Date.parse(createdAt))
      || new Date(createdAt).toISOString() !== createdAt) throw migrationUnavailable();
  return { id, size, sha256, createdAt };
}

async function verifyObject(bucket, key, backup) {
  const object = await bucket.head(key);
  if (!object || object.size !== backup.size) throw migrationUnavailable();
  let checksum = object.checksums?.sha256;
  if (!checksum) {
    // Administrative uploads can omit R2's native SHA-256 metadata.
    const payload = await bucket.get(key, { onlyIf: { etagMatches: object.etag } });
    if (!payload?.body || payload.version !== object.version) throw migrationUnavailable();
    const digest = new crypto.DigestStream("SHA-256");
    const [, streamedChecksum] = await Promise.all([payload.body.pipeTo(digest), digest.digest]);
    checksum = streamedChecksum;
  }
  if (bytesToHex(checksum) !== backup.sha256) throw migrationUnavailable();
  return object.version;
}

export class BackupMigrationClaim {
  constructor(ctx, env) {
    this.storage = ctx.storage;
    this.bucket = env.BACKUPS;
  }

  async fetch(request) {
    try {
      const emailHash = new URL(request.url).pathname.slice(1);
      if (request.method !== "POST" || !SHA256.test(emailHash)) return json({ error: "not_found" }, 404);
      const { owner, erase } = (await smallJSON(request)) ?? {};
      if (typeof owner !== "string" || !SHA256.test(owner) || typeof erase !== "boolean") {
        throw new APIError(400, "invalid_request");
      }
      const existing = this.storage.kv.get("owner");
      if (existing && existing !== owner) return noContent();

      const manifestKey = `migrations/inbox/${emailHash}.json`;
      const manifest = await this.bucket.get(manifestKey);
      if (!manifest) return noContent();
      const backup = await readManifest(manifest, emailHash);
      const key = `migrations/objects/${backup.id}.bin`;
      const version = erase ? undefined : await verifyObject(this.bucket, key, backup);

      // A verified address can claim its staged backup for only one account. Hold the claim across retries.
      const claimed = this.storage.transactionSync(() => {
        const current = this.storage.kv.get("owner");
        if (current) return current === owner;
        this.storage.kv.put("owner", owner);
        return true;
      });
      return claimed ? json({ backup, key, manifestKey, version }) : noContent();
    } catch (error) {
      return errorResponse(error);
    }
  }
}
