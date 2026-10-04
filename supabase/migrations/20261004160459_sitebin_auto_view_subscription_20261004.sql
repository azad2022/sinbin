-- SiteBin: seven-day automatic viewing subscription.
-- Activation is fully server-authoritative: 100 coins are deducted atomically
-- and the entitlement remains active for seven days.
--
-- Repository parity file for the production migration:
-- 20261004160459_sitebin_auto_view_subscription_20261004

BEGIN;

ALTER TABLE public.coin_ledger
  DROP CONSTRAINT IF EXISTS coin_ledger_transaction_type_check;

ALTER TABLE public.coin_ledger
  ADD CONSTRAINT coin_ledger_transaction_type_check
  CHECK (
    transaction_type = ANY (
      ARRAY[
        'WELCOME_REWARD'::text,
        'VIEW_REWARD'::text,
        'CAMPAIGN_RESERVATION'::text,
        'CAMPAIGN_SPEND'::text,
        'CAMPAIGN_REFUND'::text,
        'REFERRAL_REWARD'::text,
        'PLATFORM_GRANT'::text,
        'COIN_TRANSFER_SENT'::text,
        'COIN_TRANSFER_RECEIVED'::text,
        'DAILY_BONUS'::text,
        'AUTO_VIEW_SUBSCRIPTION'::text
      ]
    )
  );

CREATE TABLE IF NOT EXISTS public.auto_view_entitlements (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.auto_view_purchases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  amount BIGINT NOT NULL DEFAULT 100 CHECK (amount = 100),
  idempotency_key TEXT NOT NULL UNIQUE,
  activated_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.auto_view_entitlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auto_view_purchases ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.auto_view_entitlements FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.auto_view_purchases FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.auto_view_entitlements TO service_role;
GRANT SELECT ON TABLE public.auto_view_purchases TO service_role;

CREATE INDEX IF NOT EXISTS idx_auto_view_purchases_user_created
  ON public.auto_view_purchases(user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.get_auto_view_status()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid UUID := (SELECT auth.uid());
  v_expires_at TIMESTAMPTZ;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
  END IF;

  IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
  END IF;

  SELECT expires_at
  INTO v_expires_at
  FROM public.auto_view_entitlements
  WHERE user_id = v_uid;

  RETURN pg_catalog.json_build_object(
    'active', COALESCE(v_expires_at > pg_catalog.clock_timestamp(), false),
    'expires_at', CASE
      WHEN v_expires_at IS NULL THEN NULL
      ELSE extract(epoch FROM v_expires_at) * 1000
    END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_auto_view_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_auto_view_status() TO authenticated;

CREATE OR REPLACE FUNCTION public.activate_auto_view(p_idempotency_key TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid UUID := (SELECT auth.uid());
  v_key TEXT := pg_catalog.btrim(p_idempotency_key);
  v_profile RECORD;
  v_existing RECORD;
  v_entitlement RECORD;
  v_now TIMESTAMPTZ := pg_catalog.clock_timestamp();
  v_activated_at TIMESTAMPTZ;
  v_expires_at TIMESTAMPTZ;
  v_purchase RECORD;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
  END IF;

  IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
  END IF;

  IF v_key IS NULL OR pg_catalog.length(v_key) < 16 OR pg_catalog.length(v_key) > 128
     OR v_key ~ '[[:space:]]' THEN
    RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Invalid auto-view activation request key';
  END IF;

  SELECT *
  INTO v_profile
  FROM public.profiles
  WHERE id = v_uid
  FOR UPDATE;

  IF v_profile IS NULL THEN
    RAISE EXCEPTION 'PROFILE_NOT_FOUND: Account must be initialized before enabling auto-view';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.auto_view_purchases
  WHERE idempotency_key = v_key;

  IF v_existing IS NOT NULL THEN
    IF v_existing.user_id <> v_uid THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: Activation request key belongs to another account';
    END IF;

    RETURN pg_catalog.json_build_object(
      'success', TRUE,
      'activated', TRUE,
      'charged', TRUE,
      'amount', v_existing.amount,
      'expires_at', extract(epoch FROM v_existing.expires_at) * 1000,
      'available_coins', v_profile.available_coins,
      'purchase_id', v_existing.id
    );
  END IF;

  SELECT *
  INTO v_entitlement
  FROM public.auto_view_entitlements
  WHERE user_id = v_uid
  FOR UPDATE;

  IF v_entitlement IS NOT NULL
     AND v_entitlement.expires_at > v_now THEN
    RETURN pg_catalog.json_build_object(
      'success', TRUE,
      'activated', TRUE,
      'charged', FALSE,
      'amount', 0,
      'expires_at', extract(epoch FROM v_entitlement.expires_at) * 1000,
      'available_coins', v_profile.available_coins
    );
  END IF;

  IF v_profile.available_coins < 100 THEN
    RAISE EXCEPTION 'INSUFFICIENT_BALANCE: Available balance (%) coins is less than 100 coins', v_profile.available_coins;
  END IF;

  v_activated_at := v_now;
  v_expires_at := v_now + INTERVAL '7 days';

  INSERT INTO public.auto_view_purchases(
    user_id, amount, idempotency_key, activated_at, expires_at, created_at
  )
  VALUES(
    v_uid, 100, v_key, v_activated_at, v_expires_at, v_now
  )
  RETURNING * INTO v_purchase;

  UPDATE public.profiles
  SET available_coins = available_coins - 100,
      lifetime_spent = lifetime_spent + 100,
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = v_uid
  RETURNING * INTO v_profile;

  INSERT INTO public.auto_view_entitlements(user_id, expires_at, updated_at)
  VALUES(v_uid, v_expires_at, pg_catalog.clock_timestamp())
  ON CONFLICT (user_id) DO UPDATE
  SET expires_at = EXCLUDED.expires_at,
      updated_at = EXCLUDED.updated_at;

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
    v_uid,
    -100,
    'AUTO_VIEW_SUBSCRIPTION',
    'فعال‌سازی بازدید خودکار برای ۷ روز',
    v_purchase.id::text,
    'auto_view_purchase_' || v_purchase.id::text,
    v_purchase.created_at
  );

  RETURN pg_catalog.json_build_object(
    'success', TRUE,
    'activated', TRUE,
    'charged', TRUE,
    'amount', 100,
    'expires_at', extract(epoch FROM v_expires_at) * 1000,
    'available_coins', v_profile.available_coins,
    'purchase_id', v_purchase.id
  );
EXCEPTION
  WHEN unique_violation THEN
    SELECT *
    INTO v_existing
    FROM public.auto_view_purchases
    WHERE idempotency_key = v_key;

    IF v_existing IS NULL THEN
      RAISE;
    END IF;

    IF v_existing.user_id <> v_uid THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: Activation request key belongs to another account';
    END IF;

    SELECT *
    INTO v_profile
    FROM public.profiles
    WHERE id = v_uid;

    RETURN pg_catalog.json_build_object(
      'success', TRUE,
      'activated', TRUE,
      'charged', TRUE,
      'amount', v_existing.amount,
      'expires_at', extract(epoch FROM v_existing.expires_at) * 1000,
      'available_coins', v_profile.available_coins,
      'purchase_id', v_existing.id
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.activate_auto_view(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.activate_auto_view(TEXT) TO authenticated;

COMMIT;
