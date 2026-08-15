// send-email-otp — mails a 6-digit verification code via Resend.
//
// Two purposes:
//   • 'verify'        — prove the account's CURRENT email (fired at signup
//                       and by every "Verify now" button);
//   • 'email_change'  — prove a NEW address before verify-email-otp swaps
//                       the account onto it.
//
// This is VoyZa's own verification layer: the dashboard's "Confirm email"
// is off (signups get an instant session and gotrue auto-stamps
// email_confirmed_at), so inbox ownership is proven here and recorded in
// user_profiles.email_verified_at — the flag every email-keyed feature
// gates on.
//
// SECURITY MODEL
//  • Auth required — the target user comes from the JWT, never the body.
//  • Codes are random 6-digit, stored as SHA-256("<uid>:<purpose>:<code>")
//    — a leaked table row reveals nothing usable on its own.
//  • 10-minute expiry; issuing a new code consumes all previous unconsumed
//    codes for the same (user, purpose).
//  • Rate limit: 60s cooldown between sends, max 5 sends/hour/user.
//  • email_change: rejects addresses already on a VoyZa account.

import { createClient } from "jsr:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const resendKey = Deno.env.get("RESEND_API_KEY");
const supabase = createClient(supabaseUrl, serviceRoleKey);

const CODE_TTL_MS = 10 * 60_000;
const SEND_COOLDOWN_MS = 60_000;
const SENDS_PER_HOUR = 5;

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(s),
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function sixDigitCode(): string {
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  return String(buf[0] % 1_000_000).padStart(6, "0");
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return reply(405, { ok: false, reason: "method_not_allowed" });
    }
    const token = (req.headers.get("Authorization") ?? "")
      .replace(/^Bearer\s+/i, "");
    const { data: userData, error: userErr } = await supabase.auth.getUser(
      token,
    );
    const user = userData?.user;
    if (userErr || !user) {
      return reply(401, { ok: false, reason: "not_authenticated" });
    }

    const body = await req.json().catch(() => ({}));
    const purpose = body.purpose === "email_change" ? "email_change" : "verify";

    // Resolve the address being proven.
    let target = "";
    if (purpose === "verify") {
      target = (user.email ?? "").toLowerCase();
      if (!target) return reply(200, { ok: false, reason: "no_email" });
    } else {
      target = typeof body.new_email === "string"
        ? body.new_email.trim().toLowerCase()
        : "";
      if (!EMAIL_RE.test(target)) {
        return reply(200, { ok: false, reason: "invalid_email" });
      }
      if (target === (user.email ?? "").toLowerCase()) {
        return reply(200, { ok: false, reason: "same_email" });
      }
      // Already someone's account? AUTH level first — email_exists sees
      // every live auth user (verified or not, profile row or not), which
      // the other two checks individually don't: get_user_id_by_email is
      // verified-only by design, and the profiles scan misses
      // profile-less accounts. All three run as belt-and-braces, and the
      // definitive re-check at verify time + gotrue's unique-email
      // constraint at the actual swap keep this airtight even if a
      // matching signup lands mid-flow.
      const { data: takenAtAuth } = await supabase
        .rpc("email_exists", { user_email: target });
      const { data: taken } = await supabase
        .rpc("get_user_id_by_email", { user_email: target });
      const { count: authTaken } = await supabase
        .from("user_profiles")
        .select("id", { count: "exact", head: true })
        .ilike("email", target);
      if (takenAtAuth === true || taken || (authTaken ?? 0) > 0) {
        return reply(200, { ok: false, reason: "email_taken" });
      }
    }

    // ── Rate limits ───────────────────────────────────────────────────
    const hourAgo = new Date(Date.now() - 3_600_000).toISOString();
    const { data: recent } = await supabase
      .from("email_otp_sends")
      .select("sent_at")
      .eq("user_id", user.id)
      .gte("sent_at", hourAgo)
      .order("sent_at", { ascending: false });
    if (recent && recent.length >= SENDS_PER_HOUR) {
      return reply(429, { ok: false, reason: "rate_limited" });
    }
    if (
      recent && recent.length > 0 &&
      Date.now() - Date.parse(recent[0].sent_at) < SEND_COOLDOWN_MS
    ) {
      return reply(429, { ok: false, reason: "cooldown" });
    }

    if (!resendKey) {
      console.error("send-email-otp: RESEND_API_KEY not set");
      return reply(200, { ok: false, reason: "email_disabled" });
    }

    // ── Issue the code ────────────────────────────────────────────────
    const code = sixDigitCode();
    const codeHash = await sha256Hex(`${user.id}:${purpose}:${code}`);

    // One live code per (user, purpose): consume predecessors.
    await supabase
      .from("email_otp_codes")
      .update({ consumed_at: new Date().toISOString() })
      .eq("user_id", user.id)
      .eq("purpose", purpose)
      .is("consumed_at", null);

    const { error: insErr } = await supabase.from("email_otp_codes").insert({
      user_id: user.id,
      purpose,
      target_email: target,
      code_hash: codeHash,
      expires_at: new Date(Date.now() + CODE_TTL_MS).toISOString(),
    });
    if (insErr) {
      console.error("send-email-otp: insert failed", insErr);
      return reply(500, { ok: false, reason: "server_error" });
    }

    // ── Send (same branded shell as the invite/lifecycle emails) ──────
    const heading = purpose === "verify"
      ? "Verify your email"
      : "Confirm your new email";
    const intro = purpose === "verify"
      ? "Enter this code in VoyZa to verify your email address. It proves " +
        "the account is really yours — and unlocks invites, referrals, and " +
        "account recovery."
      : "Enter this code in VoyZa to switch your account to this address.";
    const p = "margin:0 0 12px;color:#46535f;font-size:15px;line-height:1.5";
    const html =
      `<div style="background:#f4f6f8;padding:24px;font-family:-apple-system,'Segoe UI',Roboto,sans-serif">` +
      `<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden;border:1px solid #e6e9ee">` +
      `<div style="background:linear-gradient(135deg,#2B1D70,#2E5BD0 60%,#15BFB6);padding:22px 24px;color:#fff;font-weight:800;font-size:20px">VoyZa</div>` +
      `<div style="padding:24px">` +
      `<h1 style="margin:0 0 14px;font-size:22px;color:#16202b">${heading}</h1>` +
      `<p style="${p}">${intro}</p>` +
      `<div style="margin:18px 0;padding:16px;border:2px dashed #2E5BD0;border-radius:12px;text-align:center;font-size:32px;font-weight:800;letter-spacing:8px;color:#16202b">${code}</div>` +
      `<p style="${p}">The code expires in 10 minutes.</p>` +
      `<p style="margin:16px 0 0;color:#9aa4ad;font-size:12px">Didn't request this? You can ignore this email — nothing changes without the code.</p>` +
      `</div>` +
      `<div style="padding:16px 24px;color:#9aa4ad;font-size:12px;border-top:1px solid #eef1f4">VoyZa · voyza.xtremon.com</div>` +
      `</div></div>`;

    const from = Deno.env.get("LIFECYCLE_FROM") ??
      "VoyZa <onboarding@resend.dev>";
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from,
        to: target,
        subject: `${code} is your VoyZa verification code`,
        html,
      }),
    });
    if (!res.ok) {
      console.error("send-email-otp: resend failed", res.status);
      return reply(200, { ok: false, reason: "send_failed" });
    }

    await supabase.from("email_otp_sends").insert({ user_id: user.id });

    // Housekeeping: drop this user's long-dead rows (best-effort).
    await supabase
      .from("email_otp_codes")
      .delete()
      .eq("user_id", user.id)
      .lt("expires_at", new Date(Date.now() - 86_400_000).toISOString());

    return reply(200, { ok: true });
  } catch (e) {
    const errorId = crypto.randomUUID();
    console.error(`send-email-otp error [${errorId}]:`, e);
    return reply(500, { ok: false, reason: "server_error", id: errorId });
  }
});
