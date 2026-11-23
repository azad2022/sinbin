-- SiteBin financial refund accounting and permanent-auth hardening.
--
-- Budget is partitioned into spent + reserved + refunded. This preserves the
-- original campaign total while making cancellation/refund accounting explicit.
--
-- Each financial RPC rejects anonymous Supabase users. Anonymous users otherwise
-- use the authenticated Postgres role and would pass a plain auth.uid() check.

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS refunded_budget BIGINT NOT NULL DEFAULT 0
  CHECK (refunded_budget >= 0);

ALTER TABLE public.campaigns
  DROP CONSTRAINT IF EXISTS campaigns_budget_parts_consistent;

ALTER TABLE public.campaigns
  ADD CONSTRAINT campaigns_budget_parts_consistent
  CHECK (spent_budget + reserved_budget + refunded_budget = total_budget);

ALTER TABLE public.campaigns
  DROP CONSTRAINT IF EXISTS chk_campaign_budget_bound;

ALTER TABLE public.campaigns
  ADD CONSTRAINT chk_campaign_budget_bound
  CHECK (spent_budget + reserved_budget + refunded_budget <= total_budget);

CREATE OR REPLACE FUNCTION public.cancel_campaign(p_campaign_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid UUID := (select auth.uid());
    v_campaign RECORD;
    v_owner RECORD;
    v_refund BIGINT;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    IF p_campaign_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ARGUMENT: Campaign ID cannot be null';
    END IF;

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

    SELECT * INTO v_owner
    FROM public.profiles
    WHERE id = v_uid
    FOR UPDATE;

    v_refund := v_campaign.reserved_budget;

    IF v_owner.reserved_coins < v_refund THEN
        RAISE EXCEPTION 'INSUFFICIENT_RESERVED_BALANCE: Owner reserved coins (%) is less than campaign refund amount (%)',
            v_owner.reserved_coins, v_refund;
    END IF;

    UPDATE public.campaigns
    SET status = 'CANCELLED',
        reserved_budget = 0,
        refunded_budget = refunded_budget + v_refund,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_campaign.id;

    IF v_refund > 0 THEN
        UPDATE public.profiles
        SET available_coins = available_coins + v_refund,
            reserved_coins = reserved_coins - v_refund,
            updated_at = pg_catalog.clock_timestamp()
        WHERE id = v_uid;

        INSERT INTO public.coin_ledger(
            user_id, amount, transaction_type, description,
            reference_id, idempotency_key, created_at
        )
        VALUES(
            v_uid, v_refund, 'CAMPAIGN_REFUND',
            'استرداد مانده بودجه سفارش لغو شده ' || v_campaign.domain,
            v_campaign.id::text, 'camp_refund_' || v_campaign.id::text,
            pg_catalog.clock_timestamp()
        );
    END IF;

    RETURN pg_catalog.json_build_object(
        'success', TRUE,
        'refunded_amount', v_refund
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.cancel_view_session(p_session_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid UUID := (select auth.uid());
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

    UPDATE public.view_sessions
    SET status='CANCELLED'
    WHERE id=p_session_id
      AND viewer_id=v_uid
      AND status IN ('INITIALIZED','CONTENT_READY');

    RETURN FOUND;
END;
$function$;


CREATE OR REPLACE FUNCTION public.complete_view_session(p_session_id uuid, p_idempotency_key text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid UUID:=(select auth.uid());
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

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    IF p_session_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ARGUMENT: Session ID cannot be null';
    END IF;

    v_clean_key:=pg_catalog.trim(p_idempotency_key);
    IF v_clean_key IS NULL OR pg_catalog.length(v_clean_key)=0 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Idempotency key cannot be empty';
    END IF;

    IF pg_catalog.length(v_clean_key)>128 THEN
        RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY: Idempotency key exceeds maximum length of 128 characters';
    END IF;

    SELECT * INTO v_existing_by_key
    FROM public.view_sessions
    WHERE idempotency_key=v_clean_key;

    IF v_existing_by_key IS NOT NULL THEN
        IF v_existing_by_key.viewer_id<>v_uid THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT: Key has already been used by another user';
        END IF;
        IF v_existing_by_key.id<>p_session_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT: Key has already been associated with a different session';
        END IF;
        IF v_existing_by_key.status='COMPLETED' THEN
            RETURN pg_catalog.json_build_object('success',TRUE,'reward',v_existing_by_key.reward_coins,'already_completed',TRUE);
        END IF;
    END IF;

    SELECT * INTO v_session FROM public.view_sessions WHERE id=p_session_id FOR UPDATE;
    IF v_session IS NULL THEN
        RAISE EXCEPTION 'SESSION_NOT_FOUND: View session does not exist';
    END IF;
    IF v_session.viewer_id<>v_uid THEN
        RAISE EXCEPTION 'FORBIDDEN: Session does not belong to the caller';
    END IF;
    IF v_session.status='COMPLETED' THEN
        RETURN pg_catalog.json_build_object('success',TRUE,'reward',v_session.reward_coins,'already_completed',TRUE);
    END IF;
    IF v_session.status<>'CONTENT_READY' THEN
        RAISE EXCEPTION 'INVALID_SESSION_STATUS: Session is % but must be CONTENT_READY to complete',v_session.status;
    END IF;
    IF v_session.content_ready_at IS NULL THEN
        RAISE EXCEPTION 'INVALID_SESSION_STATE: Content ready signal was never received';
    END IF;

    v_elapsed_seconds:=extract(epoch from(pg_catalog.clock_timestamp()-v_session.content_ready_at));
    IF v_elapsed_seconds<(v_session.required_duration_seconds-1.0) THEN
        RAISE EXCEPTION 'PREMATURE_COMPLETION: Elapsed time (%) is less than required duration (%)',
            v_elapsed_seconds,v_session.required_duration_seconds;
    END IF;

    SELECT * INTO v_campaign FROM public.campaigns WHERE id=v_session.campaign_id FOR UPDATE;
    IF v_campaign IS NULL THEN
        RAISE EXCEPTION 'CAMPAIGN_NOT_FOUND: Associated campaign no longer exists';
    END IF;
    IF v_campaign.status NOT IN('ACTIVE','PAUSED') THEN
        RAISE EXCEPTION 'CAMPAIGN_INACTIVE: Campaign is % but must be ACTIVE or PAUSED',v_campaign.status;
    END IF;
    IF v_campaign.completed_views>=v_campaign.target_views THEN
        RAISE EXCEPTION 'CAMPAIGN_EXHAUSTED: Campaign has already reached its target view count';
    END IF;
    IF v_campaign.reserved_budget<v_campaign.cost_per_view THEN
        RAISE EXCEPTION 'INSUFFICIENT_CAMPAIGN_BUDGET: Campaign reserved budget (%) is less than cost per view (%)',
            v_campaign.reserved_budget,v_campaign.cost_per_view;
    END IF;

    v_first_lock:=CASE WHEN v_campaign.owner_id<v_uid THEN v_campaign.owner_id ELSE v_uid END;
    v_second_lock:=CASE WHEN v_campaign.owner_id<v_uid THEN v_uid ELSE v_campaign.owner_id END;

    SELECT * INTO v_dummy_profile FROM public.profiles WHERE id=v_first_lock FOR UPDATE;
    IF v_first_lock<>v_second_lock THEN
        SELECT * INTO v_dummy_profile FROM public.profiles WHERE id=v_second_lock FOR UPDATE;
    END IF;

    SELECT * INTO v_owner FROM public.profiles WHERE id=v_campaign.owner_id;
    SELECT * INTO v_viewer FROM public.profiles WHERE id=v_uid;

    IF v_owner.reserved_coins<v_campaign.cost_per_view THEN
        RAISE EXCEPTION 'INSUFFICIENT_RESERVED_BALANCE: Campaign owner reserved balance (%) is less than cost per view (%)',
            v_owner.reserved_coins,v_campaign.cost_per_view;
    END IF;

    UPDATE public.campaigns
    SET completed_views=completed_views+1,
        spent_budget=spent_budget+cost_per_view,
        reserved_budget=reserved_budget-cost_per_view,
        status=CASE WHEN completed_views+1>=target_views THEN 'COMPLETED' ELSE status END,
        updated_at=pg_catalog.clock_timestamp()
    WHERE id=v_campaign.id;

    UPDATE public.profiles
    SET reserved_coins=reserved_coins-v_campaign.cost_per_view,
        lifetime_spent=lifetime_spent+v_campaign.cost_per_view,
        received_views_count=received_views_count+1,
        updated_at=pg_catalog.clock_timestamp()
    WHERE id=v_campaign.owner_id;

    UPDATE public.profiles
    SET available_coins=available_coins+v_session.reward_coins,
        lifetime_earned=lifetime_earned+v_session.reward_coins,
        completed_views_count=completed_views_count+1,
        updated_at=pg_catalog.clock_timestamp()
    WHERE id=v_uid;

    UPDATE public.view_sessions
    SET status='COMPLETED',
        completed_at=pg_catalog.clock_timestamp(),
        idempotency_key=v_clean_key
    WHERE id=v_session.id;

    INSERT INTO public.coin_ledger(
        user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
    )
    VALUES(
        v_uid,v_session.reward_coins,'VIEW_REWARD',
        'مشاهده موفق ' || v_session.required_duration_seconds || ' ثانیه‌ای از ' || v_campaign.domain,
        v_campaign.id::text,v_clean_key,pg_catalog.clock_timestamp()
    );

    INSERT INTO public.coin_ledger(
        user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
    )
    VALUES(
        v_campaign.owner_id,-v_campaign.cost_per_view,'CAMPAIGN_SPEND',
        'مصرف بودجه بازدید از ' || v_campaign.domain,
        v_campaign.id::text,'spend_' || v_session.id::text,pg_catalog.clock_timestamp()
    );

    RETURN pg_catalog.json_build_object(
        'success',TRUE,'reward',v_session.reward_coins,'already_completed',FALSE
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.create_campaign(p_url text, p_normalized_url text, p_domain text, p_duration_seconds integer, p_target_views integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

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

    SELECT * INTO v_price
    FROM public.duration_pricing
    WHERE duration_seconds = p_duration_seconds;

    IF v_price IS NULL THEN
        RAISE EXCEPTION 'INVALID_DURATION: Unsupported duration option';
    END IF;

    v_total_cost := v_price.advertiser_cost * p_target_views;

    SELECT * INTO v_profile
    FROM public.profiles
    WHERE id = v_uid
    FOR UPDATE;

    IF v_profile IS NULL THEN
        RAISE EXCEPTION 'PROFILE_NOT_FOUND: User profile does not exist';
    END IF;

    IF v_profile.available_coins < v_total_cost THEN
        RAISE EXCEPTION 'INSUFFICIENT_BALANCE: Available balance (%) coins) is less than required budget (%) coins)',
            v_profile.available_coins, v_total_cost;
    END IF;

    UPDATE public.profiles
    SET available_coins = available_coins - v_total_cost,
        reserved_coins = reserved_coins + v_total_cost,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = v_uid;

    INSERT INTO public.campaigns(
        owner_id,url,normalized_url,domain,duration_seconds,target_views,
        completed_views,cost_per_view,total_budget,spent_budget,reserved_budget,status,
        created_at,updated_at
    )
    VALUES(
        v_uid,v_clean_url,v_clean_normalized,v_clean_domain,p_duration_seconds,p_target_views,
        0,v_price.advertiser_cost,v_total_cost,0,v_total_cost,'ACTIVE',
        pg_catalog.clock_timestamp(),pg_catalog.clock_timestamp()
    )
    RETURNING * INTO v_new_campaign;

    INSERT INTO public.coin_ledger(
        user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
    )
    VALUES(
        v_uid,-v_total_cost,'CAMPAIGN_RESERVATION',
        'رزرو بودجه برای سفارش ' || p_target_views || ' بازدید از ' || v_clean_domain,
        v_new_campaign.id::text,'camp_res_' || v_new_campaign.id::text,pg_catalog.clock_timestamp()
    );

    RETURN pg_catalog.row_to_json(v_new_campaign);
END;
$function$;


CREATE OR REPLACE FUNCTION public.init_user_account(p_install_id text, p_handle text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    v_clean_install := pg_catalog.nullif(pg_catalog.trim(p_install_id), '');
    IF v_clean_install IS NULL THEN
        RAISE EXCEPTION 'INVALID_INSTALL_ID: Installation identifier is required for account initialization';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('install_' || v_clean_install));

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

    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('user_init_' || v_uid::text));
    SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid FOR UPDATE;

    IF v_profile IS NULL THEN
        v_handle := pg_catalog.coalesce(
            pg_catalog.nullif(pg_catalog.trim(p_handle), ''),
            'user_' || pg_catalog.substring(v_uid::text, 1, 8)
        );

        IF EXISTS(SELECT 1 FROM public.welcome_bonus_grants WHERE user_id = v_uid) THEN
            v_bonus_amount := 0;
        END IF;

        INSERT INTO public.profiles(
            id,user_handle,app_install_id,available_coins,reserved_coins,
            lifetime_earned,lifetime_spent,trust_score,completed_views_count,
            received_views_count,welcome_bonus_claimed,created_at,updated_at
        )
        VALUES(
            v_uid,v_handle,v_clean_install,v_bonus_amount,0,
            v_bonus_amount,0,100.0,0,0,(v_bonus_amount>0),
            pg_catalog.clock_timestamp(),pg_catalog.clock_timestamp()
        )
        RETURNING * INTO v_profile;

        IF v_bonus_amount > 0 THEN
            INSERT INTO public.welcome_bonus_grants(user_id,install_id,amount,granted_at)
            VALUES(v_uid,v_clean_install,v_bonus_amount,pg_catalog.clock_timestamp());

            INSERT INTO public.coin_ledger(
                user_id,amount,transaction_type,description,reference_id,idempotency_key,created_at
            )
            VALUES(
                v_uid,v_bonus_amount,'WELCOME_REWARD',
                'هدیه ورود به سایت بین (Welcome Bonus)','init_bonus',
                'welcome_' || v_uid::text,pg_catalog.clock_timestamp()
            );
        END IF;
    END IF;

    RETURN pg_catalog.row_to_json(v_profile);
END;
$function$;


CREATE OR REPLACE FUNCTION public.pause_campaign(p_campaign_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid UUID := (select auth.uid());
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    UPDATE public.campaigns
    SET status='PAUSED',updated_at=pg_catalog.clock_timestamp()
    WHERE id=p_campaign_id AND owner_id=v_uid AND status='ACTIVE';

    RETURN FOUND;
END;
$function$;


CREATE OR REPLACE FUNCTION public.request_view_session()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('view_session_req_' || v_uid::text));

    SELECT vs.*,c.url,c.domain INTO v_existing_active
    FROM public.view_sessions vs
    JOIN public.campaigns c ON c.id=vs.campaign_id
    WHERE vs.viewer_id=v_uid AND vs.status IN('INITIALIZED','CONTENT_READY')
    ORDER BY vs.started_at DESC LIMIT 1;

    IF v_existing_active IS NOT NULL THEN
        IF v_existing_active.started_at>(pg_catalog.clock_timestamp()-INTERVAL '3 minutes') THEN
            RETURN pg_catalog.json_build_object(
                'id',v_existing_active.id,'campaign_id',v_existing_active.campaign_id,
                'target_url',v_existing_active.url,'domain',v_existing_active.domain,
                'required_duration_seconds',v_existing_active.required_duration_seconds,
                'reward_coins',v_existing_active.reward_coins,
                'started_at',extract(epoch from v_existing_active.started_at)*1000
            );
        ELSE
            UPDATE public.view_sessions SET status='EXPIRED' WHERE id=v_existing_active.id;
        END IF;
    END IF;

    SELECT c.* INTO v_campaign
    FROM public.campaigns c
    WHERE c.status='ACTIVE'
      AND c.owner_id<>v_uid
      AND c.completed_views<c.target_views
      AND c.reserved_budget>=c.cost_per_view
      AND NOT EXISTS(
          SELECT 1 FROM public.view_sessions vs
          WHERE vs.campaign_id=c.id
            AND vs.viewer_id=v_uid
            AND vs.status='COMPLETED'
            AND vs.completed_at>(pg_catalog.clock_timestamp()-INTERVAL '15 minutes')
      )
    ORDER BY c.created_at ASC
    FOR UPDATE SKIP LOCKED
    LIMIT 1;

    IF v_campaign IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_price
    FROM public.duration_pricing
    WHERE duration_seconds=v_campaign.duration_seconds;

    INSERT INTO public.view_sessions(
        campaign_id,viewer_id,required_duration_seconds,reward_coins,status,started_at,created_at
    )
    VALUES(
        v_campaign.id,v_uid,v_campaign.duration_seconds,v_price.viewer_reward,'INITIALIZED',
        pg_catalog.clock_timestamp(),pg_catalog.clock_timestamp()
    )
    RETURNING * INTO v_new_session;

    RETURN pg_catalog.json_build_object(
        'id',v_new_session.id,'campaign_id',v_campaign.id,'target_url',v_campaign.url,
        'domain',v_campaign.domain,'required_duration_seconds',v_new_session.required_duration_seconds,
        'reward_coins',v_new_session.reward_coins,
        'started_at',extract(epoch from v_new_session.started_at)*1000
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.resume_campaign(p_campaign_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid UUID := (select auth.uid());
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Authentication token required';
    END IF;

    IF COALESCE((SELECT (auth.jwt()->>'is_anonymous')::boolean), false) THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Anonymous authentication is not allowed';
    END IF;

    UPDATE public.campaigns
    SET status='ACTIVE',updated_at=pg_catalog.clock_timestamp()
    WHERE id=p_campaign_id AND owner_id=v_uid AND status='PAUSED';

    RETURN FOUND;
END;
$function$;


CREATE OR REPLACE FUNCTION public.signal_content_ready(p_session_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid UUID := (select auth.uid());
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

    UPDATE public.view_sessions
    SET content_ready_at=coalesce(content_ready_at,pg_catalog.clock_timestamp()),
        status='CONTENT_READY'
    WHERE id=p_session_id AND viewer_id=v_uid AND status='INITIALIZED';

    RETURN FOUND;
END;
$function$;


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

REVOKE ALL ON FUNCTION public.cancel_view_session(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_view_session(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.cancel_campaign(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_campaign(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.pause_campaign(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pause_campaign(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.resume_campaign(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resume_campaign(UUID) TO authenticated;
