
-- SiteBin corrective migration: PL/pgSQL built-in expressions.
-- PostgreSQL exposes TRIM/COALESCE/NULLIF as SQL expressions, not callable
-- functions under pg_catalog. Keep pg_catalog qualification only for actual
-- callable built-ins when search_path is intentionally empty.

CREATE OR REPLACE FUNCTION public.init_user_account(p_install_id TEXT, p_handle TEXT DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
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
    END IF;

    RETURN pg_catalog.row_to_json(v_profile);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_campaign(
    p_url TEXT,
    p_normalized_url TEXT,
    p_domain TEXT,
    p_duration_seconds INT,
    p_target_views INT
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid UUID := (select auth.uid());
    v_price RECORD;
    v_total_cost BIGINT;
    v_profile RECORD;
    v_new_campaign RECORD;
    v_clean_url TEXT;
    v_clean_normalized TEXT;
    v_clean_domain TEXT;
    v_authority TEXT;
    v_host TEXT;
    v_port_text TEXT;
    v_ip INET;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    v_clean_url := trim(p_url);
    v_clean_normalized := trim(p_normalized_url);

    IF v_clean_url IS NULL OR length(v_clean_url) = 0
       OR length(v_clean_url) > 2048
       OR v_clean_url !~* '^https://'
       OR v_clean_url ~ '[[:space:]]'
       OR position('@' in v_clean_url) > 0
       OR position('[' in v_clean_url) > 0
       OR position(']' in v_clean_url) > 0 THEN
        RAISE EXCEPTION 'INVALID_URL: Target URL must be an HTTPS address without userinfo, IPv6 literals, or whitespace, up to 2048 characters';
    END IF;

    v_authority := substring(v_clean_url FROM '^https://([^/?#]+)');
    IF v_authority IS NULL OR length(v_authority) = 0 THEN
        RAISE EXCEPTION 'INVALID_URL: Target URL host is missing';
    END IF;

    IF (length(v_authority) - length(replace(v_authority, ':', ''))) > 1 THEN
        RAISE EXCEPTION 'INVALID_URL: Target URL contains an invalid host or port';
    END IF;

    IF position(':' in v_authority) > 0 THEN
        v_host := split_part(v_authority, ':', 1);
        v_port_text := split_part(v_authority, ':', 2);
        IF v_port_text !~ '^[0-9]{1,5}$' OR (v_port_text)::integer NOT BETWEEN 1 AND 65535 THEN
            RAISE EXCEPTION 'INVALID_URL: Target URL contains an invalid port';
        END IF;
    ELSE
        v_host := v_authority;
    END IF;

    v_host := lower(trim(v_host));
    IF v_host IS NULL OR length(v_host) = 0 OR length(v_host) > 253
       OR v_host !~ '^[a-z0-9.-]+$'
       OR v_host LIKE '%.localhost'
       OR v_host LIKE '%.local'
       OR v_host LIKE '%.internal'
       OR v_host IN ('localhost', 'localhost.localdomain', 'metadata.google.internal', 'metadata.google.com') THEN
        RAISE EXCEPTION 'INVALID_URL: Target host is not an allowed public hostname';
    END IF;

    IF v_host ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' THEN
        IF EXISTS (
            SELECT 1
            FROM unnest(string_to_array(v_host, '.')) AS octet(value)
            WHERE octet.value::integer NOT BETWEEN 0 AND 255
        ) THEN
            RAISE EXCEPTION 'INVALID_URL: Target IPv4 address is invalid';
        END IF;

        v_ip := v_host::inet;
        IF v_ip <<= inet '0.0.0.0/8'
           OR v_ip <<= inet '10.0.0.0/8'
           OR v_ip <<= inet '100.64.0.0/10'
           OR v_ip <<= inet '127.0.0.0/8'
           OR v_ip <<= inet '169.254.0.0/16'
           OR v_ip <<= inet '172.16.0.0/12'
           OR v_ip <<= inet '192.0.0.0/24'
           OR v_ip <<= inet '192.168.0.0/16'
           OR v_ip <<= inet '198.18.0.0/15'
           OR v_ip <<= inet '198.51.100.0/24'
           OR v_ip <<= inet '203.0.113.0/24'
           OR v_ip <<= inet '224.0.0.0/4'
           OR v_ip = inet '255.255.255.255' THEN
            RAISE EXCEPTION 'INVALID_URL: Target IPv4 address is private, reserved, multicast, or otherwise non-public';
        END IF;
    END IF;

    v_clean_domain := v_host;

    IF v_clean_normalized IS NULL OR length(v_clean_normalized) = 0 OR length(v_clean_normalized) > 2048 THEN
        RAISE EXCEPTION 'INVALID_NORMALIZED_URL: Normalized URL cannot be empty';
    END IF;

    IF p_target_views <= 0 OR p_target_views > 1000000 THEN
        RAISE EXCEPTION 'INVALID_TARGET_VIEWS: Target views must be between 1 and 1,000,000';
    END IF;

    SELECT * INTO v_price
    FROM public.duration_pricing
    WHERE duration_seconds = p_duration_seconds;

    IF v_price IS NULL THEN
        RAISE EXCEPTION 'INVALID_DURATION: Unsupported duration option';
    END IF;

    v_total_cost := v_price.advertiser_cost * p_target_views;

    SELECT * INTO v_profile
    FROM public.profiles
    WHERE id = v_uid
    FOR UPDATE;

    IF v_profile IS NULL THEN
        RAISE EXCEPTION 'PROFILE_NOT_FOUND: User profile does not exist';
    END IF;

    IF v_profile.available_coins < v_total_cost THEN
        RAISE EXCEPTION 'INSUFFICIENT_BALANCE: Available balance (%) coins is less than required budget (%) coins',
            v_profile.available_coins, v_total_cost;
    END IF;

    UPDATE public.profiles
    SET available_coins = available_coins - v_total_cost,
        reserved_coins = reserved_coins + v_total_cost,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_uid;

    INSERT INTO public.campaigns(
        owner_id,url,normalized_url,domain,duration_seconds,target_views,
        completed_views,cost_per_view,total_budget,spent_budget,reserved_budget,status,
        created_at,updated_at
    )
    VALUES(
        v_uid,v_clean_url,v_clean_normalized,v_clean_domain,p_duration_seconds,p_target_views,
        0,v_price.advertiser_cost,v_total_cost,0,v_total_cost,'ACTIVE',
        pg_catalog.clock_timestamp(),pg_catalog.clock_timestamp()
    )
    RETURNING * INTO v_new_campaign;

    INSERT INTO public.coin_ledger(
        user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
    )
    VALUES(
        v_uid,-v_total_cost,'CAMPAIGN_RESERVATION',
        'رزرو بودجه برای سفارش ' || p_target_views || ' بازدید از ' || v_clean_domain,
        v_new_campaign.id::text,'camp_res_' || v_new_campaign.id::text,pg_catalog.clock_timestamp()
    );

    RETURN pg_catalog.row_to_json(v_new_campaign);
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_view_session(p_session_id UUID, p_idempotency_key TEXT)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid UUID := (select auth.uid());
    v_clean_key TEXT;
    v_existing_by_key RECORD;
    v_session RECORD;
    v_campaign RECORD;
    v_owner RECORD;
    v_viewer RECORD;
    v_first_lock UUID;
    v_second_lock UUID;
    v_dummy_profile RECORD;
    v_elapsed_seconds NUMERIC;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ARGUMENT: Session ID cannot be null';
    END IF;

    v_clean_key := trim(p_idempotency_key);
    IF v_clean_key IS NULL OR length(v_clean_key) = 0 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Idempotency key cannot be empty';
    END IF;

    IF length(v_clean_key) > 128 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Idempotency key exceeds maximum length of 128 characters';
    END IF;

    SELECT * INTO v_existing_by_key
    FROM public.view_sessions
    WHERE idempotency_key = v_clean_key;

    IF v_existing_by_key IS NOT NULL THEN
        IF v_existing_by_key.viewer_id <> v_uid THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT: Key has already been used by another user';
        END IF;
        IF v_existing_by_key.id <> p_session_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT: Key has already been associated with a different session';
        END IF;
        IF v_existing_by_key.status = 'COMPLETED' THEN
            RETURN pg_catalog.json_build_object(
                'success', TRUE,
                'reward', v_existing_by_key.reward_coins,
                'already_completed', TRUE
            );
        END IF;
    END IF;

    SELECT * INTO v_session
    FROM public.view_sessions
    WHERE id = p_session_id
    FOR UPDATE;

    IF v_session IS NULL THEN
        RAISE EXCEPTION 'SESSION_NOT_FOUND: View session does not exist';
    END IF;

    IF v_session.viewer_id <> v_uid THEN
        RAISE EXCEPTION 'FORBIDDEN: Session does not belong to the caller';
    END IF;

    IF v_session.status = 'COMPLETED' THEN
        RETURN pg_catalog.json_build_object(
            'success', TRUE,
            'reward', v_session.reward_coins,
            'already_completed', TRUE
        );
    END IF;

    IF v_session.status <> 'CONTENT_READY' THEN
        RAISE EXCEPTION 'INVALID_SESSION_STATUS: Session is % but must be CONTENT_READY to complete', v_session.status;
    END IF;

    IF v_session.content_ready_at IS NULL THEN
        RAISE EXCEPTION 'INVALID_SESSION_STATE: Content ready signal was never received';
    END IF;

    v_elapsed_seconds := extract(epoch from (pg_catalog.clock_timestamp() - v_session.content_ready_at));

    IF v_elapsed_seconds < (v_session.required_duration_seconds - 1.0) THEN
        RAISE EXCEPTION 'PREMATURE_COMPLETION: Elapsed time (%) is less than required duration (%)',
            v_elapsed_seconds, v_session.required_duration_seconds;
    END IF;

    SELECT * INTO v_campaign
    FROM public.campaigns
    WHERE id = v_session.campaign_id
    FOR UPDATE;

    IF v_campaign IS NULL THEN
        RAISE EXCEPTION 'CAMPAIGN_NOT_FOUND: Associated campaign no longer exists';
    END IF;

    IF v_campaign.status NOT IN ('ACTIVE', 'PAUSED') THEN
        RAISE EXCEPTION 'CAMPAIGN_INACTIVE: Campaign is % but must be ACTIVE or PAUSED', v_campaign.status;
    END IF;

    IF v_campaign.completed_views >= v_campaign.target_views THEN
        RAISE EXCEPTION 'CAMPAIGN_EXHAUSTED: Campaign has already reached its target view count';
    END IF;

    IF v_campaign.reserved_budget < v_campaign.cost_per_view THEN
        RAISE EXCEPTION 'INSUFFICIENT_CAMPAIGN_BUDGET: Campaign reserved budget (%) is less than cost per view (%)',
            v_campaign.reserved_budget, v_campaign.cost_per_view;
    END IF;

    v_first_lock := CASE WHEN v_campaign.owner_id < v_uid THEN v_campaign.owner_id ELSE v_uid END;
    v_second_lock := CASE WHEN v_campaign.owner_id < v_uid THEN v_uid ELSE v_campaign.owner_id END;

    SELECT * INTO v_dummy_profile FROM public.profiles WHERE id = v_first_lock FOR UPDATE;
    IF v_first_lock <> v_second_lock THEN
        SELECT * INTO v_dummy_profile FROM public.profiles WHERE id = v_second_lock FOR UPDATE;
    END IF;

    SELECT * INTO v_owner FROM public.profiles WHERE id = v_campaign.owner_id;
    SELECT * INTO v_viewer FROM public.profiles WHERE id = v_uid;

    IF v_owner.reserved_coins < v_campaign.cost_per_view THEN
        RAISE EXCEPTION 'INSUFFICIENT_RESERVED_BALANCE: Campaign owner reserved balance (%) is less than cost per view (%)',
            v_owner.reserved_coins, v_campaign.cost_per_view;
    END IF;

    UPDATE public.campaigns
    SET completed_views = completed_views + 1,
        spent_budget = spent_budget + cost_per_view,
        reserved_budget = reserved_budget - cost_per_view,
        status = CASE WHEN completed_views + 1 >= target_views THEN 'COMPLETED' ELSE status END,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_campaign.id;

    UPDATE public.profiles
    SET reserved_coins = reserved_coins - v_campaign.cost_per_view,
        lifetime_spent = lifetime_spent + v_campaign.cost_per_view,
        received_views_count = received_views_count + 1,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_campaign.owner_id;

    UPDATE public.profiles
    SET available_coins = available_coins + v_session.reward_coins,
        lifetime_earned = lifetime_earned + v_session.reward_coins,
        completed_views_count = completed_views_count + 1,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_uid;

    UPDATE public.view_sessions
    SET status = 'COMPLETED',
        completed_at = pg_catalog.clock_timestamp(),
        idempotency_key = v_clean_key
    WHERE id = v_session.id;

    INSERT INTO public.coin_ledger(
        user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
    )
    VALUES(
        v_uid,v_session.reward_coins,'VIEW_REWARD',
        'مشاهده موفق ' || v_session.required_duration_seconds || ' ثانیه‌ای از ' || v_campaign.domain,
        v_campaign.id::text,v_clean_key,pg_catalog.clock_timestamp()
    );

    INSERT INTO public.coin_ledger(
        user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
    )
    VALUES(
        v_campaign.owner_id,-v_campaign.cost_per_view,'CAMPAIGN_SPEND',
        'مصرف بودجه بازدید از ' || v_campaign.domain,
        v_campaign.id::text,'spend_' || v_session.id::text,pg_catalog.clock_timestamp()
    );

    RETURN pg_catalog.json_build_object(
        'success', TRUE,
        'reward', v_session.reward_coins,
        'already_completed', FALSE
    );
END;
$$;

REVOKE ALL ON FUNCTION public.init_user_account(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.init_user_account(TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.create_campaign(TEXT, TEXT, TEXT, INT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_campaign(TEXT, TEXT, TEXT, INT, INT) TO authenticated;

REVOKE ALL ON FUNCTION public.complete_view_session(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_view_session(UUID, TEXT) TO authenticated;
