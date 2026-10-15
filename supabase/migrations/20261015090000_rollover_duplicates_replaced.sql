-- Carry-forward: a leftover ALWAYS moves to today; when the same place is
-- already planned today, the moved row REPLACES that copy.
--
-- The hourly job (20261012090000) moves not-done, not-skipped places from
-- past days to the trip's local today. Its first version left a leftover
-- where it was when the place was already on today, to avoid planning a
-- place twice — which looked like the job had missed it: on Oct 14 "Hong
-- Kong Disneyland" sat open after the run because a second "Hong Kong
-- Disneyland" (same Google place id) was already on Oct 15.
--
-- The rule now (Sam, 2026-10-15: "always move; if duplicate, replace"):
--   * the leftover moves to today;
--   * an OPEN copy of the same place already on today (not done, not
--     skipped, not a stay, single-day) is deleted — the moved row takes
--     its place, so today still plans the place once;
--   * when today's copy is already decided (done, skipped, or a stay that
--     spans today), it is the plan and the leftover is deleted instead —
--     a visit that happened, or a choice already made, is never replaced
--     by an open stop from an earlier day;
--   * two leftovers of one place from different past days: the older
--     moves first, the newer replaces it, as it would any other open copy.
-- Deletes are plain row deletes (nothing references locations; clients
-- drop the row on the realtime DELETE event). Notifications count moves,
-- as before. The app's own planner for guest trips
-- (lib/utils/rollover_planner.dart) applies the same rule.

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
  v_match_ids uuid[];
  v_decided boolean;
begin
  -- Overlapping runs (a slow hour) must not race on the same rows.
  if not pg_try_advisory_xact_lock(hashtext('run_trip_rollover')) then
    return 0;
  end if;

  -- Today's rows for the trip being processed. `open` = replaceable: an
  -- ordinary single-day stop not yet done or skipped.
  create temp table if not exists rollover_occupants (
    id uuid,
    place_id text,
    nm text,
    nn text,
    lat double precision,
    lng double precision,
    open boolean
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
    insert into rollover_occupants (id, place_id, nm, nn, lat, lng, open)
    select l.id, l.place_id, lower(btrim(l.name)), public.rollover_norm_name(l.name),
           l.lat, l.lng,
           (not l.is_done
            and not coalesce(l.is_skipped, false)
            and not l.is_accommodation
            and (l.scheduled_end_date is null
                 or (l.scheduled_end_date at time zone 'UTC')::date
                    <= (l.scheduled_date at time zone 'UTC')::date))
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
      -- Same place already on today? (same place id, same name at the same
      -- point, or the same normalized name within 1 km)
      select coalesce(array_agg(o.id), '{}'::uuid[]),
             coalesce(bool_or(not o.open), false)
        into v_match_ids, v_decided
        from rollover_occupants o
       where (cand.place_id is not null and cand.place_id <> ''
              and o.place_id = cand.place_id)
          or (o.nm = lower(btrim(cand.name))
              and abs(o.lat - cand.lat) < 1e-6 and abs(o.lng - cand.lng) < 1e-6)
          or (o.nn <> '' and o.nn = public.rollover_norm_name(cand.name)
              and 2 * 6371000 * asin(sqrt(
                    power(sin(radians(o.lat - cand.lat) / 2), 2)
                    + cos(radians(cand.lat)) * cos(radians(o.lat))
                      * power(sin(radians(o.lng - cand.lng) / 2), 2))) <= 1000);

      if cardinality(v_match_ids) > 0 then
        if v_decided then
          -- Today's copy is done, skipped or a stay: it stays the plan,
          -- the leftover goes.
          delete from locations where id = cand.id;
          continue;
        end if;
        -- Open copies on today are replaced by the moved row.
        delete from locations where id = any(v_match_ids);
        delete from rollover_occupants where id = any(v_match_ids);
      end if;

      update locations
         set scheduled_date = (v_local_today::timestamp) at time zone 'UTC',
             scheduled_end_date = null
       where id = cand.id;

      insert into rollover_occupants (id, place_id, nm, nn, lat, lng, open)
      values (cand.id, cand.place_id, lower(btrim(cand.name)),
              public.rollover_norm_name(cand.name), cand.lat, cand.lng, true);
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
  'Hourly job: moves not-done, not-skipped places from past days to today for trips with auto_roll_unvisited, using each trip''s estimated local date; an open copy of the same place already on today is replaced by the moved row (a done/skipped copy wins and the leftover is deleted); notifies members and the owner once per day.';
