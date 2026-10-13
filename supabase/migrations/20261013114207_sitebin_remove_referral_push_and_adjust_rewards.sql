BEGIN;

-- Keep direct referral registration independent of push-delivery infrastructure.
CREATE OR REPLACE FUNCTION public.register_referral(p_inviter_handle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_handle text;
  v_inviter_id uuid;
  v_inviter_handle text;
  v_existing public.referrals%ROWTYPE;
  v_referral_id uuid;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
  END IF;

  IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
  END IF;

  PERFORM private.enforce_user_rate_limit(v_uid, 'register_referral');

  v_handle := NULLIF(pg_catalog.lower(pg_catalog.btrim(p_inviter_handle)), '');
  IF v_handle IS NULL OR pg_catalog.length(v_handle) > 64 OR v_handle ~ '[[:cntrl:]]' THEN
    RETURN pg_catalog.jsonb_build_object('success', false, 'code', 'INVALID_CODE');
  END IF;

  -- Resolve by the existing public handle; do not accept either UUID from client.
  SELECT p.id, p.user_handle INTO v_inviter_id, v_inviter_handle
  FROM public.profiles p
  WHERE pg_catalog.lower(p.user_handle) = v_handle;

  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('success', false, 'code', 'INVALID_CODE');
  END IF;

  IF v_inviter_id = v_uid THEN
    RETURN pg_catalog.jsonb_build_object('success', false, 'code', 'SELF_REFERRAL');
  END IF;

  -- A stable row-lock order prevents two simultaneous invitations from locking
  -- the same pair of profiles in opposite order.
  PERFORM p.id
  FROM public.profiles p
  WHERE p.id IN (v_uid, v_inviter_id)
  ORDER BY p.id
  FOR UPDATE;

  IF NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = v_uid)
     OR NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = v_inviter_id) THEN
    RETURN pg_catalog.jsonb_build_object('success', false, 'code', 'ACCOUNT_NOT_FOUND');
  END IF;

  SELECT * INTO v_existing
  FROM public.referrals r
  WHERE r.invitee_id = v_uid
  FOR UPDATE;

  IF FOUND THEN
    SELECT p.user_handle INTO v_inviter_handle
    FROM public.profiles p WHERE p.id = v_existing.inviter_id;
    RETURN pg_catalog.jsonb_build_object(
      'success', false,
      'code', 'ALREADY_REGISTERED',
      'inviter_handle', v_inviter_handle
    );
  END IF;

  -- Detect cycles so reciprocal/descendant invitations cannot build loops.
  IF EXISTS (
    WITH RECURSIVE descendants(user_id) AS (
      SELECT r.invitee_id FROM public.referrals r WHERE r.inviter_id = v_uid
      UNION
      SELECT r.invitee_id
      FROM public.referrals r
      JOIN descendants d ON r.inviter_id = d.user_id
    )
    SELECT 1 FROM descendants WHERE user_id = v_inviter_id
  ) THEN
    RETURN pg_catalog.jsonb_build_object('success', false, 'code', 'REFERRAL_CYCLE');
  END IF;

  -- Anti-abuse: reject two accounts whose canonical device evidence overlaps.
  IF EXISTS (
    SELECT 1
    FROM private.device_identities a
    JOIN private.device_identities b
      ON (a.android_id_hmac IS NOT NULL AND a.android_id_hmac = b.android_id_hmac)
      OR (a.app_set_id_hmac IS NOT NULL AND a.app_set_id_hmac = b.app_set_id_hmac
          AND a.app_set_scope = b.app_set_scope)
      OR (a.installation_key_fingerprint IS NOT NULL
          AND a.installation_key_fingerprint = b.installation_key_fingerprint)
    WHERE (a.current_auth_uid = v_inviter_id OR a.first_auth_uid = v_inviter_id)
      AND (b.current_auth_uid = v_uid OR b.first_auth_uid = v_uid)
  ) OR EXISTS (
    SELECT 1
    FROM private.device_identities d
    WHERE d.first_auth_uid = v_inviter_id
      AND d.current_auth_uid = v_uid
  ) OR EXISTS (
    SELECT 1
    FROM private.device_identities d
    WHERE d.first_auth_uid = v_uid
      AND d.current_auth_uid = v_inviter_id
  ) THEN
    RETURN pg_catalog.jsonb_build_object('success', false, 'code', 'SAME_DEVICE');
  END IF;

  INSERT INTO public.referrals(inviter_id, invitee_id, created_at)
  VALUES(v_inviter_id, v_uid, v_now)
  RETURNING id INTO v_referral_id;


  RETURN pg_catalog.jsonb_build_object(
    'success', true,
    'already_registered', false,
    'referral_id', v_referral_id,
    'inviter_handle', v_inviter_handle,
    'created_at', v_now
  );
END;
$function$;

-- Future/unpaid 500-distinct-site awards pay 20,000 coins to each direct party.
-- Existing granted rows/balances are intentionally left untouched.
CREATE OR REPLACE FUNCTION private.award_referral_milestone(
  p_referral_id uuid,
  p_milestone text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_ref public.referrals%ROWTYPE;
  v_expected_count integer;
  v_existing_count integer;
  v_existing_ledger_count integer;
  v_amount bigint;
  v_recipient record;
  v_grant_id uuid;
  v_ledger_id uuid;
  v_idempotency_key text;
  v_description text;
BEGIN
  IF p_milestone = 'VIEWS_100' THEN
    v_expected_count := 100;
    v_amount := 500;
  ELSIF p_milestone = 'WEBSITES_500' THEN
    v_expected_count := 500;
    v_amount := 20000;
  ELSE
    RAISE EXCEPTION 'INVALID_REFERRAL_MILESTONE';
  END IF;

  SELECT * INTO v_ref
  FROM public.referrals
  WHERE id = p_referral_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'REFERRAL_NOT_FOUND';
  END IF;

  IF (p_milestone = 'VIEWS_100' AND v_ref.completed_views_count < v_expected_count)
     OR (p_milestone = 'WEBSITES_500' AND v_ref.unique_websites_count < v_expected_count) THEN
    RETURN;
  END IF;

  IF (p_milestone = 'VIEWS_100' AND v_ref.tier_100_paid_at IS NOT NULL)
     OR (p_milestone = 'WEBSITES_500' AND v_ref.tier_500_paid_at IS NOT NULL) THEN
    RETURN;
  END IF;

  -- Lock both wallets in the same order. Any failure below rolls back the two
  -- credits, ledger entries, grants and milestone timestamp atomically.
  PERFORM p.id
  FROM public.profiles p
  WHERE p.id IN (v_ref.inviter_id, v_ref.invitee_id)
  ORDER BY p.id
  FOR UPDATE;

  SELECT pg_catalog.count(*),
         pg_catalog.count(*) FILTER (WHERE g.ledger_entry_id IS NOT NULL)
  INTO v_existing_count, v_existing_ledger_count
  FROM private.referral_reward_grants g
  WHERE g.referral_id = v_ref.id
    AND g.milestone = p_milestone;

  IF v_existing_count = 2 AND v_existing_ledger_count = 2 THEN
    UPDATE public.referrals
    SET tier_100_paid_at = CASE WHEN p_milestone = 'VIEWS_100'
          THEN COALESCE(tier_100_paid_at, pg_catalog.clock_timestamp()) ELSE tier_100_paid_at END,
        tier_500_paid_at = CASE WHEN p_milestone = 'WEBSITES_500'
          THEN COALESCE(tier_500_paid_at, pg_catalog.clock_timestamp()) ELSE tier_500_paid_at END,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_ref.id;
    RETURN;
  ELSIF v_existing_count <> 0 THEN
    RAISE EXCEPTION 'REFERRAL_REWARD_STATE_INCONSISTENT: partial milestone grant state';
  END IF;

  FOR v_recipient IN
    SELECT p.id, p.user_handle
    FROM public.profiles p
    WHERE p.id IN (v_ref.inviter_id, v_ref.invitee_id)
    ORDER BY p.id
  LOOP
    v_idempotency_key := 'referral_' || v_ref.id::text || '_' || p_milestone || '_' || v_recipient.id::text;
    v_description := CASE p_milestone
      WHEN 'VIEWS_100' THEN 'پاداش دعوت: تکمیل ۱۰۰ بازدید معتبر'
      ELSE 'پاداش دعوت: مشاهده ۵۰۰ وب‌سایت متفاوت'
    END;

    INSERT INTO private.referral_reward_grants(
      referral_id, milestone, recipient_id, amount, idempotency_key
    )
    VALUES(v_ref.id, p_milestone, v_recipient.id, v_amount, v_idempotency_key)
    RETURNING id INTO v_grant_id;

    UPDATE public.profiles
    SET available_coins = available_coins + v_amount,
        lifetime_earned = lifetime_earned + v_amount,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_recipient.id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'REFERRAL_REWARD_RECIPIENT_NOT_FOUND';
    END IF;

    INSERT INTO public.coin_ledger(
      user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
    )
    VALUES(
      v_recipient.id,
      v_amount,
      'REFERRAL_REWARD',
      v_description,
      'referral:' || v_ref.id::text || ':' || p_milestone,
      v_idempotency_key,
      pg_catalog.clock_timestamp()
    )
    RETURNING id INTO v_ledger_id;

    UPDATE private.referral_reward_grants
    SET ledger_entry_id = v_ledger_id
    WHERE id = v_grant_id;
  END LOOP;

  UPDATE public.referrals
  SET tier_100_paid_at = CASE WHEN p_milestone = 'VIEWS_100'
        THEN pg_catalog.clock_timestamp() ELSE tier_100_paid_at END,
      tier_500_paid_at = CASE WHEN p_milestone = 'WEBSITES_500'
        THEN pg_catalog.clock_timestamp() ELSE tier_500_paid_at END,
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = v_ref.id;
END;
$function$;

-- Retire referral-push endpoints before dropping the private delivery tables.
DROP FUNCTION IF EXISTS public.claim_referral_notifications(uuid, integer);
DROP FUNCTION IF EXISTS public.finish_referral_notification_delivery(uuid, text, text, text[]);
DROP FUNCTION IF EXISTS public.load_referral_notification_delivery(uuid[]);
DROP FUNCTION IF EXISTS public.register_push_token(text, boolean);
DROP FUNCTION IF EXISTS public.set_referral_push_notifications_enabled(boolean);

DROP TABLE IF EXISTS private.referral_notification_outbox;
DROP TABLE IF EXISTS private.referral_push_tokens;

COMMIT;
