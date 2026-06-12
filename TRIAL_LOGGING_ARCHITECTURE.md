# Trial Logging Architecture: App vs Webhook

## Overview

There are **TWO different things** we're tracking for trials:

| Table | Logged By | Data | Purpose |
|-------|-----------|------|---------|
| `user_profiles.trial_start_at` | **Both** (webhook + app) | Timestamp | When did user's trial start? |
| `trial_devices` | **App only** | Device info | Which devices used the trial? |

---

## Correct Architecture

### ✅ App Logs to `trial_devices` (When User Purchases)

**File:** `lib/screens/paywall_screen.dart` (after purchase succeeds)

```typescript
// The app knows the device, so it logs here
await repo.logTrialStart(
  userId: user.id,
  deviceId: device.id,  // ← Only app knows this!
  productIdentifier: productId,
);

// This inserts into trial_devices:
// {
//   user_id: "550e8400-...",
//   device_id: "device-abc123",
//   product_identifier: "premium:yearly",
//   trial_started_at: "2025-04-04T22:02:59Z"
// }
```

**Advantages:**
- ✅ App has device information
- ✅ Can track multiple devices per user
- ✅ Can track device model, OS version, etc.
- ✅ Fires immediately, no webhook delay

---

### ✅ Webhook Updates `user_profiles.trial_start_at` (Fallback)

**File:** `supabase/functions/revenuecat-webhook/index.ts`

```typescript
// Webhook doesn't have device info, but it does have trial date
if (periodType === 'TRIAL' && event.type === 'INITIAL_PURCHASE') {
  await supabase
    .from('user_profiles')
    .update({
      trial_start_at: purchaseDate,  // ← Only webhook has this!
      updated_at: new Date().toISOString(),
    })
    .eq('user_id', userId);
}
```

**Why here?**
- ✅ Webhook guarantees the trial is real (signed by RevenueCat)
- ✅ Acts as fallback if app purchase fails
- ✅ Provides server-side audit trail
- ✅ Can be used for analytics queries

---

## Data Flow: Trial Purchase

```
User taps "Start Free Trial"
    ↓
PaywallScreen._purchaseSelectedPackage()
    ├─ Call RevenueCat Purchases.purchasePackage()
    ├─ SUCCESS: entitlement becomes active
    ├─ App logs to trial_devices ✅
    │  └─ repo.logTrialStart(userId, deviceId, productId)
    │     └─ INSERT into trial_devices
    │
    └─ App also syncs to user_subscriptions (fallback) ✅
       └─ repo.syncTrialSubscription()
          └─ UPSERT into user_subscriptions

    (Async, no user wait)
    └─ RevenueCat fires INITIAL_PURCHASE webhook
       └─ Webhook updates user_profiles.trial_start_at ✅
          └─ UPDATE user_profiles SET trial_start_at = ...
```

---

## Anonymous User Flow

### During Trial (Before Signup)
- ❌ No `user_profiles` record (no Supabase account)
- ❌ No `trial_devices` record (no app login, can't log)
- ❌ No `user_subscriptions` record — `user_subscriptions.user_id` is `uuid` + FK to
  `auth.users`, so a `$RCAnonymousID:…` string **cannot** be stored there. The webhook
  acknowledges the anonymous event with 200 but does **not** write to the DB.
- ✅ RevenueCat SDK has entitlement — **this is the source of truth while anonymous.**
  The app gates premium off the RC SDK entitlement, not `user_subscriptions`, so the
  user has full access even with no DB row.

### When User Signs Up

```
User signs up → Supabase user_id created (550e8400-...)
    ↓
App calls RevenueCatService.login(supabaseUserId)
    ↓
RevenueCat fires TRANSFER webhook
    transferred_from: [$RCAnonymousID:xxx]
    transferred_to: [550e8400-...]
    ↓
Webhook:
  - Expires $RCAnonymousID subscription
  - Activates 550e8400-... subscription
  - Updates user_profiles.trial_start_at ✅
    ↓
App:
  - Detects subscription is active
  - NOW can log to trial_devices ✅
    └─ repo.logTrialStart(userId, deviceId, productId)
```

---

## Current Implementation Status

### ✅ Done
- [x] App logs to `trial_devices` when trial is purchased
- [x] Webhook updates `user_profiles.trial_start_at`
- [x] App syncs `user_subscriptions` for authenticated users
- [x] Anonymous webhook events acknowledged with 200, **no DB write** (the `user_id`
      column is `uuid`/FK — can't hold `$RCAnonymousID`). Entitlement lives in RevenueCat
      until signup, then TRANSFER + client `syncTrialSubscription()` write the real UUID row.

### ⏳ TODO: Improve Device ID
- [ ] Add `device_info_plus` package
- [ ] Get actual device ID in `paywall_screen.dart`
- [ ] Log device model, OS version to `trial_devices`

**File:** [paywall_screen.dart:667](lib/screens/paywall_screen.dart#L667)
```typescript
// TODO: Improve device_id to use actual device identifier (device_info_plus)
final deviceId = user.id;  // ← Should be actual device ID
```

---

## Database Schema

### `trial_devices` (App Logs This)
```sql
CREATE TABLE trial_devices (
  id UUID PRIMARY KEY,
  user_id TEXT NOT NULL,           -- Supabase user ID
  device_id TEXT NOT NULL,          -- Device identifier
  product_identifier TEXT,           -- "premium:yearly"
  store TEXT,                        -- "PLAY_STORE", "APP_STORE"
  trial_started_at TIMESTAMPTZ,     -- When trial started
  created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### `user_profiles` (Webhook Updates This)
```sql
ALTER TABLE user_profiles
ADD COLUMN trial_start_at TIMESTAMPTZ;  -- When any trial started (latest)
```

### `user_subscriptions` (Both Update This)
```sql
CREATE TABLE user_subscriptions (
  user_id TEXT PRIMARY KEY,         -- Supabase UUID or $RCAnonymousID
  entitlement TEXT,                  -- "premium"
  status TEXT,                        -- "active", "expired", etc.
  product_identifier TEXT,            -- "premium:yearly"
  expires_at TIMESTAMPTZ,
  period_type TEXT,                   -- "TRIAL", "MONTHLY", "ANNUAL"
  -- ... other fields
);
```

---

## Key Differences

| Aspect | `trial_devices` | `user_profiles.trial_start_at` |
|--------|-----------------|--------------------------------|
| Logged by | App | Webhook |
| Knows device ID | ✅ Yes | ❌ No |
| Fires immediately | ✅ Yes | ❌ Delayed |
| Works for anonymous | ❌ No | ⏸️ Only after signup |
| Can track multiple devices | ✅ Yes | ❌ Single value |
| Audit trail | ✅ Yes | ✅ Yes |

---

## Testing

### Verify App Logs to trial_devices
```sql
-- After user purchases trial in app
SELECT * FROM trial_devices 
WHERE user_id = '550e8400-...';
-- Should see: device_id (currently user_id), product_id, trial_started_at
```

### Verify Webhook Updates user_profiles
```sql
-- After webhook fires
SELECT trial_start_at FROM user_profiles 
WHERE user_id = '550e8400-...';
-- Should see: trial_start_at timestamp
```

### Verify Anonymous User Transfer
```sql
-- Anonymous user starts trial
SELECT * FROM user_subscriptions 
WHERE user_id LIKE '$RCAnonymousID%' AND entitlement = 'premium';

-- User signs up, TRANSFER fires
SELECT * FROM trial_devices 
WHERE user_id = '550e8400-...' AND product_identifier = 'premium:yearly';
-- Should see new record after TRANSFER webhook processed
```

---

## Summary

✅ **Correct**: App logs device information to `trial_devices`  
✅ **Correct**: Webhook records trial date in `user_profiles`  
✅ **Correct**: Both update `user_subscriptions`  
⏳ **TODO**: Improve app-side device ID (currently uses user_id as placeholder)

The separation is intentional:
- **App** = device-specific details (has the info)
- **Webhook** = subscription facts (is authoritative source)
