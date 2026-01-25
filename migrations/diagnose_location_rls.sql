-- Diagnostic Script: Check Location RLS Configuration
-- Run this in Supabase SQL Editor to diagnose the location visibility issue

-- ============================================================================
-- CHECK 1: Is RLS enabled on locations table?
-- ============================================================================
SELECT
    schemaname,
    tablename,
    rowsecurity as rls_enabled
FROM pg_tables
WHERE tablename = 'locations';

-- Expected: rls_enabled = true
-- If false, RLS is not enabled and ALL users can see ALL locations

-- ============================================================================
-- CHECK 2: What policies exist on locations table?
-- ============================================================================
SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    cmd as operation,
    CASE
        WHEN cmd = 'SELECT' THEN 'Controls who can VIEW locations'
        WHEN cmd = 'INSERT' THEN 'Controls who can CREATE locations'
        WHEN cmd = 'UPDATE' THEN 'Controls who can MODIFY locations'
        WHEN cmd = 'DELETE' THEN 'Controls who can REMOVE locations'
    END as description
FROM pg_policies
WHERE tablename = 'locations'
ORDER BY cmd, policyname;

-- Expected for CORRECT setup (after migration 005 or 008):
-- locations_select_policy  | SELECT
-- locations_insert_policy  | INSERT
-- locations_update_policy  | UPDATE
-- locations_delete_policy  | DELETE

-- Expected for BROKEN setup (original schema):
-- Users can select their own locations  | SELECT
-- Users can insert their own locations  | INSERT
-- Users can update their own locations  | UPDATE
-- Users can delete their own locations  | DELETE

-- ============================================================================
-- CHECK 3: Do the helper functions exist?
-- ============================================================================
SELECT
    routine_name as function_name,
    routine_type,
    security_type,
    CASE
        WHEN security_type = 'DEFINER' THEN 'Safe - avoids RLS recursion'
        ELSE 'May have issues with RLS'
    END as security_status
FROM information_schema.routines
WHERE routine_schema = 'public'
    AND routine_name IN (
        'is_trip_owner',
        'is_trip_collaborator',
        'has_trip_write_access',
        'can_modify_trip_locations',
        'can_view_trip_locations'
    )
ORDER BY routine_name;

-- Expected: All 5 functions should exist with security_type = 'DEFINER'
-- If any are missing, the comprehensive RLS policies won't work correctly

-- ============================================================================
-- CHECK 4: View the actual SELECT policy definition
-- ============================================================================
SELECT
    policyname,
    pg_get_expr(qual, 'locations'::regclass) as policy_definition
FROM pg_policy
WHERE polrelid = 'public.locations'::regclass
    AND polcmd = 'r';  -- 'r' means SELECT

-- For CORRECT policy, you should see something like:
-- ((trip_id IS NULL) AND (user_id = auth.uid())) OR ((trip_id IS NOT NULL) AND can_view_trip_locations(trip_id, auth.uid()))

-- For BROKEN policy, you'll see just:
-- (auth.uid() = user_id)

-- ============================================================================
-- CHECK 5: Sample location data (what exists in the database)
-- ============================================================================
SELECT
    COUNT(*) as total_locations,
    COUNT(CASE WHEN trip_id IS NULL THEN 1 END) as non_trip_locations,
    COUNT(CASE WHEN trip_id IS NOT NULL THEN 1 END) as trip_locations,
    COUNT(DISTINCT user_id) as unique_users
FROM public.locations;

-- This shows the distribution of locations in your database

-- ============================================================================
-- CHECK 6: Non-trip locations by user (potential privacy leak)
-- ============================================================================
SELECT
    user_id,
    COUNT(*) as non_trip_location_count,
    MIN(created_at) as oldest_location,
    MAX(created_at) as newest_location
FROM public.locations
WHERE trip_id IS NULL
GROUP BY user_id
ORDER BY non_trip_location_count DESC;

-- This shows which users have non-trip locations
-- If multiple users have non-trip locations and they can see each other's,
-- that confirms the bug

-- ============================================================================
-- INTERPRETATION GUIDE
-- ============================================================================
/*
SCENARIO 1: RLS is disabled
- CHECK 1: rls_enabled = false
- FIX: Run migration 008 (it includes ENABLE ROW LEVEL SECURITY)

SCENARIO 2: Old broken policies are active
- CHECK 2: Shows "Users can select their own locations" policy
- CHECK 3: Helper functions may be missing
- FIX: Run migration 008 to replace old policies

SCENARIO 3: Correct policies but bug still occurs
- CHECK 2: Shows "locations_select_policy"
- CHECK 3: All 5 helper functions exist
- CHECK 4: Shows the correct policy definition with trip_id checks
- ISSUE: May be a frontend caching issue or realtime subscription problem
- FIX: Users may need to log out and back in to refresh subscriptions

SCENARIO 4: Policies conflict
- CHECK 2: Shows BOTH old and new policies
- ISSUE: Multiple policies with same operation are ORed together
- FIX: Run migration 008 which drops ALL old policies first

SCENARIO 5: Everything looks correct
- All checks pass
- But bug still occurs
- ISSUE: May be Supabase realtime subscription not respecting RLS
- FIX: Check Supabase realtime settings and consider using direct queries
*/

-- ============================================================================
-- RECOMMENDED ACTION BASED ON RESULTS
-- ============================================================================
/*
After running these diagnostic queries:

1. If CHECK 1 shows RLS disabled → Run migration 008
2. If CHECK 2 shows old policy names → Run migration 008
3. If CHECK 3 shows missing functions → Run migration 008
4. If CHECK 4 shows broken policy definition → Run migration 008
5. If all checks pass but bug persists → Contact for further investigation

Migration 008 is designed to be idempotent and will fix all of the above scenarios.
*/
