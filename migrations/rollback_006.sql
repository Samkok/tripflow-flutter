-- Rollback for migration 006: Revert function volatility back to STABLE
-- This will restore the previous behavior (not recommended - may cause caching issues)

-- Function to check if user owns a trip
CREATE OR REPLACE FUNCTION public.is_trip_owner(trip_uuid uuid, user_uuid uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE  -- Reverted back to STABLE
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
STABLE  -- Reverted back to STABLE
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
STABLE  -- Reverted back to STABLE
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
STABLE  -- Reverted back to STABLE
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
STABLE  -- Reverted back to STABLE
AS $$
    SELECT
        public.is_trip_owner(trip_uuid, user_uuid)
        OR
        public.is_trip_collaborator(trip_uuid, user_uuid);
$$;
