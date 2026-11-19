import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import test from "node:test";
import { BackupAccount, DIRECT_BACKUP_BYTES, MAX_BACKUP_BYTES, PART_BYTES } from "../src/backup-account.mjs";
import { BackupMigrationClaim } from "../src/migration-claim.mjs";

const oldDevice = { id: randomUUID(), key: "ab".repeat(32) };
const newDevice = { id: randomUUID(), key: "cd".repeat(32) };
const ciphertext = Buffer.from([1, 87, 46, 214, 2, 63]);
const hash = (data) => createHash("sha256").update(data).digest("hex");

function createStorage() {
  const rows = new Map();
  return {
    alarmAt: null,
    kv: {
      get(key) { return structuredClone(rows.get(key)); },
      put(key, value) { rows.set(key, structuredClone(value)); },
      delete(key) { rows.delete(key); },
      list({ prefix, limit }) {
        return [...rows].filter(([key]) => key.startsWith(prefix)).slice(0, limit);
      },
    },
    transactionSync(operation) { return operation(); },
    async getAlarm() { return this.alarmAt; },
    async setAlarm(at) { this.alarmAt = at; },
  };
}

function harness() {
  const storage = createStorage();
  const owner = hash("first UID");
  const objects = new Map();
  const bucket = {
    async put(key, stream, options) {
      assert.equal(options.onlyIf.etagDoesNotMatch, "*");
      if (objects.has(key)) return null;
      await this.beforePut?.();
      const body = await new Response(stream).arrayBuffer();
      const sha256 = await crypto.subtle.digest("SHA-256", body);
      if (Buffer.compare(Buffer.from(sha256), Buffer.from(options.sha256))) throw new Error("BadDigest (10037)");
      const stored = { size: body.byteLength, body, checksums: { sha256 } };
      objects.set(key, stored);
      await this.afterPut?.();
      return stored;
    },
    async get(key, options) {
      await this.beforeGet?.(key);
      const object = objects.get(key);
      if (!object) return null;
      if (options?.onlyIf.etagMatches !== undefined && options.onlyIf.etagMatches !== object.etag) {
        return { ...object, body: undefined };
      }
      return { ...object, body: new Response(object.body).body };
    },
    async head(key) { return objects.get(key); },
    async delete(keys) {
      await this.beforeDelete?.(keys);
      if (this.failDelete) throw new Error("R2 unavailable");
      for (const key of keys) objects.delete(key);
    },
  };
  const migrations = new Map();
  const migrationClaims = {
    getByName(name) {
      if (!migrations.has(name)) migrations.set(name, createStorage());
      return {
        async fetch(request) {
          await migrationClaims.beforeFetch?.();
          const claim = new BackupMigrationClaim({ storage: migrations.get(name) }, { BACKUPS: bucket });
          const response = await claim.fetch(request);
          await migrationClaims.afterFetch?.(response);
          return response;
        },
      };
    },
  };
  const accounts = new Map([[owner, storage]]);
  function create(accountOwner = owner) {
    if (!accounts.has(accountOwner)) accounts.set(accountOwner, createStorage());
    const ctx = { id: { toString: () => accountOwner }, storage: accounts.get(accountOwner), waitUntil() {} };
    return new BackupAccount(ctx, { BACKUPS: bucket, MIGRATION_CLAIMS: migrationClaims });
  }
  return { bucket, objects, storage, migrationClaims, create };
}

function send(account, method, path, { body, device, headers = {} } = {}) {
  if (device) {
    headers = { "X-Pulse-Device-ID": device.id, "X-Pulse-Device-Key": device.key, ...headers };
  }
  return account.fetch(new Request(`https://pulse.example/v1/${path}`, { method, headers, body }));
}

function claim(account, device, expectedGeneration) {
  return send(account, "POST", "device/claim", { device, body: JSON.stringify({ expectedGeneration }) });
}

function put(account, id, { device = oldDevice, generation = 1, headers = {}, body = ciphertext } = {}) {
  return send(account, "PUT", `backups/${id}`, {
    device,
    body,
    headers: { "Content-Length": body.length, "X-Pulse-SHA256": hash(body), "X-Pulse-Generation": generation, ...headers },
  });
}

async function state(account, headers) {
  const response = await send(account, "GET", "state", { headers });
  assert.equal(response.status, 200);
  return response.json();
}

async function expectError(response, status, error) {
  assert.equal(response.status, status);
  assert.deepEqual(await response.json(), { error });
}

test("only verified ciphertext is visible, IDs are immutable, and retention keeps seven", async () => {
  const setup = harness();
  const account = setup.create();
  assert.deepEqual(await state(account), {
    activeDeviceId: null, generation: 0, backups: [], maxBackupBytes: MAX_BACKUP_BYTES,
    supportedBackupProtections: ["recoveryKey", "account"],
  });
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const ids = Array.from({ length: 8 }, () => randomUUID());

  await expectError(await put(account, ids[0], { headers: { "X-Pulse-SHA256": "00".repeat(32) } }), 422, "checksum_mismatch");
  await expectError(await put(account, ids[0], { headers: { "Content-Length": DIRECT_BACKUP_BYTES + 1 } }), 413, "backup_too_large");
  await expectError(await put(account, ids[0], { headers: { "Content-Length": ciphertext.length + 1 } }), 422, "checksum_mismatch");
  assert.equal(setup.objects.size, 0);
  assert.equal((await state(account)).backups.length, 0);
  for (const id of ids) assert.equal((await put(account, id)).status, 201);
  const expected = [...ids].reverse().slice(0, 7);
  await expectError(await put(account, randomUUID(), { headers: { "X-Pulse-SHA256": "ff".repeat(32) } }), 422, "checksum_mismatch");
  assert.deepEqual((await state(account)).backups.map((item) => item.id), expected);
  assert.equal(setup.objects.size, 7);

  const restored = await send(account, "GET", `backups/${ids[7]}`);
  assert.equal(restored.headers.get("X-Pulse-SHA256"), hash(ciphertext));
  assert.equal(restored.headers.get("Cache-Control"), "no-store");
  assert.deepEqual(Buffer.from(await restored.arrayBuffer()), ciphertext);
  await expectError(await send(account, "GET", `backups/${ids[0]}`), 404, "backup_not_found");
  // The client missed the commit response and retries the identical file after an object restart.
  const replay = await put(setup.create(), ids[7]);
  assert.equal(replay.status, 200);
  assert.deepEqual(await replay.json(), (await state(account)).backups[0]);
  await expectError(await put(account, ids[7], { body: Buffer.from("different") }), 409, "backup_id_used");
  await expectError(await put(account, ids[0]), 409, "backup_id_used");
});

test("device takeover fences a writer already streaming and prevents impersonation", async () => {
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const started = Promise.withResolvers();
  const release = Promise.withResolvers();
  setup.bucket.beforePut = () => { started.resolve(); return release.promise; };
  const slowUpload = put(account, randomUUID());
  await started.promise;

  await expectError(await claim(account, newDevice, 0), 409, "device_conflict");
  const adopted = await claim(account, newDevice, 1);
  assert.equal((await adopted.json()).generation, 2);
  const copiedId = { id: newDevice.id, key: oldDevice.key };
  await expectError(await claim(account, copiedId, 2), 409, "device_conflict");
  await expectError(await put(account, randomUUID(), { device: copiedId, generation: 2 }), 409, "device_conflict");
  release.resolve();
  await expectError(await slowUpload, 409, "device_conflict");
  assert.equal(setup.objects.size, 0);
  const current = await put(account, randomUUID(), { device: newDevice, generation: 2 });
  assert.equal(current.status, 201);
});

test("backup deletion fences an in-flight snapshot and account deletion prevents replay", async () => {
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const first = randomUUID();
  assert.equal((await put(account, first)).status, 201);
  const started = Promise.withResolvers();
  const release = Promise.withResolvers();
  setup.bucket.beforePut = () => { started.resolve(); return release.promise; };
  const slowUpload = put(account, randomUUID());
  await started.promise;

  const wipe = await send(account, "DELETE", "backups", { device: oldDevice, headers: { "X-Pulse-Generation": "1" } });
  assert.equal(wipe.status, 204);
  assert.equal(wipe.headers.get("X-Pulse-Generation"), "2");
  assert.equal(setup.objects.size, 0);
  release.resolve();
  await expectError(await slowUpload, 409, "device_conflict");
  assert.deepEqual((await state(account)).backups, []);
  assert.equal(setup.objects.size, 0);
  await expectError(await put(account, randomUUID()), 409, "device_conflict");
  await expectError(await put(account, first, { generation: 2 }), 409, "backup_id_used");
  const afterDeletion = randomUUID();
  assert.equal((await put(account, afterDeletion, { generation: 2 })).status, 201);
  const replay = await send(account, "DELETE", "backups", { device: oldDevice, headers: { "X-Pulse-Generation": "1" } });
  assert.equal(replay.status, 204);
  assert.equal(replay.headers.get("X-Pulse-Generation"), "2");
  assert.equal((await state(account)).backups[0].id, afterDeletion);

  assert.equal((await send(account, "DELETE", "account")).status, 204);
  assert.equal((await send(account, "DELETE", "account")).status, 204);
  assert.equal(setup.objects.size, 0);
  assert.equal(setup.storage.kv.list({ prefix: "used:", limit: 10 }).length, 0);
  await expectError(await claim(account, oldDevice, 0), 410, "account_deleted");
  await expectError(await send(account, "GET", "state"), 410, "account_deleted");
});

test("the alarm deletes orphaned bytes and retries removals across object restarts", async () => {
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  setup.bucket.afterPut = async () => { throw new Error("R2 connection reset after write"); };
  await expectError(await put(account, randomUUID()), 503, "service_unavailable");
  assert.equal(setup.objects.size, 1);
  const persisted = setup.storage.kv.get("state");
  persisted.garbage[0].at = Date.now() - 1;
  setup.storage.kv.put("state", persisted);

  setup.storage.alarmAt = null;
  setup.bucket.failDelete = true;
  await assert.rejects(setup.create().alarm(), /R2 unavailable/);
  assert.ok(setup.storage.alarmAt > Date.now());
  assert.equal(setup.objects.size, 1);

  setup.bucket.failDelete = false;
  await setup.create().alarm();
  assert.equal(setup.objects.size, 0);
  assert.deepEqual(setup.storage.kv.get("state").garbage, []);
});

test("account deletion cannot be undone by an R2 write that completes afterwards", async () => {
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const started = Promise.withResolvers();
  const release = Promise.withResolvers();
  setup.bucket.beforePut = () => { started.resolve(); return release.promise; };
  const slowUpload = put(account, randomUUID());
  await started.promise;
  assert.equal((await send(account, "DELETE", "account")).status, 204);
  release.resolve();
  await expectError(await slowUpload, 410, "account_deleted");
  assert.equal(setup.objects.size, 0);
  await expectError(await send(setup.create(), "GET", "state"), 410, "account_deleted");
});

test("account deletion leaves no state for a never-invited UID and fences an invited UID", async () => {
  const setup = harness();
  const account = setup.create();
  assert.equal((await send(account, "DELETE", "account")).status, 204);
  assert.equal(setup.storage.kv.get("state"), undefined);

  const invited = { "X-Pulse-Internal-Eligible": "1" };
  assert.equal((await send(account, "DELETE", "account", { headers: invited })).status, 204);
  await expectError(await claim(account, oldDevice, 0), 410, "account_deleted");
});

const emailHash = hash("owner@example.net");
const migrationHeaders = { "X-Pulse-Internal-Migration-Email": emailHash };

function stage({ objects }, options = {}) {
  const backup = { id: randomUUID(), createdAt: "2020-01-01T00:00:00.000Z", sha256: hash(ciphertext), size: ciphertext.length };
  const manifestKey = `migrations/inbox/${emailHash}.json`;
  const key = `migrations/objects/${backup.id}.bin`;
  const manifest = Buffer.from(JSON.stringify({ version: 1, emailHash, ...backup, ...options.manifest }));
  objects.set(manifestKey, { size: manifest.length, body: manifest });
  objects.set(key, {
    size: ciphertext.length,
    body: ciphertext,
    etag: "test-etag",
    version: "staged-version",
    checksums: options.stream ? {} : { sha256: Buffer.from(backup.sha256, "hex") },
  });
  return { backup, key, manifestKey };
}

test("only the matching verified address can claim across UIDs, and the chosen UID can restore", async () => {
  const setup = harness();
  const first = setup.create();
  const second = setup.create(hash("second UID"));
  const staged = stage(setup);
  assert.deepEqual((await state(first)).backups, []);
  const wrongEmail = { "X-Pulse-Internal-Migration-Email": hash("other@example.net") };
  assert.deepEqual((await state(second, wrongEmail)).backups, []);
  assert.ok(setup.objects.has(staged.manifestKey));

  const snapshots = await Promise.all([state(first, migrationHeaders), state(second, migrationHeaders)]);
  const winner = snapshots.findIndex((result) => result.backups.length === 1);
  assert.ok(winner >= 0);
  assert.deepEqual(snapshots[winner].backups, [staged.backup]);
  assert.deepEqual(snapshots[1 - winner].backups, []);
  assert.equal(snapshots[winner].generation, 0);
  assert.equal(snapshots[winner].activeDeviceId, null);
  assert.equal(setup.objects.has(staged.manifestKey), false);

  const accounts = [first, second];
  const result = await send(accounts[winner], "GET", `backups/${staged.backup.id}`);
  assert.equal(result.headers.get("X-Pulse-SHA256"), staged.backup.sha256);
  assert.equal(result.headers.get("X-Pulse-Backup-Protection"), "recoveryKey");
  assert.deepEqual(Buffer.from(await result.arrayBuffer()), ciphertext);
  await expectError(await send(accounts[1 - winner], "GET", `backups/${staged.backup.id}`), 404, "backup_not_found");
});

test("a claim can resume once after a lost response and even a re-staged manifest cannot bind another UID", async () => {
  const setup = harness();
  const account = setup.create();
  const other = setup.create(hash("second UID"));
  const staged = stage(setup);
  const savedManifest = setup.objects.get(staged.manifestKey);
  setup.migrationClaims.afterFetch = async () => { throw new Error("response lost after claim"); };
  await expectError(await send(account, "GET", "state", { headers: migrationHeaders }), 503, "service_unavailable");
  setup.migrationClaims.afterFetch = undefined;
  assert.deepEqual((await state(other, migrationHeaders)).backups, []);
  assert.deepEqual((await state(setup.create(), migrationHeaders)).backups, [staged.backup]);
  assert.deepEqual((await state(account, migrationHeaders)).backups, [staged.backup]);
  assert.equal(setup.objects.has(staged.manifestKey), false);

  assert.equal((await send(account, "DELETE", "account")).status, 204);
  assert.equal(setup.objects.has(staged.key), false);
  setup.objects.set(staged.manifestKey, savedManifest);
  await expectError(await send(account, "GET", "state", { headers: migrationHeaders }), 410, "account_deleted");
  assert.deepEqual((await state(other, migrationHeaders)).backups, []);
});

function mockDigestStream(t) {
  // Cloudflare's DigestStream is available in production. Use Node's stream and hash primitives here.
  class DigestStream extends WritableStream {
    constructor(algorithm) {
      assert.equal(algorithm, "SHA-256");
      const hasher = createHash("sha256");
      const digest = Promise.withResolvers();
      super({
        write(chunk) { hasher.update(chunk); },
        close() { digest.resolve(hasher.digest()); },
        abort(cause) { digest.reject(cause); },
      });
      this.digest = digest.promise;
    }
  }
  Object.defineProperty(crypto, "DigestStream", { value: DigestStream, configurable: true });
  t.after(() => { delete crypto.DigestStream; });
}

test("migration rejects invalid manifests and streams a digest for a CLI object without SHA metadata", async (t) => {
  mockDigestStream(t);
  const setup = harness();
  const account = setup.create();
  const staged = stage(setup, { stream: true, manifest: { emailHash: hash("wrong@example.net") } });
  await expectError(await send(account, "GET", "state", { headers: migrationHeaders }), 503, "migration_unavailable");

  const manifest = Buffer.from(JSON.stringify({ version: 1, emailHash, ...staged.backup }));
  setup.objects.set(staged.manifestKey, { size: manifest.length, body: manifest });
  setup.objects.get(staged.key).body = Buffer.alloc(ciphertext.length);
  await expectError(await send(account, "GET", "state", { headers: migrationHeaders }), 503, "migration_unavailable");
  setup.objects.get(staged.key).body = ciphertext;
  assert.deepEqual((await state(account, migrationHeaders)).backups, [staged.backup]);

  setup.objects.get(staged.key).version = "replaced-version";
  await expectError(await send(account, "GET", `backups/${staged.backup.id}`), 503, "backup_unavailable");
});

test("deleting backups fences an in-flight migration and preserves the generation on retries", async () => {
  const setup = harness();
  const account = setup.create();
  const staged = stage(setup);
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const claimed = Promise.withResolvers();
  const release = Promise.withResolvers();
  setup.migrationClaims.afterFetch = async () => {
    setup.migrationClaims.afterFetch = undefined;
    claimed.resolve();
    await release.promise;
  };
  const reading = state(account, migrationHeaders);
  await claimed.promise;

  async function wipe() {
    const result = await send(account, "DELETE", "backups", {
      device: oldDevice, headers: { ...migrationHeaders, "X-Pulse-Generation": "1" },
    });
    assert.equal(result.status, 204);
    assert.equal(result.headers.get("X-Pulse-Generation"), "2");
  }
  await wipe();
  assert.equal(setup.objects.has(staged.key), false);
  assert.equal(setup.objects.has(staged.manifestKey), false);
  release.resolve();
  assert.deepEqual((await reading).backups, []);
  await wipe();
  assert.deepEqual((await state(setup.create(), migrationHeaders)).backups, []);
  assert.deepEqual((await state(setup.create(hash("second UID")), migrationHeaders)).backups, []);
});

test("account deletion closes untouched migrations and retries erasure after a dependency fails", async () => {
  const setup = harness();
  const account = setup.create();
  const staged = stage(setup);
  const headers = { ...migrationHeaders, "X-Pulse-Internal-Eligible": "1" };
  setup.migrationClaims.beforeFetch = async () => { throw new Error("migration store unavailable"); };
  await expectError(await send(account, "DELETE", "account", { headers }), 503, "service_unavailable");
  assert.ok(setup.storage.alarmAt > Date.now());
  assert.equal(setup.objects.has(staged.key), true);
  await expectError(await send(account, "GET", "state", { headers }), 410, "account_deleted");

  setup.migrationClaims.beforeFetch = undefined;
  await setup.create().alarm();
  assert.equal(setup.objects.size, 0);
  assert.equal(setup.storage.kv.get("state").pendingMigrationErase, undefined);
  assert.equal((await send(account, "DELETE", "account", { headers })).status, 204);
  assert.deepEqual((await state(setup.create(hash("second UID")), migrationHeaders)).backups, []);
});

test("adoption follows the seven-snapshot retention rule and removes expired staged bytes", async () => {
  const setup = harness();
  const account = setup.create();
  const staged = stage(setup);
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const ids = Array.from({ length: 7 }, () => randomUUID());
  for (const id of ids) assert.equal((await put(account, id)).status, 201);
  assert.deepEqual((await state(account, migrationHeaders)).backups.map(({ id }) => id), ids.reverse());
  assert.equal(setup.objects.size, 7);
  await expectError(await send(account, "GET", `backups/${staged.backup.id}`), 404, "backup_not_found");
});

function startParts(account, id, { size, sha256, protection }, device = oldDevice, generation = 1) {
  return send(account, "POST", `backups/${id}/parts`, {
    device,
    headers: { "X-Pulse-Generation": generation },
    body: JSON.stringify({ size, sha256, protection }),
  });
}

function putPart(account, id, index, body, { sha256 = hash(body), device = oldDevice, generation = 1 } = {}) {
  return send(account, "PUT", `backups/${id}/parts/${index}`, {
    device,
    headers: { "X-Pulse-Generation": generation, "Content-Length": body.length, "X-Pulse-SHA256": sha256 },
    body,
  });
}

function completeParts(account, id, device = oldDevice, generation = 1) {
  return send(account, "POST", `backups/${id}/parts/complete`, { device, headers: { "X-Pulse-Generation": generation } });
}

function abortParts(account, id, device = oldDevice, generation = 1) {
  return send(account, "DELETE", `backups/${id}/parts`, { device, headers: { "X-Pulse-Generation": generation } });
}

test("parts are verified and replayable, and completion publishes the exact ordered ciphertext", async (t) => {
  mockDigestStream(t);
  globalThis.FixedLengthStream = class extends TransformStream { constructor() { super(); } };
  t.after(() => { delete globalThis.FixedLengthStream; });
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const id = randomUUID();
  const first = Buffer.alloc(PART_BYTES, 3);
  const expected = Buffer.concat([first, ciphertext]);
  const manifest = { size: expected.length, sha256: hash(expected) };

  await expectError(await startParts(account, id, { ...manifest, size: MAX_BACKUP_BYTES + 1 }), 413, "backup_too_large");
  const start = await startParts(account, id, manifest);
  assert.equal(start.status, 200);
  assert.deepEqual(await start.json(), { partSize: PART_BYTES, totalParts: 2, receivedParts: [] });
  await expectError(await startParts(account, randomUUID(), manifest), 409, "upload_in_progress");
  await expectError(await putPart(account, id, 2, ciphertext), 400, "invalid_part");
  await expectError(await putPart(account, id, 0, ciphertext), 422, "invalid_part_size");
  await expectError(await putPart(account, id, 1, ciphertext, { sha256: "00".repeat(32) }), 422, "checksum_mismatch");
  assert.equal((await putPart(account, id, 1, ciphertext)).status, 204);
  assert.equal((await putPart(setup.create(), id, 1, ciphertext)).status, 204);
  await expectError(await putPart(account, id, 1, Buffer.alloc(ciphertext.length)), 409, "part_already_uploaded");
  assert.deepEqual((await (await startParts(account, id, manifest)).json()).receivedParts, [1]);
  await expectError(await completeParts(account, id), 409, "parts_incomplete");
  await expectError(await send(account, "GET", `backups/${id}`), 404, "backup_not_found");
  assert.deepEqual((await state(account)).backups, []);

  setup.bucket.afterPut = async () => { throw new Error("response lost after R2 write"); };
  await expectError(await putPart(account, id, 0, first), 503, "service_unavailable");
  setup.bucket.afterPut = undefined;
  assert.deepEqual((await (await startParts(account, id, manifest)).json()).receivedParts, [1]);
  assert.equal((await putPart(setup.create(), id, 0, first)).status, 204);
  assert.deepEqual((await (await startParts(account, id, manifest)).json()).receivedParts, [0, 1]);

  const committed = await completeParts(account, id);
  assert.equal(committed.status, 201);
  const record = await committed.json();
  assert.deepEqual((await state(account)).backups, [record]);
  assert.deepEqual(await (await completeParts(setup.create(), id)).json(), record);
  assert.deepEqual((await (await startParts(account, id, manifest)).json()).backup, record);
  assert.equal((await putPart(account, id, 1, ciphertext)).status, 204);
  assert.equal((await abortParts(account, id)).status, 204);
  const downloaded = await send(account, "GET", `backups/${id}`);
  assert.equal(downloaded.headers.get("Content-Length"), String(expected.length));
  assert.equal(downloaded.headers.get("X-Pulse-SHA256"), manifest.sha256);
  assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), expected);

  for (let index = 0; index < 7; index++) assert.equal((await put(account, randomUUID())).status, 201);
  assert.equal(setup.objects.size, 7);
  await expectError(await send(account, "GET", `backups/${id}`), 404, "backup_not_found");
  await expectError(await startParts(account, id, manifest), 409, "backup_id_used");
});

test("whole-file digest failures stay pending until abort, and the alarm clears all orphaned part keys", async (t) => {
  mockDigestStream(t);
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const id = randomUUID();
  const wrongManifest = { size: ciphertext.length, sha256: "00".repeat(32) };
  assert.equal((await startParts(account, id, wrongManifest)).status, 200);
  assert.equal((await putPart(account, id, 0, ciphertext)).status, 204);
  await expectError(await completeParts(account, id), 422, "checksum_mismatch");
  assert.deepEqual((await state(account)).backups, []);
  assert.equal((await abortParts(account, id)).status, 204);
  assert.equal((await abortParts(account, id)).status, 204);

  const newId = randomUUID();
  const manifest = { size: ciphertext.length, sha256: hash(ciphertext) };
  assert.equal((await startParts(account, newId, manifest)).status, 200);
  assert.equal((await putPart(account, newId, 0, ciphertext)).status, 204);
  assert.equal((await completeParts(account, newId)).status, 201);
  assert.equal(setup.objects.size, 2);
  const persisted = setup.storage.kv.get("state");
  persisted.garbage[0].at = Date.now() - 1;
  setup.storage.kv.put("state", persisted);
  await setup.create().alarm();
  assert.equal(setup.objects.size, 1);
  assert.equal((await send(account, "DELETE", "account")).status, 204);
  assert.equal(setup.objects.size, 0);
  await expectError(await completeParts(account, newId), 410, "account_deleted");
});

test("backup deletion fences a part already streaming and device takeover fences completion", async (t) => {
  mockDigestStream(t);
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const manifest = { size: ciphertext.length, sha256: hash(ciphertext) };
  const id = randomUUID();
  assert.equal((await startParts(account, id, manifest)).status, 200);
  const writing = Promise.withResolvers();
  const finishWrite = Promise.withResolvers();
  setup.bucket.beforePut = () => { writing.resolve(); return finishWrite.promise; };
  const part = putPart(account, id, 0, ciphertext);
  await writing.promise;
  assert.equal((await send(account, "DELETE", "backups", {
    device: oldDevice, headers: { "X-Pulse-Generation": "1" },
  })).status, 204);
  finishWrite.resolve();
  await expectError(await part, 409, "device_conflict");
  setup.bucket.beforePut = undefined;
  assert.deepEqual((await state(account)).backups, []);

  const nextId = randomUUID();
  assert.equal((await startParts(account, nextId, manifest, oldDevice, 2)).status, 200);
  assert.equal((await putPart(account, nextId, 0, ciphertext, { generation: 2 })).status, 204);
  const reading = Promise.withResolvers();
  const finishRead = Promise.withResolvers();
  setup.bucket.beforeGet = () => { reading.resolve(); return finishRead.promise; };
  const completing = completeParts(account, nextId, oldDevice, 2);
  await reading.promise;
  assert.equal((await claim(account, newDevice, 2)).status, 200);
  finishRead.resolve();
  await expectError(await completing, 409, "device_conflict");
  assert.deepEqual((await state(account)).backups, []);
});

test("orphaned large reservations apply byte-based backpressure and use bounded cleanup batches", async () => {
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const manifest = { size: MAX_BACKUP_BYTES, sha256: "ca".repeat(32) };
  for (let index = 0; index < 5; index++) {
    const id = randomUUID();
    const started = await startParts(account, id, manifest);
    assert.equal(started.status, 200);
    assert.equal((await started.json()).totalParts, 32);
    assert.equal((await abortParts(account, id)).status, 204);
  }
  const next = randomUUID();
  await expectError(await startParts(account, next, manifest), 503, "cleanup_pending");
  const persisted = setup.storage.kv.get("state");
  for (const entry of persisted.garbage) entry.at = Date.now() - 1;
  setup.storage.kv.put("state", persisted);
  const batches = [];
  setup.bucket.beforeDelete = (keys) => { batches.push(keys.length); };
  await setup.create().alarm();
  assert.deepEqual(batches, [128, 32]);
  assert.equal((await startParts(account, next, manifest)).status, 200);
});

test("legacy records and in-flight multipart uploads default to recovery-key protection", async (t) => {
  mockDigestStream(t);
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const directId = randomUUID();
  const multipartId = randomUUID();
  const manifest = { size: ciphertext.length, sha256: hash(ciphertext) };
  const direct = await put(account, directId);
  assert.equal(direct.status, 201);
  assert.equal((await direct.json()).protection, "recoveryKey");
  assert.equal((await startParts(account, multipartId, manifest)).status, 200);

  // Emulate the JSON persisted by v441 before protection was stored on either record.
  const legacyState = setup.storage.kv.get("state");
  const legacyRecord = legacyState.backups[0].backup;
  delete legacyRecord.protection;
  delete legacyState.pending.manifest.protection;
  setup.storage.kv.put("state", legacyState);
  const restarted = setup.create();
  assert.deepEqual((await state(restarted)).backups, [legacyRecord]);
  assert.deepEqual(await (await put(restarted, directId)).json(), legacyRecord);
  assert.deepEqual(await (await put(restarted, directId, {
    headers: { "X-Pulse-Backup-Protection": "recoveryKey" },
  })).json(), legacyRecord);
  await expectError(await put(restarted, directId, {
    headers: { "X-Pulse-Backup-Protection": "account" },
  }), 409, "backup_id_used");
  await expectError(await startParts(restarted, directId, { ...manifest, protection: "account" }), 409, "backup_id_used");
  const download = await send(restarted, "GET", `backups/${directId}`);
  assert.equal(download.headers.get("X-Pulse-Backup-Protection"), "recoveryKey");
  assert.deepEqual(Buffer.from(await download.arrayBuffer()), ciphertext);

  assert.equal((await startParts(restarted, multipartId, manifest)).status, 200);
  await expectError(await startParts(restarted, multipartId, { ...manifest, protection: "account" }), 409, "backup_id_used");
  assert.equal((await putPart(restarted, multipartId, 0, ciphertext)).status, 204);
  assert.equal((await (await completeParts(restarted, multipartId)).json()).protection, "recoveryKey");
});

test("direct and multipart uploads retain both explicit modes with matching downloads and replay", async (t) => {
  mockDigestStream(t);
  globalThis.FixedLengthStream = class extends TransformStream { constructor() { super(); } };
  t.after(() => { delete globalThis.FixedLengthStream; });
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const records = [];
  for (const protection of ["account", "recoveryKey"]) {
    const alternate = protection === "account" ? "recoveryKey" : "account";
    const id = randomUUID();
    const headers = { "X-Pulse-Backup-Protection": protection };
    const direct = await put(account, id, { headers });
    assert.equal(direct.status, 201);
    const directRecord = await direct.json();
    assert.equal(directRecord.protection, protection);
    assert.deepEqual(await (await put(account, id, { headers })).json(), directRecord);
    await expectError(await put(account, id, {
      headers: { "X-Pulse-Backup-Protection": alternate },
    }), 409, "backup_id_used");
    records.push(directRecord);

    const multipartId = randomUUID();
    const manifest = { size: ciphertext.length, sha256: hash(ciphertext), protection };
    assert.equal((await startParts(account, multipartId, manifest)).status, 200);
    await expectError(await startParts(account, multipartId, { ...manifest, protection: alternate }), 409, "backup_id_used");
    assert.equal((await putPart(account, multipartId, 0, ciphertext)).status, 204);
    const complete = await completeParts(account, multipartId);
    assert.equal(complete.status, 201);
    const record = await complete.json();
    assert.equal(record.protection, protection);
    assert.deepEqual((await (await startParts(account, multipartId, manifest)).json()).backup, record);
    await expectError(await startParts(account, multipartId, { ...manifest, protection: alternate }), 409, "backup_id_used");
    assert.deepEqual(await (await completeParts(account, multipartId)).json(), record);
    records.push(record);

    for (const backup of [directRecord, record]) {
      const result = await send(account, "GET", `backups/${backup.id}`);
      assert.equal(result.status, 200);
      assert.equal(result.headers.get("X-Pulse-Backup-Protection"), protection);
      assert.equal(result.headers.get("X-Pulse-SHA256"), manifest.sha256);
      assert.equal(result.headers.get("Cache-Control"), "no-store");
      assert.deepEqual(Buffer.from(await result.arrayBuffer()), ciphertext);
    }
  }

  for (let i = 0; i < 4; i++) records.push(await (await put(account, randomUUID())).json());
  assert.deepEqual((await state(account)).backups, records.slice(-7).reverse());
  assert.equal(setup.objects.size, 7);
  await expectError(await send(account, "GET", `backups/${records[0].id}`), 404, "backup_not_found");
  assert.equal((await send(account, "DELETE", "account")).status, 204);
  assert.equal(setup.objects.size, 0);
});

test("rejects unknown and ambiguous protection values without reserving or storing a file", async () => {
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const id = randomUUID();
  for (const protection of ["", "RecoveryKey", "account, account", "account, recoveryKey"]) {
    await expectError(await put(account, id, { headers: { "X-Pulse-Backup-Protection": protection } }), 400, "invalid_protection");
  }
  const manifest = { size: ciphertext.length, sha256: hash(ciphertext) };
  for (const protection of [null, true, "", "unknown", ["account"], {}]) {
    await expectError(await startParts(account, id, { ...manifest, protection }), 400, "invalid_protection");
  }
  const manifestPrefix = JSON.stringify(manifest).slice(0, -1);
  for (const key of ["protection", "prote\\u0063tion"]) {
    await expectError(await send(account, "POST", `backups/${id}/parts`, {
      device: oldDevice,
      headers: { "X-Pulse-Generation": "1" },
      body: `${manifestPrefix},"protection":"account","${key}":"recoveryKey"}`,
    }), 400, "invalid_protection");
  }
  assert.equal(setup.objects.size, 0);
  assert.equal(setup.storage.kv.get("state").pending, undefined);
});

test("canceling a matching pending direct upload prevents finalization and keeps other IDs untouched", async () => {
  const setup = harness();
  const account = setup.create();
  assert.equal((await claim(account, oldDevice, 0)).status, 200);
  const id = randomUUID();
  const waiting = Promise.withResolvers();
  const release = Promise.withResolvers();
  setup.bucket.beforePut = () => { waiting.resolve(); return release.promise; };
  const writing = put(account, id);
  await waiting.promise;
  const manifest = { size: ciphertext.length, sha256: hash(ciphertext) };
  await expectError(await startParts(account, id, manifest), 409, "upload_in_progress");
  await expectError(await startParts(account, id, { ...manifest, protection: "account" }), 409, "backup_id_used");
  assert.equal((await abortParts(account, randomUUID())).status, 204);
  assert.equal(setup.storage.kv.get("state").pending.manifest.id, id);
  assert.equal((await abortParts(account, id)).status, 204);
  assert.equal((await abortParts(account, id)).status, 204);
  release.resolve();
  await expectError(await writing, 409, "upload_invalidated");
  assert.equal(setup.objects.size, 0);
  assert.deepEqual((await state(account)).backups, []);
});

test("legacy direct uploads cannot be falsely acknowledged as canceled before their lease expires", async () => {
  const setup = harness();
  const account = setup.create();
  await claim(account, oldDevice, 0);
  const original = setup.storage.kv.get("state");
  original.pending = { key: "legacy-direct", expires: Date.now() + 60_000 };
  setup.storage.kv.put("state", original);
  await expectError(await abortParts(account, randomUUID()), 409, "upload_in_progress");
  assert.equal(setup.storage.kv.get("state").pending.key, "legacy-direct");
  original.pending.expires = Date.now() - 1;
  setup.storage.kv.put("state", original);
  assert.equal((await abortParts(account, randomUUID())).status, 204);
  assert.equal(setup.storage.kv.get("state").pending, undefined);
  assert.deepEqual((await state(account)).backups, []);
});
