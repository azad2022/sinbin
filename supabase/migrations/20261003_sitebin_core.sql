-- ==============================================================================
-- SiteBin — Server-Authoritative Architecture Migration
-- PostgreSQL / Supabase Schema, Invariants, RLS, and Hardened RPC Functions
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Duration & Pricing Matrix (Server-Authoritative Pricing)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.duration_pricing (
    duration_seconds INT PRIMARY KEY,
    advertiser_cost BIGINT NOT NULL CHECK (advertiser_cost > 0),
    viewer_reward BIGINT NOT NULL CHECK (viewer_reward > 0),
    is_popular BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT chk_pricing_economics CHECK (advertiser_cost >= viewer_reward)
);

INSERT INTO public.duration_pricing (duration_seconds, advertiser_cost, viewer_reward, is_popular)
VALUES
    (5, 5, 3, FALSE),
    (10, 9, 6, FALSE),
    (15, 14, 10, TRUE),
    (30, 26, 19, FALSE),
    (60, 50, 38, FALSE)
ON CONFLICT (duration_seconds) DO UPDATE SET
    advertiser_cost = EXCLUDED.advertiser_cost,
    viewer_reward = EXCLUDED.viewer_reward,
    is_popular = EXCLUDED.is_popular;

-- ------------------------------------------------------------------------------
-- 2. User Profiles (Linked to auth.users)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    user_handle TEXT UNIQUE NOT NULL,
    app_install_id TEXT,
    available_coins BIGINT NOT NULL DEFAULT 0 CHECK (available_coins >= 0),
    reserved_coins BIGINT NOT NULL DEFAULT 0 CHECK (reserved_coins >= 0),
    lifetime_earned BIGINT NOT NULL DEFAULT 0 CHECK (lifetime_earned >= 0),
    lifetime_spent BIGINT NOT NULL DEFAULT 0 CHECK (lifetime_spent >= 0),
    trust_score REAL NOT NULL DEFAULT 100.0,
    completed_views_count INTEGER NOT NULL DEFAULT 0 CHECK (completed_views_count >= 0),
    received_views_count INTEGER NOT NULL DEFAULT 0 CHECK (received_views_count >= 0),
    welcome_bonus_claimed BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now()
);

-- Structural constraint: a non-null installation ID can belong to at most one profile
CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_app_install_id 
    ON public.profiles (app_install_id) 
    WHERE app_install_id IS NOT NULL;

-- ------------------------------------------------------------------------------
-- 3. Welcome Bonus Grants (Server-Side Anti-Farming & Replay Prevention)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.welcome_bonus_grants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID UNIQUE NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    install_id TEXT,
    amount BIGINT NOT NULL CHECK (amount > 0),
    granted_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now()
);

-- Structural constraint: a non-null installation ID can receive at most one welcome bonus grant across all accounts
CREATE UNIQUE INDEX IF NOT EXISTS idx_welcome_bonus_grants_install_id 
    ON public.welcome_bonus_grants (install_id) 
    WHERE install_id IS NOT NULL;

-- ------------------------------------------------------------------------------
-- 4. Campaigns (Server-Authoritative Budget & Delivery)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.campaigns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    url TEXT NOT NULL,
    normalized_url TEXT NOT NULL,
    domain TEXT NOT NULL,
    duration_seconds INT NOT NULL REFERENCES public.duration_pricing(duration_seconds),
    target_views INT NOT NULL CHECK (target_views > 0),
    completed_views INT NOT NULL DEFAULT 0 CHECK (completed_views >= 0),
    cost_per_view BIGINT NOT NULL CHECK (cost_per_view > 0),
    total_budget BIGINT NOT NULL CHECK (total_budget > 0),
    spent_budget BIGINT NOT NULL DEFAULT 0 CHECK (spent_budget >= 0),
    reserved_budget BIGINT NOT NULL DEFAULT 0 CHECK (reserved_budget >= 0),
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'PAUSED', 'COMPLETED', 'CANCELLED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now(),
    CONSTRAINT chk_campaign_views_bound CHECK (completed_views <= target_views),
    CONSTRAINT chk_campaign_budget_bound CHECK (spent_budget + reserved_budget <= total_budget),
    CONSTRAINT chk_campaign_total_calc CHECK (total_budget = cost_per_view * target_views)
);

CREATE INDEX IF NOT EXISTS idx_campaigns_status_budget 
    ON public.campaigns (status, reserved_budget) 
    WHERE status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_campaigns_owner 
    ON public.campaigns (owner_id, created_at DESC);

-- ------------------------------------------------------------------------------
-- 5. View Sessions (Server-Controlled Validation & Duplicate Prevention)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.view_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
    viewer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    required_duration_seconds INT NOT NULL CHECK (required_duration_seconds > 0),
    reward_coins BIGINT NOT NULL CHECK (reward_coins > 0),
    status TEXT NOT NULL DEFAULT 'INITIALIZED' CHECK (status IN ('INITIALIZED', 'CONTENT_READY', 'COMPLETED', 'EXPIRED', 'CANCELLED')),
    started_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now(),
    content_ready_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    idempotency_key TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now()
);

-- Structural constraint: a viewer can have at most ONE active session in INITIALIZED or CONTENT_READY
CREATE UNIQUE INDEX IF NOT EXISTS idx_view_sessions_active_viewer 
    ON public.view_sessions (viewer_id) 
    WHERE status IN ('INITIALIZED', 'CONTENT_READY');

-- Structural constraint: unique non-null idempotency key for completed sessions
CREATE UNIQUE INDEX IF NOT EXISTS idx_view_sessions_idempotency_key 
    ON public.view_sessions (idempotency_key) 
    WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_view_sessions_viewer_campaign 
    ON public.view_sessions (viewer_id, campaign_id, status);

-- ------------------------------------------------------------------------------
-- 6. Financial Transaction Ledger / Audit Ledger
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.coin_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    amount BIGINT NOT NULL CHECK (amount <> 0),
    transaction_type TEXT NOT NULL CHECK (transaction_type IN ('WELCOME_REWARD', 'VIEW_REWARD', 'CAMPAIGN_RESERVATION', 'CAMPAIGN_SPEND', 'CAMPAIGN_REFUND', 'REFERRAL_REWARD')),
    description TEXT NOT NULL,
    reference_id TEXT,
    idempotency_key TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now()
);

-- Structural constraint: unique non-null idempotency key per ledger transaction
CREATE UNIQUE INDEX IF NOT EXISTS idx_coin_ledger_idempotency_key 
    ON public.coin_ledger (idempotency_key) 
    WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_coin_ledger_user 
    ON public.coin_ledger (user_id, created_at DESC);

-- ==============================================================================
-- Row Level Security (RLS) Policies
-- Explicit roles (authenticated / anon).
-- Client has ZERO direct mutation permissions; only SELECT permitted data.
-- ==============================================================================

ALTER TABLE public.duration_pricing ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read pricing" ON public.duration_pricing
    FOR SELECT TO authenticated, anon
    USING (true);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own profile" ON public.profiles
    FOR SELECT TO authenticated
    USING ((select auth.uid()) = id);

ALTER TABLE public.welcome_bonus_grants ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own welcome grant" ON public.welcome_bonus_grants
    FOR SELECT TO authenticated
    USING ((select auth.uid()) = user_id);

ALTER TABLE public.campaigns ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own or active campaigns" ON public.campaigns
    FOR SELECT TO authenticated
    USING ((select auth.uid()) = owner_id OR status = 'ACTIVE');

ALTER TABLE public.view_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own view sessions" ON public.view_sessions
    FOR SELECT TO authenticated
    USING ((select auth.uid()) = viewer_id);

ALTER TABLE public.coin_ledger ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own ledger entries" ON public.coin_ledger
    FOR SELECT TO authenticated
    USING ((select auth.uid()) = user_id);

-- ==============================================================================
-- Server-Authoritative Hardened RPC Database Functions
-- Hardening:
-- - SECURITY DEFINER
-- - SET search_path = '' (deterministic qualification)
-- - Explicit (select auth.uid()) authorization verification
-- - Transactional locks, state validations, and financial invariants
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Initialize Account & Grant Exactly One Welcome Bonus
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.init_user_account(p_install_id TEXT, p_handle TEXT DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid UUID := (select auth.uid());
    v_profile RECORD;
    v_bonus_amount BIGINT := 150;
    v_handle TEXT;
    v_clean_install TEXT;
    v_existing_grant_user UUID;
    v_existing_profile_user UUID;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    -- Clean install ID (null if empty or blank)
    v_clean_install := pg_catalog.nullif(pg_catalog.trim(p_install_id), '');

    -- Concurrency control: acquire advisory lock on installation identifier if provided
    IF v_clean_install IS NOT NULL THEN
        PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('install_' || v_clean_install));

        -- Anti-Farming check: verify install_id is not already linked to another user account
        SELECT user_id INTO v_existing_grant_user 
        FROM public.welcome_bonus_grants 
        WHERE install_id = v_clean_install;

        IF v_existing_grant_user IS NOT NULL AND v_existing_grant_user != v_uid THEN
            RAISE EXCEPTION 'INSTALL_ALREADY_REGISTERED: Installation identifier is already associated with another account';
        END IF;

        SELECT id INTO v_existing_profile_user 
        FROM public.profiles 
        WHERE app_install_id = v_clean_install;

        IF v_existing_profile_user IS NOT NULL AND v_existing_profile_user != v_uid THEN
            RAISE EXCEPTION 'INSTALL_ALREADY_REGISTERED: Installation identifier is already associated with another account';
        END IF;
    END IF;

    -- Concurrency control: acquire user-level advisory lock
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('user_init_' || v_uid::text));

    -- Check if user profile already exists
    SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid FOR UPDATE;

    IF v_profile IS NULL THEN
        -- Generate default handle if not provided
        v_handle := pg_catalog.coalesce(
            pg_catalog.nullif(pg_catalog.trim(p_handle), ''),
            'user_' || pg_catalog.substring(v_uid::text, 1, 8)
        );

        -- Check if welcome grant already recorded for this user_id
        IF EXISTS (SELECT 1 FROM public.welcome_bonus_grants WHERE user_id = v_uid) THEN
            v_bonus_amount := 0;
        END IF;

        -- Create new profile atomically
        INSERT INTO public.profiles (
            id, user_handle, app_install_id, available_coins, reserved_coins,
            lifetime_earned, lifetime_spent, trust_score, completed_views_count,
            received_views_count, welcome_bonus_claimed, created_at, updated_at
        ) VALUES (
            v_uid, v_handle, v_clean_install, v_bonus_amount, 0,
            v_bonus_amount, 0, 100.0, 0,
            0, (v_bonus_amount > 0), pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
        )
        RETURNING * INTO v_profile;

        -- Record welcome grant if eligible
        IF v_bonus_amount > 0 THEN
            INSERT INTO public.welcome_bonus_grants (user_id, install_id, amount, granted_at)
            VALUES (v_uid, v_clean_install, v_bonus_amount, pg_catalog.clock_timestamp());

            -- Record in financial transaction audit ledger
            INSERT INTO public.coin_ledger (
                user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
            ) VALUES (
                v_uid, v_bonus_amount, 'WELCOME_REWARD',
                'هدیه ورود به سایت بین (Welcome Bonus)', 'init_bonus',
                'welcome_' || v_uid::text, pg_catalog.clock_timestamp()
            );
        END IF;
    END IF;

    RETURN pg_catalog.row_to_json(v_profile);
END;
$$;

-- ------------------------------------------------------------------------------
-- 2. Create Campaign (Atomic Server-Side Pricing, Validation & Budget Reservation)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_campaign(
    p_url TEXT,
    p_normalized_url TEXT,
    p_domain TEXT,
    p_duration_seconds INT,
    p_target_views INT
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid UUID := (select auth.uid());
    v_price RECORD;
    v_total_cost BIGINT;
    v_profile RECORD;
    v_new_campaign RECORD;
    v_clean_url TEXT;
    v_clean_normalized TEXT;
    v_clean_domain TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    -- URL and Domain Sanity Validation
    v_clean_url := pg_catalog.trim(p_url);
    v_clean_normalized := pg_catalog.trim(p_normalized_url);
    v_clean_domain := pg_catalog.trim(p_domain);

    IF v_clean_url IS NULL OR pg_catalog.length(v_clean_url) = 0 OR pg_catalog.length(v_clean_url) > 2048 
       OR (v_clean_url NOT LIKE 'https://%' AND v_clean_url NOT LIKE 'http://%') THEN
        RAISE EXCEPTION 'INVALID_URL: Target URL must be a valid HTTP/HTTPS address up to 2048 characters';
    END IF;

    IF v_clean_normalized IS NULL OR pg_catalog.length(v_clean_normalized) = 0 OR pg_catalog.length(v_clean_normalized) > 2048 THEN
        RAISE EXCEPTION 'INVALID_NORMALIZED_URL: Normalized URL cannot be empty';
    END IF;

    IF v_clean_domain IS NULL OR pg_catalog.length(v_clean_domain) = 0 OR pg_catalog.length(v_clean_domain) > 253 
       OR v_clean_domain LIKE '%/%' OR v_clean_domain LIKE '% %' THEN
        RAISE EXCEPTION 'INVALID_DOMAIN: Domain must be a valid hostname without slashes or whitespace';
    END IF;

    IF p_target_views <= 0 OR p_target_views > 1000000 THEN
        RAISE EXCEPTION 'INVALID_TARGET_VIEWS: Target views must be between 1 and 1,000,000';
    END IF;

    -- Lookup server-authoritative pricing (never trusts client pricing)
    SELECT * INTO v_price 
    FROM public.duration_pricing 
    WHERE duration_seconds = p_duration_seconds;

    IF v_price IS NULL THEN
        RAISE EXCEPTION 'INVALID_DURATION: Unsupported duration option';
    END IF;

    v_total_cost := v_price.advertiser_cost * p_target_views;

    -- Lock profile row for update to prevent concurrent overspending
    SELECT * INTO v_profile 
    FROM public.profiles 
    WHERE id = v_uid 
    FOR UPDATE;

    IF v_profile IS NULL THEN
        RAISE EXCEPTION 'PROFILE_NOT_FOUND: User profile does not exist';
    END IF;

    IF v_profile.available_coins < v_total_cost THEN
        RAISE EXCEPTION 'INSUFFICIENT_BALANCE: Available balance (% coins) is less than required budget (% coins)', v_profile.available_coins, v_total_cost;
    END IF;

    -- Atomic balance reservation
    UPDATE public.profiles
    SET available_coins = available_coins - v_total_cost,
        reserved_coins = reserved_coins + v_total_cost,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_uid;

    -- Create campaign record
    INSERT INTO public.campaigns (
        owner_id, url, normalized_url, domain, duration_seconds, target_views,
        completed_views, cost_per_view, total_budget, spent_budget, reserved_budget, status,
        created_at, updated_at
    ) VALUES (
        v_uid, v_clean_url, v_clean_normalized, v_clean_domain, p_duration_seconds, p_target_views,
        0, v_price.advertiser_cost, v_total_cost, 0, v_total_cost, 'ACTIVE',
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    RETURNING * INTO v_new_campaign;

    -- Record reservation in financial audit ledger
    INSERT INTO public.coin_ledger (
        user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
    ) VALUES (
        v_uid, -v_total_cost, 'CAMPAIGN_RESERVATION',
        'رزرو بودجه برای سفارش ' || p_target_views || ' بازدید از ' || v_clean_domain,
        v_new_campaign.id::text, 'camp_res_' || v_new_campaign.id::text, pg_catalog.clock_timestamp()
    );

    RETURN pg_catalog.row_to_json(v_new_campaign);
END;
$$;

-- ------------------------------------------------------------------------------
-- 3. Request View Session (Advisory Lock, Anti-Self View & Cooldown)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_view_session()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid UUID := (select auth.uid());
    v_campaign RECORD;
    v_price RECORD;
    v_existing_active RECORD;
    v_new_session RECORD;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    -- Concurrency control: prevent simultaneous requests from the same viewer
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('view_session_req_' || v_uid::text));

    -- Check if user already has an active session
    SELECT vs.*, c.url, c.domain INTO v_existing_active
    FROM public.view_sessions vs
    JOIN public.campaigns c ON c.id = vs.campaign_id
    WHERE vs.viewer_id = v_uid
      AND vs.status IN ('INITIALIZED', 'CONTENT_READY')
    ORDER BY vs.started_at DESC 
    LIMIT 1;

    IF v_existing_active IS NOT NULL THEN
        -- If session started within the last 3 minutes, return it idempotently for resumption
        IF v_existing_active.started_at > (pg_catalog.clock_timestamp() - INTERVAL '3 minutes') THEN
            RETURN pg_catalog.json_build_object(
                'id', v_existing_active.id,
                'campaign_id', v_existing_active.campaign_id,
                'target_url', v_existing_active.url,
                'domain', v_existing_active.domain,
                'required_duration_seconds', v_existing_active.required_duration_seconds,
                'reward_coins', v_existing_active.reward_coins,
                'started_at', pg_catalog.extract(epoch from v_existing_active.started_at) * 1000
            );
        ELSE
            -- Mark stale session as EXPIRED so user can request a fresh one
            UPDATE public.view_sessions
            SET status = 'EXPIRED'
            WHERE id = v_existing_active.id;
        END IF;
    END IF;

    -- Select an active eligible campaign:
    -- 1. Status == ACTIVE
    -- 2. Owner != viewer (Anti-Self View enforced)
    -- 3. Uncompleted views remaining
    -- 4. Sufficient reserved budget for at least one view
    -- 5. Cooldown: viewer has not completed this campaign in the last 15 minutes
    SELECT c.* INTO v_campaign
    FROM public.campaigns c
    WHERE c.status = 'ACTIVE'
      AND c.owner_id != v_uid
      AND c.completed_views < c.target_views
      AND c.reserved_budget >= c.cost_per_view
      AND NOT EXISTS (
          SELECT 1 FROM public.view_sessions vs
          WHERE vs.campaign_id = c.id
            AND vs.viewer_id = v_uid
            AND vs.status = 'COMPLETED'
            AND vs.completed_at > (pg_catalog.clock_timestamp() - INTERVAL '15 minutes')
      )
    ORDER BY c.created_at ASC
    FOR UPDATE SKIP LOCKED
    LIMIT 1;

    IF v_campaign IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_price 
    FROM public.duration_pricing 
    WHERE duration_seconds = v_campaign.duration_seconds;

    -- Insert new view session (structural index guarantees only one active session per viewer)
    INSERT INTO public.view_sessions (
        campaign_id, viewer_id, required_duration_seconds, reward_coins, status,
        started_at, created_at
    ) VALUES (
        v_campaign.id, v_uid, v_campaign.duration_seconds, v_price.viewer_reward, 'INITIALIZED',
        pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    RETURNING * INTO v_new_session;

    RETURN pg_catalog.json_build_object(
        'id', v_new_session.id,
        'campaign_id', v_campaign.id,
        'target_url', v_campaign.url,
        'domain', v_campaign.domain,
        'required_duration_seconds', v_new_session.required_duration_seconds,
        'reward_coins', v_new_session.reward_coins,
        'started_at', pg_catalog.extract(epoch from v_new_session.started_at) * 1000
    );
END;
$$;

-- ------------------------------------------------------------------------------
-- 4. Signal Content Ready (Starts Server Clock for View Validation)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.signal_content_ready(p_session_id UUID)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid UUID := (select auth.uid());
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ARGUMENT: Session ID cannot be null';
    END IF;

    UPDATE public.view_sessions
    SET content_ready_at = pg_catalog.coalesce(content_ready_at, pg_catalog.clock_timestamp()),
        status = 'CONTENT_READY'
    WHERE id = p_session_id
      AND viewer_id = v_uid
      AND status = 'INITIALIZED';

    RETURN FOUND;
END;
$$;

-- ------------------------------------------------------------------------------
-- 5. Complete View Session (Deterministic Deadlock-Free Locking & Accounting)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.complete_view_session(
    p_session_id UUID,
    p_idempotency_key TEXT
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid UUID := (select auth.uid());
    v_clean_key TEXT;
    v_existing_by_key RECORD;
    v_session RECORD;
    v_campaign RECORD;
    v_owner RECORD;
    v_viewer RECORD;
    v_first_lock UUID;
    v_second_lock UUID;
    v_dummy_profile RECORD;
    v_elapsed_seconds NUMERIC;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ARGUMENT: Session ID cannot be null';
    END IF;

    -- Validate Idempotency Key
    v_clean_key := pg_catalog.trim(p_idempotency_key);
    IF v_clean_key IS NULL OR pg_catalog.length(v_clean_key) = 0 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Idempotency key cannot be empty';
    END IF;

    IF pg_catalog.length(v_clean_key) > 128 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Idempotency key exceeds maximum length of 128 characters';
    END IF;

    -- Idempotency check across sessions: key cannot be reused across different sessions or users
    SELECT * INTO v_existing_by_key 
    FROM public.view_sessions 
    WHERE idempotency_key = v_clean_key;

    IF v_existing_by_key IS NOT NULL THEN
        IF v_existing_by_key.viewer_id != v_uid THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT: Key has already been used by another user';
        END IF;

        IF v_existing_by_key.id != p_session_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT: Key has already been associated with a different session';
        END IF;

        IF v_existing_by_key.status = 'COMPLETED' THEN
            RETURN pg_catalog.json_build_object(
                'success', TRUE,
                'reward', v_existing_by_key.reward_coins,
                'already_completed', TRUE
            );
        END IF;
    END IF;

    -- 1. Lock the view session FOR UPDATE
    SELECT * INTO v_session 
    FROM public.view_sessions 
    WHERE id = p_session_id 
    FOR UPDATE;

    IF v_session IS NULL THEN
        RAISE EXCEPTION 'SESSION_NOT_FOUND: View session does not exist';
    END IF;

    IF v_session.viewer_id != v_uid THEN
        RAISE EXCEPTION 'FORBIDDEN: Session does not belong to the caller';
    END IF;

    -- Idempotent return if already completed
    IF v_session.status = 'COMPLETED' THEN
        RETURN pg_catalog.json_build_object(
            'success', TRUE,
            'reward', v_session.reward_coins,
            'already_completed', TRUE
        );
    END IF;

    -- Strict State Transition Check: MUST be exactly 'CONTENT_READY'
    IF v_session.status != 'CONTENT_READY' THEN
        RAISE EXCEPTION 'INVALID_SESSION_STATUS: Session is % but must be CONTENT_READY to complete', v_session.status;
    END IF;

    IF v_session.content_ready_at IS NULL THEN
        RAISE EXCEPTION 'INVALID_SESSION_STATE: Content ready signal was never received';
    END IF;

    -- Verify server-authoritative elapsed duration (with 1.0s network roundtrip tolerance)
    v_elapsed_seconds := pg_catalog.extract(epoch from (pg_catalog.clock_timestamp() - v_session.content_ready_at));
    IF v_elapsed_seconds < (v_session.required_duration_seconds - 1.0) THEN
        RAISE EXCEPTION 'PREMATURE_COMPLETION: Elapsed time (%s) is less than required duration (%s)', v_elapsed_seconds, v_session.required_duration_seconds;
    END IF;

    -- 2. Lock the campaign FOR UPDATE
    SELECT * INTO v_campaign 
    FROM public.campaigns 
    WHERE id = v_session.campaign_id 
    FOR UPDATE;

    IF v_campaign IS NULL THEN
        RAISE EXCEPTION 'CAMPAIGN_NOT_FOUND: Associated campaign no longer exists';
    END IF;

    IF v_campaign.status != 'ACTIVE' THEN
        RAISE EXCEPTION 'CAMPAIGN_INACTIVE: Campaign is % but must be ACTIVE', v_campaign.status;
    END IF;

    IF v_campaign.completed_views >= v_campaign.target_views THEN
        RAISE EXCEPTION 'CAMPAIGN_EXHAUSTED: Campaign has already reached its target view count';
    END IF;

    IF v_campaign.reserved_budget < v_campaign.cost_per_view THEN
        RAISE EXCEPTION 'INSUFFICIENT_CAMPAIGN_BUDGET: Campaign reserved budget (% coins) is less than cost per view (% coins)', v_campaign.reserved_budget, v_campaign.cost_per_view;
    END IF;

    -- 3. Lock profile records in deterministic UUID order to prevent deadlocks
    v_first_lock := CASE WHEN v_campaign.owner_id < v_uid THEN v_campaign.owner_id ELSE v_uid END;
    v_second_lock := CASE WHEN v_campaign.owner_id < v_uid THEN v_uid ELSE v_campaign.owner_id END;

    SELECT * INTO v_dummy_profile FROM public.profiles WHERE id = v_first_lock FOR UPDATE;
    IF v_first_lock != v_second_lock THEN
        SELECT * INTO v_dummy_profile FROM public.profiles WHERE id = v_second_lock FOR UPDATE;
    END IF;

    -- Retrieve fresh locked owner and viewer records
    SELECT * INTO v_owner FROM public.profiles WHERE id = v_campaign.owner_id;
    SELECT * INTO v_viewer FROM public.profiles WHERE id = v_uid;

    IF v_owner.reserved_coins < v_campaign.cost_per_view THEN
        RAISE EXCEPTION 'INSUFFICIENT_RESERVED_BALANCE: Campaign owner reserved balance (% coins) is less than cost per view (% coins)', v_owner.reserved_coins, v_campaign.cost_per_view;
    END IF;

    -- 4. Financial Mutations (Atomic Execution)
    -- 4a. Update Campaign Delivery Progress & Budgets
    UPDATE public.campaigns
    SET completed_views = completed_views + 1,
        spent_budget = spent_budget + cost_per_view,
        reserved_budget = reserved_budget - cost_per_view,
        status = CASE WHEN completed_views + 1 >= target_views THEN 'COMPLETED' ELSE status END,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_campaign.id;

    -- 4b. Deduct Campaign Owner's Reserved Balance and increment spent
    UPDATE public.profiles
    SET reserved_coins = reserved_coins - v_campaign.cost_per_view,
        lifetime_spent = lifetime_spent + v_campaign.cost_per_view,
        received_views_count = received_views_count + 1,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_campaign.owner_id;

    -- 4c. Credit Viewer's Balance
    UPDATE public.profiles
    SET available_coins = available_coins + v_session.reward_coins,
        lifetime_earned = lifetime_earned + v_session.reward_coins,
        completed_views_count = completed_views_count + 1,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_uid;

    -- 4d. Mark View Session COMPLETED with Idempotency Key
    UPDATE public.view_sessions
    SET status = 'COMPLETED',
        completed_at = pg_catalog.clock_timestamp(),
        idempotency_key = v_clean_key
    WHERE id = v_session.id;

    -- 4e. Record Viewer Reward in Financial Audit Ledger
    INSERT INTO public.coin_ledger (
        user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
    ) VALUES (
        v_uid, v_session.reward_coins, 'VIEW_REWARD',
        'مشاهده موفق ' || v_session.required_duration_seconds || ' ثانیه‌ای از ' || v_campaign.domain,
        v_campaign.id::text, v_clean_key, pg_catalog.clock_timestamp()
    );

    -- 4f. Record Advertiser Spend in Financial Audit Ledger
    INSERT INTO public.coin_ledger (
        user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
    ) VALUES (
        v_campaign.owner_id, -v_campaign.cost_per_view, 'CAMPAIGN_SPEND',
        'مصرف بودجه بازدید از ' || v_campaign.domain,
        v_campaign.id::text, 'spend_' || v_session.id::text, pg_catalog.clock_timestamp()
    );

    RETURN pg_catalog.json_build_object(
        'success', TRUE,
        'reward', v_session.reward_coins,
        'already_completed', FALSE
    );
END;
$$;

-- ------------------------------------------------------------------------------
-- 6. Cancel Campaign & Refund Unspent Reserved Budget
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_campaign(p_campaign_id UUID)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid UUID := (select auth.uid());
    v_campaign RECORD;
    v_owner RECORD;
    v_refund BIGINT;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF p_campaign_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ARGUMENT: Campaign ID cannot be null';
    END IF;

    -- 1. Lock campaign FOR UPDATE
    SELECT * INTO v_campaign 
    FROM public.campaigns 
    WHERE id = p_campaign_id 
      AND owner_id = v_uid 
    FOR UPDATE;

    IF v_campaign IS NULL THEN
        RAISE EXCEPTION 'CAMPAIGN_NOT_FOUND: Campaign does not exist or caller is not owner';
    END IF;

    IF v_campaign.status IN ('COMPLETED', 'CANCELLED') THEN
        RAISE EXCEPTION 'INVALID_CAMPAIGN_STATE: Cannot cancel a % campaign', v_campaign.status;
    END IF;

    -- 2. Lock owner profile FOR UPDATE
    SELECT * INTO v_owner 
    FROM public.profiles 
    WHERE id = v_uid 
    FOR UPDATE;

    v_refund := v_campaign.reserved_budget;

    IF v_owner.reserved_coins < v_refund THEN
        RAISE EXCEPTION 'INSUFFICIENT_RESERVED_BALANCE: Owner reserved coins (% coins) is less than campaign refund amount (% coins)', v_owner.reserved_coins, v_refund;
    END IF;

    -- 3. Update campaign status to CANCELLED and reset reserved budget
    UPDATE public.campaigns
    SET status = 'CANCELLED',
        reserved_budget = 0,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_campaign.id;

    -- 4. Refund unspent balance back to available coins
    IF v_refund > 0 THEN
        UPDATE public.profiles
        SET available_coins = available_coins + v_refund,
            reserved_coins = reserved_coins - v_refund,
            updated_at = pg_catalog.clock_timestamp()
        WHERE id = v_uid;

        -- Record refund in financial audit ledger
        INSERT INTO public.coin_ledger (
            user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
        ) VALUES (
            v_uid, v_refund, 'CAMPAIGN_REFUND',
            'استرداد مانده بودجه سفارش لغو شده ' || v_campaign.domain,
            v_campaign.id::text, 'camp_refund_' || v_campaign.id::text, pg_catalog.clock_timestamp()
        );
    END IF;

    RETURN pg_catalog.json_build_object(
        'success', TRUE,
        'refunded_amount', v_refund
    );
END;
$$;

-- ------------------------------------------------------------------------------
-- 7. Pause Campaign
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pause_campaign(p_campaign_id UUID)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid UUID := (select auth.uid());
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    UPDATE public.campaigns
    SET status = 'PAUSED',
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = p_campaign_id 
      AND owner_id = v_uid 
      AND status = 'ACTIVE';

    RETURN FOUND;
END;
$$;

-- ------------------------------------------------------------------------------
-- 8. Resume Campaign
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resume_campaign(p_campaign_id UUID)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid UUID := (select auth.uid());
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    UPDATE public.campaigns
    SET status = 'ACTIVE',
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = p_campaign_id 
      AND owner_id = v_uid 
      AND status = 'PAUSED';

    RETURN FOUND;
END;
$$;

-- ==============================================================================
-- Function Execution Privileges Hardening
-- Revoke all execute permissions from PUBLIC and anon; grant strictly to authenticated
-- ==============================================================================

REVOKE ALL ON FUNCTION public.init_user_account(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.init_user_account(TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.create_campaign(TEXT, TEXT, TEXT, INT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_campaign(TEXT, TEXT, TEXT, INT, INT) TO authenticated;

REVOKE ALL ON FUNCTION public.request_view_session() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_view_session() TO authenticated;

REVOKE ALL ON FUNCTION public.signal_content_ready(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.signal_content_ready(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.complete_view_session(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_view_session(UUID, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.cancel_campaign(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_campaign(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.pause_campaign(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pause_campaign(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.resume_campaign(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resume_campaign(UUID) TO authenticated;
