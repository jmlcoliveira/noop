import { APIError } from "./http.mjs";

const CERTIFICATES = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com";
const RSA = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };
const unauthorized = () => new APIError(401, "unauthorized");
let publicKeys;

function base64Bytes(value) {
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

function base64urlBytes(value) {
  return base64Bytes(value.replaceAll("-", "+").replaceAll("_", "/"));
}

function jwtJSON(value) {
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(base64urlBytes(value)));
}

function derElement(bytes, start, limit) {
  if (start + 2 > limit) throw new Error("Truncated certificate");
  const tag = bytes[start];
  let offset = start + 2;
  let size = bytes[start + 1];
  if (size >= 128) {
    const width = size - 128;
    if (width < 1 || width > 4 || offset + width > limit) throw new Error("Invalid certificate length");
    size = 0;
    for (let index = 0; index < width; index++) size = size * 256 + bytes[offset++];
  }
  const end = offset + size;
  if (end > limit) throw new Error("Truncated certificate");
  return { tag, offset, end };
}

function certificatePublicKey(pem) {
  const match = /^-----BEGIN CERTIFICATE-----\s+([\s\S]+?)\s+-----END CERTIFICATE-----\s*$/.exec(pem);
  if (!match) throw new Error("Invalid certificate PEM");
  const bytes = base64Bytes(match[1]);
  const certificate = derElement(bytes, 0, bytes.length);
  const tbs = derElement(bytes, certificate.offset, certificate.end);
  if (certificate.tag !== 0x30 || tbs.tag !== 0x30) throw new Error("Invalid certificate sequence");

  // RFC 5280 TBSCertificate fields before SubjectPublicKeyInfo.
  let offset = tbs.offset;
  if (bytes[offset] === 0xa0) offset = derElement(bytes, offset, tbs.end).end;
  for (const tag of [0x02, 0x30, 0x30, 0x30, 0x30]) {
    const field = derElement(bytes, offset, tbs.end);
    if (field.tag !== tag) throw new Error("Invalid certificate field");
    offset = field.end;
  }
  const publicKey = derElement(bytes, offset, tbs.end);
  if (publicKey.tag !== 0x30) throw new Error("Invalid public key sequence");
  return bytes.subarray(offset, publicKey.end);
}

async function firebasePublicKey(kid) {
  try {
    if (!publicKeys || publicKeys.expires <= Date.now()) {
      const response = await fetch(CERTIFICATES, { redirect: "manual" });
      if (!response.ok) throw new Error("Certificate service unavailable");
      const certificates = await response.json();
      if (!certificates || typeof certificates !== "object" || Array.isArray(certificates)
          || Object.keys(certificates).length === 0) throw new Error("Invalid certificate set");

      const maxAge = /(?:^|,)\s*max-age=(\d+)\b/i.exec(response.headers.get("Cache-Control") ?? "");
      const age = Number(response.headers.get("Age")) || 0;
      const seconds = maxAge ? Math.max(0, Number(maxAge[1]) - age) : 0;
      publicKeys = { certificates, expires: Date.now() + seconds * 1000, imported: new Map() };
    }

    const keys = publicKeys;
    if (!Object.hasOwn(keys.certificates, kid)) return undefined;
    if (!keys.imported.has(kid)) {
      const spki = certificatePublicKey(keys.certificates[kid]);
      const key = await crypto.subtle.importKey("spki", spki, RSA, false, ["verify"]);
      keys.imported.set(kid, key);
    }
    return keys.imported.get(kid);
  } catch {
    throw new APIError(503, "authentication_unavailable");
  }
}

function list(value) {
  return typeof value === "string" ? value.split(",").map((item) => item.trim()).filter(Boolean) : [];
}

export async function authenticate(request, env, accountDeletion) {
  const auth = request.headers.get("Authorization") ?? "";
  if (auth.length > 8192) throw unauthorized();
  const match = /^Bearer ([\w-]+)\.([\w-]+)\.([\w-]+)$/i.exec(auth);
  if (!match) throw unauthorized();

  const project = env.FIREBASE_PROJECT_ID;
  if (!project) throw new APIError(503, "authentication_unavailable");
  const [, encodedHeader, encodedClaims, encodedSignature] = match;
  let header, claims, signature;
  try {
    header = jwtJSON(encodedHeader);
    claims = jwtJSON(encodedClaims);
    signature = base64urlBytes(encodedSignature);
  } catch {
    throw unauthorized();
  }

  const now = Math.floor(Date.now() / 1000);
  if (header?.alg !== "RS256" || typeof header.kid !== "string" || !header.kid || header.crit !== undefined
      || claims?.aud !== project || claims.iss !== `https://securetoken.google.com/${project}`
      || typeof claims.sub !== "string" || !claims.sub || claims.sub.length > 128
      || (claims.user_id !== undefined && claims.user_id !== claims.sub)
      || !Number.isSafeInteger(claims.exp) || claims.exp <= now
      || !Number.isSafeInteger(claims.iat) || claims.iat <= 0 || claims.iat > now
      || !Number.isSafeInteger(claims.auth_time) || claims.auth_time <= 0 || claims.auth_time > claims.iat) {
    throw unauthorized();
  }

  const key = await firebasePublicKey(header.kid);
  const signed = new TextEncoder().encode(`${encodedHeader}.${encodedClaims}`);
  if (!key || !await crypto.subtle.verify(RSA, key, signature, signed)) throw unauthorized();

  const email = claims.email_verified === true && typeof claims.email === "string"
    ? claims.email.trim().toLowerCase()
    : "";
  const provider = claims.firebase?.sign_in_provider;
  const supportedProvider = provider === "password" || provider === "google.com";
  const uidAllowed = list(env.ALLOWED_FIREBASE_UIDS).includes(claims.sub);
  const emailAllowed = list(env.ALLOWED_FIREBASE_EMAILS).some((allowed) => allowed.toLowerCase() === email);
  if (!accountDeletion) {
    if (!email) throw new APIError(403, "email_not_verified");
    if (!supportedProvider) throw new APIError(403, "provider_not_allowed");
    if (!uidAllowed && !emailAllowed) throw new APIError(403, "not_allowlisted");
  }

  const eligible = Boolean(email && supportedProvider && (uidAllowed || emailAllowed));
  return { uid: claims.sub, authTime: claims.auth_time, eligible, email: eligible ? email : undefined };
}
