-- Migration 028: Add opening-hours fields to locations
--
-- Powers the closing-time-aware optimizer feature. Three new columns:
--
--   google_opening_hours          jsonb  -- per-day open/close periods captured
--                                           from Google Places, structured as
--                                           [{open_day, open_minutes, close_day,
--                                             close_minutes}, ...]. Day is 0–6
--                                           (Sunday=0) per Google's convention.
--                                           Times are minutes since midnight.
--                                           Read-only — never overwritten by
--                                           user edits.
--
--   user_closing_minute_override  int    -- user-supplied "treat as closing
--                                           at this time" (minutes since
--                                           midnight, 0–1439), or 1440 as a
--                                           sentinel for "never closes" (e.g.
--                                           accommodation). When non-null, the
--                                           timing simulation prefers this over
--                                           Google's hours.
--
--   hours_last_refreshed_at       timestamptz  -- when google_opening_hours was
--                                                last fetched. Drives the
--                                                "refreshed N days ago" UI hint.
--
-- All three columns are nullable: existing rows have no hours data (no client
-- backfill possible without an extra Places API call per row), and not every
-- place has hours (manual-coord adds, residential places, etc.). The optimizer
-- treats null hours as "always open" to avoid spurious warnings.

ALTER TABLE public.locations
  ADD COLUMN IF NOT EXISTS google_opening_hours jsonb,
  ADD COLUMN IF NOT EXISTS user_closing_minute_override int
    CHECK (user_closing_minute_override IS NULL
       OR (user_closing_minute_override >= 0
       AND user_closing_minute_override <= 1440)),
  ADD COLUMN IF NOT EXISTS hours_last_refreshed_at timestamptz;
