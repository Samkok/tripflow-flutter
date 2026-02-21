-- Migration 013: Push Notification System
-- Creates device_tokens + notifications tables with PostgreSQL triggers
-- Enables event-driven push notifications via Supabase Database Webhook → FCM

-- ============================================================================
-- STEP 1: Create device_tokens table
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.device_tokens (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    fcm_token text NOT NULL UNIQUE,           -- each physical FCM token is globally unique
    platform text NOT NULL CHECK (platform IN ('ios', 'android')),
    is_active boolean NOT NULL DEFAULT true,  -- false when user signs out or app uninstalled
    created_at timestamptz DEFAULT timezone('utc', now()) NOT NULL,
    updated_at timestamptz DEFAULT timezone('utc', now()) NOT NULL
);

-- Indexes
CREATE INDEX IF NOT EXISTS device_tokens_user_id_idx
    ON public.device_tokens(user_id);

CREATE INDEX IF NOT EXISTS device_tokens_user_active_idx
    ON public.device_tokens(user_id, is_active);

-- Enable RLS
ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

-- Authenticated users can manage their own device tokens
CREATE POLICY "Users manage own device tokens"
    ON public.device_tokens
    FOR ALL
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- Updated_at trigger
CREATE TRIGGER set_device_tokens_updated_at
    BEFORE UPDATE ON public.device_tokens
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_updated_at();

-- ============================================================================
-- STEP 2: Create notifications table
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.notifications (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    type text NOT NULL,            -- 'collaborator_added', 'location_added', etc.
    title text NOT NULL,
    body text NOT NULL,
    data jsonb NOT NULL DEFAULT '{}',
    is_read boolean NOT NULL DEFAULT false,
    read_at timestamptz,
    created_at timestamptz DEFAULT timezone('utc', now()) NOT NULL
);

-- Indexes
CREATE INDEX IF NOT EXISTS notifications_user_id_idx
    ON public.notifications(user_id);

CREATE INDEX IF NOT EXISTS notifications_user_read_idx
    ON public.notifications(user_id, is_read);

CREATE INDEX IF NOT EXISTS notifications_created_at_idx
    ON public.notifications(created_at DESC);

-- Enable RLS
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Users can view their own notifications
CREATE POLICY "Users view own notifications"
    ON public.notifications
    FOR SELECT
    USING (auth.uid() = user_id);

-- Users can mark their own notifications as read
CREATE POLICY "Users mark own notifications read"
    ON public.notifications
    FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- Only service role can insert notifications (via SECURITY DEFINER triggers)
CREATE POLICY "Service role inserts notifications"
    ON public.notifications
    FOR INSERT
    WITH CHECK (auth.role() = 'service_role');

-- Enable Realtime so in-app badge can update live
ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;

-- ============================================================================
-- STEP 3: Trigger — collaborator_added
-- Fires when a user is added to trip_collaborators
-- Notifies the newly added collaborator
-- ============================================================================

CREATE OR REPLACE FUNCTION public.notify_collaborator_added()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_trip_name text;
    v_inviter_name text;
BEGIN
    -- Get trip name
    SELECT name INTO v_trip_name
        FROM public.trips WHERE id = NEW.trip_id;

    -- Get inviter's display name
    SELECT COALESCE(
        NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), ''),
        email
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

CREATE TRIGGER on_collaborator_added
    AFTER INSERT ON public.trip_collaborators
    FOR EACH ROW
    EXECUTE FUNCTION public.notify_collaborator_added();

-- ============================================================================
-- STEP 4: Trigger — location_added
-- Fires when a location is inserted into a collaborative trip
-- Notifies trip owner and all other collaborators
-- ============================================================================

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
    -- (owners don't need to notify themselves)
    IF NEW.user_id = v_trip_owner_id THEN
        RETURN NEW;
    END IF;

    -- Get adder's display name
    SELECT COALESCE(
        NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), ''),
        email
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

CREATE TRIGGER on_location_added
    AFTER INSERT ON public.locations
    FOR EACH ROW
    EXECUTE FUNCTION public.notify_location_added();

-- ============================================================================
-- VERIFICATION COMMENTS
-- ============================================================================
-- After running this migration, verify:
--
-- 1. Tables created:
--    SELECT * FROM device_tokens;
--    SELECT * FROM notifications;
--
-- 2. RLS enabled:
--    SELECT tablename, rowsecurity FROM pg_tables
--    WHERE tablename IN ('device_tokens', 'notifications');
--
-- 3. Realtime enabled for notifications:
--    SELECT * FROM pg_publication_tables
--    WHERE pubname = 'supabase_realtime' AND tablename = 'notifications';
--
-- 4. Test collaborator trigger (use real UUIDs):
--    INSERT INTO trip_collaborators (trip_id, user_id, email, permission, invited_by)
--    VALUES ('...', '...', 'test@test.com', 'read', '...');
--    -- Check: SELECT * FROM notifications;
--
-- 5. Next step: Create Supabase Database Webhook in Dashboard:
--    Database → Webhooks → Create new webhook
--    Table: public.notifications, Event: INSERT
--    URL: https://dkbibfjszsohtixjxlle.supabase.co/functions/v1/send-push-notification
