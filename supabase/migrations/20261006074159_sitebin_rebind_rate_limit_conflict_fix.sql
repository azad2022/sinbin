-- SiteBin: make auth-account rebind safe when the pre-request rate limiter
-- already created buckets for the newly-created Auth UID.
BEGIN;

CREATE SCHEMA IF NOT EXISTS private;

CREATE OR REPLACE FUNCTION private.rebind_user_account(
    p_old_uid uuid,
    p_new_uid uuid,
    p_install_id text
)
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

    DELETE FROM public.profiles WHERE id = p_old_uid;
END;
$function$;

REVOKE ALL ON FUNCTION private.rebind_user_account(uuid,uuid,text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.rebind_user_account(uuid,uuid,text) TO postgres;

COMMIT;
