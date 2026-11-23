BEGIN;

-- One cursor row serializes each authenticated viewer's daily UTC progression.
CREATE TABLE IF NOT EXISTS private.daily_featured_viewer_cursor (
    viewer_id uuid NOT NULL
        REFERENCES public.profiles(id) ON DELETE CASCADE,
    day_utc date NOT NULL,
    next_request_position bigint NOT NULL DEFAULT 1
        CHECK (next_request_position > 0),
    last_selected_rank integer NULL
        CHECK (last_selected_rank IS NULL OR last_selected_rank > 0),
    last_selected_owner_id uuid NULL,
    exhausted boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
    PRIMARY KEY (viewer_id, day_utc)
);

ALTER TABLE private.daily_featured_viewer_cursor ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.daily_featured_viewer_cursor
    FROM PUBLIC, anon, authenticated, authenticator, service_role;

COMMENT ON TABLE private.daily_featured_viewer_cursor IS
    'Private per-viewer, per-UTC-day sequential featured-placement cursor. No client read/write access.';

-- This is an append-oriented audit trail. Campaign/session deletion nulls those
-- references but does not erase the evidence that an assignment was made.
CREATE TABLE IF NOT EXISTS private.daily_featured_campaign_assignment (
    assignment_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
    viewer_id uuid NOT NULL
        REFERENCES public.profiles(id) ON DELETE CASCADE,
    day_utc date NOT NULL,
    request_position bigint NOT NULL CHECK (request_position > 0),
    -- Keep the selected owner's UUID as immutable audit evidence even after
    -- profile deletion; this column intentionally has no profile FK.
    owner_id uuid NOT NULL,
    campaign_id uuid NULL
        REFERENCES public.campaigns(id) ON DELETE SET NULL,
    leaderboard_rank integer NOT NULL CHECK (leaderboard_rank > 0),
    leaderboard_completed_views integer NOT NULL
        CHECK (leaderboard_completed_views > 0),
    leaderboard_user_handle text NOT NULL
        CHECK (pg_catalog.btrim(leaderboard_user_handle) <> ''),
    leaderboard_as_of timestamptz NOT NULL,
    session_id uuid NULL UNIQUE
        REFERENCES public.view_sessions(id) ON DELETE SET NULL,
    reservation_status text NOT NULL DEFAULT 'RESERVED'
        CHECK (reservation_status IN ('RESERVED', 'COMPLETED', 'RELEASED', 'EXPIRED')),
    created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
    expires_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
    CONSTRAINT daily_featured_assignment_expiry_after_creation
        CHECK (expires_at > created_at),
    CONSTRAINT daily_featured_assignment_unique_position
        UNIQUE (viewer_id, day_utc, request_position),
    CONSTRAINT daily_featured_assignment_unique_owner_per_day
        UNIQUE (viewer_id, day_utc, owner_id)
);

ALTER TABLE private.daily_featured_campaign_assignment ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.daily_featured_campaign_assignment
    FROM PUBLIC, anon, authenticated, authenticator, service_role;

CREATE INDEX IF NOT EXISTS idx_daily_featured_assignment_campaign
    ON private.daily_featured_campaign_assignment (campaign_id)
    WHERE campaign_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_daily_featured_assignment_viewer_day
    ON private.daily_featured_campaign_assignment (viewer_id, day_utc, request_position DESC);

COMMENT ON TABLE private.daily_featured_campaign_assignment IS
    'Auditable daily featured placement and capacity reservation. Stores the live rank/score/handle snapshot used for the actual session assignment.';

-- Preserve historical weekly assignments, but allow new daily assignments above
-- rank five. NULL week + non-NULL owner/rank denotes the new daily model.
ALTER TABLE public.view_sessions
    ALTER COLUMN leaderboard_feature_rank TYPE integer
    USING leaderboard_feature_rank::integer;

ALTER TABLE public.view_sessions
    DROP CONSTRAINT IF EXISTS view_sessions_leaderboard_feature_fields_check;

ALTER TABLE public.view_sessions
    ADD CONSTRAINT view_sessions_leaderboard_feature_fields_check
    CHECK (
        (
            leaderboard_feature_week IS NULL
            AND leaderboard_feature_owner_id IS NULL
            AND leaderboard_feature_rank IS NULL
        )
        OR
        (
            leaderboard_feature_week IS NOT NULL
            AND leaderboard_feature_owner_id IS NOT NULL
            AND leaderboard_feature_rank IS NOT NULL
            AND leaderboard_feature_rank BETWEEN 1 AND 5
        )
        OR
        (
            leaderboard_feature_week IS NULL
            AND leaderboard_feature_owner_id IS NOT NULL
            AND leaderboard_feature_rank IS NOT NULL
            AND leaderboard_feature_rank > 0
        )
    );

-- Selection uses the campaign row as the serialization point. The helper first
-- obtains the campaign lock, then counts active Session reservations in a new
-- SQL statement (a fresh READ COMMITTED snapshot) before returning the row.
-- This prevents two independent viewers from reserving the same final target.
CREATE OR REPLACE FUNCTION private.lock_eligible_view_campaign(
    p_viewer_id uuid,
    p_owner_id uuid,
    p_random_pivot uuid,
    p_use_random_pivot boolean,
    p_exclude_recent_owner boolean,
    p_featured_order boolean,
    p_expiration_cutoff timestamptz,
    p_day_utc date
)
RETURNS public.campaigns
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_campaign public.campaigns%ROWTYPE;
    v_candidate_id uuid;
    v_active_reservations bigint;
    v_attempted_ids uuid[] := ARRAY[]::uuid[];
BEGIN
    IF p_viewer_id IS NULL OR p_expiration_cutoff IS NULL OR p_day_utc IS NULL THEN
        RETURN NULL;
    END IF;

    LOOP
        SELECT c.id
          INTO v_candidate_id
        FROM public.campaigns c
        WHERE (p_owner_id IS NULL OR c.owner_id = p_owner_id)
          AND c.owner_id <> p_viewer_id
          AND c.status = 'ACTIVE'
          AND c.completed_views < c.target_views
          AND c.reserved_budget >= c.cost_per_view
          AND (
              c.keyword IS NULL
              OR (c.resolver_status = 'READY' AND c.resolved_target_url IS NOT NULL)
          )
          AND (NOT p_use_random_pivot OR c.id >= p_random_pivot)
          -- A daily selected owner is excluded from both ranked and ordinary
          -- fallback distribution for the entire UTC day, not just two minutes.
          AND NOT EXISTS (
              SELECT 1
              FROM private.daily_featured_campaign_assignment assigned_today
              WHERE assigned_today.viewer_id = p_viewer_id
                AND assigned_today.day_utc = p_day_utc
                AND assigned_today.owner_id = c.owner_id
          )
          AND (
              NOT p_exclude_recent_owner
              OR NOT EXISTS (
                  SELECT 1
                  FROM public.view_sessions recent_vs
                  JOIN public.campaigns recent_campaign
                    ON recent_campaign.id = recent_vs.campaign_id
                  WHERE recent_vs.viewer_id = p_viewer_id
                    AND recent_vs.status = 'COMPLETED'
                    AND recent_vs.completed_at >
                        (pg_catalog.clock_timestamp() - INTERVAL '2 minutes')
                    AND recent_campaign.owner_id = c.owner_id
              )
          )
          AND NOT (c.id = ANY(v_attempted_ids))
        ORDER BY
            CASE
                WHEN p_featured_order
                THEN c.completed_views::numeric / NULLIF(c.target_views, 0)
                ELSE NULL::numeric
            END ASC NULLS LAST,
            c.created_at ASC,
            c.id ASC
        LIMIT 1
        FOR UPDATE OF c;

        IF NOT FOUND THEN
            RETURN NULL;
        END IF;

        -- The campaign row remains locked by this transaction. This separate
        -- statement observes Sessions committed while the lock acquisition
        -- above was waiting, under the normal READ COMMITTED API transaction.
        SELECT c.*
          INTO v_campaign
        FROM public.campaigns c
        WHERE c.id = v_candidate_id;

        SELECT pg_catalog.count(*)::bigint
          INTO v_active_reservations
        FROM public.view_sessions vs
        WHERE vs.campaign_id = v_candidate_id
          AND vs.status IN ('INITIALIZED', 'CONTENT_READY')
          AND vs.started_at > p_expiration_cutoff;

        IF v_campaign.id IS NOT NULL
           AND v_campaign.status = 'ACTIVE'
           AND v_campaign.completed_views + v_active_reservations
                < v_campaign.target_views
           AND v_campaign.reserved_budget >= v_campaign.cost_per_view
           AND (
               v_campaign.keyword IS NULL
               OR (
                   v_campaign.resolver_status = 'READY'
                   AND v_campaign.resolved_target_url IS NOT NULL
               )
           ) THEN
            RETURN v_campaign;
        END IF;

        v_attempted_ids := pg_catalog.array_append(v_attempted_ids, v_candidate_id);
    END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION private.lock_eligible_view_campaign(
    uuid, uuid, uuid, boolean, boolean, boolean, timestamptz, date
) FROM PUBLIC, anon, authenticated, authenticator, service_role;

-- Status transitions are the single source of truth for reservation lifecycle.
CREATE OR REPLACE FUNCTION private.sync_daily_featured_assignment_reservation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE private.daily_featured_campaign_assignment a
        SET reservation_status = 'RELEASED',
            updated_at = pg_catalog.clock_timestamp()
        WHERE a.session_id = OLD.id
          AND a.reservation_status = 'RESERVED';
        RETURN OLD;
    END IF;

    IF OLD.status IN ('INITIALIZED', 'CONTENT_READY')
       AND NEW.status NOT IN ('INITIALIZED', 'CONTENT_READY') THEN
        UPDATE private.daily_featured_campaign_assignment a
        SET reservation_status = CASE
                WHEN NEW.status = 'COMPLETED' THEN 'COMPLETED'
                WHEN NEW.status = 'EXPIRED' THEN 'EXPIRED'
                ELSE 'RELEASED'
            END,
            updated_at = pg_catalog.clock_timestamp()
        WHERE a.session_id = NEW.id
          AND a.reservation_status = 'RESERVED';
    END IF;

    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.sync_daily_featured_assignment_reservation()
    FROM PUBLIC, anon, authenticated, authenticator, service_role;

DROP TRIGGER IF EXISTS trg_sync_daily_featured_assignment_reservation_update
    ON public.view_sessions;
DROP TRIGGER IF EXISTS trg_sync_daily_featured_assignment_reservation_delete
    ON public.view_sessions;

CREATE TRIGGER trg_sync_daily_featured_assignment_reservation_update
AFTER UPDATE OF status ON public.view_sessions
FOR EACH ROW
EXECUTE FUNCTION private.sync_daily_featured_assignment_reservation();

CREATE TRIGGER trg_sync_daily_featured_assignment_reservation_delete
BEFORE DELETE ON public.view_sessions
FOR EACH ROW
EXECUTE FUNCTION private.sync_daily_featured_assignment_reservation();

-- The partial index bounds the demand-driven expiry scan. There is no pg_cron
-- extension in this project, so cleanup is performed in a bounded request batch.
CREATE INDEX IF NOT EXISTS idx_view_sessions_active_campaign_started
    ON public.view_sessions (campaign_id, started_at)
    WHERE status IN ('INITIALIZED', 'CONTENT_READY');

CREATE INDEX IF NOT EXISTS idx_view_sessions_stale_active_started
    ON public.view_sessions (started_at, id)
    WHERE status IN ('INITIALIZED', 'CONTENT_READY');

CREATE OR REPLACE FUNCTION public.request_view_session()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_uid uuid := (SELECT auth.uid());
    v_now timestamptz := pg_catalog.clock_timestamp();
    v_day_utc date;
    v_expiration_cutoff timestamptz;
    v_existing_active record;
    v_cursor private.daily_featured_viewer_cursor%ROWTYPE;
    v_ranking jsonb := '[]'::jsonb;
    v_item jsonb;
    v_board_as_of timestamptz;
    v_start_after_rank integer := 0;
    v_rank integer;
    v_owner_id uuid;
    v_owner_handle text;
    v_owner_score integer;
    v_campaign public.campaigns%ROWTYPE;
    v_price public.duration_pricing%ROWTYPE;
    v_new_session public.view_sessions%ROWTYPE;
    v_random_pivot uuid;
    v_campaign_found boolean := false;
    v_fallback_attempt integer;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    v_day_utc := (v_now AT TIME ZONE 'UTC')::date;
    v_expiration_cutoff := v_now - INTERVAL '3 minutes';

    -- One transaction lock per viewer preserves the existing request contract
    -- and prevents duplicate cursor positions for concurrent calls by one user.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtext('view_session_req_' || v_uid::text)
    );

    -- Expire this viewer's stale or no-longer-servable active Session first.
    -- Completion/cancel still serialize on the Session row and can win the race.
    UPDATE public.view_sessions vs
    SET status = 'EXPIRED'
    FROM public.campaigns c
    WHERE c.id = vs.campaign_id
      AND vs.viewer_id = v_uid
      AND vs.status IN ('INITIALIZED', 'CONTENT_READY')
      AND (
          vs.started_at <= v_expiration_cutoff
          OR c.status IN ('COMPLETED', 'CANCELLED')
          OR (
              vs.keyword IS NOT NULL
              AND (
                  c.resolver_status <> 'READY'
                  OR c.resolved_target_url IS NULL
              )
          )
      );

    -- Bounded global cleanup: one viewer request can expire at most 100 other
    -- stale/terminal Sessions. Capacity queries also ignore Sessions older than
    -- the same cutoff, so cleanup backlog cannot overbook campaign targets.
    WITH stale_sessions AS (
        SELECT vs.id
        FROM public.view_sessions vs
        JOIN public.campaigns c ON c.id = vs.campaign_id
        WHERE vs.status IN ('INITIALIZED', 'CONTENT_READY')
          AND (
              vs.started_at <= v_expiration_cutoff
              OR c.status IN ('COMPLETED', 'CANCELLED')
              OR (
                  vs.keyword IS NOT NULL
                  AND (
                      c.resolver_status <> 'READY'
                      OR c.resolved_target_url IS NULL
                  )
              )
          )
        ORDER BY vs.started_at ASC, vs.id ASC
        LIMIT 100
        FOR UPDATE OF vs SKIP LOCKED
    )
    UPDATE public.view_sessions vs
    SET status = 'EXPIRED'
    FROM stale_sessions stale
    WHERE vs.id = stale.id
      AND vs.status IN ('INITIALIZED', 'CONTENT_READY');

    -- Retry semantics: return the same valid active Session without creating a
    -- new Session, consuming a cursor position, or writing a second assignment.
    SELECT
        vs.*,
        c.url,
        c.domain,
        c.resolved_target_url,
        c.resolver_status,
        c.status AS campaign_status
      INTO v_existing_active
    FROM public.view_sessions vs
    JOIN public.campaigns c ON c.id = vs.campaign_id
    WHERE vs.viewer_id = v_uid
      AND vs.status IN ('INITIALIZED', 'CONTENT_READY')
    ORDER BY vs.started_at DESC, vs.id DESC
    LIMIT 1
    FOR UPDATE OF vs;

    IF v_existing_active.id IS NOT NULL THEN
        IF v_existing_active.started_at > v_expiration_cutoff
           AND v_existing_active.campaign_status IN ('ACTIVE', 'PAUSED')
           AND (
               v_existing_active.keyword IS NULL
               OR (
                   v_existing_active.resolver_status = 'READY'
                   AND v_existing_active.resolved_target_url IS NOT NULL
               )
           ) THEN
            RETURN pg_catalog.json_build_object(
                'id', v_existing_active.id,
                'campaign_id', v_existing_active.campaign_id,
                'target_url', CASE
                    WHEN v_existing_active.keyword IS NULL
                    THEN v_existing_active.url
                    ELSE v_existing_active.resolved_target_url
                END,
                'domain', v_existing_active.domain,
                'keyword', v_existing_active.keyword,
                'required_duration_seconds', v_existing_active.required_duration_seconds,
                'reward_coins', v_existing_active.reward_coins,
                'started_at', EXTRACT(EPOCH FROM v_existing_active.started_at) * 1000,
                'featured_rank', v_existing_active.leaderboard_feature_rank
            );
        END IF;

        UPDATE public.view_sessions vs
        SET status = 'EXPIRED'
        WHERE vs.id = v_existing_active.id
          AND vs.status IN ('INITIALIZED', 'CONTENT_READY');
    END IF;

    INSERT INTO private.daily_featured_viewer_cursor (
        viewer_id, day_utc
    )
    VALUES (v_uid, v_day_utc)
    ON CONFLICT (viewer_id, day_utc) DO NOTHING;

    SELECT c.*
      INTO v_cursor
    FROM private.daily_featured_viewer_cursor c
    WHERE c.viewer_id = v_uid
      AND c.day_utc = v_day_utc
    FOR UPDATE;

    -- The rank and score snapshot is taken once per new Session request.
    -- user_id is the final stable tiebreaker; it is never exposed by the view.
    v_board_as_of := pg_catalog.clock_timestamp();

    SELECT COALESCE(
        pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
                'owner_id', ranked.user_id,
                'user_handle', ranked.user_handle,
                'completed_views', ranked.completed_views,
                'rank', ranked.leaderboard_rank
            )
            ORDER BY ranked.leaderboard_rank
        ),
        '[]'::jsonb
    )
      INTO v_ranking
    FROM (
        SELECT
            d.user_id,
            d.user_handle,
            d.completed_views,
            pg_catalog.row_number() OVER (
                ORDER BY d.completed_views DESC, d.user_handle ASC, d.user_id ASC
            )::integer AS leaderboard_rank
        FROM public.daily_view_leaderboard d
        WHERE d.leaderboard_date = v_day_utc
          AND d.completed_views > 0
    ) ranked;

    -- If the last selected owner moved in the live ranking, continue after
    -- that owner's current position. If they disappeared, continue after the
    -- last persisted rank. We never wrap to rank one.
    IF v_cursor.last_selected_owner_id IS NOT NULL THEN
        SELECT (entry.value->>'rank')::integer
          INTO v_start_after_rank
        FROM pg_catalog.jsonb_array_elements(v_ranking) AS entry(value)
        WHERE (entry.value->>'owner_id')::uuid = v_cursor.last_selected_owner_id
        LIMIT 1;

        IF NOT FOUND THEN
            v_start_after_rank := COALESCE(v_cursor.last_selected_rank, 0);
        END IF;
    END IF;

    v_random_pivot := (
        pg_catalog.md5(
            pg_catalog.random()::text
            || v_now::text
            || v_uid::text
        )
    )::uuid;

    IF NOT v_cursor.exhausted THEN
        FOR v_item IN
            SELECT entry.value
            FROM pg_catalog.jsonb_array_elements(v_ranking) AS entry(value)
            WHERE (entry.value->>'rank')::integer > v_start_after_rank
            ORDER BY (entry.value->>'rank')::integer
        LOOP
            v_rank := (v_item->>'rank')::integer;
            v_owner_id := (v_item->>'owner_id')::uuid;
            v_owner_handle := v_item->>'user_handle';
            v_owner_score := (v_item->>'completed_views')::integer;

            IF v_owner_id = v_uid THEN
                CONTINUE;
            END IF;

            -- An owner actually selected earlier today is not selected again,
            -- even if their live rank changes during the day.
            IF EXISTS (
                SELECT 1
                FROM private.daily_featured_campaign_assignment a
                WHERE a.viewer_id = v_uid
                  AND a.day_utc = v_day_utc
                  AND a.owner_id = v_owner_id
            ) THEN
                CONTINUE;
            END IF;

            SELECT *
              INTO v_campaign
            FROM private.lock_eligible_view_campaign(
                v_uid,
                v_owner_id,
                v_random_pivot,
                false,
                true,
                true,
                v_expiration_cutoff,
                v_day_utc
            );

            IF v_campaign.id IS NULL THEN
                CONTINUE;
            END IF;

            SELECT dp.*
              INTO v_price
            FROM public.duration_pricing dp
            WHERE dp.duration_seconds = v_campaign.duration_seconds;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'INVALID_DURATION: Pricing row for campaign duration is missing';
            END IF;

            INSERT INTO public.view_sessions (
                campaign_id,
                viewer_id,
                keyword,
                required_duration_seconds,
                reward_coins,
                status,
                started_at,
                created_at,
                leaderboard_feature_week,
                leaderboard_feature_owner_id,
                leaderboard_feature_rank
            )
            VALUES (
                v_campaign.id,
                v_uid,
                v_campaign.keyword,
                v_campaign.duration_seconds,
                v_price.viewer_reward,
                'INITIALIZED',
                pg_catalog.clock_timestamp(),
                pg_catalog.clock_timestamp(),
                NULL,
                v_owner_id,
                v_rank
            )
            RETURNING * INTO v_new_session;

            INSERT INTO private.daily_featured_campaign_assignment (
                viewer_id,
                day_utc,
                request_position,
                owner_id,
                campaign_id,
                leaderboard_rank,
                leaderboard_completed_views,
                leaderboard_user_handle,
                leaderboard_as_of,
                session_id,
                reservation_status,
                created_at,
                expires_at,
                updated_at
            )
            VALUES (
                v_uid,
                v_day_utc,
                v_cursor.next_request_position,
                v_owner_id,
                v_campaign.id,
                v_rank,
                v_owner_score,
                v_owner_handle,
                v_board_as_of,
                v_new_session.id,
                'RESERVED',
                v_new_session.started_at,
                v_new_session.started_at + INTERVAL '3 minutes',
                pg_catalog.clock_timestamp()
            );

            UPDATE private.daily_featured_viewer_cursor c
            SET next_request_position = c.next_request_position + 1,
                last_selected_rank = v_rank,
                last_selected_owner_id = v_owner_id,
                updated_at = pg_catalog.clock_timestamp()
            WHERE c.viewer_id = v_uid
              AND c.day_utc = v_day_utc;

            RETURN pg_catalog.json_build_object(
                'id', v_new_session.id,
                'campaign_id', v_campaign.id,
                'target_url', CASE
                    WHEN v_campaign.keyword IS NULL
                    THEN v_campaign.url
                    ELSE v_campaign.resolved_target_url
                END,
                'domain', v_campaign.domain,
                'keyword', v_new_session.keyword,
                'required_duration_seconds', v_new_session.required_duration_seconds,
                'reward_coins', v_new_session.reward_coins,
                'started_at', EXTRACT(EPOCH FROM v_new_session.started_at) * 1000,
                'featured_rank', v_rank
            );
        END LOOP;

        -- Exhaustion is persisted for the rest of this UTC day. Do not wrap.
        UPDATE private.daily_featured_viewer_cursor c
        SET exhausted = true,
            updated_at = pg_catalog.clock_timestamp()
        WHERE c.viewer_id = v_uid
          AND c.day_utc = v_day_utc;
    END IF;

    -- No eligible remaining daily rank: preserve the existing ordinary
    -- randomized distribution and advertiser-diversity fallback stages.
    FOR v_fallback_attempt IN 1..4 LOOP
        CASE v_fallback_attempt
            WHEN 1 THEN
                SELECT *
                  INTO v_campaign
                FROM private.lock_eligible_view_campaign(
                    v_uid, NULL, v_random_pivot, true, true, false, v_expiration_cutoff, v_day_utc
                );
            WHEN 2 THEN
                SELECT *
                  INTO v_campaign
                FROM private.lock_eligible_view_campaign(
                    v_uid, NULL, v_random_pivot, false, true, false, v_expiration_cutoff, v_day_utc
                );
            WHEN 3 THEN
                SELECT *
                  INTO v_campaign
                FROM private.lock_eligible_view_campaign(
                    v_uid, NULL, v_random_pivot, true, false, false, v_expiration_cutoff, v_day_utc
                );
            WHEN 4 THEN
                SELECT *
                  INTO v_campaign
                FROM private.lock_eligible_view_campaign(
                    v_uid, NULL, v_random_pivot, false, false, false, v_expiration_cutoff, v_day_utc
                );
        END CASE;

        IF v_campaign.id IS NOT NULL THEN
            v_campaign_found := true;
            EXIT;
        END IF;
    END LOOP;

    IF NOT v_campaign_found THEN
        RETURN NULL;
    END IF;

    SELECT dp.*
      INTO v_price
    FROM public.duration_pricing dp
    WHERE dp.duration_seconds = v_campaign.duration_seconds;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_DURATION: Pricing row for campaign duration is missing';
    END IF;

    INSERT INTO public.view_sessions (
        campaign_id,
        viewer_id,
        keyword,
        required_duration_seconds,
        reward_coins,
        status,
        started_at,
        created_at,
        leaderboard_feature_week,
        leaderboard_feature_owner_id,
        leaderboard_feature_rank
    )
    VALUES (
        v_campaign.id,
        v_uid,
        v_campaign.keyword,
        v_campaign.duration_seconds,
        v_price.viewer_reward,
        'INITIALIZED',
        pg_catalog.clock_timestamp(),
        pg_catalog.clock_timestamp(),
        NULL,
        NULL,
        NULL
    )
    RETURNING * INTO v_new_session;

    UPDATE private.daily_featured_viewer_cursor c
    SET next_request_position = c.next_request_position + 1,
        updated_at = pg_catalog.clock_timestamp()
    WHERE c.viewer_id = v_uid
      AND c.day_utc = v_day_utc;

    RETURN pg_catalog.json_build_object(
        'id', v_new_session.id,
        'campaign_id', v_campaign.id,
        'target_url', CASE
            WHEN v_campaign.keyword IS NULL
            THEN v_campaign.url
            ELSE v_campaign.resolved_target_url
        END,
        'domain', v_campaign.domain,
        'keyword', v_new_session.keyword,
        'required_duration_seconds', v_new_session.required_duration_seconds,
        'reward_coins', v_new_session.reward_coins,
        'started_at', EXTRACT(EPOCH FROM v_new_session.started_at) * 1000,
        'featured_rank', NULL
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.request_view_session() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_view_session() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
