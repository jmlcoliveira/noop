import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, createPrivateKey, sign } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import worker from "../src/index.mjs";

function signingFixture() {
  const folder = mkdtempSync(join(tmpdir(), "pulse-worker-cert-"));
  try {
    const keyFile = join(folder, "key.pem");
    const certFile = join(folder, "cert.pem");
    execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=Pulse test",
      "-keyout", keyFile, "-out", certFile, "-days", "1"], { stdio: "ignore" });
    return { key: createPrivateKey(readFileSync(keyFile)), cert: readFileSync(certFile, "utf8") };
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
}

test("the Worker enforces Firebase signature, claim, invitation, and recent-auth gates", async (t) => {
  const { key, cert } = signingFixture();
  let downloads = 0;
  t.mock.method(globalThis, "fetch", async (url, options) => {
    assert.equal(url, "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com");
    assert.equal(options.redirect, "manual");
    downloads++;
    return Response.json({ valid: cert }, { headers: { "Cache-Control": "public, max-age=600", Age: "300" } });
  });
  const now = Math.floor(Date.now() / 1000);
  const env = {
    FIREBASE_PROJECT_ID: "pulse-test",
    ALLOWED_FIREBASE_UIDS: "owner-by-uid",
    ALLOWED_FIREBASE_EMAILS: " test@example.net, ",
    ACCOUNTS: {
      getByName(name) {
        return {
          fetch(request) {
            assert.equal(request.headers.get("Authorization"), null);
            const reply = {
              name,
              method: request.method,
              migrationEmailHash: request.headers.get("X-Pulse-Internal-Migration-Email"),
            };
            if (request.method === "DELETE") reply.eligible = request.headers.get("X-Pulse-Internal-Eligible") === "1";
            return Response.json(reply);
          },
        };
      },
    },
  };
  const encodeJSON = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  function token(claims = {}, header = {}) {
    const body = `${encodeJSON({ alg: "RS256", kid: "valid", ...header })}.${encodeJSON({
      aud: "pulse-test",
      iss: "https://securetoken.google.com/pulse-test",
      sub: "owner-by-email",
      iat: now - 20,
      exp: now + 1000,
      auth_time: now - 30,
      email: "Test@example.net",
      email_verified: true,
      firebase: { sign_in_provider: "password" },
      ...claims,
    })}`;
    return `${body}.${sign("sha256", Buffer.from(body), key).toString("base64url")}`;
  }

  async function check(expected, {
    status = 200, bearer = token(), method = "GET", path = "state", settings = env,
    migrationEmail = "test@example.net",
  } = {}) {
    const request = new Request(`https://pulse.example/v1/${path}`, {
      method,
      headers: {
        ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}),
        "X-Pulse-Internal-Eligible": "1",
        "X-Pulse-Internal-Migration-Email": "00".repeat(32),
      },
    });
    const response = await worker.fetch(request, settings);
    assert.equal(response.status, status);
    const { migrationEmailHash, ...result } = await response.json();
    assert.deepEqual(result, expected);
    if (expected.name) {
      const expectedHash = migrationEmail ? createHash("sha256").update(migrationEmail).digest("hex") : null;
      assert.equal(migrationEmailHash, expectedHash);
    }
  }

  await check({ error: "unauthorized" }, { status: 401, bearer: null });
  const insecure = await worker.fetch(new Request("http://pulse.example/v1/state", {
    headers: { Authorization: `Bearer ${token()}` },
  }), env);
  assert.equal(insecure.status, 400);
  assert.deepEqual(await insecure.json(), { error: "https_required" });
  await check({ name: "pulse-test:owner-by-email", method: "GET" });
  await check({ name: "pulse-test:owner-by-uid", method: "GET" }, {
    bearer: token({ sub: "owner-by-uid", email: "other@example.net" }), migrationEmail: "other@example.net",
  });
  await check({ error: "email_not_verified" }, { status: 403, bearer: token({ email_verified: false }) });
  await check({ error: "not_allowlisted" }, { status: 403, bearer: token({ email: "other@example.net" }) });
  await check({ error: "not_allowlisted" }, { status: 403, settings: { ...env, ALLOWED_FIREBASE_EMAILS: "", ALLOWED_FIREBASE_UIDS: "" } });
  const google = token({ email: "  TEST@example.net ", firebase: { sign_in_provider: "google.com" } });
  await check({ name: "pulse-test:owner-by-email", method: "GET" }, { bearer: google });
  await check({ name: "pulse-test:owner-by-email", method: "GET" }, {
    bearer: google, path: "backups/abc", migrationEmail: null,
  });
  await check({ error: "provider_not_allowed" }, { status: 403, bearer: token({ firebase: { sign_in_provider: "github.com" } }) });
  await check({ error: "unauthorized" }, { status: 401, bearer: token({ aud: "different-project" }) });
  await check({ error: "unauthorized" }, { status: 401, bearer: token({ iss: "https://bad.example" }) });
  await check({ error: "unauthorized" }, { status: 401, bearer: token({ user_id: "different-uid" }) });
  await check({ error: "unauthorized" }, { status: 401, bearer: token({ exp: now - 1 }) });
  await check({ error: "unauthorized" }, { status: 401, bearer: token({ iat: now + 100 }) });
  await check({ error: "unauthorized" }, { status: 401, bearer: token({}, { alg: "none" }) });
  await check({ error: "unauthorized" }, { status: 401, bearer: token({}, { kid: "unknown" }) });
  const [header, claims, signature] = token().split(".");
  const forged = `${header}.${claims}.${signature.startsWith("A") ? "B" : "A"}${signature.slice(1)}`;
  await check({ error: "unauthorized" }, { status: 401, bearer: forged });

  await check({ error: "recent_authentication_required" }, {
    status: 403, bearer: token({ auth_time: now - 301 }), method: "DELETE", path: "account",
  });
  await check({ name: "pulse-test:owner-by-email", method: "DELETE", eligible: true }, {
    bearer: google, method: "DELETE", path: "account",
  });
  await check({ name: "pulse-test:owner-by-email", method: "DELETE", eligible: false }, {
    method: "DELETE", path: "account", settings: { ...env, ALLOWED_FIREBASE_EMAILS: "" }, migrationEmail: null,
  });
  const admin = await worker.fetch(new Request("https://pulse.example/migrations/inbox/target.json", {
    method: "PUT", headers: { Authorization: `Bearer ${google}` }, body: "{}",
  }), env);
  assert.equal(admin.status, 404);
  assert.equal(downloads, 1);
  t.mock.method(Date, "now", () => (now + 301) * 1000);
  await check({ name: "pulse-test:owner-by-email", method: "GET" });
  assert.equal(downloads, 2);
});
