-- Migration 020: Fix notification display name
-- Use first+last name from user_profiles if available,
-- otherwise fall back to the email prefix (before @) instead of the full email.

CREATE OR REPLACE FUNCTION public.notify_collaborator_added()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_trip_name text;
    v_inviter_name text;
    v_inviter_email text;
BEGIN
    -- Get trip name
    SELECT name INTO v_trip_name
        FROM public.trips WHERE id = NEW.trip_id;

    -- Get inviter email for fallback
    SELECT email INTO v_inviter_email
        FROM public.user_profiles WHERE user_id = NEW.invited_by;

    -- Get inviter's display name: first+last if present, else email prefix
    SELECT COALESCE(
        NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), ''),
        SPLIT_PART(email, '@', 1)
    )
    INTO v_inviter_name
    FROM public.user_profiles WHERE user_id = NEW.invited_by;

    -- Create notification for the newly added collaborator
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
        NEW.user_id,
        'collaborator_added',
        'Added to a trip',
        COALESCE(v_inviter_name, 'Someone') || ' added you to "' || COALESCE(v_trip_name, 'a trip') || '"',
        jsonb_build_object(
            'trip_id', NEW.trip_id::text,
            'invited_by', NEW.invited_by::text
        )
    );

    RETURN NEW;
END;
$$;


CREATE OR REPLACE FUNCTION public.notify_location_added()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_trip_name text;
    v_adder_name text;
    v_trip_owner_id uuid;
    v_collab record;
BEGIN
    -- Skip if trip has no collaborators (solo trip — no one to notify)
    IF NOT EXISTS (
        SELECT 1 FROM public.trip_collaborators
        WHERE trip_id = NEW.trip_id LIMIT 1
    ) THEN
        RETURN NEW;
    END IF;

    -- Get trip info
    SELECT t.name, t.user_id INTO v_trip_name, v_trip_owner_id
        FROM public.trips t WHERE t.id = NEW.trip_id;

    -- Skip if the location was added by the trip owner
    IF NEW.user_id = v_trip_owner_id THEN
        RETURN NEW;
    END IF;

    -- Get adder's display name: first+last if present, else email prefix
    SELECT COALESCE(
        NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), ''),
        SPLIT_PART(email, '@', 1)
    )
    INTO v_adder_name
    FROM public.user_profiles WHERE user_id = NEW.user_id;

    -- Notify the trip owner
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

    -- Notify other collaborators (all except the one who added the location)
    FOR v_collab IN
        SELECT user_id FROM public.trip_collaborators
        WHERE trip_id = NEW.trip_id AND user_id <> NEW.user_id
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
$$;
