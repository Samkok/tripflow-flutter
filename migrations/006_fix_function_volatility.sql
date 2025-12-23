-- Migration 006: Fix function volatility to prevent caching issues
--
-- PROBLEM: The RLS helper functions were marked as STABLE, which allows
-- PostgreSQL to cache their results within a transaction. This means when
-- a user's permission changes, the old cached result might still be used
-- within the same transaction, causing a security bypass.
--
-- SOLUTION: Change all permission-checking functions to VOLATILE to force
-- PostgreSQL to re-evaluate them on every call, ensuring permission changes
-- take effect immediately.

-- ============================================================================
-- Update function volatility from STABLE to VOLATILE
-- ============================================================================

-- Function to check if user owns a trip
CREATE OR REPLACE FUNCTION public.is_trip_owner(trip_uuid uuid, user_uuid uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
VOLATILE  -- Changed from STABLE to VOLATILE
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
VOLATILE  -- Changed from STABLE to VOLATILE
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
VOLATILE  -- Changed from STABLE to VOLATILE
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
VOLATILE  -- Changed from STABLE to VOLATILE
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
VOLATILE  -- Changed from STABLE to VOLATILE
AS $$
    SELECT
        public.is_trip_owner(trip_uuid, user_uuid)
        OR
        public.is_trip_collaborator(trip_uuid, user_uuid);
$$;

-- ============================================================================
-- VERIFICATION
-- ============================================================================
-- After running this migration, permissions should update immediately:
--
-- Test scenario:
-- 1. User A shares trip with User B (read permission)
-- 2. User B tries to modify location -> DENIED by RLS
-- 3. User A changes User B to write permission
-- 4. User B immediately tries to modify location -> ALLOWED (no app restart needed)
-- 5. User A changes User B back to read permission
-- 6. User B immediately tries to modify location -> DENIED (permission revoked instantly)
