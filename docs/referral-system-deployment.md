# SiteBin referral system — deployment and operational notes

The referral system is server-authoritative. The client submits only the inviter's existing public `user_handle`; it never supplies the inviter UUID, progress counters, reward amounts, or eligibility flags.

## Milestones

- After an invitee registers one direct inviter, only eligible completed view sessions started after registration contribute to progress.
- At 100 valid completed views, 500 coins are awarded to the invitee and 500 to the direct inviter.
- A registrable website is derived from the server-validated URL using the pinned `tldts@6.1.86` Public Suffix List rules, including private suffixes. One registrable site increases the distinct-site count only once per referral.
- At 500 distinct websites, a further 20,000 coins are awarded to each direct party. Together with the 100-view milestone, that is 20,500 coins per party when both milestones complete.
- Descendants are direct referrals of their own inviter. Rewards never cascade to an ancestor.
- The database trigger updates progress in the same transaction that changes a server-validated session to `COMPLETED`. Reward balances, ledger entries, grant rows, and milestone timestamps commit atomically.

## Deployment and verification

1. Deploy the updated `campaign-url-preflight` Edge Function before applying the original referral-system migration; the referral progress trigger consumes the registrable-site metadata written by preflight.
2. Apply the new forward migration that removes referral-push infrastructure and sets the second milestone to 20,000 coins. Verify its exact version in Supabase migration history.
3. Run `supabase/tests/sitebin_referral_rewards.sql` against a disposable database or an explicitly authorized test database. It runs in a transaction and ends with `ROLLBACK`; never remove that rollback when running against a shared environment.
4. Validate using two independent accounts/devices: register one direct invitation, then verify the 100-view milestone and the 500-distinct-site milestone against `public.referrals`, `private.referral_reward_grants`, and the corresponding `public.coin_ledger` entries.

Referral progress and reward status are shown in Settings under **وضعیت حساب کاربری**. Referral registration does not send a push notification. The existing local coin-receipt notification remains separate and unchanged.

## Security and integrity invariants

- A referral cannot be self-referred, re-attributed, duplicated, or registered as a recursive cycle.
- Device-identity evidence rejects direct referrals when the two accounts overlap on the currently recorded device identifiers. Device evidence is risk evidence, not proof of unique humans.
- Progress rows are keyed by session and referral/site to prevent replay. Referral progress does not cascade-delete merely because campaign/session source rows are pruned.
- Reward amounts are selected by the server-side milestone function; client parameters cannot choose them.
- The public referrals table is read-only to authenticated clients and filtered by direct-relationship RLS. Private progress and grant tables are not directly exposed through PostgREST.
- Do not reset profile balances by hand. Validate referral grant rows and their corresponding `coin_ledger` entries.

## Important dependency

Referral progress trusts the existing server-authoritative `complete_view_session` path; it does not independently prove what final cross-origin document was visually rendered inside the WebView. The 20,000-coin tier should not be advertised as fraud-proof or enabled for broad production rollout until separate Viewer navigation/origin hardening is merged and regression-tested.
