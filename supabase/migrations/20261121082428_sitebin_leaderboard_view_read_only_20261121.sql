begin;

revoke all on public.weekly_view_leaderboard_public
from public, anon, authenticated;

grant select on public.weekly_view_leaderboard_public
to authenticated;

commit;