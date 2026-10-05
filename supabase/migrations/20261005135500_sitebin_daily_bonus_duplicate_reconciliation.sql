-- Reconcile the confirmed same-device duplicate Daily Bonus created before
-- device-scoped enforcement. Keep both original grant and ledger history, but add
-- an auditable compensating ledger entry and restore the profile balance.

BEGIN;

CREATE TABLE IF NOT EXISTS private.daily_bonus_reversals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  daily_bonus_grant_id uuid NOT NULL
    REFERENCES public.daily_bonus_grants(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL
    REFERENCES auth.users(id) ON DELETE RESTRICT,
  amount bigint NOT NULL CHECK (amount > 0),
  reversal_reason text NOT NULL,
  reversal_ledger_id uuid
    REFERENCES public.coin_ledger(id) ON DELETE RESTRICT,
  reversed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT daily_bonus_reversals_grant_key UNIQUE (daily_bonus_grant_id)
);

REVOKE ALL ON private.daily_bonus_reversals
  FROM PUBLIC, anon, authenticated, service_role;
GRANT ALL ON private.daily_bonus_reversals TO postgres;

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
        'DAILY_BONUS_REVERSAL'::text,
        'AUTO_VIEW_SUBSCRIPTION'::text
      ]
    )
  );

DO $$
DECLARE
  v_device_id uuid := 'ef82b479-ea0d-4963-b8d5-d61cccd881a7';
  v_canonical_uid uuid := 'a7c5a7f8-c415-4eb6-84ab-de5d31949656';
  v_duplicate_uid uuid := '7942ec28-b0b1-4efa-978c-9b6d9c3a254d';
  v_duplicate_grant_id uuid := '75bc6b38-42ff-4e8a-b2ba-081f0c72922a';
  v_amount bigint;
  v_before_available bigint;
  v_before_earned bigint;
  v_ledger_id uuid;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM private.daily_bonus_reversals
    WHERE daily_bonus_grant_id = v_duplicate_grant_id
  ) THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM private.device_identities
    WHERE id = v_device_id
      AND first_auth_uid = v_canonical_uid
      AND current_auth_uid = v_duplicate_uid
  ) THEN
    RAISE EXCEPTION 'RECONCILIATION_ABORTED: device identity no longer matches the confirmed duplicate pair';
  END IF;

  SELECT d.amount
  INTO v_amount
  FROM public.daily_bonus_grants d
  WHERE d.id = v_duplicate_grant_id
    AND d.user_id = v_duplicate_uid
    AND d.grant_date = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date;

  IF v_amount IS NULL OR v_amount <> 50 THEN
    RAISE EXCEPTION 'RECONCILIATION_ABORTED: duplicate grant is not the confirmed 50-coin daily grant';
  END IF;

  IF (
    SELECT count(DISTINCT d.user_id)
    FROM public.daily_bonus_grants d
    WHERE d.user_id IN (v_canonical_uid, v_duplicate_uid)
      AND d.grant_date = (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date
  ) <> 2 THEN
    RAISE EXCEPTION 'RECONCILIATION_ABORTED: expected exactly two same-day grants for confirmed linked accounts';
  END IF;

  SELECT available_coins, lifetime_earned
  INTO v_before_available, v_before_earned
  FROM public.profiles
  WHERE id = v_duplicate_uid
  FOR UPDATE;

  IF v_before_available IS NULL
     OR v_before_earned IS NULL
     OR v_before_available < v_amount
     OR v_before_earned < v_amount THEN
    RAISE EXCEPTION 'RECONCILIATION_ABORTED: duplicate grant has already been consumed; manual financial review required';
  END IF;

  UPDATE public.profiles
  SET available_coins = available_coins - v_amount,
      lifetime_earned = lifetime_earned - v_amount,
      updated_at = clock_timestamp()
  WHERE id = v_duplicate_uid;

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
    v_duplicate_uid,
    -v_amount,
    'DAILY_BONUS_REVERSAL',
    'اصلاح پاداش روزانه تکراری ناشی از نصب مجدد',
    v_duplicate_grant_id::text,
    'daily_bonus_reversal_' || v_duplicate_grant_id::text,
    clock_timestamp()
  )
  RETURNING id INTO v_ledger_id;

  INSERT INTO private.daily_bonus_reversals(
    daily_bonus_grant_id,
    user_id,
    amount,
    reversal_reason,
    reversal_ledger_id
  )
  VALUES(
    v_duplicate_grant_id,
    v_duplicate_uid,
    v_amount,
    'Same device received Daily Bonus twice before device-scoped enforcement',
    v_ledger_id
  );
END;
$$;

COMMIT;
