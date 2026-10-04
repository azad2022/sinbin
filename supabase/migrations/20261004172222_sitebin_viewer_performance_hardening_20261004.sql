-- SiteBin Viewer performance hardening.
--
-- The live Supabase project has this migration applied as
-- 20261004172222_sitebin_viewer_performance_hardening_20261004.
-- Keep repository migration parity with the authoritative database state.
--
-- Viewer campaign selection remains server-authoritative. The index only makes
-- the eligible FIFO candidate pool cheaper to scan as campaign volume grows.
--
-- Completion returns the authoritative viewer financial snapshot so Android
-- does not block the reward UI on a broad post-completion refresh.

CREATE INDEX IF NOT EXISTS idx_campaigns_view_queue
ON public.campaigns (created_at ASC, id)
WHERE status = 'ACTIVE'
  AND completed_views < target_views
  AND reserved_budget >= cost_per_view;

CREATE OR REPLACE FUNCTION public.complete_view_session(
    p_session_id UUID,
    p_idempotency_key TEXT
) RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
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
    v_campaign_completed BOOLEAN := FALSE;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ARGUMENT: Session ID cannot be null';
    END IF;

    v_clean_key := trim(p_idempotency_key);
    IF v_clean_key IS NULL OR length(v_clean_key) = 0 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Idempotency key cannot be empty';
    END IF;

    IF length(v_clean_key) > 128 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Idempotency key exceeds maximum length of 128 characters';
    END IF;

    SELECT * INTO v_existing_by_key
    FROM public.view_sessions
    WHERE idempotency_key = v_clean_key;

    IF v_existing_by_key IS NOT NULL THEN
        IF v_existing_by_key.viewer_id <> v_uid THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT: Key has already been used by another user';
        END IF;
        IF v_existing_by_key.id <> p_session_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT: Key has already been associated with a different session';
        END IF;
        IF v_existing_by_key.status = 'COMPLETED' THEN
            SELECT available_coins, lifetime_earned, completed_views_count
            INTO v_viewer
            FROM public.profiles
            WHERE id = v_uid;

            RETURN pg_catalog.json_build_object(
                'success', TRUE,
                'reward', v_existing_by_key.reward_coins,
                'already_completed', TRUE,
                'available_coins', COALESCE(v_viewer.available_coins, 0),
                'lifetime_earned', COALESCE(v_viewer.lifetime_earned, 0),
                'completed_views_count', COALESCE(v_viewer.completed_views_count, 0),
                'campaign_completed', TRUE
            );
        END IF;
    END IF;

    SELECT * INTO v_session
    FROM public.view_sessions
    WHERE id = p_session_id
    FOR UPDATE;

    IF v_session IS NULL THEN
        RAISE EXCEPTION 'SESSION_NOT_FOUND: View session does not exist';
    END IF;

    IF v_session.viewer_id <> v_uid THEN
        RAISE EXCEPTION 'FORBIDDEN: Session does not belong to the caller';
    END IF;

    IF v_session.status = 'COMPLETED' THEN
        SELECT available_coins, lifetime_earned, completed_views_count
        INTO v_viewer
        FROM public.profiles
        WHERE id = v_uid;

        RETURN pg_catalog.json_build_object(
            'success', TRUE,
            'reward', v_session.reward_coins,
            'already_completed', TRUE,
            'available_coins', COALESCE(v_viewer.available_coins, 0),
            'lifetime_earned', COALESCE(v_viewer.lifetime_earned, 0),
            'completed_views_count', COALESCE(v_viewer.completed_views_count, 0),
            'campaign_completed', TRUE
        );
    END IF;

    IF v_session.status <> 'CONTENT_READY' THEN
        RAISE EXCEPTION 'INVALID_SESSION_STATUS: Session is % but must be CONTENT_READY to complete', v_session.status;
    END IF;

    IF v_session.content_ready_at IS NULL THEN
        RAISE EXCEPTION 'INVALID_SESSION_STATE: Content ready signal was never received';
    END IF;

    v_elapsed_seconds := extract(epoch from (pg_catalog.clock_timestamp() - v_session.content_ready_at));

    IF v_elapsed_seconds < (v_session.required_duration_seconds - 1.0) THEN
        RAISE EXCEPTION 'PREMATURE_COMPLETION: Elapsed time (%) is less than required duration (%)',
            v_elapsed_seconds, v_session.required_duration_seconds;
    END IF;

    SELECT * INTO v_campaign
    FROM public.campaigns
    WHERE id = v_session.campaign_id
    FOR UPDATE;

    IF v_campaign IS NULL THEN
        RAISE EXCEPTION 'CAMPAIGN_NOT_FOUND: Associated campaign no longer exists';
    END IF;

    IF v_campaign.status NOT IN ('ACTIVE', 'PAUSED') THEN
        RAISE EXCEPTION 'CAMPAIGN_INACTIVE: Campaign is % but must be ACTIVE or PAUSED', v_campaign.status;
    END IF;

    IF v_campaign.completed_views >= v_campaign.target_views THEN
        RAISE EXCEPTION 'CAMPAIGN_EXHAUSTED: Campaign has already reached its target view count';
    END IF;

    IF v_campaign.reserved_budget < v_campaign.cost_per_view THEN
        RAISE EXCEPTION 'INSUFFICIENT_CAMPAIGN_BUDGET: Campaign reserved budget (%) is less than cost per view (%)',
            v_campaign.reserved_budget, v_campaign.cost_per_view;
    END IF;

    v_campaign_completed := (v_campaign.completed_views + 1 >= v_campaign.target_views);

    v_first_lock := CASE WHEN v_campaign.owner_id < v_uid THEN v_campaign.owner_id ELSE v_uid END;
    v_second_lock := CASE WHEN v_campaign.owner_id < v_uid THEN v_uid ELSE v_campaign.owner_id END;

    SELECT * INTO v_dummy_profile FROM public.profiles WHERE id = v_first_lock FOR UPDATE;
    IF v_first_lock <> v_second_lock THEN
        SELECT * INTO v_dummy_profile FROM public.profiles WHERE id = v_second_lock FOR UPDATE;
    END IF;

    SELECT * INTO v_owner FROM public.profiles WHERE id = v_campaign.owner_id;
    SELECT * INTO v_viewer FROM public.profiles WHERE id = v_uid;

    IF v_owner.reserved_coins < v_campaign.cost_per_view THEN
        RAISE EXCEPTION 'INSUFFICIENT_RESERVED_BALANCE: Campaign owner reserved balance (%) is less than cost per view (%)',
            v_owner.reserved_coins, v_campaign.cost_per_view;
    END IF;

    UPDATE public.campaigns
    SET completed_views = completed_views + 1,
        spent_budget = spent_budget + cost_per_view,
        reserved_budget = reserved_budget - cost_per_view,
        status = CASE WHEN completed_views + 1 >= target_views THEN 'COMPLETED' ELSE status END,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_campaign.id;

    UPDATE public.profiles
    SET reserved_coins = reserved_coins - v_campaign.cost_per_view,
        lifetime_spent = lifetime_spent + v_campaign.cost_per_view,
        received_views_count = received_views_count + 1,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_campaign.owner_id;

    UPDATE public.profiles
    SET available_coins = available_coins + v_session.reward_coins,
        lifetime_earned = lifetime_earned + v_session.reward_coins,
        completed_views_count = completed_views_count + 1,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_uid
    RETURNING available_coins, lifetime_earned, completed_views_count
    INTO v_viewer;

    UPDATE public.view_sessions
    SET status = 'COMPLETED',
        completed_at = pg_catalog.clock_timestamp(),
        idempotency_key = v_clean_key
    WHERE id = v_session.id;

    INSERT INTO public.coin_ledger(
        user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
    )
    VALUES(
        v_uid, v_session.reward_coins, 'VIEW_REWARD',
        'مشاهده موفق ' || v_session.required_duration_seconds || ' ثانیه‌ای از ' || v_campaign.domain,
        v_campaign.id::text, v_clean_key, pg_catalog.clock_timestamp()
    );

    INSERT INTO public.coin_ledger(
        user_id, amount, transaction_type, description, reference_id, idempotency_key, created_at
    )
    VALUES(
        v_campaign.owner_id, -v_campaign.cost_per_view, 'CAMPAIGN_SPEND',
        'مصرف بودجه بازدید از ' || v_campaign.domain,
        v_campaign.id::text, 'spend_' || v_session.id::text, pg_catalog.clock_timestamp()
    );

    RETURN pg_catalog.json_build_object(
        'success', TRUE,
        'reward', v_session.reward_coins,
        'already_completed', FALSE,
        'available_coins', COALESCE(v_viewer.available_coins, 0),
        'lifetime_earned', COALESCE(v_viewer.lifetime_earned, 0),
        'completed_views_count', COALESCE(v_viewer.completed_views_count, 0),
        'campaign_completed', v_campaign_completed
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.complete_view_session(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_view_session(UUID, TEXT) TO authenticated;
