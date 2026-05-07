-- Migration 027: Add place_id and original_name to locations
--
-- Lets the client open external apps (Google Maps, Grab) anchored to the
-- exact Google place rather than a coordinate, so renamed entries still
-- resolve correctly when handed off. `original_name` mirrors the Google
-- name at the time of add, so even after a user edits `name` we still
-- have the canonical label to send to those apps.
--
-- Both columns are nullable: existing rows have no place_id (no backfill
-- possible client-side), and the manual-coord add path may not have one
-- either — callers fall back to coords in that case, matching today's
-- behavior.

ALTER TABLE public.locations
  ADD COLUMN IF NOT EXISTS place_id text,
  ADD COLUMN IF NOT EXISTS original_name text;
