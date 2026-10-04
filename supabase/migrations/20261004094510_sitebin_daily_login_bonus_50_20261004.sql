-- SiteBin: daily authenticated login bonus.
-- New accounts receive the 300-coin welcome reward on their welcome day.
-- Starting after the welcome day, each UTC server day can grant exactly 50 coins once.
-- Existing production databases already contain this migration; this file restores
-- migration parity for fresh environments.

BEGIN;

CREATE TABLE IF NOT EXISTS public.daily_bonus_grants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  grant_date DATE NOT NULL,
  amount BIGINT NOT NULL DEFAULT 50 CHECK (amount = 50),
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT daily_bonus_grants_user_date_key UNIQUE (user_id, grant_date)
);

ALTER TABLE public.daily_bonus_grants ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_daily_bonus_grants_user_date_desc
  ON public.daily_bonus_grants(user_id, grant_date DESC);

CREATE OR REPLACE FUNCTION public.claim_daily_bonus()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid UUID := (SELECT auth.uid());
  v_today DATE := (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date;
  v_welcome_date DATE;
  v_profile RECORD;
  v_grant RECORD;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
  END IF;

  IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
  END IF;

  SELECT * INTO v_profile
  FROM public.profiles
  WHERE id = v_uid
  FOR UPDATE;

  IF v_profile IS NULL THEN
    RAISE EXCEPTION 'PROFILE_NOT_FOUND: Account must be initialized before receiving daily bonus';
  END IF;

  -- The 300-coin welcome day is intentionally excluded from the daily 50-coin bonus.
  SELECT (MIN(granted_at) AT TIME ZONE 'UTC')::date
  INTO v_welcome_date
  FROM public.welcome_bonus_grants
  WHERE user_id = v_uid;

  IF v_welcome_date = v_today THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'WELCOME_DAY'
    );
  END IF;

  INSERT INTO public.daily_bonus_grants(user_id, grant_date, amount, granted_at)
  VALUES(v_uid, v_today, 50, pg_catalog.clock_timestamp())
  ON CONFLICT (user_id, grant_date) DO NOTHING
  RETURNING id, amount, granted_at INTO v_grant;

  IF v_grant.id IS NULL THEN
    RETURN pg_catalog.json_build_object(
      'granted', false,
      'amount', 0,
      'grant_date', v_today,
      'reason', 'ALREADY_CLAIMED'
    );
  END IF;

  UPDATE public.profiles
  SET available_coins = available_coins + v_grant.amount,
      lifetime_earned = lifetime_earned + v_grant.amount,
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = v_uid;

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
    v_grant.amount,
    'DAILY_BONUS',
    'هدیه روزانه سایت بین',
    v_grant.id::text,
    'daily_bonus_' || v_uid::text || '_' || v_today::text,
    v_grant.granted_at
  );

  RETURN pg_catalog.json_build_object(
    'granted', true,
    'amount', v_grant.amount,
    'grant_date', v_today,
    'grant_id', v_grant.id,
    'granted_at', extract(epoch from v_grant.granted_at) * 1000
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_daily_bonus() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_daily_bonus() TO authenticated;

REVOKE ALL ON TABLE public.daily_bonus_grants FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.daily_bonus_grants TO service_role;

COMMIT;
