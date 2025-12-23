-- Rollback for migration 004: Fix location permissions
-- This restores the previous (buggy) location RLS policies

-- Drop the fixed policies
DROP POLICY IF EXISTS "Users can view locations for trips they own or collaborate on" ON public.locations;
DROP POLICY IF EXISTS "Users can insert locations for trips they own or have write access" ON public.locations;
DROP POLICY IF EXISTS "Users can update locations for trips they own or have write access" ON public.locations;
DROP POLICY IF EXISTS "Users can delete locations for trips they own or have write access" ON public.locations;

-- Restore the old (buggy) policies from migration 003
CREATE POLICY "Users can view locations for trips they own or collaborate on"
ON public.locations
FOR SELECT
USING (
    -- User owns the location
    user_id = auth.uid()
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

CREATE POLICY "Users can insert locations for trips they own or have write access"
ON public.locations
FOR INSERT
WITH CHECK (
    -- User owns the location (for non-trip locations)
    user_id = auth.uid()
    OR
    -- Location belongs to a trip user owns or has write access to
    (
        trip_id IS NOT NULL
        AND (
            public.is_trip_owner(trip_id, auth.uid())
            OR
            public.has_trip_write_access(trip_id, auth.uid())
        )
    )
);

CREATE POLICY "Users can update locations for trips they own or have write access"
ON public.locations
FOR UPDATE
USING (
    -- User owns the location
    user_id = auth.uid()
    OR
    -- Location belongs to a trip user owns or has write access to
    (
        trip_id IS NOT NULL
        AND (
            public.is_trip_owner(trip_id, auth.uid())
            OR
            public.has_trip_write_access(trip_id, auth.uid())
        )
    )
);

CREATE POLICY "Users can delete locations for trips they own or have write access"
ON public.locations
FOR DELETE
USING (
    -- User owns the location
    user_id = auth.uid()
    OR
    -- Location belongs to a trip user owns or has write access to
    (
        trip_id IS NOT NULL
        AND (
            public.is_trip_owner(trip_id, auth.uid())
            OR
            public.has_trip_write_access(trip_id, auth.uid())
        )
    )
);
