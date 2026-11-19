export class APIError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
  }
}

export function json(value, status = 200) {
  return Response.json(value, { status, headers: { "Cache-Control": "no-store" } });
}

export function noContent(headers = {}) {
  return new Response(null, { status: 204, headers: { "Cache-Control": "no-store", ...headers } });
}

export function errorResponse(error) {
  if (error instanceof APIError) return json({ error: error.message }, error.status);
  return json({ error: "service_unavailable" }, 503);
}

export async function smallJSON(request) {
  const buffer = new Uint8Array(512);
  const reader = request.body?.getReader();
  if (!reader) throw new APIError(400, "invalid_request");
  try {
    let size = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (size + value.length > buffer.length) {
        void reader.cancel().catch(() => {});
        throw new APIError(413, "request_too_large");
      }
      buffer.set(value, size);
      size += value.length;
    }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, size)));
  } catch (error) {
    if (error instanceof APIError) throw error;
    throw new APIError(400, "invalid_request");
  } finally {
    reader.releaseLock();
  }
}

export function bytesToHex(bytes) {
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
