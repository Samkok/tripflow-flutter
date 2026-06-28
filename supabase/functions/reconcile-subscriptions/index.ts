// Supabase Edge Function: Subscription Reconciliation
// Safety net for the revenuecat-webhook. Periodically (via pg_cron) re-checks
// every `active` row in user_subscriptions against the RevenueCat REST API and:
//   - expires rows RevenueCat no longer grants the entitlement for, and
//   - heals rows whose product/expiry drifted from RevenueCat (e.g. TRANSFER
//     rows left with NULL expires_at).
//
// This closes the gap where lifecycle events (CANCELLATION/EXPIRATION) keep
// arriving under an original/anonymous RC id the webhook can't map back to the
// account, leaving it stuck 'active' = free access. RevenueCat is the source of
// truth; we reconcile against it instead of relying on every event being routable.
//
// Auth: verify_jwt = true AND an in-function role=service_role claim check
// (verify_jwt alone also accepts the PUBLIC anon key). The pg_cron caller sends
// the project's service_role key as the Bearer token. No public access.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const revenueCatSecretApiKey = Deno.env.get("REVENUECAT_SECRET_API_KEY");

const supabase = createClient(supabaseUrl, supabaseServiceRoleKey);

const ENTITLEMENT = "premium";

interface RcEntitlementState {
  isActive: boolean;
  productIdentifier: string | null;
  expiresAt: string | null; // ISO 8601, or null for lifetime
  periodType: string | null;
  store: string | null;
  willRenew: boolean;
}

/**
 * Fetch the live entitlement state for a subscriber from RevenueCat.
 * Returns null when the API call fails — callers MUST treat null as
 * "unknown, do not change anything" so a transient RC outage never revokes
 * a paying user's access.
 */
async function fetchRcEntitlementState(
  appUserId: string,
): Promise<RcEntitlementState | null> {
  if (!revenueCatSecretApiKey) {
    console.warn("REVENUECAT_SECRET_API_KEY not set — cannot reconcile");
    return null;
  }

  try {
    const url = `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`;
    const res = await fetch(url, {
      headers: {
        Authorization: `Bearer ${revenueCatSecretApiKey}`,
        "Content-Type": "application/json",
      },
    });

    if (!res.ok) {
      console.warn(`RC API ${res.status} for ${appUserId} — skipping (fail-safe)`);
      return null;
    }

    const data = await res.json();
    const subscriber = data?.subscriber;
    if (!subscriber) {
      console.warn(`RC API: no subscriber object for ${appUserId} — skipping`);
      return null;
    }

    const ent = subscriber.entitlements?.[ENTITLEMENT];
    const productId: string | null = ent?.product_identifier ?? null;
    const sub = productId ? subscriber.subscriptions?.[productId] : null;
    const expiresDate: string | null =
      ent?.expires_date ?? sub?.expires_date ?? null;

    // Active if the entitlement is granted AND (lifetime [no expiry] OR not past).
    const now = Date.now();
    const isActive = !!ent &&
      (expiresDate === null || new Date(expiresDate).getTime() > now);

    return {
      isActive,
      productIdentifier: productId,
      expiresAt: expiresDate,
      periodType: sub?.period_type ?? null,
      store: sub?.store ? String(sub.store).toUpperCase() : null,
      willRenew: sub?.will_renew ?? false,
    };
  } catch (e) {
    console.error(`Failed to fetch RC state for ${appUserId} (skipping):`, e);
    return null;
  }
}

/**
 * Extract the `role` claim from a Supabase JWT Authorization header.
 * Signature is NOT verified here — the platform already did that (verify_jwt=true);
 * we only need the claim to distinguish service_role (the cron) from anon (public).
 */
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
  // Defense-in-depth: verify_jwt=true only proves the JWT is validly signed —
  // the PUBLIC anon key also passes it. Require role=service_role so only the
  // pg_cron job (which sends the service_role key) can trigger reconciliation;
  // blocks anon-key callers from amplifying RevenueCat API cost / invocations.
  // Checking the claim (not a fixed key string) is rotation- and format-safe.
  if (jwtRole(req.headers.get("Authorization") ?? "") !== "service_role") {
    console.warn("reconcile: rejected caller without service_role claim");
    return new Response(JSON.stringify({ error: "Forbidden" }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    });
  }

  const summary = {
    checked: 0,
    expired: 0,
    healed: 0,
    skipped_unknown: 0,
    unchanged: 0,
    errors: 0,
  };

  try {
    const { data: rows, error } = await supabase
      .from("user_subscriptions")
      .select("user_id, revenuecat_app_user_id, status, product_identifier, expires_at")
      .eq("status", "active");

    if (error) {
      console.error("Failed to load active subscriptions:", error);
      return new Response(
        JSON.stringify({ error: "DB read failed" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    for (const row of rows ?? []) {
      summary.checked++;

      // Reconcile against the id RevenueCat actually keys this subscriber by.
      const rcId: string = row.revenuecat_app_user_id ?? row.user_id;
      const state = await fetchRcEntitlementState(rcId);

      if (state === null) {
        // Unknown (API error / missing key) — never change on uncertainty.
        summary.skipped_unknown++;
        continue;
      }

      if (!state.isActive) {
        // RevenueCat no longer grants the entitlement → expire the stuck row.
        const { error: rpcErr } = await supabase.rpc("upsert_subscription_status", {
          p_user_id: row.user_id,
          p_revenuecat_app_user_id: row.revenuecat_app_user_id ?? row.user_id,
          p_status: "expired",
          p_entitlement: ENTITLEMENT,
          p_product_identifier: null,
          p_store: null,
          p_expires_at: null,
          p_period_type: null,
          p_purchase_date: null,
          p_will_renew: false,
          p_billing_issues_detected_at: null,
          p_unsubscribe_detected_at: null,
          p_event_type: "RECONCILE",
        });
        if (rpcErr) {
          console.error(`Failed to expire ${row.user_id}:`, rpcErr);
          summary.errors++;
        } else {
          console.log(`Expired ${row.user_id} (RC: no active ${ENTITLEMENT})`);
          summary.expired++;
        }
        continue;
      }

      // RC says active. Heal the row only if product/expiry drifted (e.g. a
      // TRANSFER row left with NULL expires_at). Skip no-op writes so we don't
      // spam user_subscription_history.
      const rowExpiryMs = new Date(row.expires_at ?? 0).getTime();
      const rcExpiryMs = new Date(state.expiresAt ?? 0).getTime();
      const expiryDrift = rowExpiryMs !== rcExpiryMs;
      const productDrift =
        (row.product_identifier ?? null) !== (state.productIdentifier ?? null) &&
        state.productIdentifier !== null;

      if (expiryDrift || productDrift) {
        const { error: rpcErr } = await supabase.rpc("upsert_subscription_status", {
          p_user_id: row.user_id,
          p_revenuecat_app_user_id: row.revenuecat_app_user_id ?? row.user_id,
          p_status: "active",
          p_entitlement: ENTITLEMENT,
          p_product_identifier: state.productIdentifier,
          p_store: state.store,
          p_expires_at: state.expiresAt,
          p_period_type: state.periodType,
          p_purchase_date: null,
          p_will_renew: state.willRenew,
          p_billing_issues_detected_at: null,
          p_unsubscribe_detected_at: null,
          p_event_type: "RECONCILE",
        });
        if (rpcErr) {
          console.error(`Failed to heal ${row.user_id}:`, rpcErr);
          summary.errors++;
        } else {
          console.log(`Healed ${row.user_id} (backfilled product/expiry from RC)`);
          summary.healed++;
        }
      } else {
        summary.unchanged++;
      }
    }

    console.log("Reconciliation summary:", summary);
    return new Response(JSON.stringify({ message: "Reconciliation complete", summary }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("Reconciliation handler error:", e);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
