-- "Carry unvisited places forward": a per-trip, owner-controlled switch.
--
-- While the trip is ongoing, every stop left ACTIVE (not done, not skipped)
-- on a day that has passed is moved to today by the owner's app, so the
-- plan follows the traveller instead of piling up behind them. The move
-- itself is a normal locations UPDATE (synced to every member); this
-- column only remembers the choice. Off by default.
alter table public.trips
  add column if not exists auto_roll_unvisited boolean not null default false;

comment on column public.trips.auto_roll_unvisited is
  'Owner setting: move unvisited (active) stops from past days to today while the trip is ongoing.';
