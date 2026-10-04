-- SiteBin: server-authoritative user-to-user coin transfers.
-- Transfers move only available (not reserved) coins and produce paired ledger entries.

BEGIN;

CREATE TABLE IF NOT EXISTS public.coin_transfers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  recipient_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  amount BIGINT NOT NULL CHECK (amount > 0),
  note TEXT,
  idempotency_key TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT coin_transfers_sender_recipient_check CHECK (sender_id <> recipient_id),
  CONSTRAINT coin_transfers_note_check CHECK (
    note IS NULL OR (
      pg_catalog.length(pg_catalog.btrim(note)) BETWEEN 1 AND 160
      AND note !~ '[[:cntrl:]]'
    )
  )
);

ALTER TABLE public.coin_transfers ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_coin_transfers_sender_created
  ON public.coin_transfers(sender_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_coin_transfers_recipient_created
  ON public.coin_transfers(recipient_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_user_handle_lower
  ON public.profiles (lower(user_handle));

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
        'COIN_TRANSFER_RECEIVED'::text
      ]
    )
  );

CREATE OR REPLACE FUNCTION public.transfer_coins(
  p_recipient_handle TEXT,
  p_amount BIGINT,
  p_idempotency_key TEXT,
  p_note TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid UUID := (select auth.uid());
  v_recipient RECORD;
  v_sender RECORD;
  v_existing RECORD;
  v_handle TEXT;
  v_note TEXT;
  v_transfer RECORD;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
  END IF;

  IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
  END IF;

  v_handle := pg_catalog.btrim(p_recipient_handle);
  v_note := NULLIF(pg_catalog.btrim(p_note), '');

  IF v_handle IS NULL OR pg_catalog.length(v_handle) = 0 OR pg_catalog.length(v_handle) > 64 THEN
    RAISE EXCEPTION 'INVALID_RECIPIENT: User ID is required and must be at most 64 characters';
  END IF;

  IF v_handle !~ '^[A-Za-z0-9_]+$' THEN
    RAISE EXCEPTION 'INVALID_RECIPIENT: Invalid user ID format';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: Transfer amount must be greater than zero';
  END IF;

  IF p_amount > 1000000 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: Maximum transfer per transaction is 1,000,000 coins';
  END IF;

  IF p_idempotency_key IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_idempotency_key)) < 16
     OR pg_catalog.length(pg_catalog.btrim(p_idempotency_key)) > 128
     OR p_idempotency_key ~ '[[:space:]]' THEN
    RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Invalid transfer request key';
  END IF;

  IF v_note IS NOT NULL
     AND (
       pg_catalog.length(v_note) > 160
       OR v_note ~ '[[:cntrl:]]'
     ) THEN
    RAISE EXCEPTION 'INVALID_NOTE: Transfer note must be at most 160 characters';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.coin_transfers
  WHERE idempotency_key = pg_catalog.btrim(p_idempotency_key);

  IF v_existing IS NOT NULL THEN
    IF v_existing.sender_id <> v_uid THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: Transfer request key belongs to another account';
    END IF;

    SELECT user_handle INTO v_handle
    FROM public.profiles
    WHERE id = v_existing.recipient_id;

    RETURN pg_catalog.json_build_object(
      'transfer_id', v_existing.id,
      'recipient_handle', v_handle,
      'amount', v_existing.amount,
      'note', v_existing.note,
      'created_at', extract(epoch from v_existing.created_at) * 1000
    );
  END IF;

  SELECT *
  INTO v_recipient
  FROM public.profiles
  WHERE lower(user_handle) = lower(v_handle);

  IF v_recipient IS NULL THEN
    RAISE EXCEPTION 'RECIPIENT_NOT_FOUND: User ID was not found';
  END IF;

  IF v_recipient.id = v_uid THEN
    RAISE EXCEPTION 'INVALID_RECIPIENT: You cannot transfer coins to yourself';
  END IF;

  -- Lock both accounts in deterministic UUID order to prevent A->B / B->A deadlocks.
  PERFORM 1
  FROM public.profiles
  WHERE id IN (v_uid, v_recipient.id)
  ORDER BY id
  FOR UPDATE;

  SELECT * INTO v_sender
  FROM public.profiles
  WHERE id = v_uid;

  SELECT * INTO v_recipient
  FROM public.profiles
  WHERE id = v_recipient.id;

  IF v_sender.available_coins < p_amount THEN
    RAISE EXCEPTION 'INSUFFICIENT_BALANCE: Available balance (%) coins is less than transfer amount (%) coins',
      v_sender.available_coins, p_amount;
  END IF;

  INSERT INTO public.coin_transfers(
    sender_id, recipient_id, amount, note, idempotency_key, created_at
  )
  VALUES(
    v_uid, v_recipient.id, p_amount, v_note,
    pg_catalog.btrim(p_idempotency_key), pg_catalog.clock_timestamp()
  )
  RETURNING * INTO v_transfer;

  UPDATE public.profiles
  SET available_coins = available_coins - p_amount,
      lifetime_spent = lifetime_spent + p_amount,
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = v_uid;

  UPDATE public.profiles
  SET available_coins = available_coins + p_amount,
      lifetime_earned = lifetime_earned + p_amount,
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = v_recipient.id;

  INSERT INTO public.coin_ledger(
    user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
  )
  VALUES(
    v_uid,
    -p_amount,
    'COIN_TRANSFER_SENT',
    'انتقال ' || p_amount || ' سکه به ' || v_recipient.user_handle,
    v_transfer.id::text,
    'transfer_sent_' || v_transfer.id::text,
    v_transfer.created_at
  );

  INSERT INTO public.coin_ledger(
    user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
  )
  VALUES(
    v_recipient.id,
    p_amount,
    'COIN_TRANSFER_RECEIVED',
    'دریافت ' || p_amount || ' سکه از ' || v_sender.user_handle,
    v_transfer.id::text,
    'transfer_received_' || v_transfer.id::text,
    v_transfer.created_at
  );

  RETURN pg_catalog.json_build_object(
    'transfer_id', v_transfer.id,
    'recipient_handle', v_recipient.user_handle,
    'amount', v_transfer.amount,
    'note', v_transfer.note,
    'created_at', extract(epoch from v_transfer.created_at) * 1000
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.transfer_coins(TEXT, BIGINT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transfer_coins(TEXT, BIGINT, TEXT, TEXT) TO authenticated;

REVOKE ALL ON TABLE public.coin_transfers FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.coin_transfers TO service_role;

COMMIT;
