-- The reverse of set_trip_dates(): the owner takes the dates OFF a trip.
-- The plan keeps its shape — Day 1 lands on the undated-trip anchor
-- (2100-01-01, see 20260915090000) and every stop keeps its day offset —
-- and dates_tbd goes back to true, so the app shows "Day 1, Day 2, …"
-- until new dates are set. Same owner check and two-pass move as
-- set_trip_dates(), which does the shifting.
CREATE OR REPLACE FUNCTION public.clear_trip_dates(p_trip_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM set_trip_dates(p_trip_id, DATE '2100-01-01');
  UPDATE trips
     SET dates_tbd = true,
         updated_at = now()
   WHERE id = p_trip_id AND user_id = auth.uid();
END;
$$;

REVOKE ALL ON FUNCTION public.clear_trip_dates(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clear_trip_dates(uuid) TO authenticated;

COMMENT ON FUNCTION public.clear_trip_dates(uuid) IS
  'Owner-only: move the trip and every stop onto the undated anchor (Day 1 = 2100-01-01) and set dates_tbd; the plan keeps its day layout.';
