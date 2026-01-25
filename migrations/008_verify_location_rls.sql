-- Migration 008: Verify and ensure correct location RLS policies are in place
-- This migration checks if the comprehensive RLS policies from migration 005 are active
-- and re-applies them if necessary to fix the location visibility bug

-- ============================================================================
-- DIAGNOSTIC: Check current policies on locations table
-- ============================================================================
-- Run this query manually in Supabase SQL Editor to see what policies exist:
/*
SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies
WHERE tablename = 'locations';
*/

-- ============================================================================
-- FIX: Drop ALL existing location policies and re-create the correct ones
-- ============================================================================

-- Drop ALL existing location policies (including any old broken ones)
DROP POLICY IF EXISTS "Users can select their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can insert their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can update their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can delete their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can view their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can view locations for trips they own or collaborate on" ON public.locations;
DROP POLICY IF EXISTS "Users can insert locations for trips they own or have write access" ON public.locations;
DROP POLICY IF EXISTS "Users can update locations for trips they own or have write access" ON public.locations;
DROP POLICY IF EXISTS "Users can delete locations for trips they own or have write access" ON public.locations;
DROP POLICY IF EXISTS "locations_select_policy" ON public.locations;
DROP POLICY IF EXISTS "locations_insert_policy" ON public.locations;
DROP POLICY IF EXISTS "locations_update_policy" ON public.locations;
DROP POLICY IF EXISTS "locations_delete_policy" ON public.locations;

-- ============================================================================
-- Re-create the helper functions (idempotent - safe to run multiple times)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.is_trip_owner(trip_uuid uuid, user_uuid uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.trips
        WHERE id = trip_uuid
        AND user_id = user_uuid
    );
$$;

CREATE OR REPLACE FUNCTION public.is_trip_collaborator(trip_uuid uuid, user_uuid uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.trip_collaborators
        WHERE trip_id = trip_uuid
        AND user_id = user_uuid
    );
$$;

CREATE OR REPLACE FUNCTION public.has_trip_write_access(trip_uuid uuid, user_uuid uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.trip_collaborators
        WHERE trip_id = trip_uuid
        AND user_id = user_uuid
        AND permission = 'write'
    );
$$;

CREATE OR REPLACE FUNCTION public.can_modify_trip_locations(trip_uuid uuid, user_uuid uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT
        public.is_trip_owner(trip_uuid, user_uuid)
        OR
        public.has_trip_write_access(trip_uuid, user_uuid);
$$;

CREATE OR REPLACE FUNCTION public.can_view_trip_locations(trip_uuid uuid, user_uuid uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT
        public.is_trip_owner(trip_uuid, user_uuid)
        OR
        public.is_trip_collaborator(trip_uuid, user_uuid);
$$;

-- ============================================================================
-- Create the CORRECT location policies
-- ============================================================================

-- SELECT policy: Users can view their non-trip locations OR trip locations they have access to
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

-- INSERT policy: Users can create non-trip locations OR add to trips they have write access to
CREATE POLICY "locations_insert_policy"
ON public.locations
FOR INSERT
WITH CHECK (
    -- Non-trip locations: user must be the creator
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    -- Trip locations: user must have write access to the trip
    (trip_id IS NOT NULL AND public.can_modify_trip_locations(trip_id, auth.uid()))
);

-- UPDATE policy: Users can modify their non-trip locations OR trip locations they have write access to
CREATE POLICY "locations_update_policy"
ON public.locations
FOR UPDATE
USING (
    -- Non-trip locations: must own it
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    -- Trip locations: must have write access (trip permission takes precedence)
    (trip_id IS NOT NULL AND public.can_modify_trip_locations(trip_id, auth.uid()))
)
WITH CHECK (
    -- Same conditions for the updated row
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    (trip_id IS NOT NULL AND public.can_modify_trip_locations(trip_id, auth.uid()))
);

-- DELETE policy: Users can delete their non-trip locations OR trip locations they have write access to
CREATE POLICY "locations_delete_policy"
ON public.locations
FOR DELETE
USING (
    -- Non-trip locations: must own it
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    -- Trip locations: must have write access (trip permission takes precedence)
    (trip_id IS NOT NULL AND public.can_modify_trip_locations(trip_id, auth.uid()))
);

-- ============================================================================
-- Grant execute permissions on helper functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.is_trip_owner(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_trip_collaborator(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_trip_write_access(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_modify_trip_locations(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_view_trip_locations(uuid, uuid) TO authenticated;

-- ============================================================================
-- Ensure RLS is enabled
-- ============================================================================

ALTER TABLE public.locations ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================
-- After running this migration, execute these queries to verify:

-- 1. Check that the correct policies exist:
/*
SELECT policyname, cmd
FROM pg_policies
WHERE tablename = 'locations'
ORDER BY cmd, policyname;

Expected output:
locations_delete_policy  | DELETE
locations_insert_policy  | INSERT
locations_select_policy  | SELECT
locations_update_policy  | UPDATE
*/

-- 2. Test the SELECT policy logic manually:
/*
-- This should show how the policy evaluates for a sample location
SELECT
    id,
    user_id,
    trip_id,
    name,
    -- Check if current user can see this location
    CASE
        WHEN trip_id IS NULL AND user_id = auth.uid() THEN 'YES - own non-trip location'
        WHEN trip_id IS NOT NULL AND public.can_view_trip_locations(trip_id, auth.uid()) THEN 'YES - trip location with access'
        ELSE 'NO - no access'
    END as can_view
FROM public.locations
LIMIT 10;
*/

-- ============================================================================
-- TESTING INSTRUCTIONS
-- ============================================================================
-- After applying this migration, test the following:

-- Test 1: Non-trip location visibility
-- - User A: Create a location without selecting a trip (trip_id = NULL)
-- - User A: Verify you can see the location on the map
-- - User B: Log in and verify you CANNOT see User A's location
-- Expected: User A sees their location, User B does NOT see it

-- Test 2: Trip location visibility (owner)
-- - User A: Create a trip and add a location to it
-- - User A: Verify you can see the trip location
-- - User B: Log in and verify you CANNOT see User A's trip location
-- Expected: User A sees it, User B does NOT see it

-- Test 3: Trip location visibility (collaborator with READ)
-- - User A: Add User B as a collaborator with READ permission
-- - User B: Verify you can NOW see the trip and its locations
-- - User B: Try to add/modify/delete a location (should fail)
-- Expected: User B can VIEW but not MODIFY

-- Test 4: Trip location visibility (collaborator with WRITE)
-- - User A: Change User B's permission to WRITE
-- - User B: Verify you can add/modify/delete locations
-- Expected: User B can VIEW and MODIFY
