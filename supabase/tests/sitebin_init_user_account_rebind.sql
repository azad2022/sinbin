-- Integration regression test for the canonical init_user_account reinstall path.
-- A reinstall creates a new Auth UID and install_id, but matching device evidence
-- must rebind the existing account instead of exposing a fresh zero-coin profile.
-- All mutations are rolled back.

BEGIN;

DO $$
DECLARE
  v_tag text := substr(md5(clock_timestamp()::text || random()::text), 1, 12);
  v_old_uid uuid := gen_random_uuid();
  v_new_uid uuid := gen_random_uuid();
  v_device_id uuid := gen_random_uuid();
  v_android_id text := substr(md5('rebind_android_' || v_tag), 1, 16);
  v_install_fp text := md5('rebind_fp_a_' || v_tag) || md5('rebind_fp_b_' || v_tag);
  v_profile json;
  v_expected_balance bigint := 456;
  v_expected_lifetime_earned bigint := 789;
BEGIN
  INSERT INTO auth.users(
    id, aud, role, email, email_confirmed_at,
    created_at, updated_at, is_sso_user, is_anonymous
  )
  VALUES
    (
      v_old_uid,
      'authenticated',
      'authenticated',
      'rebind_old_' || replace(v_old_uid::text,'-','') || '@sitebin.internal',
      clock_timestamp(),
      clock_timestamp(),
      clock_timestamp(),
      false,
      false
    ),
    (
      v_new_uid,
      'authenticated',
      'authenticated',
      'rebind_new_' || replace(v_new_uid::text,'-','') || '@sitebin.internal',
      clock_timestamp(),
      clock_timestamp(),
      clock_timestamp(),
      false,
      false
    );

  INSERT INTO public.profiles(
    id, user_handle, app_install_id, available_coins, reserved_coins,
    lifetime_earned, lifetime_spent, trust_score, completed_views_count,
    received_views_count, welcome_bonus_claimed, created_at, updated_at
  )
  VALUES(
    v_old_uid,
    'user_rebind_regression',
    'old_install_' || v_tag,
    v_expected_balance,
    0,
    v_expected_lifetime_earned,
    111,
    100,
    27,
    3,
    true,
    clock_timestamp(),
    clock_timestamp()
  );

  INSERT INTO private.device_identities(
    id,
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
    v_device_id,
    private.device_identifier_hmac('android_id', v_android_id),
    v_install_fp,
    clock_timestamp(),
    clock_timestamp(),
    v_old_uid,
    v_old_uid,
    80,
    'LOW',
    'NOT_CHECKED',
    jsonb_build_object('source','init_user_account_rebind_regression')
  );

  INSERT INTO private.welcome_bonus_entitlements(
    device_identity_id,
    beneficiary_auth_uid,
    amount,
    source,
    claim_state,
    granted_at,
    created_at
  )
  VALUES(
    v_device_id,
    v_old_uid,
    300,
    'WELCOME_BONUS_V1',
    'CLAIMED',
    clock_timestamp(),
    clock_timestamp()
  );

  INSERT INTO public.welcome_bonus_grants(
    user_id, install_id, amount, granted_at
  )
  VALUES(
    v_old_uid,
    'old_install_' || v_tag,
    300,
    clock_timestamp()
  );

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub',v_new_uid::text,
      'role','authenticated',
      'is_anonymous',false
    )::text,
    true
  );

  SELECT public.init_user_account(
    'new_install_' || v_tag,
    NULL,
    v_android_id,
    NULL,
    NULL,
    v_install_fp
  ) INTO v_profile;

  IF (v_profile->>'available_coins')::bigint <> v_expected_balance
     OR (v_profile->>'lifetime_earned')::bigint <> v_expected_lifetime_earned
     OR (v_profile->>'welcome_bonus_claimed')::boolean IS NOT TRUE
     OR v_profile->>'user_handle' <> 'user_rebind_regression'
     OR v_profile->>'app_install_id' <> 'new_install_' || v_tag THEN
    RAISE EXCEPTION 'INIT_REBIND_FAILED: canonical financial/account state was not preserved: %', v_profile;
  END IF;

  IF EXISTS(SELECT 1 FROM public.profiles WHERE id=v_old_uid) THEN
    RAISE EXCEPTION 'INIT_REBIND_FAILED: old profile still exists';
  END IF;

  IF (SELECT count(*) FROM public.welcome_bonus_grants WHERE user_id=v_new_uid) <> 1
     OR (SELECT count(*) FROM public.welcome_bonus_grants WHERE user_id=v_old_uid) <> 0 THEN
    RAISE EXCEPTION 'INIT_REBIND_FAILED: welcome grant was not moved exactly once';
  END IF;

  IF (SELECT count(*) FROM private.welcome_bonus_entitlements WHERE beneficiary_auth_uid=v_new_uid) <> 1
     OR (SELECT count(*) FROM private.welcome_bonus_entitlements WHERE beneficiary_auth_uid=v_old_uid) <> 0 THEN
    RAISE EXCEPTION 'INIT_REBIND_FAILED: welcome entitlement was not rebound exactly once';
  END IF;

  IF (SELECT current_auth_uid FROM private.device_identities WHERE id=v_device_id) <> v_new_uid THEN
    RAISE EXCEPTION 'INIT_REBIND_FAILED: device current_auth_uid was not rebound';
  END IF;
END;
$$;

ROLLBACK;
