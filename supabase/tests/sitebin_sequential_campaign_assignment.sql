-- SiteBin sequential daily assignment regression tests.
-- Runs against real local PostgreSQL; all fixtures and mutations roll back.

BEGIN;

DO $test$
DECLARE
    v_viewer UUID := '10000000-0000-0000-0000-000000000001';
    v_move_viewer UUID := '50000000-0000-0000-0000-000000000001';
    v_owners UUID[] := ARRAY[
        '20000000-0000-0000-0000-000000000001'::UUID,
        '20000000-0000-0000-0000-000000000002'::UUID,
        '20000000-0000-0000-0000-000000000003'::UUID,
        '20000000-0000-0000-0000-000000000004'::UUID,
        '20000000-0000-0000-0000-000000000005'::UUID,
        '20000000-0000-0000-0000-000000000006'::UUID,
        '20000000-0000-0000-0000-000000000007'::UUID
    ];
    v_fallback_owner UUID := '30000000-0000-0000-0000-000000000001';
    v_rebind_old UUID := '40000000-0000-0000-0000-000000000001';
    v_rebind_new UUID := '40000000-0000-0000-0000-000000000002';
    v_all_users UUID[];
    v_profile_users UUID[];
    v_ranked_users UUID[];
    v_day DATE := (pg_catalog.clock_timestamp() AT TIME ZONE 'UTC')::DATE;
    v_uid UUID;
    v_handle TEXT;
    v_score INTEGER;
    v_domain TEXT;
    v_url TEXT;
    v_token_hash TEXT;
    v_result JSON;
    v_retry_result JSON;
    v_complete JSON;
    v_complete_retry JSON;
    v_session_id UUID;
    v_campaign_id UUID;
    v_owner_id UUID;
    v_expected_owner UUID;
    v_owner_rank INTEGER;
    v_assignment_type TEXT;
    v_assigned_position BIGINT;
    v_canceled BOOLEAN;
    v_completed BOOLEAN;
    v_signal_ready BOOLEAN;
    v_status TEXT;
    v_request_position BIGINT;
    v_cursor public.viewer_daily_cursor%ROWTYPE;
    v_before_views INTEGER;
    v_after_views INTEGER;
    v_before_daily INTEGER;
    v_after_daily INTEGER;
    v_rolling_count INTEGER;
    v_boundary_previous TIMESTAMPTZ;
    v_boundary_current TIMESTAMPTZ;
    v_completed_owner UUID;
    v_reloptions TEXT[];
    v_weekly_reloptions TEXT[];
    v_view_definition TEXT;
    v_rebind_campaign UUID;
    v_rebind_session UUID;
    i INTEGER;
BEGIN
    v_all_users := ARRAY[v_viewer, v_move_viewer] || v_owners || ARRAY[v_fallback_owner, v_rebind_old, v_rebind_new];
    v_profile_users := ARRAY[v_viewer, v_move_viewer] || v_owners || ARRAY[v_fallback_owner, v_rebind_old];
    v_ranked_users := ARRAY[v_viewer] || v_owners;

    INSERT INTO auth.users (
        id, aud, role, email, email_confirmed_at,
        created_at, updated_at, is_sso_user, is_anonymous
    )
    SELECT
        u,
        'authenticated',
        'authenticated',
        'seq_' || pg_catalog.replace(u::TEXT, '-', '') || '@sitebin.internal',
        pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp(),
        FALSE,
        FALSE
    FROM pg_catalog.unnest(v_all_users) AS users(u);

    INSERT INTO public.profiles (
        id, user_handle, app_install_id, available_coins, reserved_coins,
        lifetime_earned, lifetime_spent, trust_score, completed_views_count,
        received_views_count, welcome_bonus_claimed, created_at, updated_at
    )
    SELECT
        u,
        'seq_' || (pg_catalog.substr(pg_catalog.replace(u::TEXT, '-', ''), 1, 8) || pg_catalog.substr(pg_catalog.replace(u::TEXT, '-', ''), 29, 4)),
        'seq_inst_' || (pg_catalog.substr(pg_catalog.replace(u::TEXT, '-', ''), 1, 8) || pg_catalog.substr(pg_catalog.replace(u::TEXT, '-', ''), 29, 4)),
        10000,
        1000,
        10000,
        0,
        100.0,
        0,
        0,
        TRUE,
        pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp()
    FROM pg_catalog.unnest(v_profile_users) AS users(u);

    -- Owner 1 (rank 2) intentionally has no campaign; owners 2..7 are eligible.
    FOR i IN 2..7 LOOP
        v_domain := 'seq-owner-' || i::TEXT || '.example.com';
        v_url := 'https://' || v_domain || '/';
        INSERT INTO private.campaign_preflight_tokens (
            token_hash, user_id, source_url, normalized_url, domain, final_url,
            http_status, redirect_count, response_ms, content_type, content_length,
            viewer_compatibility, quality_score, diagnostics, created_at, expires_at, consumed_at
        )
        VALUES (
            pg_catalog.md5(v_owners[i]::TEXT || v_url) || pg_catalog.md5(v_url || v_owners[i]::TEXT),
            v_owners[i], v_url, v_url, v_domain, v_url,
            200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
            pg_catalog.jsonb_build_object('referral_site_key', v_domain),
            pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp() + INTERVAL '10 minutes',
            pg_catalog.clock_timestamp()
        );

        INSERT INTO public.campaigns (
            owner_id, url, normalized_url, domain, duration_seconds,
            target_views, completed_views, cost_per_view, total_budget,
            spent_budget, reserved_budget, refunded_budget, status,
            created_at, updated_at
        )
        VALUES (
            v_owners[i],
            'https://' || v_domain || '/',
            'https://' || v_domain || '/',
            v_domain,
            5, 20, 0, 5, 100, 0, 100, 0, 'ACTIVE',
            pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
        );
    END LOOP;

    -- Self-owned inventory must never be selected by its owner.
    v_domain := 'seq-self.example.com';
    v_url := 'https://' || v_domain || '/';
    INSERT INTO private.campaign_preflight_tokens (
        token_hash, user_id, source_url, normalized_url, domain, final_url,
        http_status, redirect_count, response_ms, content_type, content_length,
        viewer_compatibility, quality_score, diagnostics, created_at, expires_at, consumed_at
    )
    VALUES (
        pg_catalog.md5(v_viewer::TEXT || v_url) || pg_catalog.md5(v_url || v_viewer::TEXT),
        v_viewer, v_url, v_url, v_domain, v_url,
        200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
        pg_catalog.jsonb_build_object('referral_site_key', v_domain),
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp() + INTERVAL '10 minutes',
        pg_catalog.clock_timestamp()
    );

    INSERT INTO public.campaigns (
        owner_id, url, normalized_url, domain, duration_seconds,
        target_views, completed_views, cost_per_view, total_budget,
        spent_budget, reserved_budget, refunded_budget, status,
        created_at, updated_at
    )
    VALUES (
        v_viewer,
        'https://seq-self.example.com/',
        'https://seq-self.example.com/',
        'seq-self.example.com',
        5, 20, 0, 5, 100, 0, 100, 0, 'ACTIVE',
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    );

    v_domain := 'seq-fallback.example.com';
    v_url := 'https://' || v_domain || '/';
    INSERT INTO private.campaign_preflight_tokens (
        token_hash, user_id, source_url, normalized_url, domain, final_url,
        http_status, redirect_count, response_ms, content_type, content_length,
        viewer_compatibility, quality_score, diagnostics, created_at, expires_at, consumed_at
    )
    VALUES (
        pg_catalog.md5(v_fallback_owner::TEXT || v_url) || pg_catalog.md5(v_url || v_fallback_owner::TEXT),
        v_fallback_owner, v_url, v_url, v_domain, v_url,
        200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
        pg_catalog.jsonb_build_object('referral_site_key', v_domain),
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp() + INTERVAL '10 minutes',
        pg_catalog.clock_timestamp()
    );

    INSERT INTO public.campaigns (
        owner_id, url, normalized_url, domain, duration_seconds,
        target_views, completed_views, cost_per_view, total_budget,
        spent_budget, reserved_budget, refunded_budget, status,
        created_at, updated_at
    )
    VALUES (
        v_fallback_owner,
        'https://seq-fallback.example.com/',
        'https://seq-fallback.example.com/',
        'seq-fallback.example.com',
        5, 20, 0, 5, 100, 0, 100, 0, 'ACTIVE',
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    );

    -- Rolling30 behavior: one completed session is 31 days old and one is 29 days old.
    INSERT INTO public.view_sessions (
        campaign_id, viewer_id, required_duration_seconds, reward_coins,
        status, started_at, created_at, completed_at, expires_at
    ) VALUES
    (
        (SELECT id FROM public.campaigns WHERE domain = 'seq-self.example.com'),
        v_viewer, 5, 3, 'COMPLETED',
        pg_catalog.clock_timestamp() - INTERVAL '31 days',
        pg_catalog.clock_timestamp() - INTERVAL '31 days',
        pg_catalog.clock_timestamp() - INTERVAL '31 days',
        pg_catalog.clock_timestamp() - INTERVAL '31 days' + INTERVAL '3 minutes'
    ),
    (
        (SELECT id FROM public.campaigns WHERE domain = 'seq-fallback.example.com'),
        v_viewer, 5, 3, 'COMPLETED',
        pg_catalog.clock_timestamp() - INTERVAL '29 days',
        pg_catalog.clock_timestamp() - INTERVAL '29 days',
        pg_catalog.clock_timestamp() - INTERVAL '29 days',
        pg_catalog.clock_timestamp() - INTERVAL '29 days' + INTERVAL '3 minutes'
    );

    SELECT completed_views INTO v_rolling_count
    FROM public.weekly_view_leaderboard_public
    WHERE user_handle = (SELECT user_handle FROM public.profiles WHERE id = v_viewer);

    IF v_rolling_count IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: rolling-30 view did not exclude the 31-day-old session';
    END IF;

    -- Eight ranked owners: viewer at rank 1, an ineligible owner at rank 2,
    -- six eligible owners through rank 8. Ranks 7/8 are tied and ordered by user_id.
    FOR i IN 1..8 LOOP
        v_uid := v_ranked_users[i];
        v_handle := (
            SELECT p.user_handle FROM public.profiles p WHERE p.id = v_uid
        );
        v_score := CASE i
            WHEN 1 THEN 1000
            WHEN 2 THEN 900
            WHEN 3 THEN 800
            WHEN 4 THEN 700
            WHEN 5 THEN 600
            WHEN 6 THEN 500
            ELSE 400
        END;

        INSERT INTO public.daily_view_leaderboard (
            leaderboard_date, user_id, user_handle, completed_views, updated_at
        )
        VALUES (v_day, v_uid, v_handle, v_score, pg_catalog.clock_timestamp());
    END LOOP;

    SELECT rank INTO v_owner_rank
    FROM public.daily_view_leaderboard_public
    WHERE user_handle = (SELECT user_handle FROM public.profiles WHERE id = v_owners[6]);
    IF v_owner_rank IS DISTINCT FROM 7 THEN
        RAISE EXCEPTION 'TEST_FAILED: first tied owner did not receive rank 7';
    END IF;

    SELECT rank INTO v_owner_rank
    FROM public.daily_view_leaderboard_public
    WHERE user_handle = (SELECT user_handle FROM public.profiles WHERE id = v_owners[7]);
    IF v_owner_rank IS DISTINCT FROM 8 THEN
        RAISE EXCEPTION 'TEST_FAILED: second tied owner did not receive rank 8';
    END IF;

    PERFORM pg_catalog.set_config(
        'request.jwt.claims',
        pg_catalog.json_build_object(
            'sub', v_viewer::TEXT,
            'role', 'authenticated',
            'is_anonymous', FALSE
        )::TEXT,
        TRUE
    );

    -- Sequential allocation, self-skip, next_eligible, rank > 5, cursor and cancel.
    FOR i IN 1..6 LOOP
        v_result := public.request_view_session();
        IF v_result IS NULL THEN
            RAISE EXCEPTION 'TEST_FAILED: sequential request % returned NULL', i;
        END IF;

        v_session_id := (v_result->>'id')::UUID;
        v_expected_owner := v_owners[i + 1];

        SELECT c.owner_id
        INTO v_owner_id
        FROM public.campaigns c
        WHERE c.id = (v_result->>'campaign_id')::UUID;

        IF v_owner_id IS DISTINCT FROM v_expected_owner THEN
            RAISE EXCEPTION 'TEST_FAILED: request % selected owner %, expected %',
                i, v_owner_id, v_expected_owner;
        END IF;

        SELECT a.owner_rank, a.assignment_type, a.assigned_position
        INTO v_owner_rank, v_assignment_type, v_assigned_position
        FROM public.special_campaign_assignments a
        WHERE a.session_id = v_session_id;

        IF v_owner_rank IS DISTINCT FROM i + 2
           OR v_assignment_type IS DISTINCT FROM 'featured'
           OR v_assigned_position IS DISTINCT FROM i THEN
            RAISE EXCEPTION 'TEST_FAILED: assignment metadata mismatch at position %', i;
        END IF;

        IF v_owner_id = v_viewer THEN
            RAISE EXCEPTION 'TEST_FAILED: self-view was assigned';
        END IF;

        IF i = 1 THEN
            v_retry_result := public.request_view_session();
            IF (v_retry_result->>'id')::UUID <> v_session_id THEN
                RAISE EXCEPTION 'TEST_FAILED: request retry created a second session';
            END IF;

            SELECT request_position INTO v_request_position
            FROM public.viewer_daily_cursor
            WHERE viewer_id = v_viewer AND day_utc = v_day;

            IF v_request_position IS DISTINCT FROM 1 THEN
                RAISE EXCEPTION 'TEST_FAILED: retry consumed another cursor position';
            END IF;
        END IF;

        IF NOT public.cancel_view_session(v_session_id) THEN
            RAISE EXCEPTION 'TEST_FAILED: cancel_view_session returned false at position %', i;
        END IF;

        SELECT a.canceled
        INTO v_canceled
        FROM public.special_campaign_assignments a
        WHERE a.session_id = v_session_id;

        IF v_canceled IS DISTINCT FROM TRUE THEN
            RAISE EXCEPTION 'TEST_FAILED: cancellation did not release assignment %', v_session_id;
        END IF;
    END LOOP;

    SELECT *
    INTO v_cursor
    FROM public.viewer_daily_cursor
    WHERE viewer_id = v_viewer AND day_utc = v_day;

    IF v_cursor.last_selected_rank IS DISTINCT FROM 8
       OR v_cursor.request_position IS DISTINCT FROM 6
       OR pg_catalog.cardinality(v_cursor.visited_owner_ids) IS DISTINCT FROM 8
       OR v_cursor.exhausted IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'TEST_FAILED: cursor did not preserve sequential high-water state';
    END IF;

    -- All ranked owners have been visited; the next request must use normal fallback.
    v_result := public.request_view_session();
    IF v_result IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: normal fallback returned NULL';
    END IF;
    v_session_id := (v_result->>'id')::UUID;

    SELECT a.assignment_type, a.assigned_position
    INTO v_assignment_type, v_assigned_position
    FROM public.special_campaign_assignments a
    WHERE a.session_id = v_session_id;

    SELECT *
    INTO v_cursor
    FROM public.viewer_daily_cursor
    WHERE viewer_id = v_viewer AND day_utc = v_day;

    IF v_assignment_type IS DISTINCT FROM 'normal'
       OR v_assigned_position IS DISTINCT FROM 7
       OR v_cursor.exhausted IS DISTINCT FROM TRUE
       OR v_cursor.request_position IS DISTINCT FROM 7 THEN
        RAISE EXCEPTION 'TEST_FAILED: exhaustion did not transition to normal fallback';
    END IF;

    -- Expired completion must transition to EXPIRED and cancel its assignment
    -- without changing campaign counters or financial balances.
    SELECT c.id, c.completed_views
    INTO v_campaign_id, v_before_views
    FROM public.campaigns c
    WHERE c.id = (v_result->>'campaign_id')::UUID;

    UPDATE public.view_sessions
    SET content_ready_at = pg_catalog.clock_timestamp() - INTERVAL '10 seconds',
        expires_at = pg_catalog.clock_timestamp() - INTERVAL '1 second',
        status = 'CONTENT_READY'
    WHERE id = v_session_id;

    v_complete := public.complete_view_session(
        v_session_id,
        'seq_expired_' || v_session_id::TEXT
    );

    IF COALESCE((v_complete->>'expired')::BOOLEAN, FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST_FAILED: expired completion was not rejected';
    END IF;

    IF (SELECT status FROM public.view_sessions WHERE id = v_session_id) <> 'EXPIRED'
       OR (SELECT canceled FROM public.special_campaign_assignments WHERE session_id = v_session_id) IS NOT TRUE
       OR (SELECT completed_views FROM public.campaigns WHERE id = v_campaign_id) IS DISTINCT FROM v_before_views THEN
        RAISE EXCEPTION 'TEST_FAILED: TTL did not release capacity without consuming budget';
    END IF;

    -- Expiration must also be enforced when the client signals content-ready.
    v_result := public.request_view_session();
    IF v_result IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: could not allocate content-ready TTL fixture';
    END IF;
    v_session_id := (v_result->>'id')::UUID;
    UPDATE public.view_sessions
    SET expires_at = pg_catalog.clock_timestamp() - INTERVAL '1 second'
    WHERE id = v_session_id;

    v_signal_ready := public.signal_content_ready(v_session_id);
    SELECT status INTO v_status FROM public.view_sessions WHERE id = v_session_id;
    SELECT canceled INTO v_canceled
    FROM public.special_campaign_assignments
    WHERE session_id = v_session_id;

    IF v_signal_ready IS TRUE OR v_status IS DISTINCT FROM 'EXPIRED'
       OR v_canceled IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'TEST_FAILED: expired content-ready signal result=%, status=%, assignment_canceled=%, expires_at=%',
            v_signal_ready,
            v_status,
            v_canceled,
            (SELECT expires_at FROM public.view_sessions WHERE id = v_session_id);
    END IF;

    -- Successful completion is idempotent and updates the daily leaderboard once.
    v_result := public.request_view_session();
    IF v_result IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: fallback request after expiration returned NULL';
    END IF;
    v_session_id := (v_result->>'id')::UUID;
    v_campaign_id := (v_result->>'campaign_id')::UUID;

    SELECT completed_views INTO v_before_views
    FROM public.campaigns WHERE id = v_campaign_id;

    -- Compare the reconciled leaderboard to its authoritative source, not
    -- the synthetic rank score used earlier to construct the allocation fixture.
    SELECT pg_catalog.count(*)::INTEGER INTO v_before_daily
    FROM public.view_sessions
    WHERE viewer_id = v_viewer
      AND status = 'COMPLETED'
      AND completed_at >= (v_day::TIMESTAMP AT TIME ZONE 'UTC')
      AND completed_at < ((v_day + 1)::TIMESTAMP AT TIME ZONE 'UTC');

    UPDATE public.view_sessions
    SET content_ready_at = pg_catalog.clock_timestamp() - INTERVAL '10 seconds',
        status = 'CONTENT_READY'
    WHERE id = v_session_id;

    v_complete := public.complete_view_session(
        v_session_id,
        'seq_complete_' || v_session_id::TEXT
    );

    IF COALESCE((v_complete->>'success')::BOOLEAN, FALSE) IS NOT TRUE
       OR COALESCE((v_complete->>'already_completed')::BOOLEAN, TRUE) IS NOT FALSE
       OR v_complete->>'available_coins' IS NULL
       OR v_complete->>'lifetime_earned' IS NULL
       OR v_complete->>'completed_views_count' IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: first completion failed or changed the Android snapshot response';
    END IF;

    v_complete_retry := public.complete_view_session(
        v_session_id,
        'seq_complete_' || v_session_id::TEXT
    );

    IF COALESCE((v_complete_retry->>'already_completed')::BOOLEAN, FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST_FAILED: duplicate completion was not idempotent';
    END IF;

    SELECT completed_views INTO v_after_views
    FROM public.campaigns WHERE id = v_campaign_id;

    SELECT completed_views INTO v_after_daily
    FROM public.daily_view_leaderboard
    WHERE leaderboard_date = v_day AND user_id = v_viewer;

    SELECT c.owner_id INTO v_completed_owner
    FROM public.campaigns c WHERE c.id = v_campaign_id;

    SELECT a.completed, a.canceled
    INTO v_completed, v_canceled
    FROM public.special_campaign_assignments a
    WHERE a.session_id = v_session_id;

    SELECT status INTO v_status
    FROM public.view_sessions
    WHERE id = v_session_id;

    IF v_after_views IS DISTINCT FROM v_before_views + 1
       OR v_after_daily IS DISTINCT FROM v_before_daily + 1
       OR v_completed IS DISTINCT FROM TRUE
       OR v_canceled IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'TEST_FAILED: completion counters/assignment inconsistent campaign_before=% campaign_after=% daily_before=% daily_after=% assignment_completed=% assignment_canceled=% session_status=%',
            v_before_views,
            v_after_views,
            v_before_daily,
            v_after_daily,
            v_completed,
            v_canceled,
            v_status;
    END IF;

    -- Preserve the existing two-minute advertiser anti-repeat behavior.
    v_result := public.request_view_session();
    IF v_result IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: anti-repeat fallback had no alternative campaign';
    END IF;

    SELECT c.owner_id INTO v_owner_id
    FROM public.campaigns c
    WHERE c.id = (v_result->>'campaign_id')::UUID;

    IF v_owner_id = v_completed_owner THEN
        RAISE EXCEPTION 'TEST_FAILED: recent advertiser was repeated by fallback';
    END IF;

    PERFORM public.cancel_view_session((v_result->>'id')::UUID);

    -- A rank change must not revisit the selected owner after it moves below the cursor.
    INSERT INTO public.daily_view_leaderboard (
        leaderboard_date, user_id, user_handle, completed_views, updated_at
    )
    SELECT v_day, p.id, p.user_handle, 2000, pg_catalog.clock_timestamp()
    FROM public.profiles p WHERE p.id = v_move_viewer;

    UPDATE public.campaigns SET status = 'PAUSED' WHERE owner_id = v_viewer;

    PERFORM pg_catalog.set_config(
        'request.jwt.claims',
        pg_catalog.json_build_object(
            'sub', v_move_viewer::TEXT,
            'role', 'authenticated',
            'is_anonymous', FALSE
        )::TEXT,
        TRUE
    );

    v_result := public.request_view_session();
    IF v_result IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: rank-movement first request returned NULL';
    END IF;
    v_session_id := (v_result->>'id')::UUID;
    SELECT c.owner_id INTO v_owner_id
    FROM public.campaigns c WHERE c.id = (v_result->>'campaign_id')::UUID;
    SELECT a.owner_rank INTO v_owner_rank
    FROM public.special_campaign_assignments a WHERE a.session_id = v_session_id;
    IF v_owner_id IS DISTINCT FROM v_owners[2] OR v_owner_rank IS DISTINCT FROM 4 THEN
        RAISE EXCEPTION 'TEST_FAILED: rank-movement first selection was not rank 4';
    END IF;
    PERFORM public.cancel_view_session(v_session_id);

    -- Move the already-selected owner from rank 4 to rank 5. It must be skipped
    -- as visited; the owner now at rank 4 is behind the high-water mark and is not wrapped to.
    UPDATE public.daily_view_leaderboard
    SET completed_views = 650, updated_at = pg_catalog.clock_timestamp()
    WHERE leaderboard_date = v_day AND user_id = v_owners[2];

    v_result := public.request_view_session();
    IF v_result IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: rank-movement second request returned NULL';
    END IF;
    v_session_id := (v_result->>'id')::UUID;
    SELECT c.owner_id INTO v_owner_id
    FROM public.campaigns c WHERE c.id = (v_result->>'campaign_id')::UUID;
    SELECT a.owner_rank INTO v_owner_rank
    FROM public.special_campaign_assignments a WHERE a.session_id = v_session_id;
    IF v_owner_id IS DISTINCT FROM v_owners[4] OR v_owner_rank IS DISTINCT FROM 6 THEN
        RAISE EXCEPTION 'TEST_FAILED: cursor repeated a moved owner or wrapped to an earlier rank';
    END IF;
    PERFORM public.cancel_view_session(v_session_id);

    UPDATE public.daily_view_leaderboard
    SET completed_views = 800, updated_at = pg_catalog.clock_timestamp()
    WHERE leaderboard_date = v_day AND user_id = v_owners[2];
    UPDATE public.campaigns SET status = 'ACTIVE' WHERE owner_id = v_viewer;

    -- UTC boundary: a completion one second before midnight belongs to the previous
    -- UTC date; one second after midnight belongs to the current UTC date.
    v_boundary_previous := (v_day::TIMESTAMP AT TIME ZONE 'UTC') - INTERVAL '1 second';
    v_boundary_current := (v_day::TIMESTAMP AT TIME ZONE 'UTC') + INTERVAL '1 second';
    -- Read the authoritative completed-session count, not the synthetic
    -- leaderboard score used to build the ranking fixture.
    SELECT pg_catalog.count(*)::INTEGER INTO v_before_daily
    FROM public.view_sessions
    WHERE viewer_id = v_viewer
      AND status = 'COMPLETED'
      AND completed_at >= (v_day::TIMESTAMP AT TIME ZONE 'UTC')
      AND completed_at < ((v_day + 1)::TIMESTAMP AT TIME ZONE 'UTC');

    INSERT INTO public.view_sessions (
        campaign_id, viewer_id, required_duration_seconds, reward_coins,
        status, started_at, created_at, expires_at
    ) VALUES
    (
        (SELECT id FROM public.campaigns WHERE domain = 'seq-self.example.com'),
        v_viewer, 5, 3, 'INITIALIZED', v_boundary_previous, v_boundary_previous,
        pg_catalog.clock_timestamp() + INTERVAL '3 minutes'
    ),
    (
        (SELECT id FROM public.campaigns WHERE domain = 'seq-self.example.com'),
        v_viewer, 5, 3, 'INITIALIZED', v_boundary_current, v_boundary_current,
        pg_catalog.clock_timestamp() + INTERVAL '3 minutes'
    );

    UPDATE public.view_sessions
    SET status = 'COMPLETED', completed_at = v_boundary_previous
    WHERE viewer_id = v_viewer AND started_at = v_boundary_previous;
    UPDATE public.view_sessions
    SET status = 'COMPLETED', completed_at = v_boundary_current
    WHERE viewer_id = v_viewer AND started_at = v_boundary_current;

    SELECT completed_views INTO v_after_daily
    FROM public.daily_view_leaderboard
    WHERE leaderboard_date = v_day AND user_id = v_viewer;
    IF v_after_daily IS DISTINCT FROM v_before_daily + 1
       OR (SELECT completed_views FROM public.daily_view_leaderboard
           WHERE leaderboard_date = v_day - 1 AND user_id = v_viewer) IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: UTC midnight completion boundary is incorrect';
    END IF;

    PERFORM pg_catalog.set_config(
        'request.jwt.claims',
        pg_catalog.json_build_object(
            'sub', v_viewer::TEXT,
            'role', 'authenticated',
            'is_anonymous', FALSE
        )::TEXT,
        TRUE
    );

    -- RLS, RPC grants, pre-request hook and compatibility view checks.
    IF has_table_privilege('anon', 'public.viewer_daily_cursor', 'SELECT')
       OR has_table_privilege('authenticated', 'public.viewer_daily_cursor', 'SELECT')
       OR has_table_privilege('anon', 'public.special_campaign_assignments', 'SELECT')
       OR has_table_privilege('authenticated', 'public.special_campaign_assignments', 'SELECT') THEN
        RAISE EXCEPTION 'TEST_FAILED: private assignment/cursor table is directly readable';
    END IF;

    IF has_table_privilege('anon', 'public.view_sessions', 'SELECT')
       OR has_table_privilege('anon', 'public.campaigns', 'SELECT')
       OR NOT has_table_privilege('authenticated', 'public.view_sessions', 'SELECT')
       OR NOT has_table_privilege('authenticated', 'public.campaigns', 'SELECT') THEN
        RAISE EXCEPTION 'TEST_FAILED: session/campaign table grants are not as expected';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_policy p
        WHERE p.polrelid = 'public.view_sessions'::REGCLASS
          AND p.polcmd = 'r'
          AND pg_catalog.pg_get_expr(p.polqual, p.polrelid) ILIKE '%viewer_id%'
          AND pg_catalog.pg_get_expr(p.polqual, p.polrelid) ILIKE '%auth.uid%'
    ) OR NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_policy p
        WHERE p.polrelid = 'public.campaigns'::REGCLASS
          AND p.polcmd = 'r'
          AND pg_catalog.pg_get_expr(p.polqual, p.polrelid) ILIKE '%owner_id%'
          AND pg_catalog.pg_get_expr(p.polqual, p.polrelid) ILIKE '%auth.uid%'
          AND pg_catalog.pg_get_expr(p.polqual, p.polrelid) NOT ILIKE '%ACTIVE%'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: session/campaign SELECT policies are not owner-scoped';
    END IF;

    IF has_function_privilege('anon', 'public.request_view_session()', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.request_view_session()', 'EXECUTE')
       OR has_function_privilege('anon', 'public.complete_view_session(uuid,text)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.complete_view_session(uuid,text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'TEST_FAILED: RPC execute grants are not restricted to authenticated';
    END IF;

    IF NOT (
        SELECT c.relrowsecurity
        FROM pg_catalog.pg_class c
        WHERE c.oid = 'public.viewer_daily_cursor'::REGCLASS
    ) OR NOT (
        SELECT c.relrowsecurity
        FROM pg_catalog.pg_class c
        WHERE c.oid = 'public.special_campaign_assignments'::REGCLASS
    ) OR NOT (
        SELECT c.relrowsecurity
        FROM pg_catalog.pg_class c
        WHERE c.oid = 'public.view_sessions'::REGCLASS
    ) OR NOT (
        SELECT c.relrowsecurity
        FROM pg_catalog.pg_class c
        WHERE c.oid = 'public.campaigns'::REGCLASS
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: RLS is not enabled on sensitive tables';
    END IF;

    SELECT c.reloptions INTO v_reloptions
    FROM pg_catalog.pg_class c
    WHERE c.oid = 'public.daily_view_leaderboard_public'::REGCLASS;

    -- The daily view uses user_id privately for deterministic tie-breaking.
    -- It is deliberately owner-executed and must expose no private identifier.
    IF NOT ('security_invoker=false' = ANY(v_reloptions))
       OR EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'daily_view_leaderboard_public'
             AND column_name = 'user_id'
       )
       OR has_column_privilege(
           'authenticated',
           'public.daily_view_leaderboard',
           'user_id',
           'SELECT'
       ) THEN
        RAISE EXCEPTION 'TEST_FAILED: daily leaderboard leaks its private tie-break identity';
    END IF;

    -- The rolling-30 public view intentionally remains a definer view: it exposes
    -- only aggregate handle/count fields, not session or campaign identifiers.
    SELECT c.reloptions INTO v_weekly_reloptions
    FROM pg_catalog.pg_class c
    WHERE c.oid = 'public.weekly_view_leaderboard_public'::REGCLASS;

    IF NOT ('security_invoker=false' = ANY(v_weekly_reloptions))
       OR EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'weekly_view_leaderboard_public'
             AND column_name IN ('viewer_id', 'campaign_id', 'owner_id')
       ) THEN
        RAISE EXCEPTION 'TEST_FAILED: rolling-30 aggregate view security contract changed';
    END IF;

    IF pg_catalog.to_regprocedure('public.check_request()') IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: public.check_request() hook is missing';
    END IF;

    SELECT pg_catalog.pg_get_viewdef('public.weekly_view_leaderboard_public'::REGCLASS, TRUE)
    INTO v_view_definition;

    IF pg_catalog.strpos(pg_catalog.lower(v_view_definition), '30 days') = 0 THEN
        RAISE EXCEPTION 'TEST_FAILED: rolling-30 leaderboard definition was changed';
    END IF;

    -- Rebind regression: cursor, visited owners, daily rank and assignments must
    -- move to the new Auth UID before the old profile is deleted.
    v_domain := 'seq-rebind.example.com';
    v_url := 'https://' || v_domain || '/';
    INSERT INTO private.campaign_preflight_tokens (
        token_hash, user_id, source_url, normalized_url, domain, final_url,
        http_status, redirect_count, response_ms, content_type, content_length,
        viewer_compatibility, quality_score, diagnostics, created_at, expires_at, consumed_at
    )
    VALUES (
        pg_catalog.md5(v_rebind_old::TEXT || v_url) || pg_catalog.md5(v_url || v_rebind_old::TEXT),
        v_rebind_old, v_url, v_url, v_domain, v_url,
        200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
        pg_catalog.jsonb_build_object('referral_site_key', v_domain),
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp() + INTERVAL '10 minutes',
        pg_catalog.clock_timestamp()
    );

    INSERT INTO public.campaigns (
        owner_id, url, normalized_url, domain, duration_seconds,
        target_views, completed_views, cost_per_view, total_budget,
        spent_budget, reserved_budget, refunded_budget, status,
        created_at, updated_at
    )
    VALUES (
        v_rebind_old,
        'https://' || v_domain || '/',
        'https://' || v_domain || '/',
        v_domain,
        5, 5, 0, 5, 25, 0, 25, 0, 'ACTIVE',
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    RETURNING id INTO v_rebind_campaign;

    INSERT INTO public.view_sessions (
        campaign_id, viewer_id, required_duration_seconds, reward_coins,
        status, started_at, created_at, expires_at
    )
    VALUES (
        v_rebind_campaign, v_rebind_old, 5, 3,
        'INITIALIZED', pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp() + INTERVAL '3 minutes'
    )
    RETURNING id INTO v_rebind_session;

    INSERT INTO public.special_campaign_assignments (
        session_id, viewer_id, campaign_owner_id, campaign_id,
        assigned_position, owner_rank, assignment_type, reserved_views,
        created_at, expires_at
    )
    VALUES (
        v_rebind_session, v_rebind_old, v_rebind_old, v_rebind_campaign,
        1, 2, 'featured', 1, pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp() + INTERVAL '3 minutes'
    );

    INSERT INTO public.daily_view_leaderboard (
        leaderboard_date, user_id, user_handle, completed_views, updated_at
    )
    SELECT v_day, p.id, p.user_handle, 5, pg_catalog.clock_timestamp()
    FROM public.profiles p
    WHERE p.id = v_rebind_old;

    INSERT INTO public.viewer_daily_cursor (
        viewer_id, day_utc, last_selected_owner_id, last_selected_rank,
        request_position, exhausted, visited_owner_ids, updated_at
    )
    VALUES (
        v_rebind_old, v_day, v_rebind_old, 2, 1, FALSE,
        ARRAY[v_rebind_old]::UUID[], pg_catalog.clock_timestamp()
    );

    PERFORM private.rebind_user_account(
        v_rebind_old,
        v_rebind_new,
        'seq_rebind_install_new'
    );

    IF EXISTS (SELECT 1 FROM public.profiles WHERE id = v_rebind_old)
       OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_rebind_new)
       OR (SELECT owner_id FROM public.campaigns WHERE id = v_rebind_campaign) <> v_rebind_new
       OR (SELECT viewer_id FROM public.view_sessions WHERE id = v_rebind_session) <> v_rebind_new
       OR (SELECT viewer_id FROM public.special_campaign_assignments WHERE session_id = v_rebind_session) <> v_rebind_new
       OR (SELECT campaign_owner_id FROM public.special_campaign_assignments WHERE session_id = v_rebind_session) <> v_rebind_new
       OR (SELECT user_id FROM public.daily_view_leaderboard WHERE leaderboard_date = v_day AND user_id = v_rebind_new) IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: rebind did not migrate owner/viewer/leaderboard references';
    END IF;

    SELECT *
    INTO v_cursor
    FROM public.viewer_daily_cursor
    WHERE viewer_id = v_rebind_new AND day_utc = v_day;

    IF v_cursor.last_selected_owner_id <> v_rebind_new
       OR v_cursor.visited_owner_ids <> ARRAY[v_rebind_new]::UUID[] THEN
        RAISE EXCEPTION 'TEST_FAILED: rebind did not migrate cursor owner history';
    END IF;

    RAISE NOTICE 'PASS: sequential ranks, self-skip, next_eligible, >5 ranks, exhaustion, fallback, retry, cancel, TTL, completion idempotency, anti-repeat, RLS/grants, view security, Rolling30 and rebind';
END;
$test$;

-- Exercise actual RLS under the client roles, not only pg_policy metadata.
SET LOCAL ROLE authenticated;
DO $rls_authenticated$
DECLARE
    v_uid UUID := auth.uid();
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: authenticated RLS test has no auth.uid()';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.view_sessions WHERE viewer_id = v_uid
    ) OR EXISTS (
        SELECT 1 FROM public.view_sessions WHERE viewer_id <> v_uid
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: authenticated viewer can read sessions outside their ownership';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.campaigns WHERE owner_id = v_uid
    ) OR EXISTS (
        SELECT 1 FROM public.campaigns WHERE owner_id <> v_uid
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: authenticated viewer can read campaigns outside their ownership';
    END IF;
END;
$rls_authenticated$;
RESET ROLE;

SET LOCAL ROLE anon;
DO $rls_anon$
BEGIN
    BEGIN
        PERFORM 1 FROM public.view_sessions LIMIT 1;
        RAISE EXCEPTION 'TEST_FAILED: anon unexpectedly read view_sessions';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;

    BEGIN
        PERFORM 1 FROM public.campaigns LIMIT 1;
        RAISE EXCEPTION 'TEST_FAILED: anon unexpectedly read campaigns';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;

    BEGIN
        PERFORM 1 FROM public.special_campaign_assignments LIMIT 1;
        RAISE EXCEPTION 'TEST_FAILED: anon unexpectedly read special assignments';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
END;
$rls_anon$;
RESET ROLE;

ROLLBACK;
