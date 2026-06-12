# RevenueCat Webhook: Anonymous User Handling

> **Correction (supersedes an earlier draft of this doc).** An earlier attempt tried to
> "process anonymous users instead of skipping them" and store a row keyed by
> `$RCAnonymousID`. That produced a **500** on every anonymous event:
> `invalid input syntax for type uuid: "$RCAnonymousID:…"`, because
> `user_subscriptions.user_id` is `uuid` (FK → `auth.users`). The correct behavior is to
> **acknowledge anonymous events with 200 and not write to the DB.** This doc reflects that.

## Problem Found

`user_subscriptions.user_id` is typed `uuid` with a foreign key to `auth.users(id)`.
Passing RevenueCat's `$RCAnonymousID:<hex>` string into the `upsert_subscription_status`
RPC throws:

```
invalid input syntax for type uuid: "$RCAnonymousID:e45c551518ed4beea91654333d928f5e"
```

**Impact of the failed attempt:**
- ❌ Every anonymous webhook (INITIAL_PURCHASE, SUBSCRIPTION_EXTENDED, RENEWAL…) returned 500
- ❌ RevenueCat retried indefinitely (repeated failing deliveries for the same event)
- ❌ Nothing was actually recorded — the row can't physically exist

---

## Why You Can't Store `$RCAnonymousID` in `user_subscriptions`

1. `user_id` is `uuid` → the string isn't a valid uuid (the literal error).
2. Even as `text`, the FK to `auth.users` would fail — an anonymous user has **no**
   `auth.users` row yet.
3. You don't need to. **RevenueCat is the source of truth** for the entitlement while the
   user is anonymous, and the app reads entitlement state straight from the RC SDK. The
   user has full premium access with zero DB rows.
4. On signup the app calls `Purchases.logIn(supabaseUserId)` → RevenueCat fires a
   **TRANSFER** event → the handler fetches the sub from the RC REST API and writes the row
   keyed by the **real Supabase UUID**. The client-side `syncTrialSubscription()` after
   signup is a second fallback for webhook delay.

---

## Solution Implemented

### Acknowledge Anonymous Events Without a DB Write

```typescript
const isAnonymousUser = isRevenueCatAnonymousId(appUserId);

if (isAnonymousUser) {
  console.log('Anonymous RevenueCat user — acknowledging without DB write:', appUserId);
  return new Response(
    JSON.stringify({
      message: 'Anonymous user event acknowledged (no DB write; syncs on signup via TRANSFER)',
      event_type: event.type,
      app_user_id: appUserId,
    }),
    { status: 200, headers: { 'Content-Type': 'application/json' } }
  );
}
```

✅ Returns **200** → RevenueCat marks the event delivered and stops retrying
✅ Covers **all** anonymous event types, not just INITIAL_PURCHASE
✅ No DB write attempted → no more uuid syntax error
✅ `trial_devices` is logged by the **app** (it knows the device ID), never the webhook
✅ `user_profiles.trial_start_at` is updated only for real UUID users (anonymous returned early)

---

## Data Flow: Anonymous User Signing Up

### Before Fix ❌
```
Day 1: Anonymous user buys trial
  └─ Webhook received
  └─ Skipped (returned early)
  └─ NO records created

Day 3: User signs up
  └─ RevenueCat.login() fires TRANSFER webhook
  └─ No subscription to transfer (never stored!)
  └─ User confused: has active trial but app says no entitlement
```

### After Fix ✅
```
Day 1: Anonymous user buys trial
  └─ Webhook received (INITIAL_PURCHASE, app_user_id = $RCAnonymousID:xxx)
  └─ Edge function returns 200, NO DB write (can't key a uuid row)
  └─ Entitlement lives in RevenueCat (source of truth)
  └─ App reads entitlement from RC SDK → premium works ✅ (no DB row needed)

Day 3: User signs up
  └─ RevenueCat.login(supabaseUserId) fires TRANSFER webhook
  └─ transferred_from: $RCAnonymousID:xxx   (skipped — not a UUID)
  └─ transferred_to:   <supabase-user-uuid> (processed)
  └─ Handler fetches sub from RC REST API, writes the row:
  └─ user_subscriptions: { supabase-uuid, premium, active, expires_at: ... }
  └─ Client syncTrialSubscription() also runs post-signup as a fallback
  └─ App still works ✅
```

---

## Testing the Fix

### 1. Test Anonymous Trial Purchase

Get your webhook logs and look for:
```
Anonymous RevenueCat user — acknowledging without DB write: $RCAnonymousID:e45c551518ed4beea91654333d928f5e
  event_type: INITIAL_PURCHASE
  → Entitlement stays in RevenueCat until signup; TRANSFER will sync it.
```
The response should be **200** (so RevenueCat stops retrying) with body
`"Anonymous user event acknowledged …"`. There should be **no** `upsert_subscription_status`
call and **no** `invalid input syntax for type uuid` error.

### 2. Verify No DB Write Was Attempted (expected: zero rows)

```sql
-- There is intentionally NO row for the anonymous id — it can't exist (uuid/FK).
SELECT * FROM user_subscriptions
WHERE revenuecat_app_user_id = '$RCAnonymousID:e45c551518ed4beea91654333d928f5e';
-- → 0 rows. The entitlement lives in RevenueCat until the user signs up.
```

The anonymous user still has full premium access in the app because the app gates
on the RevenueCat SDK entitlement, not on a `user_subscriptions` row.

### 3. Verify TRANSFER Works When User Signs Up

When the anonymous user signs up and RevenueCat fires the TRANSFER webhook:
```
TRANSFER event received
  transferred_from: [$RCAnonymousID:xxx]
  transferred_to: [550e8400-...]
TRANSFER: inherited subscription data from $RCAnonymousID:xxx
TRANSFER: expiring subscription for $RCAnonymousID:xxx
TRANSFER: activating subscription for 550e8400-...
```

Then check (the row is created for the real UUID by the TRANSFER handler):
```sql
-- New user should now have the subscription
SELECT * FROM user_subscriptions
WHERE user_id = '550e8400-...';

-- Profile should be updated (trial date)
SELECT trial_start_at FROM user_profiles
WHERE user_id = '550e8400-...';
```

---

## Changes Made

**File:** `supabase/functions/revenuecat-webhook/index.ts`

1. **Anonymous branch**: returns 200 early for any `$RCAnonymousID` event — no RPC call,
   no DB write. Stops the `invalid input syntax for type uuid` 500 and RevenueCat retries.
2. **Trial-date block**: simplified — anonymous users already returned, so `userId` is
   always a real Supabase UUID when `user_profiles.trial_start_at` is updated.
3. **`trial_devices`**: logged by the app (`paywall_screen.dart`) using the real device
   ID via `device_info_plus`, never by the webhook (the webhook has no device info).

---

## Side Effects / Notes

✅ **Safe**: No changes to the authenticated-user flow
✅ **Stops retries**: 200 response means RevenueCat marks anonymous events delivered
✅ **No data loss**: entitlement lives in RevenueCat; TRANSFER + client sync write it on signup
✅ **Correct by construction**: never attempts an impossible `uuid` write

---

## What Still Needs

1. ✅ Edge function fixed
2. ⏳ Deploy to Supabase (push code)
3. ⏳ Test with real webhook from Malaysia user
4. ⏳ Monitor webhook logs for 24 hours
5. ⏳ (Optional) Implement the advanced improvements from WEBHOOK_IMPROVEMENTS.md

---

## Deployment

```bash
# Deploy the edge function
supabase functions deploy revenuecat-webhook

# Check logs in Supabase dashboard:
# → Edge Functions → revenuecat-webhook → Logs
```

---

## Questions?

If users still don't see trial_devices/user_profile updates after this fix:
1. Check edge function logs (look for errors)
2. Verify `trial_devices` table exists
3. Check Supabase RLS policies (may be blocking inserts)
4. Run the verify script to check database setup
