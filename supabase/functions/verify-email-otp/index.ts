// verify-email-otp — checks a 6-digit code from send-email-otp and applies
// its effect:
//   • 'verify'        — stamps user_profiles.email_verified_at (creating a
//                       minimal profile row if signup's create somehow
//                       didn't run);
//   • 'email_change'  — service-role updates the auth email to the proven
//                       address, mirrors it into user_profiles, and stamps
//                       the verified flag. The client must refresh its
//                       session afterwards (the JWT still carries the old
//                       address until then).
//
// SECURITY MODEL
//  • Auth required; the code row must belong to the JWT's user.
//  • Max 5 wrong attempts per code, then it dies; 10-minute expiry;
//    single-use (consumed on success).
//  • email_change re-checks the address is still unclaimed at swap time
//    (the send-time check is only the friendly early rejection).

import { createClient } from "jsr:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, serviceRoleKey);

const MAX_ATTEMPTS = 5;

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
    const code = typeof body.code === "string" ? body.code.trim() : "";
    if (!/^\d{6}$/.test(code)) {
      return reply(200, { ok: false, reason: "invalid_code" });
    }

    // Latest live code for this (user, purpose).
    const { data: row } = await supabase
      .from("email_otp_codes")
      .select("id, target_email, code_hash, attempts, expires_at")
      .eq("user_id", user.id)
      .eq("purpose", purpose)
      .is("consumed_at", null)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (!row) {
      return reply(200, { ok: false, reason: "no_code" });
    }
    if (Date.parse(row.expires_at) < Date.now()) {
      return reply(200, { ok: false, reason: "expired" });
    }
    if (row.attempts >= MAX_ATTEMPTS) {
      await supabase
        .from("email_otp_codes")
        .update({ consumed_at: new Date().toISOString() })
        .eq("id", row.id);
      return reply(200, { ok: false, reason: "too_many_attempts" });
    }

    const expected = row.code_hash as string;
    const actual = await sha256Hex(`${user.id}:${purpose}:${code}`);
    if (actual !== expected) {
      const attemptsNow = (row.attempts as number) + 1;
      await supabase
        .from("email_otp_codes")
        .update({
          attempts: attemptsNow,
          ...(attemptsNow >= MAX_ATTEMPTS
            ? { consumed_at: new Date().toISOString() }
            : {}),
        })
        .eq("id", row.id);
      return reply(200, {
        ok: false,
        reason: attemptsNow >= MAX_ATTEMPTS
          ? "too_many_attempts"
          : "invalid_code",
        attempts_left: Math.max(0, MAX_ATTEMPTS - attemptsNow),
      });
    }

    // ── Correct code: consume, then apply ─────────────────────────────
    await supabase
      .from("email_otp_codes")
      .update({ consumed_at: new Date().toISOString() })
      .eq("id", row.id);

    const now = new Date().toISOString();
    const target = (row.target_email as string).toLowerCase();

    if (purpose === "email_change") {
      // Definitive uniqueness check at swap time — AUTH level first
      // (email_exists sees unverified and profile-less accounts too),
      // then the profile scan; gotrue's unique-email constraint inside
      // updateUserById below is the final wall either way.
      const { data: takenNow } = await supabase
        .rpc("email_exists", { user_email: target });
      if (takenNow === true) {
        return reply(200, { ok: false, reason: "email_taken" });
      }
      const { data: clash } = await supabase
        .from("user_profiles")
        .select("user_id")
        .ilike("email", target)
        .neq("user_id", user.id)
        .maybeSingle();
      if (clash) {
        return reply(200, { ok: false, reason: "email_taken" });
      }
      const { error: adminErr } = await supabase.auth.admin.updateUserById(
        user.id,
        { email: target, email_confirm: true },
      );
      if (adminErr) {
        const msg = (adminErr.message ?? "").toLowerCase();
        console.error("verify-email-otp: admin update failed", adminErr);
        return reply(200, {
          ok: false,
          reason: msg.includes("already") ? "email_taken" : "server_error",
        });
      }
      const { error: profErr } = await supabase
        .from("user_profiles")
        .update({ email: target, email_verified_at: now, updated_at: now })
        .eq("user_id", user.id);
      if (profErr) {
        // Auth email already swapped — the profile mirror self-heals on the
        // next verify/profile write; log loudly but report success.
        console.error("verify-email-otp: profile mirror failed", profErr);
      }
      return reply(200, { ok: true, purpose, email: target });
    }

    // purpose === 'verify'
    const { data: updated, error: updErr } = await supabase
      .from("user_profiles")
      .update({ email_verified_at: now, updated_at: now })
      .eq("user_id", user.id)
      .select("user_id");
    if (updErr) {
      console.error("verify-email-otp: flag update failed", updErr);
      return reply(500, { ok: false, reason: "server_error" });
    }
    if (!updated || updated.length === 0) {
      // No profile row (signup-side create failed?) — make a minimal one so
      // verification is never blocked on it.
      const { error: insErr } = await supabase.from("user_profiles").insert({
        user_id: user.id,
        email: target,
        email_verified_at: now,
      });
      if (insErr) {
        console.error("verify-email-otp: profile insert failed", insErr);
        return reply(500, { ok: false, reason: "server_error" });
      }
    }
    return reply(200, { ok: true, purpose });
  } catch (e) {
    const errorId = crypto.randomUUID();
    console.error(`verify-email-otp error [${errorId}]:`, e);
    return reply(500, { ok: false, reason: "server_error", id: errorId });
  }
});
