-- Public trip sharing & copy-by-code.
--
-- Owners mint a short share code (NOT the trip id) by making a trip public;
-- anyone signed in can paste the code to DUPLICATE the trip (never join it).
-- Toggling the trip private makes the code inert immediately (checked at
-- duplicate time). Free users get ONE lifetime copy, counted on
-- user_profiles so delete-and-recopy can't launder it.
--
-- SECURITY MODEL: trips/locations RLS stays strictly owner-or-collaborator.
-- No public SELECT policy exists or is added — every public read flows
-- through the SECURITY DEFINER functions below, by exact code, signed-in
-- only, rate-limited, and answering identically for "unknown code" and
-- "private trip" so existence never leaks.

ALTER TABLE public.trips
  ADD COLUMN IF NOT EXISTS is_public boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS share_code text UNIQUE;

CREATE INDEX IF NOT EXISTS trips_share_code_idx
  ON public.trips (share_code) WHERE share_code IS NOT NULL;

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS trip_copies_used integer NOT NULL DEFAULT 0;

-- Rate-limit ledger for code lookups. RLS on with ZERO policies: only the
-- definer functions (and service role) can touch it.
CREATE TABLE IF NOT EXISTS public.trip_code_lookup_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  attempted_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS trip_code_lookup_attempts_rate_idx
  ON public.trip_code_lookup_attempts (user_id, attempted_at DESC);
ALTER TABLE public.trip_code_lookup_attempts ENABLE ROW LEVEL SECURITY;

-- ── Owner: publish / unpublish ────────────────────────────────────────────
-- Returns the trip's share code (minted on first publish, kept forever so
-- re-publishing restores the same code — least surprise for owners who
-- already shared it).
CREATE OR REPLACE FUNCTION public.set_trip_public(p_trip_id uuid, p_public boolean)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_chars constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  v_code text;
  v_try int := 0;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT share_code INTO v_code
  FROM trips WHERE id = p_trip_id AND user_id = v_user;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  IF p_public AND v_code IS NULL THEN
    LOOP
      v_try := v_try + 1;
      v_code := (
        SELECT string_agg(substr(v_chars, 1 + floor(random() * 31)::int, 1), '')
        FROM generate_series(1, 6)
      );
      BEGIN
        UPDATE trips SET share_code = v_code, is_public = true,
               updated_at = now()
         WHERE id = p_trip_id AND user_id = v_user;
        RETURN v_code;
      EXCEPTION WHEN unique_violation THEN
        IF v_try >= 5 THEN
          RAISE EXCEPTION 'code_generation_failed';
        END IF;
      END;
    END LOOP;
  END IF;

  UPDATE trips SET is_public = p_public, updated_at = now()
   WHERE id = p_trip_id AND user_id = v_user;
  RETURN v_code;
END;
$$;

-- ── Copier: preview by code ───────────────────────────────────────────────
-- Whitelisted snapshot only. NULL for unknown code AND for private trip —
-- indistinguishable on purpose. 10 lookups/hour/user.
CREATE OR REPLACE FUNCTION public.get_public_trip_preview(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_code text;
  v_trip trips%ROWTYPE;
  v_locations jsonb;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  -- Rate limit (and keep the ledger tidy).
  DELETE FROM trip_code_lookup_attempts
   WHERE user_id = v_user AND attempted_at < now() - interval '2 hours';
  IF (SELECT count(*) FROM trip_code_lookup_attempts
       WHERE user_id = v_user AND attempted_at > now() - interval '1 hour') >= 10 THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
  INSERT INTO trip_code_lookup_attempts (user_id) VALUES (v_user);

  -- Accept "TRIP-XXXXXX" or bare "XXXXXX".
  v_code := upper(regexp_replace(trim(p_code), '^TRIP-', '', 'i'));

  SELECT * INTO v_trip FROM trips
   WHERE share_code = v_code AND is_public = true;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'name', l.name,
           'lat', l.lat,
           'lng', l.lng,
           'scheduled_date', l.scheduled_date,
           'scheduled_end_date', l.scheduled_end_date,
           'stay_duration', l.stay_duration,
           'is_accommodation', l.is_accommodation,
           'photo_reference', l.photo_reference,
           'place_id', l.place_id,
           'original_name', l.original_name,
           'google_opening_hours', l.google_opening_hours
         ) ORDER BY l.scheduled_date NULLS LAST, l.created_at), '[]'::jsonb)
    INTO v_locations
  FROM locations l WHERE l.trip_id = v_trip.id;

  RETURN jsonb_build_object(
    'name', v_trip.name,
    'description', v_trip.description,
    'start_date', v_trip.start_date,
    'end_date', v_trip.end_date,
    'country_code', v_trip.country_code,
    'locations', v_locations
  );
END;
$$;

-- ── Copier: duplicate ─────────────────────────────────────────────────────
-- One transaction: fresh trip under the caller, all locations re-anchored
-- to the chosen start date (calendar-day offsets from the source anchor),
-- progress flags reset, copy born PRIVATE. Free users (no active
-- user_subscriptions row — the client's RevenueCat gate runs first, this is
-- the anti-bypass backstop) are limited to one lifetime copy.
CREATE OR REPLACE FUNCTION public.duplicate_public_trip(p_code text, p_start_date date)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_code text;
  v_trip trips%ROWTYPE;
  v_new_id uuid := gen_random_uuid();
  v_anchor date;
  v_span int;
  v_copies int;
  v_is_pro boolean;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;
  IF p_start_date IS NULL THEN
    RAISE EXCEPTION 'bad_request';
  END IF;

  v_code := upper(regexp_replace(trim(p_code), '^TRIP-', '', 'i'));
  -- Re-verified HERE, not at preview: flipping the trip private mid-wizard
  -- kills the confirm.
  SELECT * INTO v_trip FROM trips
   WHERE share_code = v_code AND is_public = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_public';
  END IF;

  -- One lifetime copy for free users; unlimited for subscribers.
  SELECT coalesce(trip_copies_used, 0) INTO v_copies
    FROM user_profiles WHERE user_id = v_user;
  SELECT EXISTS (
    SELECT 1 FROM user_subscriptions
     WHERE user_id = v_user
       AND status = 'active'  -- the webhook's only live status (trials included)
       AND (expires_at IS NULL OR expires_at > now())
  ) INTO v_is_pro;
  IF coalesce(v_copies, 0) >= 1 AND NOT v_is_pro THEN
    RAISE EXCEPTION 'copy_limit';
  END IF;

  -- Anchor for date re-mapping: the source trip's start, else its earliest
  -- scheduled day, else the chosen start (all-null case degenerates to
  -- "everything lands on day 1").
  SELECT coalesce(
           v_trip.start_date::date,
           (SELECT min(scheduled_date)::date FROM locations
             WHERE trip_id = v_trip.id AND scheduled_date IS NOT NULL),
           p_start_date)
    INTO v_anchor;

  -- Preserve the trip's calendar length.
  SELECT coalesce(
           v_trip.end_date::date - v_trip.start_date::date,
           (SELECT max(scheduled_date)::date - min(scheduled_date)::date
              FROM locations
             WHERE trip_id = v_trip.id AND scheduled_date IS NOT NULL),
           0)
    INTO v_span;
  IF v_span < 0 THEN v_span := 0; END IF;

  INSERT INTO trips (id, user_id, name, description, status, is_active,
                     start_date, end_date, country_code,
                     is_public, share_code)
  VALUES (v_new_id, v_user, v_trip.name, v_trip.description, 'planning',
          false, p_start_date, p_start_date + v_span, v_trip.country_code,
          false, NULL);

  INSERT INTO locations (user_id, trip_id, name, lat, lng, fingerprint,
                         is_skipped, is_done, stay_duration, scheduled_date,
                         scheduled_end_date, is_accommodation, source,
                         is_synced, photo_reference, photo_references,
                         photo_attributions, place_id, original_name,
                         google_opening_hours, user_closing_minute_override,
                         hours_last_refreshed_at)
  SELECT v_user, v_new_id, l.name, l.lat, l.lng, l.fingerprint,
         false, false, l.stay_duration,
         CASE WHEN l.scheduled_date IS NULL THEN p_start_date::timestamptz
              ELSE (p_start_date + (l.scheduled_date::date - v_anchor))::timestamptz
         END,
         CASE WHEN l.scheduled_end_date IS NULL THEN NULL
              ELSE (p_start_date + (l.scheduled_end_date::date - v_anchor))::timestamptz
         END,
         l.is_accommodation, 'synced', true, l.photo_reference,
         l.photo_references, l.photo_attributions, l.place_id,
         l.original_name, l.google_opening_hours,
         l.user_closing_minute_override, l.hours_last_refreshed_at
    FROM locations l
   WHERE l.trip_id = v_trip.id;

  UPDATE user_profiles SET trip_copies_used = coalesce(trip_copies_used, 0) + 1
   WHERE user_id = v_user;

  RETURN v_new_id;
END;
$$;

REVOKE ALL ON FUNCTION public.set_trip_public(uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_public_trip_preview(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.duplicate_public_trip(text, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_trip_public(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_trip_preview(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.duplicate_public_trip(text, date) TO authenticated;
