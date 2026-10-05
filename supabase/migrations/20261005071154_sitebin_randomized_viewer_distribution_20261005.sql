-- SiteBin randomized and fairer viewer campaign distribution.
--
-- Selection remains server-authoritative. Android receives only the selected
-- session/URL and cannot choose or reorder campaigns.
--
-- Strategy:
-- 1. Use the campaign UUID primary key as a cheap random walk over the eligible
--    keyspace. Campaign IDs are gen_random_uuid(), so the keyspace is suitable
--    for approximately uniform campaign sampling without ORDER BY random().
-- 2. Prefer campaigns whose advertiser has not been completed by this viewer in
--    the last 2 minutes. This prevents one advertiser with many campaigns from
--    monopolizing a viewer's personal queue.
-- 3. Wrap around the UUID keyspace when no candidate exists after the pivot.
-- 4. If every advertiser is in the diversity window, fall back to any eligible
--    campaign so legitimate inventory is never blocked.
-- 5. Keep the existing per-viewer advisory lock and FOR UPDATE SKIP LOCKED.

CREATE INDEX IF NOT EXISTS idx_campaigns_view_random_pool
ON public.campaigns (id)
WHERE status = 'ACTIVE'
  AND completed_views < target_views
  AND reserved_budget >= cost_per_view;

CREATE INDEX IF NOT EXISTS idx_view_sessions_viewer_completed_at
ON public.view_sessions (viewer_id, completed_at DESC)
WHERE status = 'COMPLETED';

DROP INDEX IF EXISTS public.idx_campaigns_view_queue;

CREATE OR REPLACE FUNCTION public.request_view_session()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_uid UUID := (select auth.uid());
    v_campaign RECORD;
    v_price RECORD;
    v_existing_active RECORD;
    v_new_session RECORD;
    v_random_pivot UUID;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtext('view_session_req_' || v_uid::text)
    );

    SELECT vs.*, c.url, c.domain, c.keyword
    INTO v_existing_active
    FROM public.view_sessions vs
    JOIN public.campaigns c ON c.id = vs.campaign_id
    WHERE vs.viewer_id = v_uid
      AND vs.status IN ('INITIALIZED', 'CONTENT_READY')
    ORDER BY vs.started_at DESC
    LIMIT 1;

    IF v_existing_active IS NOT NULL THEN
        IF v_existing_active.started_at > (pg_catalog.clock_timestamp() - INTERVAL '3 minutes') THEN
            RETURN pg_catalog.json_build_object(
                'id', v_existing_active.id,
                'campaign_id', v_existing_active.campaign_id,
                'target_url', v_existing_active.url,
                'domain', v_existing_active.domain,
                'keyword', v_existing_active.keyword,
                'required_duration_seconds', v_existing_active.required_duration_seconds,
                'reward_coins', v_existing_active.reward_coins,
                'started_at', extract(epoch from v_existing_active.started_at) * 1000
            );
        ELSE
            UPDATE public.view_sessions
            SET status = 'EXPIRED'
            WHERE id = v_existing_active.id;
        END IF;
    END IF;

    v_random_pivot := (
        pg_catalog.md5(
            pg_catalog.random()::text
            || pg_catalog.clock_timestamp()::text
            || v_uid::text
        )
    )::uuid;

    -- Preferred pool: random campaign selection + per-viewer advertiser diversity.
    SELECT c.*
    INTO v_campaign
    FROM public.campaigns c
    WHERE c.status = 'ACTIVE'
      AND c.owner_id <> v_uid
      AND c.completed_views < c.target_views
      AND c.reserved_budget >= c.cost_per_view
      AND c.id >= v_random_pivot
      AND NOT EXISTS (
          SELECT 1
          FROM public.view_sessions vs
          JOIN public.campaigns recent_campaign
            ON recent_campaign.id = vs.campaign_id
          WHERE vs.viewer_id = v_uid
            AND vs.status = 'COMPLETED'
            AND vs.completed_at > (pg_catalog.clock_timestamp() - INTERVAL '2 minutes')
            AND recent_campaign.owner_id = c.owner_id
      )
    ORDER BY c.id ASC
    FOR UPDATE SKIP LOCKED
    LIMIT 1;

    -- Wrap around when the preferred pool has no candidate at/after the pivot.
    IF v_campaign IS NULL THEN
        SELECT c.*
        INTO v_campaign
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_uid
          AND c.completed_views < c.target_views
          AND c.reserved_budget >= c.cost_per_view
          AND NOT EXISTS (
              SELECT 1
              FROM public.view_sessions vs
              JOIN public.campaigns recent_campaign
                ON recent_campaign.id = vs.campaign_id
              WHERE vs.viewer_id = v_uid
                AND vs.status = 'COMPLETED'
                AND vs.completed_at > (pg_catalog.clock_timestamp() - INTERVAL '2 minutes')
                AND recent_campaign.owner_id = c.owner_id
          )
        ORDER BY c.id ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1;
    END IF;

    -- If all advertisers are inside the diversity window, preserve inventory
    -- availability rather than returning an empty result.
    IF v_campaign IS NULL THEN
        SELECT c.*
        INTO v_campaign
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_uid
          AND c.completed_views < c.target_views
          AND c.reserved_budget >= c.cost_per_view
          AND c.id >= v_random_pivot
        ORDER BY c.id ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1;
    END IF;

    IF v_campaign IS NULL THEN
        SELECT c.*
        INTO v_campaign
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_uid
          AND c.completed_views < c.target_views
          AND c.reserved_budget >= c.cost_per_view
        ORDER BY c.id ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1;
    END IF;

    IF v_campaign IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_price
    FROM public.duration_pricing
    WHERE duration_seconds = v_campaign.duration_seconds;

    IF v_price IS NULL THEN
        RAISE EXCEPTION 'INVALID_DURATION: Pricing row for campaign duration is missing';
    END IF;

    INSERT INTO public.view_sessions(
        campaign_id,
        viewer_id,
        keyword,
        required_duration_seconds,
        reward_coins,
        status,
        started_at,
        created_at
    )
    VALUES(
        v_campaign.id,
        v_uid,
        v_campaign.keyword,
        v_campaign.duration_seconds,
        v_price.viewer_reward,
        'INITIALIZED',
        pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp()
    )
    RETURNING * INTO v_new_session;

    RETURN pg_catalog.json_build_object(
        'id', v_new_session.id,
        'campaign_id', v_campaign.id,
        'target_url', v_campaign.url,
        'domain', v_campaign.domain,
        'keyword', v_new_session.keyword,
        'required_duration_seconds', v_new_session.required_duration_seconds,
        'reward_coins', v_new_session.reward_coins,
        'started_at', extract(epoch from v_new_session.started_at) * 1000
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.request_view_session() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_view_session() TO authenticated;
