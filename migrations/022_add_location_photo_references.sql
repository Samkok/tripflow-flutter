-- Migration 022: Add photo_references gallery column to locations
--
-- The app now fetches up to 5 photos per place from the Google Places API and
-- displays them as an in-card gallery. The existing single `photo_reference`
-- column is kept for back-compat with rows written by older clients; new
-- clients write the first item of `photo_references` into both columns so a
-- mixed fleet can still render a cover image.

ALTER TABLE public.locations
  ADD COLUMN IF NOT EXISTS photo_references text[];
