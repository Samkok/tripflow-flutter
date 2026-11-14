// Unsubscribe support shared by every function that sends commercial email
// (lifecycle emails, trip invitations). See supabase/migrations/
// 20261114090000_email_unsubscribe.sql for the two tables.
//
// Each email gets its own random token, stored with the recipient's
// address. The link carries only the token, never the address.

// deno-lint-ignore no-explicit-any
type Db = any;

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";

/// The page people land on from the footer link: one button, no sign-in.
export const UNSUBSCRIBE_PAGE = "https://voyza.xtremon.com/unsubscribe";

/// The one-click endpoint mail apps call (RFC 8058).
export function unsubscribeEndpoint(token: string): string {
  return `${SUPABASE_URL}/functions/v1/email-unsubscribe?t=${token}`;
}

export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

/// 32 random bytes, base64url: unguessable, safe in a URL.
export function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function isTokenShape(t: string | null): t is string {
  return !!t && /^[A-Za-z0-9_-]{20,100}$/.test(t);
}

/// True when this address asked not to be emailed. Fails CLOSED: if the
/// list cannot be read, the caller must not send.
export async function isSuppressed(db: Db, email: string): Promise<boolean> {
  const { data, error } = await db
    .from("email_suppressions")
    .select("email")
    .eq("email", normalizeEmail(email))
    .maybeSingle();
  if (error) throw new Error(`suppression check failed: ${error.message}`);
  return data != null;
}

/// Stores a fresh token for [email]. Returns null when it cannot be stored;
/// the caller must then not send, because the email would carry a dead link.
export async function newUnsubscribeToken(
  db: Db,
  email: string,
  kind: "lifecycle" | "invite",
): Promise<string | null> {
  const token = randomToken();
  const { error } = await db.from("email_unsubscribe_tokens").insert({
    token,
    email: normalizeEmail(email),
    kind,
  });
  if (error) {
    console.error("unsubscribe token insert failed:", error.message);
    return null;
  }
  return token;
}

/// Headers that make Gmail, Apple Mail and Outlook show their own
/// "Unsubscribe" button, which unsubscribes in one click.
export function unsubscribeHeaders(token: string): Record<string, string> {
  return {
    "List-Unsubscribe": `<${unsubscribeEndpoint(token)}>`,
    "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
  };
}

export function escapeHtml(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/// The sender's postal address, required in commercial email (CAN-SPAM).
/// Kept in the EMAIL_POSTAL_ADDRESS secret, never in the repository.
export function postalAddress(): string | null {
  const a = (Deno.env.get("EMAIL_POSTAL_ADDRESS") ?? "").trim();
  return a ? a : null;
}

/// Footer for commercial email: why they got it, the unsubscribe link, and
/// who sent it with a postal address. [whyHtml] must already be escaped.
export function commercialFooterHtml(token: string, whyHtml: string): string {
  const link = `${UNSUBSCRIBE_PAGE}?t=${token}`;
  const address = postalAddress();
  const sender = address
    ? `VoyZa · Kok Heng, ${escapeHtml(address)}`
    : "VoyZa · Kok Heng";
  const a = "color:#6b7884;text-decoration:underline";
  return `<div style="padding:16px 24px;color:#9aa4ad;font-size:12px;line-height:1.6;border-top:1px solid #eef1f4">`
    + `You're getting this email because ${whyHtml}. `
    + `<a href="${link}" style="${a}">Unsubscribe</a><br>`
    + `${sender} · <a href="https://voyza.xtremon.com" style="${a}">voyza.xtremon.com</a>`
    + `</div>`;
}
