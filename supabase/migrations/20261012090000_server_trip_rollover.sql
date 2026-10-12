-- "Carry unvisited places forward" — done by the server, hourly.
--
-- Until now the move (stops left not done and not skipped on past days go
-- to today; see 20260912120000 for the trips.auto_roll_unvisited setting
-- and lib/utils/rollover_planner.dart for the rule) ran only on the
-- OWNER's device, when the owner opened the app. Members looked at a plan
-- stuck on yesterday until then. This migration moves the decision to the
-- database so it happens whether or not anyone opens the app; the app's own
-- run is kept for guests only, whose trips never reach the server.
--
-- What "today" means without a timezone. Days are stored as midnight UTC
-- (the calendar day the owner saw), and nothing records where a trip is in
-- the world. The job estimates each trip's local clock from the median
-- longitude of its dated places (15° = 1 h) and takes ONE hour off as a
-- margin. Civil time nearly everywhere runs ahead of the sun (the margin
-- covers the rare places behind it), so the estimate never reaches a new
-- date before the traveller does; it reaches it one to three hours after
-- local midnight, before anyone is up. Running hourly also heals the case
-- of a device that pushes a stale copy of a moved row back.
--
-- The rule is the planner's, as closely as SQL allows:
--   * trip has the setting on, has dates, is not undated (2100 anchor),
--     and local-today falls within its dates;
--   * a row moves when its day is before local-today and it is not done,
--     not skipped, not an accommodation and not a multi-day stay;
--   * a row whose place is already planned on local-today — same place id,
--     same name at the same point, or the same normalized name within
--     1 km — stays where it is, and two such leftovers move only once;
--   * moved rows land on local-today with no end date (single-day by
--     definition, which also keeps the end-after-start check satisfied).
--
-- Notice: one "N places from <day> moved to today in «trip»" push per
-- member AND the owner (the owner's heads-up used to be the app's toast),
-- idempotent per (trip, day), with the wording of the existing RPC. That
-- RPC stays for the app's "switch it on now" path and shares the helper.

-- ── 1. Notification helper shared by the RPC and the job ──────────────────
create or replace function public.notify_trip_rollover_internal(
  p_trip_id uuid,
  p_owner uuid,
  p_moved integer,
  p_from_dates date[],
  p_to_date date,
  p_include_owner boolean
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_name text;
  v_days date[];
  v_from text;
  v_moved integer;
  v_body text;
  v_data jsonb;
  v_sent integer := 0;
begin
  if p_moved is null or p_moved < 1 or p_to_date is null then
    return 0;
  end if;
  select name into v_trip_name from trips where id = p_trip_id;
  if not found then
    return 0;
  end if;

  v_moved := least(p_moved, 500);

  select array_agg(distinct d order by d) into v_days
    from unnest(coalesce(p_from_dates, '{}'::date[])) as d
   where d is not null;
  if v_days is null or cardinality(v_days) <> 1 then
    v_from := 'earlier days';
  elsif v_days[1] = p_to_date - 1 then
    v_from := 'yesterday';
  else
    v_from := to_char(v_days[1], 'Mon FMDD');
  end if;

  v_body := v_moved::text
    || case when v_moved = 1 then ' place' else ' places' end
    || ' from ' || v_from || ' moved to today in "'
    || coalesce(v_trip_name, 'your trip') || '"';

  v_data := jsonb_build_object(
    'trip_id', p_trip_id::text,
    'moved', v_moved,
    'to_date', to_char(p_to_date, 'YYYY-MM-DD')
  );

  insert into notifications (user_id, type, title, body, data)
  select distinct r.user_id, 'trip_rollover', 'Plan carried forward', v_body, v_data
    from (
      select c.user_id
        from trip_collaborators c
       where c.trip_id = p_trip_id and c.user_id is not null
      union
      select p_owner where p_include_owner and p_owner is not null
    ) r
   where (p_include_owner or r.user_id <> p_owner)
     and not exists (
           select 1 from notifications n
            where n.user_id = r.user_id
              and n.type = 'trip_rollover'
              and n.data->>'trip_id' = p_trip_id::text
              and n.data->>'to_date' = to_char(p_to_date, 'YYYY-MM-DD')
         );
  get diagnostics v_sent = row_count;
  return v_sent;
end;
$$;

revoke all on function public.notify_trip_rollover_internal(uuid, uuid, integer, date[], date, boolean)
  from public, anon, authenticated;

comment on function public.notify_trip_rollover_internal(uuid, uuid, integer, date[], date, boolean) is
  'Internal: the carry-forward heads-up to members (and the owner when asked); idempotent per (trip, day). No auth check — callers decide.';

-- The owner's RPC keeps its contract (auth + owner check, members only) and
-- now shares the body above.
create or replace function public.notify_trip_rollover(
  p_trip_id uuid,
  p_moved integer,
  p_from_dates date[],
  p_to_date date
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not_authenticated';
  end if;
  if not exists (select 1 from trips where id = p_trip_id and user_id = v_user) then
    raise exception 'not_owner';
  end if;
  return public.notify_trip_rollover_internal(
    p_trip_id, v_user, p_moved, p_from_dates, p_to_date, false);
end;
$$;

-- ── 2. Name normalization for the "same place" rule ───────────────────────
-- Lower case, anything that is not a letter or digit becomes a space,
-- runs of spaces collapse. (The app also folds accents; without unaccent
-- here, an accented and an unaccented spelling of one name may both stay —
-- a harmless duplicate, never a lost place.)
create or replace function public.rollover_norm_name(p_name text)
returns text
language sql
immutable
as $$
  select btrim(regexp_replace(lower(coalesce(p_name, '')), '[^[:alnum:]]+', ' ', 'g'));
$$;

-- ── 3. The job ────────────────────────────────────────────────────────────
create or replace function public.run_trip_rollover()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  t record;
  cand record;
  v_offset_minutes integer;
  v_local_today date;
  v_moved integer;
  v_from date[];
  v_total integer := 0;
begin
  -- Overlapping runs (a slow hour) must not race on the same rows.
  if not pg_try_advisory_xact_lock(hashtext('run_trip_rollover')) then
    return 0;
  end if;

  create temp table if not exists rollover_occupants (
    place_id text,
    nm text,
    nn text,
    lat double precision,
    lng double precision
  ) on commit drop;

  for t in
    select tr.id, tr.user_id,
           (tr.start_date at time zone 'UTC')::date as start_day,
           (tr.end_date at time zone 'UTC')::date as end_day,
           (select percentile_cont(0.5) within group (order by l.lng)
              from locations l
             where l.trip_id = tr.id and l.scheduled_date is not null) as median_lng
      from trips tr
     where tr.auto_roll_unvisited
       and not tr.dates_tbd
       and tr.start_date is not null
       and tr.end_date is not null
       and (tr.start_date at time zone 'UTC')::date < date '2100-01-01'
  loop
    if t.median_lng is null then
      continue; -- no dated places: nothing to move, and no clock to estimate
    end if;
    -- Solar offset from the median longitude, minus one hour of margin.
    v_offset_minutes := round(t.median_lng * 4)::integer - 60;
    v_local_today :=
      ((now() at time zone 'UTC') + make_interval(mins => v_offset_minutes))::date;
    if v_local_today < t.start_day or v_local_today > t.end_day then
      continue; -- not ongoing by the trip's own clock
    end if;

    truncate rollover_occupants;
    insert into rollover_occupants (place_id, nm, nn, lat, lng)
    select l.place_id, lower(btrim(l.name)), public.rollover_norm_name(l.name), l.lat, l.lng
      from locations l
     where l.trip_id = t.id
       and l.scheduled_date is not null
       and (l.scheduled_date at time zone 'UTC')::date <= v_local_today
       and coalesce((l.scheduled_end_date at time zone 'UTC')::date,
                    (l.scheduled_date at time zone 'UTC')::date) >= v_local_today;

    v_moved := 0;
    v_from := '{}'::date[];
    for cand in
      select l.id, l.place_id, l.name, l.lat, l.lng,
             (l.scheduled_date at time zone 'UTC')::date as day
        from locations l
       where l.trip_id = t.id
         and l.scheduled_date is not null
         and (l.scheduled_date at time zone 'UTC')::date < v_local_today
         and not l.is_done
         and not coalesce(l.is_skipped, false)
         and not l.is_accommodation
         and (l.scheduled_end_date is null
              or (l.scheduled_end_date at time zone 'UTC')::date
                 <= (l.scheduled_date at time zone 'UTC')::date)
       order by l.scheduled_date, l.created_at, l.id
    loop
      if exists (
        select 1 from rollover_occupants o
         where (cand.place_id is not null and cand.place_id <> ''
                and o.place_id = cand.place_id)
            or (o.nm = lower(btrim(cand.name))
                and abs(o.lat - cand.lat) < 1e-6 and abs(o.lng - cand.lng) < 1e-6)
            or (o.nn <> '' and o.nn = public.rollover_norm_name(cand.name)
                and 2 * 6371000 * asin(sqrt(
                      power(sin(radians(o.lat - cand.lat) / 2), 2)
                      + cos(radians(cand.lat)) * cos(radians(o.lat))
                        * power(sin(radians(o.lng - cand.lng) / 2), 2))) <= 1000)
      ) then
        continue; -- already planned today: left where it is
      end if;

      update locations
         set scheduled_date = (v_local_today::timestamp) at time zone 'UTC',
             scheduled_end_date = null
       where id = cand.id;

      insert into rollover_occupants (place_id, nm, nn, lat, lng)
      values (cand.place_id, lower(btrim(cand.name)),
              public.rollover_norm_name(cand.name), cand.lat, cand.lng);
      v_moved := v_moved + 1;
      v_from := array_append(v_from, cand.day);
    end loop;

    if v_moved > 0 then
      perform public.notify_trip_rollover_internal(
        t.id, t.user_id, v_moved, v_from, v_local_today, true);
      v_total := v_total + v_moved;
    end if;
  end loop;

  return v_total;
end;
$$;

revoke all on function public.run_trip_rollover() from public, anon, authenticated;

comment on function public.run_trip_rollover() is
  'Hourly job: moves not-done, not-skipped places from past days to today for trips with auto_roll_unvisited, using each trip''s estimated local date; notifies members and the owner once per day.';

-- ── 4. Schedule: every hour, seven minutes past ───────────────────────────
do $$
begin
  perform cron.unschedule('trip-rollover-hourly');
exception when others then
  null;
end;
$$;

select cron.schedule(
  'trip-rollover-hourly',
  '7 * * * *',
  $$ select public.run_trip_rollover(); $$
);
