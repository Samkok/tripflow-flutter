// Supabase Edge Function: Subscription Reconciliation
// Safety net for the revenuecat-webhook. Periodically (via pg_cron) re-checks
// user_subscriptions rows against the RevenueCat REST API and:
//   - expires `active` rows RevenueCat no longer grants the entitlement for,
//   - heals `active` rows whose product/expiry drifted from RevenueCat (e.g.
//     TRANSFER rows left with NULL expires_at), and
//   - revives `expired` rows RevenueCat says are active again. That is what a
//     dead webhook leaves behind: from 2026-08-24 to 09-22 no purchase or
//     renewal reached the table, every row drifted to `expired`, and nothing
//     could bring one back because only `active` rows were ever re-checked.
//
// Which rows: every `active` row, plus `expired` rows updated in the last
// RECHECK_EXPIRED_DAYS (an outage shows up as rows that went quiet).
// POST {"scope":"all"} re-checks every expired row regardless of age — a
// manual, capped backfill after a long outage.
//
// A row that does not exist cannot be reconciled: someone whose very first
// purchase was lost has no row until the webhook delivers their next event.
//
// RevenueCat is the source of truth; we reconcile against it instead of relying
// on every event being routable. Unknown (API error) = change nothing.
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

// Expired rows younger than this are re-checked every run (one RC call each);
// older ones only on a manual scope=all run.
const RECHECK_EXPIRED_DAYS = 90;
// Per-run caps keep a run well inside the function's wall-clock budget
// (roughly 0.3 s per RevenueCat call).
const MAX_RECENT_EXPIRED = 150;
const MAX_ALL_EXPIRED = 500;

interface RcEntitlementState {
  isActive: boolean;
  productIdentifier: string | null;
  expiresAt: string | null; // ISO 8601, or null for lifetime
  periodType: string | null;
  store: string | null;
  willRenew: boolean;
  purchaseDate: string | null; // ISO 8601: latest purchase/renewal of that product
  unsubscribeDetectedAt: string | null;
  billingIssuesDetectedAt: string | null;
}

interface SubscriptionRow {
  user_id: string;
  revenuecat_app_user_id: string | null;
  status: string;
  product_identifier: string | null;
  expires_at: string | null;
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

    // The v1 subscriber object carries no will_renew, so derive it: a dated,
    // active subscription renews unless RevenueCat has seen auto-renew
    // switched off; a lifetime unlock has nothing to renew.
    const unsubscribeDetectedAt: string | null =
      sub?.unsubscribe_detected_at ?? null;
    const willRenew =
      isActive && expiresDate !== null && unsubscribeDetectedAt === null;

    return {
      isActive,
      productIdentifier: productId,
      expiresAt: expiresDate,
      periodType: sub?.period_type ?? null,
      store: sub?.store ? String(sub.store).toUpperCase() : null,
      willRenew,
      purchaseDate: sub?.purchase_date ?? ent?.purchase_date ?? null,
      unsubscribeDetectedAt,
      billingIssuesDetectedAt: sub?.billing_issues_detected_at ?? null,
    };
  } catch (e) {
    console.error(`Failed to fetch RC state for ${appUserId} (skipping):`, e);
    return null;
  }
}

/**
 * Write RevenueCat's view of a row. With `state` null the row is expired and
 * its product/expiry details are left as they were (the RPC keeps existing
 * values for null inputs). Every write is audited as a RECONCILE event.
 */
async function writeRow(
  row: SubscriptionRow,
  status: "active" | "expired",
  state: RcEntitlementState | null,
) {
  const { error } = await supabase.rpc("upsert_subscription_status", {
    p_user_id: row.user_id,
    p_revenuecat_app_user_id: row.revenuecat_app_user_id ?? row.user_id,
    p_status: status,
    p_entitlement: ENTITLEMENT,
    p_product_identifier: state?.productIdentifier ?? null,
    p_store: state?.store ?? null,
    p_expires_at: state?.expiresAt ?? null,
    p_period_type: state?.periodType ?? null,
    p_purchase_date: state?.purchaseDate ?? null,
    p_will_renew: state?.willRenew ?? false,
    p_billing_issues_detected_at: state?.billingIssuesDetectedAt ?? null,
    p_unsubscribe_detected_at: state?.unsubscribeDetectedAt ?? null,
    p_event_type: "RECONCILE",
  });
  return error;
}

/** `{"scope":"all"}` widens the expired-row pass; anything else is the default. */
async function readScope(req: Request): Promise<"recent" | "all"> {
  try {
    const body = await req.json();
    return body?.scope === "all" ? "all" : "recent";
  } catch {
    return "recent";
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

  const scope = await readScope(req);

  const summary = {
    scope,
    checked: 0,
    active_rows: 0,
    expired_rows: 0,
    expired: 0,
    revived: 0,
    healed: 0,
    skipped_unknown: 0,
    unchanged: 0,
    errors: 0,
  };

  try {
    const columns =
      "user_id, revenuecat_app_user_id, status, product_identifier, expires_at";

    const { data: activeRows, error: activeErr } = await supabase
      .from("user_subscriptions")
      .select(columns)
      .eq("status", "active");
    if (activeErr) {
      console.error("Failed to load active subscriptions:", activeErr);
      return new Response(
        JSON.stringify({ error: "DB read failed" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    // Most recently touched first, so a capped run still covers the rows most
    // likely to have changed.
    const expiredQuery = supabase
      .from("user_subscriptions")
      .select(columns)
      .eq("status", "expired")
      .order("updated_at", { ascending: false });
    const since = new Date(
      Date.now() - RECHECK_EXPIRED_DAYS * 86_400_000,
    ).toISOString();
    const { data: expiredRows, error: expiredErr } = scope === "all"
      ? await expiredQuery.limit(MAX_ALL_EXPIRED)
      : await expiredQuery.gte("updated_at", since).limit(MAX_RECENT_EXPIRED);
    if (expiredErr) {
      console.error("Failed to load expired subscriptions:", expiredErr);
      return new Response(
        JSON.stringify({ error: "DB read failed" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    const rows: SubscriptionRow[] = [
      ...((activeRows ?? []) as SubscriptionRow[]),
      ...((expiredRows ?? []) as SubscriptionRow[]),
    ];
    summary.active_rows = activeRows?.length ?? 0;
    summary.expired_rows = expiredRows?.length ?? 0;

    for (const row of rows) {
      summary.checked++;

      // Reconcile against the id RevenueCat actually keys this subscriber by.
      const rcId: string = row.revenuecat_app_user_id ?? row.user_id;
      const state = await fetchRcEntitlementState(rcId);

      if (state === null) {
        // Unknown (API error / missing key) — never change on uncertainty.
        summary.skipped_unknown++;
        continue;
      }

      if (row.status !== "active") {
        // An expired row: only RevenueCat saying "active" changes anything.
        if (!state.isActive) {
          summary.unchanged++;
          continue;
        }
        const err = await writeRow(row, "active", state);
        if (err) {
          console.error(`Failed to revive ${row.user_id}:`, err);
          summary.errors++;
        } else {
          console.log(
            `Revived ${row.user_id} (RC: active ${ENTITLEMENT}, expires ${state.expiresAt ?? "never"})`,
          );
          summary.revived++;
        }
        continue;
      }

      if (!state.isActive) {
        // RevenueCat no longer grants the entitlement → expire the stuck row.
        const err = await writeRow(row, "expired", null);
        if (err) {
          console.error(`Failed to expire ${row.user_id}:`, err);
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
        const err = await writeRow(row, "active", state);
        if (err) {
          console.error(`Failed to heal ${row.user_id}:`, err);
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
