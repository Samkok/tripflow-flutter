-- Copy-count endorsement: show owners how many people copied their trip.
--
--  • trips.copy_count — denormalized display counter, readable by the owner
--    through their existing RLS (no new policies needed).
--  • trip_copy_credits — the dedupe ledger: PRIMARY KEY (trip, copier)
--    guarantees one credit per person per trip, no matter how many times
--    they copy it. RLS on with zero policies (definer functions only).
--  • Self-copy is now REJECTED in both preview and duplicate ('own_trip'):
--    your own code is for sharing, and self-copies would farm the counter.

ALTER TABLE public.trips
  ADD COLUMN IF NOT EXISTS copy_count integer NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.trip_copy_credits (
  source_trip_id uuid NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
  copier_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source_trip_id, copier_user_id)
);
ALTER TABLE public.trip_copy_credits ENABLE ROW LEVEL SECURITY;

-- ── preview: reject the owner's own code ─────────────────────────────────
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

  DELETE FROM trip_code_lookup_attempts
   WHERE user_id = v_user AND attempted_at < now() - interval '2 hours';
  IF (SELECT count(*) FROM trip_code_lookup_attempts
       WHERE user_id = v_user AND attempted_at > now() - interval '1 hour') >= 10 THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
  INSERT INTO trip_code_lookup_attempts (user_id) VALUES (v_user);

  v_code := upper(regexp_replace(trim(p_code), '^TRIP-', '', 'i'));

  SELECT * INTO v_trip FROM trips
   WHERE share_code = v_code AND is_public = true;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Your own code pastes nowhere: it's for OTHER people to copy.
  IF v_trip.user_id = v_user THEN
    RAISE EXCEPTION 'own_trip';
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

-- ── duplicate: self-copy block + one-per-person copy credit ──────────────
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
  SELECT * INTO v_trip FROM trips
   WHERE share_code = v_code AND is_public = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_public';
  END IF;

  IF v_trip.user_id = v_user THEN
    RAISE EXCEPTION 'own_trip';
  END IF;

  SELECT coalesce(trip_copies_used, 0) INTO v_copies
    FROM user_profiles WHERE user_id = v_user;
  SELECT EXISTS (
    SELECT 1 FROM user_subscriptions
     WHERE user_id = v_user
       AND status = 'active'
       AND (expires_at IS NULL OR expires_at > now())
  ) INTO v_is_pro;
  IF coalesce(v_copies, 0) >= 1 AND NOT v_is_pro THEN
    RAISE EXCEPTION 'copy_limit';
  END IF;

  SELECT coalesce(
           v_trip.start_date::date,
           (SELECT min(scheduled_date)::date FROM locations
             WHERE trip_id = v_trip.id AND scheduled_date IS NOT NULL),
           p_start_date)
    INTO v_anchor;

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

  -- Copy credit: exactly one per (trip, person), forever — repeat copies by
  -- the same person don't inflate the owner's endorsement count.
  INSERT INTO trip_copy_credits (source_trip_id, copier_user_id)
  VALUES (v_trip.id, v_user)
  ON CONFLICT DO NOTHING;
  IF FOUND THEN
    UPDATE trips SET copy_count = copy_count + 1 WHERE id = v_trip.id;
  END IF;

  RETURN v_new_id;
END;
$$;
