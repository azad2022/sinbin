-- SiteBin real PostgreSQL integration checks for campaign URL preflight.
-- Intended for a disposable transaction. Every financial assertion is rolled back.

BEGIN;

DO $$
DECLARE
    v_uid uuid;
    v_other_uid uuid;
    v_before_available bigint;
    v_before_reserved bigint;
    v_after_available bigint;
    v_after_reserved bigint;
    v_token text := 'sitebin-preflight-integration-token-20261005-abcdefghijklmnopqrstuvwxyz';
    v_token_hash text := encode(extensions.digest(v_token, 'sha256'), 'hex');
BEGIN
    SELECT id INTO v_uid
    FROM public.profiles
    ORDER BY created_at
    LIMIT 1;

    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'TEST_SETUP: no profile exists';
    END IF;

    SELECT id INTO v_other_uid
    FROM public.profiles
    WHERE id <> v_uid
    LIMIT 1;

    PERFORM set_config(
        'request.jwt.claims',
        json_build_object('sub', v_uid::text, 'is_anonymous', false)::text,
        true
    );
    PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);

    IF has_function_privilege(
        'authenticated',
        'public.create_campaign(text,text,text,integer,integer,text)',
        'execute'
    ) THEN
        RAISE EXCEPTION 'TEST_FAIL: legacy 6-arg create_campaign remains executable';
    END IF;

    IF NOT has_function_privilege(
        'authenticated',
        'public.create_campaign(text,text,text,integer,integer,text,text)',
        'execute'
    ) THEN
        RAISE EXCEPTION 'TEST_FAIL: 7-arg create_campaign is not executable';
    END IF;

    IF has_function_privilege(
        'anon',
        'public.consume_campaign_url_preflight_rate_limit()',
        'execute'
    ) THEN
        RAISE EXCEPTION 'TEST_FAIL: anonymous preflight limiter execution is exposed';
    END IF;

    IF NOT has_function_privilege(
        'authenticated',
        'public.consume_campaign_url_preflight_rate_limit()',
        'execute'
    ) THEN
        RAISE EXCEPTION 'TEST_FAIL: authenticated preflight limiter execution missing';
    END IF;

    IF has_function_privilege(
        'authenticated',
        'public.store_campaign_preflight_token(text,uuid,text,text,text,text,integer,integer,bigint,text,bigint,text,integer,jsonb,timestamptz)',
        'execute'
    ) THEN
        RAISE EXCEPTION 'TEST_FAIL: token storage is executable by authenticated users';
    END IF;

    SELECT available_coins, reserved_coins
    INTO v_before_available, v_before_reserved
    FROM public.profiles
    WHERE id = v_uid
    FOR UPDATE;

    BEGIN
        PERFORM public.create_campaign(
            'https://example.com/',
            'https://example.com/',
            'example.com',
            5,
            1,
            NULL,
            NULL
        );
        RAISE EXCEPTION 'TEST_FAIL: create_campaign without preflight token succeeded';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM NOT LIKE 'PREFLIGHT_REQUIRED:%' THEN
                RAISE;
            END IF;
    END;

    SELECT available_coins, reserved_coins
    INTO v_after_available, v_after_reserved
    FROM public.profiles
    WHERE id = v_uid;

    IF v_after_available <> v_before_available OR v_after_reserved <> v_before_reserved THEN
        RAISE EXCEPTION 'TEST_FAIL: financial state changed after missing preflight token';
    END IF;

    INSERT INTO private.campaign_preflight_tokens(
        token_hash, user_id, source_url, normalized_url, domain, final_url,
        http_status, redirect_count, response_ms, content_type, content_length,
        viewer_compatibility, quality_score, diagnostics, created_at, expires_at
    )
    VALUES(
        v_token_hash, v_uid,
        'https://example.com/', 'https://example.com/', 'example.com', 'https://example.com/',
        200, 0, 120, 'text/html', 4096,
        'COMPATIBLE', 95, '[{"code":"TEST","severity":"INFO","message":"integration"}]'::jsonb,
        clock_timestamp(), clock_timestamp() + interval '10 minutes'
    );

    PERFORM public.create_campaign(
        'https://example.com/',
        'https://example.com/',
        'example.com',
        5,
        1,
        NULL,
        v_token
    );

    SELECT available_coins, reserved_coins
    INTO v_after_available, v_after_reserved
    FROM public.profiles
    WHERE id = v_uid;

    IF v_after_available <> v_before_available - 5 OR v_after_reserved <> v_before_reserved + 5 THEN
        RAISE EXCEPTION 'TEST_FAIL: successful preflight did not produce expected reservation';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM private.campaign_preflight_tokens
        WHERE token_hash = v_token_hash AND consumed_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'TEST_FAIL: preflight token was not consumed atomically';
    END IF;

    BEGIN
        PERFORM public.create_campaign(
            'https://example.com/',
            'https://example.com/',
            'example.com',
            5,
            1,
            NULL,
            v_token
        );
        RAISE EXCEPTION 'TEST_FAIL: consumed preflight token was reusable';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM NOT LIKE 'PREFLIGHT_REQUIRED:%' THEN
                RAISE;
            END IF;
    END;

    INSERT INTO private.campaign_preflight_tokens(
        token_hash, user_id, source_url, normalized_url, domain, final_url,
        http_status, redirect_count, response_ms, content_type, content_length,
        viewer_compatibility, quality_score, diagnostics, created_at, expires_at
    )
    VALUES(
        encode(extensions.digest('sitebin-preflight-mismatch-token-abcdefghijklmnopqrstuvwxyz', 'sha256'),'hex'),
        v_uid,
        'https://example.com/', 'https://example.com/', 'example.com', 'https://example.com/',
        200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 90, '[]'::jsonb,
        clock_timestamp(), clock_timestamp() + interval '10 minutes'
    );

    BEGIN
        PERFORM public.create_campaign(
            'https://example.org/',
            'https://example.org/',
            'example.org',
            5,
            1,
            NULL,
            'sitebin-preflight-mismatch-token-abcdefghijklmnopqrstuvwxyz'
        );
        RAISE EXCEPTION 'TEST_FAIL: preflight URL mismatch was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM NOT LIKE 'PREFLIGHT_MISMATCH:%' THEN
                RAISE;
            END IF;
    END;

    IF v_other_uid IS NOT NULL THEN
        INSERT INTO private.campaign_preflight_tokens(
            token_hash, user_id, source_url, normalized_url, domain, final_url,
            http_status, redirect_count, response_ms, content_type, content_length,
            viewer_compatibility, quality_score, diagnostics, created_at, expires_at
        )
        VALUES(
            encode(extensions.digest('sitebin-preflight-owner-token-abcdefghijklmnopqrstuvwxyz', 'sha256'),'hex'),
            v_other_uid,
            'https://example.com/', 'https://example.com/', 'example.com', 'https://example.com/',
            200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 90, '[]'::jsonb,
            clock_timestamp(), clock_timestamp() + interval '10 minutes'
        );

        BEGIN
            PERFORM public.create_campaign(
                'https://example.com/',
                'https://example.com/',
                'example.com',
                5,
                1,
                NULL,
                'sitebin-preflight-owner-token-abcdefghijklmnopqrstuvwxyz'
            );
            RAISE EXCEPTION 'TEST_FAIL: preflight token was usable by another user';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLERRM NOT LIKE 'PREFLIGHT_REQUIRED:%' THEN
                    RAISE;
                END IF;
        END;
    END IF;

    INSERT INTO private.campaign_preflight_tokens(
        token_hash, user_id, source_url, normalized_url, domain, final_url,
        http_status, redirect_count, response_ms, content_type, content_length,
        viewer_compatibility, quality_score, diagnostics, created_at, expires_at
    )
    VALUES(
        encode(extensions.digest('sitebin-preflight-expired-token-abcdefghijklmnopqrstuvwxyz', 'sha256'),'hex'),
        v_uid,
        'https://example.com/', 'https://example.com/', 'example.com', 'https://example.com/',
        200, 0, 100, 'text/html', 2048, 'COMPATIBLE', 90, '[]'::jsonb,
        clock_timestamp() - interval '20 minutes', clock_timestamp() - interval '10 minutes'
    );

    BEGIN
        PERFORM public.create_campaign(
            'https://example.com/',
            'https://example.com/',
            'example.com',
            5,
            1,
            NULL,
            'sitebin-preflight-expired-token-abcdefghijklmnopqrstuvwxyz'
        );
        RAISE EXCEPTION 'TEST_FAIL: expired preflight token was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM NOT LIKE 'PREFLIGHT_REQUIRED:%' THEN
                RAISE;
            END IF;
    END;

    DELETE FROM private.rate_limit_buckets WHERE user_id = v_uid AND action IN ('campaign_url_preflight','keyword_resolver');

    PERFORM private.enforce_user_rate_limit(v_uid, 'campaign_url_preflight');
    PERFORM private.enforce_user_rate_limit(v_uid, 'campaign_url_preflight');

    BEGIN
        PERFORM private.enforce_user_rate_limit(v_uid, 'campaign_url_preflight');
        RAISE EXCEPTION 'TEST_FAIL: preflight rate limit did not trip at 3rd request';
    EXCEPTION
        WHEN SQLSTATE 'PGRST' THEN
            NULL;
    END;

    DELETE FROM private.rate_limit_buckets WHERE user_id = v_uid AND action IN ('campaign_url_preflight','keyword_resolver');

    PERFORM private.enforce_user_rate_limit(v_uid, 'keyword_resolver');
    BEGIN
        PERFORM private.enforce_user_rate_limit(v_uid, 'keyword_resolver');
        RAISE EXCEPTION 'TEST_FAIL: keyword resolver rate limit did not trip at 2nd request';
    EXCEPTION
        WHEN SQLSTATE 'PGRST' THEN
            NULL;
    END;
END $$;

ROLLBACK;
