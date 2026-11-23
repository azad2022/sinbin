-- SiteBin financial/security integration smoke test.
-- Isolated account + preflight token; all mutations are rolled back.

BEGIN;

DO $test$
DECLARE
    v_tag text := substr(md5(clock_timestamp()::text || random()::text), 1, 10);
    v_uid uuid := gen_random_uuid();
    v_url text := 'https://s2-fin-' || v_tag || '.example.com/path';
    v_domain text := 's2-fin-' || v_tag || '.example.com';
    v_token text := 's2-financial-' || substr(md5(clock_timestamp()::text),1,24);
    v_token_hash text := encode(extensions.digest(v_token, 'sha256'), 'hex');
    v_create json;
    v_campaign record;
    v_campaign_id uuid;
    v_before_available bigint;
    v_before_reserved bigint;
    v_after_available bigint;
    v_after_reserved bigint;
    v_ip_url text := 'https://127.0.0.1/';
    v_ip_domain text := '127.0.0.1';
    v_ip_token text := 's2-financial-ip-' || substr(md5(clock_timestamp()::text),1,24);
    v_ip_token_hash text := encode(extensions.digest(v_ip_token, 'sha256'), 'hex');
BEGIN
    INSERT INTO auth.users(
        id, aud, role, email, email_confirmed_at,
        created_at, updated_at, is_sso_user, is_anonymous
    )
    VALUES(
        v_uid, 'authenticated', 'authenticated',
        's2_financial_' || v_tag || '@sitebin.internal',
        clock_timestamp(), clock_timestamp(), clock_timestamp(), false, false
    );

    INSERT INTO public.profiles(
        id, user_handle, app_install_id, available_coins, reserved_coins,
        lifetime_earned, lifetime_spent, trust_score, completed_views_count,
        received_views_count, welcome_bonus_claimed, created_at, updated_at
    )
    VALUES(
        v_uid, 's2_fin_' || v_tag, 's2_fin_inst_' || v_tag,
        1000, 0, 1000, 0, 100, 0, 0, true,
        clock_timestamp(), clock_timestamp()
    );

    -- Anonymous JWTs are rejected by the mutation itself even when Postgres role
    -- is authenticated. No campaign inventory is needed for this auth check.
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
        PERFORM public.request_view_session();
        RAISE EXCEPTION 'FINANCIAL_FAIL: anonymous request unexpectedly succeeded';
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

    -- Without a server-side HTTPS preflight token, an HTTP URL is rejected at the preflight gate.
    BEGIN
        PERFORM public.create_campaign(
            'http://example.com',
            'http://example.com',
            'example.com',
            5,
            1,
            NULL,
            NULL
        );
        RAISE EXCEPTION 'FINANCIAL_FAIL: HTTP destination unexpectedly accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF position('PREFLIGHT_REQUIRED:' IN SQLERRM) = 0 THEN RAISE; END IF;
    END;

    -- A valid preflight token lets URL validation reach the authoritative
    -- private-IP guard instead of failing earlier at the preflight boundary.
    INSERT INTO private.campaign_preflight_tokens(
        token_hash, user_id, source_url, normalized_url, domain, final_url,
        http_status, redirect_count, response_ms, content_type, content_length,
        viewer_compatibility, quality_score, diagnostics, created_at, expires_at
    ) VALUES (
        v_ip_token_hash, v_uid, v_ip_url, v_ip_url, v_ip_domain, v_ip_url,
        200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 95,
        jsonb_build_object('referral_site_key', v_ip_domain),
        clock_timestamp(), clock_timestamp() + INTERVAL '10 minutes'
    );

    BEGIN
        PERFORM public.create_campaign(
            v_ip_url,
            v_ip_url,
            v_ip_domain,
            5,
            1,
            NULL,
            v_ip_token
        );
        RAISE EXCEPTION 'FINANCIAL_FAIL: private IPv4 destination unexpectedly accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF position('INVALID_URL:' IN SQLERRM) = 0 THEN RAISE; END IF;
    END;

    SELECT available_coins, reserved_coins
      INTO v_before_available, v_before_reserved
    FROM public.profiles
    WHERE id = v_uid
    FOR UPDATE;

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

    SELECT public.create_campaign(
        v_url,
        v_url,
        'attacker.invalid',
        5,
        1,
        NULL,
        v_token
    ) INTO v_create;

    v_campaign_id := (v_create->>'id')::uuid;

    SELECT * INTO v_campaign
    FROM public.campaigns
    WHERE id = v_campaign_id;

    IF v_campaign.domain <> v_domain
       OR v_campaign.total_budget <> 5
       OR v_campaign.spent_budget <> 0
       OR v_campaign.reserved_budget <> 5
       OR v_campaign.refunded_budget <> 0
       OR v_campaign.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'FINANCIAL_FAIL: authoritative domain/budget reservation mismatch';
    END IF;

    SELECT available_coins, reserved_coins
      INTO v_after_available, v_after_reserved
    FROM public.profiles
    WHERE id = v_uid;

    IF v_after_available <> v_before_available - 5
       OR v_after_reserved <> v_before_reserved + 5 THEN
        RAISE EXCEPTION 'FINANCIAL_FAIL: campaign creation wallet reservation is wrong';
    END IF;

    PERFORM public.cancel_campaign(v_campaign_id);

    SELECT * INTO v_campaign
    FROM public.campaigns
    WHERE id = v_campaign_id;

    IF v_campaign.status <> 'CANCELLED'
       OR v_campaign.spent_budget <> 0
       OR v_campaign.reserved_budget <> 0
       OR v_campaign.refunded_budget <> 5
       OR v_campaign.spent_budget + v_campaign.reserved_budget + v_campaign.refunded_budget <> v_campaign.total_budget THEN
        RAISE EXCEPTION 'FINANCIAL_FAIL: campaign refund accounting mismatch';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.coin_ledger
        WHERE user_id = v_uid
          AND transaction_type = 'CAMPAIGN_REFUND'
          AND reference_id = v_campaign_id::text
          AND amount = 5
    ) THEN
        RAISE EXCEPTION 'FINANCIAL_FAIL: refund ledger entry missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.profiles
        WHERE id = v_uid
          AND available_coins = v_before_available
          AND reserved_coins = v_before_reserved
    ) THEN
        RAISE EXCEPTION 'FINANCIAL_FAIL: owner balances did not return to baseline';
    END IF;

    RAISE NOTICE 'PASS: auth, URL validation, authoritative campaign budget reservation and refund invariants';
END;
$test$;

ROLLBACK;
