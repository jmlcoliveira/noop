import { APIError, bytesToHex, errorResponse, json, noContent, smallJSON } from "./http.mjs";

export const DIRECT_BACKUP_BYTES = 80 * 1024 * 1024;
export const PART_BYTES = 16 * 1024 * 1024;
export const MAX_BACKUP_BYTES = 32 * PART_BYTES;
const RETAINED_BACKUPS = 7;
const UPLOAD_LEASE_MS = 60 * 60 * 1000;
const CLEANUP_RETRY_MS = 60 * 1000;
const MAX_CLEANUP_ITEMS = 32;
const MAX_CLEANUP_BYTES = MAX_CLEANUP_ITEMS * DIRECT_BACKUP_BYTES;
const CLEANUP_BATCH_SIZE = 128;
export const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
export const SHA256 = /^[0-9a-f]{64}$/;
const BACKUP_PATH = /^\/v1\/backups\/([^/]+)$/;
const PARTS_PATH = /^\/v1\/backups\/([^/]+)\/parts(?:\/(complete|0|[1-9]\d?))?$/;
const MIGRATION_EMAIL = "X-Pulse-Internal-Migration-Email";
const PROTECTION_HEADER = "X-Pulse-Backup-Protection";
const RECOVERY_KEY = "recoveryKey";

function displayState(state) {
  return {
    activeDeviceId: state.device?.id ?? null,
    generation: state.generation,
    backups: state.backups.map(({ backup }) => backup),
    maxBackupBytes: MAX_BACKUP_BYTES,
    supportedBackupProtections: ["recoveryKey", "account"],
  };
}

async function readDevice(request) {
  const id = request.headers.get("X-Pulse-Device-ID") ?? "";
  const key = request.headers.get("X-Pulse-Device-Key") ?? "";
  if (!UUID.test(id) || !SHA256.test(key)) throw new APIError(400, "invalid_device");
  const fingerprint = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
  return { id, fingerprint: bytesToHex(fingerprint) };
}

function readGeneration(request) {
  const header = request.headers.get("X-Pulse-Generation") ?? "";
  const generation = Number(header);
  if (!/^\d+$/.test(header) || !Number.isSafeInteger(generation)) {
    throw new APIError(400, "invalid_generation");
  }
  return generation;
}

function verifyDevice(state, device, generation = state.generation) {
  if (state.device?.id !== device.id || state.device.fingerprint !== device.fingerprint
      || state.generation !== generation) throw new APIError(409, "device_conflict");
}

function readUpload(request, maxBytes) {
  const length = request.headers.get("Content-Length") ?? "";
  const size = Number(length);
  if (!/^\d+$/.test(length)) throw new APIError(411, "content_length_required");
  if (size > maxBytes) throw new APIError(413, "backup_too_large");
  if (!request.body || size < 1) throw new APIError(400, "empty_backup");
  if ((request.headers.get("Content-Encoding") ?? "identity").toLowerCase() !== "identity") {
    throw new APIError(415, "unsupported_content_encoding");
  }
  const sha256 = request.headers.get("X-Pulse-SHA256") ?? "";
  if (!SHA256.test(sha256)) throw new APIError(400, "invalid_checksum");
  return { size, sha256 };
}

function readProtection(value = RECOVERY_KEY) {
  if (value === RECOVERY_KEY || value === "account") return value;
  throw new APIError(400, "invalid_protection");
}

function parsePartManifest(text) {
  const manifest = JSON.parse(text);
  let depth = 0;
  let seenProtection = false;
  // JSON.parse keeps the last duplicate key. Reject ambiguous top-level protection, including escaped keys.
  for (const [token, key, colon] of text.matchAll(/("(?:[^"\\]|\\.)*")(\s*:)?|[{}\[\]]/g)) {
    if (token === "{" || token === "[") depth++;
    if (token === "}" || token === "]") depth--;
    if (colon && depth === 1 && JSON.parse(key) === "protection") {
      if (seenProtection) throw new APIError(400, "invalid_protection");
      seenProtection = true;
    }
  }
  return manifest;
}

function matchesManifest(existing, incoming) {
  return existing?.size === incoming.size && existing.sha256 === incoming.sha256
    && (existing.protection ?? RECOVERY_KEY) === incoming.protection;
}

function matchingObject(object, receipt) {
  const checksum = object?.checksums?.sha256;
  return object?.size === receipt.size && checksum && bytesToHex(checksum) === receipt.sha256;
}

function partKey(prefix, index) {
  return `${prefix}/${index}`;
}

function partPlan(size, receivedParts, backup) {
  return json({ partSize: PART_BYTES, totalParts: Math.ceil(size / PART_BYTES), receivedParts, backup });
}

function verifyCleanupCapacity(garbage) {
  const reservedBytes = garbage.reduce((total, item) => (
    total + (item.partCount ? item.partCount * PART_BYTES : DIRECT_BACKUP_BYTES)
  ), 0);
  if (garbage.length >= MAX_CLEANUP_ITEMS || reservedBytes >= MAX_CLEANUP_BYTES) {
    throw new APIError(503, "cleanup_pending");
  }
}

export class BackupAccount {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.storage = ctx.storage;
    this.bucket = env.BACKUPS;
    this.migrationClaims = env.MIGRATION_CLAIMS;
    this.prefix = ctx.id.toString();
    this.uploading = new Set();
    this.completing = new Set();
  }

  #read() {
    return this.storage.kv.get("state") ?? { generation: 0, backups: [], garbage: [] };
  }

  #save(state) {
    this.storage.kv.put("state", state);
  }

  #liveState() {
    const state = this.#read();
    if (state.deleted) throw new APIError(410, "account_deleted");
    return state;
  }

  async fetch(request) {
    try {
      const path = new URL(request.url).pathname;
      const method = request.method;
      if (path === "/v1/account" && method === "DELETE") {
        return await this.#deleteAccount(request);
      }
      if (path === "/v1/state" && method === "GET") return await this.#state(request);
      if (path === "/v1/device/claim" && method === "POST") return await this.#claim(request);
      if (path === "/v1/backups" && method === "DELETE") return await this.#deleteBackups(request);

      const parts = PARTS_PATH.exec(path);
      if (parts && UUID.test(parts[1])) {
        const [, id, action] = parts;
        if (method === "POST" && action === undefined) return await this.#startParts(request, id);
        if (method === "PUT" && action && action !== "complete") return await this.#uploadPart(request, id, Number(action));
        if (method === "POST" && action === "complete") return await this.#completeParts(request, id);
        if (method === "DELETE" && action === undefined) return await this.#abortParts(request, id);
      }

      const id = BACKUP_PATH.exec(path)?.[1];
      if (id && UUID.test(id)) {
        if (method === "GET") return await this.#download(id);
        if (method === "PUT") return await this.#upload(request, id);
      }
      return json({ error: "not_found" }, 404);
    } catch (error) {
      return errorResponse(error);
    }
  }

  async #findMigration(emailHash, erase) {
    const claim = this.migrationClaims.getByName(emailHash);
    const response = await claim.fetch(new Request(`https://migration.pulse.internal/${emailHash}`, {
      method: "POST",
      body: JSON.stringify({ owner: this.prefix, erase }),
    }));
    if (!response.ok) throw new APIError(503, "migration_unavailable");
    return response.status === 204 ? null : response.json();
  }

  async #state(request) {
    const initial = this.#liveState();
    const emailHash = request.headers.get(MIGRATION_EMAIL) ?? "";
    if (initial.migrationClosed || !SHA256.test(emailHash)) return json(displayState(initial));

    const migration = await this.#findMigration(emailHash, false);
    if (migration) {
      const { backup, key, manifestKey, version } = migration;
      await this.#scheduleCleanup(Date.now());
      const state = this.#read();
      this.#queue(state, [{ key: manifestKey }]);
      this.storage.transactionSync(() => {
        if (!state.migrationClosed && !this.storage.kv.get(`used:${backup.id}`)) {
          state.backups.push({ backup, key, version });
          state.backups.sort((a, b) => b.backup.createdAt.localeCompare(a.backup.createdAt));
          this.#queue(state, state.backups.splice(RETAINED_BACKUPS));
          this.storage.kv.put(`used:${backup.id}`, true);
        } else if (!state.backups.some((entry) => entry.key === key)) {
          this.#queue(state, [{ key }]);
        }
        state.migrationClosed = true;
        this.#save(state);
      });
      await this.#removeGarbage().catch(() => {});
    }
    return json(displayState(this.#liveState()));
  }

  async #claim(request) {
    const device = await readDevice(request);
    const { expectedGeneration } = (await smallJSON(request)) ?? {};
    if (!Number.isSafeInteger(expectedGeneration) || expectedGeneration < 0) {
      throw new APIError(400, "invalid_generation");
    }

    const state = this.#liveState();
    if (state.device?.id === device.id) {
      verifyDevice(state, device);
      return json(displayState(state));
    }
    if (state.generation !== expectedGeneration) throw new APIError(409, "device_conflict");

    this.#abandonUpload(state);
    state.device = device;
    state.generation += 1;
    this.#save(state);
    await this.#scheduleCleanup();
    return json(displayState(state));
  }

  async #download(id) {
    const entry = this.#liveState().backups.find(({ backup }) => backup.id === id);
    if (!entry) throw new APIError(404, "backup_not_found");
    const headers = {
      "Cache-Control": "no-store",
      "Content-Type": "application/octet-stream",
      "Content-Length": String(entry.backup.size),
      [PROTECTION_HEADER]: entry.backup.protection ?? RECOVERY_KEY,
      "X-Content-Type-Options": "nosniff",
      "X-Pulse-SHA256": entry.backup.sha256,
    };
    if (entry.parts) {
      const stream = new FixedLengthStream(entry.backup.size);
      this.ctx.waitUntil(this.#writeParts(entry, stream.writable).catch(() => {}));
      return new Response(stream.readable, { headers });
    }
    const object = await this.bucket.get(entry.key);
    if (!object || object.size !== entry.backup.size) throw new APIError(503, "backup_unavailable");
    if (entry.version !== undefined && object.version !== entry.version) {
      void object.body.cancel().catch(() => {});
      throw new APIError(503, "backup_unavailable");
    }
    return new Response(object.body, { headers });
  }

  async #upload(request, id) {
    const device = await readDevice(request);
    const generation = readGeneration(request);
    const protection = readProtection(request.headers.get(PROTECTION_HEADER) ?? undefined);
    const manifest = { id, ...readUpload(request, DIRECT_BACKUP_BYTES), protection };
    const state = this.#liveState();
    verifyDevice(state, device, generation);

    const existing = state.backups.find(({ backup }) => backup.id === id)?.backup;
    if (matchesManifest(existing, manifest)) return json(existing);
    if (this.storage.kv.get(`used:${id}`)) throw new APIError(409, "backup_id_used");
    if (state.pending?.expires <= Date.now()) this.#abandonUpload(state);
    if (state.pending) {
      if (state.pending.manifest?.id === id && !matchesManifest(state.pending.manifest, manifest)) {
        throw new APIError(409, "backup_id_used");
      }
      throw new APIError(409, "upload_in_progress");
    }
    verifyCleanupCapacity(state.garbage);

    const key = `${this.prefix}/${crypto.randomUUID()}`;
    state.pending = { key, expires: Date.now() + UPLOAD_LEASE_MS, manifest };
    this.#save(state);
    this.uploading.add(key);

    let uncertain = false;
    try {
      // Persist the sweep before the R2 write so a reset cannot strand an uncommitted object.
      await this.#scheduleCleanup();
      this.#verifyReservation(key, device, generation);
      try {
        await this.#writePayload(key, request, manifest);
      } catch (error) {
        uncertain = !(error instanceof APIError);
        throw error;
      }

      const updated = this.#verifyReservation(key, device, generation);
      return this.#commitBackup(updated, manifest, { key });
    } finally {
      this.uploading.delete(key);
      await this.#finishUpload(key, !uncertain);
    }
  }

  async #startParts(request, id) {
    const device = await readDevice(request);
    const generation = readGeneration(request);
    const { size, sha256, protection: requestedProtection } = (await smallJSON(request, parsePartManifest)) ?? {};
    const manifest = { id, size, sha256, protection: readProtection(requestedProtection) };
    if (!Number.isSafeInteger(size) || size < 1) throw new APIError(400, "invalid_size");
    if (size > MAX_BACKUP_BYTES) throw new APIError(413, "backup_too_large");
    if (typeof sha256 !== "string" || !SHA256.test(sha256)) throw new APIError(400, "invalid_checksum");

    const state = this.#liveState();
    verifyDevice(state, device, generation);
    const existing = state.backups.find(({ backup }) => backup.id === id)?.backup;
    if (matchesManifest(existing, manifest)) {
      return partPlan(size, [], existing);
    }
    if (this.storage.kv.get(`used:${id}`)) throw new APIError(409, "backup_id_used");
    if (state.pending?.expires <= Date.now()) this.#abandonUpload(state);
    if (state.pending) {
      const { manifest: pendingManifest, parts } = state.pending;
      if (pendingManifest?.id !== id) throw new APIError(409, "upload_in_progress");
      if (!matchesManifest(pendingManifest, manifest)) throw new APIError(409, "backup_id_used");
      if (!parts) throw new APIError(409, "upload_in_progress");
      const received = parts.flatMap((part, index) => part ? [index] : []);
      return partPlan(size, received);
    }

    verifyCleanupCapacity(state.garbage);
    state.pending = {
      key: `${this.prefix}/${crypto.randomUUID()}`,
      expires: Date.now() + UPLOAD_LEASE_MS,
      manifest,
      parts: Array(Math.ceil(size / PART_BYTES)).fill(null),
    };
    this.#save(state);
    await this.#scheduleCleanup();
    this.#verifyReservation(state.pending.key, device, generation);
    return partPlan(size, []);
  }

  async #uploadPart(request, id, index) {
    const device = await readDevice(request);
    const generation = readGeneration(request);
    const receipt = readUpload(request, PART_BYTES);
    const state = this.#liveState();
    verifyDevice(state, device, generation);
    const committed = state.backups.find(({ backup }) => backup.id === id)?.parts;
    if (committed) {
      const part = committed[index];
      if (part?.size === receipt.size && part.sha256 === receipt.sha256) return noContent();
      throw new APIError(409, "part_already_uploaded");
    }
    const pending = this.#pendingParts(state, id);
    if (index >= pending.parts.length) throw new APIError(400, "invalid_part");
    const expectedSize = Math.min(PART_BYTES, pending.manifest.size - index * PART_BYTES);
    if (receipt.size !== expectedSize) throw new APIError(422, "invalid_part_size");
    const existing = pending.parts[index];
    if (existing?.sha256 === receipt.sha256) return noContent();
    if (existing) throw new APIError(409, "part_already_uploaded");

    const key = partKey(pending.key, index);
    if (this.uploading.has(key)) throw new APIError(409, "upload_in_progress");
    this.uploading.add(key);
    try {
      await this.#scheduleCleanup();
      this.#verifyReservation(pending.key, device, generation);
      await this.#writePayload(key, request, receipt, true);
      const updated = this.#verifyReservation(pending.key, device, generation);
      updated.pending.parts[index] = receipt;
      updated.pending.expires = Date.now() + UPLOAD_LEASE_MS;
      this.#save(updated);
      return noContent();
    } finally {
      this.uploading.delete(key);
    }
  }

  async #completeParts(request, id) {
    const device = await readDevice(request);
    const generation = readGeneration(request);
    const state = this.#liveState();
    verifyDevice(state, device, generation);
    const existing = state.backups.find(({ backup }) => backup.id === id)?.backup;
    if (existing) return json(existing);
    if (this.storage.kv.get(`used:${id}`)) throw new APIError(409, "backup_id_used");
    const pending = this.#pendingParts(state, id);
    if (pending.parts.includes(null)) throw new APIError(409, "parts_incomplete");
    if (this.completing.has(pending.key)) throw new APIError(409, "upload_in_progress");

    this.completing.add(pending.key);
    try {
      const digest = new crypto.DigestStream("SHA-256");
      let checksum;
      try {
        const [, bytes] = await Promise.all([this.#writeParts(pending, digest), digest.digest]);
        checksum = bytesToHex(bytes);
      } catch (error) {
        this.#verifyReservation(pending.key, device, generation);
        throw error;
      }
      const updated = this.#verifyReservation(pending.key, device, generation);
      if (checksum !== pending.manifest.sha256) throw new APIError(422, "checksum_mismatch");
      const result = this.#commitBackup(updated, pending.manifest, { key: pending.key, parts: pending.parts });
      await this.#scheduleCleanup();
      await this.#removeGarbage().catch(() => {});
      return result;
    } finally {
      this.completing.delete(pending.key);
    }
  }

  async #abortParts(request, id) {
    const device = await readDevice(request);
    const generation = readGeneration(request);
    const state = this.#liveState();
    verifyDevice(state, device, generation);
    if (state.pending && !state.pending.manifest?.id) {
      // Older direct reservations did not record an addressable upload ID. Do not
      // acknowledge a cancellation that cannot fence that still-active writer.
      if (state.pending.expires > Date.now()) throw new APIError(409, "upload_in_progress");
      this.#abandonUpload(state);
      this.#save(state);
      await this.#scheduleCleanup();
    }
    if (state.pending?.manifest?.id === id) {
      this.#abandonUpload(state);
      this.#save(state);
      await this.#scheduleCleanup();
    }
    return noContent();
  }

  #pendingParts(state, id) {
    const pending = state.pending;
    if (pending?.manifest?.id !== id || !pending.parts || pending.expires <= Date.now()) {
      throw new APIError(409, "upload_invalidated");
    }
    return pending;
  }

  async #writePayload(key, request, receipt, allowExisting = false) {
    const checksum = Uint8Array.from(receipt.sha256.match(/../g), (pair) => parseInt(pair, 16));
    let stored;
    try {
      stored = await this.bucket.put(key, request.body, {
        sha256: checksum.buffer,
        onlyIf: { etagDoesNotMatch: "*" },
      });
    } catch (error) {
      if (String(error).includes("10037") || /checksum|sha-?256/i.test(String(error))) {
        throw new APIError(422, "checksum_mismatch");
      }
      throw error;
    }
    // An interrupted R2 response can leave a verified part at its immutable key.
    if (!stored && allowExisting) stored = await this.bucket.head(key);
    if (!matchingObject(stored, receipt)) throw new APIError(422, "checksum_mismatch");
  }

  async #writeParts(entry, target) {
    try {
      for (const [index, receipt] of entry.parts.entries()) {
        const object = await this.bucket.get(partKey(entry.key, index));
        if (!object?.body || !matchingObject(object, receipt)) {
          void object?.body?.cancel().catch(() => {});
          throw new APIError(503, "backup_unavailable");
        }
        await object.body.pipeTo(target, { preventClose: true });
      }
      await target.close();
    } catch (error) {
      await target.abort(error).catch(() => {});
      throw error;
    }
  }

  #commitBackup(state, manifest, entry) {
    if (this.storage.kv.get(`used:${manifest.id}`)) throw new APIError(409, "backup_id_used");
    const backup = { ...manifest, protection: manifest.protection ?? RECOVERY_KEY, createdAt: new Date().toISOString() };
    delete state.pending;
    state.backups.unshift({ ...entry, backup });
    this.#queue(state, state.backups.splice(RETAINED_BACKUPS));
    this.storage.transactionSync(() => {
      this.storage.kv.put(`used:${backup.id}`, true);
      this.#save(state);
    });
    return json(backup, 201);
  }

  #verifyReservation(key, device, generation) {
    const state = this.#liveState();
    verifyDevice(state, device, generation);
    if (state.pending?.key !== key || state.pending.expires <= Date.now()) {
      throw new APIError(409, "upload_invalidated");
    }
    return state;
  }

  async #finishUpload(key, settled) {
    const state = this.#read();
    if (state.pending?.key === key) {
      this.#abandonUpload(state);
      this.#save(state);
    }
    const entry = state.garbage.find((item) => item.key === key);
    if (settled && entry && entry.at > Date.now()) {
      entry.at = Date.now();
      this.#save(state);
    }
    // The metadata update already succeeded. The durable alarm retries deferred R2 deletion.
    await this.#scheduleCleanup();
    await this.#removeGarbage().catch(() => {});
  }

  #queue(state, entries, at = Date.now()) {
    for (const { key, parts } of entries) {
      if (!state.garbage.some((entry) => entry.key === key)) {
        state.garbage.push(parts ? { key, partCount: parts.length, at } : { key, at });
      }
    }
  }

  #abandonUpload(state) {
    if (!state.pending) return;
    const pending = state.pending;
    delete state.pending;
    this.#queue(state, [pending], pending.expires);
  }

  async #deleteBackups(request) {
    const device = await readDevice(request);
    const generation = readGeneration(request);
    const state = this.#liveState();
    verifyDevice(state, device);
    if (generation === state.generation) {
      state.lastDeletionGeneration = generation;
      state.generation += 1;
      await this.#deleteStored(state, request);
    } else if (generation === state.lastDeletionGeneration && state.generation === generation + 1) {
      await this.#cleanDeletedBackups();
    } else {
      throw new APIError(409, "device_conflict");
    }
    return noContent({ "X-Pulse-Generation": String(state.generation) });
  }

  async #deleteAccount(request) {
    // A formerly invited UID may erase its account. An ineligible UID with no state has nothing to erase.
    const existing = this.storage.kv.get("state");
    const eligible = request.headers.get("X-Pulse-Internal-Eligible") === "1";
    if (!existing && !eligible) return noContent();
    const state = existing ?? this.#read();
    state.deleted = true;
    state.purgeUsedIds = true;
    delete state.device;
    delete state.generation;
    delete state.lastDeletionGeneration;
    await this.#deleteStored(state, request);
    this.#removeUsedIds(this.#read());
    return noContent();
  }

  #removeUsedIds(state) {
    const keys = [...this.storage.kv.list({ prefix: "used:", limit: 128 })];
    this.storage.transactionSync(() => {
      for (const [key] of keys) this.storage.kv.delete(key);
      state.purgeUsedIds = keys.length === 128;
      this.#save(state);
    });
  }

  async #deleteStored(state, request) {
    const emailHash = request.headers.get(MIGRATION_EMAIL) ?? "";
    if (!state.migrationClosed && SHA256.test(emailHash)) state.pendingMigrationErase = emailHash;
    state.migrationClosed = true;
    this.#abandonUpload(state);
    this.#queue(state, state.backups);
    state.backups = [];
    this.#save(state);
    await this.#cleanDeletedBackups();
  }

  async #cleanDeletedBackups() {
    await this.#scheduleCleanup();
    try {
      await this.#eraseMigration();
    } finally {
      await this.#removeGarbage();
    }
  }

  async #eraseMigration() {
    const emailHash = this.#read().pendingMigrationErase;
    if (!emailHash) return;
    const migration = await this.#findMigration(emailHash, true);
    const state = this.#read();
    if (state.pendingMigrationErase !== emailHash) return;
    if (migration) this.#queue(state, [{ key: migration.manifestKey }, { key: migration.key }]);
    delete state.pendingMigrationErase;
    this.#save(state);
  }

  async #scheduleCleanup(at = Infinity) {
    const { pending, garbage, purgeUsedIds, pendingMigrationErase } = this.#read();
    const accountCleanup = purgeUsedIds || pendingMigrationErase ? Date.now() : Infinity;
    const next = Math.min(at, accountCleanup, pending?.expires ?? Infinity, ...garbage.map((entry) => entry.at));
    if (!Number.isFinite(next)) return;
    const target = Math.max(next, Date.now() + CLEANUP_RETRY_MS);
    const alarm = await this.storage.getAlarm();
    if (alarm === null || target < alarm) await this.storage.setAlarm(target);
  }

  async #removeGarbage() {
    const state = this.#read();
    const finished = new Set();
    const keys = [];
    for (const { key, partCount, at } of state.garbage) {
      if (at > Date.now()) continue;
      const objects = partCount ? Array.from({ length: partCount }, (_, index) => partKey(key, index)) : [key];
      if (objects.some((object) => this.uploading.has(object))) continue;
      keys.push(...objects);
      finished.add(key);
    }
    if (!finished.size) return;

    for (let start = 0; start < keys.length; start += CLEANUP_BATCH_SIZE) {
      await this.bucket.delete(keys.slice(start, start + CLEANUP_BATCH_SIZE));
    }
    const current = this.#read();
    current.garbage = current.garbage.filter(({ key }) => !finished.has(key));
    this.#save(current);
  }

  async alarm() {
    const state = this.#read();
    if (state.purgeUsedIds) this.#removeUsedIds(state);
    if (state.pending?.expires <= Date.now()) {
      this.#abandonUpload(state);
      this.#save(state);
    }
    try {
      try {
        await this.#eraseMigration();
      } finally {
        await this.#removeGarbage();
      }
    } finally {
      await this.#scheduleCleanup();
    }
  }
}
