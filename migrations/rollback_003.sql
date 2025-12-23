-- Rollback script for migration 003
-- Run this first to remove the broken policies before applying the fixed version

-- Drop the problematic trips policy that causes infinite recursion
DROP POLICY IF EXISTS "Users can view trips they own or collaborate on" ON public.trips;

-- Restore the original trips select policy
CREATE POLICY "Users can view their own trips"
ON public.trips
FOR SELECT
USING (user_id = auth.uid());

-- Drop the location policies
DROP POLICY IF EXISTS "Users can view locations for trips they own or collaborate on" ON public.locations;
DROP POLICY IF EXISTS "Users can insert locations for trips they own or have write access" ON public.locations;
DROP POLICY IF EXISTS "Users can update locations for trips they own or have write access" ON public.locations;
DROP POLICY IF EXISTS "Users can delete locations for trips they own or have write access" ON public.locations;

-- Restore original location policies
CREATE POLICY "Users can view their own locations"
ON public.locations
FOR SELECT
USING (user_id = auth.uid());

CREATE POLICY "Users can insert their own locations"
ON public.locations
FOR INSERT
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update their own locations"
ON public.locations
FOR UPDATE
USING (user_id = auth.uid());

CREATE POLICY "Users can delete their own locations"
ON public.locations
FOR DELETE
USING (user_id = auth.uid());

-- Drop all policies on trip_collaborators
DROP POLICY IF EXISTS "Users can view collaborators for their trips" ON public.trip_collaborators;
DROP POLICY IF EXISTS "Trip owners can add collaborators" ON public.trip_collaborators;
DROP POLICY IF EXISTS "Trip owners can update collaborators" ON public.trip_collaborators;
DROP POLICY IF EXISTS "Trip owners can remove collaborators or users can leave" ON public.trip_collaborators;

-- Drop helper functions if they exist
DROP FUNCTION IF EXISTS public.is_trip_owner(uuid, uuid);
DROP FUNCTION IF EXISTS public.is_trip_collaborator(uuid, uuid);
DROP FUNCTION IF EXISTS public.has_trip_write_access(uuid, uuid);

-- Drop the table (this will cascade delete all collaborators)
-- Comment this out if you want to keep the data
-- DROP TABLE IF EXISTS public.trip_collaborators CASCADE;
