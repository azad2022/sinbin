BEGIN;

-- Ranked weekly campaigns get a limited number of featured impressions:
-- the advertiser's weekly quota equals the number of completed views they
-- personally performed in the same UTC week. Each viewer's first five
-- displayed sessions try ranks 1..5 respectively; session #6 onward stays random.

ALTER TABLE public.view_sessions
  ADD COLUMN IF NOT EXISTS leaderboard_feature_week date,
  ADD COLUMN IF NOT EXISTS leaderboard_feature_owner_id uuid,
  ADD COLUMN IF NOT EXISTS leaderboard_feature_rank smallint;

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
      AND leaderboard_feature_rank BETWEEN 1 AND 5
    )
  );

CREATE TABLE IF NOT EXISTS private.weekly_featured_campaign_quota (
  week_start date NOT NULL,
  owner_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  quota_views integer NOT NULL DEFAULT 0 CHECK (quota_views >= 0),
  reserved_views integer NOT NULL DEFAULT 0 CHECK (reserved_views >= 0),
  completed_views integer NOT NULL DEFAULT 0 CHECK (completed_views >= 0),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (week_start, owner_id)
);

ALTER TABLE private.weekly_featured_campaign_quota ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.weekly_featured_campaign_quota FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.record_weekly_featured_campaign_quota()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  -- A reserved featured impression is consumed only on valid completion.
  -- If the viewer abandons or the session expires/is cancelled, release it.
  IF OLD.leaderboard_feature_week IS NOT NULL
     AND OLD.leaderboard_feature_owner_id IS NOT NULL
     AND OLD.status IN ('INITIALIZED', 'CONTENT_READY')
     AND NEW.status NOT IN ('INITIALIZED', 'CONTENT_READY') THEN
    UPDATE private.weekly_featured_campaign_quota q
    SET reserved_views = pg_catalog.greatest(q.reserved_views - 1, 0),
        completed_views = q.completed_views
          + CASE WHEN NEW.status = 'COMPLETED' THEN 1 ELSE 0 END,
        updated_at = pg_catalog.clock_timestamp()
    WHERE q.week_start = OLD.leaderboard_feature_week
      AND q.owner_id = OLD.leaderboard_feature_owner_id;
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.record_weekly_featured_campaign_quota()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_record_weekly_featured_campaign_quota
  ON public.view_sessions;

CREATE TRIGGER trg_record_weekly_featured_campaign_quota
AFTER UPDATE OF status ON public.view_sessions
FOR EACH ROW
WHEN (
  OLD.status IN ('INITIALIZED', 'CONTENT_READY')
  AND NEW.status NOT IN ('INITIALIZED', 'CONTENT_READY')
)
EXECUTE FUNCTION private.record_weekly_featured_campaign_quota();

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

    -- Count website sessions actually issued to this viewer during the week,
    -- not only completed views. This makes position #6 and later random even
    -- if a viewer abandoned one of the first five sessions.
    SELECT pg_catalog.count(*)::integer
    INTO v_viewer_week_sessions
    FROM public.view_sessions vs
    WHERE vs.viewer_id = v_uid
      AND vs.started_at >= v_week_start_at
      AND vs.started_at < v_week_end_at;

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

    v_random_pivot := (
        pg_catalog.md5(
            pg_catalog.random()::text
            || pg_catalog.clock_timestamp()::text
            || v_uid::text
        )
    )::uuid;

    -- Featured placement: the Nth website issued this UTC week attempts the
    -- campaign of weekly leaderboard rank N. Self-views are never eligible.
    -- The quota row is locked by INSERT .. ON CONFLICT, serializing allocation
    -- across all campaigns owned by the same top-five advertiser.
    IF v_feature_rank IS NOT NULL
       AND v_feature_owner_id IS NOT NULL
       AND v_feature_owner_id <> v_uid
       AND COALESCE(v_feature_score, 0) > 0 THEN

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
            SELECT c.*
            INTO v_campaign
            FROM public.campaigns c
            WHERE c.owner_id = v_feature_owner_id
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
            ORDER BY
              c.completed_views::numeric / NULLIF(c.target_views, 0),
              c.created_at ASC,
              c.id ASC
            FOR UPDATE OF c SKIP LOCKED
            LIMIT 1;

            IF v_campaign.id IS NOT NULL THEN
                UPDATE private.weekly_featured_campaign_quota q
                SET reserved_views = q.reserved_views + 1,
                    updated_at = pg_catalog.clock_timestamp()
                WHERE q.week_start = v_week_start
                  AND q.owner_id = v_feature_owner_id
                  AND q.reserved_views + q.completed_views < q.quota_views;

                IF FOUND THEN
                    -- Mark this session so completion/expiry can consume or
                    -- release exactly this one reserved featured impression.
                    NULL;
                ELSE
                    v_campaign := NULL;
                    v_feature_rank := NULL;
                    v_feature_owner_id := NULL;
                END IF;
            ELSE
                v_feature_rank := NULL;
                v_feature_owner_id := NULL;
            END IF;
        ELSE
            v_feature_rank := NULL;
            v_feature_owner_id := NULL;
        END IF;
    ELSE
        v_feature_rank := NULL;
        v_feature_owner_id := NULL;
    END IF;

    -- From the sixth issued website, or whenever the matching rank's campaign
    -- is not eligible/available, preserve the existing randomized distribution.
    IF v_campaign.id IS NULL THEN
        SELECT c.*
        INTO v_campaign
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_uid
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
    END IF;

    IF v_campaign.id IS NULL THEN
        SELECT c.*
        INTO v_campaign
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_uid
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
    END IF;

    IF v_campaign.id IS NULL THEN
        SELECT c.*
        INTO v_campaign
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_uid
          AND c.completed_views < c.target_views
          AND c.reserved_budget >= c.cost_per_view
          AND (c.keyword IS NULL OR (c.resolver_status = 'READY' AND c.resolved_target_url IS NOT NULL))
          AND c.id >= v_random_pivot
        ORDER BY c.id ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1;
    END IF;

    IF v_campaign.id IS NULL THEN
        SELECT c.*
        INTO v_campaign
        FROM public.campaigns c
        WHERE c.status = 'ACTIVE'
          AND c.owner_id <> v_uid
          AND c.completed_views < c.target_views
          AND c.reserved_budget >= c.cost_per_view
          AND (c.keyword IS NULL OR (c.resolver_status = 'READY' AND c.resolved_target_url IS NOT NULL))
        ORDER BY c.id ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1;
    END IF;

    IF v_campaign.id IS NULL THEN
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
