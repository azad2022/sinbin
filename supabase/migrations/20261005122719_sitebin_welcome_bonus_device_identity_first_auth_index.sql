-- Production index for device identity ownership lookups.
CREATE INDEX IF NOT EXISTS idx_device_identities_first_auth_uid
  ON private.device_identities(first_auth_uid);
