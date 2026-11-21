begin;

create or replace view public.weekly_view_leaderboard_public
with (security_invoker = false)
as
with bounds as (
  select
    pg_catalog.date_trunc(
      'week',
      pg_catalog.statement_timestamp() at time zone 'UTC'
    )::date as week_start,
    pg_catalog.statement_timestamp() as as_of
),
user_counts as (
  select
    vs.viewer_id,
    p.user_handle,
    pg_catalog.count(*)::integer as completed_views,
    pg_catalog.max(vs.completed_at) as updated_at
  from public.view_sessions vs
  join public.profiles p
    on p.id = vs.viewer_id
  cross join bounds b
  where vs.status = 'COMPLETED'
    and vs.completed_at >= b.as_of - interval '30 days'
    and vs.completed_at < b.as_of
    and pg_catalog.btrim(p.user_handle) <> ''
  group by vs.viewer_id, p.user_handle
)
select
  b.week_start,
  pg_catalog.row_number() over (
    order by uc.completed_views desc, uc.user_handle asc
  )::integer as rank,
  uc.user_handle,
  uc.completed_views,
  uc.updated_at
from user_counts uc
cross join bounds b;

comment on view public.weekly_view_leaderboard_public is
  'Backward-compatible Android leaderboard endpoint. Returns rolling last-30-days completed view counts. The underlying weekly_view_leaderboard table and weekly featured-campaign logic remain weekly. week_start is the current UTC week start only as a client compatibility filter.';

revoke all on public.weekly_view_leaderboard_public from public, anon;
grant select on public.weekly_view_leaderboard_public to authenticated;

commit;