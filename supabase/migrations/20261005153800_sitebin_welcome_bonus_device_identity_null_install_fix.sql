-- Corrective migration: missing client install_id must never block normal account initialization.

BEGIN;
CREATE OR REPLACE FUNCTION public.init_user_account(
    p_install_id text,
    p_handle text DEFAULT NULL::text,
    p_android_id text DEFAULT NULL::text,
    p_app_set_id text DEFAULT NULL::text,
    p_app_set_scope text DEFAULT NULL::text,
    p_installation_key_fingerprint text DEFAULT NULL::text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
    v_profile public.profiles%ROWTYPE;
    v_handle text;
    v_clean_install text;
    v_android_id text;
    v_app_set_id text;
    v_app_set_scope text;
    v_install_fp text;
    v_android_hmac text;
    v_app_set_hmac text;
    v_install_hmac text;
    v_legacy_install_hmac text;
    v_device_id uuid;
    v_device_ids_found integer := 0;
    v_device_entitlement_id uuid;
    v_device_entitlement_uid uuid;
    v_user_existing_grant public.welcome_bonus_grants%ROWTYPE;
    v_user_has_grant boolean := false;
    v_invalid_evidence boolean := false;
    v_has_android boolean := false;
    v_has_developer_app_set boolean := false;
    v_has_install_key boolean := false;
    v_risk_score integer := 50;
    v_risk_level text := 'MEDIUM';
    v_attempts integer := 0;
    v_window_started_at timestamptz;
    v_rate_limited boolean := false;
    v_bonus_amount bigint := 300;
    v_inserted_entitlement_id uuid;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((auth.jwt()->>'is_anonymous')::boolean, false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    v_clean_install := NULLIF(pg_catalog.btrim(COALESCE(p_install_id, '')), '');
    IF v_clean_install IS NULL THEN
        v_clean_install := 'server_' || v_uid::text;
    END IF;

    IF v_clean_install IS NOT NULL AND pg_catalog.length(v_clean_install) > 256 THEN
        v_clean_install := pg_catalog.left(v_clean_install, 256);
    END IF;

    -- Client-generated install_id is retained only as legacy/application metadata.
    -- It is not an entitlement key and never determines eligibility.
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

    v_has_android := v_android_id IS NOT NULL;
    v_has_developer_app_set :=
      v_app_set_id IS NOT NULL AND v_app_set_scope = 'DEVELOPER';
    v_has_install_key := v_install_fp IS NOT NULL;

    IF v_has_android THEN
        v_android_hmac :=
          private.device_identifier_hmac('android_id', v_android_id);
    END IF;

    IF v_app_set_id IS NOT NULL THEN
        v_app_set_hmac :=
          private.device_identifier_hmac('app_set_id', v_app_set_id);
    END IF;

    IF v_has_install_key THEN
        v_install_hmac :=
          private.device_identifier_hmac(
            'installation_key_fingerprint',
            v_install_fp
          );
    END IF;

    IF v_clean_install IS NOT NULL THEN
        v_legacy_install_hmac :=
          private.device_identifier_hmac(
            'legacy_install_id',
            v_clean_install
          );
    END IF;

    -- A previously granted user is always preserved. Historical 150/300 coin
    -- records remain the source of truth for existing users.
    SELECT *
    INTO v_user_existing_grant
    FROM public.welcome_bonus_grants
    WHERE user_id = v_uid
    LIMIT 1;

    v_user_has_grant := v_user_existing_grant.id IS NOT NULL;

    -- Find all identities touched by the submitted evidence. A conflict means
    -- different strong signals point at different known device identities.
    SELECT
      count(DISTINCT di.id),
      min(di.id::text)::uuid
    INTO
      v_device_ids_found,
      v_device_id
    FROM private.device_identities di
    WHERE (v_android_hmac IS NOT NULL AND di.android_id_hmac = v_android_hmac)
       OR (v_app_set_hmac IS NOT NULL AND di.app_set_id_hmac = v_app_set_hmac)
       OR (v_install_fp IS NOT NULL AND di.installation_key_fingerprint = v_install_fp)
       OR (v_legacy_install_hmac IS NOT NULL AND di.legacy_install_id_hmac = v_legacy_install_hmac);

    IF v_device_ids_found > 1 THEN
        v_risk_level := 'HIGH';
        v_risk_score := 100;
    ELSE
        IF v_has_android AND v_has_install_key AND NOT v_invalid_evidence THEN
            v_risk_level := 'LOW';
            v_risk_score := 80;
            IF v_has_developer_app_set THEN
                v_risk_score := 95;
            END IF;
        ELSIF v_has_developer_app_set AND v_has_install_key AND NOT v_invalid_evidence THEN
            v_risk_level := 'LOW';
            v_risk_score := 75;
        ELSE
            v_risk_level := 'MEDIUM';
            v_risk_score := 50;
        END IF;
    END IF;

    -- The primary anti-reinstall key is Android ID. App Set ID is a secondary
    -- strong signal and detects some signing-key continuity breaks. Installation
    -- key is continuity/provenance evidence only.
    IF v_android_hmac IS NOT NULL THEN
        INSERT INTO private.welcome_bonus_attempt_buckets(signal_hmac)
        VALUES(v_android_hmac)
        ON CONFLICT (signal_hmac) DO NOTHING;

        SELECT attempt_count, window_started_at
        INTO v_attempts, v_window_started_at
        FROM private.welcome_bonus_attempt_buckets
        WHERE signal_hmac = v_android_hmac
        FOR UPDATE;

        IF clock_timestamp() - v_window_started_at >= interval '15 minutes' THEN
            UPDATE private.welcome_bonus_attempt_buckets
            SET window_started_at = clock_timestamp(),
                attempt_count = 1
            WHERE signal_hmac = v_android_hmac;
            v_attempts := 1;
        ELSIF v_attempts >= 5 THEN
            v_rate_limited := true;
        ELSE
            UPDATE private.welcome_bonus_attempt_buckets
            SET attempt_count = attempt_count + 1
            WHERE signal_hmac = v_android_hmac
            RETURNING attempt_count INTO v_attempts;
        END IF;
    END IF;

    -- If an existing device identity was found, serialize its entitlement
    -- decision under a row lock.
    IF v_device_id IS NOT NULL THEN
        PERFORM 1
        FROM private.device_identities
        WHERE id = v_device_id
        FOR UPDATE;

        UPDATE private.device_identities
        SET last_seen_at = clock_timestamp(),
            first_auth_uid = COALESCE(first_auth_uid, v_uid),
            current_auth_uid = v_uid,
            risk_score = GREATEST(risk_score, v_risk_score),
            risk_level = CASE
              WHEN risk_level = 'HIGH' OR v_risk_level = 'HIGH' THEN 'HIGH'
              WHEN risk_level = 'LOW' AND v_risk_level = 'LOW' THEN 'LOW'
              ELSE 'MEDIUM'
            END,
            app_set_scope = COALESCE(v_app_set_scope, app_set_scope)
        WHERE id = v_device_id;
    ELSIF v_android_hmac IS NOT NULL OR v_app_set_hmac IS NOT NULL OR v_install_fp IS NOT NULL THEN
        BEGIN
            INSERT INTO private.device_identities(
              android_id_hmac,
              app_set_id_hmac,
              app_set_scope,
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
              v_android_hmac,
              v_app_set_hmac,
              v_app_set_scope,
              v_install_fp,
              clock_timestamp(),
              clock_timestamp(),
              v_uid,
              v_uid,
              v_risk_score,
              v_risk_level,
              'NOT_CHECKED',
              jsonb_build_object('source','android_device_evidence')
            )
            ON CONFLICT DO NOTHING
            RETURNING id INTO v_device_id;
        EXCEPTION
            WHEN unique_violation THEN
                NULL;
        END;

        IF v_device_id IS NULL THEN
            SELECT
              count(DISTINCT di.id),
              min(di.id::text)::uuid
            INTO
              v_device_ids_found,
              v_device_id
            FROM private.device_identities di
            WHERE (v_android_hmac IS NOT NULL AND di.android_id_hmac = v_android_hmac)
               OR (v_app_set_hmac IS NOT NULL AND di.app_set_id_hmac = v_app_set_hmac)
               OR (v_install_fp IS NOT NULL AND di.installation_key_fingerprint = v_install_fp);

            IF v_device_ids_found > 1 THEN
                v_risk_level := 'HIGH';
                v_risk_score := 100;
                v_device_id := NULL;
            END IF;
        END IF;

        IF v_device_id IS NOT NULL THEN
            PERFORM 1
            FROM private.device_identities
            WHERE id = v_device_id
            FOR UPDATE;

            UPDATE private.device_identities
            SET last_seen_at = clock_timestamp(),
                first_auth_uid = COALESCE(first_auth_uid, v_uid),
                current_auth_uid = v_uid,
                app_set_scope = COALESCE(v_app_set_scope, app_set_scope),
                risk_score = GREATEST(risk_score, v_risk_score),
                risk_level = CASE
                  WHEN risk_level = 'HIGH' OR v_risk_level = 'HIGH' THEN 'HIGH'
                  WHEN risk_level = 'LOW' AND v_risk_level = 'LOW' THEN 'LOW'
                  ELSE 'MEDIUM'
                END
            WHERE id = v_device_id;
        END IF;
    END IF;

    -- A known device can never receive a second lifetime entitlement.
    IF v_device_id IS NOT NULL THEN
        SELECT id, beneficiary_auth_uid
        INTO v_device_entitlement_id, v_device_entitlement_uid
        FROM private.welcome_bonus_entitlements
        WHERE device_identity_id = v_device_id
        FOR UPDATE;

        IF v_device_entitlement_id IS NOT NULL THEN
            v_risk_level := 'HIGH';
            v_risk_score := 100;
        END IF;
    END IF;

    -- Existing users may be associated with their already-granted entitlement,
    -- but this association never mints new coins.
    IF v_user_has_grant THEN
        IF v_device_id IS NOT NULL AND v_device_entitlement_id IS NULL THEN
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
              v_uid,
              v_user_existing_grant.amount,
              'WELCOME_BONUS_LEGACY_ASSOCIATION',
              'CLAIMED',
              v_user_existing_grant.granted_at,
              v_user_existing_grant.granted_at
            )
            ON CONFLICT DO NOTHING;
        END IF;
    END IF;

    -- New user profile creation is independent from eligibility. Insufficient or
    -- suspicious device evidence yields a normal zero-coin account rather than
    -- blocking the application.
    SELECT *
    INTO v_profile
    FROM public.profiles
    WHERE id = v_uid
    FOR UPDATE;

    IF NOT FOUND THEN
        v_handle := COALESCE(
            NULLIF(pg_catalog.btrim(p_handle), ''),
            'user_' || pg_catalog.substring(v_uid::text, 1, 8)
        );

        -- Only a clean, first-seen device with Android ID + installation key can
        -- mint the first bonus. App Set ID strengthens the decision and is also
        -- used for historical matching. Rate limiting only affects the bonus.
        IF v_device_id IS NOT NULL
           AND v_device_entitlement_id IS NULL
           AND v_risk_level = 'LOW'
           AND v_has_android
           AND v_has_install_key
           AND NOT v_invalid_evidence
           AND NOT v_rate_limited THEN

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
              v_uid,
              v_bonus_amount,
              'WELCOME_BONUS_V1',
              'CLAIMED',
              clock_timestamp(),
              clock_timestamp()
            )
            ON CONFLICT (device_identity_id) DO NOTHING
            RETURNING id INTO v_inserted_entitlement_id;

            IF v_inserted_entitlement_id IS NOT NULL THEN
                v_device_entitlement_id := v_inserted_entitlement_id;

                INSERT INTO public.profiles(
                    id,
                    user_handle,
                    app_install_id,
                    available_coins,
                    reserved_coins,
                    lifetime_earned,
                    lifetime_spent,
                    trust_score,
                    completed_views_count,
                    received_views_count,
                    welcome_bonus_claimed,
                    created_at,
                    updated_at
                )
                VALUES(
                    v_uid,
                    v_handle,
                    COALESCE(v_clean_install, ''),
                    v_bonus_amount,
                    0,
                    v_bonus_amount,
                    0,
                    100.0,
                    0,
                    0,
                    true,
                    clock_timestamp(),
                    clock_timestamp()
                )
                RETURNING * INTO v_profile;

                INSERT INTO public.welcome_bonus_grants(
                  user_id,
                  install_id,
                  amount,
                  granted_at
                )
                VALUES(
                  v_uid,
                  COALESCE(v_clean_install, ''),
                  v_bonus_amount,
                  clock_timestamp()
                );

                INSERT INTO public.coin_ledger(
                  user_id,
                  amount,
                  transaction_type,
                  description,
                  reference_id,
                  idempotency_key,
                  created_at
                )
                VALUES(
                  v_uid,
                  v_bonus_amount,
                  'WELCOME_REWARD',
                  'هدیه ورود به سایت بین (Welcome Bonus)',
                  v_inserted_entitlement_id::text,
                  'welcome_device_' || v_device_id::text,
                  clock_timestamp()
                );

            END IF;
        END IF;

        IF v_profile.id IS NULL THEN
            INSERT INTO public.profiles(
                id,
                user_handle,
                app_install_id,
                available_coins,
                reserved_coins,
                lifetime_earned,
                lifetime_spent,
                trust_score,
                completed_views_count,
                received_views_count,
                welcome_bonus_claimed,
                created_at,
                updated_at
            )
            VALUES(
                v_uid,
                v_handle,
                COALESCE(v_clean_install, ''),
                0,
                0,
                0,
                0,
                CASE WHEN v_risk_level = 'HIGH' THEN 0 ELSE 100.0 END,
                0,
                0,
                false,
                clock_timestamp(),
                clock_timestamp()
            )
            RETURNING * INTO v_profile;
        END IF;
    END IF;

    RETURN pg_catalog.row_to_json(v_profile);
END;
$function$;


REVOKE ALL ON FUNCTION public.init_user_account(text,text,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.init_user_account(text,text,text,text,text,text) TO authenticated, service_role;
COMMIT;
