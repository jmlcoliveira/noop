import { BackupAccount } from "./backup-account.mjs";
import { authenticate } from "./firebase.mjs";
import { APIError, bytesToHex, errorResponse, json } from "./http.mjs";
import { BackupMigrationClaim } from "./migration-claim.mjs";
import { googleOAuthCallback } from "./oauth-callback.mjs";

export { BackupAccount, BackupMigrationClaim };

export default {
  async fetch(request, env) {
    try {
      const { pathname: path, protocol } = new URL(request.url);
      if (request.method === "GET" && path === "/health") return json({ status: "ok" });
      if (request.method === "GET" && path === "/auth/google/callback") return googleOAuthCallback(request);
      if (!path.startsWith("/v1/")) return json({ error: "not_found" }, 404);
      if (protocol !== "https:") return json({ error: "https_required" }, 400);

      const accountDeletion = request.method === "DELETE" && path === "/v1/account";
      const user = await authenticate(request, env, accountDeletion);
      if (accountDeletion && Math.floor(Date.now() / 1000) - user.authTime > 300) {
        throw new APIError(403, "recent_authentication_required");
      }

      const headers = new Headers(request.headers);
      headers.delete("Authorization");
      headers.delete("X-Pulse-Internal-Eligible");
      headers.delete("X-Pulse-Internal-Migration-Email");
      if (accountDeletion && user.eligible) headers.set("X-Pulse-Internal-Eligible", "1");
      const migrationRoute = (request.method === "GET" && path === "/v1/state")
        || (request.method === "DELETE" && (path === "/v1/backups" || accountDeletion));
      if (migrationRoute && user.email) {
        const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(user.email));
        headers.set("X-Pulse-Internal-Migration-Email", bytesToHex(digest));
      }
      const account = env.ACCOUNTS.getByName(`${env.FIREBASE_PROJECT_ID}:${user.uid}`);
      return await account.fetch(new Request(request, { headers }));
    } catch (error) {
      return errorResponse(error);
    }
  },
};
