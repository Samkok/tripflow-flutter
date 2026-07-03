-- Let every member of a trip (owner OR collaborator) see the full
-- collaborator list — not just their own row. This matches what the privacy
-- policy already states ("every member of a shared trip can see the email
-- address of every other member") and powers the home-card avatar display.
--
-- A naive self-referencing SELECT policy on trip_collaborators would recurse
-- (evaluating the policy re-queries the same table). We route the membership
-- check through a SECURITY DEFINER helper, which bypasses RLS on its inner
-- reads and breaks the recursion.

CREATE OR REPLACE FUNCTION public.is_trip_member(p_trip_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.trips
     WHERE id = p_trip_id AND user_id = p_user_id
    UNION ALL
    SELECT 1 FROM public.trip_collaborators
     WHERE trip_id = p_trip_id AND user_id = p_user_id
  );
$$;

REVOKE ALL ON FUNCTION public.is_trip_member(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.is_trip_member(uuid, uuid) TO authenticated;

DROP POLICY IF EXISTS "Users can view collaborators for their trips"
  ON public.trip_collaborators;

CREATE POLICY "Users can view collaborators for their trips"
ON public.trip_collaborators
FOR SELECT
USING (public.is_trip_member(trip_collaborators.trip_id, auth.uid()));
