-- Places outlive the member who added them.
--
-- A place inside a trip is controlled by TRIP MEMBERSHIP (RLS), but its
-- `user_id` still names whoever added it. That left two holes:
--
--   1. Account deletion. The app deleted "every location where user_id =
--      me" from the client. A member with write access was therefore allowed
--      to delete the places they had added to SOMEONE ELSE'S trip — they
--      vanished from the owner's plan. And when the member had already left
--      (no access), those rows survived and the final `DELETE FROM
--      auth.users` hit locations_user_id_fkey (NO ACTION): the deletion
--      failed AFTER the app had already wiped the user's trips and profile.
--   2. Leaving / being removed. The places stayed (good) but kept pointing
--      at a user with no access to them, and kept counting against that
--      user's free-place allowance.
--
-- Now: when a member leaves, is removed, or deletes their account, the
-- places they added to another person's trip are HANDED OVER to the trip
-- owner (`user_id` := owner, `handed_over_from` := the original author).
-- Account deletion runs entirely server-side, in one transaction.
--
-- `user_id` also becomes server-owned: clients can no longer change a row's
-- author (a stale device upserting its old copy would otherwise undo a
-- hand-over — or fail outright once the old author's login is gone).

ALTER TABLE public.locations
  ADD COLUMN IF NOT EXISTS handed_over_from uuid NULL;

COMMENT ON COLUMN public.locations.handed_over_from IS
  'Original author when the row was handed to the trip owner (member left, was removed, or deleted their account). No FK on purpose: the author may be gone. Handed-over places do not count against the owner''s free-place allowance.';

-- ── Authorship is server-owned ───────────────────────────────────────────
-- Outside a hand-over, an UPDATE keeps the row's author and hand-over
-- marker whatever the client sent, and an INSERT can't claim a marker.
CREATE OR REPLACE FUNCTION public.locations_guard_author()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF coalesce(current_setting('voyza.location_handover', true), '') = 'on' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.handed_over_from := NULL;
  ELSE
    NEW.user_id := OLD.user_id;
    NEW.handed_over_from := OLD.handed_over_from;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS locations_guard_author ON public.locations;
CREATE TRIGGER locations_guard_author
  BEFORE INSERT OR UPDATE ON public.locations
  FOR EACH ROW EXECUTE FUNCTION public.locations_guard_author();

-- ── Hand-over when a member leaves or is removed ─────────────────────────
-- Fires for every deleted trip_collaborators row. When the TRIP itself is
-- being deleted the trips row is already gone, so this is a no-op there
-- (the places fall back to their authors via locations.trip_id SET NULL).
CREATE OR REPLACE FUNCTION public.hand_over_member_locations()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner uuid;
BEGIN
  SELECT user_id INTO v_owner FROM trips WHERE id = OLD.trip_id;
  IF v_owner IS NULL OR OLD.user_id IS NULL OR v_owner = OLD.user_id THEN
    RETURN OLD;
  END IF;

  PERFORM set_config('voyza.location_handover', 'on', true);
  UPDATE locations
     SET user_id = v_owner,
         handed_over_from = coalesce(handed_over_from, OLD.user_id)
   WHERE trip_id = OLD.trip_id
     AND user_id = OLD.user_id;
  PERFORM set_config('voyza.location_handover', 'off', true);
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS on_collaborator_removed ON public.trip_collaborators;
CREATE TRIGGER on_collaborator_removed
  AFTER DELETE ON public.trip_collaborators
  FOR EACH ROW EXECUTE FUNCTION public.hand_over_member_locations();

-- ── Account deletion, all server-side, one transaction ───────────────────
-- Replaces the old version, which only deleted the login and relied on the
-- app having deleted locations / trips / profile table by table first.
--   1. Places the user added to OTHER people's trips → the trip owner.
--   2. Invitations the user sent into other people's trips → attributed to
--      the trip owner (invited_by is NOT NULL with no ON DELETE action).
--   3. The user's own places: loose ones and those in their own trips.
--   4. Their trips. Collaborator rows cascade; places OTHER members added
--      to those trips fall back to loose places of their authors
--      (locations.trip_id ON DELETE SET NULL) — nobody else's data is
--      destroyed by this user's deletion.
--   5. Profile, then the login; every remaining reference cascades.
-- Any failure rolls the whole thing back: the account is either fully
-- there or fully gone.
CREATE OR REPLACE FUNCTION public.delete_user_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  PERFORM set_config('voyza.location_handover', 'on', true);
  UPDATE locations l
     SET user_id = t.user_id,
         handed_over_from = coalesce(l.handed_over_from, v_uid)
    FROM trips t
   WHERE l.trip_id = t.id
     AND l.user_id = v_uid
     AND t.user_id <> v_uid;
  PERFORM set_config('voyza.location_handover', 'off', true);

  UPDATE trip_collaborators c
     SET invited_by = t.user_id
    FROM trips t
   WHERE c.trip_id = t.id
     AND c.invited_by = v_uid
     AND t.user_id <> v_uid;

  DELETE FROM locations WHERE user_id = v_uid;
  DELETE FROM trips WHERE user_id = v_uid;
  DELETE FROM user_profiles WHERE user_id = v_uid;
  DELETE FROM auth.users WHERE id = v_uid;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_user_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_user_account() TO authenticated;

COMMENT ON FUNCTION public.delete_user_account() IS
  'Deletes the calling user entirely, in one transaction: hands the places they added to other people''s trips to those trip owners, deletes their own places/trips/profile, then the login.';
