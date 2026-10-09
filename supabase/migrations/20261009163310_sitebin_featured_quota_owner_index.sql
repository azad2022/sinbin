BEGIN;

CREATE INDEX IF NOT EXISTS idx_weekly_featured_campaign_quota_owner_id
  ON private.weekly_featured_campaign_quota (owner_id);

COMMIT;
