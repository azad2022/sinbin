-- Keep a small, reusable demo viewer pool independent of the account
-- that owns the original seed campaigns. This preserves anti-self-view rules
-- while ensuring fresh/test accounts can always receive default sites.

DO $$
DECLARE
    v_owner UUID;
    v_domain TEXT;
    v_url TEXT;
    v_campaign_id UUID;
BEGIN
    FOREACH v_owner IN ARRAY ARRAY[
        'cf96b011-3163-4b44-bb5d-ba6d8741e456'::uuid,
        '0328a88e-0c70-4d32-829c-9049b8096cfb'::uuid
    ] LOOP
        FOREACH v_domain IN ARRAY ARRAY['solmint.ir','cafebazaar.ir','wikipedia.org'] LOOP
            v_url := CASE v_domain
                WHEN 'solmint.ir' THEN 'https://solmint.ir'
                WHEN 'cafebazaar.ir' THEN 'https://cafebazaar.ir/app/?id=com.bloggersho.teleprompter.app&ref=share'
                ELSE 'https://wikipedia.org'
            END;

            IF NOT EXISTS (
                SELECT 1
                FROM public.campaigns
                WHERE owner_id = v_owner AND domain = v_domain
            ) THEN
                PERFORM 1
                FROM public.profiles
                WHERE id = v_owner
                FOR UPDATE;

                IF (SELECT available_coins FROM public.profiles WHERE id = v_owner) < 25 THEN
                    RAISE EXCEPTION 'INSUFFICIENT_SEED_BALANCE for owner %', v_owner;
                END IF;

                INSERT INTO public.campaigns(
                    owner_id,
                    url,
                    normalized_url,
                    domain,
                    duration_seconds,
                    target_views,
                    completed_views,
                    cost_per_view,
                    total_budget,
                    spent_budget,
                    reserved_budget,
                    refunded_budget,
                    status,
                    created_at,
                    updated_at
                )
                VALUES(
                    v_owner,
                    v_url,
                    CASE v_domain
                        WHEN 'solmint.ir' THEN 'https://solmint.ir/'
                        WHEN 'cafebazaar.ir' THEN v_url
                        ELSE 'https://wikipedia.org/'
                    END,
                    v_domain,
                    5,
                    5,
                    0,
                    5,
                    25,
                    0,
                    25,
                    0,
                    'ACTIVE',
                    pg_catalog.clock_timestamp(),
                    pg_catalog.clock_timestamp()
                )
                RETURNING id INTO v_campaign_id;

                UPDATE public.profiles
                SET available_coins = available_coins - 25,
                    reserved_coins = reserved_coins + 25,
                    updated_at = pg_catalog.clock_timestamp()
                WHERE id = v_owner;

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
                    v_owner,
                    -25,
                    'CAMPAIGN_RESERVATION',
                    'رزرو بودجه سایت پیش‌فرض تست بازدید ' || v_domain,
                    v_campaign_id::text,
                    'default_view_seed_' || v_owner::text || '_' || replace(v_domain, '.', '_'),
                    pg_catalog.clock_timestamp()
                );
            END IF;
        END LOOP;
    END LOOP;
END $$;
