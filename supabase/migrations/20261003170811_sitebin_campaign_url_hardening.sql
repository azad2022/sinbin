
-- SiteBin campaign URL hardening.
-- Server-side enforcement: campaign destinations must be HTTPS public hostnames.
-- The server derives the stored domain from the URL and rejects private/reserved IPv4 literals.

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

    v_clean_url := pg_catalog.trim(p_url);
    v_clean_normalized := pg_catalog.trim(p_normalized_url);

    IF v_clean_url IS NULL OR pg_catalog.length(v_clean_url) = 0
       OR pg_catalog.length(v_clean_url) > 2048
       OR v_clean_url !~* '^https://'
       OR v_clean_url ~ '[[:space:]]'
       OR position('@' in v_clean_url) > 0
       OR position('[' in v_clean_url) > 0
       OR position(']' in v_clean_url) > 0 THEN
        RAISE EXCEPTION 'INVALID_URL: Target URL must be an HTTPS address without userinfo, IPv6 literals, or whitespace, up to 2048 characters';
    END IF;

    v_authority := substring(v_clean_url FROM '^https://([^/?#]+)');
    IF v_authority IS NULL OR pg_catalog.length(v_authority) = 0 THEN
        RAISE EXCEPTION 'INVALID_URL: Target URL host is missing';
    END IF;

    IF (pg_catalog.length(v_authority) - pg_catalog.length(pg_catalog.replace(v_authority, ':', ''))) > 1 THEN
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
    IF v_host IS NULL OR pg_catalog.length(v_host) = 0 OR pg_catalog.length(v_host) > 253
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

    IF v_clean_normalized IS NULL OR pg_catalog.length(v_clean_normalized) = 0 OR pg_catalog.length(v_clean_normalized) > 2048 THEN
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

    INSERT INTO public.campaigns (
        owner_id, url, normalized_url, domain, duration_seconds, target_views,
        completed_views, cost_per_view, total_budget, spent_budget, reserved_budget, status,
        created_at, updated_at
    ) VALUES (
        v_uid, v_clean_url, v_clean_normalized, v_clean_domain, p_duration_seconds, p_target_views,
        0, v_price.advertiser_cost, v_total_cost, 0, v_total_cost, 'ACTIVE',
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    RETURNING * INTO v_new_campaign;

    INSERT INTO public.coin_ledger (
        user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
    ) VALUES (
        v_uid, -v_total_cost, 'CAMPAIGN_RESERVATION',
        'رزرو بودجه برای سفارش ' || p_target_views || ' بازدید از ' || v_clean_domain,
        v_new_campaign.id::text, 'camp_res_' || v_new_campaign.id::text, pg_catalog.clock_timestamp()
    );

    RETURN pg_catalog.row_to_json(v_new_campaign);
END;
$$;

REVOKE ALL ON FUNCTION public.create_campaign(TEXT, TEXT, TEXT, INT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_campaign(TEXT, TEXT, TEXT, INT, INT) TO authenticated;
