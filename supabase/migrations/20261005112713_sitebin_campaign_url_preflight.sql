-- SiteBin campaign URL preflight hardening.
BEGIN;

CREATE TABLE IF NOT EXISTS private.campaign_preflight_tokens (
    token_hash TEXT PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    source_url TEXT NOT NULL,
    normalized_url TEXT NOT NULL,
    domain TEXT NOT NULL,
    final_url TEXT NOT NULL,
    http_status INTEGER NOT NULL,
    redirect_count INTEGER NOT NULL DEFAULT 0,
    response_ms BIGINT NOT NULL,
    content_type TEXT NULL,
    content_length BIGINT NULL,
    viewer_compatibility TEXT NOT NULL,
    quality_score INTEGER NOT NULL,
    diagnostics JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp(),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ NULL,
    CONSTRAINT campaign_preflight_token_hash_check CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT campaign_preflight_url_length_check CHECK (
        length(source_url) BETWEEN 1 AND 2048
        AND length(normalized_url) BETWEEN 1 AND 2048
        AND length(final_url) BETWEEN 1 AND 2048
    ),
    CONSTRAINT campaign_preflight_https_check CHECK (
        source_url ~* '^https://' AND normalized_url ~* '^https://' AND final_url ~* '^https://'
    ),
    CONSTRAINT campaign_preflight_status_check CHECK (http_status BETWEEN 200 AND 599),
    CONSTRAINT campaign_preflight_redirect_check CHECK (redirect_count BETWEEN 0 AND 3),
    CONSTRAINT campaign_preflight_response_check CHECK (response_ms >= 0),
    CONSTRAINT campaign_preflight_compatibility_check CHECK (viewer_compatibility IN ('COMPATIBLE','NEEDS_ATTENTION','INCOMPATIBLE')),
    CONSTRAINT campaign_preflight_score_check CHECK (quality_score BETWEEN 0 AND 100),
    CONSTRAINT campaign_preflight_expiry_check CHECK (expires_at > created_at)
);

ALTER TABLE private.campaign_preflight_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.campaign_preflight_tokens FROM PUBLIC, anon, authenticated;
DROP POLICY IF EXISTS "Deny direct access to campaign preflight tokens" ON private.campaign_preflight_tokens;
CREATE POLICY "Deny direct access to campaign preflight tokens"
ON private.campaign_preflight_tokens AS RESTRICTIVE FOR ALL TO public
USING (false) WITH CHECK (false);

CREATE INDEX IF NOT EXISTS idx_campaign_preflight_tokens_user_expiry ON private.campaign_preflight_tokens(user_id, expires_at);
CREATE INDEX IF NOT EXISTS idx_campaign_preflight_tokens_expiry ON private.campaign_preflight_tokens(expires_at);

CREATE OR REPLACE FUNCTION public.store_campaign_preflight_token(
    p_token_hash TEXT, p_user_id UUID, p_source_url TEXT, p_normalized_url TEXT,
    p_domain TEXT, p_final_url TEXT, p_http_status INTEGER, p_redirect_count INTEGER,
    p_response_ms BIGINT, p_content_type TEXT, p_content_length BIGINT,
    p_viewer_compatibility TEXT, p_quality_score INTEGER, p_diagnostics JSONB,
    p_expires_at TIMESTAMPTZ
)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_now TIMESTAMPTZ := pg_catalog.clock_timestamp(); v_hash TEXT := lower(pg_catalog.btrim(p_token_hash));
BEGIN
    IF p_user_id IS NULL OR v_hash !~ '^[0-9a-f]{64}$' OR p_source_url IS NULL
       OR p_normalized_url IS NULL OR p_final_url IS NULL OR p_domain IS NULL
       OR p_expires_at IS NULL OR p_expires_at <= v_now OR p_expires_at > v_now + interval '15 minutes'
       OR p_http_status NOT BETWEEN 200 AND 599 OR p_redirect_count NOT BETWEEN 0 AND 3 OR p_response_ms < 0
       OR p_viewer_compatibility NOT IN ('COMPATIBLE','NEEDS_ATTENTION')
       OR p_quality_score NOT BETWEEN 0 AND 100 THEN
        RAISE EXCEPTION 'INVALID_PREFLIGHT_TOKEN: Invalid server preflight payload';
    END IF;

    IF length(p_source_url) > 2048 OR length(p_normalized_url) > 2048 OR length(p_final_url) > 2048
       OR p_source_url !~* '^https://' OR p_normalized_url !~* '^https://' OR p_final_url !~* '^https://'
       OR p_source_url ~ '[[:space:]]' OR p_normalized_url ~ '[[:space:]]' OR p_final_url ~ '[[:space:]]'
       OR position('@' in p_source_url) > 0 OR position('@' in p_normalized_url) > 0 OR position('@' in p_final_url) > 0 THEN
        RAISE EXCEPTION 'INVALID_PREFLIGHT_TOKEN: Unsafe URL in server preflight payload';
    END IF;

    DELETE FROM private.campaign_preflight_tokens
    WHERE user_id = p_user_id
      AND (expires_at < v_now OR (consumed_at IS NOT NULL AND consumed_at < v_now - interval '1 hour'));

    WITH stale AS (
        SELECT token_hash
        FROM private.campaign_preflight_tokens
        WHERE expires_at < v_now OR (consumed_at IS NOT NULL AND consumed_at < v_now - interval '1 hour')
        ORDER BY expires_at ASC
        LIMIT 200
    )
    DELETE FROM private.campaign_preflight_tokens t
    USING stale s
    WHERE t.token_hash = s.token_hash;

    INSERT INTO private.campaign_preflight_tokens(
        token_hash,user_id,source_url,normalized_url,domain,final_url,http_status,redirect_count,
        response_ms,content_type,content_length,viewer_compatibility,quality_score,diagnostics,created_at,expires_at
    )
    VALUES(
        v_hash,p_user_id,pg_catalog.btrim(p_source_url),pg_catalog.btrim(p_normalized_url),
        lower(pg_catalog.btrim(p_domain)),pg_catalog.btrim(p_final_url),p_http_status,p_redirect_count,
        p_response_ms,NULLIF(pg_catalog.btrim(coalesce(p_content_type,'')),''),p_content_length,
        p_viewer_compatibility,p_quality_score,coalesce(p_diagnostics,'[]'::jsonb),v_now,p_expires_at
    );

    RETURN pg_catalog.json_build_object('stored',true,'expires_at',p_expires_at,'expires_at_epoch_ms',(extract(epoch from p_expires_at)*1000)::bigint);
END;
$function$;

REVOKE ALL ON FUNCTION public.store_campaign_preflight_token(
 TEXT,UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,INTEGER,BIGINT,TEXT,BIGINT,TEXT,INTEGER,JSONB,TIMESTAMPTZ
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.store_campaign_preflight_token(
 TEXT,UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,INTEGER,BIGINT,TEXT,BIGINT,TEXT,INTEGER,JSONB,TIMESTAMPTZ
) TO service_role;

CREATE OR REPLACE FUNCTION public.prune_campaign_preflight_tokens()
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_deleted BIGINT;
BEGIN
 DELETE FROM private.campaign_preflight_tokens
 WHERE expires_at < pg_catalog.clock_timestamp()
    OR (consumed_at IS NOT NULL AND consumed_at < pg_catalog.clock_timestamp() - interval '1 hour');
 GET DIAGNOSTICS v_deleted = ROW_COUNT; RETURN v_deleted;
END;
$function$;
REVOKE ALL ON FUNCTION public.prune_campaign_preflight_tokens() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.prune_campaign_preflight_tokens() TO service_role;

CREATE OR REPLACE FUNCTION public.consume_campaign_url_preflight_rate_limit()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid UUID := (SELECT auth.uid());
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required'; END IF;
 IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean),false) THEN
   RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
 END IF;
 PERFORM private.enforce_user_rate_limit(v_uid,'campaign_url_preflight');
END;
$function$;
REVOKE ALL ON FUNCTION public.consume_campaign_url_preflight_rate_limit() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.consume_campaign_url_preflight_rate_limit() TO authenticated;

CREATE OR REPLACE FUNCTION public.consume_keyword_resolver_rate_limit()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid UUID := (SELECT auth.uid());
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required'; END IF;
 IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean),false) THEN
   RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
 END IF;
 PERFORM private.enforce_user_rate_limit(v_uid,'keyword_resolver');
END;
$function$;
REVOKE ALL ON FUNCTION public.consume_keyword_resolver_rate_limit() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.consume_keyword_resolver_rate_limit() TO authenticated;

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
        when 'campaign_url_preflight' then
            v_limit_10s := 2;   v_limit_1m := 6;  v_limit_5m := 12;  v_limit_1h := 30;
            v_block_10s := 20;  v_block_1m := 120; v_block_5m := 600; v_block_1h := 3600;
        when 'keyword_resolver' then
            v_limit_10s := 1;   v_limit_1m := 4;  v_limit_5m := 8;   v_limit_1h := 20;
            v_block_10s := 30;  v_block_1m := 180; v_block_5m := 900; v_block_1h := 3600;
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

        /*
         * Hourly exhaustion on high-impact operations is strong evidence of
         * abusive automation. Escalate to a one-hour account-wide write block.
         * Viewer timing/telemetry operations deliberately do not trigger this.
         */
        if v_count_1h >= v_limit_1h
           and pg_catalog.btrim(p_action) in (
               'create_campaign',
               'transfer_coins',
               'activate_auto_view',
               'init_user_account'
           ) then
            insert into private.rate_limit_buckets (
                user_id, action,
                ten_second_started_at,
                minute_started_at,
                five_minute_started_at,
                hour_started_at,
                blocked_until,
                updated_at
            )
            values (
                p_user_id, '__GLOBAL__',
                v_now, v_now, v_now, v_now,
                v_now + interval '1 hour',
                v_now
            )
            on conflict (user_id, action) do update
            set blocked_until = greatest(
                    coalesce(private.rate_limit_buckets.blocked_until, v_now),
                    v_now + interval '1 hour'
                ),
                updated_at = v_now;
        end if;
    end if;

    -- Limit the table footprint lazily per user. A user can only accumulate
    -- stale action rows from actions they actually used.
    delete from private.rate_limit_buckets
    where user_id = p_user_id
      and action <> pg_catalog.btrim(p_action)
      and updated_at < v_now - interval '2 hours';
end;
$function$;


CREATE OR REPLACE FUNCTION public.create_campaign(
  p_url text,
  p_normalized_url text,
  p_domain text,
  p_duration_seconds integer,
  p_target_views integer,
  p_keyword text,
  p_preflight_token text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_uid UUID := (select auth.uid());
    v_price RECORD;
    v_profile RECORD;
    v_new_campaign RECORD;
    v_clean_url TEXT;
    v_clean_normalized TEXT;
    v_clean_domain TEXT;
    v_clean_keyword TEXT;
    v_total_cost BIGINT;
    v_authority TEXT;
    v_host TEXT;
    v_port_text TEXT;
    v_ip INET;
    v_advertiser_cost BIGINT;
    v_resolver_status TEXT;
    v_preflight RECORD;
    v_preflight_hash TEXT;
    v_now TIMESTAMPTZ := pg_catalog.clock_timestamp();
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    IF p_preflight_token IS NULL
       OR pg_catalog.length(pg_catalog.btrim(p_preflight_token)) < 32
       OR pg_catalog.length(pg_catalog.btrim(p_preflight_token)) > 256
       OR pg_catalog.btrim(p_preflight_token) ~ '[[:space:]]' THEN
        RAISE EXCEPTION 'PREFLIGHT_REQUIRED: A recent server-side website preflight is required before creating a campaign';
    END IF;

    v_preflight_hash := pg_catalog.encode(
        extensions.digest(pg_catalog.btrim(p_preflight_token), 'sha256'),
        'hex'
    );

    UPDATE private.campaign_preflight_tokens
    SET consumed_at = v_now
    WHERE token_hash = v_preflight_hash
      AND user_id = v_uid
      AND expires_at > v_now
      AND consumed_at IS NULL
    RETURNING * INTO v_preflight;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'PREFLIGHT_REQUIRED: The website preflight is missing, expired, already used, or not owned by this account';
    END IF;

    IF v_preflight.viewer_compatibility = 'INCOMPATIBLE' THEN
        RAISE EXCEPTION 'PREFLIGHT_REJECTED: The website is not compatible with the SiteBin viewer';
    END IF;

    IF pg_catalog.btrim(p_url) <> v_preflight.source_url
       OR pg_catalog.btrim(p_normalized_url) <> v_preflight.normalized_url THEN
        RAISE EXCEPTION 'PREFLIGHT_MISMATCH: The submitted URL does not match the preflighted URL';
    END IF;

    -- Token-stored URL metadata is authoritative; client metadata is never trusted.
    v_clean_url := v_preflight.source_url;
    v_clean_normalized := v_preflight.normalized_url;
    v_clean_domain := v_preflight.domain;
    v_clean_normalized := trim(p_normalized_url);
    v_clean_keyword := NULLIF(pg_catalog.btrim(p_keyword), '');

    IF v_clean_url IS NULL OR pg_catalog.length(v_clean_url) = 0
       OR pg_catalog.length(v_clean_url) > 2048
       OR v_clean_url !~* '^https://'
       OR v_clean_url ~ '[[:space:]]'
       OR position('@' in v_clean_url) > 0
       OR position('[' in v_clean_url) > 0
       OR position(']' in v_clean_url) > 0 THEN
        RAISE EXCEPTION 'INVALID_URL: Target URL must be an HTTPS address without userinfo, IPv6 literals, or whitespace, up to 2048 characters';
    END IF;

    v_authority := substring(v_clean_url FROM '^https://([^/?#]+)');
    IF v_authority IS NULL OR pg_catalog.length(v_authority) = 0 THEN
        RAISE EXCEPTION 'INVALID_URL: Target URL host is missing';
    END IF;

    IF (pg_catalog.length(v_authority) - pg_catalog.length(replace(v_authority, ':', ''))) > 1 THEN
        RAISE EXCEPTION 'INVALID_URL: Target URL contains an invalid host or port';
    END IF;

    IF position(':' in v_authority) > 0 THEN
        v_host := split_part(v_authority, ':', 1);
        v_port_text := split_part(v_authority, ':', 2);
        IF v_port_text !~ '^[0-9]{1,5}$' OR (v_port_text)::integer NOT BETWEEN 1 AND 65535 THEN
            RAISE EXCEPTION 'INVALID_URL: Target URL contains an invalid port';
        END IF;
    ELSE
        v_host := v_authority;
    END IF;

    v_host := lower(trim(v_host));

    IF v_host IS NULL OR pg_catalog.length(v_host) = 0 OR pg_catalog.length(v_host) > 253
       OR v_host !~ '^[a-z0-9.-]+$'
       OR v_host LIKE '%.localhost'
       OR v_host LIKE '%.local'
       OR v_host LIKE '%.internal'
       OR v_host IN ('localhost', 'localhost.localdomain', 'metadata.google.internal', 'metadata.google.com') THEN
        RAISE EXCEPTION 'INVALID_URL: Target host is not an allowed public hostname';
    END IF;

    IF v_host ~ '^[0-9]+$'
       OR v_host ~* '^0x[0-9a-f]+$'
       OR (v_host ~ '^[0-9.]+$' AND v_host !~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') THEN
        RAISE EXCEPTION 'INVALID_URL: Target host uses a disallowed numeric IP representation';
    END IF;

    IF v_host ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' THEN
        IF EXISTS (
            SELECT 1
            FROM unnest(string_to_array(v_host, '.')) AS octet(value)
            WHERE octet.value::integer NOT BETWEEN 0 AND 255
        ) THEN
            RAISE EXCEPTION 'INVALID_URL: Target IPv4 address is invalid';
        END IF;

        v_ip := v_host::inet;
        IF v_ip <<= inet '0.0.0.0/8'
           OR v_ip <<= inet '10.0.0.0/8'
           OR v_ip <<= inet '100.64.0.0/10'
           OR v_ip <<= inet '127.0.0.0/8'
           OR v_ip <<= inet '169.254.0.0/16'
           OR v_ip <<= inet '172.16.0.0/12'
           OR v_ip <<= inet '192.0.0.0/24'
           OR v_ip <<= inet '192.168.0.0/16'
           OR v_ip <<= inet '198.18.0.0/15'
           OR v_ip <<= inet '198.51.100.0/24'
           OR v_ip <<= inet '203.0.113.0/24'
           OR v_ip <<= inet '224.0.0.0/4'
           OR v_ip = inet '255.255.255.255' THEN
            RAISE EXCEPTION 'INVALID_URL: Target IPv4 address is private, reserved, multicast, or otherwise non-public';
        END IF;
    END IF;

    IF v_clean_normalized IS NULL
       OR pg_catalog.length(v_clean_normalized) = 0
       OR pg_catalog.length(v_clean_normalized) > 2048 THEN
        RAISE EXCEPTION 'INVALID_NORMALIZED_URL: Normalized URL cannot be empty';
    END IF;

    IF v_clean_keyword IS NOT NULL THEN
        IF pg_catalog.length(v_clean_keyword) > 25
           OR v_clean_keyword ~ '[[:cntrl:]]' THEN
            RAISE EXCEPTION 'INVALID_KEYWORD: Keyword must be between 1 and 25 characters and cannot contain control characters';
        END IF;
    END IF;

    IF p_target_views <= 0 OR p_target_views > 1000000 THEN
        RAISE EXCEPTION 'INVALID_TARGET_VIEWS: Target views must be between 1 and 1,000,000';
    END IF;

    SELECT * INTO v_price
    FROM public.duration_pricing
    WHERE duration_seconds = p_duration_seconds;

    IF v_price IS NULL THEN
        RAISE EXCEPTION 'INVALID_DURATION: Unsupported duration option';
    END IF;

    v_advertiser_cost :=
        CASE
            WHEN v_clean_keyword IS NULL THEN v_price.advertiser_cost
            ELSE v_price.keyword_advertiser_cost
        END;

    v_total_cost := v_advertiser_cost * p_target_views;

    SELECT * INTO v_profile
    FROM public.profiles
    WHERE id = v_uid
    FOR UPDATE;

    IF v_profile IS NULL THEN
        RAISE EXCEPTION 'PROFILE_NOT_FOUND: User profile does not exist';
    END IF;

    IF v_profile.available_coins < v_total_cost THEN
        RAISE EXCEPTION 'INSUFFICIENT_BALANCE: Available balance (%) coins is less than required budget (%) coins',
            v_profile.available_coins, v_total_cost;
    END IF;

    UPDATE public.profiles
    SET available_coins = available_coins - v_total_cost,
        reserved_coins = reserved_coins + v_total_cost,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_uid;

    v_resolver_status := CASE WHEN v_clean_keyword IS NULL THEN 'NOT_REQUIRED' ELSE 'PENDING' END;

    INSERT INTO public.campaigns(
        owner_id, url, normalized_url, domain, keyword,
        duration_seconds, target_views, completed_views,
        cost_per_view, total_budget, spent_budget, reserved_budget,
        status, resolved_target_url, resolver_status, resolved_at, resolver_version,
        created_at, updated_at
    )
    VALUES(
        v_uid, v_clean_url, v_clean_normalized, v_clean_domain, v_clean_keyword,
        p_duration_seconds, p_target_views, 0,
        v_advertiser_cost, v_total_cost, 0, v_total_cost,
        'ACTIVE',
        NULL,
        v_resolver_status,
        NULL,
        1,
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    RETURNING * INTO v_new_campaign;

    INSERT INTO public.coin_ledger(
        user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
    )
    VALUES(
        v_uid,
        -v_total_cost,
        'CAMPAIGN_RESERVATION',
        CASE
            WHEN v_clean_keyword IS NULL THEN
                'رزرو بودجه برای سفارش ' || p_target_views || ' بازدید از ' || v_clean_domain
            ELSE
                'رزرو بودجه برای سفارش ' || p_target_views || ' بازدید از ' || v_clean_domain ||
                ' با کلمه کلیدی «' || v_clean_keyword || '»'
        END,
        v_new_campaign.id::text,
        'camp_res_' || v_new_campaign.id::text,
        pg_catalog.clock_timestamp()
    );

    RETURN pg_catalog.row_to_json(v_new_campaign);
END;
$function$;

REVOKE ALL ON FUNCTION public.create_campaign(TEXT,TEXT,TEXT,INTEGER,INTEGER,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.create_campaign(TEXT,TEXT,TEXT,INTEGER,INTEGER) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.create_campaign(TEXT,TEXT,TEXT,INTEGER,INTEGER,TEXT,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_campaign(TEXT,TEXT,TEXT,INTEGER,INTEGER,TEXT,TEXT) TO authenticated;

COMMIT;