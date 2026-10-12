BEGIN;

CREATE TABLE IF NOT EXISTS private.weekly_featured_campaign_assignment (
    week_start date NOT NULL,
    owner_id uuid NOT NULL,
    campaign_id uuid NULL
        REFERENCES public.campaigns(id) ON DELETE SET NULL,
    assigned_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
    PRIMARY KEY (week_start, owner_id),
    UNIQUE (week_start, campaign_id)
);

COMMENT ON TABLE private.weekly_featured_campaign_assignment IS
    'Pins at most one featured campaign per leaderboard owner for each UTC week. A deleted pinned campaign is not replaced until the next week.';

ALTER TABLE private.weekly_featured_campaign_assignment ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.weekly_featured_campaign_assignment FROM PUBLIC, anon, authenticated;

CREATE INDEX IF NOT EXISTS idx_view_sessions_viewer_served_week
    ON public.view_sessions (viewer_id, started_at DESC)
    WHERE content_ready_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public.request_view_session()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_uid uuid := (select auth.uid());
    v_campaign record;
    v_price record;
    v_existing_active record;
    v_new_session record;
    v_random_pivot uuid;
    v_week_start date;
    v_week_start_at timestamptz;
    v_week_end_at timestamptz;
    v_viewer_week_sessions integer := 0;
    v_feature_rank smallint;
    v_feature_owner_id uuid;
    v_feature_score integer;
    v_feature_quota record;
    v_requested_feature_owner_id uuid;
    v_assigned_campaign_id uuid;
    v_assignment_found boolean := false;
    v_campaign_found boolean := false;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    -- Keep the existing one-active-session-per-viewer serialization.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtext('view_session_req_' || v_uid::text)
    );

    SELECT vs.*, c.url, c.domain, c.keyword, c.resolved_target_url, c.resolver_status
    INTO v_existing_active
    FROM public.view_sessions vs
    JOIN public.campaigns c ON c.id = vs.campaign_id
    WHERE vs.viewer_id = v_uid
      AND vs.status IN ('INITIALIZED', 'CONTENT_READY')
    ORDER BY vs.started_at DESC
    LIMIT 1;

    IF v_existing_active.id IS NOT NULL THEN
        IF v_existing_active.started_at > (pg_catalog.clock_timestamp() - INTERVAL '3 minutes') THEN
            IF v_existing_active.keyword IS NOT NULL
               AND (v_existing_active.resolver_status <> 'READY'
                    OR v_existing_active.resolved_target_url IS NULL) THEN
                UPDATE public.view_sessions
                SET status = 'EXPIRED'
                WHERE id = v_existing_active.id;
            ELSE
                RETURN pg_catalog.json_build_object(
                    'id', v_existing_active.id,
                    'campaign_id', v_existing_active.campaign_id,
                    'target_url', CASE
                        WHEN v_existing_active.keyword IS NULL THEN v_existing_active.url
                        ELSE v_existing_active.resolved_target_url
                    END,
                    'domain', v_existing_active.domain,
                    'keyword', v_existing_active.keyword,
                    'required_duration_seconds', v_existing_active.required_duration_seconds,
                    'reward_coins', v_existing_active.reward_coins,
                    'started_at', extract(epoch from v_existing_active.started_at) * 1000,
                    'featured_rank', v_existing_active.leaderboard_feature_rank
                );
            END IF;
        ELSE
            UPDATE public.view_sessions
            SET status = 'EXPIRED'
            WHERE id = v_existing_active.id;
        END IF;
    END IF;

    v_week_start := pg_catalog.date_trunc(
        'week', pg_catalog.clock_timestamp() AT TIME ZONE 'UTC'
    )::date;
    v_week_start_at := v_week_start::timestamp AT TIME ZONE 'UTC';
    v_week_end_at := (v_week_start + 7)::timestamp AT TIME ZONE 'UTC';

    -- Count a position only once the actual page content was ready to display.
    -- A session abandoned before content_ready_at does not consume a priority slot.
    SELECT pg_catalog.count(*)::integer
    INTO v_viewer_week_sessions
    FROM public.view_sessions vs
    WHERE vs.viewer_id = v_uid
      AND vs.started_at >= v_week_start_at
      AND vs.started_at < v_week_end_at
      AND vs.content_ready_at IS NOT NULL;

    IF v_viewer_week_sessions BETWEEN 0 AND 4 THEN
        v_feature_rank := (v_viewer_week_sessions + 1)::smallint;

        SELECT ranked.user_id, ranked.completed_views
        INTO v_feature_owner_id, v_feature_score
        FROM (
            SELECT w.user_id,
                   w.completed_views,
                   pg_catalog.row_number() OVER (
                     ORDER BY w.completed_views DESC, w.user_handle ASC
                   )::integer AS leaderboard_rank
            FROM public.weekly_view_leaderboard w
            WHERE w.week_start = v_week_start
        ) ranked
        WHERE ranked.leaderboard_rank = v_feature_rank;
    ELSE
        v_feature_rank := NULL;
        v_feature_owner_id := NULL;
        v_feature_score := NULL;
    END IF;

    -- Preserve the targeted owner for fallback exclusion even if the pinned
    -- campaign or its quota is unavailable.
    v_requested_feature_owner_id := v_feature_owner_id;

    v_random_pivot := (
        pg_catalog.md5(
            pg_catalog.random()::text
            || pg_catalog.clock_timestamp()::text
            || v_uid::text
        )
    )::uuid;

    -- Keep one stable, featured campaign per leaderboard owner and UTC week.
    -- Serialize assignment creation before taking a campaign lock so concurrent
    -- viewers cannot pin different campaigns for the same owner.
    IF v_feature_rank IS NOT NULL
       AND v_feature_owner_id IS NOT NULL
       AND v_feature_owner_id <> v_uid
       AND COALESCE(v_feature_score, 0) > 0 THEN

        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtext(
                'weekly_featured_assignment_' || v_week_start::text || ':' || v_feature_owner_id::text
            )
        );

        SELECT a.campaign_id
        INTO v_assigned_campaign_id
        FROM private.weekly_featured_campaign_assignment a
        WHERE a.week_start = v_week_start
          AND a.owner_id = v_feature_owner_id;
        v_assignment_found := FOUND;

        IF NOT v_assignment_found THEN
            -- Pin only an eligible campaign. If the owner has no eligible
            -- campaign yet, leave the assignment absent and retry on a later
            -- viewer request. Once pinned, never substitute another link this week.
            SELECT c.id
            INTO v_assigned_campaign_id
            FROM public.campaigns c
            WHERE c.owner_id = v_feature_owner_id
              AND c.status = 'ACTIVE'
              AND c.completed_views < c.target_views
              AND c.reserved_budget >= c.cost_per_view
              AND (
                  c.keyword IS NULL
                  OR (c.resolver_status = 'READY' AND c.resolved_target_url IS NOT NULL)
              )
            ORDER BY
              c.completed_views::numeric / NULLIF(c.target_views, 0),
              c.created_at ASC,
              c.id ASC
            FOR UPDATE OF c SKIP LOCKED
            LIMIT 1;

            IF FOUND THEN
                INSERT INTO private.weekly_featured_campaign_assignment (
                    week_start, owner_id, campaign_id
                )
                VALUES (
                    v_week_start, v_feature_owner_id, v_assigned_campaign_id
                )
                ON CONFLICT (week_start, owner_id) DO NOTHING;

                SELECT a.campaign_id
                INTO v_assigned_campaign_id
                FROM private.weekly_featured_campaign_assignment a
                WHERE a.week_start = v_week_start
                  AND a.owner_id = v_feature_owner_id;
                v_assignment_found := FOUND;
            END IF;
        END IF;

        IF v_assignment_found AND v_assigned_campaign_id IS NOT NULL THEN
            SELECT c.*
            INTO v_campaign
            FROM public.campaigns c
            WHERE c.id = v_assigned_campaign_id
              AND c.owner_id = v_feature_owner_id
              AND c.owner_id <> v_uid
              AND c.status = 'ACTIVE'
              AND c.completed_views < c.target_views
              AND c.reserved_budget >= c.cost_per_view
              AND (
                  c.keyword IS NULL
                  OR (c.resolver_status = 'READY' AND c.resolved_target_url IS NOT NULL)
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM public.view_sessions vs
                  JOIN public.campaigns recent_campaign
                    ON recent_campaign.id = vs.campaign_id
                  WHERE vs.viewer_id = v_uid
                    AND vs.status = 'COMPLETED'
                    AND vs.completed_at > (
                      pg_catalog.clock_timestamp() - INTERVAL '2 minutes'
                    )
                    AND recent_campaign.owner_id = c.owner_id
              )
            FOR UPDATE OF c SKIP LOCKED
            LIMIT 1;

            v_campaign_found := FOUND;
        ELSE
            v_campaign_found := false;
        END IF;

        -- Preserve the original campaign -> quota lock order to avoid deadlocks
        -- with completion/cancellation processing.
        IF v_campaign_found THEN
            INSERT INTO private.weekly_featured_campaign_quota (
                week_start, owner_id, quota_views, updated_at
            )
            VALUES (
                v_week_start, v_feature_owner_id, v_feature_score,
                pg_catalog.clock_timestamp()
            )
            ON CONFLICT (week_start, owner_id) DO UPDATE
              SET quota_views = EXCLUDED.quota_views,
                  updated_at = EXCLUDED.updated_at
            RETURNING quota_views, reserved_views, completed_views
            INTO v_feature_quota;

            IF v_feature_quota.reserved_views + v_feature_quota.completed_views
               < v_feature_quota.quota_views THEN
                UPDATE private.weekly_featured_campaign_quota q
                SET reserved_views = q.reserved_views + 1,
                    updated_at = pg_catalog.clock_timestamp()
                WHERE q.week_start = v_week_start
                  AND q.owner_id = v_feature_owner_id
                  AND q.reserved_views + q.completed_views < q.quota_views;

                IF NOT FOUND THEN
                    v_campaign_found := false;
                END IF;
            ELSE
                v_campaign_found := false;
            END IF;
        END IF;

        IF NOT v_campaign_found THEN
            v_feature_rank := NULL;
            v_feature_owner_id := NULL;
        END IF;
    ELSE
        v_feature_rank := NULL;
        v_feature_owner_id := NULL;
    END IF;

    -- From the sixth page whose content was displayed, or whenever the matching
    -- rank's campaign is unavailable, preserve the existing randomized distribution.
    IF NOT v_campaign_found THEN
        SELECT c.*
        INTO v_campaign
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_uid
          AND (v_requested_feature_owner_id IS NULL OR c.owner_id <> v_requested_feature_owner_id)
          AND c.completed_views < c.target_views
          AND c.reserved_budget >= c.cost_per_view
          AND (c.keyword IS NULL OR (c.resolver_status = 'READY' AND c.resolved_target_url IS NOT NULL))
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
        v_campaign_found := FOUND;
    END IF;

    IF NOT v_campaign_found THEN
        SELECT c.*
        INTO v_campaign
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_uid
          AND (v_requested_feature_owner_id IS NULL OR c.owner_id <> v_requested_feature_owner_id)
          AND c.completed_views < c.target_views
          AND c.reserved_budget >= c.cost_per_view
          AND (c.keyword IS NULL OR (c.resolver_status = 'READY' AND c.resolved_target_url IS NOT NULL))
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
        v_campaign_found := FOUND;
    END IF;

    IF NOT v_campaign_found THEN
        SELECT c.*
        INTO v_campaign
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_uid
          AND (v_requested_feature_owner_id IS NULL OR c.owner_id <> v_requested_feature_owner_id)
          AND c.completed_views < c.target_views
          AND c.reserved_budget >= c.cost_per_view
          AND (c.keyword IS NULL OR (c.resolver_status = 'READY' AND c.resolved_target_url IS NOT NULL))
          AND c.id >= v_random_pivot
        ORDER BY c.id ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1;
        v_campaign_found := FOUND;
    END IF;

    IF NOT v_campaign_found THEN
        SELECT c.*
        INTO v_campaign
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_uid
          AND (v_requested_feature_owner_id IS NULL OR c.owner_id <> v_requested_feature_owner_id)
          AND c.completed_views < c.target_views
          AND c.reserved_budget >= c.cost_per_view
          AND (c.keyword IS NULL OR (c.resolver_status = 'READY' AND c.resolved_target_url IS NOT NULL))
        ORDER BY c.id ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1;
        v_campaign_found := FOUND;
    END IF;

    IF NOT v_campaign_found THEN
        RETURN NULL;
    END IF;

    SELECT *
    INTO v_price
    FROM public.duration_pricing
    WHERE duration_seconds = v_campaign.duration_seconds;

    IF v_price IS NULL THEN
        RAISE EXCEPTION 'INVALID_DURATION: Pricing row for campaign duration is missing';
    END IF;

    IF v_campaign.keyword IS NOT NULL
       AND (v_campaign.resolver_status <> 'READY' OR v_campaign.resolved_target_url IS NULL) THEN
        RAISE EXCEPTION 'CAMPAIGN_RESOLUTION_PENDING: Keyword campaign destination is not ready';
    END IF;

    INSERT INTO public.view_sessions (
        campaign_id, viewer_id, keyword,
        required_duration_seconds, reward_coins, status, started_at, created_at,
        leaderboard_feature_week, leaderboard_feature_owner_id, leaderboard_feature_rank
    )
    VALUES (
        v_campaign.id, v_uid, v_campaign.keyword,
        v_campaign.duration_seconds, v_price.viewer_reward, 'INITIALIZED',
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp(),
        CASE WHEN v_feature_rank IS NOT NULL THEN v_week_start ELSE NULL END,
        v_feature_owner_id,
        v_feature_rank
    )
    RETURNING * INTO v_new_session;

    RETURN pg_catalog.json_build_object(
        'id', v_new_session.id,
        'campaign_id', v_campaign.id,
        'target_url', CASE
            WHEN v_campaign.keyword IS NULL THEN v_campaign.url
            ELSE v_campaign.resolved_target_url
        END,
        'domain', v_campaign.domain,
        'keyword', v_new_session.keyword,
        'required_duration_seconds', v_new_session.required_duration_seconds,
        'reward_coins', v_new_session.reward_coins,
        'started_at', extract(epoch from v_new_session.started_at) * 1000,
        'featured_rank', v_new_session.leaderboard_feature_rank
    );
END;
$function$;


REVOKE ALL ON FUNCTION public.request_view_session() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_view_session() TO authenticated;

COMMIT;
