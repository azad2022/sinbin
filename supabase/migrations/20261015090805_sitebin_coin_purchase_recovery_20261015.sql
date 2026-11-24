-- Reconcile real purchases that completed in the valid order window but were verified late.
-- Unique receipt/order constraints and the signed purchase-time window remain enforced.

CREATE OR REPLACE FUNCTION public.finalize_coin_purchase_from_verified_receipt(
    p_user_id UUID,
    p_payload TEXT,
    p_product_id TEXT,
    p_purchase_token TEXT,
    p_store_order_id TEXT,
    p_purchase_time_ms BIGINT,
    p_package_name TEXT,
    p_receipt_sha256 TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_intent private.coin_purchase_intents%ROWTYPE;
    v_existing private.coin_purchases%ROWTYPE;
    v_product private.coin_store_catalog%ROWTYPE;
    v_profile public.profiles%ROWTYPE;
    v_purchase_id UUID;
    v_purchase_time TIMESTAMPTZ;
BEGIN
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Verified account is required';
    END IF;
    IF p_package_name IS DISTINCT FROM 'sitebin.azerakhsh.ir' THEN
        RAISE EXCEPTION 'PACKAGE_MISMATCH: Invalid application package';
    END IF;
    IF p_product_id IS NULL OR p_product_id NOT IN (
        'coins_5000', 'coins_10000', 'coins_20000', 'coins_50000'
    ) THEN
        RAISE EXCEPTION 'INVALID_PRODUCT: Unknown coin package';
    END IF;
    IF p_payload IS NULL OR p_payload !~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' THEN
        RAISE EXCEPTION 'INVALID_ORDER_PAYLOAD: Invalid order payload';
    END IF;
    IF p_purchase_token IS NULL OR pg_catalog.length(pg_catalog.btrim(p_purchase_token)) = 0
       OR pg_catalog.length(p_purchase_token) > 2048
       OR p_store_order_id IS NULL OR pg_catalog.length(pg_catalog.btrim(p_store_order_id)) = 0
       OR pg_catalog.length(p_store_order_id) > 512 THEN
        RAISE EXCEPTION 'INVALID_RECEIPT: Invalid purchase token or order ID';
    END IF;
    IF p_purchase_time_ms IS NULL OR p_purchase_time_ms <= 0 THEN
        RAISE EXCEPTION 'INVALID_RECEIPT: Invalid purchase time';
    END IF;
    IF p_receipt_sha256 IS NULL OR p_receipt_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'INVALID_RECEIPT: Invalid receipt digest';
    END IF;

    -- Lock the profile before purchase-intent/receipt rows. This lock order matches the
    -- account-rebind path and avoids profile<->intent deadlocks during reinstalls.
    SELECT * INTO v_profile
    FROM public.profiles
    WHERE id = p_user_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PROFILE_NOT_FOUND: Purchase account no longer exists';
    END IF;

    -- Serialize concurrent verification attempts. The same signed receipt can credit at most once.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended('sitebin-coin-token:' || p_purchase_token, 0)
    );
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended('sitebin-coin-order:' || p_store_order_id, 0)
    );

    SELECT * INTO v_existing
    FROM private.coin_purchases
    WHERE purchase_token = p_purchase_token
    FOR UPDATE;
    IF FOUND THEN
        IF v_existing.user_id <> p_user_id
           OR v_existing.product_id <> p_product_id
           OR v_existing.store_order_id <> p_store_order_id
           OR v_existing.payload <> p_payload THEN
            RAISE EXCEPTION 'PURCHASE_TOKEN_REPLAY: Receipt was already used';
        END IF;
        SELECT * INTO v_profile FROM public.profiles WHERE id = p_user_id;
        RETURN pg_catalog.json_build_object(
            'success', TRUE,
            'already_processed', TRUE,
            'product_id', v_existing.product_id,
            'coins', v_existing.coin_amount,
            'available_coins', COALESCE(v_profile.available_coins, 0),
            'purchase_id', v_existing.id
        );
    END IF;

    SELECT * INTO v_existing
    FROM private.coin_purchases
    WHERE store_order_id = p_store_order_id
    FOR UPDATE;
    IF FOUND THEN
        RAISE EXCEPTION 'STORE_ORDER_REPLAY: Store order ID was already used';
    END IF;

    SELECT * INTO v_intent
    FROM private.coin_purchase_intents
    WHERE payload = pg_catalog.btrim(p_payload)
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PURCHASE_INTENT_NOT_FOUND: Order intent was not found';
    END IF;
    IF v_intent.user_id <> p_user_id THEN
        RAISE EXCEPTION 'PURCHASE_ACCOUNT_MISMATCH: Order belongs to another account';
    END IF;
    IF v_intent.product_id <> p_product_id THEN
        RAISE EXCEPTION 'PURCHASE_PRODUCT_MISMATCH: Receipt product does not match order';
    END IF;
    -- EXPIRED describes a stale pending intent, not an invalid historical purchase.
    -- The signed Bazaar purchase timestamp is separately bounded by expires_at + 15 minutes below.
    -- This lets the app safely recover a completed, unconsumed purchase after a network outage.
    IF v_intent.status NOT IN ('PENDING', 'EXPIRED') THEN
        RAISE EXCEPTION 'PURCHASE_NOT_PENDING: Order was already finalized';
    END IF;

    SELECT * INTO v_product
    FROM private.coin_store_catalog
    WHERE product_id = p_product_id AND enabled = TRUE;
    IF NOT FOUND
       OR v_product.coin_amount <> v_intent.coin_amount
       OR v_product.price_rial <> v_intent.price_rial THEN
        RAISE EXCEPTION 'PURCHASE_PRODUCT_MISMATCH: Server catalog does not match order';
    END IF;

    v_purchase_time := pg_catalog.to_timestamp(p_purchase_time_ms::DOUBLE PRECISION / 1000.0);
    IF v_purchase_time < v_intent.created_at - INTERVAL '5 minutes'
       OR v_purchase_time > v_intent.expires_at + INTERVAL '15 minutes' THEN
        RAISE EXCEPTION 'PURCHASE_INTENT_EXPIRED: Receipt time is outside the order validity window';
    END IF;

    INSERT INTO private.coin_purchases (
        intent_id, user_id, product_id, coin_amount, price_rial,
        purchase_token, store_order_id, payload, package_name, purchase_time, receipt_sha256
    )
    VALUES (
        v_intent.id, p_user_id, v_product.product_id, v_product.coin_amount, v_product.price_rial,
        p_purchase_token, p_store_order_id, v_intent.payload, p_package_name, v_purchase_time, p_receipt_sha256
    )
    RETURNING id INTO v_purchase_id;

    UPDATE public.profiles
    SET available_coins = available_coins + v_product.coin_amount,
        lifetime_earned = lifetime_earned + v_product.coin_amount,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = p_user_id
    RETURNING * INTO v_profile;

    INSERT INTO public.coin_ledger (
        user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
    )
    VALUES (
        p_user_id,
        v_product.coin_amount,
        'COIN_PURCHASE',
        'خرید ' || v_product.coin_amount::TEXT || ' سکه از کافه‌بازار',
        v_purchase_id::TEXT,
        'coin_purchase_' || v_purchase_id::TEXT,
        v_purchase_time
    );

    UPDATE private.coin_purchase_intents
    SET status = 'CREDITED',
        credited_purchase_token = p_purchase_token,
        credited_at = pg_catalog.clock_timestamp()
    WHERE id = v_intent.id;

    RETURN pg_catalog.json_build_object(
        'success', TRUE,
        'already_processed', FALSE,
        'product_id', v_product.product_id,
        'coins', v_product.coin_amount,
        'available_coins', v_profile.available_coins,
        'purchase_id', v_purchase_id
    );
END;
$function$;
