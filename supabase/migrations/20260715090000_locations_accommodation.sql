-- Accommodation support for trip locations.
--
-- A location can be flagged as the accommodation for the day(s) it spans
-- ([scheduled_date .. scheduled_end_date]). Business rule: a trip may have
-- MANY accommodations across its days, but any single calendar day has at
-- most ONE. The client enforces this with a friendly replace flow; the
-- exclusion constraint below is the authoritative backstop so concurrent
-- writers (owner + collaborators syncing offline edits) cannot violate it.
--
-- RLS: intentionally untouched — the new column rides the existing
-- locations policies (can_modify_trip_locations for writes), so exactly the
-- people who can edit a trip's places can flag its accommodation.

CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE public.locations
  ADD COLUMN IF NOT EXISTS is_accommodation boolean NOT NULL DEFAULT false;

-- An accommodation must sit on concrete day(s) — the uniqueness rule is
-- meaningless for unscheduled rows.
ALTER TABLE public.locations
  ADD CONSTRAINT locations_accommodation_needs_date
  CHECK (NOT is_accommodation OR scheduled_date IS NOT NULL);

-- ONE accommodation per trip-day: no two accommodation rows in the same trip
-- may overlap on any calendar day. Clients write local-midnight timestamps
-- serialized without an offset (interpreted as UTC), so AT TIME ZONE 'UTC'
-- recovers the intended wall-clock date.
ALTER TABLE public.locations
  ADD CONSTRAINT locations_one_accommodation_per_day
  EXCLUDE USING gist (
    trip_id WITH =,
    daterange(
      (scheduled_date AT TIME ZONE 'UTC')::date,
      (COALESCE(scheduled_end_date, scheduled_date) AT TIME ZONE 'UTC')::date,
      '[]'
    ) WITH &&
  ) WHERE (is_accommodation AND trip_id IS NOT NULL);
