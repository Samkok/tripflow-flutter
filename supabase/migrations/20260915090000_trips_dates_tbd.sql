-- Trips without dates yet.
--
-- A trip can now be planned before its dates are known: its days are
-- "Day 1, Day 2, …". Under the hood nothing about dates changes — every
-- date-keyed piece of the app keeps working — because an undated trip
-- simply sits on a far-future ANCHOR: start_date = 2100-01-01, end_date =
-- anchor + (days - 1), and every stop's scheduled_date/scheduled_end_date
-- on anchor + (day - 1). `dates_tbd` tells the app to show day numbers
-- instead of calendar dates and to hide weekday-dependent hints. The
-- far-future anchor also guarantees no undated plan is ever treated as
-- past or due (rollover, past-trip locks).
--
-- set_trip_dates() then moves the whole plan so that Day 1 lands on the
-- chosen start date: same day-shift for the trip and every stop.

ALTER TABLE public.trips
  ADD COLUMN IF NOT EXISTS dates_tbd boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.trips.dates_tbd IS
  'True while the trip has no real dates: start_date/end_date and every stop''s scheduled_date sit on the 2100-01-01 anchor (Day N = anchor + N-1) until set_trip_dates() moves them.';

-- Owner-only. Shifts the trip's dates and every stop's scheduled day by the
-- same number of days so Day 1 = p_start_date, then clears dates_tbd.
-- Also usable to reschedule a dated trip (same shift semantics).
--
-- Stops move in TWO passes through a far-away parking offset: the
-- one-accommodation-per-day exclusion constraint checks rows one at a time,
-- so a single pass could see a stay land on the days its neighbour hasn't
-- vacated yet and refuse a perfectly valid shift.
CREATE OR REPLACE FUNCTION public.set_trip_dates(p_trip_id uuid, p_start_date date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_trip trips%ROWTYPE;
  v_old_start date;
  v_old_end date;
  v_delta integer;
  v_park constant integer := 100000;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;
  IF p_start_date IS NULL THEN
    RAISE EXCEPTION 'bad_request';
  END IF;

  SELECT * INTO v_trip FROM trips WHERE id = p_trip_id AND user_id = v_user;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  -- Dates are written by the app as local midnight with no offset, stored
  -- as that instant in UTC — AT TIME ZONE 'UTC' recovers the calendar day.
  v_old_start := coalesce(
    (v_trip.start_date AT TIME ZONE 'UTC')::date,
    (SELECT min((l.scheduled_date AT TIME ZONE 'UTC')::date)
       FROM locations l WHERE l.trip_id = p_trip_id AND l.scheduled_date IS NOT NULL),
    p_start_date);
  v_old_end := coalesce(
    (v_trip.end_date AT TIME ZONE 'UTC')::date,
    (SELECT max((coalesce(l.scheduled_end_date, l.scheduled_date) AT TIME ZONE 'UTC')::date)
       FROM locations l WHERE l.trip_id = p_trip_id AND l.scheduled_date IS NOT NULL),
    v_old_start);
  IF v_old_end < v_old_start THEN
    v_old_end := v_old_start;
  END IF;

  v_delta := p_start_date - v_old_start;

  IF v_delta <> 0 THEN
    UPDATE locations
       SET scheduled_date     = scheduled_date + make_interval(days => v_delta + v_park),
           scheduled_end_date = scheduled_end_date + make_interval(days => v_delta + v_park)
     WHERE trip_id = p_trip_id AND scheduled_date IS NOT NULL;
    UPDATE locations
       SET scheduled_date     = scheduled_date - make_interval(days => v_park),
           scheduled_end_date = scheduled_end_date - make_interval(days => v_park)
     WHERE trip_id = p_trip_id AND scheduled_date IS NOT NULL;
  END IF;

  UPDATE trips
     SET start_date = (p_start_date::timestamp) AT TIME ZONE 'UTC',
         end_date   = ((p_start_date + (v_old_end - v_old_start))::timestamp) AT TIME ZONE 'UTC',
         dates_tbd  = false,
         updated_at = now()
   WHERE id = p_trip_id;
END;
$$;

REVOKE ALL ON FUNCTION public.set_trip_dates(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_trip_dates(uuid, date) TO authenticated;

COMMENT ON FUNCTION public.set_trip_dates(uuid, date) IS
  'Owner-only: shift the trip and every stop so Day 1 = p_start_date; clears dates_tbd. Two-pass move keeps the accommodation exclusion constraint quiet.';

-- notify_location_added: on an undated trip the push says "for Day 3"
-- instead of a meaningless 2100 calendar date. Otherwise identical to
-- 20260912090000 (owner adds → all collaborators; collaborator adds → owner
-- + every other collaborator; the adder is never notified; the owner never
-- twice).
CREATE OR REPLACE FUNCTION public.notify_location_added()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_trip_name text;
    v_trip_owner_id uuid;
    v_trip_dates_tbd boolean;
    v_trip_start date;
    v_adder_name text;
    v_collab record;
    v_day_text text;
    v_body text;
    v_data jsonb;
    v_day integer;
    v_day_end integer;
BEGIN
    -- Skip standalone locations and solo trips (no one to notify)
    IF NEW.trip_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.trip_collaborators
        WHERE trip_id = NEW.trip_id LIMIT 1
    ) THEN
        RETURN NEW;
    END IF;

    -- Get trip info
    SELECT t.name, t.user_id, coalesce(t.dates_tbd, false),
           (t.start_date AT TIME ZONE 'UTC')::date
      INTO v_trip_name, v_trip_owner_id, v_trip_dates_tbd, v_trip_start
      FROM public.trips t WHERE t.id = NEW.trip_id;

    -- Get adder's display name: first+last if present, else email prefix
    SELECT COALESCE(
        NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), ''),
        SPLIT_PART(email, '@', 1)
    )
    INTO v_adder_name
    FROM public.user_profiles WHERE user_id = NEW.user_id;

    -- Which day: "for Sep 14", "for Sep 14 – Sep 16", "for Day 3",
    -- "for Day 3 – Day 5", or "(no date yet)".
    IF NEW.scheduled_date IS NULL THEN
        v_day_text := ' (no date yet)';
    ELSIF v_trip_dates_tbd AND v_trip_start IS NOT NULL THEN
        v_day := (NEW.scheduled_date AT TIME ZONE 'UTC')::date - v_trip_start + 1;
        v_day_end := CASE WHEN NEW.scheduled_end_date IS NULL THEN v_day
                          ELSE (NEW.scheduled_end_date AT TIME ZONE 'UTC')::date - v_trip_start + 1 END;
        IF v_day_end > v_day THEN
            v_day_text := ' for Day ' || v_day || ' – Day ' || v_day_end;
        ELSE
            v_day_text := ' for Day ' || v_day;
        END IF;
    ELSIF NEW.scheduled_end_date IS NOT NULL
          AND (NEW.scheduled_end_date AT TIME ZONE 'UTC')::date
              > (NEW.scheduled_date AT TIME ZONE 'UTC')::date THEN
        v_day_text := ' for '
            || to_char(NEW.scheduled_date AT TIME ZONE 'UTC', 'Mon FMDD')
            || ' – '
            || to_char(NEW.scheduled_end_date AT TIME ZONE 'UTC', 'Mon FMDD');
    ELSE
        v_day_text := ' for '
            || to_char(NEW.scheduled_date AT TIME ZONE 'UTC', 'Mon FMDD');
    END IF;

    v_body := COALESCE(v_adder_name, 'A collaborator') ||
        ' added "' || COALESCE(NEW.name, 'a location') ||
        '" to "' || COALESCE(v_trip_name, 'your trip') || '"' || v_day_text;

    v_data := jsonb_build_object(
        'trip_id', NEW.trip_id::text,
        'location_id', NEW.id::text,
        'scheduled_date',
            CASE WHEN NEW.scheduled_date IS NULL THEN NULL
                 ELSE to_char((NEW.scheduled_date AT TIME ZONE 'UTC')::date, 'YYYY-MM-DD') END,
        'scheduled_end_date',
            CASE WHEN NEW.scheduled_end_date IS NULL THEN NULL
                 ELSE to_char((NEW.scheduled_end_date AT TIME ZONE 'UTC')::date, 'YYYY-MM-DD') END
    );

    -- Notify the trip owner (unless the owner is the adder)
    IF v_trip_owner_id IS NOT NULL AND NEW.user_id IS DISTINCT FROM v_trip_owner_id THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_trip_owner_id, 'location_added', 'New stop added', v_body, v_data);
    END IF;

    -- Notify every collaborator except the adder (and except the owner,
    -- who was handled above and must not be notified twice)
    FOR v_collab IN
        SELECT user_id FROM public.trip_collaborators
        WHERE trip_id = NEW.trip_id
          AND user_id <> NEW.user_id
          AND user_id IS DISTINCT FROM v_trip_owner_id
    LOOP
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_collab.user_id, 'location_added', 'New stop added', v_body, v_data);
    END LOOP;

    RETURN NEW;
END;
$function$;
