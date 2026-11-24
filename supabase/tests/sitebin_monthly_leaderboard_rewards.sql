-- Monthly leaderboard reward settlement integration test.
-- Run after the monthly leaderboard migration on a disposable/transactional
-- database. Synthetic auth users, profiles, sessions, wallet mutations and
-- ledger entries are rolled back at the end.

BEGIN;

DO $monthly_reward_test$
DECLARE
  v_month_start date := DATE '2020-01-01';
  v_campaign_id uuid;
  v_user_ids uuid[] := ARRAY[
    gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
    gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
  ];
  v_handles text[] := ARRAY[
    'monthly_reward_a',
    'monthly_reward_b',
    'monthly_reward_c',
    'monthly_reward_d',
    'monthly_reward_e',
    'monthly_reward_f'
  ];
  v_view_counts integer[] := ARRAY[5, 5, 4, 3, 2, 1];
  v_hour_offsets integer[] := ARRAY[0, 1, 2, 3, 4, 5];
  v_expected_amounts bigint[] := ARRAY[20000, 15000, 10000, 7000, 5000, 0];
  v_expected_handles text[] := ARRAY[
    'monthly_reward_a',
    'monthly_reward_b',
    'monthly_reward_c',
    'monthly_reward_d',
    'monthly_reward_e'
  ];
  v_actual_handles text[];
  v_actual_amounts bigint[];
  v_result jsonb;
  v_retry_result jsonb;
  v_available bigint;
  v_lifetime_earned bigint;
  v_ledger_count integer;
  v_ledger_total bigint;
  v_i integer;
  v_j integer;
  v_completed_at timestamptz;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.campaigns
  ) THEN
    RAISE EXCEPTION 'TEST_SETUP_FAILED: at least one campaign is required';
  END IF;

  SELECT c.id
    INTO v_campaign_id
  FROM public.campaigns c
  ORDER BY c.created_at, c.id
  LIMIT 1;

  IF EXISTS (
    SELECT 1
    FROM public.view_sessions vs
    WHERE vs.status = 'COMPLETED'
      AND vs.completed_at >= (v_month_start::timestamp AT TIME ZONE 'UTC')
      AND vs.completed_at < ((v_month_start + INTERVAL '1 month')::timestamp AT TIME ZONE 'UTC')
  ) THEN
    RAISE EXCEPTION 'TEST_SETUP_FAILED: selected historical month is not empty';
  END IF;

  UPDATE private.monthly_leaderboard_config
  SET first_eligible_month = v_month_start
  WHERE singleton = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_SETUP_FAILED: monthly reward config is missing';
  END IF;

  FOR v_i IN 1..6 LOOP
    INSERT INTO auth.users (
      id,
      aud,
      role,
      email,
      email_confirmed_at,
      created_at,
      updated_at,
      is_sso_user,
      is_anonymous
    )
    VALUES (
      v_user_ids[v_i],
      'authenticated',
      'authenticated',
      v_handles[v_i] || '@monthly-reward-test.invalid',
      pg_catalog.clock_timestamp(),
      pg_catalog.clock_timestamp(),
      pg_catalog.clock_timestamp(),
      false,
      false
    );

    INSERT INTO public.profiles (
      id,
      user_handle,
      app_install_id,
      available_coins,
      lifetime_earned
    )
    VALUES (
      v_user_ids[v_i],
      v_handles[v_i],
      'monthly_reward_test_' || v_i::text || '_' ||
        pg_catalog.substr(pg_catalog.replace(v_user_ids[v_i]::text, '-', ''), 1, 12),
      100,
      25
    );

    FOR v_j IN 1..v_view_counts[v_i] LOOP
      v_completed_at :=
        (TIMESTAMP '2020-01-02 00:00:00'
          + (v_hour_offsets[v_i] * INTERVAL '1 hour')
          + (v_j * INTERVAL '1 minute'))
        AT TIME ZONE 'UTC';

      INSERT INTO public.view_sessions (
        campaign_id,
        viewer_id,
        required_duration_seconds,
        reward_coins,
        status,
        started_at,
        content_ready_at,
        completed_at
      )
      VALUES (
        v_campaign_id,
        v_user_ids[v_i],
        5,
        3,
        'COMPLETED',
        v_completed_at,
        v_completed_at,
        v_completed_at
      );
    END LOOP;
  END LOOP;

  v_result :=
    private.settle_monthly_leaderboard_rewards_for_month(v_month_start);

  IF COALESCE((v_result ->> 'already_settled')::boolean, true)
     OR COALESCE((v_result ->> 'winner_count')::integer, 0) <> 5
     OR COALESCE((v_result ->> 'total_coins')::bigint, 0) <> 57000 THEN
    RAISE EXCEPTION 'TEST_FAILED: settlement result mismatch: %', v_result;
  END IF;

  SELECT
    pg_catalog.array_agg(g.user_handle_snapshot ORDER BY g.rank),
    pg_catalog.array_agg(g.amount ORDER BY g.rank)
  INTO v_actual_handles, v_actual_amounts
  FROM private.monthly_leaderboard_reward_grants g
  WHERE g.month_start = v_month_start;

  IF v_actual_handles <> v_expected_handles
     OR v_actual_amounts <> v_expected_amounts[1:5] THEN
    RAISE EXCEPTION 'TEST_FAILED: rank/tie-break/prize mismatch: handles %, amounts %',
      v_actual_handles, v_actual_amounts;
  END IF;

  SELECT pg_catalog.count(*)::integer, COALESCE(pg_catalog.sum(l.amount), 0)::bigint
    INTO v_ledger_count, v_ledger_total
  FROM public.coin_ledger l
  WHERE l.user_id = ANY(v_user_ids)
    AND l.transaction_type = 'MONTHLY_LEADERBOARD_REWARD';

  IF v_ledger_count <> 5 OR v_ledger_total <> 57000 THEN
    RAISE EXCEPTION 'TEST_FAILED: ledger count/total mismatch: %, %',
      v_ledger_count, v_ledger_total;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM private.monthly_leaderboard_reward_grants g
    WHERE g.month_start = v_month_start
      AND g.ledger_entry_id IS NULL
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: a reward grant has no linked ledger row';
  END IF;

  FOR v_i IN 1..6 LOOP
    SELECT p.available_coins, p.lifetime_earned
      INTO v_available, v_lifetime_earned
    FROM public.profiles p
    WHERE p.id = v_user_ids[v_i];

    IF v_available <> 100 + v_expected_amounts[v_i]
       OR v_lifetime_earned <> 25 + v_expected_amounts[v_i] THEN
      RAISE EXCEPTION 'TEST_FAILED: wallet balance/lifetime total mismatch for %: %, %',
        v_handles[v_i], v_available, v_lifetime_earned;
    END IF;
  END LOOP;

  -- A replay must return the existing settlement without a second credit.
  v_retry_result :=
    private.settle_monthly_leaderboard_rewards_for_month(v_month_start);

  IF COALESCE((v_retry_result ->> 'already_settled')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: retry did not report already_settled: %', v_retry_result;
  END IF;

  SELECT pg_catalog.count(*)::integer, COALESCE(pg_catalog.sum(l.amount), 0)::bigint
    INTO v_ledger_count, v_ledger_total
  FROM public.coin_ledger l
  WHERE l.user_id = ANY(v_user_ids)
    AND l.transaction_type = 'MONTHLY_LEADERBOARD_REWARD';

  IF v_ledger_count <> 5 OR v_ledger_total <> 57000 THEN
    RAISE EXCEPTION 'TEST_FAILED: retry duplicated ledger payout: %, %',
      v_ledger_count, v_ledger_total;
  END IF;

  IF has_function_privilege(
       'anon',
       'private.settle_monthly_leaderboard_rewards_for_month(date)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'private.settle_monthly_leaderboard_rewards_for_month(date)',
       'EXECUTE'
     )
     OR has_table_privilege(
       'authenticated',
       'private.monthly_leaderboard_reward_grants',
       'SELECT'
     ) THEN
    RAISE EXCEPTION 'TEST_FAILED: monthly reward internals are exposed to client roles';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM cron.job j
    WHERE j.jobname = 'sitebin-monthly-leaderboard-rewards'
      AND j.active = true
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: monthly reward cron job is missing or inactive';
  END IF;

  RAISE NOTICE 'PASS: UTC month boundary, deterministic ranking, five prize tiers, atomic wallet/ledger credit, idempotent retry, private access and cron schedule';
END;
$monthly_reward_test$;

ROLLBACK;
