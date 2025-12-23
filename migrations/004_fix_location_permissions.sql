-- Migration: Fix location RLS policies to properly enforce read/write permissions
-- This migration fixes the issue where read-only collaborators can modify trip locations

-- Drop existing location policies
DROP POLICY IF EXISTS "Users can view locations for trips they own or collaborate on" ON public.locations;
DROP POLICY IF EXISTS "Users can insert locations for trips they own or have write access" ON public.locations;
DROP POLICY IF EXISTS "Users can update locations for trips they own or have write access" ON public.locations;
DROP POLICY IF EXISTS "Users can delete locations for trips they own or have write access" ON public.locations;

-- SELECT: Users can view their own locations OR locations for trips they own/collaborate on
CREATE POLICY "Users can view locations for trips they own or collaborate on"
ON public.locations
FOR SELECT
USING (
    -- User owns the location (for non-trip locations)
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    -- Location belongs to a trip user owns or collaborates on
    (
        trip_id IS NOT NULL
        AND (
            public.is_trip_owner(trip_id, auth.uid())
            OR
            public.is_trip_collaborator(trip_id, auth.uid())
        )
    )
);

-- INSERT: Different rules for trip vs non-trip locations
CREATE POLICY "Users can insert locations for trips they own or have write access"
ON public.locations
FOR INSERT
WITH CHECK (
    -- For non-trip locations: user must be the owner
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    -- For trip locations: user must be trip owner OR have write access
    (
        trip_id IS NOT NULL
        AND user_id = auth.uid()
        AND (
            public.is_trip_owner(trip_id, auth.uid())
            OR
            public.has_trip_write_access(trip_id, auth.uid())
        )
    )
);

-- UPDATE: Different rules for trip vs non-trip locations
CREATE POLICY "Users can update locations for trips they own or have write access"
ON public.locations
FOR UPDATE
USING (
    -- For non-trip locations: user must be the owner
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    -- For trip locations: user must be trip owner OR have write access
    (
        trip_id IS NOT NULL
        AND (
            public.is_trip_owner(trip_id, auth.uid())
            OR
            public.has_trip_write_access(trip_id, auth.uid())
        )
    )
);

-- DELETE: Different rules for trip vs non-trip locations
CREATE POLICY "Users can delete locations for trips they own or have write access"
ON public.locations
FOR DELETE
USING (
    -- For non-trip locations: user must be the owner
    (trip_id IS NULL AND user_id = auth.uid())
    OR
    -- For trip locations: user must be trip owner OR have write access
    (
        trip_id IS NOT NULL
        AND (
            public.is_trip_owner(trip_id, auth.uid())
            OR
            public.has_trip_write_access(trip_id, auth.uid())
        )
    )
);
