# Realtime Permission Updates - Troubleshooting Guide

This guide helps diagnose why permission updates might not be reflecting in real-time.

## Quick Diagnostic Steps

### Step 1: Check Database Realtime Configuration

Run this SQL in your Supabase SQL Editor:

```sql
-- Check if trip_collaborators is in the realtime publication
SELECT * FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
AND schemaname = 'public'
AND tablename = 'trip_collaborators';
```

**Expected result:** Should return 1 row showing `trip_collaborators` is published.

**If empty:** Run `migrations/007_verify_enable_realtime.sql`

### Step 2: Check Supabase Dashboard

1. Open your Supabase dashboard
2. Go to **Database** → **Replication**
3. Click on the `supabase_realtime` publication
4. Verify `trip_collaborators` is in the list of tables

**If not listed:** Click "Add table" and add `public.trip_collaborators`

### Step 3: Check Flutter App Logs

Look for these debug prints in your Flutter console:

#### ✅ Good Signs (Everything Working):
```
CollaboratorRealtimeService: 🔔 Starting subscription for user abc-123-...
CollaboratorRealtimeService: ✅ Successfully subscribed to realtime updates
```

Then when you change permission in database:
```
CollaboratorRealtimeService: 📨 Received UPDATE event
CollaboratorRealtimeService: 📨 New: {id: ..., trip_id: ..., user_id: ..., permission: write}
CollaboratorRealtimeService: Emitting event - CollaboratorEvent(type: updated, tripId: ...)
CollaboratorRealtimeNotifier: Handling event - CollaboratorEvent(type: updated, ...)
```

#### ⚠️ Warning Signs:

**No subscription message:**
```
CollaboratorRealtimeService: ⚠️ No user logged in, skipping subscription
```
→ User not authenticated. Make sure user is logged in before testing.

**Subscription started but no success:**
```
CollaboratorRealtimeService: 🔔 Starting subscription for user abc-123-...
CollaboratorRealtimeService: ❌ Channel error during subscription
```
→ Check network connectivity, Supabase project status

**Subscription success but no events received:**
```
CollaboratorRealtimeService: ✅ Successfully subscribed to realtime updates
(then silence when you change permissions)
```
→ Realtime not enabled on table. Run migration 007.

### Step 4: Test Permission Update

1. Have two devices/browsers open:
   - Device A: Owner/admin of the trip
   - Device B: Collaborator with read permission

2. On Device B, check debug logs show:
   ```
   CollaboratorRealtimeService: ✅ Successfully subscribed to realtime updates
   ```

3. On Device A (or directly in Supabase SQL Editor), change permission:
   ```sql
   UPDATE trip_collaborators
   SET permission = 'write'
   WHERE user_id = '<device-b-user-id>'
   AND trip_id = '<trip-id>';
   ```

4. Within 1-2 seconds, Device B should show:
   ```
   CollaboratorRealtimeService: 📨 Received UPDATE event
   CollaboratorRealtimeService: 📨 New: {...permission: write...}
   ```

5. UI on Device B should update (edit buttons appear)

### Step 5: Check RLS Policies

Verify the SELECT policy allows users to see their own collaborator records:

```sql
-- Check RLS policies on trip_collaborators
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'trip_collaborators';
```

**Expected:** Should have a SELECT policy that includes:
```sql
user_id = auth.uid() OR trip_id IN (SELECT id FROM trips WHERE user_id = auth.uid())
```

If missing, run:
```sql
CREATE POLICY trip_collaborators_select_policy
ON public.trip_collaborators
FOR SELECT
USING (
  user_id = auth.uid()
  OR
  trip_id IN (
    SELECT id FROM public.trips WHERE user_id = auth.uid()
  )
);
```

## Common Issues and Solutions

### Issue: "Already subscribed, skipping"

**Symptom:** App logs show `Already subscribed, skipping` but no events received.

**Cause:** Service thinks it's subscribed but subscription actually failed or was closed.

**Solution:**
1. Force unsubscribe and resubscribe:
   ```dart
   final service = CollaboratorRealtimeService();
   service.unsubscribe();
   await Future.delayed(Duration(seconds: 1));
   service.subscribe();
   ```
2. Restart the app completely
3. Check Supabase realtime status in dashboard

### Issue: Multiple Subscription Attempts

**Symptom:** Logs show multiple "Starting subscription" messages

**Cause:** Provider is being recreated multiple times or multiple widgets are initializing it.

**Solution:** Ensure `collaboratorRealtimeInitProvider` is only watched at app root in `main.dart`, not in individual screens.

### Issue: Events Received But UI Not Updating

**Symptom:** Debug logs show events received but UI still shows old permission

**Cause:** Provider not invalidating correctly or UI not watching the right provider

**Solution:**
1. Verify `CollaboratorRealtimeNotifier._handleEvent()` is called
2. Check that it invalidates the correct provider:
   ```dart
   ref.invalidate(hasWriteAccessProvider(event.tripId));
   ```
3. Verify UI watches `hasActiveTripWriteAccessProvider`:
   ```dart
   final writeAccessAsync = ref.watch(hasActiveTripWriteAccessProvider);
   ```

### Issue: Works on WiFi But Not Mobile Data

**Symptom:** Realtime works on WiFi but fails on cellular

**Cause:** Firewall or carrier blocking websocket connections

**Solution:**
1. Check if carrier blocks websockets (some enterprise networks do)
2. Test on different network
3. Check Supabase project region (choose closest to users)
4. Consider fallback polling mechanism if websockets consistently fail

### Issue: Delayed Updates (>5 seconds)

**Symptom:** Events arrive but take 5+ seconds

**Cause:** Network latency, Supabase server load, or client processing delays

**Solution:**
1. Check Supabase dashboard for performance issues
2. Verify client internet speed
3. Check if app is in background (iOS/Android may throttle)
4. Reduce complexity in event handlers

## Testing Checklist

Use this checklist to verify everything is working:

- [ ] Migration 006 applied (functions are VOLATILE)
- [ ] Migration 007 applied (realtime enabled)
- [ ] `trip_collaborators` visible in Supabase Replication settings
- [ ] User is authenticated (not anonymous)
- [ ] Debug logs show "Successfully subscribed"
- [ ] Manual SQL UPDATE triggers event in app within 2 seconds
- [ ] UI updates when permission changes
- [ ] Works on both WiFi and mobile data
- [ ] No app restart needed to see changes
- [ ] No trip deactivate/reactivate needed

## Emergency Fallback: Manual Refresh

If realtime consistently fails, you can add a manual refresh button:

```dart
// Add to your UI
IconButton(
  icon: Icon(Icons.refresh),
  onPressed: () {
    // Force refresh permissions
    ref.invalidate(hasWriteAccessProvider);
    ref.read(_collaboratorRefreshCounterProvider.notifier).state++;
  },
)
```

This allows users to manually trigger permission checks if realtime fails.

## Getting Help

If none of these solutions work:

1. Export debug logs from your Flutter app
2. Check Supabase logs in dashboard: Settings → Logs
3. Verify Supabase project is on a paid plan (free tier has realtime limits)
4. Check Supabase status page: https://status.supabase.com/
5. Review Supabase realtime documentation: https://supabase.com/docs/guides/realtime

## Performance Tuning

Once working, you can optimize:

1. **Reduce event frequency:** Only emit events on actual permission changes
2. **Batch updates:** If updating multiple permissions, batch them in a transaction
3. **Debounce UI updates:** Add a small delay before updating UI to avoid flicker
4. **Unsubscribe when not needed:** Unsubscribe when app goes to background

Example debounce:
```dart
Timer? _debounceTimer;

void _handleEvent(CollaboratorEvent event) {
  _debounceTimer?.cancel();
  _debounceTimer = Timer(Duration(milliseconds: 300), () {
    // Update UI here
  });
}
```
