-- SiteBin real PostgreSQL integration tests for the daily login bonus.
-- Uses one existing account whose welcome grant is not today and rolls back all mutations.

BEGIN;

DO $$
DECLARE
  v_uid uuid;
  v_result json;
  v_before_available bigint;
  v_before_earned bigint;
  v_daily_rows bigint;
  v_daily_ledger_rows bigint;
BEGIN
  SELECT p.id, p.available_coins, p.lifetime_earned
    INTO v_uid, v_before_available, v_before_earned
  FROM public.profiles p
  JOIN public.welcome_bonus_grants w ON w.user_id = p.id
  WHERE (w.granted_at AT TIME ZONE 'UTC')::date < (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date
  ORDER BY w.granted_at
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'TEST_SETUP_FAILED: no existing account with a prior welcome day';
  END IF;

  IF NOT has_function_privilege('anon', 'public.claim_daily_bonus()', 'EXECUTE') THEN
    NULL;
  ELSE
    RAISE EXCEPTION 'TEST_FAILED: anon can execute claim_daily_bonus';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.claim_daily_bonus()', 'EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated cannot execute claim_daily_bonus';
  END IF;

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_uid::text,
      'role', 'authenticated',
      'is_anonymous', true
    )::text,
    true
  );

  BEGIN
    SELECT public.claim_daily_bonus() INTO v_result;
    RAISE EXCEPTION 'TEST_FAILED: anonymous daily bonus claim unexpectedly succeeded';
  EXCEPTION
    WHEN OTHERS THEN
      IF position('UNAUTHORIZED: Anonymous authentication is not allowed' IN SQLERRM) = 0 THEN
        RAISE;
      END IF;
  END;

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_uid::text,
      'role', 'authenticated',
      'is_anonymous', false
    )::text,
    true
  );

  SELECT public.claim_daily_bonus() INTO v_result;

  IF (v_result->>'granted')::boolean IS NOT TRUE
     OR (v_result->>'amount')::bigint <> 50 THEN
    RAISE EXCEPTION 'TEST_FAILED: first daily claim did not grant exactly 50 coins: %', v_result;
  END IF;

  SELECT available_coins, lifetime_earned
    INTO v_before_available, v_before_earned
  FROM public.profiles
  WHERE id = v_uid;

  IF v_before_available < 50 OR v_before_earned < 50 THEN
    RAISE EXCEPTION 'TEST_FAILED: balance/lifetime earned did not increase';
  END IF;

  SELECT public.claim_daily_bonus() INTO v_result;

  IF (v_result->>'granted')::boolean IS NOT FALSE
     OR v_result->>'reason' <> 'ALREADY_CLAIMED' THEN
    RAISE EXCEPTION 'TEST_FAILED: duplicate same-day claim was not rejected as ALREADY_CLAIMED: %', v_result;
  END IF;

  SELECT count(*) INTO v_daily_rows
  FROM public.daily_bonus_grants
  WHERE user_id = v_uid
    AND grant_date = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date;

  IF v_daily_rows <> 1 THEN
    RAISE EXCEPTION 'TEST_FAILED: expected exactly one daily grant row, got %', v_daily_rows;
  END IF;

  SELECT count(*) INTO v_daily_ledger_rows
  FROM public.coin_ledger
  WHERE user_id = v_uid
    AND transaction_type = 'DAILY_BONUS'
    AND reference_id = (SELECT id::text FROM public.daily_bonus_grants WHERE user_id = v_uid AND grant_date = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date);

  IF v_daily_ledger_rows <> 1 THEN
    RAISE EXCEPTION 'TEST_FAILED: expected exactly one daily ledger row, got %', v_daily_ledger_rows;
  END IF;
END;
$$;

ROLLBACK;
