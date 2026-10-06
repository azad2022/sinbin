-- SiteBin: realtime foreground synchronization + authenticated account continuity.
-- This migration preserves the existing application identity and release signing policy.
BEGIN;

CREATE SCHEMA IF NOT EXISTS private;

CREATE OR REPLACE FUNCTION private.rebind_user_account(
    p_old_uid uuid,
    p_new_uid uuid,
    p_install_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_old_profile public.profiles%ROWTYPE;
    v_new_profile public.profiles%ROWTYPE;
    v_old_handle text;
    v_new_install_id text;
BEGIN
    IF p_old_uid IS NULL OR p_new_uid IS NULL OR p_old_uid = p_new_uid THEN
        RETURN;
    END IF;

    PERFORM 1 FROM auth.users WHERE id = p_new_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_REBIND_TARGET_AUTH_NOT_FOUND';
    END IF;

    SELECT * INTO v_old_profile
    FROM public.profiles
    WHERE id = p_old_uid
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_REBIND_SOURCE_PROFILE_NOT_FOUND';
    END IF;

    SELECT * INTO v_new_profile
    FROM public.profiles
    WHERE id = p_new_uid
    FOR UPDATE;

    IF FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_REBIND_TARGET_PROFILE_EXISTS';
    END IF;

    v_old_handle := v_old_profile.user_handle;
    v_new_install_id := NULLIF(pg_catalog.btrim(COALESCE(p_install_id, '')), '');
    IF v_new_install_id IS NULL THEN
        v_new_install_id := v_old_profile.app_install_id;
    END IF;

    -- Preserve a globally unique handle while the old row is still present.
    UPDATE public.profiles
    SET user_handle = '__rebind__' || p_old_uid::text
    WHERE id = p_old_uid;

    INSERT INTO public.profiles(
        id, user_handle, app_install_id, available_coins, reserved_coins,
        lifetime_earned, lifetime_spent, trust_score, completed_views_count,
        received_views_count, welcome_bonus_claimed, created_at, updated_at
    )
    VALUES(
        p_new_uid, v_old_handle, v_new_install_id, v_old_profile.available_coins,
        v_old_profile.reserved_coins, v_old_profile.lifetime_earned,
        v_old_profile.lifetime_spent, v_old_profile.trust_score,
        v_old_profile.completed_views_count, v_old_profile.received_views_count,
        v_old_profile.welcome_bonus_claimed, v_old_profile.created_at, clock_timestamp()
    );

    UPDATE public.auto_view_entitlements SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.auto_view_purchases SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.campaigns SET owner_id = p_new_uid WHERE owner_id = p_old_uid;
    UPDATE public.coin_ledger SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.coin_transfers SET sender_id = p_new_uid WHERE sender_id = p_old_uid;
    UPDATE public.coin_transfers SET recipient_id = p_new_uid WHERE recipient_id = p_old_uid;
    UPDATE public.daily_bonus_grants SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.view_sessions SET viewer_id = p_new_uid WHERE viewer_id = p_old_uid;
    UPDATE public.welcome_bonus_grants SET user_id = p_new_uid WHERE user_id = p_old_uid;

    UPDATE private.campaign_preflight_tokens SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE private.daily_bonus_device_claims
    SET beneficiary_auth_uid = p_new_uid
    WHERE beneficiary_auth_uid = p_old_uid;
    UPDATE private.rate_limit_buckets SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE private.welcome_bonus_entitlements
    SET beneficiary_auth_uid = p_new_uid
    WHERE beneficiary_auth_uid = p_old_uid;

    DELETE FROM public.profiles WHERE id = p_old_uid;
END;
$function$;

REVOKE ALL ON FUNCTION private.rebind_user_account(uuid,uuid,text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.rebind_user_account(uuid,uuid,text) TO postgres;

CREATE OR REPLACE FUNCTION private.grant_welcome_bonus_if_eligible(
    p_user_uid uuid,
    p_device_identity_id uuid,
    p_install_id text,
    p_amount bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_device_entitlement_id uuid;
    v_profile public.profiles%ROWTYPE;
    v_user_grant_id uuid;
BEGIN
    IF p_user_uid IS NULL OR p_device_identity_id IS NULL OR p_amount <= 0 THEN
        RETURN false;
    END IF;

    SELECT * INTO v_profile
    FROM public.profiles
    WHERE id = p_user_uid
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN false;
    END IF;

    SELECT id INTO v_user_grant_id
    FROM public.welcome_bonus_grants
    WHERE user_id = p_user_uid
    LIMIT 1;
    IF v_user_grant_id IS NOT NULL THEN
        RETURN false;
    END IF;

    PERFORM 1
    FROM private.device_identities
    WHERE id = p_device_identity_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN false;
    END IF;

    SELECT id INTO v_device_entitlement_id
    FROM private.welcome_bonus_entitlements
    WHERE device_identity_id = p_device_identity_id
    LIMIT 1
    FOR UPDATE;
    IF v_device_entitlement_id IS NOT NULL THEN
        RETURN false;
    END IF;

    INSERT INTO private.welcome_bonus_entitlements(
        device_identity_id, beneficiary_auth_uid, amount, source,
        claim_state, granted_at, created_at
    )
    VALUES(
        p_device_identity_id, p_user_uid, p_amount, 'WELCOME_BONUS_V1',
        'CLAIMED', clock_timestamp(), clock_timestamp()
    )
    ON CONFLICT (device_identity_id) DO NOTHING
    RETURNING id INTO v_device_entitlement_id;

    IF v_device_entitlement_id IS NULL THEN
        RETURN false;
    END IF;

    UPDATE public.profiles
    SET available_coins = available_coins + p_amount,
        lifetime_earned = lifetime_earned + p_amount,
        welcome_bonus_claimed = true,
        updated_at = clock_timestamp()
    WHERE id = p_user_uid;

    INSERT INTO public.welcome_bonus_grants(
        user_id, install_id, amount, granted_at
    )
    VALUES(
        p_user_uid, COALESCE(NULLIF(pg_catalog.btrim(p_install_id), ''), ''),
        p_amount, clock_timestamp()
    );

    INSERT INTO public.coin_ledger(
        user_id, amount, transaction_type, description,
        reference_id, idempotency_key, created_at
    )
    VALUES(
        p_user_uid, p_amount, 'WELCOME_REWARD',
        'هدیه ورود به سایت بین (Welcome Bonus)',
        v_device_entitlement_id::text,
        'welcome_device_' || p_device_identity_id::text,
        clock_timestamp()
    );

    RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION private.grant_welcome_bonus_if_eligible(uuid,uuid,text,bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.grant_welcome_bonus_if_eligible(uuid,uuid,text,bigint) TO postgres;

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
    v_prior_auth_uid uuid;
    v_rebound boolean := false;
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
            v_app_set_scope := NULL;
        END IF;
    END IF;

    IF v_app_set_id IS NOT NULL AND v_app_set_scope IS NULL THEN
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

    -- Legacy grants created before device evidence existed are anchored to their
    -- legacy identity. On the first run of a new client, enrich that same identity
    -- with strong evidence instead of creating an unclaimed second identity.
    IF v_user_has_grant AND v_legacy_install_hmac IS NOT NULL THEN
        SELECT di.id
        INTO v_device_id
        FROM private.device_identities di
        JOIN private.welcome_bonus_entitlements e
          ON e.device_identity_id = di.id
        WHERE e.beneficiary_auth_uid = v_uid
          AND di.legacy_install_id_hmac = v_legacy_install_hmac
        LIMIT 1
        FOR UPDATE;
    END IF;

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

    -- Existing legacy accounts may reinstall and generate a new install_id.
    -- When no strong signal has ever been associated with their legacy entitlement,
    -- bind the newly observed strong evidence to that existing device identity.
    -- This prevents a second Auth user on the same physical device from finding
    -- an unclaimed "new" identity after the first legacy user reinstalls.
    IF v_user_has_grant
       AND v_device_ids_found = 0
       AND v_android_hmac IS NOT NULL THEN
        SELECT di.id
        INTO v_device_id
        FROM private.device_identities di
        JOIN private.welcome_bonus_entitlements e
          ON e.device_identity_id = di.id
        WHERE e.beneficiary_auth_uid = v_uid
          AND di.android_id_hmac IS NULL
          AND di.app_set_id_hmac IS NULL
          AND di.installation_key_fingerprint IS NULL
        LIMIT 1
        FOR UPDATE;

        IF v_device_id IS NOT NULL THEN
            UPDATE private.device_identities
            SET android_id_hmac = v_android_hmac,
                app_set_id_hmac = COALESCE(v_app_set_hmac, app_set_id_hmac),
                app_set_scope = COALESCE(v_app_set_scope, app_set_scope),
                installation_key_fingerprint = COALESCE(v_install_hmac, installation_key_fingerprint),
                last_seen_at = clock_timestamp(),
                current_auth_uid = v_uid
            WHERE id = v_device_id;
        END IF;
    END IF;

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

    -- The device identity is the continuity anchor. Before changing
    -- current_auth_uid, remember who currently owns the canonical device account.
    IF v_device_id IS NOT NULL THEN
        SELECT COALESCE(current_auth_uid, first_auth_uid)
        INTO v_prior_auth_uid
        FROM private.device_identities
        WHERE id = v_device_id
        FOR UPDATE;

        IF v_prior_auth_uid = v_uid THEN
            v_prior_auth_uid := NULL;
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

    -- Resolve the canonical account before creating any new profile.
    -- If this is a reinstall and the same device is already bound to another
    -- authenticated UID, move the existing account data to the newly-created UID
    -- instead of exposing a fresh zero-coin account.
    SELECT *
    INTO v_profile
    FROM public.profiles
    WHERE id = v_uid
    FOR UPDATE;

    IF NOT FOUND AND v_prior_auth_uid IS NOT NULL AND v_prior_auth_uid <> v_uid THEN
        PERFORM private.rebind_user_account(
            v_prior_auth_uid,
            v_uid,
            COALESCE(v_clean_install, '')
        );

        SELECT *
        INTO v_profile
        FROM public.profiles
        WHERE id = v_uid
        FOR UPDATE;

        v_rebound := FOUND;
    END IF;

    -- Only a genuinely new device/account reaches this path.
    IF NOT FOUND THEN
        v_handle := COALESCE(
            NULLIF(pg_catalog.btrim(p_handle), ''),
            'user_' || pg_catalog.substring(v_uid::text, 1, 8)
        );

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

    -- Re-read legacy grants after a possible account rebind. A moved historical
    -- grant must prevent a second welcome reward on the new auth UID.
    SELECT *
    INTO v_user_existing_grant
    FROM public.welcome_bonus_grants
    WHERE user_id = v_uid
    LIMIT 1;

    v_user_has_grant := v_user_existing_grant.id IS NOT NULL;

    -- A rebind may have moved an entitlement onto the current UID. Serialize
    -- the final device-level decision before potentially granting 300 coins.
    IF v_device_id IS NOT NULL THEN
        SELECT id, beneficiary_auth_uid
        INTO v_device_entitlement_id, v_device_entitlement_uid
        FROM private.welcome_bonus_entitlements
        WHERE device_identity_id = v_device_id
        FOR UPDATE;
    END IF;

    -- Welcome bonus eligibility is a property of the device/account, not of the
    -- local install_id. This also repairs old zero-coin profiles that were created
    -- during the previous auth-continuity bug but never received their one-time bonus.
    IF v_device_id IS NOT NULL
       AND v_device_entitlement_id IS NULL
       AND v_risk_level = 'LOW'
       AND v_has_android
       AND v_has_install_key
       AND NOT v_invalid_evidence
       AND NOT v_rate_limited
       AND NOT v_user_has_grant
       AND COALESCE(v_profile.welcome_bonus_claimed, false) = false THEN

        IF private.grant_welcome_bonus_if_eligible(
            v_uid,
            v_device_id,
            COALESCE(v_clean_install, ''),
            v_bonus_amount
        ) THEN
            SELECT *
            INTO v_profile
            FROM public.profiles
            WHERE id = v_uid
            FOR UPDATE;
        END IF;
    END IF;
    RETURN pg_catalog.row_to_json(v_profile);
END;
$function$;


DO $publication$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'profiles'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.profiles;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'coin_ledger'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.coin_ledger;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'campaigns'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.campaigns;
    END IF;
END;
$publication$;

DO $repair$
DECLARE
    v_old_uid uuid := 'bac61f42-e81e-44d9-9241-b4c462d3943b';
    v_new_uid uuid := '06b6514d-3a51-4f05-83ea-27461137dc0c';
    v_device_id uuid := '5816c56a-7e8e-40db-8981-bb96b044309d';
    v_new_is_empty boolean;
BEGIN
    SELECT
      p.available_coins = 0
      AND p.reserved_coins = 0
      AND p.lifetime_earned = 0
      AND p.lifetime_spent = 0
      AND p.welcome_bonus_claimed = false
      AND NOT EXISTS (SELECT 1 FROM public.coin_ledger WHERE user_id = v_new_uid)
      AND NOT EXISTS (SELECT 1 FROM public.campaigns WHERE owner_id = v_new_uid)
      AND NOT EXISTS (SELECT 1 FROM public.coin_transfers WHERE sender_id = v_new_uid OR recipient_id = v_new_uid)
      AND NOT EXISTS (SELECT 1 FROM public.daily_bonus_grants WHERE user_id = v_new_uid)
      AND NOT EXISTS (SELECT 1 FROM public.view_sessions WHERE viewer_id = v_new_uid)
      AND NOT EXISTS (SELECT 1 FROM public.welcome_bonus_grants WHERE user_id = v_new_uid)
      AND NOT EXISTS (SELECT 1 FROM public.auto_view_entitlements WHERE user_id = v_new_uid)
      AND NOT EXISTS (SELECT 1 FROM public.auto_view_purchases WHERE user_id = v_new_uid)
      AND NOT EXISTS (SELECT 1 FROM private.campaign_preflight_tokens WHERE user_id = v_new_uid)
      AND NOT EXISTS (SELECT 1 FROM private.daily_bonus_device_claims WHERE beneficiary_auth_uid = v_new_uid)
      AND NOT EXISTS (SELECT 1 FROM private.welcome_bonus_entitlements WHERE beneficiary_auth_uid = v_new_uid)
    INTO v_new_is_empty
    FROM public.profiles p
    WHERE p.id = v_new_uid;

    IF v_new_is_empty THEN
        DELETE FROM private.rate_limit_buckets WHERE user_id = v_new_uid;
        DELETE FROM public.profiles WHERE id = v_new_uid;
        PERFORM private.rebind_user_account(v_old_uid, v_new_uid, 'inst_846a6527-76f2-4851-8b72-5d1f51d0929d');
        UPDATE private.device_identities
        SET current_auth_uid = v_new_uid,
            last_seen_at = clock_timestamp()
        WHERE id = v_device_id;
    END IF;

    IF EXISTS (SELECT 1 FROM public.profiles WHERE id = v_new_uid) THEN
        PERFORM private.grant_welcome_bonus_if_eligible(
            v_new_uid, v_device_id,
            'inst_846a6527-76f2-4851-8b72-5d1f51d0929d', 300
        );
    END IF;
END;
$repair$;

COMMIT;
