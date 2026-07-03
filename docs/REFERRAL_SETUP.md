# Referral system — owner setup & verification guide

The referral system ("**Give a month, get a month**") is fully implemented:
schema + RPC live in Supabase, `redeem-referral` deployed, the
`revenuecat-webhook` reward hook deployed, the Flutter client wired
(signup field, Invite friends screen, pending-code redemption on first
sign-in), and the landing page ready in `landing/r/`.

**How it works:** referee enters a code at signup → gets 30 days of Pro
(RevenueCat promotional entitlement) on their first verified sign-in →
when they start a trial or make a first purchase, the referrer gets 30 days
too (cap: 12 earned months per trailing 365 days). Fraud controls: verified
JWT identity, self-referral checks (account + device), one referral per
referee lifetime, rate limiting, sandbox gating, idempotent webhook handling.

## Manual steps (each with completion criteria)

### 1. Verify the RevenueCat secret key
- Where: https://app.revenuecat.com → VoyZa project → **API Keys** → Secret keys
- The Supabase secret `REVENUECAT_SECRET_API_KEY` already exists (used by the
  webhook + reconcile cron). Confirm at
  https://supabase.com/dashboard/project/dkbibfjszsohtixjxlle/settings/functions
- ✅ *Done when:* a test promotional grant via the RC dashboard (Customer →
  Grant promotional entitlement) or the M5 sandbox test succeeds.

### 2. Upload the landing page
- Follow [landing/README.md](../landing/README.md).
- ✅ *Done when:* `https://voyza.xtremon.com/r/VOYZA-TEST12` shows the code,
  copy works on both mobile browsers, store buttons resolve.

### 3. Sandbox verification (before announcing the program)
- Set the Supabase secret `REFERRAL_ALLOW_SANDBOX=true`
  (Dashboard → Edge Functions → Secrets), then with TWO test accounts:
  1. Account A: Settings → Invite friends → code appears → Share (fires `referral_share`).
  2. Account B: sign up with A's code → verify email → sign in →
     `referrals` row `pending` + B shows Pro (RC dashboard: promotional entitlement).
  3. B starts a sandbox trial → row becomes `rewarded`, A gets +30d promo,
     a push notification, and the reward email.
  4. Replay the same webhook event from the RC dashboard → no double grant.
  5. A redeems own code → rejected (`self_referral`).
  6. Stacking: reward A twice → RC shows continuous coverage (no gap).
- ✅ *Done when:* all six pass, **then remove `REFERRAL_ALLOW_SANDBOX`**.

### 4. GA4 (optional, later)
- After `referral_code_redeemed` shows in GA4 DebugView, mark it a
  **secondary** key event at https://analytics.google.com → Admin → Events.
- ⚠️ **Never import referral events into Google Ads** — they're organic;
  importing them would pollute paid-campaign optimization.
- ✅ *Done when:* visible under Key events, absent from Ads conversions.

### 5. Store compliance (read-and-confirm, no action)
- Rewards are server-granted free entitlement time — nothing is sold outside
  IAP, so Apple 3.1.1 / Play payments policies aren't implicated.
- Keep all copy non-monetary: "get 1 month of Pro free", never "$10 value"
  or "earn money". The shipped copy already follows this.
- ✅ *Done when:* you've read this and kept future copy consistent.

## Known v1 limitations (accepted; upgrades noted)
- Referee who started a trial BEFORE redeeming a code → referrer never
  qualifies (v1.1: qualify-at-redeem).
- Referrer who is a paying subscriber gets an overlapping promo month
  (v1.1: bank rewards and auto-apply on EXPIRATION).
- No deferred deep linking — the link opens the landing page and the code is
  typed/pasted at signup (v2: a link SDK if volume justifies it).
- Referee refund after the referrer was rewarded → cost is one promo month.

## Monitoring
- Referral funnel: GA4 `referral_share` → `referral_code_redeemed` → `referral_reward_earned`.
- State inspection: `select status, count(*) from referrals group by 1;`
- Edge-fn logs: Dashboard → Edge Functions → redeem-referral / revenuecat-webhook.
