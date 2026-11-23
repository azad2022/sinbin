-- Correct linked-identity daily-claim sealing to retain the source Auth UID.

BEGIN;

CREATE OR REPLACE FUNCTION public.claim_daily_bonus(
  p_android_id text,
  p_app_set_id text,
  p_app_set_scope text,
  p_installation_key_fingerprint text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_today date := (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date;
  v_android_id text;
  v_app_set_id text;
  v_app_set_scope text;
  v_install_fp text;
  v_android_hmac text;
  v_app_set_hmac text;
  v_install_hmac text;
  v_invalid_evidence boolean := false;
  v_match_count integer := 0;
  v_device_id uuid;
  v_first_auth_uid uuid;
  v_current_auth_uid uuid;
  v_profile public.profiles%ROWTYPE;
  v_entitlement RECORD;
  v_grant RECORD;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
  END IF;

  IF COALESCE((auth.jwt()->>'is_anonymous')::boolean, false) THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
  END IF;

  IF p_android_id IS NOT NULL THEN
    v_android_id := NULLIF(pg_catalog.lower(pg_catalog.btrim(p_android_id)), '');
    IF v_android_id IS NULL OR v_android_id !~ '^[0-9a-f]{16}$' THEN
      v_invalid_evidence := true;
      v_android_id := NULL;
    END IF;
  END IF;

  IF p_app_set_id IS NOT NULL THEN
    v_app_set_id := NULLIF(pg_catalog.lower(pg_catalog.btrim(p_app_set_id)), '');
    IF v_app_set_id IS NULL
       OR v_app_set_id !~
          '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
      v_invalid_evidence := true;
      v_app_set_id := NULL;
    END IF;
  END IF;

  IF p_app_set_scope IS NOT NULL THEN
    v_app_set_scope := pg_catalog.upper(pg_catalog.btrim(p_app_set_scope));
    IF v_app_set_scope NOT IN ('DEVELOPER','APP') THEN
      v_invalid_evidence := true;
      v_app_set_scope := NULL;
    END IF;
  END IF;

  IF v_app_set_id IS NOT NULL AND v_app_set_scope IS NULL THEN
    v_invalid_evidence := true;
    v_app_set_id := NULL;
  END IF;

  IF p_installation_key_fingerprint IS NOT NULL THEN
    v_install_fp := NULLIF(pg_catalog.lower(pg_catalog.btrim(p_installation_key_fingerprint)), '');
    IF v_install_fp IS NULL OR v_install_fp !~ '^[0-9a-f]{64}$' THEN
      v_invalid_evidence := true;
      v_install_fp := NULL;
    END IF;
  END IF;

  IF v_invalid_evidence THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'INVALID_DEVICE_EVIDENCE'
    );
  END IF;

  IF v_android_id IS NOT NULL THEN
    v_android_hmac := private.device_identifier_hmac('android_id', v_android_id);
  END IF;
  IF v_app_set_id IS NOT NULL THEN
    v_app_set_hmac := private.device_identifier_hmac('app_set_id', v_app_set_id);
  END IF;
  IF v_install_fp IS NOT NULL THEN
    v_install_hmac := private.device_identifier_hmac(
      'installation_key_fingerprint',
      v_install_fp
    );
  END IF;

  IF v_android_hmac IS NULL
     AND v_app_set_hmac IS NULL
     AND v_install_hmac IS NULL THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'DEVICE_EVIDENCE_REQUIRED'
    );
  END IF;

  SELECT count(DISTINCT di.id), min(di.id::text)::uuid
  INTO v_match_count, v_device_id
  FROM private.device_identities di
  WHERE (v_android_hmac IS NOT NULL AND di.android_id_hmac = v_android_hmac)
     OR (v_app_set_hmac IS NOT NULL AND di.app_set_id_hmac = v_app_set_hmac)
     OR (v_install_hmac IS NOT NULL AND di.installation_key_fingerprint = v_install_hmac);

  IF v_match_count = 0 THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'DEVICE_NOT_REGISTERED'
    );
  END IF;

  IF v_match_count > 1 THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'DEVICE_IDENTITY_CONFLICT'
    );
  END IF;

  SELECT first_auth_uid, current_auth_uid
  INTO v_first_auth_uid, v_current_auth_uid
  FROM private.device_identities
  WHERE id = v_device_id
  FOR UPDATE;

  -- One physical device is anchored to its first authenticated SiteBin identity.
  -- A new Auth UID after reinstall therefore cannot farm Daily Bonus.
  IF v_first_auth_uid IS NOT NULL AND v_first_auth_uid <> v_uid THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'ACCOUNT_CONTINUITY_REQUIRED'
    );
  END IF;

  SELECT id, device_identity_id, beneficiary_auth_uid, amount, granted_at
  INTO v_entitlement
  FROM private.welcome_bonus_entitlements
  WHERE device_identity_id = v_device_id
  LIMIT 1
  FOR UPDATE;

  IF v_entitlement.id IS NOT NULL
     AND v_entitlement.beneficiary_auth_uid <> v_uid THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'ACCOUNT_CONTINUITY_REQUIRED'
    );
  END IF;

  SELECT id, user_id, amount, granted_at
  INTO v_grant
  FROM public.daily_bonus_grants
  WHERE user_id IN (v_first_auth_uid, v_current_auth_uid)
    AND grant_date = v_today
  ORDER BY granted_at ASC, id ASC
  LIMIT 1
  FOR UPDATE;

  IF v_grant.id IS NOT NULL THEN
    INSERT INTO private.daily_bonus_device_claims(
      device_identity_id,
      grant_date,
      beneficiary_auth_uid,
      amount,
      daily_bonus_grant_id,
      granted_at
    )
    VALUES(
      v_device_id,
      v_today,
      v_grant.user_id,
      v_grant.amount,
      v_grant.id,
      v_grant.granted_at
    )
    ON CONFLICT (device_identity_id, grant_date) DO NOTHING;

    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'ALREADY_CLAIMED',
      'grant_id', v_grant.id
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM private.daily_bonus_device_claims c
    WHERE c.device_identity_id = v_device_id
      AND c.grant_date = v_today
  ) THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'ALREADY_CLAIMED'
    );
  END IF;

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
  INTO v_profile
  FROM public.profiles
  WHERE id = v_uid
  FOR UPDATE;

  IF v_profile IS NULL THEN
    RAISE EXCEPTION 'PROFILE_NOT_FOUND: Account must be initialized before receiving daily bonus';
  END IF;

  SELECT id, amount, granted_at
  INTO v_grant
  FROM public.daily_bonus_grants
  WHERE user_id = v_uid
    AND grant_date = v_today
  FOR UPDATE;

  IF v_grant.id IS NOT NULL THEN
    INSERT INTO private.daily_bonus_device_claims(
      device_identity_id,
      grant_date,
      beneficiary_auth_uid,
      amount,
      daily_bonus_grant_id,
      granted_at
    )
    VALUES(
      v_device_id,
      v_today,
      v_uid,
      v_grant.amount,
      v_grant.id,
      v_grant.granted_at
    )
    ON CONFLICT (device_identity_id, grant_date) DO NOTHING;

    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'ALREADY_CLAIMED',
      'grant_id', v_grant.id
    );
  END IF;

  INSERT INTO public.daily_bonus_grants(user_id, grant_date, amount, granted_at)
  VALUES(v_uid, v_today, 50, pg_catalog.clock_timestamp())
  RETURNING id, amount, granted_at INTO v_grant;

  UPDATE public.profiles
  SET available_coins = available_coins + v_grant.amount,
      lifetime_earned = lifetime_earned + v_grant.amount,
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = v_uid;

  INSERT INTO public.coin_ledger(
    user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
  )
  VALUES(
    v_uid,
    v_grant.amount,
    'DAILY_BONUS',
    'هدیه روزانه سایت بین',
    v_grant.id::text,
    'daily_bonus_' || v_uid::text || '_' || v_today::text,
    v_grant.granted_at
  );

  INSERT INTO private.daily_bonus_device_claims(
    device_identity_id,
    grant_date,
    beneficiary_auth_uid,
    amount,
    daily_bonus_grant_id,
    granted_at
  )
  VALUES(
    v_device_id,
    v_today,
    v_uid,
    v_grant.amount,
    v_grant.id,
    v_grant.granted_at
  );

  RETURN pg_catalog.json_build_object(
    'granted', true,
    'amount', 50,
    'grant_date', v_today,
    'grant_id', v_grant.id,
    'granted_at', extract(epoch from v_grant.granted_at) * 1000
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_daily_bonus(text,text,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_daily_bonus(text,text,text,text)
  TO authenticated;


COMMIT;
