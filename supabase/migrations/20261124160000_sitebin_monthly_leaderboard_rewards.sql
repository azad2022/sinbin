BEGIN;

-- Monthly leaderboard rewards.
-- Period boundaries follow UTC, matching SiteBin's existing daily/weekly leaderboard buckets.
-- The first eligible period is the first complete UTC calendar month after this migration,
-- so historical activity is never paid retroactively.

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

GRANT USAGE ON SCHEMA cron TO postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA cron TO postgres;

ALTER TABLE public.coin_ledger
  DROP CONSTRAINT IF EXISTS coin_ledger_transaction_type_check;

ALTER TABLE public.coin_ledger
  ADD CONSTRAINT coin_ledger_transaction_type_check
  CHECK (
    transaction_type = ANY (ARRAY[
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
      'COIN_PURCHASE',
      'MONTHLY_LEADERBOARD_REWARD'
    ]::text[])
  );

CREATE TABLE IF NOT EXISTS private.monthly_leaderboard_config (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton IS TRUE),
  first_eligible_month date NOT NULL
    CHECK (
      first_eligible_month =
        pg_catalog.date_trunc('month', first_eligible_month::timestamp)::date
    ),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

INSERT INTO private.monthly_leaderboard_config (
  singleton,
  first_eligible_month
)
VALUES (
  true,
  (
    pg_catalog.date_trunc(
      'month',
      pg_catalog.clock_timestamp() AT TIME ZONE 'UTC'
    ) + INTERVAL '1 month'
  )::date
)
ON CONFLICT (singleton) DO NOTHING;

CREATE TABLE IF NOT EXISTS private.monthly_leaderboard_settlements (
  month_start date PRIMARY KEY
    CHECK (month_start = pg_catalog.date_trunc('month', month_start::timestamp)::date),
  month_end_exclusive date NOT NULL,
  winner_count smallint NOT NULL DEFAULT 0 CHECK (winner_count BETWEEN 0 AND 5),
  total_coins bigint NOT NULL DEFAULT 0 CHECK (total_coins >= 0),
  started_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  settled_at timestamptz,
  CONSTRAINT monthly_leaderboard_settlement_month_bounds
    CHECK (month_end_exclusive = (month_start + INTERVAL '1 month')::date)
);

CREATE TABLE IF NOT EXISTS private.monthly_leaderboard_reward_grants (
  month_start date NOT NULL
    REFERENCES private.monthly_leaderboard_settlements(month_start)
    ON DELETE RESTRICT,
  rank smallint NOT NULL CHECK (rank BETWEEN 1 AND 5),
  user_id uuid NOT NULL
    REFERENCES public.profiles(id)
    ON DELETE CASCADE,
  user_handle_snapshot text NOT NULL
    CHECK (pg_catalog.btrim(user_handle_snapshot) <> ''),
  completed_views integer NOT NULL CHECK (completed_views > 0),
  amount bigint NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  ledger_entry_id uuid UNIQUE
    REFERENCES public.coin_ledger(id)
    ON DELETE SET NULL,
  paid_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (month_start, rank),
  UNIQUE (month_start, user_id),
  CONSTRAINT monthly_leaderboard_reward_amount_by_rank
    CHECK (
      (rank = 1 AND amount = 20000)
      OR (rank = 2 AND amount = 15000)
      OR (rank = 3 AND amount = 10000)
      OR (rank = 4 AND amount = 7000)
      OR (rank = 5 AND amount = 5000)
    )
);

CREATE INDEX IF NOT EXISTS idx_monthly_leaderboard_reward_grants_user
  ON private.monthly_leaderboard_reward_grants (user_id, paid_at DESC);

CREATE INDEX IF NOT EXISTS idx_view_sessions_monthly_completed
  ON public.view_sessions (completed_at, viewer_id)
  WHERE status = 'COMPLETED' AND completed_at IS NOT NULL;

ALTER TABLE private.monthly_leaderboard_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.monthly_leaderboard_settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.monthly_leaderboard_reward_grants ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE private.monthly_leaderboard_config
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.monthly_leaderboard_settlements
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.monthly_leaderboard_reward_grants
  FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE private.monthly_leaderboard_settlements IS
  'Immutable one-time settlement record for each closed UTC calendar month.';
COMMENT ON TABLE private.monthly_leaderboard_reward_grants IS
  'Auditable monthly top-five coin awards; unique per month, rank, and recipient.';
COMMENT ON COLUMN private.monthly_leaderboard_config.first_eligible_month IS
  'First full UTC calendar month eligible for awards; prevents retroactive payouts.';

CREATE OR REPLACE FUNCTION private.settle_monthly_leaderboard_rewards_for_month(
  p_month_start date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_current_month date;
  v_first_eligible_month date;
  v_existing_settled_at timestamptz;
  v_month_end date;
  v_winner_snapshot jsonb;
  v_winner jsonb;
  v_winner_ids uuid[];
  v_winner_count smallint;
  v_locked_profile_count integer;
  v_total_coins bigint;
  v_user_id uuid;
  v_rank smallint;
  v_amount bigint;
  v_idempotency_key text;
  v_reference_id text;
  v_description text;
  v_ledger_entry_id uuid;
BEGIN
  IF p_month_start IS NULL
     OR p_month_start <>
       pg_catalog.date_trunc('month', p_month_start::timestamp)::date THEN
    RAISE EXCEPTION 'INVALID_MONTH_START: expected the first day of a UTC calendar month';
  END IF;

  v_current_month := pg_catalog.date_trunc(
    'month',
    pg_catalog.clock_timestamp() AT TIME ZONE 'UTC'
  )::date;

  IF p_month_start >= v_current_month THEN
    RAISE EXCEPTION 'MONTH_NOT_CLOSED: rewards can only be settled for a closed month';
  END IF;

  SELECT c.first_eligible_month
    INTO v_first_eligible_month
  FROM private.monthly_leaderboard_config c
  WHERE c.singleton = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MONTHLY_REWARD_CONFIG_MISSING';
  END IF;

  IF p_month_start < v_first_eligible_month THEN
    RAISE EXCEPTION 'MONTH_NOT_ELIGIBLE: historical months are not payable';
  END IF;

  -- Serialize settlement for this month, including manual retries.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'sitebin:monthly-leaderboard:' || p_month_start::text,
      0
    )
  );

  SELECT s.settled_at
    INTO v_existing_settled_at
  FROM private.monthly_leaderboard_settlements s
  WHERE s.month_start = p_month_start
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_settled_at IS NULL THEN
      RAISE EXCEPTION 'MONTHLY_REWARD_STATE_INCONSISTENT: unfinished settlement row exists';
    END IF;

    RETURN pg_catalog.jsonb_build_object(
      'month_start', p_month_start,
      'already_settled', true,
      'winner_count', (
        SELECT s.winner_count
        FROM private.monthly_leaderboard_settlements s
        WHERE s.month_start = p_month_start
      ),
      'total_coins', (
        SELECT s.total_coins
        FROM private.monthly_leaderboard_settlements s
        WHERE s.month_start = p_month_start
      )
    );
  END IF;

  v_month_end := (p_month_start + INTERVAL '1 month')::date;

  INSERT INTO private.monthly_leaderboard_settlements (
    month_start,
    month_end_exclusive
  )
  VALUES (
    p_month_start,
    v_month_end
  );

  -- Only server-recorded successful completions count.
  -- Ties go to the user who reached that final view count first;
  -- the immutable user UUID is the final deterministic tie-breaker.
  WITH ranked AS (
    SELECT
      vs.viewer_id AS user_id,
      p.user_handle,
      pg_catalog.count(*)::integer AS completed_views,
      pg_catalog.max(vs.completed_at) AS last_completed_at,
      pg_catalog.row_number() OVER (
        ORDER BY
          pg_catalog.count(*) DESC,
          pg_catalog.max(vs.completed_at) ASC,
          vs.viewer_id ASC
      )::integer AS reward_rank
    FROM public.view_sessions vs
    JOIN public.profiles p
      ON p.id = vs.viewer_id
    WHERE vs.status = 'COMPLETED'
      AND vs.completed_at >= (p_month_start::timestamp AT TIME ZONE 'UTC')
      AND vs.completed_at < (v_month_end::timestamp AT TIME ZONE 'UTC')
      AND pg_catalog.btrim(p.user_handle) <> ''
    GROUP BY vs.viewer_id, p.user_handle
  )
  SELECT COALESCE(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'rank', r.reward_rank,
        'user_id', r.user_id,
        'user_handle', r.user_handle,
        'completed_views', r.completed_views,
        'amount',
          CASE r.reward_rank
            WHEN 1 THEN 20000
            WHEN 2 THEN 15000
            WHEN 3 THEN 10000
            WHEN 4 THEN 7000
            WHEN 5 THEN 5000
          END
      )
      ORDER BY r.reward_rank
    ),
    '[]'::jsonb
  )
  INTO v_winner_snapshot
  FROM ranked r
  WHERE r.reward_rank <= 5;

  SELECT
    pg_catalog.jsonb_array_length(v_winner_snapshot)::smallint,
    COALESCE(
      pg_catalog.sum((winner.value ->> 'amount')::bigint),
      0
    )::bigint,
    COALESCE(
      pg_catalog.array_agg((winner.value ->> 'user_id')::uuid),
      ARRAY[]::uuid[]
    )
  INTO v_winner_count, v_total_coins, v_winner_ids
  FROM pg_catalog.jsonb_array_elements(v_winner_snapshot) AS winner(value);

  -- Lock all five (or fewer) wallets in UUID order to avoid deadlocks with
  -- other financial transactions. Wallet and ledger writes share this transaction.
  PERFORM p.id
  FROM public.profiles p
  WHERE p.id = ANY(v_winner_ids)
  ORDER BY p.id
  FOR UPDATE;

  SELECT pg_catalog.count(*)::integer
    INTO v_locked_profile_count
  FROM public.profiles p
  WHERE p.id = ANY(v_winner_ids);

  IF v_locked_profile_count <> v_winner_count THEN
    RAISE EXCEPTION 'MONTHLY_REWARD_RECIPIENT_MISSING: a ranked wallet disappeared';
  END IF;

  FOR v_winner IN
    SELECT item.value
    FROM pg_catalog.jsonb_array_elements(v_winner_snapshot)
      WITH ORDINALITY AS item(value, ordinality)
    ORDER BY item.ordinality
  LOOP
    v_user_id := (v_winner ->> 'user_id')::uuid;
    v_rank := (v_winner ->> 'rank')::smallint;
    v_amount := (v_winner ->> 'amount')::bigint;

    v_idempotency_key :=
      'monthly_leaderboard_' ||
      pg_catalog.to_char(p_month_start, 'YYYYMM') ||
      '_rank_' || v_rank::text ||
      '_user_' || v_user_id::text;

    v_reference_id :=
      'monthly_leaderboard:' ||
      pg_catalog.to_char(p_month_start, 'YYYY-MM') ||
      ':rank:' || v_rank::text;

    v_description :=
      'جایزه رتبه ' || v_rank::text ||
      ' جدول بازدید ماهانه ' ||
      pg_catalog.to_char(p_month_start, 'YYYY-MM');

    INSERT INTO private.monthly_leaderboard_reward_grants (
      month_start,
      rank,
      user_id,
      user_handle_snapshot,
      completed_views,
      amount,
      idempotency_key
    )
    VALUES (
      p_month_start,
      v_rank,
      v_user_id,
      v_winner ->> 'user_handle',
      (v_winner ->> 'completed_views')::integer,
      v_amount,
      v_idempotency_key
    );

    UPDATE public.profiles
    SET available_coins = available_coins + v_amount,
        lifetime_earned = lifetime_earned + v_amount,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_user_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'MONTHLY_REWARD_RECIPIENT_MISSING: wallet update affected no row';
    END IF;

    INSERT INTO public.coin_ledger (
      user_id,
      amount,
      transaction_type,
      description,
      reference_id,
      idempotency_key,
      created_at
    )
    VALUES (
      v_user_id,
      v_amount,
      'MONTHLY_LEADERBOARD_REWARD',
      v_description,
      v_reference_id,
      v_idempotency_key,
      pg_catalog.clock_timestamp()
    )
    RETURNING id INTO v_ledger_entry_id;

    UPDATE private.monthly_leaderboard_reward_grants
    SET ledger_entry_id = v_ledger_entry_id
    WHERE month_start = p_month_start
      AND rank = v_rank;
  END LOOP;

  UPDATE private.monthly_leaderboard_settlements
  SET winner_count = v_winner_count,
      total_coins = v_total_coins,
      settled_at = pg_catalog.clock_timestamp()
  WHERE month_start = p_month_start;

  RETURN pg_catalog.jsonb_build_object(
    'month_start', p_month_start,
    'already_settled', false,
    'winner_count', v_winner_count,
    'total_coins', v_total_coins
  );
END;
$function$;

CREATE OR REPLACE FUNCTION private.process_due_monthly_leaderboard_rewards()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_first_eligible_month date;
  v_current_month date;
  v_month_start date;
  v_settled_at timestamptz;
  v_month_result jsonb;
  v_processed_months integer := 0;
  v_total_paid bigint := 0;
BEGIN
  -- A single processor lock prevents overlapping daily cron/manual invocations.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('sitebin:monthly-leaderboard:processor', 0)
  );

  SELECT c.first_eligible_month
    INTO v_first_eligible_month
  FROM private.monthly_leaderboard_config c
  WHERE c.singleton = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MONTHLY_REWARD_CONFIG_MISSING';
  END IF;

  v_current_month := pg_catalog.date_trunc(
    'month',
    pg_catalog.clock_timestamp() AT TIME ZONE 'UTC'
  )::date;

  v_month_start := v_first_eligible_month;

  -- Daily execution also provides automatic recovery if a previous monthly
  -- settlement failed: every unprocessed closed month is retried in order.
  WHILE v_month_start < v_current_month LOOP
    SELECT s.settled_at
      INTO v_settled_at
    FROM private.monthly_leaderboard_settlements s
    WHERE s.month_start = v_month_start;

    IF NOT FOUND OR v_settled_at IS NULL THEN
      v_month_result :=
        private.settle_monthly_leaderboard_rewards_for_month(v_month_start);

      v_processed_months := v_processed_months + 1;
      v_total_paid := v_total_paid +
        COALESCE((v_month_result ->> 'total_coins')::bigint, 0);
    END IF;

    v_month_start := (v_month_start + INTERVAL '1 month')::date;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'processed_months', v_processed_months,
    'total_coins_paid', v_total_paid,
    'first_eligible_month', v_first_eligible_month,
    'checked_at', pg_catalog.clock_timestamp()
  );
END;
$function$;

REVOKE ALL ON FUNCTION private.settle_monthly_leaderboard_rewards_for_month(date)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.process_due_monthly_leaderboard_rewards()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION private.process_due_monthly_leaderboard_rewards()
  TO postgres;

-- Run daily at 00:15 UTC. The processor itself enforces UTC month closure,
-- is idempotent, and retries any missed closed month on the next invocation.
SELECT cron.schedule(
  'sitebin-monthly-leaderboard-rewards',
  '15 0 * * *',
  'SELECT private.process_due_monthly_leaderboard_rewards();'
);

COMMIT;
