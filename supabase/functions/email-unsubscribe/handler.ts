// The request logic of email-unsubscribe, kept apart from Deno.serve so it
// can be tested without a server or a database.

import { isTokenShape, UNSUBSCRIBE_PAGE } from "../_shared/email_unsubscribe.ts";

export interface UnsubscribeDeps {
  /// The address a token was issued for, or null when the token is unknown.
  lookup(token: string): Promise<string | null>;
  /// Adds the address to the suppression list. Idempotent.
  suppress(email: string, source: string): Promise<void>;
}

const ALLOWED_ORIGIN = "https://voyza.xtremon.com";

function cors(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    "Vary": "Origin",
  };
}

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...cors() },
  });
}

export async function handleUnsubscribe(
  req: Request,
  deps: UnsubscribeDeps,
): Promise<Response> {
  const url = new URL(req.url);
  const fromQuery = url.searchParams.get("t");

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors() });
  }

  // A browser that opens the one-click address gets the page with a
  // button. A GET never unsubscribes: link scanners in mail filters
  // fetch every link in an email.
  if (req.method === "GET") {
    const target = isTokenShape(fromQuery)
      ? `${UNSUBSCRIBE_PAGE}?t=${fromQuery}`
      : UNSUBSCRIBE_PAGE;
    return new Response(null, { status: 302, headers: { Location: target } });
  }

  if (req.method !== "POST") return json(405, { ok: false, reason: "method" });

  // One-click (RFC 8058): the token is in the address and the body is
  // "List-Unsubscribe=One-Click". The page sends JSON {"t": token}.
  let token = fromQuery;
  let source = "one_click";
  if (!token && (req.headers.get("content-type") ?? "").includes("json")) {
    const body = await req.json().catch(() => ({}));
    token = typeof body.t === "string" ? body.t : null;
    source = "page";
  }
  if (!isTokenShape(token)) return json(400, { ok: false, reason: "bad_link" });

  try {
    const email = await deps.lookup(token);
    if (!email) return json(404, { ok: false, reason: "unknown_link" });
    await deps.suppress(email, source);
    return json(200, { ok: true });
  } catch (e) {
    console.error("email-unsubscribe failed:", e);
    return json(500, { ok: false, reason: "server_error" });
  }
}
