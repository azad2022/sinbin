ALTER TABLE public.coin_ledger
  DROP CONSTRAINT IF EXISTS coin_ledger_transaction_type_check;

ALTER TABLE public.coin_ledger
  ADD CONSTRAINT coin_ledger_transaction_type_check
  CHECK (transaction_type = ANY (ARRAY[
    'WELCOME_REWARD'::text,
    'VIEW_REWARD'::text,
    'CAMPAIGN_RESERVATION'::text,
    'CAMPAIGN_SPEND'::text,
    'CAMPAIGN_REFUND'::text,
    'REFERRAL_REWARD'::text,
    'PLATFORM_GRANT'::text
  ]));

CREATE OR REPLACE FUNCTION public.init_user_account(
    p_install_id text,
    p_handle text DEFAULT NULL::text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_uid UUID := (select auth.uid());
    v_profile RECORD;
    v_bonus_amount BIGINT := 150;
    v_handle TEXT;
    v_clean_install TEXT;
    v_existing_grant_user UUID;
    v_existing_profile_user UUID;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    v_clean_install := nullif(trim(p_install_id), '');
    IF v_clean_install IS NULL THEN
        RAISE EXCEPTION 'INVALID_INSTALL_ID: Installation identifier is required for account initialization';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('install_' || v_clean_install));

    SELECT user_id INTO v_existing_grant_user
    FROM public.welcome_bonus_grants
    WHERE install_id = v_clean_install;

    IF v_existing_grant_user IS NOT NULL AND v_existing_grant_user != v_uid THEN
        RAISE EXCEPTION 'INSTALL_ALREADY_REGISTERED: Installation identifier is already associated with another account';
    END IF;

    SELECT id INTO v_existing_profile_user
    FROM public.profiles
    WHERE app_install_id = v_clean_install;

    IF v_existing_profile_user IS NOT NULL AND v_existing_profile_user != v_uid THEN
        RAISE EXCEPTION 'INSTALL_ALREADY_REGISTERED: Installation identifier is already associated with another account';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('user_init_' || v_uid::text));

    SELECT * INTO v_profile
    FROM public.profiles
    WHERE id = v_uid
    FOR UPDATE;

    IF v_profile IS NULL THEN
        v_handle := coalesce(
            nullif(trim(p_handle), ''),
            'user_' || substring(v_uid::text, 1, 8)
        );

        IF EXISTS (SELECT 1 FROM public.welcome_bonus_grants WHERE user_id = v_uid) THEN
            v_bonus_amount := 0;
        END IF;

        INSERT INTO public.profiles(
            id,user_handle,app_install_id,available_coins,reserved_coins,
            lifetime_earned,lifetime_spent,trust_score,completed_views_count,
            received_views_count,welcome_bonus_claimed,created_at,updated_at
        )
        VALUES(
            v_uid,v_handle,v_clean_install,v_bonus_amount,0,
            v_bonus_amount,0,100.0,0,0,(v_bonus_amount>0),
            pg_catalog.clock_timestamp(),pg_catalog.clock_timestamp()
        )
        RETURNING * INTO v_profile;

        IF v_bonus_amount > 0 THEN
            INSERT INTO public.welcome_bonus_grants(user_id,install_id,amount,granted_at)
            VALUES(v_uid,v_clean_install,v_bonus_amount,pg_catalog.clock_timestamp());

            INSERT INTO public.coin_ledger(
                user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
            )
            VALUES(
                v_uid,v_bonus_amount,'WELCOME_REWARD',
                'هدیه ورود به سایت بین (Welcome Bonus)','init_bonus',
                'welcome_' || v_uid::text,pg_catalog.clock_timestamp()
            );
        END IF;
    ELSE
        IF NOT EXISTS (
            SELECT 1 FROM public.welcome_bonus_grants WHERE user_id = v_uid
        ) AND COALESCE(v_profile.welcome_bonus_claimed, false) = false THEN
            UPDATE public.profiles
            SET available_coins = available_coins + v_bonus_amount,
                lifetime_earned = lifetime_earned + v_bonus_amount,
                welcome_bonus_claimed = true,
                updated_at = pg_catalog.clock_timestamp()
            WHERE id = v_uid
            RETURNING * INTO v_profile;

            INSERT INTO public.welcome_bonus_grants(user_id,install_id,amount,granted_at)
            VALUES(v_uid,v_clean_install,v_bonus_amount,pg_catalog.clock_timestamp());

            INSERT INTO public.coin_ledger(
                user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
            )
            VALUES(
                v_uid,v_bonus_amount,'WELCOME_REWARD',
                'هدیه ورود به سایت بین (Welcome Bonus)','init_bonus_repair',
                'welcome_' || v_uid::text,pg_catalog.clock_timestamp()
            );
        ELSIF COALESCE(v_profile.welcome_bonus_claimed, false) = false
              AND EXISTS (SELECT 1 FROM public.welcome_bonus_grants WHERE user_id = v_uid) THEN
            UPDATE public.profiles
            SET welcome_bonus_claimed = true,
                updated_at = pg_catalog.clock_timestamp()
            WHERE id = v_uid
            RETURNING * INTO v_profile;
        END IF;
    END IF;

    RETURN pg_catalog.row_to_json(v_profile);
END;
$function$;

DO $seed$
DECLARE
    v_owner_id UUID;
    v_seed_grant BIGINT := 450;
    v_existing_grant BOOLEAN := false;
BEGIN
    SELECT p.id INTO v_owner_id
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.user_handle = 'tester'
      AND u.email LIKE 'sitebin_test_%@sitebin.internal'
      AND COALESCE(u.is_anonymous, false) = false
    ORDER BY u.created_at ASC
    LIMIT 1;

    IF v_owner_id IS NULL THEN
        RETURN;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM public.coin_ledger
        WHERE user_id = v_owner_id
          AND transaction_type = 'PLATFORM_GRANT'
          AND reference_id = 'sitebin_demo_seed_v1'
    ) INTO v_existing_grant;

    IF NOT v_existing_grant THEN
        UPDATE public.profiles
        SET available_coins = available_coins + v_seed_grant,
            lifetime_earned = lifetime_earned + v_seed_grant,
            updated_at = pg_catalog.clock_timestamp()
        WHERE id = v_owner_id;

        INSERT INTO public.coin_ledger(
            user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
        )
        VALUES(
            v_owner_id, v_seed_grant, 'PLATFORM_GRANT',
            'بودجه آزمایشی رسمی برای کمپین‌های نمونه SiteBin',
            'sitebin_demo_seed_v1',
            'platform_grant_sitebin_demo_seed_v1',
            pg_catalog.clock_timestamp()
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.campaigns
        WHERE owner_id = v_owner_id AND domain = 'solmint.ir'
    ) THEN
        INSERT INTO public.campaigns(
            owner_id,url,normalized_url,domain,duration_seconds,target_views,
            completed_views,cost_per_view,total_budget,spent_budget,reserved_budget,refunded_budget,status,
            created_at,updated_at
        )
        VALUES(
            v_owner_id,
            'https://solmint.ir',
            'https://solmint.ir/',
            'solmint.ir',
            5,30,
            0,5,150,0,150,0,'ACTIVE',
            pg_catalog.clock_timestamp(),pg_catalog.clock_timestamp()
        );

        INSERT INTO public.coin_ledger(
            user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
        )
        VALUES(
            v_owner_id,-150,'CAMPAIGN_RESERVATION',
            'رزرو بودجه کمپین نمونه solmint.ir',
            'sitebin_demo_campaign_solmint',
            'sitebin_demo_reserve_solmint_v1',
            pg_catalog.clock_timestamp()
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.campaigns
        WHERE owner_id = v_owner_id AND domain = 'cafebazaar.ir'
    ) THEN
        INSERT INTO public.campaigns(
            owner_id,url,normalized_url,domain,duration_seconds,target_views,
            completed_views,cost_per_view,total_budget,spent_budget,reserved_budget,refunded_budget,status,
            created_at,updated_at
        )
        VALUES(
            v_owner_id,
            'https://cafebazaar.ir/app/?id=com.bloggersho.teleprompter.app&ref=share',
            'https://cafebazaar.ir/app/?id=com.bloggersho.teleprompter.app&ref=share',
            'cafebazaar.ir',
            5,30,
            0,5,150,0,150,0,'ACTIVE',
            pg_catalog.clock_timestamp(),pg_catalog.clock_timestamp()
        );

        INSERT INTO public.coin_ledger(
            user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
        )
        VALUES(
            v_owner_id,-150,'CAMPAIGN_RESERVATION',
            'رزرو بودجه کمپین نمونه cafebazaar.ir',
            'sitebin_demo_campaign_cafebazaar',
            'sitebin_demo_reserve_cafebazaar_v1',
            pg_catalog.clock_timestamp()
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.campaigns
        WHERE owner_id = v_owner_id AND domain = 'wikipedia.org'
    ) THEN
        INSERT INTO public.campaigns(
            owner_id,url,normalized_url,domain,duration_seconds,target_views,
            completed_views,cost_per_view,total_budget,spent_budget,reserved_budget,refunded_budget,status,
            created_at,updated_at
        )
        VALUES(
            v_owner_id,
            'https://wikipedia.org',
            'https://wikipedia.org/',
            'wikipedia.org',
            5,30,
            0,5,150,0,150,0,'ACTIVE',
            pg_catalog.clock_timestamp(),pg_catalog.clock_timestamp()
        );

        INSERT INTO public.coin_ledger(
            user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
        )
        VALUES(
            v_owner_id,-150,'CAMPAIGN_RESERVATION',
            'رزرو بودجه کمپین نمونه wikipedia.org',
            'sitebin_demo_campaign_wikipedia',
            'sitebin_demo_reserve_wikipedia_v1',
            pg_catalog.clock_timestamp()
        );
    END IF;

    UPDATE public.profiles
    SET available_coins = GREATEST(available_coins - v_seed_grant, 0),
        reserved_coins = reserved_coins + v_seed_grant,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_owner_id
      AND NOT v_existing_grant;
END;
$seed$;

UPDATE public.coin_ledger
SET description = description
WHERE false;
