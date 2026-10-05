-- Fix RECORD existence checks in viewer session functions.
--
-- PostgreSQL composite/RECORD variables can evaluate as NULL with
-- "record IS NOT NULL" when any selected field is NULL. Viewer sessions
-- legitimately contain nullable fields (for example keyword and
-- resolved_target_url), so existence must be tested through the NOT NULL
-- primary key instead.
--
-- This migration captures the already-verified live Supabase hotfix while
-- preserving the rest of the authoritative function definitions unchanged.

DO $$
DECLARE
  v_sql text;
BEGIN
  SELECT pg_get_functiondef(p.oid)
  INTO v_sql
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname='request_view_session'
    AND pg_get_function_identity_arguments(p.oid)='';

  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'request_view_session() not found';
  END IF;

  IF position('IF v_existing_active IS NOT NULL THEN' IN v_sql) = 0 THEN
    IF position('IF v_existing_active.id IS NOT NULL THEN' IN v_sql) > 0 THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'Unexpected request_view_session() definition; expected existence guard was not found';
  END IF;

  v_sql := replace(
    v_sql,
    'IF v_existing_active IS NOT NULL THEN',
    'IF v_existing_active.id IS NOT NULL THEN'
  );

  EXECUTE v_sql;
END
$$;

DO $$
DECLARE
  v_sql text;
BEGIN
  SELECT pg_get_functiondef(p.oid)
  INTO v_sql
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname='complete_view_session'
    AND pg_get_function_identity_arguments(p.oid)='p_session_id uuid, p_idempotency_key text';

  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'complete_view_session(uuid,text) not found';
  END IF;

  IF position('IF v_existing_by_key IS NOT NULL THEN' IN v_sql) = 0 THEN
    IF position('IF v_existing_by_key.id IS NOT NULL THEN' IN v_sql) > 0 THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'Unexpected complete_view_session() definition; expected existence guard was not found';
  END IF;

  v_sql := replace(
    v_sql,
    'IF v_existing_by_key IS NOT NULL THEN',
    'IF v_existing_by_key.id IS NOT NULL THEN'
  );

  EXECUTE v_sql;
END
$$;
