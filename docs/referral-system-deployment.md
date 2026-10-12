# SiteBin referral system — deployment and operational notes

This feature is server-authoritative. The client submits only the inviter's existing public `user_handle`; it never supplies the inviter UUID, progress counters, reward amounts, or eligibility flags.

## Milestones

- After the invitee registers one direct inviter, only eligible completed view sessions started after that registration contribute to progress.
- A completed valid view earns 500 coins for the inviter and 500 for the invitee at 100 views.
- A registrable website is derived from the server-validated URL with the pinned `tldts@6.1.86` Public Suffix List rules, including private suffixes. One registrable site can increase the distinct-site count only once per referral.
- At 500 distinct websites, a further 25,000 coins are granted to each direct party.
- Descendants are direct referrals of their own inviter. Rewards never cascade to an ancestor.
- The database trigger updates progress at the same commit that changes a server-validated session to `COMPLETED`. Reward balances, ledger entries, grant rows, and milestone timestamps commit atomically.

## Required rollout order

1. Merge the source and migration files into the deployment branch after CI passes.
2. Deploy the updated `campaign-url-preflight` Edge Function **before** applying `20261012184746_sitebin_referral_system.sql`. The new database trigger consumes the registrable-site metadata stored by preflight.
3. Apply the SQL migration and verify its version in Supabase migration history.
4. Deploy the `send-referral-push` Edge Function with JWT verification enabled.
4a. Apply `20261012185446_sitebin_referral_reward_ledger_index.sql` when present in the merged migration history; it covers the reward-ledger foreign key.
5. Run `supabase/tests/sitebin_referral_rewards.sql` against a disposable database or an explicitly authorized test database. It runs inside a transaction and ends with `ROLLBACK`; never remove that rollback when running against a shared environment.
6. Complete device testing with two independent accounts/devices, including one invite, the 100-view milestone, and a controlled 500-domain milestone test. Verify the live ledger, not only the UI.

## Push-notification configuration

The Android Firebase configuration is deliberately not committed.

- Configure the GitHub repository secret `GOOGLE_SERVICES_JSON_BASE64` with the base64-encoded Firebase `google-services.json` for Android package `sitebin.azerakhsh.ir`. The CI checks its package if the secret is present. If it is absent, the Android build still compiles, but FCM token registration is unavailable and push delivery is **not operational**.
- Configure the Supabase Edge Function secret `FCM_SERVICE_ACCOUNT_JSON` with the JSON service-account credential from the **same Firebase project** as the Android configuration. Enable the Firebase Cloud Messaging API for that project. Never commit this JSON, expose it to the Android client, or print it in logs.
- The Edge Function uses OAuth 2.0 with the service account to send FCM HTTP v1 data messages. It claims a database outbox item, sends outside the coin-award transaction, and records delivery/retry status through service-role-only RPCs.
- The client permission, the Android notification-channel setting, the local `اعلان‌های زیرمجموعه‌ها` toggle, an active FCM token, and both server-side configuration items must all permit delivery. A missing push configuration must not roll back a successfully registered referral or alter its payout.

Do not claim that push is live until a real Android device receives a registration notification and the outbox records the accepted FCM send.

## Security and integrity invariants

- A referral cannot be self-referred, re-attributed, duplicated, or registered as a recursive cycle.
- Existing device-identity evidence is used to reject direct referrals where the two accounts overlap on the currently recorded device identifiers. Device evidence is risk evidence, not proof of unique humans.
- Progress rows are keyed by session and referral/site to prevent replay. Referral progress does not cascade-delete merely because campaign/session source rows are pruned.
- Server reward amounts are hard-coded by the milestone in the database; client parameters cannot choose them.
- The public referrals table is read-only to authenticated clients and filtered by direct relationship RLS. Private progress, grants, token, and outbox tables are not directly exposed through PostgREST.
- Do not reset profile balances by hand. Validate referral grant rows and the corresponding `coin_ledger` entries.

## Important dependency

Referral progress intentionally trusts the existing server-authoritative `complete_view_session` path. It does not independently prove what final cross-origin document was visually rendered inside the WebView. Because the previously identified WebView navigation/origin-pinning issue can undermine the meaning of a completed view, the 25,000-coin tier should not be advertised as fraud-proof or enabled for broad production rollout until that separate Viewer hardening is merged and regression-tested.
