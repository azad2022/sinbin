-- SiteBin: move rate-limit thresholds into a private, versioned policy table.
-- Backwards-compatible: existing RPC signatures and response contracts are unchanged.
-- Existing Android releases continue to use the same RPC endpoints.
BEGIN;

CREATE TABLE IF NOT EXISTS private.rate_limit_policies (
    action text PRIMARY KEY,
    limit_10s integer NOT NULL CHECK (limit_10s > 0),
    limit_1m integer NOT NULL CHECK (limit_1m > 0),
    limit_5m integer NOT NULL CHECK (limit_5m > 0),
    limit_1h integer NOT NULL CHECK (limit_1h > 0),
    block_10s integer NOT NULL CHECK (block_10s >= 0),
    block_1m integer NOT NULL CHECK (block_1m >= 0),
    block_5m integer NOT NULL CHECK (block_5m >= 0),
    block_1h integer NOT NULL CHECK (block_1h >= 0),
    enabled boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
    CONSTRAINT rate_limit_global_policy_must_remain_enabled
        CHECK (action <> '__GLOBAL__' OR enabled)
);

ALTER TABLE private.rate_limit_policies ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.rate_limit_policies FROM PUBLIC, anon, authenticated, authenticator;
DROP POLICY IF EXISTS "Deny direct access to rate limit policies" ON private.rate_limit_policies;
CREATE POLICY "Deny direct access to rate limit policies"
ON private.rate_limit_policies
AS RESTRICTIVE
FOR ALL
TO public
USING (false)
WITH CHECK (false);

COMMENT ON TABLE private.rate_limit_policies IS
'Server-only rate-limit policy configuration. Managed exclusively through reviewed database migrations.';

INSERT INTO private.rate_limit_policies
(action, limit_10s, limit_1m, limit_5m, limit_1h, block_10s, block_1m, block_5m, block_1h)
VALUES
('__GLOBAL__', 20, 180, 600, 7200, 15, 120, 600, 3600),
('create_campaign', 2, 5, 10, 30, 30, 180, 900, 3600),
('transfer_coins', 3, 8, 20, 50, 30, 300, 1200, 3600),
('request_view_session', 6, 20, 100, 900, 15, 60, 600, 3600),
('signal_content_ready', 6, 20, 100, 900, 15, 60, 600, 3600),
('complete_view_session', 6, 20, 100, 900, 15, 60, 600, 3600),
('cancel_view_session', 6, 20, 100, 300, 15, 60, 600, 3600),
('pause_campaign', 3, 10, 25, 100, 20, 120, 600, 3600),
('resume_campaign', 3, 10, 25, 100, 20, 120, 600, 3600),
('cancel_campaign', 3, 10, 25, 100, 20, 120, 600, 3600),
('activate_auto_view', 2, 4, 10, 30, 30, 300, 1200, 3600),
('init_user_account', 3, 6, 15, 30, 20, 120, 600, 3600),
('register_referral', 1, 3, 8, 20, 30, 180, 900, 3600),
('register_push_token', 2, 10, 30, 120, 15, 60, 300, 1800),
('set_referral_push_notifications_enabled', 2, 6, 18, 60, 15, 120, 600, 1800),
('campaign_url_preflight', 3, 20, 60, 120, 20, 120, 600, 3600),
('keyword_resolver', 1, 4, 8, 20, 30, 180, 900, 3600),
('claim_daily_bonus', 6, 30, 120, 720, 15, 60, 600, 3600)
ON CONFLICT (action) DO UPDATE SET
    limit_10s = EXCLUDED.limit_10s,
    limit_1m = EXCLUDED.limit_1m,
    limit_5m = EXCLUDED.limit_5m,
    limit_1h = EXCLUDED.limit_1h,
    block_10s = EXCLUDED.block_10s,
    block_1m = EXCLUDED.block_1m,
    block_5m = EXCLUDED.block_5m,
    block_1h = EXCLUDED.block_1h,
    enabled = true,
    updated_at = pg_catalog.clock_timestamp();

CREATE OR REPLACE FUNCTION private.enforce_user_rate_limit(
    p_user_id uuid,
    p_action text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_now timestamptz := pg_catalog.clock_timestamp();
    v_bucket private.rate_limit_buckets%rowtype;
    v_policy private.rate_limit_policies%rowtype;
    v_count_10s integer;
    v_count_1m integer;
    v_count_5m integer;
    v_count_1h integer;
    v_block_seconds integer := 0;
    v_retry_after integer := 1;
BEGIN
    IF p_user_id IS NULL OR p_action IS NULL OR pg_catalog.btrim(p_action) = '' THEN
        RETURN;
    END IF;

    SELECT * INTO v_policy
    FROM private.rate_limit_policies
    WHERE action = pg_catalog.btrim(p_action)
      AND enabled = true;

    IF NOT FOUND THEN
        IF pg_catalog.btrim(p_action) = '__GLOBAL__' THEN
            RAISE EXCEPTION 'SITEBIN_RATE_LIMIT_GLOBAL_POLICY_MISSING';
        END IF;
        RETURN;
    END IF;

    INSERT INTO private.rate_limit_buckets (
        user_id, action, ten_second_started_at, minute_started_at,
        five_minute_started_at, hour_started_at
    )
    VALUES (
        p_user_id, pg_catalog.btrim(p_action), v_now, v_now, v_now, v_now
    )
    ON CONFLICT (user_id, action) DO NOTHING;

    SELECT * INTO v_bucket
    FROM private.rate_limit_buckets
    WHERE user_id = p_user_id
      AND action = pg_catalog.btrim(p_action)
    FOR UPDATE;

    IF v_bucket.blocked_until IS NOT NULL AND v_bucket.blocked_until > v_now THEN
        v_retry_after := greatest(1, ceil(extract(epoch FROM (v_bucket.blocked_until - v_now)))::integer);
        RAISE SQLSTATE 'PGRST'
        USING
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
    END IF;

    v_count_10s := CASE
        WHEN v_bucket.ten_second_started_at <= v_now - interval '10 seconds' THEN 1
        ELSE v_bucket.ten_second_count + 1
    END;
    v_count_1m := CASE
        WHEN v_bucket.minute_started_at <= v_now - interval '1 minute' THEN 1
        ELSE v_bucket.minute_count + 1
    END;
    v_count_5m := CASE
        WHEN v_bucket.five_minute_started_at <= v_now - interval '5 minutes' THEN 1
        ELSE v_bucket.five_minute_count + 1
    END;
    v_count_1h := CASE
        WHEN v_bucket.hour_started_at <= v_now - interval '1 hour' THEN 1
        ELSE v_bucket.hour_count + 1
    END;

    UPDATE private.rate_limit_buckets
    SET
        ten_second_started_at = CASE
            WHEN v_bucket.ten_second_started_at <= v_now - interval '10 seconds' THEN v_now
            ELSE v_bucket.ten_second_started_at
        END,
        ten_second_count = v_count_10s,
        minute_started_at = CASE
            WHEN v_bucket.minute_started_at <= v_now - interval '1 minute' THEN v_now
            ELSE v_bucket.minute_started_at
        END,
        minute_count = v_count_1m,
        five_minute_started_at = CASE
            WHEN v_bucket.five_minute_started_at <= v_now - interval '5 minutes' THEN v_now
            ELSE v_bucket.five_minute_started_at
        END,
        five_minute_count = v_count_5m,
        hour_started_at = CASE
            WHEN v_bucket.hour_started_at <= v_now - interval '1 hour' THEN v_now
            ELSE v_bucket.hour_started_at
        END,
        hour_count = v_count_1h,
        updated_at = v_now,
        blocked_until = NULL
    WHERE user_id = p_user_id
      AND action = pg_catalog.btrim(p_action);

    IF v_count_1h >= v_policy.limit_1h THEN
        v_block_seconds := v_policy.block_1h;
    ELSIF v_count_5m >= v_policy.limit_5m THEN
        v_block_seconds := v_policy.block_5m;
    ELSIF v_count_1m >= v_policy.limit_1m THEN
        v_block_seconds := v_policy.block_1m;
    ELSIF v_count_10s >= v_policy.limit_10s THEN
        v_block_seconds := v_policy.block_10s;
    END IF;

    IF v_block_seconds > 0 THEN
        UPDATE private.rate_limit_buckets
        SET blocked_until = v_now + make_interval(secs => v_block_seconds),
            updated_at = v_now
        WHERE user_id = p_user_id
          AND action = pg_catalog.btrim(p_action);

        IF v_count_1h >= v_policy.limit_1h
           AND pg_catalog.btrim(p_action) IN (
               'create_campaign',
               'transfer_coins',
               'activate_auto_view',
               'init_user_account'
           ) THEN
            INSERT INTO private.rate_limit_buckets (
                user_id, action, ten_second_started_at, minute_started_at,
                five_minute_started_at, hour_started_at, blocked_until, updated_at
            )
            VALUES (
                p_user_id, '__GLOBAL__', v_now, v_now, v_now, v_now,
                v_now + interval '1 hour', v_now
            )
            ON CONFLICT (user_id, action) DO UPDATE
            SET blocked_until = greatest(
                    coalesce(private.rate_limit_buckets.blocked_until, v_now),
                    v_now + interval '1 hour'
                ),
                updated_at = v_now;
        END IF;
    END IF;

    DELETE FROM private.rate_limit_buckets
    WHERE user_id = p_user_id
      AND action <> pg_catalog.btrim(p_action)
      AND updated_at < v_now - interval '2 hours';
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_request()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_method text := current_setting('request.method', true);
    v_path text := trim(both '/' FROM current_setting('request.path', true));
    v_claim_sub text := nullif(current_setting('request.jwt.claim.sub', true), '');
    v_claims text := current_setting('request.jwt.claims', true);
    v_uid uuid;
    v_action text;
BEGIN
    IF v_method IS NULL OR v_method IN ('GET', 'HEAD') THEN
        RETURN;
    END IF;

    IF v_claim_sub IS NULL AND v_claims IS NOT NULL AND pg_catalog.btrim(v_claims) <> '' THEN
        v_claim_sub := (v_claims::jsonb ->> 'sub');
    END IF;

    v_uid := nullif(v_claim_sub, '')::uuid;
    IF v_uid IS NULL THEN
        RETURN;
    END IF;

    IF v_path LIKE 'rpc/%' THEN
        v_action := split_part(v_path, '/', 2);
        PERFORM private.enforce_user_rate_limit(v_uid, '__GLOBAL__');

        CASE v_action
            WHEN 'create_campaign',
                 'transfer_coins',
                 'request_view_session',
                 'signal_content_ready',
                 'complete_view_session',
                 'cancel_view_session',
                 'pause_campaign',
                 'resume_campaign',
                 'cancel_campaign',
                 'activate_auto_view',
                 'init_user_account',
                 'claim_daily_bonus'
            THEN
                PERFORM private.enforce_user_rate_limit(v_uid, v_action);
            ELSE
                NULL;
        END CASE;
    END IF;
END;
$function$;

REVOKE EXECUTE ON FUNCTION private.enforce_user_rate_limit(uuid, text)
FROM PUBLIC, anon, authenticated, authenticator;
REVOKE EXECUTE ON FUNCTION public.check_request() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_request() TO anon, authenticated, authenticator;

NOTIFY pgrst, 'reload config';
COMMIT;
