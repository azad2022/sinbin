-- ==============================================================================
-- SiteBin — Server-Authoritative Architecture Migration
-- PostgreSQL / Supabase Schema & RPC Functions
-- ==============================================================================

-- 1. Duration & Pricing Matrix (Server-Authoritative Pricing)
CREATE TABLE IF NOT EXISTS public.duration_pricing (
    duration_seconds INT PRIMARY KEY,
    advertiser_cost BIGINT NOT NULL CHECK (advertiser_cost > 0),
    viewer_reward BIGINT NOT NULL CHECK (viewer_reward > 0),
    is_popular BOOLEAN NOT NULL DEFAULT FALSE
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

-- 2. User Profiles (Linked to auth.users)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    user_handle TEXT UNIQUE NOT NULL,
    app_install_id TEXT,
    available_coins BIGINT NOT NULL DEFAULT 0 CHECK (available_coins >= 0),
    reserved_coins BIGINT NOT NULL DEFAULT 0 CHECK (reserved_coins >= 0),
    lifetime_earned BIGINT NOT NULL DEFAULT 0 CHECK (lifetime_earned >= 0),
    lifetime_spent BIGINT NOT NULL DEFAULT 0 CHECK (lifetime_spent >= 0),
    trust_score REAL NOT NULL DEFAULT 100.0,
    completed_views_count INTEGER NOT NULL DEFAULT 0,
    received_views_count INTEGER NOT NULL DEFAULT 0,
    welcome_bonus_claimed BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Welcome Bonus Grants (Server-Side Anti-Farming & Replay Prevention)
CREATE TABLE IF NOT EXISTS public.welcome_bonus_grants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID UNIQUE NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    install_id TEXT,
    amount BIGINT NOT NULL DEFAULT 150,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 4. Campaigns (Server-Authoritative Budget & Delivery)
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
    reserved_budget BIGINT NOT NULL CHECK (reserved_budget >= 0),
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'PAUSED', 'COMPLETED', 'CANCELLED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_campaigns_status_budget ON public.campaigns (status, reserved_budget) WHERE status = 'ACTIVE';

-- 5. View Sessions (Server-Controlled Validation & Duplicate Prevention)
CREATE TABLE IF NOT EXISTS public.view_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
    viewer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    required_duration_seconds INT NOT NULL,
    reward_coins BIGINT NOT NULL CHECK (reward_coins > 0),
    status TEXT NOT NULL DEFAULT 'INITIALIZED' CHECK (status IN ('INITIALIZED', 'CONTENT_READY', 'COMPLETED', 'EXPIRED', 'CANCELLED')),
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    content_ready_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    idempotency_key TEXT UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_view_sessions_viewer_campaign ON public.view_sessions (viewer_id, campaign_id, status);

-- 6. Coin Ledger (Double-Entry Financial Auditing)
CREATE TABLE IF NOT EXISTS public.coin_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    amount BIGINT NOT NULL,
    transaction_type TEXT NOT NULL CHECK (transaction_type IN ('WELCOME_REWARD', 'VIEW_REWARD', 'CAMPAIGN_RESERVATION', 'CAMPAIGN_SPEND', 'CAMPAIGN_REFUND', 'REFERRAL_REWARD')),
    description TEXT NOT NULL,
    reference_id TEXT,
    idempotency_key TEXT UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_coin_ledger_user ON public.coin_ledger (user_id, created_at DESC);

-- ==============================================================================
-- Row Level Security (RLS) Policies
-- Client has ZERO direct mutation permissions; only SELECT own data.
-- ==============================================================================

ALTER TABLE public.duration_pricing ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read pricing" ON public.duration_pricing FOR SELECT USING (true);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own profile" ON public.profiles FOR SELECT USING (auth.uid() = id);

ALTER TABLE public.welcome_bonus_grants ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own welcome grant" ON public.welcome_bonus_grants FOR SELECT USING (auth.uid() = user_id);

ALTER TABLE public.campaigns ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own or active campaigns" ON public.campaigns FOR SELECT USING (auth.uid() = owner_id OR status = 'ACTIVE');

ALTER TABLE public.view_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own view sessions" ON public.view_sessions FOR SELECT USING (auth.uid() = viewer_id);

ALTER TABLE public.coin_ledger ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own ledger entries" ON public.coin_ledger FOR SELECT USING (auth.uid() = user_id);

-- ==============================================================================
-- Server-Authoritative RPC Database Functions (SECURITY DEFINER)
-- ==============================================================================

-- 1. Initialize Account & Grant Exactly One Welcome Bonus
CREATE OR REPLACE FUNCTION public.init_user_account(p_install_id TEXT, p_handle TEXT DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_profile RECORD;
    v_bonus_amount BIGINT := 150;
    v_handle TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    -- Generate default handle if not provided
    v_handle := COALESCE(p_handle, 'user_' || SUBSTRING(v_uid::text, 1, 8));

    -- Check if profile already exists
    SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid;

    IF v_profile IS NULL THEN
        -- Create new profile and grant welcome bonus atomically
        INSERT INTO public.profiles (
            id, user_handle, app_install_id, available_coins, reserved_coins,
            lifetime_earned, lifetime_spent, trust_score, welcome_bonus_claimed
        ) VALUES (
            v_uid, v_handle, p_install_id, v_bonus_amount, 0,
            v_bonus_amount, 0, 100.0, TRUE
        )
        RETURNING * INTO v_profile;

        -- Record welcome bonus in grant table (Unique Constraint enforced)
        INSERT INTO public.welcome_bonus_grants (user_id, install_id, amount)
        VALUES (v_uid, p_install_id, v_bonus_amount)
        ON CONFLICT (user_id) DO NOTHING;

        -- Record in audit ledger
        INSERT INTO public.coin_ledger (
            user_id, amount, transaction_type, description, reference_id, idempotency_key
        ) VALUES (
            v_uid, v_bonus_amount, 'WELCOME_REWARD', 'هدیه ورود به سایت بین (Welcome Bonus)', 'init_bonus', 'welcome_' || v_uid::text
        )
        ON CONFLICT (idempotency_key) DO NOTHING;
    END IF;

    RETURN row_to_json(v_profile);
END;
$$;

-- 2. Create Campaign (Atomic Budget Calculation, Validation & Ledger Reservation)
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
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_price RECORD;
    v_total_cost BIGINT;
    v_profile RECORD;
    v_new_campaign RECORD;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF p_target_views <= 0 THEN
        RAISE EXCEPTION 'INVALID_TARGET_VIEWS: Target views must be greater than zero';
    END IF;

    -- Lookup server-authoritative pricing
    SELECT * INTO v_price FROM public.duration_pricing WHERE duration_seconds = p_duration_seconds;
    IF v_price IS NULL THEN
        RAISE EXCEPTION 'INVALID_DURATION: Unsupported duration option';
    END IF;

    v_total_cost := v_price.advertiser_cost * p_target_views;

    -- Lock profile for update to prevent race conditions & overspending
    SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid FOR UPDATE;
    IF v_profile IS NULL THEN
        RAISE EXCEPTION 'PROFILE_NOT_FOUND: User profile does not exist';
    END IF;

    IF v_profile.available_coins < v_total_cost THEN
        RAISE EXCEPTION 'INSUFFICIENT_BALANCE: Available coins % is less than required %', v_profile.available_coins, v_total_cost;
    END IF;

    -- Deduct available and reserve budget atomically
    UPDATE public.profiles
    SET available_coins = available_coins - v_total_cost,
        reserved_coins = reserved_coins + v_total_cost,
        updated_at = now()
    WHERE id = v_uid;

    -- Create campaign
    INSERT INTO public.campaigns (
        owner_id, url, normalized_url, domain, duration_seconds, target_views,
        completed_views, cost_per_view, total_budget, spent_budget, reserved_budget, status
    ) VALUES (
        v_uid, p_url, p_normalized_url, p_domain, p_duration_seconds, p_target_views,
        0, v_price.advertiser_cost, v_total_cost, 0, v_total_cost, 'ACTIVE'
    )
    RETURNING * INTO v_new_campaign;

    -- Record reservation in ledger
    INSERT INTO public.coin_ledger (
        user_id, amount, transaction_type, description, reference_id, idempotency_key
    ) VALUES (
        v_uid, -v_total_cost, 'CAMPAIGN_RESERVATION',
        'رزرو بودجه برای سفارش ' || p_target_views || ' بازدید از ' || p_domain,
        v_new_campaign.id::text, 'camp_res_' || v_new_campaign.id::text
    );

    RETURN row_to_json(v_new_campaign);
END;
$$;

-- 3. Request View Session (Server-Side Campaign Selection, Anti-Self View & Cooldown)
CREATE OR REPLACE FUNCTION public.request_view_session()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_campaign RECORD;
    v_price RECORD;
    v_existing_session RECORD;
    v_new_session RECORD;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    -- Check if user already has an active incomplete session started less than 3 minutes ago
    SELECT * INTO v_existing_session
    FROM public.view_sessions
    WHERE viewer_id = v_uid
      AND status IN ('INITIALIZED', 'CONTENT_READY')
      AND started_at > now() - INTERVAL '3 minutes'
    ORDER BY started_at DESC LIMIT 1;

    IF v_existing_session IS NOT NULL THEN
        -- Return existing active session details
        SELECT c.url, c.domain INTO v_campaign FROM public.campaigns c WHERE c.id = v_existing_session.campaign_id;
        RETURN json_build_object(
            'id', v_existing_session.id,
            'campaign_id', v_existing_session.campaign_id,
            'target_url', v_campaign.url,
            'domain', v_campaign.domain,
            'required_duration_seconds', v_existing_session.required_duration_seconds,
            'reward_coins', v_existing_session.reward_coins,
            'started_at', EXTRACT(EPOCH FROM v_existing_session.started_at) * 1000
        );
    END IF;

    -- Cancel stale sessions older than 3 minutes
    UPDATE public.view_sessions
    SET status = 'EXPIRED'
    WHERE viewer_id = v_uid AND status IN ('INITIALIZED', 'CONTENT_READY') AND started_at <= now() - INTERVAL '3 minutes';

    -- Find an eligible active campaign:
    -- 1. Must be ACTIVE
    -- 2. Must NOT be owned by current user (Anti-Self View)
    -- 3. Must have remaining uncompleted views & budget
    -- 4. Viewer must not have completed this campaign within the last 15 minutes (Cooldown)
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
            AND vs.completed_at > now() - INTERVAL '15 minutes'
      )
    ORDER BY c.created_at ASC
    FOR UPDATE SKIP LOCKED
    LIMIT 1;

    IF v_campaign IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_price FROM public.duration_pricing WHERE duration_seconds = v_campaign.duration_seconds;

    -- Create new server-authoritative view session
    INSERT INTO public.view_sessions (
        campaign_id, viewer_id, required_duration_seconds, reward_coins, status, started_at
    ) VALUES (
        v_campaign.id, v_uid, v_campaign.duration_seconds, v_price.viewer_reward, 'INITIALIZED', now()
    )
    RETURNING * INTO v_new_session;

    RETURN json_build_object(
        'id', v_new_session.id,
        'campaign_id', v_campaign.id,
        'target_url', v_campaign.url,
        'domain', v_campaign.domain,
        'required_duration_seconds', v_new_session.required_duration_seconds,
        'reward_coins', v_new_session.reward_coins,
        'started_at', EXTRACT(EPOCH FROM v_new_session.started_at) * 1000
    );
END;
$$;

-- 4. Signal Content Ready (Starts Server Clock for View Validation)
CREATE OR REPLACE FUNCTION public.signal_content_ready(p_session_id UUID)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_uid UUID := auth.uid();
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    UPDATE public.view_sessions
    SET content_ready_at = COALESCE(content_ready_at, now()),
        status = 'CONTENT_READY'
    WHERE id = p_session_id
      AND viewer_id = v_uid
      AND status = 'INITIALIZED';

    RETURN FOUND;
END;
$$;

-- 5. Complete View Session (Idempotent, Atomic Validation, Budget Deduction & Reward Grant)
CREATE OR REPLACE FUNCTION public.complete_view_session(
    p_session_id UUID,
    p_idempotency_key TEXT
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_session RECORD;
    v_campaign RECORD;
    v_elapsed_seconds NUMERIC;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    -- Check if this idempotency key was already executed
    SELECT * INTO v_session FROM public.view_sessions WHERE idempotency_key = p_idempotency_key;
    IF v_session IS NOT NULL AND v_session.status = 'COMPLETED' THEN
        -- Return existing result idempotently without double credit
        RETURN json_build_object(
            'success', TRUE,
            'reward', v_session.reward_coins,
            'already_completed', TRUE
        );
    END IF;

    -- Lock the view session FOR UPDATE
    SELECT * INTO v_session FROM public.view_sessions WHERE id = p_session_id FOR UPDATE;
    IF v_session IS NULL THEN
        RAISE EXCEPTION 'SESSION_NOT_FOUND: View session does not exist';
    END IF;

    IF v_session.viewer_id != v_uid THEN
        RAISE EXCEPTION 'FORBIDDEN: Session does not belong to caller';
    END IF;

    IF v_session.status = 'COMPLETED' THEN
        RETURN json_build_object(
            'success', TRUE,
            'reward', v_session.reward_coins,
            'already_completed', TRUE
        );
    END IF;

    -- Validate Server Timing
    IF v_session.content_ready_at IS NULL THEN
        RAISE EXCEPTION 'INVALID_SESSION_STATE: Content ready signal was never received';
    END IF;

    v_elapsed_seconds := EXTRACT(EPOCH FROM (now() - v_session.content_ready_at));
    -- Enforce duration with 1.0 second tolerance for network roundtrip
    IF v_elapsed_seconds < (v_session.required_duration_seconds - 1.0) THEN
        RAISE EXCEPTION 'PREMATURE_COMPLETION: Elapsed time % is less than required % seconds', v_elapsed_seconds, v_session.required_duration_seconds;
    END IF;

    -- Lock the campaign row
    SELECT * INTO v_campaign FROM public.campaigns WHERE id = v_session.campaign_id FOR UPDATE;
    IF v_campaign IS NULL THEN
        RAISE EXCEPTION 'CAMPAIGN_NOT_FOUND: Campaign no longer exists';
    END IF;

    IF v_campaign.status != 'ACTIVE' THEN
        RAISE EXCEPTION 'CAMPAIGN_INACTIVE: Campaign is not active';
    END IF;

    IF v_campaign.reserved_budget < v_campaign.cost_per_view THEN
        RAISE EXCEPTION 'BUDGET_EXHAUSTED: Campaign budget is fully exhausted';
    END IF;

    -- 1. Update Campaign Delivery Progress & Budget
    UPDATE public.campaigns
    SET completed_views = completed_views + 1,
        spent_budget = spent_budget + cost_per_view,
        reserved_budget = reserved_budget - cost_per_view,
        status = CASE WHEN completed_views + 1 >= target_views THEN 'COMPLETED' ELSE status END,
        updated_at = now()
    WHERE id = v_campaign.id;

    -- 2. Deduct Campaign Owner's Reserved Coins
    UPDATE public.profiles
    SET reserved_coins = GREATEST(0, reserved_coins - v_campaign.cost_per_view),
        lifetime_spent = lifetime_spent + v_campaign.cost_per_view,
        received_views_count = received_views_count + 1,
        updated_at = now()
    WHERE id = v_campaign.owner_id;

    -- 3. Credit Viewer's Coins
    UPDATE public.profiles
    SET available_coins = available_coins + v_session.reward_coins,
        lifetime_earned = lifetime_earned + v_session.reward_coins,
        completed_views_count = completed_views_count + 1,
        updated_at = now()
    WHERE id = v_uid;

    -- 4. Mark Session Completed
    UPDATE public.view_sessions
    SET status = 'COMPLETED',
        completed_at = now(),
        idempotency_key = p_idempotency_key
    WHERE id = v_session.id;

    -- 5. Record Viewer Reward in Coin Ledger
    INSERT INTO public.coin_ledger (
        user_id, amount, transaction_type, description, reference_id, idempotency_key
    ) VALUES (
        v_uid, v_session.reward_coins, 'VIEW_REWARD',
        'مشاهده موفق ' || v_session.required_duration_seconds || ' ثانیه‌ای از ' || v_campaign.domain,
        v_campaign.id::text, p_idempotency_key
    );

    RETURN json_build_object(
        'success', TRUE,
        'reward', v_session.reward_coins,
        'already_completed', FALSE
    );
END;
$$;

-- 6. Cancel Campaign & Refund Remaining Reserved Budget
CREATE OR REPLACE FUNCTION public.cancel_campaign(p_campaign_id UUID)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_campaign RECORD;
    v_refund BIGINT;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    SELECT * INTO v_campaign FROM public.campaigns WHERE id = p_campaign_id AND owner_id = v_uid FOR UPDATE;
    IF v_campaign IS NULL THEN
        RAISE EXCEPTION 'CAMPAIGN_NOT_FOUND: Campaign does not exist or caller is not owner';
    END IF;

    IF v_campaign.status IN ('COMPLETED', 'CANCELLED') THEN
        RAISE EXCEPTION 'INVALID_CAMPAIGN_STATE: Cannot cancel a completed or already cancelled campaign';
    END IF;

    v_refund := v_campaign.reserved_budget;

    -- Update campaign status
    UPDATE public.campaigns
    SET status = 'CANCELLED',
        reserved_budget = 0,
        updated_at = now()
    WHERE id = v_campaign.id;

    -- Refund unspent reserved budget back to available balance
    IF v_refund > 0 THEN
        UPDATE public.profiles
        SET available_coins = available_coins + v_refund,
            reserved_coins = GREATEST(0, reserved_coins - v_refund),
            updated_at = now()
        WHERE id = v_uid;

        INSERT INTO public.coin_ledger (
            user_id, amount, transaction_type, description, reference_id, idempotency_key
        ) VALUES (
            v_uid, v_refund, 'CAMPAIGN_REFUND',
            'استرداد مانده بودجه سفارش لغو شده ' || v_campaign.domain,
            v_campaign.id::text, 'refund_' || v_campaign.id::text || '_' || EXTRACT(EPOCH FROM now())::text
        );
    END IF;

    RETURN json_build_object(
        'success', TRUE,
        'refunded_amount', v_refund
    );
END;
$$;

-- 7. Pause & Resume Campaign
CREATE OR REPLACE FUNCTION public.pause_campaign(p_campaign_id UUID)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_uid UUID := auth.uid();
BEGIN
    UPDATE public.campaigns
    SET status = 'PAUSED', updated_at = now()
    WHERE id = p_campaign_id AND owner_id = v_uid AND status = 'ACTIVE';
    RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.resume_campaign(p_campaign_id UUID)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_uid UUID := auth.uid();
BEGIN
    UPDATE public.campaigns
    SET status = 'ACTIVE', updated_at = now()
    WHERE id = p_campaign_id AND owner_id = v_uid AND status = 'PAUSED';
    RETURN FOUND;
END;
$$;
