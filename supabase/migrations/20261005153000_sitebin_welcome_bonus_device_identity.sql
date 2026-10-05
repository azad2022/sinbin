
-- SiteBin Welcome Bonus: device-authoritative lifetime entitlement.
-- No raw device identifiers are persisted. Strong identifiers are HMACed with a
-- server-only Vault secret. Existing welcome grants are preserved verbatim.

BEGIN;

CREATE SCHEMA IF NOT EXISTS private;

DO $provision$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM vault.secrets WHERE name = 'sitebin_device_hmac_v1'
  ) THEN
    PERFORM vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'sitebin_device_hmac_v1',
      'SiteBin server-only HMAC key for device evidence normalization'
    );
  END IF;
END;
$provision$;

CREATE TABLE IF NOT EXISTS private.device_identities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  android_id_hmac text,
  app_set_id_hmac text,
  app_set_scope text,
  installation_key_fingerprint text,
  legacy_install_id_hmac text,
  first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  first_auth_uid uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  current_auth_uid uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  risk_score integer NOT NULL DEFAULT 0 CHECK (risk_score BETWEEN 0 AND 100),
  risk_level text NOT NULL DEFAULT 'MEDIUM'
    CHECK (risk_level = ANY (ARRAY['LOW'::text,'MEDIUM'::text,'HIGH'::text])),
  integrity_status text NOT NULL DEFAULT 'NOT_CHECKED'
    CHECK (integrity_status = ANY (ARRAY['NOT_CHECKED'::text,'PASS'::text,'FAIL'::text])),
  app_version text,
  platform_metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

ALTER TABLE private.device_identities
  ADD CONSTRAINT device_identities_android_hmac_format
  CHECK (android_id_hmac IS NULL OR android_id_hmac ~ '^[0-9a-f]{64}$');

ALTER TABLE private.device_identities
  ADD CONSTRAINT device_identities_app_set_hmac_format
  CHECK (app_set_id_hmac IS NULL OR app_set_id_hmac ~ '^[0-9a-f]{64}$');

ALTER TABLE private.device_identities
  ADD CONSTRAINT device_identities_install_fingerprint_format
  CHECK (
    installation_key_fingerprint IS NULL
    OR installation_key_fingerprint ~ '^[0-9a-f]{64}$'
  );

ALTER TABLE private.device_identities
  ADD CONSTRAINT device_identities_legacy_install_hmac_format
  CHECK (
    legacy_install_id_hmac IS NULL
    OR legacy_install_id_hmac ~ '^[0-9a-f]{64}$'
  );

ALTER TABLE private.device_identities
  ADD CONSTRAINT device_identities_app_set_scope_check
  CHECK (
    app_set_scope IS NULL
    OR app_set_scope = ANY (ARRAY['DEVELOPER'::text,'APP'::text])
  );

CREATE UNIQUE INDEX IF NOT EXISTS uq_device_identities_android_hmac
  ON private.device_identities(android_id_hmac)
  WHERE android_id_hmac IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_device_identities_app_set_hmac
  ON private.device_identities(app_set_id_hmac)
  WHERE app_set_id_hmac IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_device_identities_installation_fingerprint
  ON private.device_identities(installation_key_fingerprint)
  WHERE installation_key_fingerprint IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_device_identities_legacy_install_hmac
  ON private.device_identities(legacy_install_id_hmac)
  WHERE legacy_install_id_hmac IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_device_identities_current_auth_uid
  ON private.device_identities(current_auth_uid);

CREATE TABLE IF NOT EXISTS private.welcome_bonus_entitlements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_identity_id uuid NOT NULL
    REFERENCES private.device_identities(id) ON DELETE RESTRICT,
  beneficiary_auth_uid uuid NOT NULL
    REFERENCES auth.users(id) ON DELETE RESTRICT,
  amount bigint NOT NULL CHECK (amount > 0),
  source text NOT NULL DEFAULT 'WELCOME_BONUS_V1',
  claim_state text NOT NULL DEFAULT 'CLAIMED'
    CHECK (claim_state = ANY (ARRAY['CLAIMED'::text])),
  granted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT welcome_bonus_entitlements_device_unique UNIQUE (device_identity_id),
  CONSTRAINT welcome_bonus_entitlements_beneficiary_unique UNIQUE (beneficiary_auth_uid)
);

CREATE INDEX IF NOT EXISTS idx_welcome_bonus_entitlements_beneficiary
  ON private.welcome_bonus_entitlements(beneficiary_auth_uid);

CREATE TABLE IF NOT EXISTS private.welcome_bonus_attempt_buckets (
  signal_hmac text PRIMARY KEY
    CHECK (signal_hmac ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0)
);

REVOKE ALL ON private.device_identities FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON private.welcome_bonus_entitlements FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON private.welcome_bonus_attempt_buckets FROM PUBLIC, anon, authenticated, service_role;
GRANT ALL ON private.device_identities TO postgres;
GRANT ALL ON private.welcome_bonus_entitlements TO postgres;
GRANT ALL ON private.welcome_bonus_attempt_buckets TO postgres;

CREATE OR REPLACE FUNCTION private.device_identifier_hmac(
  p_signal_type text,
  p_value text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_secret text;
  v_normalized text;
BEGIN
  IF p_signal_type NOT IN (
    'android_id',
    'app_set_id',
    'installation_key_fingerprint',
    'legacy_install_id'
  ) THEN
    RAISE EXCEPTION 'INVALID_DEVICE_SIGNAL_TYPE';
  END IF;

  v_normalized := pg_catalog.lower(pg_catalog.btrim(p_value));
  IF v_normalized IS NULL OR v_normalized = '' THEN
    RETURN NULL;
  END IF;

  SELECT decrypted_secret
  INTO v_secret
  FROM vault.decrypted_secrets
  WHERE name = 'sitebin_device_hmac_v1'
  LIMIT 1;

  IF v_secret IS NULL OR pg_catalog.btrim(v_secret) = '' THEN
    RAISE EXCEPTION 'DEVICE_IDENTITY_CONFIG_MISSING: server HMAC key is not configured';
  END IF;

  RETURN encode(
    extensions.hmac(
      'sitebin:v1:' || p_signal_type || ':' || v_normalized,
      v_secret,
      'sha256'
    ),
    'hex'
  );
END;
$function$;

REVOKE ALL ON FUNCTION private.device_identifier_hmac(text,text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.device_identifier_hmac(text,text) TO postgres;

-- Preserve existing historical grants without minting anything.
-- The legacy install ID is only a migration association signal; it is never
-- sufficient to authorize a new welcome bonus.
INSERT INTO private.device_identities(
  legacy_install_id_hmac,
  first_seen_at,
  last_seen_at,
  first_auth_uid,
  current_auth_uid,
  risk_score,
  risk_level,
  integrity_status,
  app_version,
  platform_metadata
)
SELECT
  private.device_identifier_hmac('legacy_install_id', g.install_id),
  MIN(g.granted_at),
  MAX(g.granted_at),
  g.user_id,
  g.user_id,
  0,
  'MEDIUM',
  'NOT_CHECKED',
  NULL,
  jsonb_build_object('source', 'legacy_welcome_bonus_grants')
FROM public.welcome_bonus_grants g
WHERE g.install_id IS NOT NULL
  AND pg_catalog.btrim(g.install_id) <> ''
GROUP BY g.install_id, g.user_id
ON CONFLICT DO NOTHING;

INSERT INTO private.welcome_bonus_entitlements(
  device_identity_id,
  beneficiary_auth_uid,
  amount,
  source,
  claim_state,
  granted_at,
  created_at
)
SELECT
  di.id,
  g.user_id,
  g.amount,
  'WELCOME_BONUS_LEGACY',
  'CLAIMED',
  g.granted_at,
  g.granted_at
FROM public.welcome_bonus_grants g
JOIN private.device_identities di
  ON di.legacy_install_id_hmac =
     private.device_identifier_hmac('legacy_install_id', g.install_id)
ON CONFLICT (beneficiary_auth_uid) DO NOTHING;

DROP FUNCTION IF EXISTS public.init_user_account(text,text);

CREATE FUNCTION public.init_user_account(
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

REVOKE ALL ON FUNCTION public.init_user_account(
  text,text,text,text,text,text
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.init_user_account(
  text,text,text,text,text,text
) TO authenticated, service_role;

COMMIT;
