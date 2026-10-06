-- Arrival and departure times.
--
-- A trip's first day often starts late (an afternoon landing) and its last
-- ends early (a midday flight). The owner can now say when: arrival_minute
-- is the time of day they arrive on the FIRST day, departure_minute the
-- time they leave on the LAST — both in minutes after midnight (0–1439,
-- the trip's own clock, no time zone). NULL = not set = a full day.
--
-- Times of day rather than timestamps on purpose: they belong to "Day 1"
-- and "the last day" whatever the dates are, so set_trip_dates(),
-- clear_trip_dates() and adding or removing days need no change, and a
-- trip with no dates yet can carry them too. Auto-plan reads them to fill
-- the first day only after the arrival and to end the last day in time to
-- leave.
--
-- Not copied by duplicate_public_trip(): they are the owner's own travel
-- times, not part of the itinerary someone else copies. The existing
-- owner-only UPDATE policy on trips covers both columns.

ALTER TABLE public.trips
  ADD COLUMN IF NOT EXISTS arrival_minute smallint
    CHECK (arrival_minute IS NULL OR arrival_minute BETWEEN 0 AND 1439),
  ADD COLUMN IF NOT EXISTS departure_minute smallint
    CHECK (departure_minute IS NULL OR departure_minute BETWEEN 0 AND 1439);

COMMENT ON COLUMN public.trips.arrival_minute IS
  'Time of day the traveller arrives on the trip''s first day, in minutes after midnight (0-1439). NULL = not set.';
COMMENT ON COLUMN public.trips.departure_minute IS
  'Time of day the traveller leaves on the trip''s last day, in minutes after midnight (0-1439). NULL = not set.';
