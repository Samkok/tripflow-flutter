-- location_added notifications: alert EVERY trip member except the adder.
--
-- Previously the trigger returned early when the trip OWNER added a location,
-- so collaborators were never told about owner adds. Now:
--   • owner adds     → all collaborators notified
--   • collaborator adds → owner + all other collaborators notified
--   • the adder never notifies themself
--   • owner is excluded from the collaborator loop so they can't be
--     notified twice if they also hold a collaborator row.
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

    -- Notify the trip owner (unless the owner is the adder)
    IF v_trip_owner_id IS NOT NULL AND NEW.user_id IS DISTINCT FROM v_trip_owner_id THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
            v_trip_owner_id,
            'location_added',
            'New stop added',
            COALESCE(v_adder_name, 'A collaborator') ||
                ' added "' || COALESCE(NEW.name, 'a location') ||
                '" to "' || COALESCE(v_trip_name, 'your trip') || '"',
            jsonb_build_object(
                'trip_id', NEW.trip_id::text,
                'location_id', NEW.id::text
            )
        );
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
        VALUES (
            v_collab.user_id,
            'location_added',
            'New stop added',
            COALESCE(v_adder_name, 'A collaborator') ||
                ' added "' || COALESCE(NEW.name, 'a location') ||
                '" to "' || COALESCE(v_trip_name, 'your trip') || '"',
            jsonb_build_object(
                'trip_id', NEW.trip_id::text,
                'location_id', NEW.id::text
            )
        );
    END LOOP;

    RETURN NEW;
END;
$function$;
