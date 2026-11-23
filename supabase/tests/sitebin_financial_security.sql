-- SiteBin real PostgreSQL integration smoke tests.
-- Run only against a disposable/transactional test context.
-- This file intentionally uses BEGIN/ROLLBACK and never creates permanent test data.

BEGIN;

DO $$
DECLARE
    v_tag text := substr(md5(clock_timestamp()::text || random()::text), 1, 10);
    v_uid uuid := gen_random_uuid();
    v_before_available bigint;
    v_before_reserved bigint;
    v_create json;
    v_campaign record;
    v_campaign_id uuid;
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

    SELECT available_coins, reserved_coins
      INTO v_before_available, v_before_reserved
    FROM public.profiles
    WHERE id = v_uid;

    -- Anonymous users use the authenticated Postgres role, so the server must
    -- explicitly reject them for financial SiteBin operations.
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
        RAISE EXCEPTION 'TEST_FAILED: anonymous request unexpectedly succeeded';
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

    -- RPC-level destination validation.
    BEGIN
        PERFORM public.create_campaign(
            'http://example.com',
            'http://example.com',
            'example.com',
            5,
            1
        );
        RAISE EXCEPTION 'TEST_FAILED: HTTP destination unexpectedly accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF position('INVALID_URL:' IN SQLERRM) = 0 THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM public.create_campaign(
            'https://127.0.0.1',
            'https://127.0.0.1',
            '127.0.0.1',
            5,
            1
        );
        RAISE EXCEPTION 'TEST_FAILED: private IPv4 destination unexpectedly accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF position('INVALID_URL:' IN SQLERRM) = 0 THEN
                RAISE;
            END IF;
    END;

    -- Server-authoritative domain and reservation.
    SELECT public.create_campaign(
        'https://example.com/path',
        'https://example.com/path',
        'attacker.invalid',
        5,
        1
    )
    INTO v_create;

    v_campaign_id := (v_create->>'id')::uuid;

    SELECT * INTO v_campaign
      FROM public.campaigns
     WHERE id = v_campaign_id;

    IF v_campaign.domain <> 'example.com'
       OR v_campaign.total_budget <> 5
       OR v_campaign.spent_budget <> 0
       OR v_campaign.reserved_budget <> 5
       OR v_campaign.refunded_budget <> 0
       OR v_campaign.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'TEST_FAILED: reservation/domain invariant mismatch';
    END IF;

    -- Cancellation must move the remaining reservation into explicit refund
    -- accounting and restore the owner's spendable/reserved balances.
    PERFORM public.cancel_campaign(v_campaign_id);

    SELECT * INTO v_campaign
      FROM public.campaigns
     WHERE id = v_campaign_id;

    IF v_campaign.status <> 'CANCELLED'
       OR v_campaign.spent_budget <> 0
       OR v_campaign.reserved_budget <> 0
       OR v_campaign.refunded_budget <> 5
       OR v_campaign.spent_budget + v_campaign.reserved_budget + v_campaign.refunded_budget <> v_campaign.total_budget THEN
        RAISE EXCEPTION 'TEST_FAILED: refund invariant mismatch';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM public.coin_ledger
         WHERE user_id = v_uid
           AND transaction_type = 'CAMPAIGN_REFUND'
           AND reference_id = v_campaign_id::text
           AND amount = 5
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: refund ledger entry missing';
    END IF;

    PERFORM 1
      FROM public.profiles
     WHERE id = v_uid
       AND available_coins = v_before_available
       AND reserved_coins = v_before_reserved;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEST_FAILED: owner balances did not return to baseline';
    END IF;
END;
$$;

ROLLBACK;
