-- "Carry unvisited places forward" — ONE heads-up per member per run.
--
-- When the owner's app moves the stops left unvisited on past days to
-- today (trips.auto_roll_unvisited, see 20260912120000), the other members
-- should hear about it once: "3 places from yesterday moved to today in
-- 'Vietnam'" — never one push per moved stop. The move itself is a batch
-- UPDATE on locations, which no trigger announces (on_location_added is
-- INSERT-only), so the owner's app calls this after the batch.
--
-- Rules:
--   * caller must be the trip's owner (the setting is theirs);
--   * one notifications row per collaborator — the caller is never told,
--     and pending invites (no user_id yet) are skipped;
--   * a member already told about this trip's move for this day is not
--     told twice (second owner device, retried call) — the (trip, to_date)
--     pair in `data` is the idempotency key;
--   * the wording mirrors rolloverFromLabel()/rolloverMessage() in the
--     app: "yesterday" when every moved stop came from the day before,
--     that day's short date ("Sep 9") when they all share one other day,
--     "earlier days" otherwise. Dates are plain calendar days as the owner
--     sees them; the server does no timezone math.
CREATE OR REPLACE FUNCTION public.notify_trip_rollover(
  p_trip_id uuid,
  p_moved integer,
  p_from_dates date[],
  p_to_date date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_trip_name text;
  v_days date[];
  v_from text;
  v_moved integer;
  v_body text;
  v_data jsonb;
  v_sent integer := 0;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;
  IF p_moved IS NULL OR p_moved < 1 OR p_to_date IS NULL THEN
    RETURN 0;
  END IF;

  SELECT name INTO v_trip_name
    FROM trips WHERE id = p_trip_id AND user_id = v_user;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  v_moved := LEAST(p_moved, 500);

  SELECT array_agg(DISTINCT d ORDER BY d) INTO v_days
    FROM unnest(COALESCE(p_from_dates, '{}'::date[])) AS d
   WHERE d IS NOT NULL;
  IF v_days IS NULL OR cardinality(v_days) <> 1 THEN
    v_from := 'earlier days';
  ELSIF v_days[1] = p_to_date - 1 THEN
    v_from := 'yesterday';
  ELSE
    v_from := to_char(v_days[1], 'Mon FMDD');
  END IF;

  v_body := v_moved::text
    || CASE WHEN v_moved = 1 THEN ' place' ELSE ' places' END
    || ' from ' || v_from || ' moved to today in "'
    || COALESCE(v_trip_name, 'your trip') || '"';

  v_data := jsonb_build_object(
    'trip_id', p_trip_id::text,
    'moved', v_moved,
    'to_date', to_char(p_to_date, 'YYYY-MM-DD')
  );

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT DISTINCT c.user_id, 'trip_rollover', 'Plan carried forward', v_body, v_data
    FROM trip_collaborators c
   WHERE c.trip_id = p_trip_id
     AND c.user_id IS NOT NULL
     AND c.user_id <> v_user
     AND NOT EXISTS (
           SELECT 1 FROM notifications n
            WHERE n.user_id = c.user_id
              AND n.type = 'trip_rollover'
              AND n.data->>'trip_id' = p_trip_id::text
              AND n.data->>'to_date' = to_char(p_to_date, 'YYYY-MM-DD')
         );
  GET DIAGNOSTICS v_sent = ROW_COUNT;
  RETURN v_sent;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_trip_rollover(uuid, integer, date[], date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_trip_rollover(uuid, integer, date[], date) TO authenticated;

COMMENT ON FUNCTION public.notify_trip_rollover(uuid, integer, date[], date) IS
  'Owner-only: one "N places from <day> moved to today" push per collaborator after a carry-forward run; idempotent per (trip, day).';
