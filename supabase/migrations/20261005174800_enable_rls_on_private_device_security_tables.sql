-- Defense-in-depth for private device/bonus security state.
-- These tables intentionally have no client-facing policies or grants.
-- Server-side SECURITY DEFINER RPCs owned by the database security owner
-- remain the only supported access path.

ALTER TABLE private.device_identities ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.welcome_bonus_entitlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.welcome_bonus_attempt_buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.daily_bonus_device_claims ENABLE ROW LEVEL SECURITY;
