-- Regression test for the ordinary campaign distribution fallback.
-- Uses only isolated fixtures; no existing account or Production campaign is read.

BEGIN;

DO $test$
DECLARE
    v_tag text := substr(md5(clock_timestamp()::text || random()::text), 1, 10);
    v_viewer uuid := gen_random_uuid();
    v_owners uuid[] := ARRAY[
        gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
    ];
    v_all_users uuid[];
    v_url text;
    v_domain text;
    v_token text;
    v_token_hash text;
    v_campaign_id uuid;
    v_first json;
    v_second json;
    v_first_session uuid;
    v_second_session uuid;
    v_first_owner uuid;
    v_second_owner uuid;
    i integer;
BEGIN
    v_all_users := ARRAY[v_viewer] || v_owners;

    INSERT INTO auth.users(
        id, aud, role, email, email_confirmed_at,
        created_at, updated_at, is_sso_user, is_anonymous
    )
    SELECT
        u, 'authenticated', 'authenticated',
        'sitebin_distribution_' || replace(u::text,'-','') || '@sitebin.internal',
        clock_timestamp(), clock_timestamp(), clock_timestamp(), false, false
    FROM unnest(v_all_users) AS users(u);

    INSERT INTO public.profiles(
        id, user_handle, app_install_id, available_coins, reserved_coins,
        lifetime_earned, lifetime_spent, trust_score, completed_views_count,
        received_views_count, welcome_bonus_claimed, created_at, updated_at
    )
    SELECT
        u,
        'dist_' || substr(replace(u::text,'-',''),1,12),
        'dist_inst_' || substr(replace(u::text,'-',''),1,12),
        10000, 10000, 10000, 0, 100, 0, 0, true,
        clock_timestamp(), clock_timestamp()
    FROM unnest(v_all_users) AS users(u);

    FOR i IN 1..4 LOOP
        v_domain := 'dist-' || v_tag || '-' || i::text || '.example.com';
        v_url := 'https://' || v_domain || '/';
        v_token := 'dist-token-' || v_tag || '-' || i::text;
        v_token_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');

        INSERT INTO private.campaign_preflight_tokens(
            token_hash, user_id, source_url, normalized_url, domain, final_url,
            http_status, redirect_count, response_ms, content_type, content_length,
            viewer_compatibility, quality_score, diagnostics, created_at,
            expires_at, consumed_at
        )
        VALUES(
            v_token_hash, v_owners[i], v_url, v_url, v_domain, v_url,
            200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
            jsonb_build_object('referral_site_key', v_domain),
            clock_timestamp(), clock_timestamp() + INTERVAL '10 minutes',
            clock_timestamp()
        );

        INSERT INTO public.campaigns(
            owner_id, url, normalized_url, domain, duration_seconds,
            target_views, completed_views, cost_per_view, total_budget,
            spent_budget, reserved_budget, refunded_budget, status,
            created_at, updated_at
        )
        VALUES(
            v_owners[i], v_url, v_url, v_domain, 5,
            20, 0, 5, 100, 0, 100, 0, 'ACTIVE',
            clock_timestamp(), clock_timestamp()
        );
    END LOOP;

    PERFORM set_config(
        'request.jwt.claims',
        json_build_object('sub',v_viewer::text,'role','authenticated','is_anonymous',false)::text,
        true
    );
    PERFORM set_config('request.jwt.claim.sub', v_viewer::text, true);

    -- There are no daily leaderboard rows for this new viewer, so the initial
    -- allocation must use the ordinary path and carry no featured rank.
    v_first := public.request_view_session();
    IF v_first IS NULL OR v_first->>'featured_rank' IS NOT NULL THEN
        RAISE EXCEPTION 'DISTRIBUTION_FAIL: initial ordinary fallback returned a featured Session: %', v_first;
    END IF;

    v_first_session := (v_first->>'id')::uuid;
    SELECT owner_id INTO v_first_owner
    FROM public.campaigns
    WHERE id = (v_first->>'campaign_id')::uuid;

    IF NOT public.cancel_view_session(v_first_session) THEN
        RAISE EXCEPTION 'DISTRIBUTION_FAIL: first fallback Session could not be canceled';
    END IF;

    -- A recent completed advertiser is deprioritized while another eligible
    -- advertiser exists; the fallback should continue to an alternative owner.
    INSERT INTO public.view_sessions(
        campaign_id, viewer_id, required_duration_seconds, reward_coins,
        status, started_at, content_ready_at, completed_at, created_at
    )
    VALUES(
        (v_first->>'campaign_id')::uuid, v_viewer, 5, 3,
        'COMPLETED',
        clock_timestamp() - INTERVAL '60 seconds',
        clock_timestamp() - INTERVAL '55 seconds',
        clock_timestamp() - INTERVAL '30 seconds',
        clock_timestamp() - INTERVAL '30 seconds'
    );

    v_second := public.request_view_session();
    IF v_second IS NULL OR v_second->>'featured_rank' IS NOT NULL THEN
        RAISE EXCEPTION 'DISTRIBUTION_FAIL: second fallback did not return a normal Session: %', v_second;
    END IF;

    v_second_session := (v_second->>'id')::uuid;
    SELECT owner_id INTO v_second_owner
    FROM public.campaigns
    WHERE id = (v_second->>'campaign_id')::uuid;

    IF v_second_owner = v_first_owner THEN
        RAISE EXCEPTION 'DISTRIBUTION_FAIL: recent advertiser was selected despite other eligible inventory';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM private.daily_featured_campaign_assignment
        WHERE session_id IN (v_first_session, v_second_session)
    ) THEN
        RAISE EXCEPTION 'DISTRIBUTION_FAIL: ordinary fallback was incorrectly audited as featured';
    END IF;

    PERFORM public.cancel_view_session(v_second_session);

    RAISE NOTICE 'PASS: normal fallback stays non-featured and respects the recent-advertiser diversity pass';
END;
$test$;

ROLLBACK;
