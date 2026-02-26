-- Migration 016: Add missing columns to the locations table
--
-- PROBLEM: The locations table is missing several columns that the Flutter app's
-- SavedLocation.toJson() sends in every upsert call:
--   - source, is_synced, is_done, last_synced_at, photo_reference, photo_attributions
--
-- This caused EVERY syncLocation() call to fail silently with:
--   "column <name> of relation locations does not exist"
--
-- The result: locations were only saved to local Hive (device cache) and NEVER
-- made it to Supabase. Consequently:
--   - trip_id was never set in the database (it was correct in Hive but never synced)
--   - Collaborators could never see each other's added locations
--   - Even after fetchRemoteLocations(), collaborator locations were absent
--
-- SOLUTION: Add all missing columns with safe ADD COLUMN IF NOT EXISTS

ALTER TABLE public.locations
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'synced',
  ADD COLUMN IF NOT EXISTS is_synced boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS is_done boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS last_synced_at timestamp with time zone,
  ADD COLUMN IF NOT EXISTS photo_reference text,
  ADD COLUMN IF NOT EXISTS photo_attributions text[];

-- Indexes for commonly filtered columns
CREATE INDEX IF NOT EXISTS locations_source_idx ON public.locations (source);
CREATE INDEX IF NOT EXISTS locations_is_done_idx ON public.locations (is_done);
