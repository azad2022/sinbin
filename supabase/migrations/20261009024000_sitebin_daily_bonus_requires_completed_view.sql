-- SiteBin: daily bonus requires a completed view on the same UTC server day.
-- The existing device-continuity and once-per-day protections remain unchanged.
-- Legacy grants already created for a day remain valid; the new guard only blocks
-- creation of a new grant until a server-validated view has completed.

BEGIN;

DO $patch$
DECLARE
  ddl text;
  needle text := $needle$
  IF v_entitlement.id IS NOT NULL
     AND (v_entitlement.granted_at AT TIME ZONE 'UTC')::date = v_today THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'WELCOME_DAY'
    );
  END IF;

  SELECT *
$needle$;
  replacement text := $replacement$
  IF v_entitlement.id IS NOT NULL
     AND (v_entitlement.granted_at AT TIME ZONE 'UTC')::date = v_today THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'WELCOME_DAY'
    );
  END IF;

  -- A daily bonus can only be minted after at least one server-validated
  -- view session has reached COMPLETED on the current UTC server day.
  IF NOT EXISTS (
    SELECT 1
    FROM public.view_sessions vs
    WHERE vs.viewer_id = v_uid
      AND vs.status = 'COMPLETED'
      AND vs.completed_at IS NOT NULL
      AND (vs.completed_at AT TIME ZONE 'UTC')::date = v_today
  ) THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'VISIT_REQUIRED'
    );
  END IF;

  SELECT *
$replacement$;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(p.oid)
    INTO ddl
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'claim_daily_bonus'
    AND pg_catalog.pg_get_function_identity_arguments(p.oid) =
      'p_android_id text, p_app_set_id text, p_app_set_scope text, p_installation_key_fingerprint text';

  IF ddl IS NULL THEN
    RAISE EXCEPTION 'claim_daily_bonus function definition not found';
  END IF;

  IF ddl NOT LIKE '%VISIT_REQUIRED%' THEN
    IF pg_catalog.position(needle in ddl) = 0 THEN
      RAISE EXCEPTION 'claim_daily_bonus patch anchor not found';
    END IF;
    ddl := pg_catalog.replace(ddl, needle, replacement);
    EXECUTE ddl;
  END IF;
END
$patch$;

COMMIT;
