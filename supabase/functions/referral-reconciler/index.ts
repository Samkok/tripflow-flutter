// referral-reconciler — daily sweep of the referral payout backlog.
//
// The webhook is event-driven: 'qualified' rows deferred by the 12/365d cap
// or the 365-day promo-stack limit, and 'banked' rows whose referrer's paid
// plan lapsed WITHOUT emitting a usable event (billing quirks, very old
// events, RC outages during the lapse), would otherwise wait for the
// referee's or referrer's next webhook event — which may never come. This
// function sweeps them on a schedule so no earned month is stranded.
//
// For each backlog row (oldest first, batch-limited):
//   qualified + referrer paying      → move to 'banked'
//   qualified + referrer not paying  → pay out (cap + CAS + grant)
//   banked    + referrer not paying  → pay out (cap + CAS + grant)
//   banked    + referrer paying      → leave (still banked)
//
// Auth: verify_jwt=true AND an in-function role=service_role claim check —
// same defense-in-depth as reconcile-subscriptions (the platform validates
// the signature; the claim check blocks anon-key callers).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const revenueCatSecretApiKey = Deno.env.get("REVENUECAT_SECRET_API_KEY");
const resendKey = Deno.env.get("RESEND_API_KEY");

const supabase = createClient(supabaseUrl, supabaseServiceRoleKey);

const ENTITLEMENT = "premium";
const CAP_PER_365D = 12;
const BATCH_LIMIT = 50;

/** See revenuecat-webhook: promotional expiry + whether store-paid is live. */
async function getReferrerEntitlementState(
  rcAppUserId: string,
): Promise<{ promoExpiresMs: number | null; paidActive: boolean } | null> {
  if (!revenueCatSecretApiKey) return null;
  try {
    const res = await fetch(
      `https://api.revenuecat.com/v1/subscribers/${
        encodeURIComponent(rcAppUserId)
      }`,
      { headers: { "Authorization": `Bearer ${revenueCatSecretApiKey}` } },
    );
    if (!res.ok) return null;
    const data = await res.json();
    const ent = data?.subscriber?.entitlements?.[ENTITLEMENT];
    if (!ent) return { promoExpiresMs: null, paidActive: false };
    const isPromo = typeof ent.product_identifier === "string" &&
      ent.product_identifier.startsWith("rc_promo_");
    const expiresMs = ent.expires_date ? Date.parse(ent.expires_date) : null;
    if (isPromo) {
      return {
        promoExpiresMs: expiresMs !== null && Number.isFinite(expiresMs)
          ? expiresMs
          : null,
        paidActive: false,
      };
    }
    const paidActive = expiresMs === null || expiresMs > Date.now();
    return { promoExpiresMs: null, paidActive };
  } catch (_) {
    return null;
  }
}

/** Same extend-don't-overwrite grant math as the webhook. */
async function grantPromotionalMonth(
  rcAppUserId: string,
  existingPromoExpiresMs: number | null,
): Promise<boolean> {
  if (!revenueCatSecretApiKey) return false;
  const now = Date.now();
  const remainingDays = existingPromoExpiresMs && existingPromoExpiresMs > now
    ? (existingPromoExpiresMs - now) / 86_400_000
    : 0;
  const targetDays = remainingDays + 30;
  if (targetDays > 365) {
    console.log("reconciler: promo stack too long to extend — deferring");
    return false;
  }
  const duration = targetDays <= 30
    ? "monthly"
    : targetDays <= 60
    ? "two_month"
    : targetDays <= 90
    ? "three_month"
    : targetDays <= 180
    ? "six_month"
    : "yearly";
  const res = await fetch(
    `https://api.revenuecat.com/v1/subscribers/${
      encodeURIComponent(rcAppUserId)
    }/entitlements/${ENTITLEMENT}/promotional`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${revenueCatSecretApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ duration }),
    },
  );
  if (!res.ok) {
    console.error(
      "reconciler: promotional grant failed",
      res.status,
      await res.text(),
    );
    return false;
  }
  console.log(`reconciler: granted ${duration} promo to ${rcAppUserId}`);
  return true;
}

async function sendRewardEmail(userId: string, monthsThisYear: number) {
  if (!resendKey) return;
  try {
    const from = Deno.env.get("LIFECYCLE_FROM") ??
      "VoyZa <onboarding@resend.dev>";
    const { data: profile } = await supabase
      .from("user_profiles").select("email").eq("user_id", userId)
      .maybeSingle();
    if (!profile?.email) return;
    const p = "margin:0 0 12px;color:#46535f;font-size:15px;line-height:1.5";
    const html =
      `<div style="background:#f4f6f8;padding:24px;font-family:-apple-system,'Segoe UI',Roboto,sans-serif">` +
      `<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden;border:1px solid #e6e9ee">` +
      `<div style="background:linear-gradient(135deg,#2B1D70,#2E5BD0 60%,#15BFB6);padding:22px 24px;color:#fff;font-weight:800;font-size:20px">VoyZa</div>` +
      `<div style="padding:24px">` +
      `<h1 style="margin:0 0 14px;font-size:22px;color:#16202b">You earned a free month of Pro! 🎉</h1>` +
      `<p style="${p}">A referral month just landed on your account — <strong>30 days of Pro</strong>.</p>` +
      `<p style="${p}">That's ${monthsThisYear} of 12 free months earned this year. Keep sharing your code to earn more.</p>` +
      `</div>` +
      `<div style="padding:16px 24px;color:#9aa4ad;font-size:12px;border-top:1px solid #eef1f4">VoyZa · voyza.xtremon.com</div>` +
      `</div></div>`;
    await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from,
        to: profile.email,
        subject: "You earned a free month of VoyZa Pro",
        html,
      }),
    });
  } catch (e) {
    console.error("reconciler: reward email failed (non-fatal):", e);
  }
}

function jwtRole(authHeader: string): string | null {
  const token = authHeader.replace(/^Bearer\s+/i, "");
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const pad = b64.length % 4 ? "=".repeat(4 - (b64.length % 4)) : "";
    return (JSON.parse(atob(b64 + pad)).role as string) ?? null;
  } catch {
    return null;
  }
}

serve(async (req) => {
  if (jwtRole(req.headers.get("Authorization") ?? "") !== "service_role") {
    console.warn("reconciler: rejected caller without service_role claim");
    return new Response(JSON.stringify({ error: "Forbidden" }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    });
  }

  const summary = {
    scanned: 0,
    granted: 0,
    banked: 0,
    left_banked: 0,
    deferred: 0,
    skipped_rc_unknown: 0,
    errors: 0,
  };

  try {
    const { data: rows, error } = await supabase
      .from("referrals")
      .select("id, referrer_user_id, status")
      .in("status", ["qualified", "banked"])
      .is("rewarded_at", null)
      .order("created_at", { ascending: true })
      .limit(BATCH_LIMIT);
    if (error) throw error;
    summary.scanned = rows?.length ?? 0;
    if (!rows || rows.length === 0) {
      return new Response(JSON.stringify(summary), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // Group by referrer: one RC read per referrer, sequential payouts so the
    // extend math composes.
    const byReferrer = new Map<string, typeof rows>();
    for (const r of rows) {
      const list = byReferrer.get(r.referrer_user_id) ?? [];
      list.push(r);
      byReferrer.set(r.referrer_user_id, list);
    }

    for (const [referrerId, backlog] of byReferrer) {
      let entState = await getReferrerEntitlementState(referrerId);
      if (entState === null) {
        summary.skipped_rc_unknown += backlog.length;
        continue; // RC unreachable — never guess
      }

      for (const row of backlog) {
        try {
          if (entState.paidActive) {
            if (row.status === "qualified") {
              // Referrer is paying → this earned month should be banked.
              const { data: b } = await supabase
                .from("referrals")
                .update({
                  status: "banked",
                  banked_at: new Date().toISOString(),
                })
                .eq("id", row.id)
                .eq("status", "qualified")
                .is("rewarded_at", null)
                .select("id");
              if (b && b.length > 0) summary.banked++;
            } else {
              summary.left_banked++; // banked + still paying: correct state
            }
            continue;
          }

          // Not paying → pay out, cap-checked.
          const since = new Date(Date.now() - 365 * 86_400_000).toISOString();
          const { count } = await supabase
            .from("referrals")
            .select("id", { count: "exact", head: true })
            .eq("referrer_user_id", referrerId)
            .eq("status", "rewarded")
            .gte("rewarded_at", since);
          if ((count ?? 0) >= CAP_PER_365D) {
            summary.deferred += 1;
            break; // cap reached for this referrer — rest of backlog waits
          }

          const { data: claimed } = await supabase
            .from("referrals")
            .update({
              status: "rewarded",
              rewarded_at: new Date().toISOString(),
            })
            .eq("id", row.id)
            .in("status", ["qualified", "banked"])
            .is("rewarded_at", null)
            .select("id");
          if (!claimed || claimed.length === 0) continue; // race — skip

          const granted = await grantPromotionalMonth(
            referrerId,
            entState.promoExpiresMs,
          );
          if (!granted) {
            await supabase
              .from("referrals")
              .update({ status: row.status, rewarded_at: null })
              .eq("id", row.id);
            summary.deferred += 1;
            break; // stack limit / RC failure — retry next run
          }

          summary.granted += 1;
          const monthsThisYear = (count ?? 0) + 1;
          await supabase.from("notifications").insert({
            user_id: referrerId,
            type: "referral_reward",
            title: "You earned a free month of VoyZa Pro! 🎉",
            body:
              `A referral month just landed — 30 days of Pro added. ` +
              `${monthsThisYear} of 12 free months earned this year.`,
            data: { screen: "referral" },
          });
          await sendRewardEmail(referrerId, monthsThisYear);

          // Refresh so the next payout EXTENDS the fresh promo.
          entState = (await getReferrerEntitlementState(referrerId)) ??
            entState;
        } catch (e) {
          console.error("reconciler: row failed", row.id, e);
          summary.errors += 1;
        }
      }
    }

    console.log("reconciler summary:", JSON.stringify(summary));
    return new Response(JSON.stringify(summary), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("reconciler: fatal", e);
    summary.errors += 1;
    return new Response(JSON.stringify(summary), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
