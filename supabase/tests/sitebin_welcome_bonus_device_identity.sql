-- Real PostgreSQL/Supabase integration test for the device-authoritative Welcome Bonus.
-- All test mutations are rolled back. This test intentionally creates real auth.users
-- rows inside the transaction to exercise the actual auth.uid()-based RPC path.

BEGIN;

DO $$
DECLARE
  v_tag text := substr(md5(clock_timestamp()::text || random()::text), 1, 12);
  v_uid uuid;
  v_existing_150 uuid;
  v_existing_300 uuid;
  v_profile json;
  v_bonus_count integer := 0;
  v_entitlement_count bigint;
  v_grant_count bigint;
  v_ledger_sum bigint;
  v_before_150 bigint;
  v_before_300 bigint;
  v_before_ledger_150 bigint;
  v_before_ledger_300 bigint;
  i integer;
BEGIN
  -- Create isolated real Auth identities for the test.
  CREATE TEMP TABLE tmp_sitebin_test_users(id uuid PRIMARY KEY) ON COMMIT DROP;

  FOR i IN 1..13 LOOP
    v_uid := gen_random_uuid();

    INSERT INTO auth.users(
      id, aud, role, email, email_confirmed_at,
      created_at, updated_at, is_sso_user, is_anonymous
    )
    VALUES(
      v_uid,
      'authenticated',
      'authenticated',
      'sitebin_it_' || v_tag || '_' || i::text || '@sitebin.internal',
      clock_timestamp(),
      clock_timestamp(),
      clock_timestamp(),
      false,
      false
    );

    INSERT INTO tmp_sitebin_test_users(id) VALUES(v_uid);
  END LOOP;

  -- Test 1: first claim is exactly 300 coins.
  SELECT id INTO v_uid FROM tmp_sitebin_test_users ORDER BY id LIMIT 1;
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub',v_uid::text,'role','authenticated','is_anonymous',false)::text,
    true
  );

  SELECT public.init_user_account(
    'install_first_' || v_tag,
    NULL,
    '0123456789abcdef',
    '523e4567-e89b-42d3-a456-426614174000',
    'DEVELOPER',
    repeat('1',64)
  ) INTO v_profile;

  IF (v_profile->>'available_coins')::bigint <> 300
     OR (v_profile->>'lifetime_earned')::bigint <> 300
     OR (v_profile->>'welcome_bonus_claimed')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST1_FAILED: first claim was not exactly 300: %',v_profile;
  END IF;

  SELECT count(*) INTO v_entitlement_count
  FROM private.welcome_bonus_entitlements
  WHERE beneficiary_auth_uid=v_uid;

  SELECT count(*) INTO v_grant_count
  FROM public.welcome_bonus_grants
  WHERE user_id=v_uid;

  SELECT coalesce(sum(amount),0) INTO v_ledger_sum
  FROM public.coin_ledger
  WHERE user_id=v_uid;

  IF v_entitlement_count <> 1 OR v_grant_count <> 1 OR v_ledger_sum <> 300 THEN
    RAISE EXCEPTION 'TEST1_FAILED: entitlement=%, grant=%, ledger_sum=%',
      v_entitlement_count,v_grant_count,v_ledger_sum;
  END IF;

  -- Test 1B: malformed optional App Set ID must not suppress the first 300-coin grant
  -- when the primary Android ID and installation-key evidence are valid.
  v_uid := (SELECT id FROM tmp_sitebin_test_users ORDER BY id OFFSET 12 LIMIT 1);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub',v_uid::text,'role','authenticated','is_anonymous',false)::text,
    true
  );

  SELECT public.init_user_account(
    'install_optional_appset_' || v_tag,
    NULL,
    substr(md5('optional_appset_' || v_tag), 1, 16),
    'not-a-uuid',
    'DEVELOPER',
    md5(v_tag) || md5('optional_appset')
  ) INTO v_profile;

  IF (v_profile->>'available_coins')::bigint <> 300
     OR (v_profile->>'welcome_bonus_claimed')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST1B_FAILED: malformed optional App Set ID suppressed welcome bonus: %',v_profile;
  END IF;

  SELECT count(*) INTO v_entitlement_count
  FROM private.welcome_bonus_entitlements
  WHERE beneficiary_auth_uid=v_uid;

  SELECT count(*) INTO v_grant_count
  FROM public.welcome_bonus_grants
  WHERE user_id=v_uid;

  SELECT coalesce(sum(amount),0) INTO v_ledger_sum
  FROM public.coin_ledger
  WHERE user_id=v_uid;

  IF v_entitlement_count <> 1 OR v_grant_count <> 1 OR v_ledger_sum <> 300 THEN
    RAISE EXCEPTION 'TEST1B_FAILED: entitlement=%, grant=%, ledger_sum=%',
      v_entitlement_count,v_grant_count,v_ledger_sum;
  END IF;

  -- Test 2 / 7: duplicate/replay on same Auth user and changed install ID is harmless.
  SELECT public.init_user_account(
    'install_replay_' || v_tag,
    NULL,
    '0123456789abcdef',
    '523e4567-e89b-42d3-a456-426614174000',
    'DEVELOPER',
    repeat('2',64)
  ) INTO v_profile;

  IF (v_profile->>'available_coins')::bigint <> 300 THEN
    RAISE EXCEPTION 'TEST2_FAILED: duplicate claim changed balance: %',v_profile;
  END IF;

  SELECT count(*) INTO v_entitlement_count
  FROM private.welcome_bonus_entitlements
  WHERE beneficiary_auth_uid=v_uid;

  SELECT count(*) INTO v_grant_count
  FROM public.welcome_bonus_grants
  WHERE user_id=v_uid;

  IF v_entitlement_count <> 1 OR v_grant_count <> 1 THEN
    RAISE EXCEPTION 'TEST2_FAILED: duplicate claim created extra records';
  END IF;

  -- Tests 4,5,6,10,12: uninstall/reinstall + new Auth user + new install ID,
  -- changed installation key, fake/local identifier changes, all same device.
  -- The canonical account must be rebound to the new Auth UID with its existing
  -- financial state; reinstall must never expose a fresh zero-coin account.
  FOR v_uid IN
    SELECT id FROM tmp_sitebin_test_users ORDER BY id OFFSET 1 LIMIT 10
  LOOP
    PERFORM set_config(
      'request.jwt.claims',
      json_build_object('sub',v_uid::text,'role','authenticated','is_anonymous',false)::text,
      true
    );

    SELECT public.init_user_account(
      'install_reinstall_' || replace(v_uid::text,'-',''),
      NULL,
      '0123456789abcdef',
      '523e4567-e89b-42d3-a456-426614174000',
      'DEVELOPER',
      md5(v_uid::text)||md5('changed-device-secret-'||v_uid::text)
    ) INTO v_profile;

    IF (v_profile->>'available_coins')::bigint <> 300
       OR (v_profile->>'welcome_bonus_claimed')::boolean IS NOT TRUE
       OR (v_profile->>'lifetime_earned')::bigint < 300 THEN
      RAISE EXCEPTION 'TEST_REINSTALL_FAILED: canonical account was not preserved for %: %',v_uid,v_profile;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_entitlement_count
  FROM private.welcome_bonus_entitlements e
  JOIN tmp_sitebin_test_users u ON u.id=e.beneficiary_auth_uid;

  IF v_entitlement_count <> 1 THEN
    RAISE EXCEPTION 'TEST5_FAILED: more than one entitlement for same device';
  END IF;

  -- Test 11: insufficient device evidence fails closed without blocking the app.
  v_uid := (
    SELECT id
    FROM tmp_sitebin_test_users
    WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id=tmp_sitebin_test_users.id)
    ORDER BY id
    LIMIT 1
  );
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub',v_uid::text,'role','authenticated','is_anonymous',false)::text,
    true
  );

  SELECT public.init_user_account('install_no_evidence_'||v_tag,NULL,NULL,NULL,NULL,NULL)
  INTO v_profile;

  IF (v_profile->>'available_coins')::bigint <> 0 THEN
    RAISE EXCEPTION 'TEST11_FAILED: missing evidence minted coins: %',v_profile;
  END IF;

  -- Test 9: malformed/tampered evidence is ignored and cannot mint.
  v_uid := (
    SELECT id
    FROM tmp_sitebin_test_users
    WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id=tmp_sitebin_test_users.id)
    ORDER BY id
    LIMIT 1
  );
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub',v_uid::text,'role','authenticated','is_anonymous',false)::text,
    true
  );

  SELECT public.init_user_account(
    'install_bad_'||v_tag,NULL,
    'not-android-id',
    'not-a-uuid',
    'BAD',
    'fake'
  ) INTO v_profile;

  IF (v_profile->>'available_coins')::bigint <> 0 THEN
    RAISE EXCEPTION 'TEST9_FAILED: malformed evidence minted coins';
  END IF;

  -- Test 8: anonymous execution is blocked at the privilege and function layers.
  IF has_function_privilege(
       'anon',
       'public.init_user_account(text,text,text,text,text,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'TEST8_FAILED: anon can execute init_user_account';
  END IF;

  -- Test 9/18: no amount parameter / amount cannot be client-controlled.
  IF to_regprocedure(
       'public.init_user_account(text,text,text,text,text,text,bigint)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'TEST_AMOUNT_FAILED: amount parameter overload exists';
  END IF;

  -- Legacy reinstall regression: existing account gets a new install_id but the
  -- first strong evidence is attached to its already-claimed identity. A new Auth
  -- user with the same device evidence must inherit the canonical account state,
  -- not receive a second bonus and not fall back to zero coins.
  v_existing_300 := (
    SELECT user_id
    FROM public.welcome_bonus_grants
    WHERE amount=300
    ORDER BY granted_at
    LIMIT 1
  );

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub',v_existing_300::text,'role','authenticated','is_anonymous',false)::text,
    true
  );

  SELECT public.init_user_account(
    'brand_new_install_after_reinstall_' || v_tag,
    NULL,
    'abcdef1234567890',
    '823e4567-e89b-42d3-a456-426614174000',
    'DEVELOPER',
    repeat('5',64)
  ) INTO v_profile;

  v_uid := gen_random_uuid();
  INSERT INTO auth.users(id,aud,role,email,created_at,updated_at,is_sso_user,is_anonymous)
  VALUES(
    v_uid,'authenticated','authenticated',
    'sitebin_legacy_attacker_'||replace(v_uid::text,'-','')||'@sitebin.internal',
    clock_timestamp(),clock_timestamp(),false,false
  );

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub',v_uid::text,'role','authenticated','is_anonymous',false)::text,
    true
  );

  SELECT public.init_user_account(
    'attacker_new_install_after_reinstall_' || v_tag,
    NULL,
    'abcdef1234567890',
    '823e4567-e89b-42d3-a456-426614174000',
    'DEVELOPER',
    repeat('6',64)
  ) INTO v_profile;

  IF (v_profile->>'available_coins')::bigint <> 300
     OR (v_profile->>'welcome_bonus_claimed')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'LEGACY_REINSTALL_FAILED: canonical account was not preserved: %',v_profile;
  END IF;

  -- Tests 16/17: historical 150-coin and 300-coin users must not be reminted.
  SELECT user_id INTO v_existing_150
  FROM public.welcome_bonus_grants
  WHERE amount=150
  ORDER BY granted_at
  LIMIT 1;

  SELECT user_id INTO v_existing_300
  FROM public.welcome_bonus_grants
  WHERE amount=300
  ORDER BY granted_at
  LIMIT 1;

  SELECT available_coins INTO v_before_150 FROM public.profiles WHERE id=v_existing_150;
  SELECT available_coins INTO v_before_300 FROM public.profiles WHERE id=v_existing_300;
  SELECT count(*) INTO v_before_ledger_150
  FROM public.coin_ledger
  WHERE user_id=v_existing_150 AND transaction_type='WELCOME_REWARD';
  SELECT count(*) INTO v_before_ledger_300
  FROM public.coin_ledger
  WHERE user_id=v_existing_300 AND transaction_type='WELCOME_REWARD';

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub',v_existing_150::text,'role','authenticated','is_anonymous',false)::text,
    true
  );
  PERFORM public.init_user_account(
    (SELECT install_id FROM public.welcome_bonus_grants WHERE user_id=v_existing_150),
    NULL,
    'fedcba9876543210',
    '623e4567-e89b-42d3-a456-426614174000',
    'DEVELOPER',
    repeat('3',64)
  );

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub',v_existing_300::text,'role','authenticated','is_anonymous',false)::text,
    true
  );
  PERFORM public.init_user_account(
    (SELECT install_id FROM public.welcome_bonus_grants WHERE user_id=v_existing_300),
    NULL,
    'fedcba9876543211',
    '723e4567-e89b-42d3-a456-426614174000',
    'DEVELOPER',
    repeat('4',64)
  );

  IF (SELECT available_coins FROM public.profiles WHERE id=v_existing_150) <> v_before_150
     OR (SELECT available_coins FROM public.profiles WHERE id=v_existing_300) <> v_before_300
     OR (SELECT count(*) FROM public.coin_ledger WHERE user_id=v_existing_150 AND transaction_type='WELCOME_REWARD') <> v_before_ledger_150
     OR (SELECT count(*) FROM public.coin_ledger WHERE user_id=v_existing_300 AND transaction_type='WELCOME_REWARD') <> v_before_ledger_300 THEN
    RAISE EXCEPTION 'TEST16_17_FAILED: historical account changed';
  END IF;

  -- Test 14: burst attempts for one device are capped at 5 attempts / 15 minutes.
  v_uid := (SELECT id FROM tmp_sitebin_test_users ORDER BY id LIMIT 1);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub',v_uid::text,'role','authenticated','is_anonymous',false)::text,
    true
  );

  FOR i IN 1..20 LOOP
    PERFORM public.init_user_account(
      'burst_'||i::text||'_'||v_tag,
      NULL,
      '0123456789abcdef',
      '523e4567-e89b-42d3-a456-426614174000',
      'DEVELOPER',
      repeat(lpad(to_hex(i),2,'0'),32)
    );
  END LOOP;

  IF (SELECT attempt_count
      FROM private.welcome_bonus_attempt_buckets
      WHERE signal_hmac=private.device_identifier_hmac('android_id','0123456789abcdef')) <> 5 THEN
    RAISE EXCEPTION 'TEST14_FAILED: device burst was not capped at 5 attempts';
  END IF;
END;
$$;

ROLLBACK;
