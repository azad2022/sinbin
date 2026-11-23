-- Defense-in-depth for private device/bonus security state.
-- These tables intentionally have no client-facing policies or grants.
-- Server-side SECURITY DEFINER RPCs owned by the database security owner
-- remain the only supported access path.

-- This relation is consumed by the daily-bonus continuity migration that
-- follows. It was referenced here and by that RPC but was never created in
-- the migration history, making a clean replay impossible.
CREATE TABLE IF NOT EXISTS private.daily_bonus_device_claims (
    device_identity_id UUID NOT NULL
        REFERENCES private.device_identities(id) ON DELETE RESTRICT,
    grant_date DATE NOT NULL,
    beneficiary_auth_uid UUID NOT NULL
        REFERENCES auth.users(id) ON DELETE RESTRICT,
    amount BIGINT NOT NULL CHECK (amount > 0),
    daily_bonus_grant_id UUID NOT NULL
        REFERENCES public.daily_bonus_grants(id) ON DELETE RESTRICT,
    granted_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.clock_timestamp(),
    CONSTRAINT daily_bonus_device_claims_pkey
        PRIMARY KEY (device_identity_id, grant_date),
    CONSTRAINT daily_bonus_device_claims_grant_unique
        UNIQUE (daily_bonus_grant_id)
);

CREATE INDEX IF NOT EXISTS idx_daily_bonus_device_claims_beneficiary
    ON private.daily_bonus_device_claims (beneficiary_auth_uid, grant_date DESC);

ALTER TABLE private.daily_bonus_device_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.daily_bonus_device_claims FROM PUBLIC, anon, authenticated, service_role;

ALTER TABLE private.device_identities ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.welcome_bonus_entitlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.welcome_bonus_attempt_buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.daily_bonus_device_claims ENABLE ROW LEVEL SECURITY;
