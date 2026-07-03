// Supabase Edge Function: claim-invites
//
// Runs on the invitee's first verified sign-in (hooked in main.dart next to
// redeemPendingCodeIfAny). Turns "invited a non-user to a trip" into the
// app's strongest growth loop:
//   1. auto-joins them to every trip their email was invited to
//      (inserting the collaborator row fires the existing "added to a trip"
//       notification), and
//   2. runs the referral reward — both the inviter and the new user get a
//      free month — using the referral code carried on the pending invite
//      (the invitee never had to type a code).
//
// Reliability: collaboration join is idempotent (ON CONFLICT DO NOTHING) and
// always completes; the referral is best-effort but retried on a later claim
// because pending rows are only deleted once the whole flow succeeds.
//
// Identity comes from the JWT only (verify_jwt=true just proves a valid
// project token; anon key passes too), so we resolve the user via getUser().

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, serviceRoleKey);

const revenueCatSecretApiKey = Deno.env.get("REVENUECAT_SECRET_API_KEY");
const ENTITLEMENT = "premium";

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function grantPromotionalMonth(rcAppUserId: string): Promise<boolean> {
  if (!revenueCatSecretApiKey) {
    console.error("claim-invites: REVENUECAT_SECRET_API_KEY not set");
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
    console.error("claim-invites: grant failed", res.status, await res.text());
    return false;
  }
  return true;
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return reply(405, { ok: false, reason: "method_not_allowed" });
    }

    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: userData, error: userErr } = await supabase.auth.getUser(token);
    const user = userData?.user;
    if (userErr || !user) {
      return reply(401, { ok: false, reason: "not_authenticated" });
    }
    const email = (user.email ?? "").toLowerCase();
    if (!email) return reply(200, { ok: true, joined: 0 });

    const body = await req.json().catch(() => ({}));
    const deviceId = typeof body.device_id === "string" ? body.device_id : null;

    // 1. Pending invites addressed to this user's email, not expired.
    const { data: invites } = await supabase
      .from("pending_trip_invites")
      .select("id, trip_id, permission, invited_by, referral_code")
      .eq("email", email)
      .gt("expires_at", new Date().toISOString());
    if (!invites || invites.length === 0) {
      return reply(200, { ok: true, joined: 0 });
    }

    // 2. Auto-join every trip (idempotent). A FIRST-TIME insert fires the
    // existing collaborator_added notification; conflicting retries are
    // no-ops and are not counted (ON CONFLICT DO NOTHING returns no rows).
    let joined = 0;
    for (const inv of invites) {
      const { data: inserted, error: cErr } = await supabase
        .from("trip_collaborators")
        .upsert(
          {
            trip_id: inv.trip_id,
            user_id: user.id,
            email,
            permission: inv.permission,
            invited_by: inv.invited_by,
          },
          { onConflict: "trip_id,user_id", ignoreDuplicates: true },
        )
        .select("trip_id");
      if (cErr) {
        console.error("claim-invites: collaborator upsert failed", cErr);
      } else if (inserted && inserted.length > 0) {
        joined++; // only genuine new joins
      }
    }

    // 3. Referral reward (best-effort). Skip if the user already has a
    // referral (they typed a code) — UNIQUE(referee) keeps it single.
    //
    // SAME anti-abuse defenses as redeem-referral (the typed-code path):
    // account self-referral, DEVICE self-referral (second account on the
    // referrer's own phone), and the 14-day account-age window. Skipping
    // any of them here would make the invite channel a self-referral farm.
    let referralDone = true;
    const { data: existingReferral } = await supabase
      .from("referrals")
      .select("id")
      .eq("referee_user_id", user.id)
      .maybeSingle();

    if (!existingReferral) {
      const code = invites[0].referral_code;
      const { data: codeRow } = await supabase
        .from("referral_codes")
        .select("user_id")
        .eq("code", code)
        .maybeSingle();
      const referrerId = codeRow?.user_id as string | undefined;

      // 14-day redemption window (mirrors redeem-referral).
      const createdAtMs = Date.parse(user.created_at ?? "");
      const withinWindow = Number.isFinite(createdAtMs) &&
        Date.now() - createdAtMs <= 14 * 86_400_000;

      // Device self-referral: is this the referrer's own device?
      let sameDeviceAsReferrer = false;
      if (deviceId && referrerId) {
        const { data: deviceRow } = await supabase
          .from("trial_devices")
          .select("user_id")
          .eq("device_id", deviceId)
          .maybeSingle();
        sameDeviceAsReferrer = deviceRow?.user_id === referrerId;
      }

      if (
        referrerId && referrerId !== user.id &&
        withinWindow && !sameDeviceAsReferrer
      ) {
        // Grant the new user their 30 days first; only record the referral
        // on success so a failure leaves no half-state and retries next claim.
        const granted = await grantPromotionalMonth(user.id);
        if (granted) {
          const { error: insErr } = await supabase.from("referrals").insert({
            referrer_user_id: referrerId,
            referee_user_id: user.id,
            code,
            referee_rewarded_at: new Date().toISOString(),
          });
          // 23505 = a concurrent path already created it: fine.
          if (insErr && (insErr as { code?: string }).code !== "23505") {
            console.error("claim-invites: referrals insert failed", insErr);
            referralDone = false;
          }
        } else {
          referralDone = false; // keep pending rows for a retry
        }
      }
      // referrerId missing / account-self / same-device-self / window
      // expired → the reward is TERMINALLY skipped (referralDone stays
      // true, pending rows get cleaned up below). The trip auto-join above
      // still completed — only the reward is withheld.
    }

    // 4. Delete the pending invites only once everything settled. If the
    // referral grant failed, keep them so the next claim retries (the
    // collaborator upsert above is idempotent).
    if (referralDone) {
      await supabase
        .from("pending_trip_invites")
        .delete()
        .in("id", invites.map((i) => i.id));
    }

    console.log(`claim-invites: ${user.id} joined ${joined} trip(s), referral=${referralDone}`);
    return reply(200, { ok: true, joined, referral: referralDone });
  } catch (e) {
    const errorId = crypto.randomUUID();
    console.error(`claim-invites error [${errorId}]:`, e);
    return reply(500, { ok: false, reason: "server_error", id: errorId });
  }
});
