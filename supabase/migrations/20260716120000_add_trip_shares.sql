-- Public share tokens for read-only trip pages.
--
-- A row here means the trip owner explicitly published a wall-free, read-only
-- view of that trip, served by the `public-trip` edge function (verify_jwt
-- false). The function reads with the service role, so NO public select
-- policy exists — possession of the unguessable token is the capability.
-- Revocation = set revoked_at (the page 404s from then on).

create table if not exists public.trip_shares (
  -- 64 hex chars (~244 bits) — unguessable capability token.
  token text primary key
    default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  trip_id uuid not null references public.trips(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

create index if not exists trip_shares_trip_id_idx
  on public.trip_shares(trip_id);

alter table public.trip_shares enable row level security;

-- Owners manage (create/read/revoke) share links for THEIR trips only.
-- No anon/public policies: the public read path is the edge function.
create policy "owner manages own trip shares"
  on public.trip_shares
  for all
  using (auth.uid() = created_by)
  with check (
    auth.uid() = created_by
    and exists (
      select 1 from public.trips t
      where t.id = trip_id and t.user_id = auth.uid()
    )
  );
