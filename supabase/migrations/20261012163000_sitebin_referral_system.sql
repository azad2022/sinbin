BEGIN;

-- SiteBin referral milestones. All progress and grants are server-authoritative.
-- Algorithm for website identity is pinned in campaign-url-preflight (tldts 6.1.86,
-- allowPrivateDomains=true). Historical sites are backfilled below; unknown
-- historical domains abort this migration rather than silently degrading the
-- 500-distinct-site reward's semantics.

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS referral_site_key text;

ALTER TABLE private.campaign_preflight_tokens
  ADD COLUMN IF NOT EXISTS referral_site_key text;

CREATE OR REPLACE FUNCTION private.capture_preflight_referral_site_key()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_key text;
BEGIN
  IF pg_catalog.jsonb_typeof(NEW.diagnostics) = 'object' THEN
    v_key := NULLIF(pg_catalog.lower(pg_catalog.btrim(NEW.diagnostics ->> 'referral_site_key')), '');
  END IF;

  IF v_key IS NOT NULL AND (
      pg_catalog.length(v_key) > 253
      OR v_key !~ '^[a-z0-9.-]+$'
      OR v_key LIKE '.%'
      OR v_key LIKE '%.'
      OR v_key LIKE '%..%'
  ) THEN
    RAISE EXCEPTION 'INVALID_REFERRAL_SITE_KEY';
  END IF;

  NEW.referral_site_key := v_key;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.capture_preflight_referral_site_key()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_capture_preflight_referral_site_key
  ON private.campaign_preflight_tokens;

CREATE TRIGGER trg_capture_preflight_referral_site_key
BEFORE INSERT OR UPDATE OF diagnostics ON private.campaign_preflight_tokens
FOR EACH ROW EXECUTE FUNCTION private.capture_preflight_referral_site_key();

-- Exact backfill from the currently-live 32-campaign inventory. This is an
-- explicit one-time map produced from the same PSL rules; if inventory changed
-- before rollout, stop and extend the mapping instead of guessing.
UPDATE public.campaigns
SET referral_site_key = CASE pg_catalog.lower(domain)
  WHEN 'farsi.khamenei.ir' THEN 'khamenei.ir'
  WHEN 'www.parhana.ir' THEN 'parhana.ir'
  WHEN 'www.zagrospoosh.com' THEN 'zagrospoosh.com'
  WHEN 'ble.ir' THEN 'ble.ir'
  WHEN 'cafebazaar.ir' THEN 'cafebazaar.ir'
  WHEN 'hamgamtire.ir' THEN 'hamgamtire.ir'
  WHEN 'iblo.ir' THEN 'iblo.ir'
  WHEN 'iranblockchain.org' THEN 'iranblockchain.org'
  WHEN 'kimiyabeans.com' THEN 'kimiyabeans.com'
  WHEN 'letsgotrip.ir' THEN 'letsgotrip.ir'
  WHEN 'ooscar.ir' THEN 'ooscar.ir'
  WHEN 'pafix.ir' THEN 'pafix.ir'
  WHEN 'parmanshop.ir' THEN 'parmanshop.ir'
  WHEN 'safine.net' THEN 'safine.net'
  WHEN 'shokofedolls.ir' THEN 'shokofedolls.ir'
  WHEN 'solmint.ir' THEN 'solmint.ir'
  WHEN 'torob.com' THEN 'torob.com'
  WHEN 'wikipedia.org' THEN 'wikipedia.org'
  WHEN 'www.parhana.ir' THEN 'parhana.ir'
  WHEN 'www.zagrospoosh.com' THEN 'zagrospoosh.com'
  ELSE NULL
END;

DO $backfill_guard$
DECLARE
  v_unknown text;
BEGIN
  SELECT pg_catalog.string_agg(DISTINCT c.domain, ', ' ORDER BY c.domain)
  INTO v_unknown
  FROM public.campaigns c
  WHERE c.referral_site_key IS NULL
    AND c.domain !~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$';

  IF v_unknown IS NOT NULL THEN
    RAISE EXCEPTION 'REFERRAL_SITE_KEY_BACKFILL_REQUIRED: unmapped existing campaign domains: %', v_unknown;
  END IF;
END;
$backfill_guard$;

ALTER TABLE public.campaigns
  DROP CONSTRAINT IF EXISTS campaigns_referral_site_key_check;

ALTER TABLE public.campaigns
  ADD CONSTRAINT campaigns_referral_site_key_check
  CHECK (
    referral_site_key IS NULL OR (
      referral_site_key = pg_catalog.lower(pg_catalog.btrim(referral_site_key))
      AND pg_catalog.length(referral_site_key) BETWEEN 1 AND 253
      AND referral_site_key ~ '^[a-z0-9.-]+$'
      AND referral_site_key NOT LIKE '.%'
      AND referral_site_key NOT LIKE '%.'
      AND referral_site_key NOT LIKE '%..%'
    )
  ) NOT VALID;

ALTER TABLE public.campaigns
  VALIDATE CONSTRAINT campaigns_referral_site_key_check;

CREATE INDEX IF NOT EXISTS idx_campaigns_referral_site_key
  ON public.campaigns (referral_site_key)
  WHERE referral_site_key IS NOT NULL;

CREATE OR REPLACE FUNCTION private.assign_campaign_referral_site_key()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_key text;
  v_found boolean := false;
BEGIN
  SELECT t.referral_site_key, true
  INTO v_key, v_found
  FROM private.campaign_preflight_tokens t
  WHERE t.user_id = NEW.owner_id
    AND t.source_url = NEW.url
    AND t.normalized_url = NEW.normalized_url
    AND t.consumed_at IS NOT NULL
  ORDER BY t.consumed_at DESC, t.created_at DESC
  LIMIT 1;

  IF NOT COALESCE(v_found, false) THEN
    RAISE EXCEPTION 'PREFLIGHT_REFERRAL_METADATA_MISSING: campaign must be created from a consumed, server-validated preflight token';
  END IF;

  -- NULL means the public hostname has no registrable domain in the pinned PSL
  -- (for example, a public IP literal). Such views can count toward 100 views,
  -- but must not count toward the 500-distinct-website milestone.
  NEW.referral_site_key := v_key;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.assign_campaign_referral_site_key()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_assign_campaign_referral_site_key
  ON public.campaigns;

CREATE TRIGGER trg_assign_campaign_referral_site_key
BEFORE INSERT ON public.campaigns
FOR EACH ROW EXECUTE FUNCTION private.assign_campaign_referral_site_key();

CREATE TABLE IF NOT EXISTS public.referrals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inviter_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  invitee_id uuid NOT NULL UNIQUE REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  completed_views_count integer NOT NULL DEFAULT 0 CHECK (completed_views_count >= 0),
  unique_websites_count integer NOT NULL DEFAULT 0 CHECK (unique_websites_count >= 0),
  tier_100_paid_at timestamptz,
  tier_500_paid_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT referrals_not_self CHECK (inviter_id <> invitee_id),
  CONSTRAINT referrals_site_progress_bounded CHECK (unique_websites_count <= completed_views_count)
);

CREATE INDEX IF NOT EXISTS idx_referrals_inviter_created
  ON public.referrals (inviter_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_referrals_invitee_created
  ON public.referrals (invitee_id, created_at DESC);

ALTER TABLE public.referrals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.referrals FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.referrals TO authenticated;

DROP POLICY IF EXISTS referrals_read_direct_relationship ON public.referrals;
CREATE POLICY referrals_read_direct_relationship
ON public.referrals
FOR SELECT TO authenticated
USING (inviter_id = (SELECT auth.uid()) OR invitee_id = (SELECT auth.uid()));

CREATE TABLE IF NOT EXISTS private.referral_completed_views (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referral_id uuid NOT NULL REFERENCES public.referrals(id) ON DELETE CASCADE,
  view_session_id uuid NOT NULL UNIQUE REFERENCES public.view_sessions(id) ON DELETE CASCADE,
  campaign_id uuid NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  site_key text,
  completed_at timestamptz NOT NULL,
  CONSTRAINT referral_completed_views_site_key_check
    CHECK (site_key IS NULL OR (
      site_key = pg_catalog.lower(pg_catalog.btrim(site_key))
      AND pg_catalog.length(site_key) BETWEEN 1 AND 253
      AND site_key ~ '^[a-z0-9.-]+$'
    ))
);

CREATE INDEX IF NOT EXISTS idx_referral_completed_views_referral_completed
  ON private.referral_completed_views (referral_id, completed_at DESC);

CREATE TABLE IF NOT EXISTS private.referral_website_progress (
  referral_id uuid NOT NULL REFERENCES public.referrals(id) ON DELETE CASCADE,
  website_key text NOT NULL,
  first_view_session_id uuid NOT NULL UNIQUE REFERENCES public.view_sessions(id) ON DELETE CASCADE,
  first_completed_at timestamptz NOT NULL,
  PRIMARY KEY (referral_id, website_key)
);

CREATE TABLE IF NOT EXISTS private.referral_reward_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referral_id uuid NOT NULL REFERENCES public.referrals(id) ON DELETE CASCADE,
  milestone text NOT NULL CHECK (milestone IN ('VIEWS_100', 'WEBSITES_500')),
  recipient_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  amount bigint NOT NULL CHECK (amount > 0),
  idempotency_key text NOT NULL UNIQUE,
  ledger_entry_id uuid REFERENCES public.coin_ledger(id),
  paid_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT referral_reward_grants_once UNIQUE (referral_id, milestone, recipient_id)
);

CREATE INDEX IF NOT EXISTS idx_referral_reward_grants_recipient
  ON private.referral_reward_grants (recipient_id, paid_at DESC);

CREATE TABLE IF NOT EXISTS private.referral_push_tokens (
  token text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT true,
  platform text NOT NULL DEFAULT 'android' CHECK (platform IN ('android')),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT referral_push_token_shape CHECK (
    pg_catalog.length(token) BETWEEN 20 AND 4096
    AND token !~ '[[:cntrl:]]'
  )
);

CREATE INDEX IF NOT EXISTS idx_referral_push_tokens_user_enabled
  ON private.referral_push_tokens (user_id, updated_at DESC)
  WHERE enabled;

CREATE TABLE IF NOT EXISTS private.referral_notification_outbox (
  event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referral_id uuid NOT NULL REFERENCES public.referrals(id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (event_type IN ('REFERRAL_REGISTERED')),
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  recipient_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  payload jsonb NOT NULL,
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  last_attempt_at timestamptz,
  delivered_at timestamptz,
  last_error text,
  CONSTRAINT referral_notification_outbox_once UNIQUE (referral_id, event_type, recipient_id)
);

CREATE INDEX IF NOT EXISTS idx_referral_notification_outbox_pending_recipient
  ON private.referral_notification_outbox (recipient_id, created_at)
  WHERE delivered_at IS NULL;

ALTER TABLE private.referral_completed_views ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.referral_website_progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.referral_reward_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.referral_push_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.referral_notification_outbox ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE private.referral_completed_views FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.referral_website_progress FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.referral_reward_grants FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.referral_push_tokens FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.referral_notification_outbox FROM PUBLIC, anon, authenticated;

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
    v_amount := 25000;
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

REVOKE ALL ON FUNCTION private.award_referral_milestone(uuid, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.track_referral_completed_view()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_ref public.referrals%ROWTYPE;
  v_campaign_owner uuid;
  v_site_key text;
  v_inserted_session uuid;
  v_new_site_key text;
BEGIN
  IF NOT (OLD.status IS DISTINCT FROM 'COMPLETED' AND NEW.status = 'COMPLETED') THEN
    RETURN NEW;
  END IF;

  SELECT r.* INTO v_ref
  FROM public.referrals r
  WHERE r.invitee_id = NEW.viewer_id
    AND NEW.started_at > r.created_at
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  SELECT c.owner_id, c.referral_site_key
  INTO v_campaign_owner, v_site_key
  FROM public.campaigns c
  WHERE c.id = NEW.campaign_id;

  IF v_campaign_owner IS NULL
     OR v_campaign_owner = v_ref.invitee_id
     OR v_campaign_owner = v_ref.inviter_id THEN
    RETURN NEW;
  END IF;

  INSERT INTO private.referral_completed_views(
    referral_id, view_session_id, campaign_id, site_key, completed_at
  )
  VALUES(v_ref.id, NEW.id, NEW.campaign_id, v_site_key, COALESCE(NEW.completed_at, pg_catalog.clock_timestamp()))
  ON CONFLICT (view_session_id) DO NOTHING
  RETURNING view_session_id INTO v_inserted_session;

  IF v_inserted_session IS NULL THEN
    RETURN NEW;
  END IF;

  v_new_site_key := NULL;
  IF v_site_key IS NOT NULL THEN
    INSERT INTO private.referral_website_progress(
      referral_id, website_key, first_view_session_id, first_completed_at
    )
    VALUES(v_ref.id, v_site_key, NEW.id, COALESCE(NEW.completed_at, pg_catalog.clock_timestamp()))
    ON CONFLICT (referral_id, website_key) DO NOTHING
    RETURNING website_key INTO v_new_site_key;
  END IF;

  UPDATE public.referrals
  SET completed_views_count = completed_views_count + 1,
      unique_websites_count = unique_websites_count + CASE WHEN v_new_site_key IS NOT NULL THEN 1 ELSE 0 END,
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = v_ref.id
  RETURNING * INTO v_ref;

  IF v_ref.completed_views_count >= 100 AND v_ref.tier_100_paid_at IS NULL THEN
    PERFORM private.award_referral_milestone(v_ref.id, 'VIEWS_100');
  END IF;

  IF v_ref.unique_websites_count >= 500 AND v_ref.tier_500_paid_at IS NULL THEN
    PERFORM private.award_referral_milestone(v_ref.id, 'WEBSITES_500');
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.track_referral_completed_view()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_track_referral_completed_view ON public.view_sessions;
CREATE TRIGGER trg_track_referral_completed_view
AFTER UPDATE OF status ON public.view_sessions
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM 'COMPLETED' AND NEW.status = 'COMPLETED')
EXECUTE FUNCTION private.track_referral_completed_view();

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
  v_event_id uuid;
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

  INSERT INTO private.referral_notification_outbox(
    referral_id, event_type, actor_id, recipient_id, payload
  )
  VALUES(
    v_referral_id,
    'REFERRAL_REGISTERED',
    v_uid,
    v_inviter_id,
    pg_catalog.jsonb_build_object(
      'title', 'زیرمجموعه جدید',
      'body', v_inviter_handle || ' زیرمجموعه مستقیم شما شد.',
      'inviter_handle', v_inviter_handle,
      'invitee_handle', (SELECT p.user_handle FROM public.profiles p WHERE p.id = v_uid)
    )
  )
  RETURNING event_id INTO v_event_id;

  RETURN pg_catalog.jsonb_build_object(
    'success', true,
    'already_registered', false,
    'referral_id', v_referral_id,
    'event_id', v_event_id,
    'inviter_handle', v_inviter_handle,
    'created_at', v_now
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.register_referral(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_referral(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_referral_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_my_referral jsonb;
  v_direct_invites integer;
  v_direct_100 integer;
  v_direct_500 integer;
  v_coins bigint;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
  END IF;

  IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
  END IF;

  SELECT pg_catalog.jsonb_build_object(
    'inviter_handle', inviter.user_handle,
    'created_at', r.created_at,
    'completed_views_count', r.completed_views_count,
    'unique_websites_count', r.unique_websites_count,
    'tier_100_paid', r.tier_100_paid_at IS NOT NULL,
    'tier_500_paid', r.tier_500_paid_at IS NOT NULL
  )
  INTO v_my_referral
  FROM public.referrals r
  JOIN public.profiles inviter ON inviter.id = r.inviter_id
  WHERE r.invitee_id = v_uid;

  IF v_my_referral IS NULL THEN
    v_my_referral := 'null'::jsonb;
  END IF;

  SELECT pg_catalog.count(*)::integer,
         pg_catalog.count(*) FILTER (WHERE r.tier_100_paid_at IS NOT NULL)::integer,
         pg_catalog.count(*) FILTER (WHERE r.tier_500_paid_at IS NOT NULL)::integer
  INTO v_direct_invites, v_direct_100, v_direct_500
  FROM public.referrals r
  WHERE r.inviter_id = v_uid;

  SELECT COALESCE(pg_catalog.sum(g.amount), 0)::bigint
  INTO v_coins
  FROM private.referral_reward_grants g
  WHERE g.recipient_id = v_uid;

  RETURN pg_catalog.jsonb_build_object(
    'my_referral', v_my_referral,
    'direct_invite_count', COALESCE(v_direct_invites, 0),
    'direct_tier_100_completed_count', COALESCE(v_direct_100, 0),
    'direct_tier_500_completed_count', COALESCE(v_direct_500, 0),
    'referral_coins_earned', COALESCE(v_coins, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_referral_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_referral_status() TO authenticated;

CREATE OR REPLACE FUNCTION public.register_push_token(
  p_token text,
  p_enabled boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_token text := NULLIF(pg_catalog.btrim(p_token), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
  END IF;
  IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
  END IF;
  IF v_token IS NULL
     OR pg_catalog.length(v_token) NOT BETWEEN 20 AND 4096
     OR v_token ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION 'INVALID_PUSH_TOKEN';
  END IF;

  INSERT INTO private.referral_push_tokens(token, user_id, enabled, platform, updated_at)
  VALUES(v_token, v_uid, COALESCE(p_enabled, true), 'android', pg_catalog.clock_timestamp())
  ON CONFLICT (token) DO UPDATE
  SET user_id = EXCLUDED.user_id,
      enabled = EXCLUDED.enabled,
      updated_at = EXCLUDED.updated_at;

  RETURN pg_catalog.jsonb_build_object('success', true, 'enabled', COALESCE(p_enabled, true));
END;
$function$;

REVOKE ALL ON FUNCTION public.register_push_token(text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_push_token(text, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_referral_push_notifications_enabled(p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
  END IF;
  IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
    RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
  END IF;

  UPDATE private.referral_push_tokens
  SET enabled = COALESCE(p_enabled, false),
      updated_at = pg_catalog.clock_timestamp()
  WHERE user_id = v_uid;

  RETURN pg_catalog.jsonb_build_object(
    'success', true,
    'enabled', COALESCE(p_enabled, false)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.set_referral_push_notifications_enabled(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_referral_push_notifications_enabled(boolean) TO authenticated;

-- Extend the account-rebind transaction so profile FK cascades cannot remove
-- referral relationships, payout audit rows, tokens or pending notifications.
CREATE OR REPLACE FUNCTION private.rebind_user_account(p_old_uid uuid, p_new_uid uuid, p_install_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_old_profile public.profiles%ROWTYPE;
    v_new_profile public.profiles%ROWTYPE;
    v_old_handle text;
    v_new_install_id text;
BEGIN
    IF p_old_uid IS NULL OR p_new_uid IS NULL OR p_old_uid = p_new_uid THEN
        RETURN;
    END IF;

    PERFORM 1 FROM auth.users WHERE id = p_new_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_REBIND_TARGET_AUTH_NOT_FOUND';
    END IF;

    SELECT * INTO v_old_profile
    FROM public.profiles
    WHERE id = p_old_uid
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_REBIND_SOURCE_PROFILE_NOT_FOUND';
    END IF;

    SELECT * INTO v_new_profile
    FROM public.profiles
    WHERE id = p_new_uid
    FOR UPDATE;

    IF FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_REBIND_TARGET_PROFILE_EXISTS';
    END IF;

    v_old_handle := v_old_profile.user_handle;
    v_new_install_id := NULLIF(pg_catalog.btrim(COALESCE(p_install_id, '')), '');
    IF v_new_install_id IS NULL THEN
        v_new_install_id := v_old_profile.app_install_id;
    END IF;

    UPDATE public.profiles
    SET user_handle = '__rebind__' || p_old_uid::text
    WHERE id = p_old_uid;

    INSERT INTO public.profiles(
        id, user_handle, app_install_id, available_coins, reserved_coins,
        lifetime_earned, lifetime_spent, trust_score, completed_views_count,
        received_views_count, welcome_bonus_claimed, created_at, updated_at
    )
    VALUES(
        p_new_uid, v_old_handle, v_new_install_id, v_old_profile.available_coins,
        v_old_profile.reserved_coins, v_old_profile.lifetime_earned,
        v_old_profile.lifetime_spent, v_old_profile.trust_score,
        v_old_profile.completed_views_count, v_old_profile.received_views_count,
        v_old_profile.welcome_bonus_claimed, v_old_profile.created_at, pg_catalog.clock_timestamp()
    );

    UPDATE public.auto_view_entitlements SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.auto_view_purchases SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.campaigns SET owner_id = p_new_uid WHERE owner_id = p_old_uid;
    UPDATE public.coin_ledger SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.coin_transfers SET sender_id = p_new_uid WHERE sender_id = p_old_uid;
    UPDATE public.coin_transfers SET recipient_id = p_new_uid WHERE recipient_id = p_old_uid;
    UPDATE public.daily_bonus_grants SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE public.view_sessions SET viewer_id = p_new_uid WHERE viewer_id = p_old_uid;
    UPDATE public.welcome_bonus_grants SET user_id = p_new_uid WHERE user_id = p_old_uid;

    UPDATE private.campaign_preflight_tokens SET user_id = p_new_uid WHERE user_id = p_old_uid;
    UPDATE private.daily_bonus_device_claims
    SET beneficiary_auth_uid = p_new_uid
    WHERE beneficiary_auth_uid = p_old_uid;

    /*
     * Rate-limit rows are keyed by (user_id, action). On reinstall, the
     * PostgREST pre-request limiter has already touched the new UID before
     * init_user_account runs, so a plain UPDATE from old UID -> new UID can
     * collide on (new_uid, action). Merge conservatively instead: preserve the
     * stricter state and then delete the old rows.
     */
    INSERT INTO private.rate_limit_buckets AS target(
        user_id, action,
        ten_second_started_at, ten_second_count,
        minute_started_at, minute_count,
        five_minute_started_at, five_minute_count,
        hour_started_at, hour_count,
        blocked_until, updated_at
    )
    SELECT
        p_new_uid,
        source.action,
        source.ten_second_started_at,
        source.ten_second_count,
        source.minute_started_at,
        source.minute_count,
        source.five_minute_started_at,
        source.five_minute_count,
        source.hour_started_at,
        source.hour_count,
        source.blocked_until,
        source.updated_at
    FROM private.rate_limit_buckets AS source
    WHERE source.user_id = p_old_uid
    ON CONFLICT (user_id, action) DO UPDATE
    SET ten_second_started_at = LEAST(
            target.ten_second_started_at,
            EXCLUDED.ten_second_started_at
        ),
        ten_second_count = GREATEST(
            target.ten_second_count,
            EXCLUDED.ten_second_count
        ),
        minute_started_at = LEAST(
            target.minute_started_at,
            EXCLUDED.minute_started_at
        ),
        minute_count = GREATEST(
            target.minute_count,
            EXCLUDED.minute_count
        ),
        five_minute_started_at = LEAST(
            target.five_minute_started_at,
            EXCLUDED.five_minute_started_at
        ),
        five_minute_count = GREATEST(
            target.five_minute_count,
            EXCLUDED.five_minute_count
        ),
        hour_started_at = LEAST(
            target.hour_started_at,
            EXCLUDED.hour_started_at
        ),
        hour_count = GREATEST(
            target.hour_count,
            EXCLUDED.hour_count
        ),
        blocked_until = CASE
            WHEN target.blocked_until IS NULL THEN EXCLUDED.blocked_until
            WHEN EXCLUDED.blocked_until IS NULL THEN target.blocked_until
            ELSE GREATEST(target.blocked_until, EXCLUDED.blocked_until)
        END,
        updated_at = GREATEST(target.updated_at, EXCLUDED.updated_at);

    DELETE FROM private.rate_limit_buckets WHERE user_id = p_old_uid;

    UPDATE private.welcome_bonus_entitlements
    SET beneficiary_auth_uid = p_new_uid
    WHERE beneficiary_auth_uid = p_old_uid;

    -- Preserve referral attribution, progress and push delivery state before the old profile cascades.
    UPDATE public.referrals
    SET inviter_id = CASE WHEN inviter_id = p_old_uid THEN p_new_uid ELSE inviter_id END,
        invitee_id = CASE WHEN invitee_id = p_old_uid THEN p_new_uid ELSE invitee_id END,
        updated_at = pg_catalog.clock_timestamp()
    WHERE inviter_id = p_old_uid OR invitee_id = p_old_uid;

    UPDATE private.referral_reward_grants
    SET recipient_id = p_new_uid
    WHERE recipient_id = p_old_uid;

    UPDATE private.referral_notification_outbox
    SET actor_id = CASE WHEN actor_id = p_old_uid THEN p_new_uid ELSE actor_id END,
        recipient_id = CASE WHEN recipient_id = p_old_uid THEN p_new_uid ELSE recipient_id END
    WHERE actor_id = p_old_uid OR recipient_id = p_old_uid;

    UPDATE private.referral_push_tokens
    SET user_id = p_new_uid, updated_at = pg_catalog.clock_timestamp()
    WHERE user_id = p_old_uid;

    DELETE FROM public.profiles WHERE id = p_old_uid;
END;
$function$


COMMIT;
