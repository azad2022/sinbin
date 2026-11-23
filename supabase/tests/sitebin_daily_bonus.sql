-- Device-authoritative daily bonus integration test.
-- Uses an isolated Auth user, Device Identity, prior-day welcome grant and
-- server-completed Session. Every mutation is rolled back.

BEGIN;

DO $test$
DECLARE
    v_tag text := substr(md5(clock_timestamp()::text || random()::text), 1, 10);
    v_uid uuid := gen_random_uuid();
    v_device_id uuid := gen_random_uuid();
    v_android_id text := '0123456789abcdef';
    v_install_fp text := repeat('a', 64);
    v_url text := 'https://s2-daily-' || v_tag || '.example.com/';
    v_domain text := 's2-daily-' || v_tag || '.example.com';
    v_token text := 's2-daily-bonus-' || substr(md5(clock_timestamp()::text),1,24);
    v_token_hash text := encode(extensions.digest(v_token, 'sha256'), 'hex');
    v_campaign_id uuid;
    v_session_id uuid;
    v_result json;
    v_before_available bigint;
    v_after_available bigint;
    v_before_earned bigint;
    v_after_earned bigint;
    v_daily_rows bigint;
    v_daily_ledger_rows bigint;
    v_device_claim_rows bigint;
    v_today date := (clock_timestamp() AT TIME ZONE 'UTC')::date;
BEGIN
    INSERT INTO auth.users(
        id, aud, role, email, email_confirmed_at,
        created_at, updated_at, is_sso_user, is_anonymous
    )
    VALUES(
        v_uid, 'authenticated', 'authenticated',
        's2_daily_' || v_tag || '@sitebin.internal',
        clock_timestamp(), clock_timestamp(), clock_timestamp(), false, false
    );

    INSERT INTO public.profiles(
        id, user_handle, app_install_id, available_coins, reserved_coins,
        lifetime_earned, lifetime_spent, trust_score, completed_views_count,
        received_views_count, welcome_bonus_claimed, created_at, updated_at
    )
    VALUES(
        v_uid, 's2_daily_' || v_tag, 's2_daily_inst_' || v_tag,
        1000, 0, 300, 0, 100, 0, 0, true,
        clock_timestamp(), clock_timestamp()
    );

    INSERT INTO private.device_identities(
        id, android_id_hmac, installation_key_fingerprint,
        first_seen_at, last_seen_at, first_auth_uid, current_auth_uid,
        risk_score, risk_level, integrity_status, platform_metadata
    )
    VALUES(
        v_device_id,
        private.device_identifier_hmac('android_id', v_android_id),
        private.device_identifier_hmac('installation_key_fingerprint', v_install_fp),
        clock_timestamp(), clock_timestamp(), v_uid, v_uid,
        80, 'LOW', 'NOT_CHECKED',
        jsonb_build_object('source', 'sitebin_daily_bonus_isolated_test')
    );

    INSERT INTO private.welcome_bonus_entitlements(
        device_identity_id, beneficiary_auth_uid, amount, source,
        claim_state, granted_at, created_at
    )
    VALUES(
        v_device_id, v_uid, 300, 'WELCOME_BONUS_V1',
        'CLAIMED', clock_timestamp() - INTERVAL '1 day',
        clock_timestamp() - INTERVAL '1 day'
    );

    INSERT INTO public.welcome_bonus_grants(user_id, install_id, amount, granted_at)
    VALUES(
        v_uid, 's2_daily_inst_' || v_tag, 300, clock_timestamp() - INTERVAL '1 day'
    );

    IF has_function_privilege(
        'anon',
        'public.claim_daily_bonus(text,text,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'DAILY_BONUS_FAIL: anon can execute claim_daily_bonus';
    END IF;

    IF NOT has_function_privilege(
        'authenticated',
        'public.claim_daily_bonus(text,text,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'DAILY_BONUS_FAIL: authenticated cannot execute claim_daily_bonus';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        json_build_object(
            'sub', v_uid::text,
            'role', 'authenticated',
            'is_anonymous', false
        )::text,
        true
    );
    PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);

    INSERT INTO private.campaign_preflight_tokens(
        token_hash, user_id, source_url, normalized_url, domain, final_url,
        http_status, redirect_count, response_ms, content_type, content_length,
        viewer_compatibility, quality_score, diagnostics, created_at, expires_at
    )
    VALUES(
        v_token_hash, v_uid, v_url, v_url, v_domain, v_url,
        200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
        jsonb_build_object('referral_site_key', v_domain),
        clock_timestamp(), clock_timestamp() + INTERVAL '10 minutes'
    );

    SELECT (public.create_campaign(
        v_url, v_url, v_domain, 5, 1, NULL, v_token
    )->>'id')::uuid INTO v_campaign_id;

    -- This is a fixture for the server-validated completed-view prerequisite.
    INSERT INTO public.view_sessions(
        campaign_id, viewer_id, required_duration_seconds, reward_coins,
        status, started_at, content_ready_at, completed_at, created_at
    )
    VALUES(
        v_campaign_id, v_uid, 5, 3,
        'COMPLETED',
        clock_timestamp() - INTERVAL '10 seconds',
        clock_timestamp() - INTERVAL '7 seconds',
        clock_timestamp() - INTERVAL '1 second',
        clock_timestamp() - INTERVAL '1 second'
    )
    RETURNING id INTO v_session_id;

    SELECT available_coins, lifetime_earned
      INTO v_before_available, v_before_earned
    FROM public.profiles
    WHERE id = v_uid;

    -- Authenticated role carrying an anonymous JWT must still be rejected.
    PERFORM set_config(
        'request.jwt.claims',
        json_build_object(
            'sub', v_uid::text,
            'role', 'authenticated',
            'is_anonymous', true
        )::text,
        true
    );
    PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);

    BEGIN
        PERFORM public.claim_daily_bonus(
            v_android_id, NULL, NULL, v_install_fp
        );
        RAISE EXCEPTION 'DAILY_BONUS_FAIL: anonymous claim unexpectedly succeeded';
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
    PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);

    v_result := public.claim_daily_bonus(
        v_android_id, NULL, NULL, v_install_fp
    );

    IF (v_result->>'granted')::boolean IS NOT TRUE
       OR (v_result->>'amount')::bigint <> 50 THEN
        RAISE EXCEPTION 'DAILY_BONUS_FAIL: first valid claim did not grant 50: %', v_result;
    END IF;

    SELECT available_coins, lifetime_earned
      INTO v_after_available, v_after_earned
    FROM public.profiles
    WHERE id = v_uid;

    IF v_after_available <> v_before_available + 50
       OR v_after_earned <> v_before_earned + 50 THEN
        RAISE EXCEPTION 'DAILY_BONUS_FAIL: profile balance/lifetime delta is not exactly 50';
    END IF;

    v_result := public.claim_daily_bonus(
        v_android_id, NULL, NULL, v_install_fp
    );

    IF (v_result->>'granted')::boolean IS NOT FALSE
       OR v_result->>'reason' <> 'ALREADY_CLAIMED' THEN
        RAISE EXCEPTION 'DAILY_BONUS_FAIL: duplicate same-day claim was not idempotent: %', v_result;
    END IF;

    SELECT count(*) INTO v_daily_rows
    FROM public.daily_bonus_grants
    WHERE user_id = v_uid AND grant_date = v_today;

    SELECT count(*) INTO v_daily_ledger_rows
    FROM public.coin_ledger
    WHERE user_id = v_uid
      AND transaction_type = 'DAILY_BONUS'
      AND reference_id = (
          SELECT id::text
          FROM public.daily_bonus_grants
          WHERE user_id = v_uid AND grant_date = v_today
      );

    SELECT count(*) INTO v_device_claim_rows
    FROM private.daily_bonus_device_claims
    WHERE device_identity_id = v_device_id
      AND grant_date = v_today
      AND beneficiary_auth_uid = v_uid;

    IF v_daily_rows <> 1 OR v_daily_ledger_rows <> 1 OR v_device_claim_rows <> 1 THEN
        RAISE EXCEPTION 'DAILY_BONUS_FAIL: grant/ledger/device claim rows were not exactly one';
    END IF;

    RAISE NOTICE 'PASS: daily bonus requires authenticated device evidence and a completed view; duplicate claim is idempotent';
END;
$test$;

ROLLBACK;
