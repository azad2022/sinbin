-- CI-only fixtures for pre-existing demo owners referenced by
-- 20261004101500_sitebin_default_viewer_demo_pool.sql.
--
-- The production migration history contains these two identities before this
-- migration runs. A clean disposable replay has no auth.users/profiles rows,
-- so reproduce only the minimum historical prerequisite locally. These are
-- synthetic accounts and synthetic starting balances; this file must never be
-- run against a hosted database.
--
-- 75 coins are required per owner because the CI-only demo campaign fixture
-- reserves 25 coins for each of its three default campaigns.

BEGIN;

INSERT INTO auth.users (
    id,
    aud,
    role,
    email,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    is_anonymous
)
VALUES
(
    'cf96b011-3163-4b44-bb5d-ba6d8741e456'::uuid,
    'authenticated',
    'authenticated',
    'sitebin_ci_demo_owner_cf96b011@sitebin.internal',
    pg_catalog.clock_timestamp(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"ci_fixture":"historical_demo_owner"}'::jsonb,
    pg_catalog.clock_timestamp(),
    pg_catalog.clock_timestamp(),
    false
),
(
    '0328a88e-0c70-4d32-829c-9049b8096cfb'::uuid,
    'authenticated',
    'authenticated',
    'sitebin_ci_demo_owner_0328a88e@sitebin.internal',
    pg_catalog.clock_timestamp(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"ci_fixture":"historical_demo_owner"}'::jsonb,
    pg_catalog.clock_timestamp(),
    pg_catalog.clock_timestamp(),
    false
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (
    id,
    user_handle,
    app_install_id,
    available_coins,
    reserved_coins,
    lifetime_earned,
    lifetime_spent,
    trust_score,
    completed_views_count,
    received_views_count,
    welcome_bonus_claimed,
    created_at,
    updated_at
)
VALUES
(
    'cf96b011-3163-4b44-bb5d-ba6d8741e456'::uuid,
    'sitebin_ci_demo_owner_cf96b011',
    'sitebin_ci_demo_install_cf96b011',
    75,
    0,
    75,
    0,
    100,
    0,
    0,
    true,
    pg_catalog.clock_timestamp(),
    pg_catalog.clock_timestamp()
),
(
    '0328a88e-0c70-4d32-829c-9049b8096cfb'::uuid,
    'sitebin_ci_demo_owner_0328a88e',
    'sitebin_ci_demo_install_0328a88e',
    75,
    0,
    75,
    0,
    100,
    0,
    0,
    true,
    pg_catalog.clock_timestamp(),
    pg_catalog.clock_timestamp()
)
ON CONFLICT (id) DO NOTHING;

DO $assert$
BEGIN
    IF (
        SELECT count(*)
        FROM public.profiles
        WHERE id IN (
            'cf96b011-3163-4b44-bb5d-ba6d8741e456'::uuid,
            '0328a88e-0c70-4d32-829c-9049b8096cfb'::uuid
        )
          AND available_coins >= 75
    ) <> 2 THEN
        RAISE EXCEPTION
            'CI_FIXTURE_FAILED: both historical demo owners must exist with at least 75 available coins';
    END IF;
END;
$assert$;

COMMIT;
