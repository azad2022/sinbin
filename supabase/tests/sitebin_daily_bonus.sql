-- Real PostgreSQL integration test for device-scoped daily bonus.
-- Every mutation is rolled back.

BEGIN;

DO $$
DECLARE
  v_uid1 uuid := gen_random_uuid();
  v_uid2 uuid := gen_random_uuid();
  v_result json;
  v_before_available bigint;
  v_after_available bigint;
  v_daily_rows bigint;
  v_device_rows bigint;
  v_daily_ledger_rows bigint;
  v_device_id uuid;
BEGIN
  INSERT INTO auth.users(
    id,aud,role,email,created_at,updated_at,is_sso_user,is_anonymous
  )
  VALUES
    (
      v_uid1,'authenticated','authenticated',
      'sitebin_daily_device_test_1_'||replace(v_uid1::text,'-','')||'@sitebin.internal',
      clock_timestamp(),clock_timestamp(),false,false
    ),
    (
      v_uid2,'authenticated','authenticated',
      'sitebin_daily_device_test_2_'||replace(v_uid2::text,'-','')||'@sitebin.internal',
      clock_timestamp(),clock_timestamp(),false,false
    );

  INSERT INTO public.profiles(
    id,user_handle,app_install_id,available_coins,reserved_coins,
    lifetime_earned,lifetime_spent,trust_score,completed_views_count,
    received_views_count,welcome_bonus_claimed
  )
  VALUES
    (
      v_uid1,'daily_device_test_1_'||substr(replace(v_uid1::text,'-',''),1,12),
      'daily-device-install-1',0,0,0,0,100,0,0,false
    ),
    (
      v_uid2,'daily_device_test_2_'||substr(replace(v_uid2::text,'-',''),1,12),
      'daily-device-install-2',0,0,0,0,100,0,0,false
    );

  INSERT INTO private.device_identities(
    android_id_hmac,
    installation_key_fingerprint,
    first_seen_at,
    last_seen_at,
    first_auth_uid,
    current_auth_uid,
    risk_score,
    risk_level,
    integrity_status,
    platform_metadata
  )
  VALUES(
    private.device_identifier_hmac('android_id','abcdef1234567890'),
    private.device_identifier_hmac('installation_key_fingerprint',repeat('a',64)),
    clock_timestamp(),
    clock_timestamp(),
    v_uid1,
    v_uid1,
    95,
    'LOW',
    'NOT_CHECKED',
    jsonb_build_object('source','sitebin_daily_bonus_integration_test')
  )
  RETURNING id INTO v_device_id;

  IF has_function_privilege('anon','public.claim_daily_bonus()', 'EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: obsolete zero-argument daily bonus RPC is still executable';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.claim_daily_bonus(text,text,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated cannot execute device-scoped daily bonus RPC';
  END IF;

  IF to_regprocedure('public.claim_daily_bonus()') IS NOT NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: obsolete claim_daily_bonus() overload still exists';
  END IF;

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub',v_uid1::text,
      'role','authenticated',
      'is_anonymous',false
    )::text,
    true
  );

  SELECT available_coins INTO v_before_available
  FROM public.profiles
  WHERE id=v_uid1;

  SELECT public.claim_daily_bonus(
    'abcdef1234567890',
    NULL,
    NULL,
    repeat('a',64)
  )
  INTO v_result;

  IF (v_result->>'granted')::boolean IS NOT TRUE
     OR (v_result->>'amount')::bigint <> 50 THEN
    RAISE EXCEPTION 'TEST_FAILED: first device daily claim did not grant exactly 50: %',v_result;
  END IF;

  SELECT available_coins INTO v_after_available
  FROM public.profiles
  WHERE id=v_uid1;

  IF v_after_available <> v_before_available + 50 THEN
    RAISE EXCEPTION 'TEST_FAILED: balance increased by unexpected amount';
  END IF;

  -- The same Auth user cannot claim the same server day twice.
  SELECT public.claim_daily_bonus(
    'abcdef1234567890',
    NULL,
    NULL,
    repeat('a',64)
  )
  INTO v_result;

  IF (v_result->>'granted')::boolean IS NOT FALSE
     OR v_result->>'reason' <> 'ALREADY_CLAIMED' THEN
    RAISE EXCEPTION 'TEST_FAILED: duplicate same-device claim was not rejected: %',v_result;
  END IF;

  -- A second Auth UID on the same device cannot receive another daily reward.
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub',v_uid2::text,
      'role','authenticated',
      'is_anonymous',false
    )::text,
    true
  );

  SELECT public.claim_daily_bonus(
    'abcdef1234567890',
    NULL,
    NULL,
    repeat('a',64)
  )
  INTO v_result;

  IF (v_result->>'granted')::boolean IS NOT FALSE
     OR v_result->>'reason' <> 'ACCOUNT_CONTINUITY_REQUIRED' THEN
    RAISE EXCEPTION 'TEST_FAILED: second Auth UID on same device was not blocked: %',v_result;
  END IF;

  SELECT count(*)
  INTO v_daily_rows
  FROM public.daily_bonus_grants
  WHERE user_id=v_uid1
    AND grant_date=(CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date;

  IF v_daily_rows <> 1 THEN
    RAISE EXCEPTION 'TEST_FAILED: expected exactly one daily_bonus_grants row, got %',v_daily_rows;
  END IF;

  SELECT count(*)
  INTO v_device_rows
  FROM private.daily_bonus_device_claims
  WHERE device_identity_id=v_device_id
    AND grant_date=(CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date;

  IF v_device_rows <> 1 THEN
    RAISE EXCEPTION 'TEST_FAILED: expected exactly one daily device claim row, got %',v_device_rows;
  END IF;

  SELECT count(*)
  INTO v_daily_ledger_rows
  FROM public.coin_ledger
  WHERE user_id=v_uid1
    AND transaction_type='DAILY_BONUS'
    AND reference_id=(
      SELECT id::text
      FROM public.daily_bonus_grants
      WHERE user_id=v_uid1
        AND grant_date=(CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date
    );

  IF v_daily_ledger_rows <> 1 THEN
    RAISE EXCEPTION 'TEST_FAILED: expected exactly one daily ledger row, got %',v_daily_ledger_rows;
  END IF;
END;
$$;

ROLLBACK;
