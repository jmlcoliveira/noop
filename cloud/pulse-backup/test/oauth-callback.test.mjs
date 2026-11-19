import assert from "node:assert/strict";
import test from "node:test";
import { googleOAuthCallback } from "../src/oauth-callback.mjs";
const base = "https://pulse.joliveira.xyz/auth/google/callback";

test("Google callback preserves one-time response query and fixes native destination", () => {
  const query = "?code=opaque%2Bcode&state=a%2Fb%3D&scope=openid+email&redirect_uri=https%3A%2F%2Fevil.invalid";
  const response = googleOAuthCallback(new Request(base + query));
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("Location"), "pulseauth://google/callback" + query);
  assert.equal(response.headers.get("Cache-Control"), "no-store, max-age=0");
  assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
  assert.equal(response.headers.get("Content-Security-Policy"), "default-src 'none'; frame-ancestors 'none'");
  assert.equal(googleOAuthCallback(new Request(base + "?error=access_denied&state=random")).status, 302);
});

test("Google callback rejects ambiguous, missing, oversized and wrong-origin responses", () => {
  for (const suffix of ["", "?code=c", "?state=s", "?state=&code=c", "?state=s&code=", "?state=s&code=c&code=d", "?state=s&code=c&error=e", "?state=s&code=c&state=t", "?state=s&code=c#fragment", "?state=" + "s".repeat(4097) + "&code=c"]) {
    assert.equal(googleOAuthCallback(new Request(base + suffix)).status, 400);
  }
  assert.equal(googleOAuthCallback(new Request(base.replace("https:", "http:") + "?state=s&code=c")).status, 400);
  assert.equal(googleOAuthCallback(new Request(base.replace("pulse.joliveira.xyz", "evil.invalid") + "?state=s&code=c")).status, 400);
  assert.equal(googleOAuthCallback(new Request(base + "?state=s&code=c", {method:"POST"})).status, 405);
});
