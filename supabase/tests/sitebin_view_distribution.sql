-- SiteBin real PostgreSQL integration tests for randomized viewer distribution.
-- All mutations are rolled back. Run only against a disposable/transactional test context.
--
-- The test uses real production campaign inventory inside a transaction and
-- exercises public.request_view_session() with a simulated authenticated JWT.

BEGIN;

DO $$
DECLARE
    v_viewer uuid;
    v_result json;
    v_session_id uuid;
    v_first_campaign_id uuid;
    v_first_owner uuid;
    v_selected_campaign uuid;
    v_selected_owner uuid;
    v_distinct_campaigns bigint;
    v_fallback_owner uuid;
    v_owner_campaign uuid;
BEGIN
    -- Pick a real account with no active session and no completed view in the
    -- 2-minute advertiser-diversity window so the fixture starts clean.
    SELECT p.id
      INTO v_viewer
    FROM public.profiles p
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.view_sessions vs
        WHERE vs.viewer_id = p.id
          AND vs.status = 'COMPLETED'
          AND vs.completed_at > pg_catalog.clock_timestamp() - INTERVAL '2 minutes'
    )
      AND NOT EXISTS (
        SELECT 1
        FROM public.view_sessions vs
        WHERE vs.viewer_id = p.id
          AND vs.status IN ('INITIALIZED', 'CONTENT_READY')
    )
    ORDER BY p.id
    LIMIT 1;

    IF v_viewer IS NULL THEN
        RAISE EXCEPTION 'TEST_SETUP_FAILED: no clean viewer account available';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        pg_catalog.json_build_object(
            'sub', v_viewer::text,
            'role', 'authenticated',
            'is_anonymous', false
        )::text,
        true
    );

    -- First request establishes the advertiser that will be placed into the
    -- recent-completion diversity window.
    v_result := public.request_view_session();

    IF v_result IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: request_view_session returned no session with eligible inventory';
    END IF;

    v_session_id := (v_result->>'id')::uuid;
    v_first_campaign_id := (v_result->>'campaign_id')::uuid;

    SELECT owner_id
      INTO v_first_owner
    FROM public.campaigns
    WHERE id = v_first_campaign_id;

    IF v_first_owner IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: selected campaign owner could not be resolved';
    END IF;

    UPDATE public.view_sessions
    SET status = 'CANCELLED'
    WHERE id = v_session_id
      AND viewer_id = v_viewer;

    INSERT INTO public.view_sessions(
        campaign_id,
        viewer_id,
        required_duration_seconds,
        reward_coins,
        status,
        started_at,
        content_ready_at,
        completed_at,
        created_at
    )
    VALUES(
        v_first_campaign_id,
        v_viewer,
        5,
        3,
        'COMPLETED',
        pg_catalog.clock_timestamp() - INTERVAL '1 minute',
        pg_catalog.clock_timestamp() - INTERVAL '55 seconds',
        pg_catalog.clock_timestamp() - INTERVAL '30 seconds',
        pg_catalog.clock_timestamp() - INTERVAL '30 seconds'
    );

    CREATE TEMP TABLE _sitebin_distribution_selected(
        campaign_id uuid NOT NULL
    ) ON COMMIT DROP;

    -- Repeated requests show that delivery is no longer FIFO and that the
    -- recently completed advertiser does not immediately dominate this viewer.
    FOR i IN 1..30 LOOP
        v_result := public.request_view_session();

        IF v_result IS NULL THEN
            RAISE EXCEPTION 'TEST_FAILED: randomized request returned no session at iteration %', i;
        END IF;

        v_selected_campaign := (v_result->>'campaign_id')::uuid;

        SELECT owner_id
          INTO v_selected_owner
        FROM public.campaigns
        WHERE id = v_selected_campaign;

        IF v_selected_owner = v_first_owner THEN
            RAISE EXCEPTION 'TEST_FAILED: advertiser diversity violated at iteration %', i;
        END IF;

        INSERT INTO _sitebin_distribution_selected(campaign_id)
        VALUES(v_selected_campaign);

        UPDATE public.view_sessions
        SET status = 'CANCELLED'
        WHERE id = (v_result->>'id')::uuid
          AND viewer_id = v_viewer;
    END LOOP;

    SELECT count(DISTINCT campaign_id)
      INTO v_distinct_campaigns
    FROM _sitebin_distribution_selected;

    IF v_distinct_campaigns < 3 THEN
        RAISE EXCEPTION
            'TEST_FAILED: only % distinct campaigns selected across 30 requests',
            v_distinct_campaigns;
    END IF;

    -- Fallback safety: make every eligible advertiser except one recent for
    -- this viewer. The remaining fresh advertiser must still be served.
    SELECT c.owner_id
      INTO v_fallback_owner
    FROM public.campaigns c
    WHERE c.status = 'ACTIVE'
      AND c.owner_id <> v_viewer
      AND c.completed_views < c.target_views
      AND c.reserved_budget >= c.cost_per_view
      AND c.owner_id <> v_first_owner
    GROUP BY c.owner_id
    ORDER BY c.owner_id
    LIMIT 1;

    IF v_fallback_owner IS NULL THEN
        RAISE EXCEPTION 'TEST_SETUP_FAILED: need at least two eligible advertisers';
    END IF;

    FOR v_owner_campaign IN
        SELECT DISTINCT ON (c.owner_id) c.id
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_viewer
          AND c.completed_views < c.target_views
          AND c.reserved_budget >= c.cost_per_view
          AND c.owner_id <> v_fallback_owner
        ORDER BY c.owner_id, c.id
    LOOP
        INSERT INTO public.view_sessions(
            campaign_id,
            viewer_id,
            required_duration_seconds,
            reward_coins,
            status,
            started_at,
            content_ready_at,
            completed_at,
            created_at
        )
        VALUES(
            v_owner_campaign,
            v_viewer,
            5,
            3,
            'COMPLETED',
            pg_catalog.clock_timestamp() - INTERVAL '1 minute',
            pg_catalog.clock_timestamp() - INTERVAL '55 seconds',
            pg_catalog.clock_timestamp() - INTERVAL '20 seconds',
            pg_catalog.clock_timestamp() - INTERVAL '20 seconds'
        );
    END LOOP;

    v_result := public.request_view_session();

    IF v_result IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: diversity fallback returned no session';
    END IF;

    SELECT owner_id
      INTO v_selected_owner
    FROM public.campaigns
    WHERE id = (v_result->>'campaign_id')::uuid;

    IF v_selected_owner <> v_fallback_owner THEN
        RAISE EXCEPTION
            'TEST_FAILED: fallback selected owner % instead of the only fresh owner %',
            v_selected_owner,
            v_fallback_owner;
    END IF;
END;
$$;

ROLLBACK;
