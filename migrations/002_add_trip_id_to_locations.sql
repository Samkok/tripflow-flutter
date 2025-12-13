-- Migration: Add trip_id field to locations table
-- This allows locations to be associated with specific trips

ALTER TABLE public.locations
ADD COLUMN IF NOT EXISTS trip_id uuid references public.trips(id) on delete set null;

-- Create index for faster trip-based lookups
CREATE INDEX IF NOT EXISTS locations_trip_id_idx ON public.locations (trip_id);

-- Create index for finding locations by user and trip
CREATE INDEX IF NOT EXISTS locations_user_trip_idx ON public.locations (user_id, trip_id);
