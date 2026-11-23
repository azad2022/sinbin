# SiteBin Backend / Database Audit — Session 2
**Observed:** 2026-11-23 (UTC)  
**Scope:** Backend, Supabase, PostgreSQL, migrations, security and view-session lifecycle only.  
**Production writes:** None. All database queries in this audit were read-only.

## 1. Repository and migration provenance

- Repository: `azad2022/sinbin`, default branch `main`.
- `main` HEAD at audit: `6b25a6bccf6bf6c47b4d2f04c008d32e378b5c14` (2026-11-05).
- Existing branch `db/rolling-30d-leaderboard-20261121`: HEAD `1d38cd4c70a07cbcc598a5e3458f31d55aae3220`, exactly two commits ahead of `main`, no commits behind.
- Those two commits add:
  - `20261121082350_sitebin_weekly_leaderboard_rolling_30d_20261121.sql`
  - `20261121082428_sitebin_leaderboard_view_read_only_20261121.sql`
- Both migration versions are already present in the live Supabase migration history. They must not be recreated or reapplied.
- This audit is recorded on `db/daily-sequential-featured-lifecycle-20261123`, based on the existing rolling-30d branch so that the already-applied migrations remain in ancestry.
- PR #42 (rate-limit policy-table change) and PR #43 (WebView SSL/Auto View recovery) were open Draft PRs at audit. Neither was merged or changed in this task. PR #43 is Android/WebView scope and is excluded from Session 2 implementation.

## 2. Supabase environment and migration history

- Project ref: `kypzzxqhmvhttyhjengk` (`sinbin`).
- Status: `ACTIVE_HEALTHY`.
- PostgreSQL: `17.11.0.002` (engine 17).
- Region: `ap-northeast-1`.
- Database session timezone: `UTC`.
- The live migration history includes the core/hardening, daily and weekly leaderboard, reconciliation, weekly featured assignment/quota, referral, coin-store and 2026-11-21 rolling-30d/view-read-only migrations. The last recorded versions are `20261121082350` and `20261121082428`.
- Supabase development branches: none existed at the time of audit. A development branch incurs a quoted recurring cost and was not created without approval.

## 3. Relevant live database objects

### Tables
- `public.view_sessions`
- `public.campaigns`
- `public.profiles`
- `public.daily_view_leaderboard`
- `public.weekly_view_leaderboard`
- `private.weekly_featured_campaign_assignment`
- `private.weekly_featured_campaign_quota`
- `private.rate_limit_buckets`

### Views
- `public.daily_view_leaderboard_public`: `security_invoker=true`.
- `public.weekly_view_leaderboard_public`: `security_invoker=false`; despite its name, its query computes a rolling 30-day completed-view aggregate.
- The latter returns the compatibility column `week_start` as the current UTC week start. Existing Android code filters this column, so the current RPC/view contract must remain available until the Android migration is done.

### Functions in the lifecycle path
- `public.request_view_session()`
- `public.signal_content_ready(uuid)`
- `public.complete_view_session(uuid,text)`
- `public.cancel_view_session(uuid)`
- `public.cancel_campaign(uuid)`
- `private.reconcile_view_leaderboards()`
- `private.reconcile_view_leaderboard_entry(uuid,timestamptz)`
- `private.record_weekly_featured_campaign_quota()`
- `private.check_request()`
- `public.check_request()`

### Triggers
- `trg_reconcile_view_leaderboards_write`
- `trg_reconcile_view_leaderboards_update`
- `trg_record_weekly_featured_campaign_quota`
- `trg_release_weekly_featured_campaign_quota_delete`
- `trg_track_referral_completed_view`
- Campaign URL / referral-key validation triggers.

### Constraints and indexes
- Daily leaderboard primary key: `(leaderboard_date,user_id)`.
- Weekly leaderboard primary key: `(week_start,user_id)`.
- Active session uniqueness: `idx_view_sessions_active_viewer`, partial on `INITIALIZED` / `CONTENT_READY`.
- Session idempotency: unique partial `idx_view_sessions_idempotency_key`.
- Existing campaign/session indexes include `idx_view_sessions_campaign_id`, `idx_view_sessions_viewer_campaign`, `idx_view_sessions_viewer_completed_at`.
- Current featured-session constraint requires legacy week/owner/rank fields together and hard-limits rank to 1..5.
- Campaign budget constraints enforce `spent_budget + reserved_budget + refunded_budget = total_budget`, completed views within target, and `spent_budget = completed_views * cost_per_view`.

## 4. Actual lifecycle and accounting behavior

1. `request_view_session()` authenticates a non-anonymous user and takes a per-viewer advisory transaction lock.
2. It returns the viewer's existing active session if younger than three minutes (unless keyword resolution is no longer ready); otherwise it marks that session `EXPIRED`.
3. New sessions are inserted as `INITIALIZED`.
4. `signal_content_ready()` changes `INITIALIZED` to `CONTENT_READY` and records `content_ready_at`.
5. `complete_view_session()` locks the session, validates viewer ownership, idempotency key, ready state and elapsed duration, then locks the campaign and wallet rows. It moves campaign money from `reserved_budget` to `spent_budget`, updates wallet accounting, marks the session `COMPLETED`, and writes ledger entries in one transaction.
6. Completion retry is idempotent: the same session/key returns `already_completed=true` after completion.
7. `cancel_view_session()` only changes the caller's active session to `CANCELLED`. Existing triggers release a legacy featured quota reservation.
8. Expiration is not scheduled: the three-minute expiry is currently checked when that viewer requests another session. No `cron.job` relation or `pg_cron` extension was found.
9. `cancel_campaign()` sets the campaign to `CANCELLED` and refunds remaining campaign budget, but does not cancel its existing active sessions.

Important accounting distinction:
- `campaigns.reserved_budget` is the advertiser's remaining monetary budget, not a count of in-flight impression reservations.
- Campaign creation reserves the full campaign budget up front. Completion decrements `reserved_budget` by one `cost_per_view`; campaign cancellation refunds the remaining amount.
- The current request path locks a campaign row only during selection. It does not maintain or test a durable per-campaign count of active sessions before creating another session. A transaction-scoped row lock alone does not reserve a target slot after the request commits.

## 5. Actual selection behavior versus approved policy

The live `request_view_session()` still uses weekly fields and logic:
- Computes the current UTC week and viewer's weekly `content_ready_at` count.
- Considers only ranks 1 through 5.
- Reads `weekly_view_leaderboard`, not `daily_view_leaderboard`.
- Pins one campaign per owner/week in `private.weekly_featured_campaign_assignment`.
- Uses `private.weekly_featured_campaign_quota`, whose `quota_views` is derived from the owner's featured score / personal completed views.
- If the selected rank's campaign or quota is unavailable, it falls back to ordinary randomized distribution; it does not walk subsequent ranks.
- There is no per-viewer/per-UTC-day cursor, no all-rank scan, and no durable “last actually selected rank” progression.
- The existing two-minute advertiser diversity exclusion applies to recent completed views.
- Existing request RPC has zero arguments and does not accept a client request-idempotency key. Immediate retry is handled by returning the existing active session; a retry after the 3-minute active-session expiry cannot be distinguished from a new request without a client idempotency key.

## 6. Data integrity observations (live read-only queries)

- Sessions total: 4,669.
- `COMPLETED`: 3,622.
- `CANCELLED`: 996.
- `EXPIRED`: 41.
- `CONTENT_READY`: 3.
- `INITIALIZED`: 7.
- Daily leaderboard rows: 129; sum of `completed_views`: 3,622.
- Independent aggregation of completed sessions by UTC day and viewer: 129 rows, sum 3,622, zero mismatches against `daily_view_leaderboard`. This check passed.
- All 10 currently active sessions were older than the existing three-minute expiry threshold at audit time.
- Of campaigns with active sessions, 3 were already beyond target when active sessions were counted: two campaigns were `COMPLETED` and one was `CANCELLED`. The maximum observed overage was 2 active sessions over target. These rows are stale/invalid under the existing lifecycle, not grounds to change financial balances.
- Campaigns total: 64; ACTIVE: 26.
- Campaign `reserved_budget` total: 87,399; `spent_budget` total: 36,610.
- A separate check comparing each profile's `reserved_coins` with the sum of its ACTIVE/PAUSED campaign `reserved_budget` found zero mismatched profiles. Do not “repair” this by changing wallet or campaign money.
- Legacy weekly featured data: 22 owner/week campaign assignments; 13 quota rows. Among owner/week groups that have a quota row, completed and active reservation counters match the corresponding session states. Ten owner/week groups have no quota row; historic featured sessions in total are 55 completed, while persisted quota rows total 38 completed. The legacy tables are not suitable as the new cursor or budget source and must be retained as historical data, not rewritten to fabricate parity.

## 7. RLS, grants and Security Advisor

### Verified access behavior
- Authenticated read of `daily_view_leaderboard_public` succeeded and returned 129 rows.
- Authenticated read of `weekly_view_leaderboard_public` succeeded and returned 27 rows.
- Anonymous SELECT privilege on both leaderboard views is absent.
- `authenticated` has no direct INSERT/UPDATE privilege on `view_sessions`.
- Daily leaderboard base data is exposed through column-level SELECT grants only; the public view is invoker-mode.
- The daily view's current ACL is broader than required (non-SELECT privileges are recorded for `authenticated`). Migration should revoke all and re-grant SELECT only.
- `private` schema is not currently granted USAGE to `anon` or `authenticated`.

### Security Advisor findings at audit
- ERROR: one `security_definer_view` — `public.weekly_view_leaderboard_public`.
- WARN: public `public.check_request()` is executable by `anon` and `authenticated`.
- WARN: 21 authenticated-callable SECURITY DEFINER RPCs. The lifecycle RPCs use empty search_path and validate `auth.uid()`; their execute grants are required by the current Android RPC contract.
- INFO: 16 RLS-enabled tables without policies. These are default-deny by RLS; grants and schema exposure still need object-by-object review.
- WARN: leaked-password protection disabled in Supabase Auth (dashboard/Auth configuration, not a SQL migration).
- Performance Advisor: two unindexed foreign keys in the coin-store private schema and seven unused indexes. Not changed in this scoped leaderboard/lifecycle migration.
- Health Advisor: no findings.

### Pre-request hook
- `authenticator` has `pgrst.db_pre_request=public.check_request`.
- `private.check_request()` also exists but is not the configured hook; its execute privilege is only granted to `authenticator`.
- Do not revoke `anon` / `authenticated` execute from the active pre-request hook without replacing and testing the hook. PostgREST invokes it for API requests and needs the appropriate role grants.

## 8. Android / RPC compatibility

- Android reads `public.weekly_view_leaderboard_public` via the existing `week_start` filter and selects `rank,user_handle,completed_views`.
- `request_view_session()` is called with no arguments; returned JSON includes `id,campaign_id,target_url,domain,keyword,required_duration_seconds,reward_coins,started_at,featured_rank`.
- Session lifecycle RPCs are `signal_content_ready(p_session_id)`, `complete_view_session(p_session_id,p_idempotency_key)`, and `cancel_view_session(p_session_id)`.
- Do not change those signatures or JSON keys in Session 2.
- Any new rolling30 view should be additive; the old view name/column shape must remain until Android is migrated in Session 3.

## 9. Migration / implementation plan (not yet applied)

1. Create a private, RLS-protected completed-view event projection with one unique row per completed session. Backfill only the rolling window from `view_sessions`; keep `view_sessions` as the historical source of truth. Maintain the projection with idempotent completion/reversal and profile-handle triggers.
2. Create `public.rolling_30d_view_leaderboard_public` as `security_invoker=true` over the private projection; maintain `public.weekly_view_leaderboard_public` as a compatibility wrapper with the old `week_start` shape, also invoker mode. Apply authenticated SELECT-only grants. Fix deterministic tie ordering with user_id as the final key in both daily and rolling ranking.
3. Add a per-viewer/per-UTC-day cursor keyed by `(viewer_id,day_utc)`, and a private assignment audit table keyed by viewer/day/request position with owner, campaign, actual live rank, score/handle snapshot, session, reservation status, timestamps and expiry.
4. Replace the top-five quota selection with a live UTC daily rank scan. Start after the last actually selected owner/rank, skip self and previously served owners, check every eligible campaign for that owner, continue to the next rank, and persist exhaustion for the viewer/day before using ordinary distribution.
5. Centralize campaign selection under a campaign-row lock. In the same transaction, verify `completed_views + active-session-reservations < target_views`, budget remains, campaign is active, content is ready, and anti-repeat still passes; create the session and assignment before releasing the lock. Active `INITIALIZED`/`CONTENT_READY` session rows are the durable reservation. Do not reinterpret `reserved_budget` as a view counter.
6. Add a partial campaign/status session index and bounded stale-session expiry. On each request, expire stale active sessions and sessions belonging to terminal campaigns; maintain assignment reservation states via trigger. Do not add pg_cron without a separate verified operational need.
7. Preserve the old weekly assignment/quota tables and triggers for historical session transitions; new daily assignments must not write the legacy weekly reservation columns.
8. Widen the featured rank field/constraint to support all ranks while preserving the existing JSON `featured_rank` contract.
9. Add PostgreSQL integration tests using isolated fixture users/campaigns; concurrency tests must use independent database transactions. No production SQL should be used for iterative migration testing.

## 10. Status

- Read-only audit: completed for the objects and queries listed above.
- Data reconciliation: PASS (zero daily aggregation mismatches).
- Authenticated leaderboard read smoke: PASS for both current public views.
- Current target/capacity behavior: FAIL observed (3 campaigns overbooked by stale/active sessions).
- Sequential / all-rank / next-eligible / campaign-reservation concurrency tests: NOT RUN.
- Migration creation/application on a development database: BLOCKED pending approval of the quoted Supabase branch recurring cost.
- Production database changes: NONE.
