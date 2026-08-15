// Supabase Edge Function: redeem-referral
//
// Called by the app on the referee's FIRST verified sign-in (there is no
// session at signup — email confirmation is on), with the referral code the
// user entered at signup (persisted locally as a pending code) or typed into
// the referral screen's "Have a code?" field.
//
// Flow: rate-limit → validate code → self-referral checks (account + device
// via trial_devices) → 14-day redemption window → insert referrals row
// 'pending' (UNIQUE(referee) is the concurrency lock) → grant the REFEREE
// 30 days of promotional 'premium' via the RevenueCat REST API → mark
// referee_rewarded_at. The REFERRER is rewarded later by the
// revenuecat-webhook when the referee starts a trial / first purchase.
//
// Identity: verify_jwt=true only proves a valid project JWT (the anon key
// passes too), so the referee is resolved via auth.getUser(token) — never
// from the request body.
//
// Responses are machine-readable so the client can decide keep-vs-clear for
// its pending code: { ok, status: 'redeemed'|'already_redeemed', reason? }
// reasons: invalid_code | self_referral | already_redeemed | window_expired
//          | rate_limited | grant_failed | not_authenticated

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, serviceRoleKey);

const revenueCatSecretApiKey = Deno.env.get("REVENUECAT_SECRET_API_KEY");

const ENTITLEMENT = "premium";
const REDEMPTION_WINDOW_DAYS = 14;
const RATE_LIMIT_PER_HOUR = 5;

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function grantRefereeMonth(rcAppUserId: string): Promise<boolean> {
  if (!revenueCatSecretApiKey) {
    console.error("redeem-referral: REVENUECAT_SECRET_API_KEY not set");
    return false;
  }
  const res = await fetch(
    `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(rcAppUserId)}` +
      `/entitlements/${ENTITLEMENT}/promotional`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${revenueCatSecretApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ duration: "monthly" }),
    },
  );
  if (!res.ok) {
    console.error("redeem-referral: grant failed", res.status, await res.text());
    return false;
  }
  return true;
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return reply(405, { ok: false, reason: "method_not_allowed" });
    }

    // ── Identity from the JWT only ────────────────────────────────────
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    const { data: userData, error: userErr } = await supabase.auth.getUser(token);
    const referee = userData?.user;
    if (userErr || !referee) {
      return reply(401, { ok: false, reason: "not_authenticated" });
    }

    // ── VERIFIED INBOX REQUIRED ───────────────────────────────────────
    // With dashboard confirmations off, accounts are free instant
    // identities — rewarding unverified ones turns every fake signup into
    // a month of Pro. Checked BEFORE the attempt log so an unverified
    // user's retries don't eat their rate budget; the client keeps the
    // pending code and retries after verification.
    const { data: refereeProf } = await supabase
      .from("user_profiles")
      .select("email_verified_at")
      .eq("user_id", referee.id)
      .maybeSingle();
    if (!refereeProf?.email_verified_at) {
      return reply(200, { ok: false, reason: "email_unverified" });
    }

    const body = await req.json().catch(() => ({}));
    const rawCode = typeof body.code === "string" ? body.code : "";
    const deviceId = typeof body.device_id === "string" ? body.device_id : null;

    // ── Rate limit: 5 attempts per hour per user ──────────────────────
    await supabase.from("referral_redemption_attempts").insert({
      user_id: referee.id,
    });
    const hourAgo = new Date(Date.now() - 3_600_000).toISOString();
    const { count: attempts } = await supabase
      .from("referral_redemption_attempts")
      .select("id", { count: "exact", head: true })
      .eq("user_id", referee.id)
      .gte("attempted_at", hourAgo);
    if ((attempts ?? 0) > RATE_LIMIT_PER_HOUR) {
      return reply(429, { ok: false, reason: "rate_limited" });
    }

    // ── Normalize + look up the code ──────────────────────────────────
    let code = rawCode.trim().toUpperCase();
    if (code && !code.startsWith("VOYZA-") && /^[0-9A-Z]{6}$/.test(code)) {
      code = `VOYZA-${code}`; // tolerate the bare 6-char form
    }
    if (!/^VOYZA-[0-9A-Z]{6}$/.test(code)) {
      return reply(200, { ok: false, reason: "invalid_code" });
    }
    const { data: codeRow } = await supabase
      .from("referral_codes")
      .select("user_id, code")
      .eq("code", code)
      .maybeSingle();
    if (!codeRow) {
      return reply(200, { ok: false, reason: "invalid_code" });
    }
    const referrerId = codeRow.user_id as string;

    // ── Self-referral: account ────────────────────────────────────────
    if (referrerId === referee.id) {
      return reply(200, { ok: false, reason: "self_referral" });
    }

    // ── Self-referral: device (second account on the referrer's device)
    if (deviceId) {
      const { data: deviceRow } = await supabase
        .from("trial_devices")
        .select("user_id")
        .eq("device_id", deviceId)
        .maybeSingle();
      if (deviceRow?.user_id === referrerId) {
        return reply(200, { ok: false, reason: "self_referral" });
      }
    }

    // ── Redemption window: account younger than 14 days ──────────────
    const createdAtMs = Date.parse(referee.created_at ?? "");
    if (
      !Number.isFinite(createdAtMs) ||
      Date.now() - createdAtMs > REDEMPTION_WINDOW_DAYS * 86_400_000
    ) {
      return reply(200, { ok: false, reason: "window_expired" });
    }

    // ── Existing row? (retry path vs already-redeemed) ────────────────
    const { data: existing } = await supabase
      .from("referrals")
      .select("id, code, referee_rewarded_at")
      .eq("referee_user_id", referee.id)
      .maybeSingle();

    let referralId: string;
    if (existing) {
      if (existing.referee_rewarded_at != null || existing.code !== code) {
        // Fully redeemed already, or trying a different code second time.
        return reply(200, { ok: true, status: "already_redeemed" });
      }
      referralId = existing.id; // grant previously failed — retry it below
    } else {
      const { data: inserted, error: insertErr } = await supabase
        .from("referrals")
        .insert({
          referrer_user_id: referrerId,
          referee_user_id: referee.id,
          code,
        })
        .select("id")
        .maybeSingle();
      if (insertErr) {
        // UNIQUE(referee_user_id) violation ⇒ concurrent redeem won.
        if ((insertErr as { code?: string }).code === "23505") {
          return reply(200, { ok: true, status: "already_redeemed" });
        }
        // CHECK(referrer <> referee) or anything else unexpected.
        console.error("redeem-referral: insert failed", insertErr);
        return reply(500, { ok: false, reason: "server_error" });
      }
      referralId = inserted!.id;
    }

    // ── Grant the referee their 30 days ───────────────────────────────
    const granted = await grantRefereeMonth(referee.id);
    if (!granted) {
      // Row stays with referee_rewarded_at NULL — client keeps the pending
      // code and retries later; retries land in the branch above.
      return reply(502, { ok: false, reason: "grant_failed" });
    }
    const { data: completedRow } = await supabase
      .from("referrals")
      .update({ referee_rewarded_at: new Date().toISOString() })
      .eq("id", referralId)
      .is("referee_rewarded_at", null)
      .select("id")
      .maybeSingle();

    // Exactly-once side effects: only the call that flipped
    // referee_rewarded_at runs them. A lost-response retry lands in the
    // already_redeemed branch above; a concurrent double-grant loses this
    // guarded update and skips.
    if (completedRow) {
      // Instant referrer reward: +2 free place slots, capped at +10 by the
      // SQL function itself (LEAST), so no client math to trust.
      const { error: bonusErr } = await supabase.rpc(
        "increment_referral_bonus_places",
        { target_user: referrerId },
      );
      if (bonusErr) {
        console.error(
          "redeem-referral: bonus slots failed (non-fatal):",
          bonusErr,
        );
      }
      // Tell the referrer the moment it happens. The month-at-conversion
      // wait starts NOW — silence here made the program feel dead.
      try {
        await supabase.from("notifications").insert({
          user_id: referrerId,
          type: "referral_redeemed",
          title: "Your code was just used 🎉",
          body:
            "A friend joined VoyZa with your code — you earned +2 free " +
            "place slots right now. Your free month unlocks when they go " +
            "Pro (usually within a month).",
          data: { screen: "referral" },
        });
      } catch (e) {
        console.error("redeem-referral: notify failed (non-fatal):", e);
      }
    }

    console.log(
      `redeem-referral: ${referee.id} redeemed ${code} (referrer ${referrerId})`,
    );
    return reply(200, { ok: true, status: "redeemed" });
  } catch (e) {
    const errorId = crypto.randomUUID();
    console.error(`redeem-referral error [${errorId}]:`, e);
    return reply(500, { ok: false, reason: "server_error", id: errorId });
  }
});
