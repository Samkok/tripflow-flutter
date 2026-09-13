-- Place tags: every stop can carry one of a FIXED set of tags (food,
-- sights, culture, nature, shopping, nightlife, transport, stay); the
-- single-day map paints the pin in the tag's colour and lists the colours
-- in a small legend. `place_types` keeps Google's place-type list from the
-- moment the stop was added, so a tag can be re-suggested later without
-- another Places call.
--
-- Both columns are nullable: rows written before this migration are simply
-- untagged. Copies by code (duplicate_public_trip) carry both along —
-- statuses still reset to active, as before.

ALTER TABLE public.locations
  ADD COLUMN IF NOT EXISTS tag text NULL,
  ADD COLUMN IF NOT EXISTS place_types text[] NULL;

ALTER TABLE public.locations DROP CONSTRAINT IF EXISTS locations_tag_known;
ALTER TABLE public.locations ADD CONSTRAINT locations_tag_known
  CHECK (tag IS NULL OR tag IN (
    'food', 'sights', 'culture', 'nature', 'shopping', 'nightlife',
    'transport', 'stay'));

COMMENT ON COLUMN public.locations.tag IS
  'Fixed-set place tag (food|sights|culture|nature|shopping|nightlife|transport|stay); the day map colours the pin by it.';
COMMENT ON COLUMN public.locations.place_types IS
  'Google place types captured when the stop was added; feeds the tag suggestion.';

-- duplicate_public_trip: identical to 20260807120000 except that the copied
-- rows keep the source stop's tag and place_types.
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
                         hours_last_refreshed_at, tag, place_types)
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
         l.user_closing_minute_override, l.hours_last_refreshed_at,
         l.tag, l.place_types
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
