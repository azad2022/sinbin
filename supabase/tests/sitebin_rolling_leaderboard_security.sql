BEGIN;

DO $test$
DECLARE
    v_view_options text[];
BEGIN
    IF to_regclass('private.completed_view_leaderboard_events') IS NULL THEN
        RAISE EXCEPTION 'Rolling leaderboard private projection table is missing';
    END IF;

    IF has_table_privilege(
        'authenticated',
        'private.completed_view_leaderboard_events',
        'SELECT'
    ) THEN
        RAISE EXCEPTION 'authenticated must not read private rolling leaderboard event rows directly';
    END IF;

    IF has_table_privilege(
        'anon',
        'private.completed_view_leaderboard_events',
        'SELECT'
    ) THEN
        RAISE EXCEPTION 'anon must not read private rolling leaderboard event rows';
    END IF;

    IF to_regprocedure('private.get_rolling_30d_leaderboard()') IS NULL THEN
        RAISE EXCEPTION 'Authenticated aggregate projection function is missing';
    END IF;

    IF NOT has_function_privilege(
        'authenticated',
        'private.get_rolling_30d_leaderboard()',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'authenticated must be able to execute the guarded aggregate projection';
    END IF;

    IF has_function_privilege(
        'anon',
        'private.get_rolling_30d_leaderboard()',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'anon must not execute the rolling leaderboard aggregate projection';
    END IF;

    IF NOT has_table_privilege(
        'authenticated',
        'public.rolling_30d_view_leaderboard_public',
        'SELECT'
    ) THEN
        RAISE EXCEPTION 'authenticated must be able to read the rolling leaderboard API view';
    END IF;

    IF has_table_privilege(
        'anon',
        'public.rolling_30d_view_leaderboard_public',
        'SELECT'
    ) THEN
        RAISE EXCEPTION 'anon must not read the rolling leaderboard API view';
    END IF;

    SELECT reloptions
      INTO v_view_options
    FROM pg_class
    WHERE oid = 'public.rolling_30d_view_leaderboard_public'::regclass;

    IF NOT COALESCE(v_view_options @> ARRAY['security_invoker=true'], false) THEN
        RAISE EXCEPTION 'Rolling leaderboard API view must use security_invoker=true';
    END IF;

    SELECT reloptions
      INTO v_view_options
    FROM pg_class
    WHERE oid = 'public.weekly_view_leaderboard_public'::regclass;

    IF NOT COALESCE(v_view_options @> ARRAY['security_invoker=true'], false) THEN
        RAISE EXCEPTION 'Compatibility leaderboard view must use security_invoker=true';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_constraint c
        WHERE c.conrelid = 'private.daily_featured_campaign_assignment'::regclass
          AND c.confrelid = 'public.profiles'::regclass
          AND c.contype = 'f'
          AND c.conkey = ARRAY[
              (
                  SELECT a.attnum
                  FROM pg_attribute a
                  WHERE a.attrelid = c.conrelid
                    AND a.attname = 'owner_id'
                    AND NOT a.attisdropped
              )
          ]::smallint[]
    ) THEN
        RAISE EXCEPTION 'Featured assignment audit owner_id must survive profile deletion';
    END IF;
END;
$test$;

ROLLBACK;
