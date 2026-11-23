BEGIN;

-- Keep exact rolling-window inputs separate from the historical session table.
-- The session table remains the source of truth; this private projection is
-- maintained idempotently and retains only the 30-day window needed by the
-- public leaderboard view.
CREATE TABLE IF NOT EXISTS private.completed_view_leaderboard_events (
    session_id uuid PRIMARY KEY
        REFERENCES public.view_sessions(id) ON DELETE CASCADE,
    user_handle text NOT NULL,
    completed_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
    CONSTRAINT completed_view_leaderboard_events_handle_nonblank
        CHECK (pg_catalog.btrim(user_handle) <> '')
);

ALTER TABLE private.completed_view_leaderboard_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE private.completed_view_leaderboard_events
    FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS authenticated_read_completed_view_leaderboard_events
    ON private.completed_view_leaderboard_events;

CREATE POLICY authenticated_read_completed_view_leaderboard_events
    ON private.completed_view_leaderboard_events
    FOR SELECT
    TO authenticated
    USING (true);

-- The invoker-mode public views below require only these two columns.
-- The private schema is not part of the default Data API exposed schemas.
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT SELECT (user_handle, completed_at)
    ON TABLE private.completed_view_leaderboard_events
    TO authenticated;

CREATE INDEX IF NOT EXISTS idx_completed_view_leaderboard_events_window
    ON private.completed_view_leaderboard_events (completed_at, user_handle);

COMMENT ON TABLE private.completed_view_leaderboard_events IS
    'Private read model for the exact rolling-30-day public leaderboard. One row per completed view session; session history remains in public.view_sessions.';

CREATE OR REPLACE FUNCTION private.sync_completed_view_leaderboard_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_handle text;
    v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
    IF TG_OP = 'DELETE' THEN
        DELETE FROM private.completed_view_leaderboard_events e
        WHERE e.session_id = OLD.id;
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE' AND OLD.status = 'COMPLETED' THEN
        DELETE FROM private.completed_view_leaderboard_events e
        WHERE e.session_id = OLD.id;
    END IF;

    IF NEW.status = 'COMPLETED'
       AND NEW.completed_at IS NOT NULL
       AND NEW.completed_at >= v_now - INTERVAL '30 days'
       AND NEW.completed_at < v_now
       AND NEW.viewer_id IS NOT NULL THEN

        SELECT p.user_handle
          INTO v_handle
        FROM public.profiles p
        WHERE p.id = NEW.viewer_id;

        IF v_handle IS NOT NULL AND pg_catalog.btrim(v_handle) <> '' THEN
            INSERT INTO private.completed_view_leaderboard_events (
                session_id, user_handle, completed_at
            )
            VALUES (
                NEW.id, v_handle, NEW.completed_at
            )
            ON CONFLICT (session_id) DO UPDATE
                SET user_handle = EXCLUDED.user_handle,
                    completed_at = EXCLUDED.completed_at;
        END IF;
    END IF;

    -- Retain only data that can contribute to the exact rolling-30-day view.
    DELETE FROM private.completed_view_leaderboard_events e
    WHERE e.completed_at < v_now - INTERVAL '30 days';

    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.sync_completed_view_leaderboard_event()
    FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_sync_completed_view_leaderboard_events
    ON public.view_sessions;

CREATE TRIGGER trg_sync_completed_view_leaderboard_events
AFTER INSERT OR UPDATE OF status, viewer_id, completed_at OR DELETE
ON public.view_sessions
FOR EACH ROW
EXECUTE FUNCTION private.sync_completed_view_leaderboard_event();

CREATE OR REPLACE FUNCTION private.sync_leaderboard_profile_handle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
    IF NEW.user_handle IS NULL OR pg_catalog.btrim(NEW.user_handle) = '' THEN
        DELETE FROM public.daily_view_leaderboard d
        WHERE d.user_id = NEW.id;

        DELETE FROM public.weekly_view_leaderboard w
        WHERE w.user_id = NEW.id;

        DELETE FROM private.completed_view_leaderboard_events e
        USING public.view_sessions vs
        WHERE vs.id = e.session_id
          AND vs.viewer_id = NEW.id;

        RETURN NEW;
    END IF;

    -- Keep the public tie-break label unique and current. profiles.user_handle
    -- has a UNIQUE constraint, so handle ordering is a stable final rank key.
    UPDATE public.daily_view_leaderboard d
    SET user_handle = NEW.user_handle
    WHERE d.user_id = NEW.id
      AND d.user_handle IS DISTINCT FROM NEW.user_handle;

    UPDATE public.weekly_view_leaderboard w
    SET user_handle = NEW.user_handle
    WHERE w.user_id = NEW.id
      AND w.user_handle IS DISTINCT FROM NEW.user_handle;

    UPDATE private.completed_view_leaderboard_events e
    SET user_handle = NEW.user_handle
    FROM public.view_sessions vs
    WHERE vs.id = e.session_id
      AND vs.viewer_id = NEW.id
      AND e.user_handle IS DISTINCT FROM NEW.user_handle;

    -- A handle can be repaired from blank to nonblank after sessions completed.
    INSERT INTO private.completed_view_leaderboard_events (
        session_id, user_handle, completed_at
    )
    SELECT
        vs.id, NEW.user_handle, vs.completed_at
    FROM public.view_sessions vs
    WHERE vs.viewer_id = NEW.id
      AND vs.status = 'COMPLETED'
      AND vs.completed_at IS NOT NULL
      AND vs.completed_at >= v_now - INTERVAL '30 days'
      AND vs.completed_at < v_now
    ON CONFLICT (session_id) DO UPDATE
        SET user_handle = EXCLUDED.user_handle,
            completed_at = EXCLUDED.completed_at;

    DELETE FROM private.completed_view_leaderboard_events e
    WHERE e.completed_at < v_now - INTERVAL '30 days';

    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.sync_leaderboard_profile_handle()
    FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_sync_leaderboard_profile_handle
    ON public.profiles;

CREATE TRIGGER trg_sync_leaderboard_profile_handle
AFTER UPDATE OF user_handle
ON public.profiles
FOR EACH ROW
WHEN (OLD.user_handle IS DISTINCT FROM NEW.user_handle)
EXECUTE FUNCTION private.sync_leaderboard_profile_handle();

-- Normalize existing display labels to the unique current profiles.user_handle.
-- Counts, user IDs, completed sessions and historical balances are not changed.
UPDATE public.daily_view_leaderboard d
SET user_handle = p.user_handle
FROM public.profiles p
WHERE p.id = d.user_id
  AND d.user_handle IS DISTINCT FROM p.user_handle
  AND pg_catalog.btrim(p.user_handle) <> '';

UPDATE public.weekly_view_leaderboard w
SET user_handle = p.user_handle
FROM public.profiles p
WHERE p.id = w.user_id
  AND w.user_handle IS DISTINCT FROM p.user_handle
  AND pg_catalog.btrim(p.user_handle) <> '';

DELETE FROM public.daily_view_leaderboard d
WHERE NOT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = d.user_id
      AND pg_catalog.btrim(p.user_handle) <> ''
);

DELETE FROM public.weekly_view_leaderboard w
WHERE NOT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = w.user_id
      AND pg_catalog.btrim(p.user_handle) <> ''
);

-- Idempotent backfill of the current rolling window only. Older sessions stay
-- intact in public.view_sessions and remain part of financial/reconciliation history.
INSERT INTO private.completed_view_leaderboard_events (
    session_id, user_handle, completed_at
)
SELECT
    vs.id,
    p.user_handle,
    vs.completed_at
FROM public.view_sessions vs
JOIN public.profiles p ON p.id = vs.viewer_id
WHERE vs.status = 'COMPLETED'
  AND vs.completed_at IS NOT NULL
  AND vs.completed_at >= pg_catalog.statement_timestamp() - INTERVAL '30 days'
  AND vs.completed_at < pg_catalog.statement_timestamp()
  AND pg_catalog.btrim(p.user_handle) <> ''
ON CONFLICT (session_id) DO UPDATE
    SET user_handle = EXCLUDED.user_handle,
        completed_at = EXCLUDED.completed_at;

DELETE FROM private.completed_view_leaderboard_events e
WHERE e.completed_at < pg_catalog.statement_timestamp() - INTERVAL '30 days'
   OR NOT EXISTS (
       SELECT 1
       FROM public.view_sessions vs
       JOIN public.profiles p ON p.id = vs.viewer_id
       WHERE vs.id = e.session_id
         AND vs.status = 'COMPLETED'
         AND vs.completed_at = e.completed_at
         AND vs.completed_at >= pg_catalog.statement_timestamp() - INTERVAL '30 days'
         AND vs.completed_at < pg_catalog.statement_timestamp()
         AND pg_catalog.btrim(p.user_handle) <> ''
         AND p.user_handle = e.user_handle
   );

-- New, unambiguous contract: exact [as_of - 30 days, as_of) interval.
CREATE OR REPLACE VIEW public.rolling_30d_view_leaderboard_public
WITH (security_invoker = true)
AS
WITH bounds AS (
    SELECT
        pg_catalog.statement_timestamp() AS window_end,
        pg_catalog.statement_timestamp() - INTERVAL '30 days' AS window_start
),
user_counts AS (
    SELECT
        e.user_handle,
        pg_catalog.count(*)::integer AS completed_views,
        pg_catalog.max(e.completed_at) AS updated_at
    FROM private.completed_view_leaderboard_events e
    CROSS JOIN bounds b
    WHERE e.completed_at >= b.window_start
      AND e.completed_at < b.window_end
    GROUP BY e.user_handle
)
SELECT
    b.window_start,
    b.window_end,
    pg_catalog.row_number() OVER (
        ORDER BY uc.completed_views DESC, uc.user_handle ASC
    )::integer AS rank,
    uc.user_handle,
    uc.completed_views,
    uc.updated_at
FROM user_counts uc
CROSS JOIN bounds b;

COMMENT ON VIEW public.rolling_30d_view_leaderboard_public IS
    'Exact rolling 30x24-hour leaderboard over completed views. UTC timestamp boundaries; invoker security; exposes only handle, rank and aggregate counts.';

-- Backward-compatible Android contract. Keep week_start and existing columns
-- until the Android consumer is migrated in Session 3.
CREATE OR REPLACE VIEW public.weekly_view_leaderboard_public
WITH (security_invoker = true)
AS
SELECT
    pg_catalog.date_trunc('week', r.window_end AT TIME ZONE 'UTC')::date AS week_start,
    r.rank,
    r.user_handle,
    r.completed_views,
    r.updated_at
FROM public.rolling_30d_view_leaderboard_public r;

COMMENT ON VIEW public.weekly_view_leaderboard_public IS
    'Backward-compatible Android endpoint. The result is rolling 30 days, not a calendar week. week_start remains only as the legacy UTC filter key. SECURITY INVOKER is enabled.';

-- Daily ranking remains UTC and its unique profile handles form a stable
-- deterministic tie-breaker without exposing auth user IDs.
CREATE OR REPLACE VIEW public.daily_view_leaderboard_public
WITH (security_invoker = true)
AS
SELECT
    d.leaderboard_date,
    pg_catalog.row_number() OVER (
        PARTITION BY d.leaderboard_date
        ORDER BY d.completed_views DESC, d.user_handle ASC
    )::integer AS rank,
    d.user_handle,
    d.completed_views,
    d.updated_at
FROM public.daily_view_leaderboard d;

COMMENT ON VIEW public.daily_view_leaderboard_public IS
    'Daily UTC leaderboard. Current unique profile handles provide a deterministic secondary ordering key.';

-- Remove inherited or legacy write grants; public leaderboard surfaces are
-- read-only for authenticated clients and unavailable to anon.
REVOKE ALL ON public.rolling_30d_view_leaderboard_public
    FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.rolling_30d_view_leaderboard_public
    TO authenticated;

REVOKE ALL ON public.weekly_view_leaderboard_public
    FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.weekly_view_leaderboard_public
    TO authenticated;

REVOKE ALL ON public.daily_view_leaderboard_public
    FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.daily_view_leaderboard_public
    TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
