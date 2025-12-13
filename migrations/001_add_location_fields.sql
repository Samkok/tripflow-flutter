-- Migration: Add missing columns to locations table
-- This migration adds scheduled_date, is_skipped, and stay_duration columns to support trip scheduling

-- Check if columns exist before adding them (for idempotency)
ALTER TABLE public.locations
ADD COLUMN IF NOT EXISTS scheduled_date timestamp with time zone,
ADD COLUMN IF NOT EXISTS is_skipped boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS stay_duration integer DEFAULT 0;

-- Create an index on scheduled_date for faster filtering by date
CREATE INDEX IF NOT EXISTS locations_scheduled_date_idx ON public.locations (scheduled_date);

-- Update the RLS policies if needed (they should already work with new columns)
-- No policy changes needed as all columns are user-controlled
