-- Test Script: Permission Update Real-time Testing
-- Use this script to test if permission updates are broadcasting correctly

-- Step 1: Verify realtime is enabled
SELECT
  schemaname,
  tablename,
  CASE
    WHEN tablename IN (
      SELECT tablename FROM pg_publication_tables WHERE pubname = 'supabase_realtime'
    ) THEN '✅ Enabled'
    ELSE '❌ Not Enabled'
  END as realtime_status
FROM pg_tables
WHERE tablename = 'trip_collaborators';

-- Step 2: List all collaborators for your trips
SELECT
  tc.id,
  tc.trip_id,
  t.name as trip_name,
  tc.user_id,
  tc.permission,
  tc.created_at
FROM trip_collaborators tc
JOIN trips t ON tc.trip_id = t.id
ORDER BY tc.created_at DESC;

-- Step 3: Test permission update
-- IMPORTANT: Replace <collaborator-id> with an actual ID from the query above
-- UNCOMMENT and run this to test permission changes:

/*
-- Test 1: Change to write permission
UPDATE trip_collaborators
SET permission = 'write'
WHERE id = '<collaborator-id>';

-- Wait 2 seconds, check app logs for:
-- "CollaboratorRealtimeService: 📨 Received UPDATE event"

-- Test 2: Change back to read permission
UPDATE trip_collaborators
SET permission = 'read'
WHERE id = '<collaborator-id>';

-- Wait 2 seconds, check app logs again
*/

-- Step 4: Monitor realtime activity (if needed)
-- This shows recent changes to trip_collaborators
SELECT
  id,
  trip_id,
  user_id,
  permission,
  updated_at,
  NOW() - updated_at as time_since_update
FROM trip_collaborators
ORDER BY updated_at DESC
LIMIT 10;

-- Step 5: Verify RLS policies
SELECT
  schemaname,
  tablename,
  policyname,
  permissive,
  cmd,
  CASE
    WHEN cmd = 'SELECT' THEN '✅ Required for realtime'
    ELSE 'Not critical for realtime'
  END as realtime_importance
FROM pg_policies
WHERE tablename = 'trip_collaborators'
ORDER BY cmd;

-- Step 6: Check function volatility (should all be VOLATILE)
SELECT
  p.proname as function_name,
  CASE p.provolatile
    WHEN 'v' THEN '✅ VOLATILE (correct)'
    WHEN 's' THEN '❌ STABLE (needs update)'
    WHEN 'i' THEN '❌ IMMUTABLE (needs update)'
  END as volatility
FROM pg_proc p
WHERE p.proname IN (
  'is_trip_owner',
  'is_trip_collaborator',
  'has_trip_write_access',
  'can_modify_trip_locations',
  'can_view_trip_locations'
)
ORDER BY p.proname;

-- Expected results:
-- ✅ All functions should show VOLATILE
-- ✅ trip_collaborators should show "Enabled" for realtime
-- ✅ Should have SELECT policy for trip_collaborators
