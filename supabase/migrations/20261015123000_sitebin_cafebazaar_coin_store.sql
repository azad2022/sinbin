-- SiteBin Cafe Bazaar one-time consumable coin store.
-- Only the verified Edge Function may finalize a purchase. Never expose purchase credits
-- to authenticated clients as a direct RPC.

CREATE TABLE IF NOT EXISTS private.coin_store_catalog (
    product_id TEXT PRIMARY KEY,
    coin_amount BIGINT NOT NULL CHECK (coin_amount > 0),
    price_rial BIGINT NOT NULL CHECK (price_rial > 0),
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp(),
    CONSTRAINT coin_store_catalog_product_id_check
      CHECK (product_id IN ('coins_5000', 'coins_10000', 'coins_20000', 'coins_50000'))
);

INSERT INTO private.coin_store_catalog (product_id, coin_amount, price_rial, enabled, updated_at)
VALUES
    ('coins_5000', 5000, 2990000, TRUE, pg_catalog.clock_timestamp()),
    ('coins_10000', 10000, 3490000, TRUE, pg_catalog.clock_timestamp()),
    ('coins_20000', 20000, 4890000, TRUE, pg_catalog.clock_timestamp()),
    ('coins_50000', 50000, 6490000, TRUE, pg_catalog.clock_timestamp())
ON CONFLICT (product_id) DO UPDATE
SET coin_amount = EXCLUDED.coin_amount,
    price_rial = EXCLUDED.price_rial,
    enabled = EXCLUDED.enabled,
    updated_at = pg_catalog.clock_timestamp();

ALTER TABLE private.coin_store_catalog ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.coin_store_catalog FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS private.coin_purchase_intents (
    id UUID PRIMARY KEY,
    payload TEXT NOT NULL UNIQUE,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL REFERENCES private.coin_store_catalog(product_id),
    coin_amount BIGINT NOT NULL CHECK (coin_amount > 0),
    price_rial BIGINT NOT NULL CHECK (price_rial > 0),
    status TEXT NOT NULL DEFAULT 'PENDING'
      CHECK (status IN ('PENDING', 'CREDITED', 'EXPIRED')),
    expires_at TIMESTAMPTZ NOT NULL,
    credited_purchase_token TEXT,
    credited_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

CREATE INDEX IF NOT EXISTS idx_coin_purchase_intents_user_recent
    ON private.coin_purchase_intents (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_coin_purchase_intents_pending_expiry
    ON private.coin_purchase_intents (status, expires_at)
    WHERE status = 'PENDING';

ALTER TABLE private.coin_purchase_intents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.coin_purchase_intents FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS private.coin_purchases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    intent_id UUID NOT NULL UNIQUE REFERENCES private.coin_purchase_intents(id) ON DELETE RESTRICT,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL REFERENCES private.coin_store_catalog(product_id),
    coin_amount BIGINT NOT NULL CHECK (coin_amount > 0),
    price_rial BIGINT NOT NULL CHECK (price_rial > 0),
    purchase_token TEXT NOT NULL UNIQUE,
    store_order_id TEXT NOT NULL UNIQUE,
    payload TEXT NOT NULL UNIQUE,
    package_name TEXT NOT NULL CHECK (package_name = 'sitebin.azerakhsh.ir'),
    purchase_time TIMESTAMPTZ NOT NULL,
    receipt_sha256 TEXT NOT NULL CHECK (receipt_sha256 ~ '^[0-9a-f]{64}$'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

CREATE INDEX IF NOT EXISTS idx_coin_purchases_user_recent
    ON private.coin_purchases (user_id, created_at DESC);

ALTER TABLE private.coin_purchases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.coin_purchases FROM PUBLIC, anon, authenticated;

ALTER TABLE public.coin_ledger
    DROP CONSTRAINT IF EXISTS coin_ledger_transaction_type_check;
ALTER TABLE public.coin_ledger
    ADD CONSTRAINT coin_ledger_transaction_type_check CHECK (
      transaction_type IN (
        'WELCOME_REWARD',
        'VIEW_REWARD',
        'CAMPAIGN_RESERVATION',
        'CAMPAIGN_SPEND',
        'CAMPAIGN_REFUND',
        'REFERRAL_REWARD',
        'PLATFORM_GRANT',
        'DAILY_BONUS',
        'AUTO_VIEW_SUBSCRIPTION',
        'COIN_TRANSFER_SENT',
        'COIN_TRANSFER_RECEIVED',
        'COIN_PURCHASE'
      )
    );

CREATE OR REPLACE FUNCTION public.create_coin_purchase_intent(p_product_id TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_uid UUID := auth.uid();
    v_product private.coin_store_catalog%ROWTYPE;
    v_profile public.profiles%ROWTYPE;
    v_intent_id UUID := gen_random_uuid();
    v_now TIMESTAMPTZ := pg_catalog.clock_timestamp();
    v_recent_count INTEGER;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;
    IF COALESCE((auth.jwt()->>'is_anonymous')::BOOLEAN, FALSE) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;
    IF p_product_id IS NULL OR pg_catalog.length(p_product_id) > 64 THEN
        RAISE EXCEPTION 'INVALID_PRODUCT: Unknown coin package';
    END IF;

    SELECT * INTO v_product
    FROM private.coin_store_catalog
    WHERE product_id = p_product_id AND enabled = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_PRODUCT: Unknown or disabled coin package';
    END IF;

    SELECT * INTO v_profile
    FROM public.profiles
    WHERE id = v_uid
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PROFILE_NOT_FOUND: Account must be initialized before purchase';
    END IF;

    SELECT pg_catalog.count(*)::INTEGER INTO v_recent_count
    FROM private.coin_purchase_intents
    WHERE user_id = v_uid
      AND created_at >= v_now - INTERVAL '10 minutes';
    IF v_recent_count >= 6 THEN
        RAISE EXCEPTION 'PURCHASE_RATE_LIMITED: Too many purchase attempts; try again later';
    END IF;

    INSERT INTO private.coin_purchase_intents (
        id, payload, user_id, product_id, coin_amount, price_rial, status, expires_at, created_at
    )
    VALUES (
        v_intent_id,
        v_intent_id::TEXT,
        v_uid,
        v_product.product_id,
        v_product.coin_amount,
        v_product.price_rial,
        'PENDING',
        v_now + INTERVAL '2 hours',
        v_now
    );

    RETURN pg_catalog.json_build_object(
        'payload', v_intent_id::TEXT,
        'product_id', v_product.product_id,
        'coin_amount', v_product.coin_amount,
        'price_rial', v_product.price_rial,
        'expires_at_ms', (EXTRACT(EPOCH FROM (v_now + INTERVAL '2 hours')) * 1000)::BIGINT
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.create_coin_purchase_intent(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_coin_purchase_intent(TEXT) TO authenticated;

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
    IF v_intent.status <> 'PENDING' THEN
        RAISE EXCEPTION 'PURCHASE_NOT_PENDING: Order was already finalized or expired';
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

    SELECT * INTO v_profile
    FROM public.profiles
    WHERE id = p_user_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PROFILE_NOT_FOUND: Purchase account no longer exists';
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

-- This finalization RPC accepts no client JWT authority and is restricted to service_role.
REVOKE ALL ON FUNCTION public.finalize_coin_purchase_from_verified_receipt(
    UUID, TEXT, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_coin_purchase_from_verified_receipt(
    UUID, TEXT, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT
) TO service_role;
