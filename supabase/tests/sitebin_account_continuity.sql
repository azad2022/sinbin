-- SiteBin account-continuity regression test.
-- All mutations are transactional and rolled back.
-- This specifically protects the Rebind + rate-limit interaction that previously
-- produced rate_limit_buckets_pkey duplicate-key failures.

BEGIN;

DO $$
DECLARE
  v_old_uid uuid := gen_random_uuid();
  v_new_uid uuid := gen_random_uuid();
  v_device_id uuid := gen_random_uuid();
  v_old_coins bigint := 271;
  v_old_earned bigint := 371;
  v_old_spent bigint := 100;
  v_new_bucket_before integer;
  v_new_bucket_after integer;
  v_old_bucket_exists boolean;
  v_new_profile public.profiles%ROWTYPE;
BEGIN
  INSERT INTO auth.users(
    id, aud, role, email, email_confirmed_at,
    created_at, updated_at, is_sso_user, is_anonymous
  )
  VALUES
    (
      v_old_uid, 'authenticated', 'authenticated',
      'sitebin_continuity_old_' || replace(v_old_uid::text,'-','') || '@sitebin.internal',
      clock_timestamp(), clock_timestamp(), clock_timestamp(), false, false
    ),
    (
      v_new_uid, 'authenticated', 'authenticated',
      'sitebin_continuity_new_' || replace(v_new_uid::text,'-','') || '@sitebin.internal',
      clock_timestamp(), clock_timestamp(), clock_timestamp(), false, false
    );

  INSERT INTO public.profiles(
    id, user_handle, app_install_id, available_coins, reserved_coins,
    lifetime_earned, lifetime_spent, trust_score, completed_views_count,
    received_views_count, welcome_bonus_claimed, created_at, updated_at
  )
  VALUES(
    v_old_uid,
    'user_continuity_old_' || substr(replace(v_old_uid::text,'-',''),1,8),
    'inst_continuity_old_' || substr(replace(v_old_uid::text,'-',''),1,8),
    v_old_coins,
    0,
    v_old_earned,
    v_old_spent,
    100,
    13,
    0,
    true,
    clock_timestamp(),
    clock_timestamp()
  );

  INSERT INTO public.profiles(
    id, user_handle, app_install_id, available_coins, reserved_coins,
    lifetime_earned, lifetime_spent, trust_score, completed_views_count,
    received_views_count, welcome_bonus_claimed, created_at, updated_at
  )
  VALUES(
    v_new_uid,
    'user_continuity_new_' || substr(replace(v_new_uid::text,'-',''),1,8),
    'inst_continuity_new_' || substr(replace(v_new_uid::text,'-',''),1,8),
    0,
    0,
    0,
    0,
    100,
    0,
    0,
    false,
    clock_timestamp(),
    clock_timestamp()
  );

  INSERT INTO private.device_identities(
    id, first_seen_at, last_seen_at,
    first_auth_uid, current_auth_uid,
    risk_score, risk_level, integrity_status,
    platform_metadata
  )
  VALUES(
    v_device_id, clock_timestamp(), clock_timestamp(),
    v_old_uid, v_old_uid,
    80, 'LOW', 'NOT_CHECKED',
    jsonb_build_object('source','continuity_regression_test')
  );

  -- The pre-request limiter has already touched the new Auth UID.
  INSERT INTO private.rate_limit_buckets(
    user_id, action,
    ten_second_started_at, ten_second_count,
    minute_started_at, minute_count,
    five_minute_started_at, five_minute_count,
    hour_started_at, hour_count,
    blocked_until, updated_at
  )
  VALUES
  (
    v_old_uid, '__GLOBAL__',
    clock_timestamp() - interval '4 seconds', 4,
    clock_timestamp() - interval '20 seconds', 8,
    clock_timestamp() - interval '30 seconds', 15,
    clock_timestamp() - interval '2 minutes', 30,
    NULL, clock_timestamp()
  ),
  (
    v_new_uid, '__GLOBAL__',
    clock_timestamp() - interval '2 seconds', 2,
    clock_timestamp() - interval '10 seconds', 3,
    clock_timestamp() - interval '20 seconds', 5,
    clock_timestamp() - interval '1 minute', 7,
    clock_timestamp() + interval '20 seconds', clock_timestamp()
  );

  SELECT minute_count
  INTO v_new_bucket_before
  FROM private.rate_limit_buckets
  WHERE user_id=v_new_uid AND action='__GLOBAL__';

  PERFORM private.rebind_user_account(
    v_old_uid,
    v_new_uid,
    'inst_continuity_reinstall'
  );

  IF EXISTS (SELECT 1 FROM public.profiles WHERE id=v_old_uid) THEN
    RAISE EXCEPTION 'CONTINUITY_FAILED: old profile still exists';
  END IF;

  SELECT *
  INTO v_new_profile
  FROM public.profiles
  WHERE id=v_new_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONTINUITY_FAILED: new profile missing';
  END IF;

  IF v_new_profile.user_handle NOT LIKE 'user_continuity_old_%'
     OR v_new_profile.available_coins <> v_old_coins
     OR v_new_profile.lifetime_earned <> v_old_earned
     OR v_new_profile.lifetime_spent <> v_old_spent
     OR v_new_profile.completed_views_count <> 13
     OR v_new_profile.welcome_bonus_claimed IS NOT TRUE
     OR v_new_profile.app_install_id <> 'inst_continuity_reinstall' THEN
    RAISE EXCEPTION 'CONTINUITY_FAILED: financial/account state was not preserved';
  END IF;

  SELECT minute_count
  INTO v_new_bucket_after
  FROM private.rate_limit_buckets
  WHERE user_id=v_new_uid AND action='__GLOBAL__';

  IF v_new_bucket_after <> GREATEST(v_new_bucket_before, 8) THEN
    RAISE EXCEPTION 'CONTINUITY_FAILED: rate-limit bucket was not safely merged';
  END IF;

  SELECT EXISTS(
    SELECT 1
    FROM private.rate_limit_buckets
    WHERE user_id=v_old_uid
  )
  INTO v_old_bucket_exists;

  IF v_old_bucket_exists THEN
    RAISE EXCEPTION 'CONTINUITY_FAILED: old rate-limit buckets remain';
  END IF;

  IF NOT EXISTS(
    SELECT 1
    FROM private.device_identities
    WHERE id=v_device_id
      AND first_auth_uid=v_old_uid
      AND current_auth_uid=v_old_uid
  ) THEN
    RAISE EXCEPTION 'CONTINUITY_FAILED: unrelated device identity was modified';
  END IF;
END;
$$;

ROLLBACK;
