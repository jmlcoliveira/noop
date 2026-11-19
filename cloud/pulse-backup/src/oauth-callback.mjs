// The Firebase session and its OAuth state are held by the initiating iPhone.
// This endpoint forwards only the one-time authorization response, never Firebase credentials.
export function googleOAuthCallback(request) {
  const headers = {
    "Cache-Control": "no-store, max-age=0",
    "Pragma": "no-cache",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
  };
  const url = new URL(request.url);
  if (request.method !== "GET") {
    return new Response("Method not allowed", { status: 405, headers: { ...headers, Allow: "GET" } });
  }
  if (url.protocol !== "https:" || url.hostname !== "pulse.joliveira.xyz"
      || url.pathname !== "/auth/google/callback" || url.hash || url.search.length > 8192) {
    return new Response("Invalid authorization response", { status: 400, headers });
  }
  const params = url.searchParams;
  const state = params.getAll("state");
  const code = params.getAll("code");
  const error = params.getAll("error");
  if (state.length !== 1 || !state[0] || state[0].length > 4096
      || code.length > 1 || error.length > 1 || !!code.length === !!error.length
      || code.some((value) => !value) || error.some((value) => !value)
      || [...params].length > 24) {
    return new Response("Invalid authorization response", { status: 400, headers });
  }
  // A fixed destination prevents this unauthenticated endpoint becoming an open redirect.
  // Preserve the exact raw query because Firebase validates the original response URI.
  return new Response(null, { status: 302, headers: {
    ...headers, Location: `pulseauth://google/callback${url.search}`,
  } });
}
