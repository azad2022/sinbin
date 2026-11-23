-- SiteBin sequential daily leaderboard campaign assignment.
-- All capacity is serialized on the campaign row. Money remains in reserved_budget;
-- reserved_views is assignment metadata and is never added to monetary columns.

BEGIN;

ALTER TABLE public.view_sessions
    ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;

UPDATE public.view_sessions
SET expires_at = started_at + INTERVAL '3 minutes'
WHERE expires_at IS NULL;

ALTER TABLE public.view_sessions
    ALTER COLUMN expires_at SET DEFAULT (pg_catalog.clock_timestamp() + INTERVAL '3 minutes'),
    ALTER COLUMN expires_at SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_view_sessions_campaign_active_expiry
    ON public.view_sessions (campaign_id, expires_at)
    WHERE status IN ('INITIALIZED', 'CONTENT_READY');

CREATE INDEX IF NOT EXISTS idx_view_sessions_active_expiry
    ON public.view_sessions (expires_at)
    WHERE status IN ('INITIALIZED', 'CONTENT_READY');

CREATE TABLE IF NOT EXISTS public.viewer_daily_cursor (
    viewer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    day_utc DATE NOT NULL,
    last_selected_owner_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    last_selected_rank INTEGER CHECK (last_selected_rank IS NULL OR last_selected_rank > 0),
    request_position BIGINT NOT NULL DEFAULT 0 CHECK (request_position >= 0),
    exhausted BOOLEAN NOT NULL DEFAULT FALSE,
    visited_owner_ids UUID[] NOT NULL DEFAULT ARRAY[]::UUID[],
    updated_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp(),
    CONSTRAINT viewer_daily_cursor_pkey PRIMARY KEY (viewer_id, day_utc)
);

CREATE INDEX IF NOT EXISTS idx_viewer_daily_cursor_day_updated
    ON public.viewer_daily_cursor (day_utc, updated_at DESC);

CREATE TABLE IF NOT EXISTS public.special_campaign_assignments (
    assignment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL UNIQUE
        REFERENCES public.view_sessions(id) ON DELETE CASCADE,
    viewer_id UUID NOT NULL
        REFERENCES public.profiles(id) ON DELETE CASCADE,
    campaign_owner_id UUID NOT NULL
        REFERENCES public.profiles(id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL
        REFERENCES public.campaigns(id) ON DELETE CASCADE,
    assigned_position BIGINT NOT NULL CHECK (assigned_position > 0),
    owner_rank INTEGER CHECK (owner_rank IS NULL OR owner_rank > 0),
    assignment_type TEXT NOT NULL
        CHECK (assignment_type IN ('featured', 'normal')),
    reserved_views INTEGER NOT NULL DEFAULT 1 CHECK (reserved_views >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp(),
    expires_at TIMESTAMPTZ NOT NULL,
    completed BOOLEAN NOT NULL DEFAULT FALSE,
    canceled BOOLEAN NOT NULL DEFAULT FALSE,
    completed_at TIMESTAMPTZ,
    canceled_at TIMESTAMPTZ,
    CONSTRAINT special_campaign_assignments_terminal_state_check
        CHECK (NOT (completed AND canceled))
);

CREATE INDEX IF NOT EXISTS idx_special_assignments_viewer_created
    ON public.special_campaign_assignments (viewer_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_special_assignments_campaign_reserved
    ON public.special_campaign_assignments (campaign_id, expires_at)
    WHERE completed = FALSE AND canceled = FALSE;

ALTER TABLE public.viewer_daily_cursor ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.special_campaign_assignments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.viewer_daily_cursor FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.special_campaign_assignments FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE public.viewer_daily_cursor IS
    'Private per-viewer UTC-day sequential allocation cursor. visited_owner_ids prevents a leaderboard owner from being revisited after ranks move during the day.';
COMMENT ON TABLE public.special_campaign_assignments IS
    'Private per-session allocation audit. reserved_views is a count, never currency; campaign capacity is computed from active view_sessions under a campaign row lock.';

-- Keep the public daily leaderboard response shape, but make ties deterministic
-- by user_id rather than mutable display handle.
-- The private user_id is used only for deterministic tie-breaking. This view
-- intentionally runs as its owner and exposes only public handle/count columns.
CREATE OR REPLACE VIEW public.daily_view_leaderboard_public
WITH (security_invoker = false)
AS
SELECT
    leaderboard_date,
    pg_catalog.row_number() OVER (
        PARTITION BY leaderboard_date
        ORDER BY completed_views DESC, user_id ASC
    )::INTEGER AS rank,
    user_handle,
    completed_views,
    updated_at
FROM public.daily_view_leaderboard;

CREATE INDEX IF NOT EXISTS idx_daily_view_leaderboard_date_rank_user_id
    ON public.daily_view_leaderboard (leaderboard_date, completed_views DESC, user_id ASC);

REVOKE ALL ON public.daily_view_leaderboard_public FROM PUBLIC, anon;
GRANT SELECT ON public.daily_view_leaderboard_public TO authenticated;

-- Keep assignment state synchronized with the authoritative session transition.
CREATE OR REPLACE FUNCTION private.sync_special_assignment_session_state()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
    IF NEW.status = 'COMPLETED' AND OLD.status IS DISTINCT FROM 'COMPLETED' THEN
        UPDATE public.special_campaign_assignments
        SET completed = TRUE,
            canceled = FALSE,
            completed_at = COALESCE(NEW.completed_at, pg_catalog.clock_timestamp()),
            canceled_at = NULL
        WHERE session_id = NEW.id
          AND completed = FALSE
          AND canceled = FALSE;
    ELSIF NEW.status IN ('CANCELLED', 'EXPIRED')
          AND OLD.status IS DISTINCT FROM NEW.status THEN
        UPDATE public.special_campaign_assignments
        SET completed = FALSE,
            canceled = TRUE,
            completed_at = NULL,
            canceled_at = pg_catalog.clock_timestamp()
        WHERE session_id = NEW.id
          AND completed = FALSE
          AND canceled = FALSE;
    END IF;

    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.sync_special_assignment_session_state() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION private.guard_expired_session_completion()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
    IF NEW.status = 'COMPLETED'
       AND OLD.status IS DISTINCT FROM 'COMPLETED'
       AND NEW.expires_at <= pg_catalog.clock_timestamp() THEN
        RAISE EXCEPTION 'SESSION_EXPIRED: View session exceeded its 3-minute TTL';
    END IF;
    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.guard_expired_session_completion() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_guard_expired_session_completion ON public.view_sessions;
CREATE TRIGGER trg_guard_expired_session_completion
BEFORE UPDATE OF status ON public.view_sessions
FOR EACH ROW
EXECUTE FUNCTION private.guard_expired_session_completion();

DROP TRIGGER IF EXISTS trg_sync_special_assignment_session_state ON public.view_sessions;
CREATE TRIGGER trg_sync_special_assignment_session_state
AFTER UPDATE OF status ON public.view_sessions
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION private.sync_special_assignment_session_state();

-- Keep assignment ownership in sync with the existing rebind_user_account flow.
CREATE OR REPLACE FUNCTION private.sync_assignment_campaign_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
    IF NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
        UPDATE public.special_campaign_assignments
        SET campaign_owner_id = NEW.owner_id
        WHERE campaign_id = NEW.id
          AND campaign_owner_id = OLD.owner_id;
    END IF;
    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.sync_assignment_campaign_owner() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_sync_assignment_campaign_owner ON public.campaigns;
CREATE TRIGGER trg_sync_assignment_campaign_owner
AFTER UPDATE OF owner_id ON public.campaigns
FOR EACH ROW
WHEN (OLD.owner_id IS DISTINCT FROM NEW.owner_id)
EXECUTE FUNCTION private.sync_assignment_campaign_owner();

CREATE OR REPLACE FUNCTION private.sync_assignment_viewer_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
    IF NEW.viewer_id IS DISTINCT FROM OLD.viewer_id THEN
        UPDATE public.special_campaign_assignments
        SET viewer_id = NEW.viewer_id
        WHERE session_id = NEW.id
          AND viewer_id = OLD.viewer_id;
    END IF;
    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.sync_assignment_viewer_owner() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_sync_assignment_viewer_owner ON public.view_sessions;
CREATE TRIGGER trg_sync_assignment_viewer_owner
AFTER UPDATE OF viewer_id ON public.view_sessions
FOR EACH ROW
WHEN (OLD.viewer_id IS DISTINCT FROM NEW.viewer_id)
EXECUTE FUNCTION private.sync_assignment_viewer_owner();

-- Preserve assignment state for sessions already in flight at deployment.
INSERT INTO public.special_campaign_assignments (
    session_id, viewer_id, campaign_owner_id, campaign_id,
    assigned_position, owner_rank, assignment_type, reserved_views,
    created_at, expires_at, completed, canceled
)
SELECT
    ranked_sessions.id,
    ranked_sessions.viewer_id,
    ranked_sessions.owner_id,
    ranked_sessions.campaign_id,
    ranked_sessions.assigned_position,
    ranked_sessions.owner_rank,
    'normal',
    1,
    ranked_sessions.created_at,
    ranked_sessions.expires_at,
    FALSE,
    FALSE
FROM (
    SELECT
        vs.id,
        vs.viewer_id,
        c.owner_id,
        vs.campaign_id,
        vs.created_at,
        vs.expires_at,
        pg_catalog.row_number() OVER (
            PARTITION BY vs.viewer_id, (vs.started_at AT TIME ZONE 'UTC')::DATE
            ORDER BY vs.started_at, vs.id
        )::BIGINT AS assigned_position,
        ranked_owner.owner_rank
    FROM public.view_sessions vs
    JOIN public.campaigns c ON c.id = vs.campaign_id
    LEFT JOIN LATERAL (
        SELECT ranked.user_id, ranked.owner_rank
        FROM (
            SELECT
                d.user_id,
                pg_catalog.row_number() OVER (
                    ORDER BY d.completed_views DESC, d.user_id ASC
                )::INTEGER AS owner_rank
            FROM public.daily_view_leaderboard d
            WHERE d.leaderboard_date = (vs.started_at AT TIME ZONE 'UTC')::DATE
        ) ranked
        WHERE ranked.user_id = c.owner_id
    ) ranked_owner ON TRUE
    WHERE vs.status IN ('INITIALIZED', 'CONTENT_READY')
) ranked_sessions
ON CONFLICT (session_id) DO NOTHING;

-- Expire stale in-flight sessions now that assignment-state triggers exist.
UPDATE public.view_sessions
SET status = 'EXPIRED'
WHERE status IN ('INITIALIZED', 'CONTENT_READY')
  AND expires_at <= pg_catalog.clock_timestamp();

-- Sequential featured allocation. Cursor row + advisory lock serialize same-viewer
-- retries; campaign row FOR UPDATE serializes all viewers competing for one campaign.
CREATE OR REPLACE FUNCTION public.request_view_session()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_uid UUID := (SELECT auth.uid());
    v_day DATE := (pg_catalog.clock_timestamp() AT TIME ZONE 'UTC')::DATE;
    v_cursor public.viewer_daily_cursor%ROWTYPE;
    v_existing_active RECORD;
    v_ranked RECORD;
    v_campaign public.campaigns%ROWTYPE;
    v_price public.duration_pricing%ROWTYPE;
    v_new_session public.view_sessions%ROWTYPE;
    v_active_sessions INTEGER;
    v_start_rank INTEGER := 1;
    v_last_rank_seen INTEGER;
    v_position BIGINT;
    v_owner_rank INTEGER;
    v_random_pivot UUID;
    v_pass INTEGER;
    v_campaign_found BOOLEAN := FALSE;
    v_started_at TIMESTAMPTZ;
    v_expires_at TIMESTAMPTZ;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::BOOLEAN), FALSE) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtext('view_session_req_' || v_uid::TEXT)
    );

    -- Expire all stale reservations before taking any campaign lock. This preserves
    -- the session -> campaign lock order used by completion and releases assignment state.
    UPDATE public.view_sessions
    SET status = 'EXPIRED'
    WHERE status IN ('INITIALIZED', 'CONTENT_READY')
      AND expires_at <= pg_catalog.clock_timestamp();

    SELECT
        vs.*,
        c.url,
        c.domain,
        c.resolved_target_url,
        c.resolver_status,
        a.owner_rank AS assigned_owner_rank
    INTO v_existing_active
    FROM public.view_sessions vs
    JOIN public.campaigns c ON c.id = vs.campaign_id
    LEFT JOIN public.special_campaign_assignments a ON a.session_id = vs.id
    WHERE vs.viewer_id = v_uid
      AND vs.status IN ('INITIALIZED', 'CONTENT_READY')
      AND vs.expires_at > pg_catalog.clock_timestamp()
    ORDER BY vs.started_at DESC
    LIMIT 1;

    IF v_existing_active.id IS NOT NULL THEN
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
                'started_at', (EXTRACT(EPOCH FROM v_existing_active.started_at) * 1000)::BIGINT,
                'featured_rank', COALESCE(v_existing_active.assigned_owner_rank, v_existing_active.leaderboard_feature_rank)
            );
        END IF;
    END IF;

    INSERT INTO public.viewer_daily_cursor (viewer_id, day_utc)
    VALUES (v_uid, v_day)
    ON CONFLICT (viewer_id, day_utc) DO NOTHING;

    SELECT *
    INTO v_cursor
    FROM public.viewer_daily_cursor
    WHERE viewer_id = v_uid
      AND day_utc = v_day
    FOR UPDATE;

    v_cursor.visited_owner_ids := COALESCE(v_cursor.visited_owner_ids, ARRAY[]::UUID[]);
    v_position := v_cursor.request_position + 1;

    IF NOT v_cursor.exhausted THEN
        v_start_rank := COALESCE(v_cursor.last_selected_rank, 0) + 1;

        FOR v_ranked IN
            SELECT ranked.user_id, ranked.owner_rank
            FROM (
                SELECT
                    d.user_id,
                    pg_catalog.row_number() OVER (
                        ORDER BY d.completed_views DESC, d.user_id ASC
                    )::INTEGER AS owner_rank
                FROM public.daily_view_leaderboard d
                WHERE d.leaderboard_date = v_day
            ) ranked
            WHERE ranked.owner_rank >= v_start_rank
              AND NOT (ranked.user_id = ANY (v_cursor.visited_owner_ids))
            ORDER BY ranked.owner_rank ASC
        LOOP
            v_last_rank_seen := v_ranked.owner_rank;
            v_cursor.visited_owner_ids := pg_catalog.array_append(
                v_cursor.visited_owner_ids,
                v_ranked.user_id
            );

            -- A viewer never receives their own campaign.
            IF v_ranked.user_id = v_uid THEN
                CONTINUE;
            END IF;

            -- Preserve the existing two-minute advertiser diversity cooldown.
            IF EXISTS (
                SELECT 1
                FROM public.view_sessions recent_vs
                JOIN public.campaigns recent_campaign
                  ON recent_campaign.id = recent_vs.campaign_id
                WHERE recent_vs.viewer_id = v_uid
                  AND recent_vs.status = 'COMPLETED'
                  AND recent_vs.completed_at > (
                      pg_catalog.clock_timestamp() - INTERVAL '2 minutes'
                  )
                  AND recent_campaign.owner_id = v_ranked.user_id
            ) THEN
                CONTINUE;
            END IF;

            FOR v_campaign IN
                SELECT c.*
                FROM public.campaigns c
                WHERE c.owner_id = v_ranked.user_id
                  AND c.status = 'ACTIVE'
                  AND c.completed_views < c.target_views
                  AND c.reserved_budget >= c.cost_per_view
                  AND (
                      c.keyword IS NULL
                      OR (c.resolver_status = 'READY' AND c.resolved_target_url IS NOT NULL)
                  )
                ORDER BY
                    c.completed_views::NUMERIC / NULLIF(c.target_views, 0),
                    c.created_at ASC,
                    c.id ASC
                FOR UPDATE OF c SKIP LOCKED
            LOOP
                SELECT pg_catalog.count(*)::INTEGER
                INTO v_active_sessions
                FROM public.view_sessions vs
                WHERE vs.campaign_id = v_campaign.id
                  AND vs.status IN ('INITIALIZED', 'CONTENT_READY')
                  AND vs.expires_at > pg_catalog.clock_timestamp();

                IF v_campaign.completed_views + v_active_sessions < v_campaign.target_views THEN
                    SELECT *
                    INTO v_price
                    FROM public.duration_pricing
                    WHERE duration_seconds = v_campaign.duration_seconds;

                    IF NOT FOUND THEN
                        RAISE EXCEPTION 'INVALID_DURATION: Pricing row for campaign duration is missing';
                    END IF;

                    v_started_at := pg_catalog.clock_timestamp();
                    v_expires_at := v_started_at + INTERVAL '3 minutes';

                    INSERT INTO public.view_sessions (
                        campaign_id,
                        viewer_id,
                        keyword,
                        required_duration_seconds,
                        reward_coins,
                        status,
                        started_at,
                        created_at,
                        expires_at
                    )
                    VALUES (
                        v_campaign.id,
                        v_uid,
                        v_campaign.keyword,
                        v_campaign.duration_seconds,
                        v_price.viewer_reward,
                        'INITIALIZED',
                        v_started_at,
                        v_started_at,
                        v_expires_at
                    )
                    RETURNING * INTO v_new_session;

                    UPDATE public.viewer_daily_cursor
                    SET last_selected_owner_id = v_ranked.user_id,
                        last_selected_rank = v_ranked.owner_rank,
                        request_position = request_position + 1,
                        exhausted = FALSE,
                        visited_owner_ids = v_cursor.visited_owner_ids,
                        updated_at = pg_catalog.clock_timestamp()
                    WHERE viewer_id = v_uid
                      AND day_utc = v_day;

                    INSERT INTO public.special_campaign_assignments (
                        session_id,
                        viewer_id,
                        campaign_owner_id,
                        campaign_id,
                        assigned_position,
                        owner_rank,
                        assignment_type,
                        reserved_views,
                        created_at,
                        expires_at
                    )
                    VALUES (
                        v_new_session.id,
                        v_uid,
                        v_campaign.owner_id,
                        v_campaign.id,
                        v_position,
                        v_ranked.owner_rank,
                        'featured',
                        1,
                        v_started_at,
                        v_expires_at
                    );

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
                        'started_at', (EXTRACT(EPOCH FROM v_new_session.started_at) * 1000)::BIGINT,
                        'featured_rank', v_ranked.owner_rank
                    );
                END IF;
            END LOOP;
        END LOOP;

        -- Every remaining rank was examined. Do not wrap or restart this UTC day.
        UPDATE public.viewer_daily_cursor
        SET last_selected_rank = CASE
                WHEN v_last_rank_seen IS NULL THEN last_selected_rank
                ELSE v_last_rank_seen
            END,
            visited_owner_ids = v_cursor.visited_owner_ids,
            exhausted = TRUE,
            updated_at = pg_catalog.clock_timestamp()
        WHERE viewer_id = v_uid
          AND day_utc = v_day;
    END IF;

    -- Preserve the existing randomized normal-distribution fallback, including
    -- its anti-repeat passes. Capacity is still checked while holding each row lock.
    v_random_pivot := pg_catalog.md5(
        pg_catalog.random()::TEXT
        || pg_catalog.clock_timestamp()::TEXT
        || v_uid::TEXT
    )::UUID;

    FOR v_pass IN 1..4 LOOP
        FOR v_campaign IN
            SELECT c.*
            FROM public.campaigns c
            WHERE c.status = 'ACTIVE'
              AND c.owner_id <> v_uid
              AND c.completed_views < c.target_views
              AND c.reserved_budget >= c.cost_per_view
              AND (
                  c.keyword IS NULL
                  OR (c.resolver_status = 'READY' AND c.resolved_target_url IS NOT NULL)
              )
              AND (v_pass NOT IN (1, 3) OR c.id >= v_random_pivot)
              AND (
                  v_pass IN (3, 4)
                  OR NOT EXISTS (
                      SELECT 1
                      FROM public.view_sessions recent_vs
                      JOIN public.campaigns recent_campaign
                        ON recent_campaign.id = recent_vs.campaign_id
                      WHERE recent_vs.viewer_id = v_uid
                        AND recent_vs.status = 'COMPLETED'
                        AND recent_vs.completed_at > (
                            pg_catalog.clock_timestamp() - INTERVAL '2 minutes'
                        )
                        AND recent_campaign.owner_id = c.owner_id
                  )
              )
            ORDER BY c.id ASC
            FOR UPDATE OF c SKIP LOCKED
        LOOP
            SELECT pg_catalog.count(*)::INTEGER
            INTO v_active_sessions
            FROM public.view_sessions vs
            WHERE vs.campaign_id = v_campaign.id
              AND vs.status IN ('INITIALIZED', 'CONTENT_READY')
              AND vs.expires_at > pg_catalog.clock_timestamp();

            IF v_campaign.completed_views + v_active_sessions < v_campaign.target_views THEN
                v_campaign_found := TRUE;
                EXIT;
            END IF;
        END LOOP;

        EXIT WHEN v_campaign_found;
    END LOOP;

    IF NOT v_campaign_found THEN
        RETURN NULL;
    END IF;

    SELECT *
    INTO v_price
    FROM public.duration_pricing
    WHERE duration_seconds = v_campaign.duration_seconds;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_DURATION: Pricing row for campaign duration is missing';
    END IF;

    SELECT ranked.owner_rank
    INTO v_owner_rank
    FROM (
        SELECT
            d.user_id,
            pg_catalog.row_number() OVER (
                ORDER BY d.completed_views DESC, d.user_id ASC
            )::INTEGER AS owner_rank
        FROM public.daily_view_leaderboard d
        WHERE d.leaderboard_date = v_day
    ) ranked
    WHERE ranked.user_id = v_campaign.owner_id;

    v_started_at := pg_catalog.clock_timestamp();
    v_expires_at := v_started_at + INTERVAL '3 minutes';

    INSERT INTO public.view_sessions (
        campaign_id,
        viewer_id,
        keyword,
        required_duration_seconds,
        reward_coins,
        status,
        started_at,
        created_at,
        expires_at
    )
    VALUES (
        v_campaign.id,
        v_uid,
        v_campaign.keyword,
        v_campaign.duration_seconds,
        v_price.viewer_reward,
        'INITIALIZED',
        v_started_at,
        v_started_at,
        v_expires_at
    )
    RETURNING * INTO v_new_session;

    INSERT INTO public.special_campaign_assignments (
        session_id,
        viewer_id,
        campaign_owner_id,
        campaign_id,
        assigned_position,
        owner_rank,
        assignment_type,
        reserved_views,
        created_at,
        expires_at
    )
    VALUES (
        v_new_session.id,
        v_uid,
        v_campaign.owner_id,
        v_campaign.id,
        v_position,
        v_owner_rank,
        'normal',
        1,
        v_started_at,
        v_expires_at
    );

    UPDATE public.viewer_daily_cursor
    SET request_position = request_position + 1,
        updated_at = pg_catalog.clock_timestamp()
    WHERE viewer_id = v_uid
      AND day_utc = v_day;

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
        'started_at', (EXTRACT(EPOCH FROM v_new_session.started_at) * 1000)::BIGINT,
        'featured_rank', v_owner_rank
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.request_view_session() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_view_session() TO authenticated;

-- Content-ready is also bounded by the server-issued three-minute TTL.
CREATE OR REPLACE FUNCTION public.signal_content_ready(p_session_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_uid UUID := (SELECT auth.uid());
    v_session public.view_sessions%ROWTYPE;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::BOOLEAN), FALSE) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ARGUMENT: Session ID cannot be null';
    END IF;

    SELECT *
    INTO v_session
    FROM public.view_sessions
    WHERE id = p_session_id
      AND viewer_id = v_uid
    FOR UPDATE;

    IF NOT FOUND OR v_session.status <> 'INITIALIZED' THEN
        RETURN FALSE;
    END IF;

    IF v_session.expires_at <= pg_catalog.clock_timestamp() THEN
        UPDATE public.view_sessions
        SET status = 'EXPIRED'
        WHERE id = v_session.id;
        RETURN FALSE;
    END IF;

    UPDATE public.view_sessions
    SET content_ready_at = COALESCE(content_ready_at, pg_catalog.clock_timestamp()),
        status = 'CONTENT_READY'
    WHERE id = v_session.id
      AND viewer_id = v_uid
      AND status = 'INITIALIZED'
      AND expires_at > pg_catalog.clock_timestamp();

    RETURN FOUND;
END;
$function$;

REVOKE ALL ON FUNCTION public.signal_content_ready(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.signal_content_ready(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.complete_view_session(
    p_session_id UUID,
    p_idempotency_key TEXT
) RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_uid UUID := (select auth.uid());
    v_clean_key TEXT;
    v_existing_by_key RECORD;
    v_session RECORD;
    v_campaign RECORD;
    v_owner RECORD;
    v_viewer RECORD;
    v_first_lock UUID;
    v_second_lock UUID;
    v_dummy_profile RECORD;
    v_elapsed_seconds NUMERIC;
    v_campaign_completed BOOLEAN := FALSE;
    v_active_session_count INTEGER;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ARGUMENT: Session ID cannot be null';
    END IF;

    v_clean_key := trim(p_idempotency_key);
    IF v_clean_key IS NULL OR length(v_clean_key) = 0 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Idempotency key cannot be empty';
    END IF;

    IF length(v_clean_key) > 128 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Idempotency key exceeds maximum length of 128 characters';
    END IF;

    SELECT * INTO v_existing_by_key
    FROM public.view_sessions
    WHERE idempotency_key = v_clean_key;

    IF v_existing_by_key IS NOT NULL THEN
        IF v_existing_by_key.viewer_id <> v_uid THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT: Key has already been used by another user';
        END IF;
        IF v_existing_by_key.id <> p_session_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT: Key has already been associated with a different session';
        END IF;
        IF v_existing_by_key.status = 'COMPLETED' THEN
            SELECT available_coins, lifetime_earned, completed_views_count
            INTO v_viewer
            FROM public.profiles
            WHERE id = v_uid;

            SELECT completed_views >= target_views
            INTO v_campaign_completed
            FROM public.campaigns
            WHERE id = v_existing_by_key.campaign_id;

            RETURN pg_catalog.json_build_object(
                'success', TRUE,
                'reward', v_existing_by_key.reward_coins,
                'already_completed', TRUE,
                'available_coins', COALESCE(v_viewer.available_coins, 0),
                'lifetime_earned', COALESCE(v_viewer.lifetime_earned, 0),
                'completed_views_count', COALESCE(v_viewer.completed_views_count, 0),
                'campaign_completed', COALESCE(v_campaign_completed, FALSE)
            );
        END IF;
    END IF;

    SELECT * INTO v_session
    FROM public.view_sessions
    WHERE id = p_session_id
    FOR UPDATE;

    IF v_session IS NULL THEN
        RAISE EXCEPTION 'SESSION_NOT_FOUND: View session does not exist';
    END IF;

    IF v_session.viewer_id <> v_uid THEN
        RAISE EXCEPTION 'FORBIDDEN: Session does not belong to the caller';
    END IF;

    IF v_session.status = 'COMPLETED' THEN
        SELECT available_coins, lifetime_earned, completed_views_count
        INTO v_viewer
        FROM public.profiles
        WHERE id = v_uid;

        SELECT completed_views >= target_views
        INTO v_campaign_completed
        FROM public.campaigns
        WHERE id = v_session.campaign_id;

        RETURN pg_catalog.json_build_object(
            'success', TRUE,
            'reward', v_session.reward_coins,
            'already_completed', TRUE,
            'available_coins', COALESCE(v_viewer.available_coins, 0),
            'lifetime_earned', COALESCE(v_viewer.lifetime_earned, 0),
            'completed_views_count', COALESCE(v_viewer.completed_views_count, 0),
            'campaign_completed', COALESCE(v_campaign_completed, FALSE)
        );
    END IF;

    IF v_session.status <> 'CONTENT_READY' THEN
        RAISE EXCEPTION 'INVALID_SESSION_STATUS: Session is % but must be CONTENT_READY to complete', v_session.status;
    END IF;

    IF v_session.content_ready_at IS NULL THEN
        RAISE EXCEPTION 'INVALID_SESSION_STATE: Content ready signal was never received';
    END IF;

    -- Enforce the server-issued TTL before any financial or profile mutation.
    IF v_session.expires_at IS NOT NULL
       AND v_session.expires_at <= pg_catalog.clock_timestamp() THEN
        UPDATE public.view_sessions
        SET status = 'EXPIRED'
        WHERE id = v_session.id
          AND status = 'CONTENT_READY';

        RETURN pg_catalog.json_build_object(
            'success', FALSE,
            'expired', TRUE,
            'reward', 0,
            'already_completed', FALSE
        );
    END IF;


    v_elapsed_seconds := extract(epoch from (pg_catalog.clock_timestamp() - v_session.content_ready_at));

    IF v_elapsed_seconds < (v_session.required_duration_seconds - 1.0) THEN
        RAISE EXCEPTION 'PREMATURE_COMPLETION: Elapsed time (%) is less than required duration (%)',
            v_elapsed_seconds, v_session.required_duration_seconds;
    END IF;

    SELECT * INTO v_campaign
    FROM public.campaigns
    WHERE id = v_session.campaign_id
    FOR UPDATE;

    IF v_campaign IS NULL THEN
        RAISE EXCEPTION 'CAMPAIGN_NOT_FOUND: Associated campaign no longer exists';
    END IF;

    IF v_campaign.status NOT IN ('ACTIVE', 'PAUSED') THEN
        RAISE EXCEPTION 'CAMPAIGN_INACTIVE: Campaign is % but must be ACTIVE or PAUSED', v_campaign.status;
    END IF;

    IF v_campaign.completed_views >= v_campaign.target_views THEN
        RAISE EXCEPTION 'CAMPAIGN_EXHAUSTED: Campaign has already reached its target view count';
    END IF;

    -- The current session is itself one active reservation. Reject any legacy or
    -- externally-created over-reservation before consuming money or counters.
    SELECT pg_catalog.count(*)::INTEGER
    INTO v_active_session_count
    FROM public.view_sessions active_vs
    WHERE active_vs.campaign_id = v_campaign.id
      AND active_vs.status IN ('INITIALIZED', 'CONTENT_READY')
      AND active_vs.expires_at > pg_catalog.clock_timestamp();

    IF v_campaign.completed_views + v_active_session_count > v_campaign.target_views THEN
        RAISE EXCEPTION 'CAMPAIGN_OVER_RESERVED: Completed plus active views (%) exceed target (%)',
            v_campaign.completed_views + v_active_session_count,
            v_campaign.target_views;
    END IF;

    IF v_campaign.reserved_budget < v_campaign.cost_per_view THEN
        RAISE EXCEPTION 'INSUFFICIENT_CAMPAIGN_BUDGET: Campaign reserved budget (%) is less than cost per view (%)',
            v_campaign.reserved_budget, v_campaign.cost_per_view;
    END IF;

    v_campaign_completed := (v_campaign.completed_views + 1 >= v_campaign.target_views);

    v_first_lock := CASE WHEN v_campaign.owner_id < v_uid THEN v_campaign.owner_id ELSE v_uid END;
    v_second_lock := CASE WHEN v_campaign.owner_id < v_uid THEN v_uid ELSE v_campaign.owner_id END;

    SELECT * INTO v_dummy_profile FROM public.profiles WHERE id = v_first_lock FOR UPDATE;
    IF v_first_lock <> v_second_lock THEN
        SELECT * INTO v_dummy_profile FROM public.profiles WHERE id = v_second_lock FOR UPDATE;
    END IF;

    SELECT * INTO v_owner FROM public.profiles WHERE id = v_campaign.owner_id;
    SELECT * INTO v_viewer FROM public.profiles WHERE id = v_uid;

    IF v_owner.reserved_coins < v_campaign.cost_per_view THEN
        RAISE EXCEPTION 'INSUFFICIENT_RESERVED_BALANCE: Campaign owner reserved balance (%) is less than cost per view (%)',
            v_owner.reserved_coins, v_campaign.cost_per_view;
    END IF;

    UPDATE public.campaigns
    SET completed_views = completed_views + 1,
        spent_budget = spent_budget + cost_per_view,
        reserved_budget = reserved_budget - cost_per_view,
        status = CASE WHEN completed_views + 1 >= target_views THEN 'COMPLETED' ELSE status END,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_campaign.id;

    UPDATE public.profiles
    SET reserved_coins = reserved_coins - v_campaign.cost_per_view,
        lifetime_spent = lifetime_spent + v_campaign.cost_per_view,
        received_views_count = received_views_count + 1,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_campaign.owner_id;

    UPDATE public.profiles
    SET available_coins = available_coins + v_session.reward_coins,
        lifetime_earned = lifetime_earned + v_session.reward_coins,
        completed_views_count = completed_views_count + 1,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_uid
    RETURNING available_coins, lifetime_earned, completed_views_count
    INTO v_viewer;

    UPDATE public.view_sessions
    SET status = 'COMPLETED',
        completed_at = pg_catalog.clock_timestamp(),
        idempotency_key = v_clean_key
    WHERE id = v_session.id;

    INSERT INTO public.coin_ledger(
        user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
    )
    VALUES(
        v_uid, v_session.reward_coins, 'VIEW_REWARD',
        'مشاهده موفق ' || v_session.required_duration_seconds || ' ثانیه‌ای از ' || v_campaign.domain,
        v_campaign.id::text, v_clean_key, pg_catalog.clock_timestamp()
    );

    INSERT INTO public.coin_ledger(
        user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
    )
    VALUES(
        v_campaign.owner_id, -v_campaign.cost_per_view, 'CAMPAIGN_SPEND',
        'مصرف بودجه بازدید از ' || v_campaign.domain,
        v_campaign.id::text, 'spend_' || v_session.id::text, pg_catalog.clock_timestamp()
    );

    RETURN pg_catalog.json_build_object(
        'success', TRUE,
        'reward', v_session.reward_coins,
        'already_completed', FALSE,
        'available_coins', COALESCE(v_viewer.available_coins, 0),
        'lifetime_earned', COALESCE(v_viewer.lifetime_earned, 0),
        'completed_views_count', COALESCE(v_viewer.completed_views_count, 0),
        'campaign_completed', v_campaign_completed
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.complete_view_session(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_view_session(UUID, TEXT) TO authenticated;

-- Rebind updates campaign owners and session viewers first; their triggers update
-- assignment rows. The cursor itself must be moved before the old profile is deleted.
CREATE OR REPLACE FUNCTION private.rebind_user_account(p_old_uid UUID, p_new_uid UUID, p_install_id TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_old_profile public.profiles%ROWTYPE;
    v_new_profile public.profiles%ROWTYPE;
    v_old_handle TEXT;
    v_new_install_id TEXT;
BEGIN
    IF p_old_uid IS NULL OR p_new_uid IS NULL OR p_old_uid = p_new_uid THEN
        RETURN;
    END IF;

    PERFORM 1 FROM auth.users WHERE id = p_new_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_REBIND_TARGET_AUTH_NOT_FOUND';
    END IF;

    SELECT * INTO v_old_profile
    FROM public.profiles
    WHERE id = p_old_uid
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_REBIND_SOURCE_PROFILE_NOT_FOUND';
    END IF;

    SELECT * INTO v_new_profile
    FROM public.profiles
    WHERE id = p_new_uid
    FOR UPDATE;
    IF FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_REBIND_TARGET_PROFILE_EXISTS';
    END IF;

    v_old_handle := v_old_profile.user_handle;
    v_new_install_id := NULLIF(pg_catalog.btrim(COALESCE(p_install_id, '')), '');
    IF v_new_install_id IS NULL THEN
        v_new_install_id := v_old_profile.app_install_id;
    END IF;

    UPDATE public.profiles
    SET user_handle = '__rebind__' || p_old_uid::TEXT
    WHERE id = p_old_uid;

    INSERT INTO public.profiles(
        id, user_handle, app_install_id, available_coins, reserved_coins,
        lifetime_earned, lifetime_spent, trust_score, completed_views_count,
        received_views_count, welcome_bonus_claimed, created_at, updated_at
    )
    VALUES(
        p_new_uid, v_old_handle, v_new_install_id, v_old_profile.available_coins,
        v_old_profile.reserved_coins, v_old_profile.lifetime_earned,
        v_old_profile.lifetime_spent, v_old_profile.trust_score,
        v_old_profile.completed_views_count, v_old_profile.received_views_count,
        v_old_profile.welcome_bonus_claimed, v_old_profile.created_at, pg_catalog.clock_timestamp()
    );

    UPDATE public.auto_view_entitlements SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.auto_view_purchases SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.campaigns SET owner_id = p_new_uid WHERE owner_id = p_old_uid;
    UPDATE public.coin_ledger SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.coin_transfers SET sender_id = p_new_uid WHERE sender_id = p_old_uid;
    UPDATE public.coin_transfers SET recipient_id = p_new_uid WHERE recipient_id = p_old_uid;
    UPDATE public.daily_bonus_grants SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.view_sessions SET viewer_id = p_new_uid WHERE viewer_id = p_old_uid;
    UPDATE public.welcome_bonus_grants SET user_id = p_new_uid WHERE user_id = p_old_uid;

    UPDATE private.campaign_preflight_tokens SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE private.daily_bonus_device_claims
    SET beneficiary_auth_uid = p_new_uid
    WHERE beneficiary_auth_uid = p_old_uid;

    INSERT INTO private.rate_limit_buckets AS target(
        user_id, action,
        ten_second_started_at, ten_second_count,
        minute_started_at, minute_count,
        five_minute_started_at, five_minute_count,
        hour_started_at, hour_count,
        blocked_until, updated_at
    )
    SELECT
        p_new_uid,
        source.action,
        source.ten_second_started_at,
        source.ten_second_count,
        source.minute_started_at,
        source.minute_count,
        source.five_minute_started_at,
        source.five_minute_count,
        source.hour_started_at,
        source.hour_count,
        source.blocked_until,
        source.updated_at
    FROM private.rate_limit_buckets AS source
    WHERE source.user_id = p_old_uid
    ON CONFLICT (user_id, action) DO UPDATE
    SET ten_second_started_at = LEAST(target.ten_second_started_at, EXCLUDED.ten_second_started_at),
        ten_second_count = GREATEST(target.ten_second_count, EXCLUDED.ten_second_count),
        minute_started_at = LEAST(target.minute_started_at, EXCLUDED.minute_started_at),
        minute_count = GREATEST(target.minute_count, EXCLUDED.minute_count),
        five_minute_started_at = LEAST(target.five_minute_started_at, EXCLUDED.five_minute_started_at),
        five_minute_count = GREATEST(target.five_minute_count, EXCLUDED.five_minute_count),
        hour_started_at = LEAST(target.hour_started_at, EXCLUDED.hour_started_at),
        hour_count = GREATEST(target.hour_count, EXCLUDED.hour_count),
        blocked_until = CASE
            WHEN target.blocked_until IS NULL THEN EXCLUDED.blocked_until
            WHEN EXCLUDED.blocked_until IS NULL THEN target.blocked_until
            ELSE GREATEST(target.blocked_until, EXCLUDED.blocked_until)
        END,
        updated_at = GREATEST(target.updated_at, EXCLUDED.updated_at);

    DELETE FROM private.rate_limit_buckets WHERE user_id = p_old_uid;

    UPDATE private.welcome_bonus_entitlements
    SET beneficiary_auth_uid = p_new_uid
    WHERE beneficiary_auth_uid = p_old_uid;

    UPDATE public.referrals
    SET inviter_id = CASE WHEN inviter_id = p_old_uid THEN p_new_uid ELSE inviter_id END,
        invitee_id = CASE WHEN invitee_id = p_old_uid THEN p_new_uid ELSE invitee_id END,
        updated_at = pg_catalog.clock_timestamp()
    WHERE inviter_id = p_old_uid OR invitee_id = p_old_uid;

    UPDATE private.referral_reward_grants
    SET recipient_id = p_new_uid
    WHERE recipient_id = p_old_uid;

    -- Preserve both credited replay history and pending purchases during reinstalls.
    UPDATE private.coin_purchase_intents
    SET user_id = p_new_uid
    WHERE user_id = p_old_uid;

    UPDATE private.coin_purchases
    SET user_id = p_new_uid
    WHERE user_id = p_old_uid;


    -- Preserve the per-UTC-day cursor when an Auth UID is rebound.
    -- Move the denormalized UTC-day ranking before deleting the old profile.
    UPDATE public.daily_view_leaderboard
    SET user_id = p_new_uid,
        updated_at = pg_catalog.clock_timestamp()
    WHERE user_id = p_old_uid;

    UPDATE public.viewer_daily_cursor
    SET viewer_id = p_new_uid,
        last_selected_owner_id = CASE
            WHEN last_selected_owner_id = p_old_uid THEN p_new_uid
            ELSE last_selected_owner_id
        END,
        visited_owner_ids = pg_catalog.array_replace(visited_owner_ids, p_old_uid, p_new_uid),
        updated_at = pg_catalog.clock_timestamp()
    WHERE viewer_id = p_old_uid;

    DELETE FROM public.profiles WHERE id = p_old_uid;
END;
$function$;

REVOKE ALL ON FUNCTION private.rebind_user_account(UUID, UUID, TEXT)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.rebind_user_account(UUID, UUID, TEXT) TO postgres;

COMMIT;
