BEGIN;

-- Cover the referral reward -> coin ledger foreign key. This keeps coin-ledger
-- maintenance from scanning every reward grant as referral volume grows.
CREATE INDEX IF NOT EXISTS idx_referral_reward_grants_ledger_entry
  ON private.referral_reward_grants (ledger_entry_id)
  WHERE ledger_entry_id IS NOT NULL;

COMMIT;
