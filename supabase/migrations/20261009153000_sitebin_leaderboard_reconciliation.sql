begin;

-- Recalculate leaderboard buckets from the authoritative completed sessions.
-- Locks are taken in sorted order by the trigger so concurrent completions or
-- reassignments for overlapping user/day/week buckets cannot overwrite counts.

create or replace function private.reconcile_view_leaderboard_entry(
  p_user_id uuid,
  p_completed_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_handle text;
  v_day date;
  v_week_start date;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_week_start_at timestamptz;
  v_week_end_at timestamptz;
  v_daily_count integer;
  v_weekly_count integer;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if p_user_id is null or p_completed_at is null then
    return;
  end if;

  v_day := (p_completed_at at time zone 'UTC')::date;
  v_week_start := pg_catalog.date_trunc('week', p_completed_at at time zone 'UTC')::date;
  v_day_start := v_day::timestamp at time zone 'UTC';
  v_day_end := (v_day + 1)::timestamp at time zone 'UTC';
  v_week_start_at := v_week_start::timestamp at time zone 'UTC';
  v_week_end_at := (v_week_start + 7)::timestamp at time zone 'UTC';

  select p.user_handle
    into v_handle
  from public.profiles p
  where p.id = p_user_id;

  if v_handle is null or pg_catalog.btrim(v_handle) = '' then
    delete from public.daily_view_leaderboard d
    where d.leaderboard_date = v_day and d.user_id = p_user_id;
    delete from public.weekly_view_leaderboard w
    where w.week_start = v_week_start and w.user_id = p_user_id;
    return;
  end if;

  select pg_catalog.count(*)::integer
    into v_daily_count
  from public.view_sessions vs
  where vs.viewer_id = p_user_id
    and vs.status = 'COMPLETED'
    and vs.completed_at >= v_day_start
    and vs.completed_at < v_day_end;

  if v_daily_count > 0 then
    insert into public.daily_view_leaderboard (
      leaderboard_date, user_id, user_handle, completed_views, updated_at
    )
    values (v_day, p_user_id, v_handle, v_daily_count, v_now)
    on conflict (leaderboard_date, user_id) do update
      set user_handle = excluded.user_handle,
          completed_views = excluded.completed_views,
          updated_at = excluded.updated_at;
  else
    delete from public.daily_view_leaderboard d
    where d.leaderboard_date = v_day and d.user_id = p_user_id;
  end if;

  select pg_catalog.count(*)::integer
    into v_weekly_count
  from public.view_sessions vs
  where vs.viewer_id = p_user_id
    and vs.status = 'COMPLETED'
    and vs.completed_at >= v_week_start_at
    and vs.completed_at < v_week_end_at;

  if v_weekly_count > 0 then
    insert into public.weekly_view_leaderboard (
      week_start, user_id, user_handle, completed_views, updated_at
    )
    values (v_week_start, p_user_id, v_handle, v_weekly_count, v_now)
    on conflict (week_start, user_id) do update
      set user_handle = excluded.user_handle,
          completed_views = excluded.completed_views,
          updated_at = excluded.updated_at;
  else
    delete from public.weekly_view_leaderboard w
    where w.week_start = v_week_start and w.user_id = p_user_id;
  end if;
end;
$function$;

revoke all on function private.reconcile_view_leaderboard_entry(uuid, timestamptz)
  from public, anon, authenticated;

create or replace function private.reconcile_view_leaderboards()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_lock_keys bigint[] := array[]::bigint[];
  v_lock_key bigint;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if old.status = 'COMPLETED'
       and old.completed_at is not null
       and old.viewer_id is not null then
      v_lock_keys := pg_catalog.array_append(
        v_lock_keys,
        pg_catalog.hashtextextended(
          'sitebin:daily:' || old.viewer_id::text || ':' ||
            ((old.completed_at at time zone 'UTC')::date)::text,
          0
        )
      );
      v_lock_keys := pg_catalog.array_append(
        v_lock_keys,
        pg_catalog.hashtextextended(
          'sitebin:weekly:' || old.viewer_id::text || ':' ||
            pg_catalog.date_trunc('week', old.completed_at at time zone 'UTC')::date::text,
          0
        )
      );
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    if new.status = 'COMPLETED'
       and new.completed_at is not null
       and new.viewer_id is not null then
      v_lock_keys := pg_catalog.array_append(
        v_lock_keys,
        pg_catalog.hashtextextended(
          'sitebin:daily:' || new.viewer_id::text || ':' ||
            ((new.completed_at at time zone 'UTC')::date)::text,
          0
        )
      );
      v_lock_keys := pg_catalog.array_append(
        v_lock_keys,
        pg_catalog.hashtextextended(
          'sitebin:weekly:' || new.viewer_id::text || ':' ||
            pg_catalog.date_trunc('week', new.completed_at at time zone 'UTC')::date::text,
          0
        )
      );
    end if;
  end if;

  -- Every transaction acquires all affected bucket locks in the same order.
  for v_lock_key in
    select distinct lock_key
    from pg_catalog.unnest(v_lock_keys) as affected(lock_key)
    order by lock_key
  loop
    perform pg_catalog.pg_advisory_xact_lock(v_lock_key);
  end loop;

  if tg_op in ('UPDATE', 'DELETE') then
    if old.status = 'COMPLETED' and old.completed_at is not null then
      perform private.reconcile_view_leaderboard_entry(old.viewer_id, old.completed_at);
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    if new.status = 'COMPLETED' and new.completed_at is not null then
      perform private.reconcile_view_leaderboard_entry(new.viewer_id, new.completed_at);
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

revoke all on function private.reconcile_view_leaderboards()
  from public, anon, authenticated;

drop trigger if exists trg_record_daily_view_leaderboard on public.view_sessions;
drop trigger if exists trg_record_weekly_view_leaderboard on public.view_sessions;
drop trigger if exists trg_reconcile_view_leaderboards_write on public.view_sessions;
drop trigger if exists trg_reconcile_view_leaderboards_update on public.view_sessions;

create trigger trg_reconcile_view_leaderboards_write
after insert or delete on public.view_sessions
for each row execute function private.reconcile_view_leaderboards();

create trigger trg_reconcile_view_leaderboards_update
after update of status, viewer_id, completed_at on public.view_sessions
for each row execute function private.reconcile_view_leaderboards();

-- Correct historical/current daily buckets against the source rows.
insert into public.daily_view_leaderboard (
  leaderboard_date, user_id, user_handle, completed_views, updated_at
)
select
  (vs.completed_at at time zone 'UTC')::date,
  vs.viewer_id,
  pg_catalog.max(p.user_handle),
  pg_catalog.count(*)::integer,
  pg_catalog.clock_timestamp()
from public.view_sessions vs
join public.profiles p on p.id = vs.viewer_id
where vs.status = 'COMPLETED'
  and vs.completed_at is not null
  and pg_catalog.btrim(p.user_handle) <> ''
group by (vs.completed_at at time zone 'UTC')::date, vs.viewer_id
on conflict (leaderboard_date, user_id) do update
set user_handle = excluded.user_handle,
    completed_views = excluded.completed_views,
    updated_at = excluded.updated_at;

delete from public.daily_view_leaderboard d
where not exists (
  select 1
  from public.view_sessions vs
  join public.profiles p on p.id = vs.viewer_id
  where vs.viewer_id = d.user_id
    and vs.status = 'COMPLETED'
    and vs.completed_at is not null
    and (vs.completed_at at time zone 'UTC')::date = d.leaderboard_date
    and pg_catalog.btrim(p.user_handle) <> ''
);

-- Correct historical/current weekly buckets against the source rows.
insert into public.weekly_view_leaderboard (
  week_start, user_id, user_handle, completed_views, updated_at
)
select
  pg_catalog.date_trunc('week', vs.completed_at at time zone 'UTC')::date,
  vs.viewer_id,
  pg_catalog.max(p.user_handle),
  pg_catalog.count(*)::integer,
  pg_catalog.clock_timestamp()
from public.view_sessions vs
join public.profiles p on p.id = vs.viewer_id
where vs.status = 'COMPLETED'
  and vs.completed_at is not null
  and pg_catalog.btrim(p.user_handle) <> ''
group by pg_catalog.date_trunc('week', vs.completed_at at time zone 'UTC')::date, vs.viewer_id
on conflict (week_start, user_id) do update
set user_handle = excluded.user_handle,
    completed_views = excluded.completed_views,
    updated_at = excluded.updated_at;

delete from public.weekly_view_leaderboard w
where not exists (
  select 1
  from public.view_sessions vs
  join public.profiles p on p.id = vs.viewer_id
  where vs.viewer_id = w.user_id
    and vs.status = 'COMPLETED'
    and vs.completed_at is not null
    and pg_catalog.date_trunc('week', vs.completed_at at time zone 'UTC')::date = w.week_start
    and pg_catalog.btrim(p.user_handle) <> ''
);

commit;
