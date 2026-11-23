-- Session 2 acceptance suite.
-- All fixture rows and all exercised state transitions are rolled back.
-- This suite creates its own Auth users, profiles and campaigns; it never
-- depends on production accounts, seed inventory or mutable dashboard data.

BEGIN;

CREATE TEMP TABLE _s2_campaigns (
    owner_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    rank integer,
    purpose text NOT NULL,
    domain text NOT NULL
) ON COMMIT DROP;

CREATE TEMP TABLE _s2_rank_fixture (
    user_id uuid PRIMARY KEY,
    completed_views integer NOT NULL CHECK (completed_views > 0)
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.restore_s2_daily_ranking(p_day date)
RETURNS void
LANGUAGE sql
AS $restore$
    INSERT INTO public.daily_view_leaderboard(
        leaderboard_date, user_id, user_handle, completed_views, updated_at
    )
    SELECT
        p_day,
        p.user_id,
        profile.user_handle,
        p.completed_views,
        pg_catalog.clock_timestamp()
    FROM _s2_rank_fixture p
    JOIN public.profiles profile ON profile.id = p.user_id
    ON CONFLICT (leaderboard_date, user_id) DO UPDATE
    SET user_handle = EXCLUDED.user_handle,
        completed_views = EXCLUDED.completed_views,
        updated_at = EXCLUDED.updated_at;
$restore$;

DO $test$
DECLARE
    v_tag text := substr(md5(clock_timestamp()::text || random()::text), 1, 10);
    v_viewer uuid := gen_random_uuid();
    v_rank_owners uuid[] := ARRAY[
        gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
        gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
        gen_random_uuid()
    ];
    v_fallback_owner uuid := gen_random_uuid();
    v_cap_viewer_a uuid := gen_random_uuid();
    v_cap_viewer_b uuid := gen_random_uuid();
    v_cap_owner uuid := gen_random_uuid();
    v_rolling_viewer uuid := gen_random_uuid();
    v_boundary_viewer uuid := gen_random_uuid();
    v_tie_a uuid := gen_random_uuid();
    v_tie_b uuid := gen_random_uuid();
    v_ttl_viewer uuid := gen_random_uuid();
    v_ttl_owner uuid := gen_random_uuid();
    v_all_users uuid[];
    v_uid uuid;
    v_handle text;
    v_owner_id uuid;
    v_campaign_id uuid;
    v_domain text;
    v_url text;
    v_token text;
    v_token_hash text;
    v_campaign_target integer;
    v_result json;
    v_retry json;
    v_completion json;
    v_completion_retry json;
    v_session_id uuid;
    v_retry_session_id uuid;
    v_assignment_status text;
    v_assignment_count integer;
    v_request_position bigint;
    v_featured_rank integer;
    v_signal boolean;
    v_available_before bigint;
    v_available_after bigint;
    v_reward bigint;
    v_completed_count integer;
    v_active_count integer;
    v_daily_before integer;
    v_daily_after integer;
    v_day_utc date := (pg_catalog.clock_timestamp() AT TIME ZONE 'UTC')::date;
    v_boundary_day date := (pg_catalog.clock_timestamp() AT TIME ZONE 'UTC')::date - 1;
    v_boundary_before timestamptz;
    v_boundary_after timestamptz;
    v_rolling_count integer;
    v_tie_rank_a integer;
    v_tie_rank_b integer;
    v_idempotency_key text;
    i integer;
BEGIN
    v_all_users := ARRAY[v_viewer] || v_rank_owners
        || ARRAY[
            v_fallback_owner, v_cap_viewer_a, v_cap_viewer_b, v_cap_owner,
            v_rolling_viewer, v_boundary_viewer, v_tie_a, v_tie_b,
            v_ttl_viewer, v_ttl_owner
        ];

    -- Isolated identities make the suite deterministic on a completely empty DB.
    INSERT INTO auth.users(
        id, aud, role, email, email_confirmed_at,
        created_at, updated_at, is_sso_user, is_anonymous
    )
    SELECT
        u, 'authenticated', 'authenticated',
        'sitebin_s2_' || pg_catalog.replace(u::text, '-', '') || '@sitebin.internal',
        pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp(),
        false, false
    FROM pg_catalog.unnest(v_all_users) AS users(u);

    INSERT INTO public.profiles(
        id, user_handle, app_install_id, available_coins, reserved_coins,
        lifetime_earned, lifetime_spent, trust_score, completed_views_count,
        received_views_count, welcome_bonus_claimed, created_at, updated_at
    )
    SELECT
        u,
        's2_' || pg_catalog.substr(pg_catalog.replace(u::text, '-', ''), 1, 12),
        's2_inst_' || pg_catalog.substr(pg_catalog.replace(u::text, '-', ''), 1, 12),
        100000, 100000, 100000, 0, 100.0, 0, 0, true,
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    FROM pg_catalog.unnest(v_all_users) AS users(u);

    -- Campaigns for rank 1 (self) and ranks 3..7. Rank 2 and rank 8
    -- intentionally have no campaign. A separate owner is reserved for fallback.
    FOR i IN 1..7 LOOP
        IF i = 1 OR i BETWEEN 2 AND 6 THEN
            v_owner_id := CASE WHEN i = 1 THEN v_viewer ELSE v_rank_owners[i] END;
            v_domain := 's2-' || v_tag || '-rank-' || i::text || '.example.com';
            v_url := 'https://' || v_domain || '/';
            v_token := 's2-token-' || v_tag || '-' || i::text;
            v_token_hash := pg_catalog.encode(
                extensions.digest(v_token, 'sha256'), 'hex'
            );

            INSERT INTO private.campaign_preflight_tokens(
                token_hash, user_id, source_url, normalized_url, domain, final_url,
                http_status, redirect_count, response_ms, content_type, content_length,
                viewer_compatibility, quality_score, diagnostics, created_at,
                expires_at, consumed_at
            ) VALUES (
                v_token_hash, v_owner_id, v_url, v_url, v_domain, v_url,
                200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
                pg_catalog.jsonb_build_object('referral_site_key', v_domain),
                pg_catalog.clock_timestamp(),
                pg_catalog.clock_timestamp() + INTERVAL '10 minutes',
                pg_catalog.clock_timestamp()
            );

            INSERT INTO public.campaigns(
                owner_id, url, normalized_url, domain, duration_seconds,
                target_views, completed_views, cost_per_view, total_budget,
                spent_budget, reserved_budget, refunded_budget, status,
                created_at, updated_at
            ) VALUES (
                v_owner_id, v_url, v_url, v_domain, 5,
                20, 0, 5, 100, 0, 100, 0, 'ACTIVE',
                pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
            )
            RETURNING id INTO v_campaign_id;

            INSERT INTO _s2_campaigns(owner_id, campaign_id, rank, purpose, domain)
            VALUES (
                v_owner_id, v_campaign_id,
                CASE WHEN i = 1 THEN 1 ELSE i + 1 END,
                CASE WHEN i = 1 THEN 'self' ELSE 'ranked' END,
                v_domain
            );
        END IF;
    END LOOP;

    -- An active campaign outside the leaderboard is available only to the normal
    -- distribution fallback after every eligible ranked owner has been examined.
    v_domain := 's2-' || v_tag || '-fallback.example.com';
    v_url := 'https://' || v_domain || '/';
    v_token := 's2-token-' || v_tag || '-fallback';
    v_token_hash := pg_catalog.encode(extensions.digest(v_token, 'sha256'), 'hex');

    INSERT INTO private.campaign_preflight_tokens(
        token_hash, user_id, source_url, normalized_url, domain, final_url,
        http_status, redirect_count, response_ms, content_type, content_length,
        viewer_compatibility, quality_score, diagnostics, created_at,
        expires_at, consumed_at
    ) VALUES (
        v_token_hash, v_fallback_owner, v_url, v_url, v_domain, v_url,
        200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
        pg_catalog.jsonb_build_object('referral_site_key', v_domain),
        pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp() + INTERVAL '10 minutes',
        pg_catalog.clock_timestamp()
    );

    INSERT INTO public.campaigns(
        owner_id, url, normalized_url, domain, duration_seconds,
        target_views, completed_views, cost_per_view, total_budget,
        spent_budget, reserved_budget, refunded_budget, status,
        created_at, updated_at
    ) VALUES (
        v_fallback_owner, v_url, v_url, v_domain, 5,
        20, 0, 5, 100, 0, 100, 0, 'ACTIVE',
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    RETURNING id INTO v_campaign_id;

    INSERT INTO _s2_campaigns(owner_id, campaign_id, rank, purpose, domain)
    VALUES (v_fallback_owner, v_campaign_id, NULL, 'fallback', v_domain);

    -- Force a known daily UTC ranking. Keep a copy in a transaction-local table
    -- because the real reconciliation trigger rebuilds the public aggregate after
    -- Session state transitions exercised below.
    INSERT INTO _s2_rank_fixture(user_id, completed_views)
    VALUES
        (v_viewer, 800),
        (v_rank_owners[1], 700),
        (v_rank_owners[2], 600),
        (v_rank_owners[3], 500),
        (v_rank_owners[4], 400),
        (v_rank_owners[5], 300),
        (v_rank_owners[6], 200),
        (v_rank_owners[7], 100);
    PERFORM pg_temp.restore_s2_daily_ranking(v_day_utc);

    -- Request retry is idempotent: the same active Session is returned and the
    -- per-viewer cursor is not consumed a second time.
    PERFORM pg_catalog.set_config(
        'request.jwt.claims',
        pg_catalog.jsonb_build_object(
            'sub', v_viewer::text,
            'role', 'authenticated',
            'is_anonymous', false
        )::text,
        true
    );
    PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_viewer::text, true);

    v_result := public.request_view_session();
    IF v_result IS NULL OR (v_result->>'featured_rank')::integer <> 3 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: expected rank 3 after self and ineligible rank 2, got %', v_result;
    END IF;

    v_session_id := (v_result->>'id')::uuid;
    IF (SELECT owner_id FROM public.campaigns WHERE id = (v_result->>'campaign_id')::uuid)
       IS DISTINCT FROM v_rank_owners[2] THEN
        RAISE EXCEPTION 'SESSION2_FAIL: self-view or rank-2 campaign was selected';
    END IF;

    SELECT count(*) INTO v_assignment_count
    FROM private.daily_featured_campaign_assignment
    WHERE viewer_id = v_viewer AND day_utc = v_day_utc;

    IF v_assignment_count <> 1 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: first request did not create exactly one audit row';
    END IF;

    SELECT next_request_position INTO v_request_position
    FROM private.daily_featured_viewer_cursor
    WHERE viewer_id = v_viewer AND day_utc = v_day_utc;

    IF v_request_position <> 2 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: cursor did not advance exactly once: %', v_request_position;
    END IF;

    v_retry := public.request_view_session();
    v_retry_session_id := (v_retry->>'id')::uuid;

    IF v_retry_session_id IS DISTINCT FROM v_session_id THEN
        RAISE EXCEPTION 'SESSION2_FAIL: request retry created a duplicate active Session';
    END IF;

    IF (SELECT next_request_position FROM private.daily_featured_viewer_cursor
        WHERE viewer_id = v_viewer AND day_utc = v_day_utc) <> 2 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: active Session retry consumed another cursor position';
    END IF;

    -- A late content-ready signal must expire the Session and release its
    -- featured reservation; it must not start a reward timer after the TTL.
    UPDATE public.view_sessions
    SET started_at = pg_catalog.clock_timestamp() - INTERVAL '4 minutes'
    WHERE id = v_session_id;

    v_signal := public.signal_content_ready(v_session_id);
    IF v_signal IS TRUE THEN
        RAISE EXCEPTION 'SESSION2_FAIL: expired Session accepted content-ready';
    END IF;

    IF (SELECT status FROM public.view_sessions WHERE id = v_session_id) <> 'EXPIRED' THEN
        RAISE EXCEPTION 'SESSION2_FAIL: expired Session status was not persisted';
    END IF;

    SELECT reservation_status INTO v_assignment_status
    FROM private.daily_featured_campaign_assignment
    WHERE session_id = v_session_id;

    IF v_assignment_status <> 'EXPIRED' THEN
        RAISE EXCEPTION 'SESSION2_FAIL: expired Session reservation was not released: %', v_assignment_status;
    END IF;
    PERFORM pg_temp.restore_s2_daily_ranking(v_day_utc);

    -- The next actual allocation starts after the last successfully selected
    -- owner, not at rank 1 or at the rank that lacked a campaign.
    v_result := public.request_view_session();
    IF v_result IS NULL OR (v_result->>'featured_rank')::integer <> 4 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: next eligible rank was not 4: %', v_result;
    END IF;
    v_session_id := (v_result->>'id')::uuid;
    IF NOT public.cancel_view_session(v_session_id) THEN
        RAISE EXCEPTION 'SESSION2_FAIL: cancel_view_session did not cancel the active Session';
    END IF;

    SELECT reservation_status INTO v_assignment_status
    FROM private.daily_featured_campaign_assignment WHERE session_id = v_session_id;
    IF v_assignment_status <> 'RELEASED' THEN
        RAISE EXCEPTION 'SESSION2_FAIL: canceled reservation state is %', v_assignment_status;
    END IF;
    PERFORM pg_temp.restore_s2_daily_ranking(v_day_utc);

    v_result := public.request_view_session();
    IF v_result IS NULL OR (v_result->>'featured_rank')::integer <> 5 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: rank 5 was not considered after rank 4: %', v_result;
    END IF;
    v_session_id := (v_result->>'id')::uuid;
    PERFORM public.cancel_view_session(v_session_id);
    PERFORM pg_temp.restore_s2_daily_ranking(v_day_utc);

    v_result := public.request_view_session();
    IF v_result IS NULL OR (v_result->>'featured_rank')::integer <> 6 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: rank 6 was excluded from daily allocation: %', v_result;
    END IF;
    v_session_id := (v_result->>'id')::uuid;
    PERFORM public.cancel_view_session(v_session_id);
    PERFORM pg_temp.restore_s2_daily_ranking(v_day_utc);

    v_result := public.request_view_session();
    IF v_result IS NULL OR (v_result->>'featured_rank')::integer <> 7 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: rank 7 was excluded from daily allocation: %', v_result;
    END IF;
    v_session_id := (v_result->>'id')::uuid;
    PERFORM public.cancel_view_session(v_session_id);
    PERFORM pg_temp.restore_s2_daily_ranking(v_day_utc);

    -- Rank 8 has no eligible campaign. Once all ranks are examined the cursor is
    -- exhausted and normal distribution returns a Session without featured_rank.
    v_result := public.request_view_session();
    IF v_result IS NULL OR v_result->>'featured_rank' IS NOT NULL THEN
        RAISE EXCEPTION 'SESSION2_FAIL: ranked exhaustion did not use normal fallback: %', v_result;
    END IF;
    v_session_id := (v_result->>'id')::uuid;

    IF (SELECT exhausted FROM private.daily_featured_viewer_cursor
        WHERE viewer_id = v_viewer AND day_utc = v_day_utc) IS NOT TRUE THEN
        RAISE EXCEPTION 'SESSION2_FAIL: ranked exhaustion was not persisted for the UTC day';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM private.daily_featured_campaign_assignment
        WHERE viewer_id = v_viewer
          AND day_utc = v_day_utc
          AND owner_id = v_viewer
    ) THEN
        RAISE EXCEPTION 'SESSION2_FAIL: self-view audit assignment exists';
    END IF;

    IF (SELECT count(*) FROM private.daily_featured_campaign_assignment
        WHERE viewer_id = v_viewer AND day_utc = v_day_utc) <> 5 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: expected five distinct ranked assignments';
    END IF;

    PERFORM public.cancel_view_session(v_session_id);

    -- Capacity and completion idempotency use one remaining active campaign.
    UPDATE public.campaigns
    SET status = 'PAUSED'
    WHERE id IN (SELECT campaign_id FROM _s2_campaigns);

    v_domain := 's2-' || v_tag || '-capacity.example.com';
    v_url := 'https://' || v_domain || '/';
    v_token := 's2-token-' || v_tag || '-capacity';
    v_token_hash := pg_catalog.encode(extensions.digest(v_token, 'sha256'), 'hex');

    INSERT INTO private.campaign_preflight_tokens(
        token_hash, user_id, source_url, normalized_url, domain, final_url,
        http_status, redirect_count, response_ms, content_type, content_length,
        viewer_compatibility, quality_score, diagnostics, created_at,
        expires_at, consumed_at
    ) VALUES (
        v_token_hash, v_cap_owner, v_url, v_url, v_domain, v_url,
        200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
        pg_catalog.jsonb_build_object('referral_site_key', v_domain),
        pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp() + INTERVAL '10 minutes',
        pg_catalog.clock_timestamp()
    );

    INSERT INTO public.campaigns(
        owner_id, url, normalized_url, domain, duration_seconds,
        target_views, completed_views, cost_per_view, total_budget,
        spent_budget, reserved_budget, refunded_budget, status,
        created_at, updated_at
    ) VALUES (
        v_cap_owner, v_url, v_url, v_domain, 5,
        1, 0, 5, 5, 0, 5, 0, 'ACTIVE',
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    RETURNING id INTO v_campaign_id;

    INSERT INTO _s2_campaigns(owner_id, campaign_id, rank, purpose, domain)
    VALUES (v_cap_owner, v_campaign_id, 3, 'capacity', v_domain);

    TRUNCATE _s2_rank_fixture;
    INSERT INTO _s2_rank_fixture(user_id, completed_views)
    VALUES (v_cap_viewer_a, 1200), (v_cap_viewer_b, 1100), (v_cap_owner, 1000);
    PERFORM pg_temp.restore_s2_daily_ranking(v_day_utc);

    PERFORM pg_catalog.set_config(
        'request.jwt.claims',
        pg_catalog.jsonb_build_object(
            'sub', v_cap_viewer_a::text, 'role', 'authenticated', 'is_anonymous', false
        )::text,
        true
    );
    PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_cap_viewer_a::text, true);

    v_result := public.request_view_session();
    IF v_result IS NULL OR (v_result->>'featured_rank')::integer <> 3 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: capacity fixture did not reserve the rank-3 campaign: %', v_result;
    END IF;
    v_session_id := (v_result->>'id')::uuid;
    PERFORM pg_temp.restore_s2_daily_ranking(v_day_utc);

    PERFORM pg_catalog.set_config(
        'request.jwt.claims',
        pg_catalog.jsonb_build_object(
            'sub', v_cap_viewer_b::text, 'role', 'authenticated', 'is_anonymous', false
        )::text,
        true
    );
    PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_cap_viewer_b::text, true);

    v_result := public.request_view_session();
    IF v_result IS NOT NULL THEN
        RAISE EXCEPTION 'SESSION2_FAIL: a second viewer reserved an exhausted one-view campaign: %', v_result;
    END IF;

    SELECT pg_catalog.count(*)::integer INTO v_active_count
    FROM public.view_sessions
    WHERE campaign_id = v_campaign_id
      AND status IN ('INITIALIZED', 'CONTENT_READY')
      AND started_at > pg_catalog.clock_timestamp() - INTERVAL '3 minutes';

    IF v_active_count <> 1 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: expected one reservation for target=1, got %', v_active_count;
    END IF;

    -- Complete exactly once; a retry with the same idempotency key must not
    -- spend another unit of campaign budget or mint another reward.
    PERFORM pg_catalog.set_config(
        'request.jwt.claims',
        pg_catalog.jsonb_build_object(
            'sub', v_cap_viewer_a::text, 'role', 'authenticated', 'is_anonymous', false
        )::text,
        true
    );
    PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_cap_viewer_a::text, true);

    IF NOT public.signal_content_ready(v_session_id) THEN
        RAISE EXCEPTION 'SESSION2_FAIL: content-ready was not accepted for fresh Session';
    END IF;

    UPDATE public.view_sessions
    SET content_ready_at = pg_catalog.clock_timestamp() - INTERVAL '6 seconds'
    WHERE id = v_session_id;

    SELECT available_coins INTO v_available_before
    FROM public.profiles WHERE id = v_cap_viewer_a;

    v_idempotency_key := 's2-complete-' || v_tag || '-' || v_session_id::text;
    v_completion := public.complete_view_session(v_session_id, v_idempotency_key);

    IF COALESCE((v_completion->>'success')::boolean, false) IS NOT TRUE
       OR COALESCE((v_completion->>'already_completed')::boolean, false) IS TRUE THEN
        RAISE EXCEPTION 'SESSION2_FAIL: first completion did not succeed exactly once: %', v_completion;
    END IF;

    v_completion_retry := public.complete_view_session(v_session_id, v_idempotency_key);
    IF COALESCE((v_completion_retry->>'success')::boolean, false) IS NOT TRUE
       OR COALESCE((v_completion_retry->>'already_completed')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'SESSION2_FAIL: completed Session retry was not idempotent: %', v_completion_retry;
    END IF;

    SELECT available_coins INTO v_available_after
    FROM public.profiles WHERE id = v_cap_viewer_a;

    SELECT completed_views INTO v_completed_count
    FROM public.campaigns WHERE id = v_campaign_id;

    IF v_available_after <> v_available_before + 3 OR v_completed_count <> 1 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: reward/campaign completion count mismatch';
    END IF;

    IF (SELECT count(*) FROM public.coin_ledger
        WHERE user_id = v_cap_viewer_a
          AND transaction_type = 'VIEW_REWARD'
          AND idempotency_key = v_idempotency_key) <> 1 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: repeated completion minted more than one reward';
    END IF;

    SELECT reservation_status INTO v_assignment_status
    FROM private.daily_featured_campaign_assignment
    WHERE session_id = v_session_id;

    IF v_assignment_status <> 'COMPLETED' THEN
        RAISE EXCEPTION 'SESSION2_FAIL: completion did not settle assignment state: %', v_assignment_status;
    END IF;

    IF (SELECT pg_catalog.count(*) FROM public.view_sessions
        WHERE campaign_id = v_campaign_id AND status = 'COMPLETED') <> 1 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: completed Session/campaign accounting is not one-to-one';
    END IF;

    -- A stale CONTENT_READY Session must be expired by the completion RPC before
    -- the financial path can run. The assignment trigger must release its slot.
    v_domain := 's2-' || v_tag || '-ttl.example.com';
    v_url := 'https://' || v_domain || '/';
    v_token := 's2-token-' || v_tag || '-ttl';
    v_token_hash := pg_catalog.encode(extensions.digest(v_token, 'sha256'), 'hex');

    INSERT INTO private.campaign_preflight_tokens(
        token_hash, user_id, source_url, normalized_url, domain, final_url,
        http_status, redirect_count, response_ms, content_type, content_length,
        viewer_compatibility, quality_score, diagnostics, created_at,
        expires_at, consumed_at
    ) VALUES (
        v_token_hash, v_ttl_owner, v_url, v_url, v_domain, v_url,
        200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
        pg_catalog.jsonb_build_object('referral_site_key', v_domain),
        pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp() + INTERVAL '10 minutes',
        pg_catalog.clock_timestamp()
    );

    INSERT INTO public.campaigns(
        owner_id, url, normalized_url, domain, duration_seconds,
        target_views, completed_views, cost_per_view, total_budget,
        spent_budget, reserved_budget, refunded_budget, status,
        created_at, updated_at
    ) VALUES (
        v_ttl_owner, v_url, v_url, v_domain, 5,
        2, 0, 5, 10, 0, 10, 0, 'ACTIVE',
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    RETURNING id INTO v_campaign_id;

    TRUNCATE _s2_rank_fixture;
    INSERT INTO _s2_rank_fixture(user_id, completed_views)
    VALUES (v_ttl_viewer, 2000), (v_ttl_owner, 1900);
    PERFORM pg_temp.restore_s2_daily_ranking(v_day_utc);

    PERFORM pg_catalog.set_config(
        'request.jwt.claims',
        pg_catalog.jsonb_build_object(
            'sub', v_ttl_viewer::text, 'role', 'authenticated', 'is_anonymous', false
        )::text,
        true
    );
    PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_ttl_viewer::text, true);

    v_result := public.request_view_session();
    IF v_result IS NULL OR (v_result->>'featured_rank')::integer <> 2 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: TTL fixture did not receive its rank-2 campaign: %', v_result;
    END IF;
    v_session_id := (v_result->>'id')::uuid;

    IF NOT public.signal_content_ready(v_session_id) THEN
        RAISE EXCEPTION 'SESSION2_FAIL: fresh TTL test Session did not become content-ready';
    END IF;

    UPDATE public.view_sessions
    SET started_at = pg_catalog.clock_timestamp() - INTERVAL '4 minutes',
        content_ready_at = pg_catalog.clock_timestamp() - INTERVAL '10 seconds'
    WHERE id = v_session_id;

    v_idempotency_key := 's2-expired-complete-' || v_tag || '-' || v_session_id::text;
    v_completion := public.complete_view_session(v_session_id, v_idempotency_key);

    IF COALESCE((v_completion->>'success')::boolean, true) IS NOT FALSE
       OR v_completion->>'error_code' <> 'SESSION_EXPIRED' THEN
        RAISE EXCEPTION 'SESSION2_FAIL: stale completion did not fail closed: %', v_completion;
    END IF;

    IF (SELECT status FROM public.view_sessions WHERE id = v_session_id) <> 'EXPIRED' THEN
        RAISE EXCEPTION 'SESSION2_FAIL: stale completion did not persist EXPIRED state';
    END IF;

    SELECT reservation_status INTO v_assignment_status
    FROM private.daily_featured_campaign_assignment
    WHERE session_id = v_session_id;

    IF v_assignment_status <> 'EXPIRED' THEN
        RAISE EXCEPTION 'SESSION2_FAIL: stale completion did not release its reservation';
    END IF;

    -- Exact rolling-30-day projection: 31-day-old completions are excluded,
    -- 29-day-old completions are included; reversing a completion removes it.
    INSERT INTO public.view_sessions(
        campaign_id, viewer_id, required_duration_seconds, reward_coins,
        status, started_at, content_ready_at, completed_at, created_at
    )
    SELECT
        (SELECT campaign_id FROM _s2_campaigns WHERE purpose = 'fallback' LIMIT 1),
        v_rolling_viewer, 5, 3,
        'COMPLETED',
        pg_catalog.clock_timestamp() - INTERVAL '31 days',
        pg_catalog.clock_timestamp() - INTERVAL '31 days' + INTERVAL '1 second',
        pg_catalog.clock_timestamp() - INTERVAL '31 days',
        pg_catalog.clock_timestamp() - INTERVAL '31 days'
    UNION ALL
    SELECT
        (SELECT campaign_id FROM _s2_campaigns WHERE purpose = 'fallback' LIMIT 1),
        v_rolling_viewer, 5, 3,
        'COMPLETED',
        pg_catalog.clock_timestamp() - INTERVAL '29 days',
        pg_catalog.clock_timestamp() - INTERVAL '29 days' + INTERVAL '1 second',
        pg_catalog.clock_timestamp() - INTERVAL '29 days',
        pg_catalog.clock_timestamp() - INTERVAL '29 days';

    SELECT completed_views INTO v_rolling_count
    FROM public.rolling_30d_view_leaderboard_public
    WHERE user_handle = (SELECT user_handle FROM public.profiles WHERE id = v_rolling_viewer);

    IF v_rolling_count IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: Rolling30 included an out-of-window row or missed an in-window row: %', v_rolling_count;
    END IF;

    UPDATE public.view_sessions
    SET status = 'CANCELLED'
    WHERE viewer_id = v_rolling_viewer
      AND status = 'COMPLETED'
      AND completed_at < pg_catalog.clock_timestamp() - INTERVAL '28 days';

    IF EXISTS (
        SELECT 1 FROM public.rolling_30d_view_leaderboard_public
        WHERE user_handle = (SELECT user_handle FROM public.profiles WHERE id = v_rolling_viewer)
    ) THEN
        RAISE EXCEPTION 'SESSION2_FAIL: reversing a completed Session did not remove its Rolling30 event';
    END IF;

    -- UTC day boundary: one completion at 23:59:59 belongs to the previous
    -- UTC date and one at 00:00:01 belongs to the next date.
    v_boundary_before := ((v_boundary_day::timestamp + TIME '23:59:59') AT TIME ZONE 'UTC');
    v_boundary_after := (((v_boundary_day + 1)::timestamp + TIME '00:00:01') AT TIME ZONE 'UTC');

    INSERT INTO public.view_sessions(
        campaign_id, viewer_id, required_duration_seconds, reward_coins,
        status, started_at, content_ready_at, completed_at, created_at
    )
    SELECT
        (SELECT campaign_id FROM _s2_campaigns WHERE purpose = 'fallback' LIMIT 1),
        v_boundary_viewer, 5, 3,
        'COMPLETED',
        v_boundary_before - INTERVAL '5 seconds',
        v_boundary_before - INTERVAL '4 seconds',
        v_boundary_before,
        v_boundary_before
    UNION ALL
    SELECT
        (SELECT campaign_id FROM _s2_campaigns WHERE purpose = 'fallback' LIMIT 1),
        v_boundary_viewer, 5, 3,
        'COMPLETED',
        v_boundary_after - INTERVAL '5 seconds',
        v_boundary_after - INTERVAL '4 seconds',
        v_boundary_after,
        v_boundary_after;

    SELECT completed_views INTO v_daily_before
    FROM public.daily_view_leaderboard
    WHERE leaderboard_date = v_boundary_day AND user_id = v_boundary_viewer;

    SELECT completed_views INTO v_daily_after
    FROM public.daily_view_leaderboard
    WHERE leaderboard_date = v_boundary_day + 1 AND user_id = v_boundary_viewer;

    IF v_daily_before IS DISTINCT FROM 1 OR v_daily_after IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: UTC boundary daily counts are wrong: previous %, current %',
            v_daily_before, v_daily_after;
    END IF;

    IF (
        SELECT pg_catalog.count(*)
        FROM public.view_sessions
        WHERE viewer_id = v_boundary_viewer
          AND status = 'COMPLETED'
          AND completed_at >= (v_boundary_day::timestamp AT TIME ZONE 'UTC')
          AND completed_at < ((v_boundary_day + 1)::timestamp AT TIME ZONE 'UTC')
    ) <> v_daily_before THEN
        RAISE EXCEPTION 'SESSION2_FAIL: daily leaderboard does not reconcile to completed Sessions';
    END IF;

    -- Stable tie ordering: equal daily scores must use the unique user_handle as
    -- a deterministic secondary key, without exposing private Auth user IDs.
    v_boundary_day := v_day_utc;
    INSERT INTO public.view_sessions(
        campaign_id, viewer_id, required_duration_seconds, reward_coins,
        status, started_at, content_ready_at, completed_at, created_at
    )
    SELECT
        (SELECT campaign_id FROM _s2_campaigns WHERE purpose = 'fallback' LIMIT 1),
        v_tie_a, 5, 3,
        'COMPLETED',
        pg_catalog.clock_timestamp() - INTERVAL '10 seconds',
        pg_catalog.clock_timestamp() - INTERVAL '9 seconds',
        pg_catalog.clock_timestamp() - INTERVAL '1 second',
        pg_catalog.clock_timestamp() - INTERVAL '1 second'
    FROM public.profiles p WHERE p.id = v_tie_a
    UNION ALL
    SELECT
        (SELECT campaign_id FROM _s2_campaigns WHERE purpose = 'fallback' LIMIT 1),
        v_tie_b, 5, 3,
        'COMPLETED',
        pg_catalog.clock_timestamp() - INTERVAL '10 seconds',
        pg_catalog.clock_timestamp() - INTERVAL '9 seconds',
        pg_catalog.clock_timestamp() - INTERVAL '1 second',
        pg_catalog.clock_timestamp() - INTERVAL '1 second';

    SELECT rank INTO v_tie_rank_a
    FROM public.daily_view_leaderboard_public
    WHERE leaderboard_date = v_day_utc
      AND user_handle = (SELECT user_handle FROM public.profiles WHERE id = v_tie_a);

    SELECT rank INTO v_tie_rank_b
    FROM public.daily_view_leaderboard_public
    WHERE leaderboard_date = v_day_utc
      AND user_handle = (SELECT user_handle FROM public.profiles WHERE id = v_tie_b);

    IF v_tie_rank_a IS NULL OR v_tie_rank_b IS NULL
       OR v_tie_rank_a >= v_tie_rank_b THEN
        RAISE EXCEPTION 'SESSION2_FAIL: equal daily scores are not ordered deterministically by handle: %, %',
            v_tie_rank_a, v_tie_rank_b;
    END IF;

    -- Private allocation state is inaccessible to client roles; only the
    -- authenticated read-only leaderboard projection is exposed.
    IF has_table_privilege('anon', 'private.daily_featured_viewer_cursor', 'SELECT')
       OR has_table_privilege('authenticated', 'private.daily_featured_viewer_cursor', 'SELECT')
       OR has_table_privilege('anon', 'private.daily_featured_campaign_assignment', 'SELECT')
       OR has_table_privilege('authenticated', 'private.daily_featured_campaign_assignment', 'SELECT') THEN
        RAISE EXCEPTION 'SESSION2_FAIL: private cursor or assignment table is directly readable';
    END IF;

    IF has_function_privilege('anon', 'public.request_view_session()', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.request_view_session()', 'EXECUTE') THEN
        RAISE EXCEPTION 'SESSION2_FAIL: request_view_session grants are incorrect';
    END IF;

    IF has_table_privilege('anon', 'public.rolling_30d_view_leaderboard_public', 'SELECT')
       OR NOT has_table_privilege('authenticated', 'public.rolling_30d_view_leaderboard_public', 'SELECT') THEN
        RAISE EXCEPTION 'SESSION2_FAIL: Rolling30 view grants are incorrect';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'rolling_30d_view_leaderboard_public'
          AND 'security_invoker=true' = ANY(COALESCE(c.reloptions, ARRAY[]::text[]))
    ) THEN
        RAISE EXCEPTION 'SESSION2_FAIL: Rolling30 view is not SECURITY INVOKER';
    END IF;

    RAISE NOTICE 'PASS: Session 2 sequential allocation, all-rank scan, fallback, TTL, capacity, completion idempotency, Rolling30, UTC daily boundary, tie order and RLS';
END;
$test$;

-- Exercise both invoker-mode public views as the actual authenticated role.
SET LOCAL ROLE authenticated;
DO $invoker_test$
DECLARE
    v_count bigint;
BEGIN
    SELECT pg_catalog.count(*) INTO v_count
    FROM public.rolling_30d_view_leaderboard_public;
    IF v_count < 0 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: authenticated Rolling30 view read failed';
    END IF;

    SELECT pg_catalog.count(*) INTO v_count
    FROM public.daily_view_leaderboard_public;
    IF v_count < 0 THEN
        RAISE EXCEPTION 'SESSION2_FAIL: authenticated daily view read failed';
    END IF;
END;
$invoker_test$;
RESET ROLE;

ROLLBACK;
