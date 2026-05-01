-- Migration: Add country_code field to trips table
-- Stores an optional ISO 3166-1 alpha-2 country code (e.g. 'JP', 'KH', 'US')
-- selected by the user when creating a trip. Used to bias Google Places
-- search results toward the planned destination.

ALTER TABLE public.trips
ADD COLUMN IF NOT EXISTS country_code text;

-- Length guard so callers cannot stuff arbitrary strings into the column.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.constraint_column_usage
    WHERE table_schema = 'public'
      AND table_name = 'trips'
      AND constraint_name = 'trips_country_code_format'
  ) THEN
    ALTER TABLE public.trips
    ADD CONSTRAINT trips_country_code_format
    CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$');
  END IF;
END $$;
