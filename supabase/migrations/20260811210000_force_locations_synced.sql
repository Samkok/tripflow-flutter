-- ─────────────────────────────────────────────────────────────────────────
-- Kill switch for the old-client "stale re-upload" loop in shared trips.
--
-- `locations.is_synced` is a DEVICE-LOCAL dirty flag that old app builds
-- round-trip through the server: their upserts write `is_synced = false`,
-- and their `fromJson` trusts the column on the way back in — so every row
-- they ever fetch lands in the device cache marked "pending local edit".
-- From there the old build (a) skips the server copy on refresh, never
-- seeing collaborators' changes, and (b) re-uploads its stale snapshot on
-- every launch, overwriting collaborators' newer edits (the "my date move
-- reverted itself" bug).
--
-- New builds ignore the column entirely (client fix, Aug 2026). This
-- migration breaks the loop for every OLD build still in the wild:
--   • trigger: any insert/update stores `is_synced = true`, so the poison
--     can never re-enter the table;
--   • backfill: existing rows flip to true, so old clients' fetches start
--     returning clean rows immediately.
-- Old builds self-heal after at most one more stale push: that push
-- succeeds → their local rows flip clean → subsequent fetches (now always
-- `true`) keep them clean → the re-upload loop ends.
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.force_locations_synced()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.is_synced := true;
  return new;
end;
$$;

drop trigger if exists locations_force_synced on public.locations;
create trigger locations_force_synced
  before insert or update on public.locations
  for each row execute function public.force_locations_synced();

-- Backfill: flip every poisoned row. (Fires the trigger too — harmless.)
update public.locations set is_synced = true where is_synced is distinct from true;
