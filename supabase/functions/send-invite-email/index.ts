// send-invite-email — emails a trip invitation to someone who isn't a VoyZa
// user yet: the trip they're invited to, the inviter's referral code (30
// free days at signup), and store buttons.
//
// SECURITY MODEL
//  • Auth required: the sender is resolved from the JWT via auth.getUser —
//    never from the body.
//  • Ownership proof: the (trip_id, email) pair must match a
//    pending_trip_invites row CREATED BY THIS USER. The function can only
//    email people the invite RPC already vetted (that RPC checks trip write
//    access), so it cannot be used as an open relay.
//  • Rate limit: max 20 invite emails per inviter per hour.
//  • Injection: recipient comes from the DB row (not the request), all
//    user-controlled text is HTML-escaped, and header fields are stripped
//    of control characters.
import { createClient } from "jsr:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const resendKey = Deno.env.get("RESEND_API_KEY");
const supabase = createClient(supabaseUrl, serviceRoleKey);

const IOS_URL = Deno.env.get("STORE_URL_IOS");
const ANDROID_URL = Deno.env.get("STORE_URL_ANDROID");

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function escapeHtml(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/// Header-safe: no CR/LF or other control chars in subject/name fields.
function headerSafe(s: string): string {
  // deno-lint-ignore no-control-regex
  return s.replace(/[\x00-\x1f\x7f]/g, " ").trim();
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return reply(405, { ok: false, reason: "method_not_allowed" });
    }
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    const { data: userData, error: userErr } = await supabase.auth.getUser(
      token,
    );
    if (userErr || !userData?.user) {
      return reply(401, { ok: false, reason: "not_authenticated" });
    }
    const inviter = userData.user;

    // VERIFIED SENDERS ONLY — with dashboard confirmations off, accounts
    // are free identities; an email relay must not be. (The invite RPC
    // enforces the same rule, so this is belt-and-braces.)
    const { data: inviterProf } = await supabase
      .from("user_profiles")
      .select("email_verified_at")
      .eq("user_id", inviter.id)
      .maybeSingle();
    if (!inviterProf?.email_verified_at) {
      return reply(200, { ok: false, reason: "email_unverified" });
    }

    const body = await req.json().catch(() => ({}));
    const tripId = typeof body.trip_id === "string" ? body.trip_id : "";
    const email = typeof body.email === "string"
      ? body.email.trim().toLowerCase()
      : "";
    if (!tripId || !email) {
      return reply(200, { ok: false, reason: "bad_request" });
    }

    // ── Rate limit: 20 invite emails per inviter per hour ─────────────
    const hourAgo = new Date(Date.now() - 3_600_000).toISOString();
    const { count } = await supabase
      .from("invite_email_log")
      .select("id", { count: "exact", head: true })
      .eq("inviter_user_id", inviter.id)
      .gte("sent_at", hourAgo);
    if ((count ?? 0) >= 20) {
      return reply(429, { ok: false, reason: "rate_limited" });
    }

    // ── Ownership proof: invite row must exist AND be this user's ─────
    const { data: invite } = await supabase
      .from("pending_trip_invites")
      .select("id, email, referral_code, permission")
      .eq("trip_id", tripId)
      .eq("email", email)
      .eq("invited_by", inviter.id)
      .maybeSingle();
    if (!invite) {
      return reply(200, { ok: false, reason: "invite_not_found" });
    }

    if (!resendKey) {
      console.error("send-invite-email: RESEND_API_KEY not set");
      return reply(200, { ok: false, reason: "email_disabled" });
    }

    // ── Compose ───────────────────────────────────────────────────────
    const { data: trip } = await supabase
      .from("trips").select("name").eq("id", tripId).maybeSingle();
    const { data: profile } = await supabase
      .from("user_profiles")
      .select("first_name, email")
      .eq("user_id", inviter.id)
      .maybeSingle();

    const inviterName = headerSafe(
      (profile?.first_name as string | null)?.trim() ||
        (inviter.email ?? "A friend").split("@")[0],
    );
    const tripName = headerSafe((trip?.name as string | null) ?? "a trip");
    const code = invite.referral_code as string;
    const landing = `https://voyza.xtremon.com/r/${encodeURIComponent(code)}`;
    const iosUrl = IOS_URL || landing;
    const androidUrl = ANDROID_URL || landing;

    const eName = escapeHtml(inviterName);
    const eTrip = escapeHtml(tripName);
    const eCode = escapeHtml(code);
    const p =
      "margin:0 0 12px;color:#46535f;font-size:15px;line-height:1.5";
    const btn =
      "display:inline-block;padding:12px 18px;border-radius:12px;" +
      "text-decoration:none;font-weight:700;font-size:14px;margin:4px";
    const html =
      `<div style="background:#f4f6f8;padding:24px;font-family:-apple-system,'Segoe UI',Roboto,sans-serif">` +
      `<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden;border:1px solid #e6e9ee">` +
      `<div style="background:linear-gradient(135deg,#2B1D70,#2E5BD0 60%,#15BFB6);padding:22px 24px;color:#fff;font-weight:800;font-size:20px">VoyZa</div>` +
      `<div style="padding:24px">` +
      `<h1 style="margin:0 0 14px;font-size:22px;color:#16202b">${eName} invited you to plan &ldquo;${eTrip}&rdquo; together</h1>` +
      `<p style="${p}">VoyZa turns a list of places into the smartest day-by-day route — and ${eName} wants to plan this trip with you.</p>` +
      `<p style="${p}">Sign up with the code below and you start with <strong>30 days of VoyZa Pro, free</strong> — no payment, no card. The trip appears in your app automatically the moment you join.</p>` +
      `<div style="margin:18px 0;padding:14px;border:2px dashed #2E5BD0;border-radius:12px;text-align:center;font-size:22px;font-weight:800;letter-spacing:2px;color:#16202b">${eCode}</div>` +
      `<div style="text-align:center;margin:18px 0 6px">` +
      `<a href="${iosUrl}" style="${btn};background:#16202b;color:#fff">Download on the App&nbsp;Store</a>` +
      `<a href="${androidUrl}" style="${btn};background:#2E5BD0;color:#fff">Get it on Google&nbsp;Play</a>` +
      `</div>` +
      `<p style="margin:16px 0 0;color:#9aa4ad;font-size:12px">Didn't expect this? You can ignore this email — nothing happens without you signing up.</p>` +
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
        to: invite.email, // DB row, not request input
        subject: `${inviterName} invited you to plan "${tripName}" on VoyZa`,
        html,
      }),
    });
    if (!res.ok) {
      console.error("send-invite-email: resend failed", res.status);
      return reply(200, { ok: false, reason: "send_failed" });
    }

    await supabase.from("invite_email_log").insert({
      inviter_user_id: inviter.id,
      invite_id: invite.id,
      email: invite.email,
    });

    return reply(200, { ok: true });
  } catch (e) {
    const errorId = crypto.randomUUID();
    console.error(`send-invite-email error [${errorId}]:`, e);
    return reply(500, { ok: false, reason: "server_error", id: errorId });
  }
});
