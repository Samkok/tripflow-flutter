-- Migration: Add trip_collaborators table for team collaboration
-- This migration creates the trip_collaborators table and updates RLS policies

-- Create the trip_collaborators table
CREATE TABLE IF NOT EXISTS public.trip_collaborators (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    trip_id uuid NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    email text NOT NULL, -- Store email for display purposes
    permission text NOT NULL DEFAULT 'read' CHECK (permission IN ('read', 'write')),
    invited_by uuid NOT NULL REFERENCES auth.users(id),
    invited_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    accepted_at timestamp with time zone, -- NULL until user accepts (for future invite flow)
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,

    -- Ensure a user can only be added once per trip
    UNIQUE(trip_id, user_id)
);

-- Create indexes for faster lookups
CREATE INDEX IF NOT EXISTS trip_collaborators_trip_id_idx ON public.trip_collaborators(trip_id);
CREATE INDEX IF NOT EXISTS trip_collaborators_user_id_idx ON public.trip_collaborators(user_id);
CREATE INDEX IF NOT EXISTS trip_collaborators_email_idx ON public.trip_collaborators(email);

-- Enable RLS on trip_collaborators
ALTER TABLE public.trip_collaborators ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Users can view collaborators for trips they own or are collaborators of
CREATE POLICY "Users can view collaborators for their trips"
ON public.trip_collaborators
FOR SELECT
USING (
    -- User is the trip owner
    EXISTS (
        SELECT 1 FROM public.trips
        WHERE trips.id = trip_collaborators.trip_id
        AND trips.user_id = auth.uid()
    )
    OR
    -- User is a collaborator on this trip
    user_id = auth.uid()
);

-- RLS Policy: Only trip owners can add collaborators
CREATE POLICY "Trip owners can add collaborators"
ON public.trip_collaborators
FOR INSERT
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.trips
        WHERE trips.id = trip_collaborators.trip_id
        AND trips.user_id = auth.uid()
    )
);

-- RLS Policy: Trip owners can update collaborator permissions
CREATE POLICY "Trip owners can update collaborators"
ON public.trip_collaborators
FOR UPDATE
USING (
    EXISTS (
        SELECT 1 FROM public.trips
        WHERE trips.id = trip_collaborators.trip_id
        AND trips.user_id = auth.uid()
    )
);

-- RLS Policy: Trip owners can remove collaborators, or collaborators can remove themselves (leave)
CREATE POLICY "Trip owners can remove collaborators or users can leave"
ON public.trip_collaborators
FOR DELETE
USING (
    -- Trip owner can remove anyone
    EXISTS (
        SELECT 1 FROM public.trips
        WHERE trips.id = trip_collaborators.trip_id
        AND trips.user_id = auth.uid()
    )
    OR
    -- User can remove themselves (leave the trip)
    user_id = auth.uid()
);

-- Update trips RLS policies to include collaborators
-- First, drop existing select policy if it exists
DROP POLICY IF EXISTS "Users can view their own trips" ON public.trips;
DROP POLICY IF EXISTS "Users can view trips they own or collaborate on" ON public.trips;

-- Create new select policy that includes collaborators
CREATE POLICY "Users can view trips they own or collaborate on"
ON public.trips
FOR SELECT
USING (
    user_id = auth.uid()
    OR
    EXISTS (
        SELECT 1 FROM public.trip_collaborators
        WHERE trip_collaborators.trip_id = trips.id
        AND trip_collaborators.user_id = auth.uid()
    )
);

-- Update locations RLS to allow collaborators with write permission
DROP POLICY IF EXISTS "Users can view their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can view locations for trips they own or collaborate on" ON public.locations;

-- Allow users to view locations for trips they own or collaborate on
CREATE POLICY "Users can view locations for trips they own or collaborate on"
ON public.locations
FOR SELECT
USING (
    -- User owns the location
    user_id = auth.uid()
    OR
    -- Location belongs to a trip user owns
    EXISTS (
        SELECT 1 FROM public.trips
        WHERE trips.id = locations.trip_id
        AND trips.user_id = auth.uid()
    )
    OR
    -- Location belongs to a trip user collaborates on
    EXISTS (
        SELECT 1 FROM public.trip_collaborators
        WHERE trip_collaborators.trip_id = locations.trip_id
        AND trip_collaborators.user_id = auth.uid()
    )
);

-- Update insert policy for locations to allow write collaborators
DROP POLICY IF EXISTS "Users can insert their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can insert locations for trips they own or have write access" ON public.locations;

CREATE POLICY "Users can insert locations for trips they own or have write access"
ON public.locations
FOR INSERT
WITH CHECK (
    -- User owns the location (for non-trip locations)
    user_id = auth.uid()
    OR
    -- Location belongs to a trip user owns
    (
        trip_id IS NOT NULL
        AND EXISTS (
            SELECT 1 FROM public.trips
            WHERE trips.id = locations.trip_id
            AND trips.user_id = auth.uid()
        )
    )
    OR
    -- Location belongs to a trip user has write access to
    (
        trip_id IS NOT NULL
        AND EXISTS (
            SELECT 1 FROM public.trip_collaborators
            WHERE trip_collaborators.trip_id = locations.trip_id
            AND trip_collaborators.user_id = auth.uid()
            AND trip_collaborators.permission = 'write'
        )
    )
);

-- Update update policy for locations
DROP POLICY IF EXISTS "Users can update their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can update locations for trips they own or have write access" ON public.locations;

CREATE POLICY "Users can update locations for trips they own or have write access"
ON public.locations
FOR UPDATE
USING (
    -- User owns the location
    user_id = auth.uid()
    OR
    -- Location belongs to a trip user owns
    EXISTS (
        SELECT 1 FROM public.trips
        WHERE trips.id = locations.trip_id
        AND trips.user_id = auth.uid()
    )
    OR
    -- Location belongs to a trip user has write access to
    EXISTS (
        SELECT 1 FROM public.trip_collaborators
        WHERE trip_collaborators.trip_id = locations.trip_id
        AND trip_collaborators.user_id = auth.uid()
        AND trip_collaborators.permission = 'write'
    )
);

-- Update delete policy for locations
DROP POLICY IF EXISTS "Users can delete their own locations" ON public.locations;
DROP POLICY IF EXISTS "Users can delete locations for trips they own or have write access" ON public.locations;

CREATE POLICY "Users can delete locations for trips they own or have write access"
ON public.locations
FOR DELETE
USING (
    -- User owns the location
    user_id = auth.uid()
    OR
    -- Location belongs to a trip user owns
    EXISTS (
        SELECT 1 FROM public.trips
        WHERE trips.id = locations.trip_id
        AND trips.user_id = auth.uid()
    )
    OR
    -- Location belongs to a trip user has write access to
    EXISTS (
        SELECT 1 FROM public.trip_collaborators
        WHERE trip_collaborators.trip_id = locations.trip_id
        AND trip_collaborators.user_id = auth.uid()
        AND trip_collaborators.permission = 'write'
    )
);

-- Create a function to get user by email (for adding collaborators)
CREATE OR REPLACE FUNCTION public.get_user_id_by_email(user_email text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    found_user_id uuid;
BEGIN
    SELECT id INTO found_user_id
    FROM auth.users
    WHERE email = user_email;

    RETURN found_user_id;
END;
$$;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION public.get_user_id_by_email(text) TO authenticated;

-- Create updated_at trigger for trip_collaborators
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = timezone('utc'::text, now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_updated_at ON public.trip_collaborators;
CREATE TRIGGER set_updated_at
    BEFORE UPDATE ON public.trip_collaborators
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_updated_at();
