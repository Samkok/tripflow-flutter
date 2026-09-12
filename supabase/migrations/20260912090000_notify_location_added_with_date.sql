-- location_added notifications: say WHICH DAY the stop was added to.
--
-- Members reading "Sam added 'Chợ Bến Thành' to 'Vietnam'" had no idea
-- which day of the trip it landed on. The body now ends with the scheduled
-- day ("… to 'Vietnam' for Sep 14", or "for Sep 14 – Sep 16" for a multi-day
-- stay), and the payload carries the raw dates so the client can render or
-- deep-link to the day later without parsing the sentence. Unscheduled adds
-- (no date) say "(no date yet)".
--
-- Date formatting: scheduled_date is written by the app as the trip day's
-- LOCAL midnight with no offset, which Postgres stores as that instant in
-- UTC — so reading it back AT TIME ZONE 'UTC' yields the calendar day the
-- user picked (same convention as the accommodation-span CHECK).
--
-- Everything else is unchanged from 20260731090000: owner adds → all
-- collaborators; collaborator adds → owner + every other collaborator; the
-- adder is never notified; the owner is never notified twice.
CREATE OR REPLACE FUNCTION public.notify_location_added()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_trip_name text;
    v_adder_name text;
    v_trip_owner_id uuid;
    v_collab record;
    v_day_text text;
    v_body text;
    v_data jsonb;
BEGIN
    -- Skip standalone locations and solo trips (no one to notify)
    IF NEW.trip_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.trip_collaborators
        WHERE trip_id = NEW.trip_id LIMIT 1
    ) THEN
        RETURN NEW;
    END IF;

    -- Get trip info
    SELECT t.name, t.user_id INTO v_trip_name, v_trip_owner_id
        FROM public.trips t WHERE t.id = NEW.trip_id;

    -- Get adder's display name: first+last if present, else email prefix
    SELECT COALESCE(
        NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), ''),
        SPLIT_PART(email, '@', 1)
    )
    INTO v_adder_name
    FROM public.user_profiles WHERE user_id = NEW.user_id;

    -- Which day: "for Sep 14", "for Sep 14 – Sep 16", or "(no date yet)".
    IF NEW.scheduled_date IS NULL THEN
        v_day_text := ' (no date yet)';
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
