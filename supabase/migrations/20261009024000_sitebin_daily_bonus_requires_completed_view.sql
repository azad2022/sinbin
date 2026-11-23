-- SiteBin: daily bonus requires a completed view on the same UTC server day.
-- The existing device-continuity and once-per-day protections remain unchanged.
-- Legacy grants already created for a day remain valid; the new guard only blocks
-- creation of a new grant until a server-validated view has completed.

BEGIN;

DO $patch$
DECLARE
  v_function_definition text;
  v_needle text := $needle$
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
  v_replacement text := $replacement$
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
    INTO v_function_definition
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'claim_daily_bonus'
    AND pg_catalog.pg_get_function_identity_arguments(p.oid) =
      'p_android_id text, p_app_set_id text, p_app_set_scope text, p_installation_key_fingerprint text';

  IF v_function_definition IS NULL THEN
    RAISE EXCEPTION 'claim_daily_bonus function definition not found';
  END IF;

  IF v_function_definition NOT LIKE '%VISIT_REQUIRED%' THEN
    IF pg_catalog.position(v_needle in v_function_definition) = 0 THEN
      RAISE EXCEPTION 'claim_daily_bonus patch anchor not found';
    END IF;
    v_function_definition := pg_catalog.replace(v_function_definition, v_needle, v_replacement);
    EXECUTE v_function_definition;
  END IF;
END
$patch$;

COMMIT;
