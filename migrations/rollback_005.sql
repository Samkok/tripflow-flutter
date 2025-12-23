-- Rollback for migration 005: Comprehensive fix for location RLS policies
-- This will restore the previous (flawed) policies if needed

-- Drop the new policies
DROP POLICY IF EXISTS "locations_select_policy" ON public.locations;
DROP POLICY IF EXISTS "locations_insert_policy" ON public.locations;
DROP POLICY IF EXISTS "locations_update_policy" ON public.locations;
DROP POLICY IF EXISTS "locations_delete_policy" ON public.locations;

-- Drop new helper functions
DROP FUNCTION IF EXISTS public.can_modify_trip_locations(uuid, uuid);
DROP FUNCTION IF EXISTS public.can_view_trip_locations(uuid, uuid);

-- Restore old policies (from migration 003)
-- Note: These have the bug where user_id = auth.uid() bypasses trip permissions

CREATE POLICY "Users can view locations for trips they own or collaborate on"
ON public.locations
FOR SELECT
USING (
    user_id = auth.uid()
    OR
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
    user_id = auth.uid()
    OR
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
    user_id = auth.uid()
    OR
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
    user_id = auth.uid()
    OR
    (
        trip_id IS NOT NULL
        AND (
            public.is_trip_owner(trip_id, auth.uid())
            OR
            public.has_trip_write_access(trip_id, auth.uid())
        )
    )
);
