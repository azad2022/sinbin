begin;

create table if not exists public.weekly_view_leaderboard (
  week_start date not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  user_handle text not null,
  completed_views integer not null default 0 check (completed_views > 0),
  updated_at timestamptz not null default now(),
  primary key (week_start, user_id)
);

alter table public.weekly_view_leaderboard enable row level security;
revoke all on public.weekly_view_leaderboard from public, anon, authenticated;
grant select (week_start, user_handle, completed_views, updated_at) on public.weekly_view_leaderboard to authenticated;

drop policy if exists "Authenticated users can read weekly leaderboard" on public.weekly_view_leaderboard;
create policy "Authenticated users can read weekly leaderboard"
  on public.weekly_view_leaderboard
  for select to authenticated using (true);

create index if not exists idx_weekly_view_leaderboard_week_rank
  on public.weekly_view_leaderboard (week_start, completed_views desc, user_handle asc);
create index if not exists idx_weekly_view_leaderboard_user_id
  on public.weekly_view_leaderboard (user_id);

create or replace view public.weekly_view_leaderboard_public
with (security_invoker = true)
as
select
  week_start,
  row_number() over (partition by week_start order by completed_views desc, user_handle asc)::integer as rank,
  user_handle,
  completed_views,
  updated_at
from public.weekly_view_leaderboard;

revoke all on public.weekly_view_leaderboard_public from public, anon;
grant select on public.weekly_view_leaderboard_public to authenticated;

create or replace function private.record_weekly_view_leaderboard()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_handle text; v_week_start date;
begin
  if new.status <> 'COMPLETED' or old.status = 'COMPLETED' or new.completed_at is null or new.viewer_id is null then return new; end if;
  select p.user_handle into v_handle from public.profiles p where p.id = new.viewer_id;
  if v_handle is null or btrim(v_handle) = '' then return new; end if;
  v_week_start := pg_catalog.date_trunc('week', new.completed_at at time zone 'UTC')::date;
  insert into public.weekly_view_leaderboard (week_start,user_id,user_handle,completed_views,updated_at)
  values (v_week_start,new.viewer_id,v_handle,1,pg_catalog.clock_timestamp())
  on conflict (week_start,user_id) do update
    set completed_views = public.weekly_view_leaderboard.completed_views + 1,
        user_handle = excluded.user_handle, updated_at = excluded.updated_at;
  return new;
end;
$function$;

revoke all on function private.record_weekly_view_leaderboard() from public, anon, authenticated;
drop trigger if exists trg_record_weekly_view_leaderboard on public.view_sessions;
create trigger trg_record_weekly_view_leaderboard
after update of status on public.view_sessions
for each row
when (new.status = 'COMPLETED' and old.status is distinct from 'COMPLETED')
execute function private.record_weekly_view_leaderboard();

insert into public.weekly_view_leaderboard (week_start,user_id,user_handle,completed_views,updated_at)
select pg_catalog.date_trunc('week',vs.completed_at at time zone 'UTC')::date,
       vs.viewer_id,max(p.user_handle),count(*)::integer,max(vs.completed_at)
from public.view_sessions vs join public.profiles p on p.id=vs.viewer_id
where vs.status='COMPLETED' and vs.completed_at is not null
group by pg_catalog.date_trunc('week',vs.completed_at at time zone 'UTC')::date, vs.viewer_id
on conflict (week_start,user_id) do update set
  user_handle=excluded.user_handle, completed_views=excluded.completed_views, updated_at=excluded.updated_at;

commit;
