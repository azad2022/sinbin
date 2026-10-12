-- SiteBin direct-referral integration regression test.
-- Run only against a disposable or explicitly authorized test database AFTER
-- sitebin_referral_system has been applied. All fixture mutations roll back.
-- This test exercises the referral completion trigger and transactional payout
-- helpers; it does not replace a full Android/Auth/WebView end-to-end test.

BEGIN;

DO $referral_test$
DECLARE
  v_inviter uuid := gen_random_uuid();
  v_invitee uuid := gen_random_uuid();
  v_downstream uuid := gen_random_uuid();
  v_handle_inviter text := 'user_ref_test_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_handle_invitee text := 'user_ref_test_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_handle_downstream text := 'user_ref_test_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_referral_id uuid;
  v_downstream_referral_id uuid;
  v_result jsonb;
  v_campaign_id uuid;
  v_campaign_owner uuid;
  v_campaign_key text;
  v_campaign2_id uuid;
  v_campaign2_owner uuid;
  v_campaign2_key text;
  v_session_id uuid;
  v_referral_created_at timestamptz;
  v_count integer;
  v_balance_inviter bigint;
  v_balance_invitee bigint;
  v_balance_downstream bigint;
  v_ledger_inviter bigint;
  v_ledger_invitee bigint;
  v_ledger_downstream bigint;
  i integer;
BEGIN
  -- Use synthetic Auth users and profiles; no existing user's balances or
  -- referral history are changed.
  INSERT INTO auth.users(
    id, aud, role, email, email_confirmed_at, created_at, updated_at,
    is_sso_user, is_anonymous
  )
  VALUES
    (v_inviter, 'authenticated', 'authenticated',
      replace(v_handle_inviter, '_', '.') || '@sitebin.referral-test.invalid',
      pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp(), false, false),
    (v_invitee, 'authenticated', 'authenticated',
      replace(v_handle_invitee, '_', '.') || '@sitebin.referral-test.invalid',
      pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp(), false, false),
    (v_downstream, 'authenticated', 'authenticated',
      replace(v_handle_downstream, '_', '.') || '@sitebin.referral-test.invalid',
      pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp(), false, false);

  INSERT INTO public.profiles(id, user_handle, app_install_id, available_coins, lifetime_earned)
  VALUES
    (v_inviter, v_handle_inviter, 'inst_ref_test_' || replace(v_inviter::text, '-', ''), 100, 0),
    (v_invitee, v_handle_invitee, 'inst_ref_test_' || replace(v_invitee::text, '-', ''), 100, 0),
    (v_downstream, v_handle_downstream, 'inst_ref_test_' || replace(v_downstream::text, '-', ''), 100, 0);

  SELECT c.id, c.owner_id, c.referral_site_key
  INTO v_campaign_id, v_campaign_owner, v_campaign_key
  FROM public.campaigns c
  WHERE c.referral_site_key IS NOT NULL
    AND c.owner_id NOT IN (v_inviter, v_invitee, v_downstream)
  ORDER BY c.id
  LIMIT 1;

  SELECT c.id, c.owner_id, c.referral_site_key
  INTO v_campaign2_id, v_campaign2_owner, v_campaign2_key
  FROM public.campaigns c
  WHERE c.referral_site_key IS NOT NULL
    AND c.referral_site_key <> v_campaign_key
    AND c.owner_id NOT IN (v_inviter, v_invitee, v_downstream)
  ORDER BY c.id
  LIMIT 1;

  IF v_campaign_id IS NULL OR v_campaign2_id IS NULL THEN
    RAISE EXCEPTION 'TEST_SETUP_FAILED: at least two campaigns on distinct registered websites are required';
  END IF;

  -- Self-referral must be rejected without creating a relationship.
  PERFORM pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_invitee::text, 'role', 'authenticated', 'is_anonymous', false
    )::text,
    true
  );
  v_result := public.register_referral(v_handle_invitee);
  IF COALESCE((v_result->>'success')::boolean, false)
     OR v_result->>'code' <> 'SELF_REFERRAL' THEN
    RAISE EXCEPTION 'TEST_FAILED: self-referral was not rejected: %', v_result;
  END IF;

  -- The first test call consumes the dedicated rate-limit slot. Reset only this
  -- synthetic user's temporary bucket inside this rollback-only fixture.
  UPDATE private.rate_limit_buckets
  SET ten_second_started_at = pg_catalog.clock_timestamp() - INTERVAL '11 seconds',
      ten_second_count = 0,
      minute_started_at = pg_catalog.clock_timestamp() - INTERVAL '61 seconds',
      minute_count = 0,
      five_minute_started_at = pg_catalog.clock_timestamp() - INTERVAL '301 seconds',
      five_minute_count = 0,
      hour_started_at = pg_catalog.clock_timestamp() - INTERVAL '3601 seconds',
      hour_count = 0,
      blocked_until = NULL
  WHERE user_id = v_invitee AND action = 'register_referral';

  v_result := public.register_referral(v_handle_inviter);
  IF NOT COALESCE((v_result->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'TEST_FAILED: valid referral did not register: %', v_result;
  END IF;

  SELECT r.id, r.created_at
  INTO v_referral_id, v_referral_created_at
  FROM public.referrals r
  WHERE r.invitee_id = v_invitee AND r.inviter_id = v_inviter;

  IF v_referral_id IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: registered direct referral row is missing';
  END IF;

  IF (SELECT pg_catalog.count(*) FROM private.referral_notification_outbox
      WHERE referral_id = v_referral_id AND event_type = 'REFERRAL_REGISTERED'
        AND actor_id = v_invitee AND recipient_id = v_inviter) <> 1 THEN
    RAISE EXCEPTION 'TEST_FAILED: referral registration outbox event must be created once for the direct inviter';
  END IF;

  -- Registering again cannot change the direct inviter or make a second event.
  UPDATE private.rate_limit_buckets
  SET ten_second_started_at = pg_catalog.clock_timestamp() - INTERVAL '11 seconds',
      ten_second_count = 0,
      minute_started_at = pg_catalog.clock_timestamp() - INTERVAL '61 seconds',
      minute_count = 0,
      five_minute_started_at = pg_catalog.clock_timestamp() - INTERVAL '301 seconds',
      five_minute_count = 0,
      hour_started_at = pg_catalog.clock_timestamp() - INTERVAL '3601 seconds',
      hour_count = 0,
      blocked_until = NULL
  WHERE user_id = v_invitee AND action = 'register_referral';

  v_result := public.register_referral(v_handle_inviter);
  IF COALESCE((v_result->>'success')::boolean, false)
     OR v_result->>'code' <> 'ALREADY_REGISTERED' THEN
    RAISE EXCEPTION 'TEST_FAILED: second invite registration was not rejected: %', v_result;
  END IF;
  IF (SELECT pg_catalog.count(*) FROM public.referrals WHERE invitee_id = v_invitee) <> 1 THEN
    RAISE EXCEPTION 'TEST_FAILED: invitee must have exactly one inviter';
  END IF;

  -- A view whose session began before the referral was created must not count.
  INSERT INTO public.view_sessions(
    campaign_id, viewer_id, required_duration_seconds, reward_coins,
    status, started_at, content_ready_at
  )
  VALUES(
    v_campaign2_id, v_invitee, 5, 3, 'CONTENT_READY',
    v_referral_created_at - INTERVAL '1 second', v_referral_created_at - INTERVAL '1 second'
  )
  RETURNING id INTO v_session_id;

  UPDATE public.view_sessions
  SET status = 'COMPLETED', completed_at = pg_catalog.clock_timestamp()
  WHERE id = v_session_id;

  -- Campaigns owned by the invitee or their direct inviter do not count toward
  -- either milestone, even if the WebView/session status is otherwise valid.
  UPDATE public.campaigns SET owner_id = v_inviter WHERE id = v_campaign_id;

  INSERT INTO public.view_sessions(
    campaign_id, viewer_id, required_duration_seconds, reward_coins,
    status, started_at, content_ready_at
  )
  VALUES(
    v_campaign_id, v_invitee, 5, 3, 'CONTENT_READY',
    pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
  )
  RETURNING id INTO v_session_id;

  UPDATE public.view_sessions
  SET status = 'COMPLETED', completed_at = pg_catalog.clock_timestamp()
  WHERE id = v_session_id;

  UPDATE public.campaigns SET owner_id = v_campaign_owner WHERE id = v_campaign_id;

  SELECT completed_views_count INTO v_count
  FROM public.referrals WHERE id = v_referral_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST_FAILED: pre-referral and inviter-owned sessions must not count; got %', v_count;
  END IF;

  -- 100 distinct, server-recorded completion transitions on one registrable
  -- site satisfy the 100-view reward but must not satisfy the 500-site reward.
  FOR i IN 1..100 LOOP
    INSERT INTO public.view_sessions(
      campaign_id, viewer_id, required_duration_seconds, reward_coins,
      status, started_at, content_ready_at
    )
    VALUES(
      v_campaign_id, v_invitee, 5, 3, 'CONTENT_READY',
      GREATEST(pg_catalog.clock_timestamp(), v_referral_created_at + INTERVAL '1 microsecond'),
      pg_catalog.clock_timestamp()
    )
    RETURNING id INTO v_session_id;

    UPDATE public.view_sessions
    SET status = 'COMPLETED', completed_at = pg_catalog.clock_timestamp()
    WHERE id = v_session_id;
  END LOOP;

  SELECT completed_views_count, unique_websites_count, tier_100_paid_at IS NOT NULL,
         tier_500_paid_at IS NOT NULL
  INTO v_count, i, v_ledger_inviter, v_ledger_invitee
  FROM public.referrals WHERE id = v_referral_id;

  IF v_count <> 100 OR i <> 1 OR NOT v_ledger_inviter OR v_ledger_invitee THEN
    RAISE EXCEPTION 'TEST_FAILED: 100 views should pay only the first tier; views %, unique %, tier100 %, tier500 %',
      v_count, i, v_ledger_inviter, v_ledger_invitee;
  END IF;

  SELECT available_coins INTO v_balance_inviter FROM public.profiles WHERE id = v_inviter;
  SELECT available_coins INTO v_balance_invitee FROM public.profiles WHERE id = v_invitee;
  IF v_balance_inviter <> 600 OR v_balance_invitee <> 600 THEN
    RAISE EXCEPTION 'TEST_FAILED: tier-1 should credit exactly 500 coins to each direct party; inviter %, invitee %',
      v_balance_inviter, v_balance_invitee;
  END IF;

  IF (SELECT pg_catalog.count(*) FROM private.referral_reward_grants
      WHERE referral_id = v_referral_id AND milestone = 'VIEWS_100') <> 2 THEN
    RAISE EXCEPTION 'TEST_FAILED: first milestone must have exactly two grants';
  END IF;
  IF (SELECT pg_catalog.count(*) FROM public.coin_ledger
      WHERE user_id IN (v_inviter, v_invitee)
        AND transaction_type = 'REFERRAL_REWARD') <> 2 THEN
    RAISE EXCEPTION 'TEST_FAILED: first milestone ledger entries missing or duplicated';
  END IF;

  -- The invitee may invite another person, but that new person is a direct
  -- child only of the invitee. Force the internal threshold helper in this
  -- rollback-only test to verify that the upstream inviter receives nothing.
  PERFORM pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_downstream::text, 'role', 'authenticated', 'is_anonymous', false
    )::text,
    true
  );
  v_result := public.register_referral(v_handle_invitee);
  IF NOT COALESCE((v_result->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'TEST_FAILED: downstream direct referral did not register: %', v_result;
  END IF;

  SELECT id INTO v_downstream_referral_id
  FROM public.referrals WHERE inviter_id = v_invitee AND invitee_id = v_downstream;

  UPDATE public.referrals
  SET completed_views_count = 100
  WHERE id = v_downstream_referral_id;
  PERFORM private.award_referral_milestone(v_downstream_referral_id, 'VIEWS_100');

  SELECT available_coins INTO v_balance_inviter FROM public.profiles WHERE id = v_inviter;
  SELECT available_coins INTO v_balance_invitee FROM public.profiles WHERE id = v_invitee;
  SELECT available_coins INTO v_balance_downstream FROM public.profiles WHERE id = v_downstream;
  IF v_balance_inviter <> 600 OR v_balance_invitee <> 1100 OR v_balance_downstream <> 600 THEN
    RAISE EXCEPTION 'TEST_FAILED: one-level payout leaked upstream; balances inviter %, invitee %, downstream %',
      v_balance_inviter, v_balance_invitee, v_balance_downstream;
  END IF;

  -- Seed 498 synthetic distinct sites in addition to the actual first site,
  -- placing only this fixture at 499. The next unique-site completion must
  -- atomically trigger the extra 25,000 coins for each direct party.
  INSERT INTO private.referral_website_progress(
    referral_id, website_key, first_view_session_id, first_completed_at
  )
  SELECT
    v_referral_id,
    'site-' || g::text || '.invalid',
    gen_random_uuid(),
    pg_catalog.clock_timestamp()
  FROM pg_catalog.generate_series(1, 498) AS g;

  UPDATE public.referrals
  SET completed_views_count = 499,
      unique_websites_count = 499
  WHERE id = v_referral_id;

  INSERT INTO public.view_sessions(
    campaign_id, viewer_id, required_duration_seconds, reward_coins,
    status, started_at, content_ready_at
  )
  VALUES(
    v_campaign2_id, v_invitee, 5, 3, 'CONTENT_READY',
    GREATEST(pg_catalog.clock_timestamp(), v_referral_created_at + INTERVAL '1 microsecond'),
    pg_catalog.clock_timestamp()
  )
  RETURNING id INTO v_session_id;

  UPDATE public.view_sessions
  SET status = 'COMPLETED', completed_at = pg_catalog.clock_timestamp()
  WHERE id = v_session_id;

  IF NOT EXISTS (
    SELECT 1 FROM public.referrals
    WHERE id = v_referral_id
      AND completed_views_count = 500
      AND unique_websites_count = 500
      AND tier_100_paid_at IS NOT NULL
      AND tier_500_paid_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: 500 unique registrable sites did not settle tier two';
  END IF;

  SELECT available_coins INTO v_balance_inviter FROM public.profiles WHERE id = v_inviter;
  SELECT available_coins INTO v_balance_invitee FROM public.profiles WHERE id = v_invitee;
  IF v_balance_inviter <> 25600 OR v_balance_invitee <> 26100 THEN
    RAISE EXCEPTION 'TEST_FAILED: tier-2 must add 25,000 coins to the direct pair only; inviter %, invitee %',
      v_balance_inviter, v_balance_invitee;
  END IF;

  SELECT pg_catalog.count(*) INTO v_ledger_inviter
  FROM private.referral_reward_grants
  WHERE recipient_id = v_inviter AND amount = 25000 AND referral_id = v_referral_id
    AND milestone = 'WEBSITES_500';
  SELECT pg_catalog.count(*) INTO v_ledger_invitee
  FROM private.referral_reward_grants
  WHERE recipient_id = v_invitee AND amount = 25000 AND referral_id = v_referral_id
    AND milestone = 'WEBSITES_500';
  IF v_ledger_inviter <> 1 OR v_ledger_invitee <> 1 THEN
    RAISE EXCEPTION 'TEST_FAILED: tier-2 reward grants are missing or duplicated';
  END IF;

  RAISE NOTICE 'PASS: referral registration, one-time binding, excluded views, direct-only payout, atomic tier-1/tier-2 grants';
END;
$referral_test$;

ROLLBACK;
