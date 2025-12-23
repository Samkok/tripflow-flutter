-- Migration 005: Comprehensive fix for location RLS policies
-- This migration fixes ALL permission issues with locations once and for all
--
-- PROBLEM: Previous policies had "user_id = auth.uid()" as an OR condition which allowed
-- ANY user to modify locations if they created them, even if they only have read permission
-- on the trip. This bypassed the trip permission system entirely.
--
-- SOLUTION: The logic must be:
-- 1. For non-trip locations (trip_id IS NULL): only the owner (user_id = auth.uid()) can CRUD
-- 2. For trip locations (trip_id IS NOT NULL): only trip owner OR write-permission collaborators can modify
--    The user_id field on locations in trips should NOT grant modify permissions

-- ============================================================================
-- STEP 1: Drop ALL existing location policies to start fresh
-- ============================================================================

DROP POLICY IF EXISTS "Users can view their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can view locations for trips they own or collaborate on" ON public.locations;
DROP POLICY IF EXISTS "Users can insert their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can insert locations for trips they own or have write access" ON public.locations;
DROP POLICY IF EXISTS "Users can update their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can update locations for trips they own or have write access" ON public.locations;
DROP POLICY IF EXISTS "Users can delete their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can delete locations for trips they own or have write access" ON public.locations;

-- ============================================================================
-- STEP 2: Ensure helper functions exist and are correct
-- ============================================================================

-- Function to check if user owns a trip (SECURITY DEFINER to avoid RLS recursion)
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

-- Function to check if user is a collaborator on a trip (any permission)
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

-- Function to check if user has WRITE access to a trip (write permission only)
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

-- Function to check if user can MODIFY a trip's locations (owner OR write collaborator)
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

-- Function to check if user can VIEW a trip's locations (owner OR any collaborator)
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
-- STEP 3: Create new SELECT policy
-- ============================================================================
-- Users can view:
-- 1. Their own non-trip locations (trip_id IS NULL AND user_id = auth.uid())
-- 2. Any location in trips they own or collaborate on (via helper function)

CREATE POLICY "locations_select_policy"
ON public.locations
FOR SELECT
USING (
    -- Case 1: Non-trip location - user must own it
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    -- Case 2: Trip location - user must be owner or collaborator of the trip
    (trip_id IS NOT NULL AND public.can_view_trip_locations(trip_id, auth.uid()))
);

-- ============================================================================
-- STEP 4: Create new INSERT policy
-- ============================================================================
-- Users can insert:
-- 1. Non-trip locations for themselves (trip_id IS NULL AND user_id = auth.uid())
-- 2. Trip locations if they are trip owner OR have write permission

CREATE POLICY "locations_insert_policy"
ON public.locations
FOR INSERT
WITH CHECK (
    -- Case 1: Non-trip location - user must be the owner
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    -- Case 2: Trip location - user must be able to modify trip locations
    (trip_id IS NOT NULL AND public.can_modify_trip_locations(trip_id, auth.uid()))
);

-- ============================================================================
-- STEP 5: Create new UPDATE policy
-- ============================================================================
-- Users can update:
-- 1. Their own non-trip locations (trip_id IS NULL AND user_id = auth.uid())
-- 2. ANY location in trips where they are owner OR have write permission
--    (regardless of who originally created the location)

CREATE POLICY "locations_update_policy"
ON public.locations
FOR UPDATE
USING (
    -- Case 1: Non-trip location - user must own it
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    -- Case 2: Trip location - user must be able to modify trip locations
    -- Note: We do NOT check user_id here - trip permission takes precedence
    (trip_id IS NOT NULL AND public.can_modify_trip_locations(trip_id, auth.uid()))
)
WITH CHECK (
    -- Same conditions for the new row after update
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    (trip_id IS NOT NULL AND public.can_modify_trip_locations(trip_id, auth.uid()))
);

-- ============================================================================
-- STEP 6: Create new DELETE policy
-- ============================================================================
-- Users can delete:
-- 1. Their own non-trip locations (trip_id IS NULL AND user_id = auth.uid())
-- 2. ANY location in trips where they are owner OR have write permission

CREATE POLICY "locations_delete_policy"
ON public.locations
FOR DELETE
USING (
    -- Case 1: Non-trip location - user must own it
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    -- Case 2: Trip location - user must be able to modify trip locations
    -- Note: We do NOT check user_id here - trip permission takes precedence
    (trip_id IS NOT NULL AND public.can_modify_trip_locations(trip_id, auth.uid()))
);

-- ============================================================================
-- STEP 7: Grant execute permissions on helper functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.is_trip_owner(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_trip_collaborator(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_trip_write_access(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_modify_trip_locations(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_view_trip_locations(uuid, uuid) TO authenticated;

-- ============================================================================
-- STEP 8: Verify RLS is enabled
-- ============================================================================

ALTER TABLE public.locations ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- VERIFICATION COMMENTS
-- ============================================================================
-- After running this migration, test the following scenarios:
--
-- 1. User A creates a non-trip location -> User A can CRUD, User B cannot see
-- 2. User A creates a trip and adds a location -> User A can CRUD
-- 3. User A adds User B with READ permission -> User B can VIEW only, not modify
-- 4. User A changes User B to WRITE permission -> User B can now CRUD
-- 5. User B (with READ) tries to add location via API -> Should be DENIED
-- 6. User B (with READ) tries to update location via API -> Should be DENIED
-- 7. User B (with READ) tries to delete location via API -> Should be DENIED
-- 8. User B (with WRITE) adds a location -> Should work
-- 9. User A can modify location created by User B (since A is owner)
-- 10. User B (with WRITE) can modify location created by User A
