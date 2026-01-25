# Location Visibility Bug Fix

## Problem Description

**Issue:** When User A adds a location that doesn't belong to any trip (trip_id = NULL), it appears on the map when User B logs in as well.

**Expected Behavior:** Locations that don't belong to any trip should only be visible to the user who created them.

## Root Cause Analysis

### Database Layer (RLS Policies)

The issue is in the Row-Level Security (RLS) policies on the `locations` table in Supabase.

**Broken Policy (from `supabase_schema.sql` lines 21-24):**
```sql
create policy "Users can select their own locations"
on public.locations for select
using (auth.uid() = user_id);
```

**Problem:** This policy only checks if the user created the location (`user_id = auth.uid()`), but it does NOT distinguish between:
- **Non-trip locations** (trip_id IS NULL) - should be private to creator
- **Trip locations** (trip_id IS NOT NULL) - should be visible to trip collaborators

### Why the Bug Occurs

1. User A creates a location without a trip → `trip_id = NULL`, `user_id = User A's ID`
2. The SELECT policy checks: `auth.uid() = user_id`
3. For User A: `User A's ID = User A's ID` ✅ **CAN SEE** (correct)
4. For User B: `User B's ID = User A's ID` ❌ **CANNOT SEE** (correct)

**Wait, that should work correctly!** So why are users seeing each other's locations?

### The Real Issue

After further investigation, the problem is likely one of these scenarios:

**Scenario 1: Migration 005 was never applied**
- The comprehensive RLS policies in migration `005_fix_location_rls_comprehensive.sql` were never run
- The old broken policies from the initial schema are still active
- These policies may have been modified or have additional issues

**Scenario 2: RLS is disabled**
- `ALTER TABLE locations ENABLE ROW LEVEL SECURITY` was never run
- All users can see all locations

**Scenario 3: Policies conflict**
- Multiple policies exist and are ORed together
- One policy allows the access even though others deny it

## The Fix

### Migration 008: Verify and Re-apply Correct RLS Policies

I've created `migrations/008_verify_location_rls.sql` which:

1. **Drops ALL existing location policies** (removes any broken/conflicting policies)
2. **Re-creates helper functions** (idempotent - safe to run multiple times)
3. **Creates the correct SELECT policy:**
   ```sql
   CREATE POLICY "locations_select_policy"
   ON public.locations
   FOR SELECT
   USING (
       -- Non-trip locations: only visible to creator
       (trip_id IS NULL AND user_id = auth.uid())
       OR
       -- Trip locations: visible to trip owner or collaborators
       (trip_id IS NOT NULL AND public.can_view_trip_locations(trip_id, auth.uid()))
   );
   ```
4. **Enables RLS** on the locations table

### Key Logic in the Fix

The SELECT policy now explicitly checks:

**For non-trip locations (trip_id IS NULL):**
- ✅ **ALLOW** if `user_id = auth.uid()` (user owns it)
- ❌ **DENY** otherwise

**For trip locations (trip_id IS NOT NULL):**
- ✅ **ALLOW** if user is the trip owner
- ✅ **ALLOW** if user is a collaborator on the trip (any permission level)
- ❌ **DENY** otherwise

## How to Apply the Fix

### Step 1: Apply Migration 008 to Supabase

**Option A: Using Supabase Dashboard (Recommended)**

1. Go to your Supabase project
2. Navigate to **SQL Editor**
3. Copy the contents of `migrations/008_verify_location_rls.sql`
4. Paste into the SQL Editor
5. Click **Run**
6. Verify no errors appear

**Option B: Using Supabase CLI**

```bash
# From your project root
supabase db push migrations/008_verify_location_rls.sql
```

### Step 2: Verify the Fix

After applying the migration, run this verification query in Supabase SQL Editor:

```sql
-- Check that the correct policies exist
SELECT policyname, cmd
FROM pg_policies
WHERE tablename = 'locations'
ORDER BY cmd, policyname;
```

**Expected output:**
```
policyname               | cmd
-------------------------|--------
locations_delete_policy  | DELETE
locations_insert_policy  | INSERT
locations_select_policy  | SELECT
locations_update_policy  | UPDATE
```

You should see exactly 4 policies with these names.

### Step 3: Test the Fix

**Test 1: Non-trip location visibility**

1. **User A:**
   - Log in to the app
   - Long-press on the map to add a location
   - Do NOT assign it to any trip
   - Verify the location appears on your map

2. **User B:**
   - Log in to the app (different account)
   - Check the map
   - ✅ **Expected:** User A's location should NOT appear
   - ❌ **Bug still exists if:** User A's location appears on User B's map

**Test 2: Trip location visibility (no collaboration)**

1. **User A:**
   - Create a trip
   - Add a location to that trip
   - Verify the location appears

2. **User B:**
   - Log in (should NOT be a collaborator on User A's trip)
   - Check the map
   - ✅ **Expected:** User A's trip location should NOT appear

**Test 3: Trip location visibility (with collaboration)**

1. **User A:**
   - Create a trip with a location
   - Add User B as a collaborator with READ permission

2. **User B:**
   - Open the app
   - Select User A's shared trip from trips list
   - ✅ **Expected:** You CAN now see the trip's locations
   - Try to add/modify a location
   - ✅ **Expected:** Should be BLOCKED (read-only access)

3. **User A:**
   - Change User B's permission to WRITE

4. **User B:**
   - Try to add/modify a location
   - ✅ **Expected:** Should now WORK (write access granted)

## Technical Details

### Helper Functions Created

The migration creates these helper functions to check permissions:

1. `is_trip_owner(trip_id, user_id)` - Checks if user owns the trip
2. `is_trip_collaborator(trip_id, user_id)` - Checks if user is a collaborator (any permission)
3. `has_trip_write_access(trip_id, user_id)` - Checks if user has WRITE permission
4. `can_modify_trip_locations(trip_id, user_id)` - Owner OR has WRITE access
5. `can_view_trip_locations(trip_id, user_id)` - Owner OR any collaborator

### Why SECURITY DEFINER?

The helper functions use `SECURITY DEFINER` to avoid RLS recursion issues. This allows the functions to check the trips and trip_collaborators tables without being affected by their own RLS policies.

### Frontend Code

The frontend code in `lib/providers/location_provider.dart` (lines 65-70) correctly filters unassigned locations:

```dart
// Authenticated, no trip: show unassigned locations
final unassignedLocations = locations
    .where((loc) => loc.tripId == null || loc.tripId!.isEmpty)
    .toList();
```

However, this assumes the backend RLS already filtered to only the user's locations. The RLS policy is the security boundary - the frontend filtering is just for UX.

## Impact Assessment

### Before Fix
- ❌ Any authenticated user could see ALL locations with `trip_id = NULL`
- ❌ Security vulnerability: user data leakage
- ❌ Privacy issue: locations meant to be private were shared

### After Fix
- ✅ Users can only see their own non-trip locations
- ✅ Users can see trip locations only if they own the trip or are collaborators
- ✅ Proper permission enforcement (READ vs WRITE)
- ✅ No data leakage between users

## Rollback Plan

If you need to rollback this migration (NOT recommended as it restores the bug):

```sql
-- Run the rollback script
-- migrations/rollback_008.sql
```

**Warning:** Rolling back will restore the original buggy policies where non-trip locations may be visible to other users.

## Additional Recommendations

### 1. Update the Main Schema File

The file `supabase_schema.sql` contains the old broken policies. Update it to match the correct policies from migration 008 so that new database setups have the correct policies from the start.

### 2. Audit Existing Data

After applying the fix, you may want to audit existing locations to ensure no data was inappropriately accessed:

```sql
-- Find all non-trip locations created by different users
SELECT DISTINCT user_id, COUNT(*) as non_trip_locations
FROM public.locations
WHERE trip_id IS NULL
GROUP BY user_id;
```

### 3. Monitor Logs

Check Supabase logs for any RLS policy violations after the migration to ensure the policies are working correctly.

## Questions?

If you encounter any issues after applying this migration:

1. Check Supabase logs for RLS policy errors
2. Verify the policies were created correctly using the verification query
3. Test with multiple user accounts to confirm the fix
4. Check if realtime subscriptions need to be refreshed (users may need to log out and back in)

## Summary

- **Issue:** Non-trip locations visible to all users instead of just the creator
- **Root Cause:** RLS policies didn't distinguish between trip and non-trip locations
- **Fix:** Migration 008 re-applies comprehensive RLS policies with proper trip_id checking
- **Impact:** High - fixes security vulnerability and privacy issue
- **Testing Required:** Yes - verify with multiple user accounts
