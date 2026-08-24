// Supabase Edge Function: RevenueCat Webhook Handler
// Receives webhook events from RevenueCat and updates user_subscriptions table
// Enables real-time subscription expiration detection via Supabase Realtime

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

// ============================================================================
// Types
// ============================================================================

interface RevenueCatWebhookEvent {
  event: {
    type: string;
    app_user_id?: string;       // Not present in TRANSFER events
    aliases?: string[];          // All app_user_ids RevenueCat links to this subscriber
    original_app_user_id?: string; // First app_user_id ever seen for this subscriber
    transferred_from?: string[]; // TRANSFER events only
    transferred_to?: string[];   // TRANSFER events only
    product_id?: string;
    new_product_id?: string;
    entitlement_ids?: string[];
    period_type?: string;
    purchased_at_ms?: number;
    expiration_at_ms?: number;
    store?: string;
    is_trial_period?: boolean;
    will_renew?: boolean;
    billing_issues_detected_at_ms?: number;
    unsubscribe_detected_at_ms?: number;
    [key: string]: any;
  };
  api_version: string;
}

// ============================================================================
// Configuration
// ============================================================================

// Event types we care about
// Based on: https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields
const RELEVANT_EVENTS = [
  // Core subscription lifecycle
  'INITIAL_PURCHASE',
  'RENEWAL',
  'CANCELLATION',
  'UNCANCELLATION',
  'EXPIRATION',

  // Billing & refunds
  'BILLING_ISSUE',
  'REFUND',
  'REFUND_REVERSED',

  // Product changes
  'PRODUCT_CHANGE',
  'NON_RENEWING_PURCHASE',

  // Android-specific
  'SUBSCRIPTION_PAUSED',
  'SUBSCRIPTION_EXTENDED',

  // Advanced
  'TRANSFER',
  'TEMPORARY_ENTITLEMENT_GRANT',

  // Testing
  'TEST'
];

// Initialize Supabase client with service role (has write access to user_subscriptions)
const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const supabase = createClient(supabaseUrl, supabaseServiceRoleKey);

// RevenueCat webhook authorization key (optional but recommended)
const revenueCatAuthKey = Deno.env.get('REVENUECAT_WEBHOOK_AUTH_KEY');

// RevenueCat secret API key — used to fetch full subscriber details via REST API.
// Required for resolving product/expiry data on TRANSFER events.
// Set this in Supabase Edge Function secrets: REVENUECAT_SECRET_API_KEY
const revenueCatSecretApiKey = Deno.env.get('REVENUECAT_SECRET_API_KEY');

// ============================================================================
// Types
// ============================================================================

interface RevenueCatSubscriberData {
  product_identifier: string | null;
  expires_at: string | null;
  period_type: string | null;
  store: string | null;
  will_renew: boolean;
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Fetches a subscriber's full subscription details from the RevenueCat REST API.
 * Used during TRANSFER events where the webhook payload carries no product/expiry data.
 *
 * Requires REVENUECAT_SECRET_API_KEY to be set in edge function secrets.
 * Returns null if the key is missing, the user is not found, or the call fails.
 */
async function fetchRevenueCatSubscriber(
  appUserId: string,
  entitlementId: string,
): Promise<RevenueCatSubscriberData | null> {
  if (!revenueCatSecretApiKey) {
    console.warn('REVENUECAT_SECRET_API_KEY not set — cannot fetch subscriber data from RC API');
    return null;
  }

  try {
    const url = `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`;
    const response = await fetch(url, {
      headers: {
        'Authorization': `Bearer ${revenueCatSecretApiKey}`,
        'Content-Type': 'application/json',
      },
    });

    if (!response.ok) {
      console.warn(`RevenueCat API returned ${response.status} for subscriber ${appUserId}`);
      return null;
    }

    const data = await response.json();
    const subscriber = data?.subscriber;

    if (!subscriber) {
      console.warn(`RevenueCat API: no subscriber object for ${appUserId}`);
      return null;
    }

    // The entitlement object contains product_identifier and expires_date
    const entitlementInfo = subscriber.entitlements?.[entitlementId];
    const productId: string | null = entitlementInfo?.product_identifier ?? null;

    // The subscription object (keyed by product_id) contains period_type, store, will_renew
    const subscriptionInfo = productId ? subscriber.subscriptions?.[productId] : null;

    // expires_date is ISO 8601 from RC; prefer the entitlement-level date
    const expiresDate: string | null =
      entitlementInfo?.expires_date ?? subscriptionInfo?.expires_date ?? null;

    return {
      product_identifier: productId,
      expires_at:         expiresDate,
      period_type:        subscriptionInfo?.period_type ?? null,
      store:              subscriptionInfo?.store       ?? null,
      will_renew:         subscriptionInfo?.will_renew  ?? true,
    };
  } catch (e) {
    console.error(`Failed to fetch RevenueCat subscriber data for ${appUserId}:`, e);
    return null;
  }
}

function isValidUUID(str: string): boolean {
  const uuidRegex =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i; // versioned UUID
  return uuidRegex.test(str);
}

function isRevenueCatAnonymousId(str: string): boolean {
  // $RCAnonymousID:<32 hex>
  return /^\$RCAnonymousID:[0-9a-f]{32}$/i.test(str);
}

function isValidAppUserId(str: string): boolean {
  return isValidUUID(str) || isRevenueCatAnonymousId(str);
}

/**
 * Given an anonymous-keyed event, find the authenticated Supabase account (if any)
 * that already owns this subscription. Without this, lifecycle events that keep
 * arriving under the original $RCAnonymousID (e.g. when RevenueCat's transfer
 * behavior is "keep with original App User ID") would never reach the account that
 * received the subscription on signup — leaving that account stuck 'active' and
 * granting free access after the subscription actually ends.
 *
 * Resolution order:
 *   1. Any alias on the event that is a real Supabase UUID → that's the owner.
 *   2. A user_subscriptions row that recorded this anonymous id in
 *      revenuecat_app_user_id (written by the client syncTrialSubscription on
 *      signup, or by a previous run of this resolver).
 *
 * Returns null when the subscriber is genuinely anonymous (not yet signed up).
 */
async function resolveAuthenticatedOwner(
  anonAppUserId: string,
  aliases: string[],
): Promise<string | null> {
  // 1. Any alias that is a real Supabase UUID is the owner.
  const aliasUuid = aliases.find(isValidUUID);
  if (aliasUuid) {
    console.log(`  resolver: matched authenticated owner via alias ${aliasUuid}`);
    return aliasUuid;
  }

  // 2. Our DB may already hold a row that recorded this anonymous id.
  try {
    const { data } = await supabase
      .from('user_subscriptions')
      .select('user_id')
      .eq('revenuecat_app_user_id', anonAppUserId)
      .maybeSingle();
    if (data?.user_id && isValidUUID(data.user_id)) {
      console.log(`  resolver: matched authenticated owner via DB row ${data.user_id}`);
      return data.user_id;
    }
  } catch (e) {
    // Non-fatal: if the column/query fails, fall through to "no owner".
    console.warn('  resolver: DB lookup by revenuecat_app_user_id failed (non-fatal):', e);
  }

  return null;
}

/**
 * Infers will_renew from RevenueCat webhook event type
 * RevenueCat webhooks do NOT include a will_renew field in the payload
 *
 * Reference: https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields
 */
function inferWillRenew(eventType: string): boolean {
  // Auto-renewable subscription events
  const renewableEvents = [
    'INITIAL_PURCHASE',
    'RENEWAL',
    'UNCANCELLATION',
    'PRODUCT_CHANGE',
    'SUBSCRIPTION_EXTENDED',
    'REFUND_REVERSED',
    'TEST'
  ];

  // Non-renewable or cancelled events
  const nonRenewableEvents = [
    'CANCELLATION',
    'BILLING_ISSUE',
    'EXPIRATION',
    'SUBSCRIPTION_PAUSED',
    'NON_RENEWING_PURCHASE',
    'REFUND'
  ];

  if (renewableEvents.includes(eventType)) {
    return true;
  }

  if (nonRenewableEvents.includes(eventType)) {
    return false;
  }

  // TRANSFER and unknown events: default to false for safety
  return false;
}

/**
 * Determines subscription status from RevenueCat webhook event
 * Follows best practices from: https://www.revenuecat.com/docs/integrations/webhooks/event-flows
 *
 * Key principles:
 * - CANCELLATION keeps status 'active' during grace period
 * - BILLING_ISSUE treated same as CANCELLATION (fires simultaneously)
 * - SUBSCRIPTION_PAUSED keeps access until period end
 */
function determineSubscriptionStatus(
  eventType: string,
  expirationDate: Date | null,
  now: Date
): string {
  console.log(`Determining status for event: ${eventType}, expires: ${expirationDate}`);

  // Active subscription events - immediately active
  const activeEvents = [
    'INITIAL_PURCHASE',
    'RENEWAL',
    'UNCANCELLATION',
    'PRODUCT_CHANGE',
    'SUBSCRIPTION_EXTENDED',
    'REFUND_REVERSED'
  ];

  if (activeEvents.includes(eventType)) {
    return 'active';
  }

  // Expired subscription events - immediately expired
  if (eventType === 'EXPIRATION' || eventType === 'REFUND') {
    return 'expired';
  }

  // Grace period events - user keeps access until expiration
  // Per RevenueCat docs: BILLING_ISSUE fires with CANCELLATION
  const gracePeriodEvents = [
    'CANCELLATION',
    'BILLING_ISSUE',
    'SUBSCRIPTION_PAUSED'
  ];

  if (gracePeriodEvents.includes(eventType)) {
    if (expirationDate && expirationDate > now) {
      return 'active';  // Grace period - user still has access
    }
    return 'expired';  // Past expiration
  }

  // Non-renewing purchase. A LIFETIME unlock (non-consumable in-app product)
  // arrives as this event with NO expiration — that is permanently active,
  // not expired. Only a dated non-renewing purchase (a fixed-length pass)
  // can lapse.
  if (eventType === 'NON_RENEWING_PURCHASE') {
    if (expirationDate === null || expirationDate > now) {
      return 'active';
    }
    return 'expired';
  }

  // TRANSFER is handled upstream with an early return before this function's
  // result is used. It never reaches this branch.

  // TEST event
  if (eventType === 'TEST') {
    return 'active';
  }

  // Unknown event type - future-proof fallback
  // Check expiration to determine status
  if (expirationDate && expirationDate > now) {
    return 'active';
  }
  return 'expired';
}

// ============================================================================
// Referral rewards — "Give a month, get a month"
// ============================================================================
//
// State machine (referrals table): pending → qualified → rewarded.
// pending   — created by redeem-referral (referee already got their 30 days)
// qualified — the referee's first PAID event landed: a non-trial
//             INITIAL_PURCHASE, or any RENEWAL (which is how a trial
//             converts). Trial STARTS alone no longer qualify.
// banked    — earned while the referrer was on active paid coverage; pays
//             out when that coverage lapses (EXPIRATION hook / reconciler)
// rewarded  — the referrer's promotional grant succeeded (cap-checked)
//
// Invariants: the pending→qualified transition is a compare-and-swap, and the
// reward step only fires while rewarded_at IS NULL — so RC webhook retries can
// never double-grant, and a transiently failed grant self-heals on the
// referee's next event (e.g. RENEWAL).

const REFERRAL_ENTITLEMENT = 'premium';
const REFERRAL_CAP_PER_365D = 12;

/**
 * Grant promotional Pro time via the RevenueCat REST API. RC promotional
 * grants REPLACE any existing promotional entitlement, so when the referrer
 * already has promo time left we round UP to the smallest duration covering
 * remaining + 30 days, starting now — continuous coverage with zero gap risk,
 * at worst a few bonus days (acceptable; grants are free months anyway).
 */
async function grantPromotionalMonth(
  rcAppUserId: string,
  existingPromoExpiresMs: number | null,
): Promise<boolean> {
  if (!revenueCatSecretApiKey) {
    console.error('referral: REVENUECAT_SECRET_API_KEY not set — cannot grant');
    return false;
  }
  const now = Date.now();
  const remainingDays = existingPromoExpiresMs && existingPromoExpiresMs > now
    ? (existingPromoExpiresMs - now) / 86_400_000
    : 0;
  const targetDays = remainingDays + 30;
  // Never SHORTEN coverage: grants replace the existing promo, and 'yearly'
  // (365d) is the longest rung. Defer instead — the row stays 'qualified'
  // and self-heals on a later event once the remaining stack has shrunk.
  if (targetDays > 365) {
    console.log('referral: promo stack too long to extend now — deferring');
    return false;
  }
  // Smallest RC duration ≥ targetDays.
  const duration = targetDays <= 30
    ? 'monthly'
    : targetDays <= 60
      ? 'two_month'
      : targetDays <= 90
        ? 'three_month'
        : targetDays <= 180
          ? 'six_month'
          : 'yearly';

  const res = await fetch(
    `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(rcAppUserId)}` +
      `/entitlements/${REFERRAL_ENTITLEMENT}/promotional`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${revenueCatSecretApiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ duration }),
    },
  );
  if (!res.ok) {
    console.error('referral: promotional grant failed', res.status, await res.text());
    return false;
  }
  console.log(`referral: granted ${duration} promo to ${rcAppUserId}`);
  return true;
}

/**
 * Referrer's entitlement state, read once from RevenueCat:
 *   promoExpiresMs — expiry of a PROMOTIONAL 'premium' entitlement (for the
 *                    extend-don't-overwrite grant math), null when none.
 *   paidActive     — true when the entitlement is backed by a real STORE
 *                    product that hasn't expired. Drives BANKING: a paying
 *                    referrer's reward is parked until their plan lapses,
 *                    instead of burning under coverage they already bought.
 * Returns null when RC is unreachable — callers must treat that as
 * "unknown, change nothing" and rely on a later event / the reconciler.
 */
async function getReferrerEntitlementState(
  rcAppUserId: string,
): Promise<{ promoExpiresMs: number | null; paidActive: boolean } | null> {
  if (!revenueCatSecretApiKey) return null;
  try {
    const res = await fetch(
      `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(rcAppUserId)}`,
      { headers: { 'Authorization': `Bearer ${revenueCatSecretApiKey}` } },
    );
    if (!res.ok) return null;
    const data = await res.json();
    const ent = data?.subscriber?.entitlements?.[REFERRAL_ENTITLEMENT];
    if (!ent) return { promoExpiresMs: null, paidActive: false };
    const isPromo = typeof ent.product_identifier === 'string' &&
      ent.product_identifier.startsWith('rc_promo_');
    const expiresMs = ent.expires_date ? Date.parse(ent.expires_date) : null;
    if (isPromo) {
      return {
        promoExpiresMs:
          expiresMs !== null && Number.isFinite(expiresMs) ? expiresMs : null,
        paidActive: false,
      };
    }
    // Store-backed entitlement: active while unexpired (null expiry =
    // lifetime/non-expiring → treat as active).
    const paidActive = expiresMs === null || expiresMs > Date.now();
    return { promoExpiresMs: null, paidActive };
  } catch (_) {
    return null;
  }
}

/** In-app + email notice that a month was BANKED (not yet started). */
async function notifyMonthBanked(userId: string) {
  try {
    await supabase.from('notifications').insert({
      user_id: userId,
      type: 'referral_reward',
      title: 'Free month earned — banked for later 🎉',
      body: 'A friend you invited just went Pro. Since you already have an ' +
        'active plan, your free month is banked and starts automatically ' +
        'when your current plan ends.',
      data: { screen: 'referral' },
    });
  } catch (e) {
    console.error('referral: banked notification failed (non-fatal):', e);
  }
  const resendKey = Deno.env.get('RESEND_API_KEY');
  if (!resendKey) return;
  try {
    const from = Deno.env.get('LIFECYCLE_FROM') ?? 'VoyZa <onboarding@resend.dev>';
    const { data: profile } = await supabase
      .from('user_profiles').select('email').eq('user_id', userId).maybeSingle();
    if (!profile?.email) return;
    const p = 'margin:0 0 12px;color:#46535f;font-size:15px;line-height:1.5';
    const html =
      `<div style="background:#f4f6f8;padding:24px;font-family:-apple-system,'Segoe UI',Roboto,sans-serif">` +
      `<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden;border:1px solid #e6e9ee">` +
      `<div style="background:linear-gradient(135deg,#2B1D70,#2E5BD0 60%,#15BFB6);padding:22px 24px;color:#fff;font-weight:800;font-size:20px">VoyZa</div>` +
      `<div style="padding:24px">` +
      `<h1 style="margin:0 0 14px;font-size:22px;color:#16202b">You earned a free month — it's banked! 🎉</h1>` +
      `<p style="${p}">A friend you invited just started using VoyZa Pro, so you've earned <strong>30 days of Pro</strong>.</p>` +
      `<p style="${p}">You're already subscribed, so we've banked it: your free month starts <strong>automatically when your current plan ends</strong> — no action needed, no days wasted.</p>` +
      `</div>` +
      `<div style="padding:16px 24px;color:#9aa4ad;font-size:12px;border-top:1px solid #eef1f4">VoyZa · voyza.xtremon.com</div>` +
      `</div></div>`;
    await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from, to: profile.email,
        subject: 'Your free month of VoyZa Pro is banked', html,
      }),
    });
  } catch (e) {
    console.error('referral: banked email failed (non-fatal):', e);
  }
}

/**
 * The user's PAID coverage just ended (EXPIRATION / REFUND) — pay out any
 * months they banked as a REFERRER while they were still paying. Sequential:
 * each payout is cap-checked and CAS-claimed exactly like the direct path.
 * Never throws; anything deferred stays 'banked' for the daily reconciler.
 */
async function processBankedPayouts(userId: string) {
  try {
    const { data: rows } = await supabase
      .from('referrals')
      .select('id')
      .eq('referrer_user_id', userId)
      .eq('status', 'banked')
      .is('rewarded_at', null)
      .order('banked_at', { ascending: true })
      .limit(REFERRAL_CAP_PER_365D);
    if (!rows || rows.length === 0) return;

    // Confirm with RC that paid coverage is REALLY gone — the event we're
    // reacting to may concern one of several products (crossgrade, resub).
    let entState = await getReferrerEntitlementState(userId);
    if (entState === null || entState.paidActive) return;

    for (const row of rows) {
      const since = new Date(Date.now() - 365 * 86_400_000).toISOString();
      const { count } = await supabase
        .from('referrals')
        .select('id', { count: 'exact', head: true })
        .eq('referrer_user_id', userId)
        .eq('status', 'rewarded')
        .gte('rewarded_at', since);
      if ((count ?? 0) >= REFERRAL_CAP_PER_365D) return; // cap — stays banked

      const { data: claimed } = await supabase
        .from('referrals')
        .update({ status: 'rewarded', rewarded_at: new Date().toISOString() })
        .eq('id', row.id)
        .eq('status', 'banked')
        .is('rewarded_at', null)
        .select('id');
      if (!claimed || claimed.length === 0) continue; // lost a race

      const granted =
        await grantPromotionalMonth(userId, entState.promoExpiresMs);
      if (!granted) {
        // Revert; the reconciler (or the next lapse event) retries.
        await supabase
          .from('referrals')
          .update({ status: 'banked', rewarded_at: null })
          .eq('id', row.id);
        return;
      }

      const monthsThisYear = (count ?? 0) + 1;
      await supabase.from('notifications').insert({
        user_id: userId,
        type: 'referral_reward',
        title: 'Your banked free month just started 🎉',
        body:
          `Your plan ended, so a banked referral month kicked in — 30 days ` +
          `of Pro, on us. ${monthsThisYear} of 12 free months this year.`,
        data: { screen: 'referral' },
      });
      await sendReferralRewardEmail(userId, monthsThisYear);

      // Refresh promo expiry so the NEXT iteration extends, not overwrites.
      entState = (await getReferrerEntitlementState(userId)) ?? entState;
    }
  } catch (e) {
    console.error('referral: processBankedPayouts failed (non-fatal):', e);
  }
}

/** Branded "you earned a month" email via Resend. Best-effort. */
async function sendReferralRewardEmail(userId: string, monthsThisYear: number) {
  const resendKey = Deno.env.get('RESEND_API_KEY');
  if (!resendKey) return;
  const from = Deno.env.get('LIFECYCLE_FROM') ?? 'VoyZa <onboarding@resend.dev>';
  const { data: profile } = await supabase
    .from('user_profiles').select('email').eq('user_id', userId).maybeSingle();
  if (!profile?.email) return;
  const p = 'margin:0 0 12px;color:#46535f;font-size:15px;line-height:1.5';
  const html =
    `<div style="background:#f4f6f8;padding:24px;font-family:-apple-system,'Segoe UI',Roboto,sans-serif">` +
    `<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden;border:1px solid #e6e9ee">` +
    `<div style="background:linear-gradient(135deg,#2B1D70,#2E5BD0 60%,#15BFB6);padding:22px 24px;color:#fff;font-weight:800;font-size:20px">VoyZa</div>` +
    `<div style="padding:24px">` +
    `<h1 style="margin:0 0 14px;font-size:22px;color:#16202b">You earned a free month of Pro! 🎉</h1>` +
    `<p style="${p}">A friend you invited just started using VoyZa Pro — so we've added <strong>30 days of Pro</strong> to your account.</p>` +
    `<p style="${p}">That's ${monthsThisYear} of 12 free months earned this year. Keep sharing your code to earn more.</p>` +
    `</div>` +
    `<div style="padding:16px 24px;color:#9aa4ad;font-size:12px;border-top:1px solid #eef1f4">VoyZa · voyza.xtremon.com</div>` +
    `</div></div>`;
  try {
    await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from, to: profile.email,
        subject: 'You earned a free month of VoyZa Pro', html,
      }),
    });
  } catch (e) {
    console.error('referral: reward email failed (non-fatal):', e);
  }
}

/**
 * Called after every successful subscription upsert. Never throws — a
 * referral failure must not fail the webhook (RC would retry and re-run
 * subscription writes).
 */
async function processReferralReward(event: any, refereeUserId: string) {
  try {
    if ((event.store ?? '').toUpperCase() === 'PROMOTIONAL') return;
    if (
      (event.environment ?? '').toUpperCase() === 'SANDBOX' &&
      Deno.env.get('REFERRAL_ALLOW_SANDBOX') !== 'true'
    ) {
      return;
    }

    // 1. Is this referee part of a referral that hasn't been rewarded yet?
    const { data: referral } = await supabase
      .from('referrals')
      .select('id, referrer_user_id, status, rewarded_at')
      .eq('referee_user_id', refereeUserId)
      .in('status', ['pending', 'qualified'])
      .maybeSingle();
    if (!referral) return;

    // 2. pending → qualified fires ONLY once the referee's money has
    // actually cleared (tightened from trial-start to PAID conversion):
    //   • INITIAL_PURCHASE with a non-TRIAL period — a direct paid start
    //     (paid intro pricing included), or
    //   • any RENEWAL — renewals are always charged, and the first renewal
    //     after a trial IS the trial→paid conversion.
    // A trial start alone no longer qualifies, which removes the
    // start-a-trial-then-cancel farming vector. Already-qualified rows, by
    // contrast, may self-heal a transiently failed reward on ANY of the
    // referee's later events.
    if (referral.status === 'pending') {
      const periodType = (event.period_type ?? '').toUpperCase();
      const paidInitial =
        event.type === 'INITIAL_PURCHASE' && periodType !== 'TRIAL';
      const paidRenewal = event.type === 'RENEWAL';
      if (!paidInitial && !paidRenewal) return;
      await supabase
        .from('referrals')
        .update({ status: 'qualified', qualified_at: new Date().toISOString() })
        .eq('id', referral.id)
        .eq('status', 'pending');
    }

    if (referral.rewarded_at != null) return; // already rewarded

    // 3. One RC read powers both banking and the grant math below. Null =
    // RC unreachable → change nothing; a later event or the daily
    // reconciler retries.
    const entState =
      await getReferrerEntitlementState(referral.referrer_user_id);
    if (entState === null) return;

    // 3a. BANKING: while the referrer is on ACTIVE PAID coverage a promo
    // month would just run underneath it and be wasted. Park the earned
    // month as 'banked' — the EXPIRATION/REFUND hook and the daily
    // reconciler pay it out the moment their plan actually lapses.
    if (entState.paidActive) {
      const { data: banked } = await supabase
        .from('referrals')
        .update({ status: 'banked', banked_at: new Date().toISOString() })
        .eq('id', referral.id)
        .eq('status', 'qualified')
        .is('rewarded_at', null)
        .select('id');
      if (banked && banked.length > 0) {
        await notifyMonthBanked(referral.referrer_user_id);
      }
      return;
    }

    // 4. Cap: 12 rewarded referrals per trailing 365 days. (Best-effort,
    // not atomic across concurrent qualifications of DIFFERENT referees —
    // worst case the cap overshoots by one month. Accepted.)
    const since = new Date(Date.now() - 365 * 86_400_000).toISOString();
    const { count } = await supabase
      .from('referrals')
      .select('id', { count: 'exact', head: true })
      .eq('referrer_user_id', referral.referrer_user_id)
      .eq('status', 'rewarded')
      .gte('rewarded_at', since);
    if ((count ?? 0) >= REFERRAL_CAP_PER_365D) {
      console.log('referral: cap reached for referrer', referral.referrer_user_id);
      return; // stays 'qualified'; UI shows "cap reached"
    }

    // 5. CLAIM before granting — the rewarded_at CAS is the mutex, so two
    // concurrent deliveries of the same event can't double-grant. If the
    // grant then fails, the claim is reverted and a later event retries.
    const { data: claimed } = await supabase
      .from('referrals')
      .update({ status: 'rewarded', rewarded_at: new Date().toISOString() })
      .eq('id', referral.id)
      .is('rewarded_at', null)
      .select('id');
    if (!claimed || claimed.length === 0) return; // lost the race

    // 6. Grant the referrer 30 days (extend when they have promo time left).
    const granted = await grantPromotionalMonth(
      referral.referrer_user_id, entState.promoExpiresMs);
    if (!granted) {
      // Revert the claim so the row self-heals on a later referee event.
      await supabase
        .from('referrals')
        .update({ status: 'qualified', rewarded_at: null })
        .eq('id', referral.id);
      return;
    }

    const monthsThisYear = (count ?? 0) + 1;

    // 6. In-app notification (the existing DB→push pipeline delivers FCM).
    await supabase.from('notifications').insert({
      user_id: referral.referrer_user_id,
      type: 'referral_reward',
      title: 'You earned a free month of VoyZa Pro! 🎉',
      body:
        `A friend you invited just got started — 30 days of Pro added. ` +
        `${monthsThisYear} of 12 free months earned this year.`,
      data: { screen: 'referral' },
    });

    // 7. Email (best-effort).
    await sendReferralRewardEmail(referral.referrer_user_id, monthsThisYear);
  } catch (e) {
    console.error('referral: processReferralReward failed (non-fatal):', e);
  }
}

// ============================================================================
// Main Handler
// ============================================================================

serve(async (req) => {
  try {
    console.log('Webhook received:', {
      method: req.method,
      url: req.url,
      // Redact Authorization — it carries the webhook auth secret; never log it.
      headers: { ...Object.fromEntries(req.headers), authorization: '[redacted]' },
    });

    // 1. Verify webhook authenticity — MANDATORY, fail-closed.
    // The request body fully controls app_user_id / type / expiry, so an
    // unauthenticated POST could forge subscription state for ANY user
    // (privilege escalation / free premium). Refuse to run if the shared secret
    // isn't configured, and always require a matching Authorization header.
    if (!revenueCatAuthKey) {
      console.error('REVENUECAT_WEBHOOK_AUTH_KEY not configured — refusing to process webhook');
      return new Response(
        JSON.stringify({ error: 'Server misconfigured' }),
        { status: 503, headers: { 'Content-Type': 'application/json' } }
      );
    }
    if (req.headers.get('Authorization') !== `Bearer ${revenueCatAuthKey}`) {
      console.error('Unauthorized webhook request - invalid or missing auth token');
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      );
    }
    console.log('Authorization verified');

    // 2. Parse webhook payload
    let payload: RevenueCatWebhookEvent;
    try {
      payload = await req.json();
    } catch (e) {
      console.error('Invalid JSON payload:', e);
      return new Response(
        JSON.stringify({ error: 'Invalid JSON' }),
        {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        }
      );
    }

    const { event } = payload;

    console.log('Parsed webhook event:', {
      type: event.type,
      app_user_id: event.app_user_id,
      product_id: event.product_id || event.new_product_id,
      entitlement_ids: event.entitlement_ids,
    });

    // 3. Filter relevant events
    if (!RELEVANT_EVENTS.includes(event.type)) {
      console.log('Ignoring non-relevant event:', event.type);
      console.log('Relevant events are:', RELEVANT_EVENTS);
      console.log('Full event data:', JSON.stringify(event, null, 2));
      return new Response(
        JSON.stringify({
          message: 'Event ignored (non-relevant)',
          event_type_received: event.type,
          relevant_events: RELEVANT_EVENTS
        }),
        {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }
      );
    }

    // 4. Extract subscription data
    const appUserId = event.app_user_id;
    const entitlement = event.entitlement_ids?.[0] || 'premium';
    const productId = event.product_id || event.new_product_id;
    const store = event.store;
    const periodType = event.period_type;
    const willRenew = inferWillRenew(event.type);

    // Convert timestamps from milliseconds to ISO 8601
    const expiresAt = event.expiration_at_ms
      ? new Date(event.expiration_at_ms).toISOString()
      : null;
    const purchaseDate = event.purchased_at_ms
      ? new Date(event.purchased_at_ms).toISOString()
      : null;
    const billingIssuesDetectedAt = event.billing_issues_detected_at_ms
      ? new Date(event.billing_issues_detected_at_ms).toISOString()
      : null;
    const unsubscribeDetectedAt = event.unsubscribe_detected_at_ms
      ? new Date(event.unsubscribe_detected_at_ms).toISOString()
      : null;

    // 5. Determine subscription status
    const now = new Date();
    const expirationDate = expiresAt ? new Date(expiresAt) : null;
    const status = determineSubscriptionStatus(event.type, expirationDate, now);

    console.log('Subscription status determined:', {
      status,
      expiresAt,
      willRenew,
    });

    // Additional logging for debugging
    console.log(`Event type: ${event.type}`);
    console.log(`Inferred will_renew: ${willRenew}`);
    console.log(`Determined status: ${status}`);

    // Explain the inference
    if (willRenew === false) {
      console.log('→ Subscription will NOT renew (cancelled/expired/non-renewable)');
    } else {
      console.log('→ Subscription WILL auto-renew');
    }

    // Log grace period scenarios
    if (status === 'active' && willRenew === false) {
      console.log(`→ GRACE PERIOD: User retains access until ${expiresAt}`);
      if (event.type === 'CANCELLATION') {
        console.log('  Reason: User cancelled subscription');
      } else if (event.type === 'BILLING_ISSUE') {
        console.log('  Reason: Billing failed, retrying during grace period');
      } else if (event.type === 'SUBSCRIPTION_PAUSED') {
        console.log('  Reason: User paused subscription (Android)');
      }
    }

    // Log special events
    if (event.type === 'TRANSFER') {
      console.log(`→ TRANSFER: Entitlements transferred. See transferred_from/to fields.`);
    }
    if (event.type === 'PRODUCT_CHANGE') {
      console.log(`→ PRODUCT_CHANGE: From ${event.product_id} to ${event.new_product_id}`);
    }

    // Handle TRANSFER events before the app_user_id check.
    // TRANSFER events carry no app_user_id — entitlements are identified via
    // transferred_from[] and transferred_to[] arrays instead.
    // Logic:
    //   - transferred_from UUIDs: they gave up the entitlement → mark expired
    //   - transferred_to UUIDs: they received the entitlement → mark active
    //   - Anonymous IDs ($RCAnonymousID:…) in either array are skipped
    //     because they have no Supabase account to update.
    if (event.type === 'TRANSFER') {
      const transferredFrom: string[] = event.transferred_from ?? [];
      const transferredTo: string[]   = event.transferred_to   ?? [];

      console.log('→ TRANSFER event received');
      console.log('  transferred_from:', transferredFrom);
      console.log('  transferred_to:',   transferredTo);

      // Read the existing subscription data from the transferred_from user(s) before
      // expiring them. TRANSFER events carry no product/expiry details, so we inherit
      // them from the source record. This ensures transferred_to users immediately
      // get accurate data rather than nulls waiting on a follow-up RENEWAL event.
      let inheritedProduct: string | null = null;
      let inheritedExpiresAt: string | null = null;
      let inheritedPeriodType: string | null = null;
      let inheritedStore: string | null = store ?? null;

      for (const fromUserId of transferredFrom) {
        if (isValidUUID(fromUserId)) {
          const { data: existingSub } = await supabase
            .from('user_subscriptions')
            .select('product_identifier, expires_at, period_type, store')
            .eq('user_id', fromUserId)
            .eq('entitlement', entitlement)
            .maybeSingle();

          if (existingSub) {
            inheritedProduct    = existingSub.product_identifier ?? null;
            inheritedExpiresAt  = existingSub.expires_at         ?? null;
            inheritedPeriodType = existingSub.period_type        ?? null;
            inheritedStore      = existingSub.store              ?? inheritedStore;
            console.log(`  TRANSFER: inherited subscription data from ${fromUserId}:`, {
              product: inheritedProduct,
              expires_at: inheritedExpiresAt,
              period_type: inheritedPeriodType,
              store: inheritedStore,
            });
            break; // One source record is enough
          }
        }
      }

      // Is the entitlement genuinely moving to another REAL account?
      //
      // On LOGOUT the SDK mints a fresh $RCAnonymousID and RevenueCat transfers
      // the store receipt onto it — so transferred_to is ALL anonymous (no UUID).
      // The signed-out user still OWNS the underlying store subscription and
      // reclaims it the moment they sign in again. Expiring their DB row here is
      // wrong: it left paying users showing 'expired' after a logout→login round
      // trip (the app still worked because it reads the live RC SDK entitlement,
      // but the DB disagreed).
      //
      // So only expire transferred_from UUIDs when a UUID in transferred_to is
      // actually receiving the entitlement (a true account→account transfer).
      const toHasUuid = transferredTo.some(isValidUUID);

      if (toHasUuid) {
        // Expire subscriptions for Supabase users losing the entitlement to another account
        for (const fromUserId of transferredFrom) {
          if (isValidUUID(fromUserId)) {
            console.log(`  TRANSFER: expiring subscription for ${fromUserId}`);
            const { error: fromError } = await supabase.rpc('upsert_subscription_status', {
              p_user_id:                       fromUserId,
              p_revenuecat_app_user_id:        fromUserId,
              p_status:                        'expired',
              p_entitlement:                   entitlement,
              p_product_identifier:            null,
              p_store:                         store ?? null,
              p_expires_at:                    null,
              p_period_type:                   null,
              p_purchase_date:                 null,
              p_will_renew:                    false,
              p_billing_issues_detected_at:    null,
              p_unsubscribe_detected_at:       null,
              p_event_type:                    'TRANSFER',
            });
            if (fromError) {
              console.error(`  TRANSFER: failed to expire for ${fromUserId}:`, fromError);
            }
          } else {
            console.log(`  TRANSFER: skipping non-UUID transferred_from: ${fromUserId}`);
          }
        }
      } else {
        console.log(
          '  TRANSFER: transferred_to is all-anonymous (logout / device anonymization) — ' +
          'NOT expiring transferred_from UUIDs; they retain the subscription until they sign in again.',
        );
      }

      // Activate subscriptions for Supabase users gaining the entitlement.
      // Resolution order for product/expiry details (best → fallback):
      //   1. RevenueCat REST API  — live data, most accurate
      //   2. DB record inherited from transferred_from — already in our DB
      //   3. null — RPC COALESCE keeps any pre-existing value; follow-up RENEWAL fills the rest
      for (const toUserId of transferredTo) {
        if (isValidUUID(toUserId)) {
          console.log(`  TRANSFER: activating subscription for ${toUserId}`);

          // 1. Try to get fresh data directly from RevenueCat API
          const rcData = await fetchRevenueCatSubscriber(toUserId, entitlement);
          if (rcData) {
            console.log(`  TRANSFER: resolved data from RevenueCat API for ${toUserId}:`, rcData);
          } else {
            console.log(`  TRANSFER: RC API unavailable, falling back to DB inheritance for ${toUserId}`);
          }

          const { error: toError } = await supabase.rpc('upsert_subscription_status', {
            p_user_id:                       toUserId,
            p_revenuecat_app_user_id:        toUserId,
            p_status:                        'active',
            p_entitlement:                   entitlement,
            p_product_identifier:            rcData?.product_identifier ?? inheritedProduct,
            p_store:                         rcData?.store?.toUpperCase()           ?? inheritedStore,
            p_expires_at:                    rcData?.expires_at         ?? inheritedExpiresAt,
            p_period_type:                   rcData?.period_type        ?? inheritedPeriodType,
            p_purchase_date:                 null,
            p_will_renew:                    rcData?.will_renew         ?? true,
            p_billing_issues_detected_at:    null,
            p_unsubscribe_detected_at:       null,
            p_event_type:                    'TRANSFER',
          });
          if (toError) {
            console.error(`  TRANSFER: failed to activate for ${toUserId}:`, toError);
          }
        } else {
          console.log(`  TRANSFER: skipping non-UUID transferred_to: ${toUserId}`);
        }
      }

      // Only report UUIDs we actually expired — on a logout (all-anonymous
      // transferred_to) we deliberately expire nobody.
      const expiredUuids = toHasUuid ? transferredFrom.filter(isValidUUID) : [];
      const toUuids      = transferredTo.filter(isValidUUID);
      console.log(`TRANSFER processed — expired: ${expiredUuids.length}, activated: ${toUuids.length}`);

      return new Response(
        JSON.stringify({
          message: 'TRANSFER event processed',
          expired_user_ids:  expiredUuids,
          activated_user_ids: toUuids,
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } }
      );
    }

    // 6. Map RevenueCat app_user_id to Supabase user_id
    // RevenueCat app_user_id should be the Supabase user UUID
    if (!appUserId || !isValidAppUserId(appUserId)) {
      console.error('app_user_id is not a valid format:', appUserId);
      return new Response(
        JSON.stringify({
          error: 'Invalid app_user_id format - must be UUID or RevenueCat anonymous ID',
          received: appUserId,
        }),
        {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        }
      );
    }

    // Resolve which Supabase user_id this event should write to.
    //
    // For a normal authenticated event this is just appUserId. But anonymous-keyed
    // events ($RCAnonymousID:…) need care:
    //   - A truly anonymous subscriber has no Supabase account yet, and the user_id
    //     column is `uuid` + FK to auth.users — passing the anon id throws
    //     `invalid input syntax for type uuid`. We ACK 200 and write nothing; the
    //     entitlement lives in RevenueCat until signup.
    //   - BUT if the subscription was already adopted by an authenticated account
    //     (via TRANSFER or the client syncTrialSubscription on signup) yet
    //     RevenueCat keeps sending events under the original anon id (transfer
    //     behavior = "keep with original"), we MUST route the update to that
    //     account. Otherwise its CANCELLATION/EXPIRATION never land and it stays
    //     'active' forever → free access. resolveAuthenticatedOwner finds it.
    const isAnonymousUser = isRevenueCatAnonymousId(appUserId);
    let userId = appUserId;

    if (isAnonymousUser) {
      const ownerUserId = await resolveAuthenticatedOwner(appUserId, event.aliases ?? []);

      if (!ownerUserId) {
        // No authenticated owner yet. We can't touch user_subscriptions (its
        // user_id is uuid + FK, so the $RCAnonymousID can't be a key), and the
        // RPC — the normal history writer — is never called on this path. So we
        // append the audit row to user_subscription_history directly, with
        // user_id = NULL and the raw id preserved in revenuecat_app_user_id.
        // This keeps a complete record of anonymous trials/cancellations.
        // (Requires user_subscription_history.user_id to be nullable.)
        const { error: historyError } = await supabase
          .from('user_subscription_history')
          .insert({
            user_id: null,
            event_type: event.type,
            status,
            entitlement,
            revenuecat_app_user_id: appUserId,
            product_identifier: productId ?? null,
            store: store ?? null,
            expires_at: expiresAt,
            period_type: periodType ?? null,
            purchase_date: purchaseDate,
            will_renew: willRenew,
            billing_issues_detected_at: billingIssuesDetectedAt,
            unsubscribe_detected_at: unsubscribeDetectedAt,
          });
        if (historyError) {
          // Non-fatal: never fail the webhook over an audit-log write. If this
          // errors with a NOT NULL violation, the user_id-nullable migration
          // hasn't been applied yet.
          console.error('Failed to write anonymous history row (non-fatal):', historyError);
        } else {
          console.log('Anonymous event recorded in user_subscription_history (user_id NULL):', appUserId);
        }

        console.log('Anonymous RevenueCat user with no linked account — no user_subscriptions write:', appUserId);
        return new Response(
          JSON.stringify({
            message: 'Anonymous user event acknowledged (history logged; user_subscriptions syncs on signup)',
            event_type: event.type,
            app_user_id: appUserId,
          }),
          { status: 200, headers: { 'Content-Type': 'application/json' } }
        );
      }

      console.log(
        `Anonymous event for ${appUserId} mapped to authenticated owner ${ownerUserId} — applying ${event.type}`,
      );
      userId = ownerUserId;
    }

    // For TEST events, check if user exists first (only for non-anonymous UUIDs)
    if (event.type === 'TEST' && !isAnonymousUser) {
      const { data: userExists } = await supabase
        .from('auth.users')
        .select('id')
        .eq('id', userId)
        .single();

      if (!userExists) {
        console.log('TEST event with non-existent user_id:', userId);
        return new Response(
          JSON.stringify({
            message: 'TEST event received but user does not exist in database',
            event_type: 'TEST',
            user_id: userId,
            note: 'For real purchases, this would work because the user exists. Use a real user UUID for testing.',
          }),
          {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          }
        );
      }
    }

    // 7. Upsert subscription status in Supabase
    console.log('Calling upsert_subscription_status:', {
      userId,
      status,
      entitlement,
      productId,
      expiresAt,
      isAnonymousUser,
    });

    const { error } = await supabase.rpc('upsert_subscription_status', {
      p_user_id: userId,
      p_revenuecat_app_user_id: appUserId,
      p_status: status,
      p_entitlement: entitlement,
      p_product_identifier: productId,
      p_store: store,
      p_expires_at: expiresAt,
      p_period_type: periodType,
      p_purchase_date: purchaseDate,
      p_will_renew: willRenew,
      p_billing_issues_detected_at: billingIssuesDetectedAt,
      p_unsubscribe_detected_at: unsubscribeDetectedAt,
      p_event_type: event.type,
    });

    if (error) {
      // Log the detail server-side only; don't leak DB internals to the caller.
      const errorId = crypto.randomUUID();
      console.error(`Error upserting subscription [${errorId}]:`, error);
      return new Response(
        JSON.stringify({ error: 'Database error', id: errorId }),
        {
          status: 500,
          headers: { 'Content-Type': 'application/json' },
        }
      );
    }

    console.log('Successfully updated subscription:', {
      userId,
      status,
      entitlement,
      expiresAt,
    });

    // 8. Update trial_start_at in user_profile.
    // userId is always a real Supabase UUID here — either an authenticated
    // app_user_id, or the authenticated owner resolved from an anonymous-keyed
    // event. Unlinked anonymous subscribers already returned above. trial_devices
    // logging happens in the app (paywall_screen.dart), not here, because only the
    // app knows the device ID. The webhook just records the server-verified date.
    if (periodType === 'TRIAL' && event.type === 'INITIAL_PURCHASE') {
      console.log('Recording trial start date for user:', userId);

      const { error: profileError } = await supabase
        .from('user_profiles')
        .update({
          trial_start_at: purchaseDate,
          updated_at: new Date().toISOString(),
        })
        .eq('user_id', userId)
        .single();

      if (profileError) {
        console.error('Error updating user profile trial_start_at:', profileError);
        // Non-fatal — continue processing
      } else {
        console.log('✅ Trial start date recorded in user_profiles');
      }
    }

    // 9. Referral qualification/reward hook. Fully self-contained and
    // non-fatal: userId here is always a resolved Supabase UUID (anonymous
    // events either returned early or were mapped by resolveAuthenticatedOwner).
    await processReferralReward(event, userId);

    // 9b. Paid coverage lapsing is the moment BANKED referral months start.
    if (event.type === 'EXPIRATION' || event.type === 'REFUND') {
      await processBankedPayouts(userId);
    }

    // 10. Return success response
    return new Response(
      JSON.stringify({
        message: 'Webhook processed successfully',
        event_type: event.type,
        user_id: userId,
        status,
        isAnonymousUser,
      }),
      {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }
    );
  } catch (error) {
    // Log full detail server-side; return only a generic message + trace id.
    const errorId = crypto.randomUUID();
    console.error(`Webhook handler error [${errorId}]:`, error);
    return new Response(
      JSON.stringify({ error: 'Internal server error', id: errorId }),
      {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }
    );
  }
});
