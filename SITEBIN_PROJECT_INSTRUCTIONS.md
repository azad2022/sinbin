# SiteBin Project Instructions — Identity & Signing

This file is the repository-safe companion to the ChatGPT Project Instructions. It contains only public identity metadata and operational rules; it must never contain private keys, keystores, passwords, access tokens, or other secrets.

## Permanent application identity

- Android applicationId: `sitebin.azerakhsh.ir`
- Standard APK filename: `sitebin.azerakhsh.apk`
- Production Release certificate SHA-256:
  `6F:25:9D:3C:45:57:BA:4B:4E:4C:94:89:F3:8B:CD:85:E7:EC:9F:46:41:C8:73:46:F9:57:8B:D0:F4:FF:29:00`
- Current CI Debug certificate SHA-256:
  `B6:3B:C4:E1:B4:67:04:CB:49:66:AB:3F:0E:D3:6F:F9:B7:D9:99:E9:67:E6:1D:3E:6B:69:DA:CC:A4:C1:66:9C`

These values are identity-critical. Do not change them without an explicit migration decision.

## Release signing

Release must remain fail-closed.

Required CI secrets:
- `RELEASE_KEYSTORE_BASE64`
- `RELEASE_STORE_PASSWORD`
- `RELEASE_KEY_PASSWORD`
- `RELEASE_KEY_ALIAS`

The Release private key and passwords must never be committed, pasted into source, or printed in logs.

Never:
- generate a replacement Release key;
- change the Release alias;
- change the Release certificate;
- change the applicationId;
- fall back from Release signing to Debug signing.

Every Release APK/AAB must be verified from the actual artifact:
- package = `sitebin.azerakhsh.ir`
- certificate = official Release fingerprint
- cryptographic signature valid
- APK/AAB SHA-256 recorded

## Debug signing

The Debug signing key is now durable and stored only in the GitHub repository secret:

`DEBUG_KEYSTORE_BASE64`

The CI workflow must:
1. require the secret;
2. materialize `~/.android/debug.keystore`;
3. verify its certificate fingerprint before the build;
4. build Debug;
5. verify the actual APK package and certificate after the build.

There is no Debug signing-key cache fallback. A missing, malformed, or mismatched secret is a hard failure. Never generate a replacement Debug key automatically.

Current Debug certificate:
`B6:3B:C4:E1:B4:67:04:CB:49:66:AB:3F:0E:D3:6F:F9:B7:D9:99:E9:67:E6:1D:3E:6B:69:DA:CC:A4:C1:66:9C`

Retired Debug certificate:
`AB:27:EE:09:3B:25:E1:0E:E5:70:15:37:DA:6E:CE:47:0C:45:6D:88:1C:35:89:AD:CE:61:01:FB:5B:F4:0F:C5`

The Debug certificate rotation was explicitly approved on 2026-10-06. It is a Level 4 identity migration. Existing APKs signed with the retired Debug key are not update-compatible with the new Debug key; affected test devices must uninstall the old Debug APK before installing the new one.

## Identity continuity

Do not confuse:
- Android package identity
- signing identity
- Supabase Auth UID
- server-side device identity
- local installId
- user_handle

Account continuity is server-authoritative. Never use package name, certificate string, user_handle, or installId alone as proof of account ownership.

## Change levels

- Level 0–1: UI/low-risk changes; normal CI.
- Level 2: realtime/state/performance changes; regression testing.
- Level 3: Auth, device identity, bonus, rate limiting, RLS/RPC; DB regression tests required.
- Level 4: signing, applicationId, backup/identity strategy, Debug certificate migration; artifact verification + install/update/uninstall/reinstall tests required.
- Level 5: Release key replacement or production applicationId change; forbidden without a formal migration strategy.

## Evidence rules

Source code is not proof of an artifact.
A migration file is not proof of live database state.
A UI balance is not proof of financial state.

For identity-sensitive decisions, verify:
1. actual APK/AAB artifact;
2. CI run and commit;
3. package from artifact;
4. certificate fingerprint from artifact;
5. live Supabase migration/database state when relevant.

Security > Convenience.
Evidence > Assumption.
Server state > client state.
Artifact evidence > source-code assumption.

## Repository hygiene

Signing material must remain excluded from Git. The repository `.gitignore` already excludes:
- `*.jks`
- `*.keystore`
- `*.b64`
- `debug.keystore`

Never add private signing material to the repository.

## Future update rule

For normal production updates:
- keep applicationId unchanged;
- keep Release signing key/certificate unchanged;
- increment versionCode;
- update versionName intentionally;
- keep standard APK filename `sitebin.azerakhsh.apk`.

For Debug:
- keep the current durable Debug keystore;
- keep the current Debug fingerprint;
- treat any Debug key change as an explicit Level 4 migration.

