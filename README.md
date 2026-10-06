# SiteBin

SiteBin is an Android application for reciprocal website traffic: users can act as viewers to earn coins and can spend coins to create website-view campaigns. The production architecture is server-authoritative: financial balances, ledgers, campaign budgets, view completion, transfers, bonuses, and entitlement decisions are executed by Supabase/PostgreSQL RPCs rather than trusted Android state.

> This document is the repository-level technical source of truth for architecture, identity continuity, signing/build rules, backend boundaries, security model, testing, and release procedure. When this document conflicts with the actual source, database schema, or CI artifact, the evidence from the running system wins and this README must be updated.

---

## 1. Non-negotiable application identity

These values are part of the permanent SiteBin identity and must not change without an explicit migration plan.

| Item | Required value |
|---|---|
| Android applicationId | `sitebin.azerakhsh.ir` |
| Standard APK filename | `sitebin.azerakhsh.apk` |
| Production Release certificate SHA-256 | `6F:25:9D:3C:45:57:BA:4B:4E:4C:94:89:F3:8B:CD:85:E7:EC:9F:46:41:C8:73:46:F9:57:8B:D0:F4:FF:29:00` |
| Current CI Debug certificate SHA-256 | `AB:27:EE:09:3B:25:E1:0E:E5:70:15:37:DA:6E:CE:47:0C:45:6D:88:1C:35:89:AD:CE:61:01:FB:5B:F4:0F:C5` |

The Release fingerprint is public certificate metadata, not a secret. The Release private key, keystore, store password, and key password are secrets and must never be committed to the repository or written to logs.

The applicationId is the Android application identity. The signing certificate is part of the update identity. Neither is the user's account ID.

---

## 2. The most important identity rule

**Package name is not the user's identity.**

SiteBin has several different identity layers:

1. **Android application identity**: `sitebin.azerakhsh.ir`.
2. **Signing identity**: the certificate used to sign the APK/AAB.
3. **Supabase Auth UID**: the current authenticated principal used by PostgreSQL/RLS.
4. **Device identity**: server-side continuity record used to associate reinstalling clients with the existing account.
5. **installId**: local installation/session identifier. It is useful telemetry/continuity input but is not a trust root.
6. **user_handle**: human-facing account handle such as `user_xxxxxxxx`; it is not an authentication secret and must not be used as a security boundary.

An Android update that keeps the same applicationId and Release signing certificate is an update of the same application. A Debug build must also keep a stable Debug signing key inside the CI build family if Debug uninstall/reinstall continuity is being tested.

---

## 3. Architecture at a glance

```text
Android UI (Jetpack Compose)
        |
        v
SiteBinViewModel
        |
        v
SiteBinRepository
        |
        v
ServerAuthoritativeEngine
        |
        +----------------------+
        |                      |
        v                      v
SupabaseApiClient       SupabaseRealtimeClient
        |
        +----------------------+
        |
        v
Supabase REST / Auth / RPC
        |
        v
PostgreSQL
        |
        +--> profiles
        +--> coin_ledger
        +--> campaigns
        +--> view_sessions
        +--> coin_transfers
        +--> bonuses / entitlements
        +--> private device identity + rate limiting
```

The Android application is a client. It requests operations and renders server results. It must never be treated as the authoritative owner of money, campaign progress, bonus eligibility, or view completion.

---

## 4. Repository structure

### Android

- `app/src/main/java/com/example/MainActivity.kt`
  - Android entry point.
  - Starts Compose UI.
  - Observes lifecycle and tells the ViewModel when the app enters/leaves foreground.
  - Handles notification permission flow.

- `app/src/main/java/com/example/SiteBinApp.kt`
  - Application-level Android initialization.

- `app/src/main/java/com/example/ui/SiteBinViewModel.kt`
  - UI state owner.
  - Navigation state.
  - Viewer orchestration.
  - Campaign creation workflow.
  - Coin transfer workflow.
  - Foreground reconciliation.
  - Realtime event reaction.
  - Low-frequency polling fallback.

- `app/src/main/java/com/example/data/repository/SiteBinRepository.kt`
  - Boundary between UI state and backend.
  - Holds server state flows.
  - Performs startup initialization.
  - Refreshes account/ledger/campaign state.
  - Delegates authoritative mutations to the backend engine.

- `app/src/main/java/com/example/data/backend/BackendContract.kt`
  - Contracts for the authoritative backend engine and realtime capability.

- `app/src/main/java/com/example/data/backend/SupabaseApiClient.kt`
  - Supabase Auth lifecycle.
  - REST requests.
  - RPC calls.
  - Session persistence.
  - Realtime transport ownership.

- `app/src/main/java/com/example/data/backend/SupabaseRealtimeClient.kt`
  - Lightweight Supabase Realtime WebSocket implementation.
  - Foreground-only.
  - Subscribes to changes affecting the current user.
  - Realtime events are hints that trigger authoritative reads; events never directly mutate financial state.

- `app/src/main/java/com/example/data/backend/BackendManager.kt`
  - Selects the configured backend.
  - Refuses to silently fall back to a local/emulated engine when Supabase configuration is missing.
  - Enforces Release identity validation.

- `app/src/main/java/com/example/data/security/AndroidDeviceEvidenceProvider.kt`
  - Collects platform/device continuity evidence:
    - Android ID
    - App Set ID
    - installation-key public-key fingerprint

- `app/src/main/java/com/example/core/security/AppIdentityGuard.kt`
  - Release package/applicationId check.
  - Release signing certificate check.
  - Client-side anti-repackaging gate.

- `app/src/main/java/com/example/core/security/UrlSecurityPolicy.kt`
  - URL normalization and blocking of unsafe destinations.

- `app/src/main/java/com/example/core/security/SafeWebView.kt`
  - Viewer WebView lifecycle.
  - Safe navigation.
  - SSL/error handling.
  - Content-visible signal.
  - Memory/lifecycle cleanup.

- `app/src/main/java/com/example/core/network/SiteSpeedChecker.kt`
  - Client-side site-speed diagnostics.
  - This is advisory only; server-side campaign preflight remains authoritative.

- `app/src/main/java/com/example/notifications/SiteBinNotificationManager.kt`
  - Coin-received notifications.

### Compose screens

- `HomeScreen.kt`
  - Account summary, quick actions, bonus banners, recent campaigns.

- `ViewerScreen.kt`
  - Current viewing session.
  - Page loading state.
  - Server-authoritative completion workflow.
  - Auto-advance handling.

- `CreateCampaignScreen.kt`
  - Website URL entry.
  - Optional keyword mode.
  - Duration and cost selection.
  - Preflight status.
  - Campaign submission.

- `CampaignsScreen.kt`
  - Active, paused, completed, and cancelled campaigns.
  - Pause/resume/cancel operations.

- `WalletScreen.kt`
  - Available/reserved coins.
  - Lifetime counters.
  - Transaction history.
  - Coin transfer.

- `SettingsScreen.kt`
  - Account identity.
  - Notifications.
  - Auto-view.
  - Application preferences.
  - Help/legal/about entries.

- `HelpGuideScreen.kt` + `SiteBinHelpContent.kt`
  - In-app product documentation.

### Backend

- `supabase/migrations/`
  - Database schema, policies, RPCs, security, identity continuity, bonuses, rate limiting, viewer/campaign logic.

- `supabase/functions/campaign-url-preflight/index.ts`
  - Authoritative website preflight.

- `supabase/functions/resolve-campaign-target/index.ts`
  - Keyword campaign target resolution.

- `supabase/tests/`
  - Transactional PostgreSQL security/regression tests.

### CI/CD

- `.github/workflows/android-ci.yml`
  - Debug CI on pushes/PRs.
  - Production Release build on manual dispatch or the explicit release commit marker.

---

## 5. Startup lifecycle

The Android startup path is intentionally server-first.

```text
MainActivity
  -> SiteBinViewModel
    -> SiteBinRepository
      -> initializeServerState()
        -> load pricing
        -> collect device evidence
        -> ensure Supabase Auth session
        -> init_user_account(...)
        -> claim/reconcile daily bonus
        -> refresh auto-view status
        -> fetch transactions
        -> fetch campaigns
        -> Ready
```

The UI should not treat the locally-generated placeholder account as authoritative. The final account comes from PostgreSQL.

---

## 6. Authentication model

SiteBin currently uses real Supabase Auth without user-facing email/password registration.

The client:

1. Attempts to reuse a valid encrypted access/refresh session.
2. Attempts token refresh when necessary.
3. If there is no valid session, it derives credentials from a cryptographically random local device secret.
4. It attempts compatibility login for older credentials.
5. It attempts login using the current bounded credential scheme.
6. If no account exists, it signs up a new Auth user.
7. It then calls `init_user_account(...)` with device evidence.

The session is stored using Android Keystore-backed encryption inside `SupabaseApiClient`.

Important distinction:

- A Supabase Auth UID can change after uninstall/reinstall because local Auth state and device-keystore material can disappear.
- That does **not** mean the SiteBin account should change.
- The server-side device identity is responsible for continuity and can rebind an existing account to the newly-created Auth UID when the evidence supports that relationship.

---

## 7. Device continuity model

The server maintains `private.device_identities`.

Evidence collected by Android is:

- Android ID
- App Set ID + scope
- Installation-key public-key SHA-256 fingerprint
- local installId as a legacy/continuity input

The server hashes sensitive platform identifiers with its private HMAC mechanism before storing them.

The continuity algorithm is deliberately conservative:

1. Find device identities matching strong submitted evidence.
2. Detect conflicts rather than blindly choosing one.
3. Lock the selected device identity.
4. Record the previous canonical Auth UID before changing `current_auth_uid`.
5. If the current Auth UID has no profile and a previous canonical account exists, call `private.rebind_user_account(old_uid, new_uid, install_id)`.
6. Rebind all account-owned foreign-key data.
7. Preserve the existing account handle and financial state.
8. Delete the old profile.
9. Update the device identity to the current Auth UID.
10. Only create a truly new profile when no valid prior account exists.

A device identity is therefore the continuity anchor; the Auth UID is the current authenticated owner of that account.

### What is not allowed

Do not merge arbitrary users because their handles look similar.

Do not merge users solely because they share one weak signal.

Do not let the client tell the server which Auth UID should be trusted.

Do not use `user_handle`, installId, or package name alone as proof of account ownership.

---

## 8. The reinstall/update distinction

### Normal update

Expected:

```text
old Release
  -> same package
  -> same Release signing certificate
  -> same installed app data/keystore
  -> same Auth session when still valid
  -> same Auth UID
  -> same profile
```

### Uninstall/reinstall

Expected:

```text
old installation deleted
  -> new local installation state
  -> possibly new Auth UID
  -> same device evidence
  -> existing device_identity found
  -> server-side Rebind
  -> same SiteBin account
```

### Dangerous case

```text
APK A signed with key A
APK B signed with key B
  -> platform-scoped Android ID may differ
  -> backend may legitimately see a different device identity
```

Therefore the Debug signing identity must be stable across CI builds used for continuity testing, and the Release signing certificate must never change.

---

## 9. Local installation identity and Android Backup

`app_install_id` is stored in `sitebin_prefs`.

The repository deliberately excludes both:

- `sitebin_supabase_session`
- `sitebin_prefs`

from Android cloud backup/device transfer rules.

Additionally, an installation marker is stored in the session preference store. A missing marker means the client must treat the local install state as fresh and must not trust a restored installId.

This prevents a stale restored installation ID from being combined with a newly-generated device secret/Auth user.

---

## 10. Server-authoritative coin economy

Financial state lives in PostgreSQL.

The important account fields include:

- `available_coins`
- `reserved_coins`
- `lifetime_earned`
- `lifetime_spent`
- `welcome_bonus_claimed`
- view counters

The financial audit trail is `public.coin_ledger`.

The Android client may display these values but must not directly increment/decrement them.

### Welcome bonus

The welcome reward is decided server-side.

The server uses:

- device identity
- device-level entitlement
- user-level welcome grant
- evidence quality/risk
- attempt rate limits

The welcome amount is not a client-controlled RPC argument.

The authoritative helper is:

`private.grant_welcome_bonus_if_eligible(...)`

It prevents duplicate device/user grants and writes the entitlement, profile balance, and ledger atomically.

### Daily bonus

The daily bonus is server-authoritative through:

`public.claim_daily_bonus(...)`

Device-scoped reconciliation exists in private data structures.

### Auto-view

`public.activate_auto_view(...)`

charges the configured amount atomically. The current product behavior charges 100 coins for a seven-day entitlement.

### Coin transfers

`public.transfer_coins(...)`

performs authenticated, server-authoritative transfer. The client receives a result and then refreshes financial state.

---

## 11. Viewer flow

A valid viewer session is created by the backend.

```text
request_view_session
        |
        v
eligible ViewSession
        |
        v
Viewer WebView loads target
        |
        v
SafeWebView detects content visible
        |
        v
signal_content_ready
        |
        v
server-authoritative timing
        |
        v
complete_view_session
        |
        +--> increment campaign progress
        +--> spend campaign budget
        +--> credit viewer
        +--> return authoritative balance snapshot
```

The Android timer is a UI representation. It is not financial authority.

Server-side checks include session state, server timing, idempotency, budget, eligibility, and anti-self-view rules.

When leaving Viewer, the current session is cancelled as appropriate and stale viewer UI is reset.

---

## 12. Campaign creation flow

Campaign creation is split into validation and financial execution.

```text
CreateCampaignScreen
      |
      v
client URL policy
      |
      v
campaign-url-preflight Edge Function
      |
      +--> normalized/final URL
      +--> HTTP status
      +--> redirects
      +--> response time
      +--> content type/length
      +--> viewer compatibility
      +--> quality diagnostics
      |
      v
preflight token
      |
      v
create_campaign RPC
      |
      +--> canonical domain
      +--> server pricing
      +--> affordability
      +--> budget reservation
      +--> campaign row
```

For keyword campaigns, `resolve-campaign-target` can resolve a relevant page on the advertiser's own origin. The resolved target is stored through `set_campaign_resolved_target`.

---

## 13. Realtime and synchronization

Realtime is a latency optimization, not the source of truth.

Current subscriptions are scoped to the authenticated user:

- `public.profiles` UPDATE for the current UID
- `public.coin_ledger` INSERT for the current UID
- `public.campaigns` changes for the current owner

When a Realtime event arrives:

- `profiles` or `coin_ledger` -> fresh financial read
- `campaigns` -> fresh campaign read

This architecture prevents a malformed/stale Realtime payload from becoming authoritative state.

Foreground-only operation limits unnecessary network traffic.

Fallback reconciliation currently behaves approximately as:

- Realtime healthy -> financial/campaign reconciliation every 60 seconds.
- Realtime unavailable -> reconciliation every 15 seconds.
- Entering foreground -> immediate reconciliation.
- Realtime event -> debounced targeted refresh.

This is intentionally not a blind 10-second polling loop.

---

## 14. URL and WebView security

`UrlSecurityPolicy` rejects unsafe destinations, including private/suspicious network targets.

`SafeWebView`:

- limits navigation to approved policy
- handles SSL errors
- handles render-process termination
- reports content-visible state
- pauses/resumes WebView lifecycle correctly
- releases WebView resources when destroyed
- prevents permission requests that are not part of the product contract

The website preflight Edge Function is authoritative for campaign creation. The client speed checker is diagnostic/UX support.

---

## 15. Release integrity guard

`AppIdentityGuard` performs client-side checks in non-Debug builds:

1. Android package name must equal `sitebin.azerakhsh.ir`.
2. `BuildConfig.APPLICATION_ID` must equal `sitebin.azerakhsh.ir`.
3. Installed signing certificate SHA-256 must equal the official Release fingerprint.

This is an anti-repackaging/integrity layer.

It is **not** authentication and it is **not** sufficient backend security.

Backend authorization remains based on:

- real Supabase JWT
- `auth.uid()`
- RLS
- authenticated RPCs
- server-side ownership checks
- server-side validation

The backend must never trust a package name or client-presented certificate string as proof of authorization.

---

## 16. Database schemas

### Public schema

| Table | Purpose |
|---|---|
| `profiles` | Canonical application account/profile and financial counters |
| `coin_ledger` | Financial audit trail |
| `coin_transfers` | Coin transfer records |
| `duration_pricing` | Authoritative duration/cost/reward matrix |
| `campaigns` | Advertiser campaigns and budget state |
| `view_sessions` | Server-issued viewing sessions |
| `welcome_bonus_grants` | Historical user-level welcome grants |
| `daily_bonus_grants` | Daily bonus records |
| `auto_view_entitlements` | Current auto-view entitlement state |
| `auto_view_purchases` | Auto-view purchase transactions |

### Private schema

| Table | Purpose |
|---|---|
| `device_identities` | Device continuity and risk state |
| `welcome_bonus_entitlements` | Device-level one-time welcome entitlement |
| `welcome_bonus_attempt_buckets` | Welcome-bonus abuse/rate control |
| `daily_bonus_device_claims` | Device-scoped daily-bonus continuity |
| `rate_limit_buckets` | Server-side RPC rate limiting |
| `campaign_preflight_tokens` | Short-lived preflight authorization state |

Foreign keys preserve the relationships between profiles, campaigns, ledger rows, view sessions, transfers, bonuses, and auto-view state.

---

## 17. Important PostgreSQL functions

### Account/identity

- `public.init_user_account(...)`
- `private.rebind_user_account(...)`
- `private.grant_welcome_bonus_if_eligible(...)`
- `private.device_identifier_hmac(...)`

### Financial

- `public.activate_auto_view(...)`
- `public.transfer_coins(...)`
- `public.claim_daily_bonus(...)`

### Campaigns

- `public.create_campaign(...)`
- `public.pause_campaign(...)`
- `public.resume_campaign(...)`
- `public.cancel_campaign(...)`
- `public.set_campaign_resolved_target(...)`

### Viewer

- `public.request_view_session()`
- `public.signal_content_ready(...)`
- `public.complete_view_session(...)`
- `public.cancel_view_session(...)`

### Rate limiting

- `private.enforce_user_rate_limit(...)`
- `public.check_request()`
- `public.consume_campaign_url_preflight_rate_limit()`
- `public.consume_keyword_resolver_rate_limit()`

### Preflight

- `public.store_campaign_preflight_token(...)`
- `public.prune_campaign_preflight_tokens()`

---

## 18. RLS / privilege model

Public financial/data tables are protected by RLS policies appropriate to their ownership.

A common ownership pattern is:

```sql
TO authenticated
USING ((select auth.uid()) = user_id)
```

For updates, both the `USING` and `WITH CHECK` sides must preserve ownership invariants.

Private security tables are not direct client APIs.

Security-definer functions are kept in the private schema when internal privilege elevation is required and are explicitly granted to the intended database role.

Never add a SECURITY DEFINER function simply to make a client permission error disappear.

---

## 19. Server-side rate limiting

The authoritative limiter is database-side and runs before protected operations.

Representative limits include:

- Global authenticated traffic: 8/10s, 30/1m, 90/5m, 300/1h.
- `create_campaign`: 2/10s, 5/1m, 10/5m, 30/1h.
- `transfer_coins`: 3/10s, 8/1m, 20/5m, 50/1h.
- Viewer operations have their own limits.
- `init_user_account`: 3/10s, 6/1m, 15/5m, 30/1h.

Rate-limit rows are keyed by `(user_id, action)`.

This matters to account rebinds: a new Auth UID can already have a limiter row before `init_user_account` runs. Therefore Rebind must **merge** old/new buckets instead of blindly updating the old key onto the new key.

The regression test `supabase/tests/sitebin_account_continuity.sql` explicitly covers this failure mode.

---

## 20. CI/CD contract

Workflow:

`.github/workflows/android-ci.yml`

### Debug

Every push/PR runs:

1. checkout
2. JDK/Android SDK setup
3. SDK packages
4. stable Debug signing key restore
5. fail-closed check if the key is missing
6. Gradle
7. Supabase smoke tests
8. Unit tests
9. `assembleDebug`
10. APK filename normalization
11. package + Debug certificate verification
12. artifact upload

Required Debug applicationId:

`sitebin.azerakhsh.ir`

Required Debug APK:

`sitebin.azerakhsh.apk`

The current CI Debug certificate is:

`AB27EE093B25E10EE5701537DA6ECE470C456D881C3589ADCE6101FB5BF40FC5`

The CI must fail rather than silently generate a replacement Debug identity.

### Release

Release runs only when:

- manually dispatched, or
- the push commit message is exactly:
  `release: build production artifacts`

Release requires:

- `RELEASE_KEYSTORE_BASE64`
- `RELEASE_STORE_PASSWORD`
- `RELEASE_KEY_PASSWORD`
- `RELEASE_KEY_ALIAS`

These are materialized only inside the CI job.

The Gradle environment variables are:

- `KEYSTORE_PATH`
- `STORE_PASSWORD`
- `KEY_ALIAS`
- `KEY_PASSWORD`

Missing Release signing configuration is a hard failure.

The Release job builds:

- APK
- AAB

Release verification must prove:

- APK cryptographic signature is valid.
- APK certificate equals the official Release certificate.
- APK package equals `sitebin.azerakhsh.ir`.
- AAB cryptographic signature is valid.
- AAB certificate equals the official Release certificate.
- artifact SHA-256 values are emitted.

The temporary Release keystore is deleted at the end of the job.

---

## 21. Build/update identity rules

### Rule A — applicationId

Never change:

`sitebin.azerakhsh.ir`

A package-name change creates a different Android application identity.

### Rule B — Release certificate

Never generate a replacement Release key.

Never change the Release alias.

Never sign a production update with Debug.

Never change the expected Release fingerprint.

### Rule C — Debug certificate

Debug is allowed to use a different certificate from Release.

However, all CI Debug APKs used in continuity testing must use the same stable Debug key.

A cache miss is not permission to rotate the key. CI fails closed.

For long-lived operational robustness, a durable secure CI secret for the Debug keystore is preferable to relying on an ephemeral cache alone. Any such migration must preserve the currently-established Debug certificate unless the continuity policy is intentionally migrated.

### Rule D — APK filename

The standard project filename remains:

`sitebin.azerakhsh.apk`

The filename itself is not Android identity; package + signing certificate are the important Android update identities. The project nevertheless keeps the fixed filename for operational consistency.

### Rule E — versions

For every update:

- increment `versionCode`
- set the new `versionName`
- keep applicationId
- keep Release signing identity
- keep the standard APK filename

Do not reset `versionCode` for a production update.

---

## 22. Identity Stability Scale: 0–5

This scale is mandatory before modifying SiteBin.

### Level 0 — Green / no identity risk

Examples:

- UI spacing
- copy/text changes
- non-functional Compose changes
- localized strings
- visual theme changes

Required:

- normal unit tests
- normal Debug CI

### Level 1 — Green / low backend risk

Examples:

- read-only UI changes
- non-financial diagnostics
- performance tuning that does not alter identity/auth

Required:

- unit tests
- relevant smoke tests
- no package/signing changes

### Level 2 — Yellow / state risk

Examples:

- changing repository refresh logic
- Realtime subscription behavior
- polling intervals
- transaction presentation
- campaign list state

Required:

- unit tests
- CI
- verify authoritative refresh path
- verify no client-side financial mutation was introduced

### Level 3 — Orange / identity or financial risk

Examples:

- Auth session changes
- install-id changes
- device evidence changes
- welcome-bonus logic
- rate-limit identity changes
- rebind logic
- RLS/RPC changes involving financial ownership

Required:

- dedicated regression test
- transactional DB test
- migration review
- current DB verification
- uninstall/reinstall test
- duplicate-operation test
- verify historical accounts are unchanged

### Level 4 — Red / build identity risk

Examples:

- Android signing change
- package/applicationId change
- Release certificate change
- Debug certificate change
- Android Backup rules affecting identity
- changing installation-key strategy

Required before merge:

- APK artifact evidence
- exact package verification
- exact certificate fingerprint verification
- install/update test
- uninstall/reinstall test
- account continuity test
- backend data audit
- explicit written migration decision

A Level 4 change is blocked by default.

### Level 5 — Critical / forbidden without formal migration

Examples:

- replacing the production Release private key
- changing production applicationId
- deliberately changing the expected Release certificate
- destructive global user merge without objective identity evidence

Do not proceed as a normal feature change.

A formal migration/ownership-transfer strategy is required.

---

## 23. Exact Release checklist

Before a production Release:

### Source

- [ ] applicationId is `sitebin.azerakhsh.ir`
- [ ] APK filename remains `sitebin.azerakhsh.apk`
- [ ] Release signing config is fail-closed
- [ ] no private key/password is committed
- [ ] `versionCode` increased
- [ ] `versionName` updated intentionally

### Backend

- [ ] migrations are applied
- [ ] migration filename/version matches database history
- [ ] RLS/policies reviewed
- [ ] RPC permissions reviewed
- [ ] financial invariants tested
- [ ] account continuity regression tested
- [ ] welcome bonus anti-replay tested
- [ ] rate-limit regression tested

### Artifact

- [ ] Release APK produced
- [ ] Release AAB produced
- [ ] package name verified from artifact
- [ ] APK certificate verified against official fingerprint
- [ ] AAB certificate verified against official fingerprint
- [ ] APK SHA-256 recorded
- [ ] AAB SHA-256 recorded
- [ ] CI job success recorded

### Device test

- [ ] install clean
- [ ] receive/earn coins
- [ ] spend coins
- [ ] close/reopen app
- [ ] install update over existing app
- [ ] verify same account
- [ ] verify same balance
- [ ] verify ledger continuity

---

## 24. Exact Debug continuity test

Use the same CI Debug APK file.

Do not compare two Debug APKs that were built with different signing identities.

Test:

```text
1. Install Debug APK.
2. Record user_handle and balance.
3. Perform a real operation.
4. Spend/earn some coins.
5. Close and reopen.
6. Delete the application.
7. Install the SAME APK file again.
8. Open SiteBin.
9. Verify user_handle.
10. Verify balance.
11. Verify transaction history.
12. Verify active entitlements/campaign state where applicable.
```

Expected:

- user handle is preserved
- financial state is preserved
- no second welcome bonus is minted
- no duplicate rate-limit error is shown
- no new empty account becomes visible to the user

A new Auth UID can still occur internally. That is acceptable when the backend rebinds it to the same canonical SiteBin account.

---

## 25. Production update test

For a Release-to-Release update:

```text
Release N
  -> account has real data
  -> install Release N+1 over Release N
  -> same package
  -> same Release certificate
  -> existing local session can remain
  -> backend account remains unchanged
```

The test is incomplete unless the actual APK/AAB certificate and package are verified. Source code alone is not proof of the artifact identity.

---

## 26. Troubleshooting

### `duplicate key value violates unique constraint "rate_limit_buckets_pkey"`

Likely historical root cause:

- new Auth UID received a rate-limit row first
- Rebind attempted old UID -> new UID with a raw UPDATE
- both already had `(user_id, action)`
- PostgreSQL raised `23505`

Current fix:

- merge buckets with `INSERT ... ON CONFLICT DO UPDATE`
- preserve stricter counters/timestamps/block state
- delete old UID buckets after merge
- regression test exists

### New `user_xxxxxxxx` after reinstall

Check in this order:

1. APK package identity.
2. APK signing certificate.
3. Debug/Release signing consistency.
4. Android/device evidence.
5. `private.device_identities`.
6. `first_auth_uid` vs `current_auth_uid`.
7. `profiles` for the old/current UID.
8. Rebind result.
9. Android Backup/restore state.

Do not manually merge before understanding which signal broke.

### App returns zero coins after update

Check:

- actual artifact package name
- actual Release certificate
- Auth session continuity
- server profile
- device identity
- whether the UI is displaying stale StateFlow data
- Realtime connection/fallback reconciliation
- ledger vs profile balance

Never “fix” a balance by setting a client-side number.

---

## 27. Migration discipline

Database changes must be reproducible from the repository.

Rules:

1. Create a proper migration file.
2. Apply it once.
3. Verify the recorded migration version.
4. Keep the repository filename aligned with the applied version.
5. Never silently rewrite history.
6. Never hard-code user UUIDs into general data migrations.
7. Data repair must be evidence-driven and idempotent.
8. Destructive repairs must be scoped to objectively identifiable corrupted records.
9. Re-run read-only verification after every schema/data repair.
10. Keep regression tests for bugs that were actually observed in production/test data.

A migration file existing in Git is not proof that production contains that migration. The live Supabase migration history is the evidence.

---

## 28. Current migration families

The migration history in this repository has evolved in stages:

### Core/hardening

- `20261003_sitebin_core.sql`
- `20261003164444_sitebin_hardening_20261003.sql`
- `20261003164751_sitebin_access_hardening_20261003.sql`
- `20261003164922_sitebin_campaign_visibility_20261003.sql`
- `20261003165012_sitebin_campaign_visibility_fix_20261003.sql`
- `20261003170402_sitebin_financial_refund_and_auth_hardening.sql`
- `20261003170811_sitebin_campaign_url_hardening.sql`
- `20261003171017_sitebin_fix_plpgsql_builtin_qualification.sql`
- `20261003172118_sitebin_campaign_destination_guard.sql`

### Welcome bonus / daily bonus / device identity

- `20261003183309_sitebin_welcome_bonus_repair_and_demo_seed.sql`
- `20261005120518_sitebin_welcome_bonus_device_identity_v4.sql`
- `20261005120613_sitebin_welcome_bonus_device_identity_fix.sql`
- `20261005121250_sitebin_welcome_bonus_device_identity_null_install_fix.sql`
- `20261005121428_sitebin_welcome_bonus_risk_scope.sql`
- `20261005121616_sitebin_welcome_bonus_legacy_device_binding_v2.sql`
- `20261005122719_sitebin_welcome_bonus_device_identity_first_auth_index.sql`
- `20261005133000_sitebin_device_daily_bonus.sql`
- `20261005134600_sitebin_device_daily_bonus_reconciliation.sql`
- `20261005135000_sitebin_device_daily_bonus_linked_grant_fix.sql`

### Campaign/pricing/viewer

- `20261004080817_sitebin_keyword_campaign_pricing.sql`
- `20261004101500_sitebin_default_viewer_demo_pool.sql`
- `20261004123000_sitebin_coin_transfers.sql`
- `20261004123500_sitebin_coin_transfer_idempotency_hardening.sql`
- `20261004143000_sitebin_campaign_keyword_limit_and_rpc_auth.sql`
- `20261004160459_sitebin_auto_view_subscription_20261004.sql`
- `20261004160827_sitebin_auto_view_status_numeric_fix_20261004.sql`
- `20261004172222_sitebin_viewer_performance_hardening_20261004.sql`
- `20261004172804_sitebin_viewer_completion_snapshot_fix_20261004.sql`
- `20261005071154_sitebin_randomized_viewer_distribution_20261005.sql`
- `20261005110000_sitebin_keyword_target_resolver.sql`
- `20261005112713_sitebin_campaign_url_preflight.sql`

### Rate limiting / security tables

- `20261004214000_sitebin_rate_limiting_20261004.sql`
- `20261005174800_enable_rls_on_private_device_security_tables.sql`

### Identity continuity / Realtime

- `20261006065611_sitebin_realtime_and_auth_continuity.sql`
- `20261006074159_sitebin_rebind_rate_limit_conflict_fix.sql`

The exact contents of these migrations remain authoritative in the files themselves.

---

## 29. Regression tests

Important repository tests include:

### Android unit tests

- `AuthCredentialPolicyTest.kt`
- `CampaignPricingTest.kt`
- `CoinTransferTest.kt`
- `DailyBonusTest.kt`
- `ServerAuthoritativeSecurityTest.kt`
- `UrlSecurityPolicyTest.kt`
- `WebsitePreflightContractTest.kt`
- `SiteBinHelpContentTest.kt`
- `HomeScreenBehaviorTest.kt`
- `AppIdentityGuardTest.kt`
- `SiteSpeedCheckerTest.kt`

### PostgreSQL tests

- `sitebin_financial_security.sql`
- `sitebin_campaign_input_security.sql`
- `sitebin_campaign_preflight.sql`
- `sitebin_daily_bonus.sql`
- `sitebin_view_distribution.sql`
- `sitebin_welcome_bonus_device_identity.sql`
- `sitebin_account_continuity.sql`

The account-continuity regression test specifically verifies:

- old account state is copied to a new Auth UID
- old profile disappears
- handle and financial values are preserved
- new install ID is accepted
- pre-existing new-UID rate-limit rows do not cause a primary-key collision
- old rate-limit rows are removed
- an unrelated device identity is not modified

---

## 30. Observability principles

When debugging production/test behavior, collect evidence in this order:

1. Actual APK/AAB artifact.
2. CI run and commit SHA.
3. Package name from artifact.
4. Certificate fingerprint from artifact.
5. Supabase migration history.
6. Live DB records.
7. PostgreSQL logs.
8. Application logs.
9. UI state.

A source file alone is never proof that an APK has a certain package/signature.

A migration file alone is never proof that production has that schema.

A UI value alone is never proof of the authoritative financial balance.

---

## 31. Security boundaries

### Client is trusted for

- rendering
- UX
- collecting non-secret device evidence
- sending user actions
- displaying server results

### Client is not trusted for

- coin balance
- ledger entries
- campaign budget
- bonus amount
- bonus eligibility
- server time
- viewer reward
- transfer authorization
- ownership authorization
- RLS bypass

### Backend is authoritative for

- identity ownership
- account continuity
- financial accounting
- campaigns
- view sessions
- bonus entitlement
- rate limiting
- preflight acceptance
- target resolution
- authorization

---

## 32. Performance principles

SiteBin does not rely on aggressive periodic polling.

Priority order:

1. local StateFlow rendering
2. Supabase Realtime hints
3. targeted authoritative refresh
4. low-frequency fallback polling
5. immediate foreground reconciliation

Realtime is foreground-only to avoid maintaining sockets while the app is backgrounded.

Viewer-specific server operations are intentionally rate-limited.

---

## 33. Dependency/tooling baseline

Current Gradle catalog includes the Android/Kotlin/Compose/Supabase transport stack used by the project, including:

- Android Gradle Plugin 9.1.1
- Kotlin 2.2.10
- Compose BOM 2024.09.00
- AndroidX Lifecycle 2.8.7
- Navigation Compose 2.8.9
- Room 2.7.0
- Retrofit 2.12.0
- OkHttp 4.10.0
- Moshi 1.15.2
- Coroutines 1.10.2
- Play Services App Set 16.1.0
- Firebase BOM 34.17.0

Dependencies are centrally versioned in `gradle/libs.versions.toml`.

---

## 34. Change-management protocol

Before modifying a sensitive part of SiteBin:

### Step 1

Identify which identity/security/financial boundaries are affected.

### Step 2

Classify the change using the 0–5 Identity Stability Scale.

### Step 3

Inspect live DB state when the change touches:

- Auth
- device identity
- bonuses
- ledger
- rate limiting
- RLS
- migrations

### Step 4

Implement the smallest root-cause fix.

### Step 5

Add a regression test for the bug, not only for the new happy path.

### Step 6

Build the actual artifact.

### Step 7

Verify the artifact, not just the source.

### Step 8

Verify the live database/migration state.

### Step 9

Run an uninstall/reinstall test for any Level 3+ identity change.

### Step 10

Only then merge/release.

---

## 35. Absolute “do not change” list

Without explicit approval, do not change:

- `applicationId`
- package identity
- official Release keystore
- Release alias
- Release certificate
- expected Release fingerprint
- standard APK filename
- Auth-to-device continuity semantics
- server-authoritative financial model

Do not “solve” compatibility by replacing the Release key.

Do not “solve” a build problem by changing applicationId.

Do not make server trust decisions from client-provided package/signing metadata.

---

## 36. Current verified continuity behavior

The current architecture has been exercised with a real account that:

- received the one-time 300-coin welcome bonus
- spent 100 coins on the seven-day auto-view option
- completed website-view sessions and earned additional rewards
- was deleted and reinstalled
- returned with the same user handle
- returned with the preserved financial state
- preserved the existing device-level welcome entitlement
- did not mint a second welcome bonus

This is the expected reference behavior for future regression testing.

---

## 37. Final principle

For SiteBin identity and money:

**Security > Convenience**

**Evidence > Assumption**

**Server state > client state**

**Artifact evidence > source-code assumption**

**Same Release key + same applicationId = same production Android application**

**Device continuity is a server-side identity problem, not a filename problem.**

If any future change appears to conflict with these rules, stop at the root cause and verify the real artifact, live database, and CI state before changing identity-critical configuration.
