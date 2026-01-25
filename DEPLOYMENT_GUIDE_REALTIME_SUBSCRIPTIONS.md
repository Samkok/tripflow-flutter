# Real-Time Subscription Expiration Detection - Deployment Guide

## Overview

This guide covers deploying the battery-efficient real-time subscription expiration detection system that replaces periodic polling with event-driven updates via Supabase Realtime and RevenueCat webhooks.

## Architecture Summary

**Three-Layer Detection System:**
1. **Supabase Realtime** (Primary) - WebSocket pub/sub, <2 second latency
2. **RevenueCat SDK Listener** (Secondary) - Native event listener, immediate when app active
3. **App Resume Check** (Fallback) - Refresh on foreground transition

**Data Flow:**
```
RevenueCat Subscription Event
    ↓
RevenueCat Webhook
    ↓
Supabase Edge Function (revenuecat-webhook)
    ↓
Update user_subscriptions table
    ↓
Supabase Realtime broadcast
    ↓
Flutter App receives event
    ↓
Update UI immediately (paywall, banner, labels)
```

---

## Phase 1: Deploy Database Migration

### Step 1.1: Apply Migration 009

**Option A: Using Supabase Dashboard (Recommended)**

1. Go to your Supabase project dashboard
2. Navigate to **SQL Editor**
3. Open `migrations/009_add_user_subscriptions.sql`
4. Copy the entire contents
5. Paste into SQL Editor
6. Click **Run**
7. Verify no errors appear

**Option B: Using Supabase CLI**

```bash
# From your project root
cd d:\Development\tripflow-flutter

# Make sure you're linked to your project
supabase link --project-ref YOUR_PROJECT_REF

# Push the migration
supabase db push
```

### Step 1.2: Verify Migration

Run this query in Supabase SQL Editor to verify:

```sql
-- Check table exists
SELECT table_name
FROM information_schema.tables
WHERE table_name = 'user_subscriptions';

-- Check RLS is enabled
SELECT tablename, rowsecurity
FROM pg_tables
WHERE tablename = 'user_subscriptions';

-- Check realtime is enabled
SELECT schemaname, tablename
FROM pg_publication_tables
WHERE tablename = 'user_subscriptions'
  AND pubname = 'supabase_realtime';

-- Check function exists
SELECT routine_name, security_type
FROM information_schema.routines
WHERE routine_name = 'upsert_subscription_status';
```

**Expected Results:**
- Table exists: ✅ `user_subscriptions`
- RLS enabled: ✅ `rowsecurity = true`
- Realtime enabled: ✅ Row in `pg_publication_tables`
- Function exists: ✅ `upsert_subscription_status` with `security_type = DEFINER`

---

## Phase 2: Deploy Webhook Handler

### Step 2.1: Install Supabase CLI (if not already installed)

```bash
npm install -g supabase
```

### Step 2.2: Link to Your Project

```bash
# From project root
supabase link --project-ref YOUR_PROJECT_REF

# You'll be prompted to enter your database password
```

### Step 2.3: Deploy the Edge Function

```bash
# From project root
cd supabase/functions

# Deploy the webhook handler
supabase functions deploy revenuecat-webhook

# This will output a URL like:
# https://YOUR_PROJECT_REF.supabase.co/functions/v1/revenuecat-webhook
```

### Step 2.4: Set Webhook Authorization Secret

```bash
# Generate a secure random key (or use your own)
# On Windows PowerShell:
$key = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | % {[char]$_})
echo $key

# On Linux/Mac:
# openssl rand -base64 32

# Set the secret in Supabase
supabase secrets set REVENUECAT_WEBHOOK_AUTH_KEY=YOUR_GENERATED_KEY_HERE

# Verify it was set
supabase secrets list
```

**IMPORTANT:** Save this key - you'll need it for RevenueCat configuration!

### Step 2.5: Test the Webhook Locally (Optional)

```bash
# Terminal 1: Start Supabase locally
supabase start

# Terminal 2: Serve the function locally
supabase functions serve revenuecat-webhook

# Terminal 3: Test with curl
curl -X POST http://localhost:54321/functions/v1/revenuecat-webhook \
  -H "Authorization: Bearer YOUR_AUTH_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "event": {
      "type": "INITIAL_PURCHASE",
      "app_user_id": "YOUR_TEST_USER_UUID",
      "entitlement_ids": ["VoyZa Pro"],
      "product_id": "monthly",
      "store": "play_store",
      "expiration_at_ms": 1735689600000,
      "purchased_at_ms": 1704067200000,
      "will_renew": true
    },
    "api_version": "1.0"
  }'
```

---

## Phase 3: Configure RevenueCat Webhook

### Step 3.1: Get Your Webhook URL

Your webhook URL is:
```
https://YOUR_PROJECT_REF.supabase.co/functions/v1/revenuecat-webhook
```

Replace `YOUR_PROJECT_REF` with your actual Supabase project reference ID.

### Step 3.2: Configure in RevenueCat Dashboard

1. Go to [RevenueCat Dashboard](https://app.revenuecat.com/)
2. Select your project
3. Navigate to **Project Settings** → **Integrations** → **Webhooks**
4. Click **+ Add Webhook**
5. Enter webhook URL: `https://YOUR_PROJECT_REF.supabase.co/functions/v1/revenuecat-webhook`
6. Set **Authorization** header:
   ```
   Bearer YOUR_GENERATED_KEY_HERE
   ```
   (Use the key you generated in Step 2.4)

### Step 3.3: Select Events

Select these events (or select "All transaction events"):
- ✅ Initial Purchase
- ✅ Renewal
- ✅ Cancellation
- ✅ Uncancellation
- ✅ Expiration
- ✅ Billing Issue
- ✅ Product Change
- ✅ Transfer
- ✅ Non-renewing Purchase

### Step 3.4: Test the Webhook

1. In RevenueCat dashboard, click **Send Test Event**
2. Select event type: **INITIAL_PURCHASE**
3. Click **Send**
4. Check the delivery status - should show **200 OK**

### Step 3.5: Verify Database Update

After sending test event, check Supabase:

```sql
SELECT * FROM user_subscriptions
ORDER BY created_at DESC
LIMIT 1;
```

You should see a new record with the test data.

---

## Phase 4: Deploy Flutter App

### Step 4.1: Verify Files Are in Place

Ensure these files exist:
- ✅ `lib/services/subscription_realtime_service.dart`
- ✅ `lib/providers/subscription_provider.dart` (updated)

### Step 4.2: Build and Test

```bash
# Clean build
flutter clean
flutter pub get

# Build for Android
flutter build apk --release

# Build for iOS
flutter build ios --release
```

### Step 4.3: Test on Real Device

**Test 1: Initial State**
1. Install the app on a test device
2. Log in with a test user
3. Verify subscription status loads correctly

**Test 2: App Resume (Fallback Layer)**
1. Close the app completely
2. Let subscription expire (use RevenueCat sandbox - subscriptions expire in minutes)
3. Open the app
4. Verify: ProUpgradeBanner appears, label shows "Free Plan", paywall triggers

**Test 3: Real-Time Detection (Primary Layer)**
1. Open the app with active subscription
2. Keep app open
3. Use RevenueCat dashboard to expire the subscription manually
4. **Expected:** Within 2 seconds:
   - ProUpgradeBanner appears in settings
   - Subscription label changes to "Free Plan"
   - Attempting to add location triggers paywall

---

## Phase 5: Monitor and Verify

### Step 5.1: Monitor Webhook Delivery

**In RevenueCat Dashboard:**
1. Go to **Webhooks** section
2. View **Delivery History**
3. Check for:
   - ✅ Delivery rate > 99%
   - ✅ Response codes: 200 (success)
   - ❌ Failed deliveries (investigate if any)

### Step 5.2: Monitor Edge Function Logs

```bash
# Real-time logs
supabase functions logs revenuecat-webhook --follow

# Filter by error level
supabase functions logs revenuecat-webhook --level error

# View recent logs
supabase functions logs revenuecat-webhook --tail 50
```

### Step 5.3: Monitor Realtime Subscriptions

In Supabase Dashboard:
1. Go to **Database** → **Realtime**
2. Check active connections
3. Verify `user_subscriptions` table is in publication

### Step 5.4: Check Flutter App Logs

Look for these log messages in your app:

**Successful realtime initialization:**
```
SubscriptionProvider: Initializing realtime subscription
SubscriptionRealtimeService: 🔔 Starting subscription for user <uuid>
SubscriptionRealtimeService: ✅ Successfully subscribed to realtime updates
SubscriptionProvider: ✅ Realtime subscription initialized
```

**Receiving realtime events:**
```
SubscriptionRealtimeService: 📨 Received UPDATE event
SubscriptionRealtimeService: ✨ Emitting event - SubscriptionEvent(...)
SubscriptionProvider: 📨 Realtime event received - SubscriptionEvent(...)
SubscriptionProvider: ✨ State updated from realtime event - isPro: false
```

---

## Rollback Procedures

### If You Need to Rollback

**Rollback Database (NOT RECOMMENDED - keeps bug):**
```sql
-- Run rollback_009.sql in SQL Editor
-- This will drop the user_subscriptions table
```

**Rollback Edge Function:**
```bash
# Remove the webhook in RevenueCat dashboard first
supabase functions delete revenuecat-webhook
```

**Rollback App Changes:**
1. Revert `lib/providers/subscription_provider.dart` to previous version
2. Delete `lib/services/subscription_realtime_service.dart`
3. Rebuild and redeploy app

---

## Troubleshooting

### Issue: Webhook Returns 401 Unauthorized

**Symptoms:**
- RevenueCat shows "401 Unauthorized" in delivery history
- Edge Function logs show "Unauthorized" messages

**Fix:**
1. Verify secret is set correctly:
   ```bash
   supabase secrets list
   ```
2. Check RevenueCat webhook Authorization header:
   - Must be: `Bearer YOUR_KEY`
   - Not just: `YOUR_KEY`
3. Regenerate key and update both Supabase and RevenueCat

---

### Issue: Webhook Returns 400 Bad Request

**Symptoms:**
- RevenueCat shows "400 Bad Request"
- Edge Function logs show "Invalid app_user_id format"

**Fix:**
1. Verify `app_user_id` in RevenueCat matches Supabase user UUID format
2. Check that RevenueCat user ID is set correctly:
   ```dart
   // In your app login code:
   await Purchases.logIn(supabaseUserId); // Must be Supabase UUID
   ```

---

### Issue: Webhook Returns 500 Internal Server Error

**Symptoms:**
- RevenueCat shows "500 Internal Server Error"
- Edge Function logs show database errors

**Fix:**
1. Check Edge Function logs:
   ```bash
   supabase functions logs revenuecat-webhook --level error
   ```
2. Verify migration 009 was applied successfully
3. Check `upsert_subscription_status` function exists:
   ```sql
   SELECT routine_name FROM information_schema.routines
   WHERE routine_name = 'upsert_subscription_status';
   ```

---

### Issue: Database Not Updating

**Symptoms:**
- Webhook returns 200 OK
- But `user_subscriptions` table is empty

**Fix:**
1. Check RLS policies:
   ```sql
   SELECT * FROM pg_policies WHERE tablename = 'user_subscriptions';
   ```
2. Verify service role has permission
3. Check if function has `SECURITY DEFINER`

---

### Issue: Realtime Not Working

**Symptoms:**
- Database updates correctly
- But Flutter app doesn't receive events

**Fix:**
1. Check Supabase Realtime is enabled on table:
   ```sql
   SELECT * FROM pg_publication_tables
   WHERE tablename = 'user_subscriptions';
   ```
2. Verify app logs for subscription errors
3. Check network connectivity (WebSocket)
4. Try restarting the app (re-establishes WebSocket)

---

### Issue: App Shows Stale Subscription Status

**Symptoms:**
- Subscription expired in RevenueCat
- App still shows "VoyZa Pro"

**Fix:**
1. Check all three layers:
   - **Realtime:** Is WebSocket connected? Check logs
   - **RevenueCat Listener:** Is SDK initialized? Check `RevenueCatService`
   - **App Resume:** Does pulling down to refresh work?

2. Manual refresh:
   - Pull down on settings screen to refresh
   - Log out and log back in

3. Verify webhook delivered:
   - Check RevenueCat delivery history
   - Check Edge Function logs
   - Query `user_subscriptions` table

---

## Performance Metrics

### Expected Performance

| Metric | Target | How to Measure |
|--------|--------|----------------|
| Detection Latency | < 2 seconds | Time from expiration to UI update |
| Webhook Delivery Rate | > 99% | RevenueCat delivery history |
| Realtime Uptime | > 99.5% | Supabase dashboard |
| Battery Impact | < 1%/hour | Android Battery Historian / Xcode Energy Log |
| Database Query Time | < 100ms | Supabase Performance tab |
| Edge Function Response | < 500ms | Supabase Functions logs |

### Monitoring Battery Usage

**Android:**
```bash
# Enable Battery Historian
adb shell dumpsys batterystats --reset
adb shell dumpsys batterystats --enable full-wake-history

# Use app for 1 hour

# Export data
adb bugreport > bugreport.zip

# Upload to: https://bathist.ef.lc/
```

**iOS:**
1. Open Xcode
2. Window → Devices and Simulators
3. Select your device
4. Click "Instruments" → Energy Log
5. Use app for 1 hour
6. Check energy impact (should be "Low" or "Very Low")

---

## Success Criteria Checklist

Before marking deployment as complete, verify:

- ✅ Migration 009 applied successfully
- ✅ Edge Function deployed and accessible
- ✅ Webhook secret configured
- ✅ RevenueCat webhook configured and tested
- ✅ Test webhook delivery shows 200 OK
- ✅ `user_subscriptions` table updates on webhook
- ✅ Flutter app builds without errors
- ✅ Realtime subscription initializes (check logs)
- ✅ Expiration detected in < 2 seconds (real device test)
- ✅ ProUpgradeBanner appears immediately on expiration
- ✅ Subscription label updates to "Free Plan"
- ✅ Paywall triggers when attempting to add location
- ✅ No periodic timer in code (battery efficient)
- ✅ Battery usage < 1%/hour (profiled on real device)
- ✅ All three detection layers working (Realtime, RevenueCat, App Resume)
- ✅ Webhook delivery rate > 99%
- ✅ No increase in crash rate or support tickets

---

## Additional Notes

### RevenueCat Sandbox Subscriptions

For testing, use RevenueCat sandbox subscriptions which expire quickly:
- **Monthly:** Expires in 5 minutes
- **Yearly:** Expires in 1 hour

This allows rapid testing without waiting for real subscription periods.

### Entitlement Identifier

Ensure your entitlement identifier in RevenueCat dashboard matches exactly:
```
VoyZa Pro
```
(With space and capital letters, as defined in `RevenueCatConfig.entitlementVoyZaPro`)

### User ID Mapping

Critical: RevenueCat `app_user_id` MUST be the Supabase user UUID:
```dart
// On login:
final user = await SupabaseService.instance.client.auth.signIn(...);
await Purchases.logIn(user.id); // Pass Supabase UUID to RevenueCat
```

### Network Considerations

- **Realtime:** Requires WebSocket support (blocked by some corporate networks)
- **Webhook:** Requires outbound HTTPS from RevenueCat servers
- **Fallback:** App resume check works even without network (uses cached data)

---

## Support and Debugging

### Useful Commands

```bash
# View all secrets
supabase secrets list

# View function logs in real-time
supabase functions logs revenuecat-webhook --follow

# Test webhook locally with ngrok
ngrok http 54321
# Then update RevenueCat webhook to: https://YOUR_NGROK_ID.ngrok.io/functions/v1/revenuecat-webhook

# Check database connection
supabase db diff

# View realtime status
# Go to Supabase Dashboard → Database → Realtime
```

### SQL Queries for Debugging

```sql
-- View all subscriptions
SELECT * FROM user_subscriptions ORDER BY updated_at DESC;

-- Find expired subscriptions
SELECT * FROM user_subscriptions
WHERE status = 'expired'
ORDER BY expires_at DESC;

-- Check realtime publication
SELECT * FROM pg_publication_tables
WHERE pubname = 'supabase_realtime';

-- View webhook processing history
SELECT
    user_id,
    status,
    entitlement,
    expires_at,
    will_renew,
    last_webhook_received_at
FROM user_subscriptions
ORDER BY last_webhook_received_at DESC
LIMIT 20;
```

---

## Summary

This deployment guide covers all phases of implementing real-time subscription expiration detection:

1. ✅ **Database:** Migration 009 creates `user_subscriptions` table with realtime enabled
2. ✅ **Backend:** Supabase Edge Function processes RevenueCat webhooks
3. ✅ **Client:** Flutter realtime service listens for subscription changes
4. ✅ **Integration:** Subscription provider updates UI immediately
5. ✅ **Optimization:** Removed battery-draining periodic timer

**Result:** Subscription expiration detected in under 2 seconds with minimal battery impact.

For issues or questions, check the Troubleshooting section or review the Edge Function logs and RevenueCat delivery history.
