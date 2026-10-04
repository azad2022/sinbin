-- SiteBin server-side rate limiting.
--
-- The authoritative limiter is attached to PostgREST as a pre-request
-- function so protected RPC calls are rejected before their business logic
-- executes. Android-side guards remain only a UX/reliability optimization.
--
-- Policy:
--   Global authenticated RPC traffic:
--     8 / 10s, 30 / 1m, 90 / 5m, 300 / 1h
--     cooldowns: 15s, 2m, 10m, 1h
--
--   create_campaign:
--     2 / 10s, 5 / 1m, 10 / 5m, 30 / 1h
--     cooldowns: 30s, 3m, 15m, 1h
--
--   transfer_coins:
--     3 / 10s, 8 / 1m, 20 / 5m, 50 / 1h
--     cooldowns: 30s, 5m, 20m, 1h
--
--   Viewer:
--     request_view_session     4 / 10s, 12 / 1m, 50 / 5m, 240 / 1h
--     signal_content_ready     3 / 10s, 12 / 1m, 60 / 5m, 240 / 1h
--     complete_view_session    3 / 10s, 10 / 1m, 40 / 5m, 200 / 1h
--     cancel_view_session      4 / 10s, 10 / 1m, 30 / 5m, 150 / 1h
--
--   Campaign controls:
--     pause/resume/cancel     3 / 10s, 10 / 1m, 25 / 5m, 100 / 1h
--
--   activate_auto_view:
--     2 / 10s, 4 / 1m, 10 / 5m, 30 / 1h
--
--   init_user_account:
--     3 / 10s, 6 / 1m, 15 / 5m, 30 / 1h

create schema if not exists private;

revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticator;

create table if not exists private.rate_limit_buckets (
    user_id uuid not null,
    action text not null,
    ten_second_started_at timestamptz not null,
    ten_second_count integer not null default 0,
    minute_started_at timestamptz not null,
    minute_count integer not null default 0,
    five_minute_started_at timestamptz not null,
    five_minute_count integer not null default 0,
    hour_started_at timestamptz not null,
    hour_count integer not null default 0,
    blocked_until timestamptz null,
    updated_at timestamptz not null default pg_catalog.clock_timestamp(),
    primary key (user_id, action),
    check (ten_second_count >= 0),
    check (minute_count >= 0),
    check (five_minute_count >= 0),
    check (hour_count >= 0)
);

alter table private.rate_limit_buckets enable row level security;
revoke all on table private.rate_limit_buckets from public, anon, authenticated;

drop policy if exists "Deny direct access to rate limit buckets" on private.rate_limit_buckets;

create policy "Deny direct access to rate limit buckets"
on private.rate_limit_buckets
as restrictive
for all
to public
using (false)
with check (false);

create or replace function private.enforce_user_rate_limit(
    p_user_id uuid,
    p_action text
) returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_now timestamptz := pg_catalog.clock_timestamp();
    v_bucket private.rate_limit_buckets%rowtype;

    v_limit_10s integer;
    v_limit_1m integer;
    v_limit_5m integer;
    v_limit_1h integer;

    v_block_10s integer;
    v_block_1m integer;
    v_block_5m integer;
    v_block_1h integer;

    v_count_10s integer;
    v_count_1m integer;
    v_count_5m integer;
    v_count_1h integer;

    v_block_seconds integer := 0;
    v_retry_after integer := 1;
begin
    if p_user_id is null or p_action is null or pg_catalog.btrim(p_action) = '' then
        return;
    end if;

    case pg_catalog.btrim(p_action)
        when '__GLOBAL__' then
            v_limit_10s := 8;   v_limit_1m := 30; v_limit_5m := 90;  v_limit_1h := 300;
            v_block_10s := 15;  v_block_1m := 120; v_block_5m := 600; v_block_1h := 3600;
        when 'create_campaign' then
            v_limit_10s := 2;   v_limit_1m := 5;  v_limit_5m := 10;  v_limit_1h := 30;
            v_block_10s := 30;  v_block_1m := 180; v_block_5m := 900; v_block_1h := 3600;
        when 'transfer_coins' then
            v_limit_10s := 3;   v_limit_1m := 8;  v_limit_5m := 20;  v_limit_1h := 50;
            v_block_10s := 30;  v_block_1m := 300; v_block_5m := 1200; v_block_1h := 3600;
        when 'request_view_session' then
            v_limit_10s := 4;   v_limit_1m := 12; v_limit_5m := 50;  v_limit_1h := 240;
            v_block_10s := 15;  v_block_1m := 60;  v_block_5m := 600; v_block_1h := 3600;
        when 'signal_content_ready' then
            v_limit_10s := 3;   v_limit_1m := 12; v_limit_5m := 60;  v_limit_1h := 240;
            v_block_10s := 15;  v_block_1m := 60;  v_block_5m := 600; v_block_1h := 3600;
        when 'complete_view_session' then
            v_limit_10s := 3;   v_limit_1m := 10; v_limit_5m := 40;  v_limit_1h := 200;
            v_block_10s := 15;  v_block_1m := 60;  v_block_5m := 600; v_block_1h := 3600;
        when 'cancel_view_session' then
            v_limit_10s := 4;   v_limit_1m := 10; v_limit_5m := 30;  v_limit_1h := 150;
            v_block_10s := 15;  v_block_1m := 60;  v_block_5m := 600; v_block_1h := 3600;
        when 'pause_campaign', 'resume_campaign', 'cancel_campaign' then
            v_limit_10s := 3;   v_limit_1m := 10; v_limit_5m := 25;  v_limit_1h := 100;
            v_block_10s := 20;  v_block_1m := 120; v_block_5m := 600; v_block_1h := 3600;
        when 'activate_auto_view' then
            v_limit_10s := 2;   v_limit_1m := 4;  v_limit_5m := 10;  v_limit_1h := 30;
            v_block_10s := 30;  v_block_1m := 300; v_block_5m := 1200; v_block_1h := 3600;
        when 'init_user_account' then
            v_limit_10s := 3;   v_limit_1m := 6;  v_limit_5m := 15;  v_limit_1h := 30;
            v_block_10s := 20;  v_block_1m := 120; v_block_5m := 600; v_block_1h := 3600;
        else
            v_limit_10s := null;
            v_limit_1m := null;
            v_limit_5m := null;
            v_limit_1h := null;
    end case;

    insert into private.rate_limit_buckets (
        user_id, action,
        ten_second_started_at,
        minute_started_at,
        five_minute_started_at,
        hour_started_at
    )
    values (
        p_user_id, pg_catalog.btrim(p_action),
        v_now, v_now, v_now, v_now
    )
    on conflict (user_id, action) do nothing;

    select *
    into v_bucket
    from private.rate_limit_buckets
    where user_id = p_user_id
      and action = pg_catalog.btrim(p_action)
    for update;

    if v_bucket.blocked_until is not null and v_bucket.blocked_until > v_now then
        v_retry_after := greatest(1, ceil(extract(epoch from (v_bucket.blocked_until - v_now)))::integer);

        raise sqlstate 'PGRST'
        using
            message = pg_catalog.json_build_object(
                'code', 'SITEBIN_RATE_LIMITED',
                'message', 'تعداد درخواست‌های شما برای این عملیات بیش از حد مجاز است.',
                'details', pg_catalog.json_build_object(
                    'retry_after_seconds', v_retry_after,
                    'action', pg_catalog.btrim(p_action)
                )::text,
                'hint', 'لطفاً پس از پایان محدودیت دوباره تلاش کنید.'
            )::text,
            detail = pg_catalog.json_build_object(
                'status', 429,
                'status_text', 'Too Many Requests',
                'headers', pg_catalog.json_build_object(
                    'Retry-After', v_retry_after::text,
                    'Cache-Control', 'no-store'
                )
            )::text;
    end if;

    v_count_10s := case
        when v_bucket.ten_second_started_at <= v_now - interval '10 seconds' then 1
        else v_bucket.ten_second_count + 1
    end;

    v_count_1m := case
        when v_bucket.minute_started_at <= v_now - interval '1 minute' then 1
        else v_bucket.minute_count + 1
    end;

    v_count_5m := case
        when v_bucket.five_minute_started_at <= v_now - interval '5 minutes' then 1
        else v_bucket.five_minute_count + 1
    end;

    v_count_1h := case
        when v_bucket.hour_started_at <= v_now - interval '1 hour' then 1
        else v_bucket.hour_count + 1
    end;

    update private.rate_limit_buckets
    set
        ten_second_started_at = case
            when v_bucket.ten_second_started_at <= v_now - interval '10 seconds' then v_now
            else v_bucket.ten_second_started_at
        end,
        ten_second_count = v_count_10s,
        minute_started_at = case
            when v_bucket.minute_started_at <= v_now - interval '1 minute' then v_now
            else v_bucket.minute_started_at
        end,
        minute_count = v_count_1m,
        five_minute_started_at = case
            when v_bucket.five_minute_started_at <= v_now - interval '5 minutes' then v_now
            else v_bucket.five_minute_started_at
        end,
        five_minute_count = v_count_5m,
        hour_started_at = case
            when v_bucket.hour_started_at <= v_now - interval '1 hour' then v_now
            else v_bucket.hour_started_at
        end,
        hour_count = v_count_1h,
        updated_at = v_now,
        blocked_until = null
    where user_id = p_user_id
      and action = pg_catalog.btrim(p_action);

    if v_limit_10s is not null then
        if v_count_1h >= v_limit_1h then
            v_block_seconds := v_block_1h;
        elsif v_count_5m >= v_limit_5m then
            v_block_seconds := v_block_5m;
        elsif v_count_1m >= v_limit_1m then
            v_block_seconds := v_block_1m;
        elsif v_count_10s >= v_limit_10s then
            v_block_seconds := v_block_10s;
        end if;
    end if;

    if v_block_seconds > 0 then
        update private.rate_limit_buckets
        set blocked_until = v_now + make_interval(secs => v_block_seconds),
            updated_at = v_now
        where user_id = p_user_id
          and action = pg_catalog.btrim(p_action);
    end if;

    -- Limit the table footprint lazily per user. A user can only accumulate
    -- stale action rows from actions they actually used.
    delete from private.rate_limit_buckets
    where user_id = p_user_id
      and action <> pg_catalog.btrim(p_action)
      and updated_at < v_now - interval '2 hours';
end;
$function$;

revoke execute on function private.enforce_user_rate_limit(uuid, text)
from public, anon, authenticated, authenticator;

create or replace function public.check_request()
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_method text := current_setting('request.method', true);
    v_path text := trim(both '/' from current_setting('request.path', true));
    v_claim_sub text := nullif(current_setting('request.jwt.claim.sub', true), '');
    v_claims text := current_setting('request.jwt.claims', true);
    v_uid uuid;
    v_action text;
begin
    if v_method is null or v_method in ('GET', 'HEAD') then
        return;
    end if;

    if v_claim_sub is null and v_claims is not null and pg_catalog.btrim(v_claims) <> '' then
        v_claim_sub := (v_claims::jsonb ->> 'sub');
    end if;

    v_uid := nullif(v_claim_sub, '')::uuid;

    if v_uid is null then
        return;
    end if;

    if v_path like 'rpc/%' then
        v_action := split_part(v_path, '/', 2);

        perform private.enforce_user_rate_limit(v_uid, '__GLOBAL__');

        case v_action
            when 'create_campaign',
                 'transfer_coins',
                 'request_view_session',
                 'signal_content_ready',
                 'complete_view_session',
                 'cancel_view_session',
                 'pause_campaign',
                 'resume_campaign',
                 'cancel_campaign',
                 'activate_auto_view',
                 'init_user_account'
            then
                perform private.enforce_user_rate_limit(v_uid, v_action);
            else
                null;
        end case;
    end if;
end;
$function$;

revoke all on function public.check_request() from public, anon, authenticated;
grant execute on function public.check_request() to authenticator;

drop function if exists private.check_request();
alter role authenticator set pgrst.db_pre_request = 'public.check_request';
notify pgrst, 'reload config';
