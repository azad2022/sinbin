#!/usr/bin/env bash
set -euo pipefail

: "${DB_URL:?DB_URL must point to the disposable local Supabase database}"

tmp_dir="$(mktemp -d)"
tag="$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
owner_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
viewer_a_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
viewer_b_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
domain="s2-concurrency-${tag}.example.com"
url="https://${domain}/"
token="s2-concurrency-token-${tag}"
token_hash="$(printf '%s' "$token" | openssl dgst -sha256 | awk '{print $NF}')"

cleanup() {
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 \
    -v owner_id="$owner_id" \
    -v viewer_a_id="$viewer_a_id" \
    -v viewer_b_id="$viewer_b_id" <<'SQL' >/dev/null 2>&1 || true
BEGIN;
DELETE FROM auth.users
WHERE id IN (:'owner_id'::uuid, :'viewer_a_id'::uuid, :'viewer_b_id'::uuid);
COMMIT;
SQL
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

# Commit fixtures so both independent database connections see the same
# single-capacity campaign and the same authoritative daily ranking.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 \
  -v tag="$tag" \
  -v domain="$domain" \
  -v url="$url" \
  -v token_hash="$token_hash" \
  -v owner_id="$owner_id" \
  -v viewer_a_id="$viewer_a_id" \
  -v viewer_b_id="$viewer_b_id" <<'SQL'
BEGIN;

INSERT INTO auth.users(
    id, aud, role, email, email_confirmed_at,
    created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
    (:'owner_id'::uuid, 'authenticated', 'authenticated',
     's2c_owner_' || :'tag' || '@sitebin.internal',
     clock_timestamp(), clock_timestamp(), clock_timestamp(), false, false),
    (:'viewer_a_id'::uuid, 'authenticated', 'authenticated',
     's2c_viewer_a_' || :'tag' || '@sitebin.internal',
     clock_timestamp(), clock_timestamp(), clock_timestamp(), false, false),
    (:'viewer_b_id'::uuid, 'authenticated', 'authenticated',
     's2c_viewer_b_' || :'tag' || '@sitebin.internal',
     clock_timestamp(), clock_timestamp(), clock_timestamp(), false, false);

INSERT INTO public.profiles(
    id, user_handle, app_install_id, available_coins, reserved_coins,
    lifetime_earned, lifetime_spent, trust_score, completed_views_count,
    received_views_count, welcome_bonus_claimed, created_at, updated_at
)
VALUES
    (:'owner_id'::uuid, 's2co_' || :'tag', 's2co_inst_' || :'tag',
     10000, 10000, 10000, 0, 100, 0, 0, true, clock_timestamp(), clock_timestamp()),
    (:'viewer_a_id'::uuid, 's2ca_' || :'tag', 's2ca_inst_' || :'tag',
     10000, 10000, 10000, 0, 100, 0, 0, true, clock_timestamp(), clock_timestamp()),
    (:'viewer_b_id'::uuid, 's2cb_' || :'tag', 's2cb_inst_' || :'tag',
     10000, 10000, 10000, 0, 100, 0, 0, true, clock_timestamp(), clock_timestamp());

INSERT INTO private.campaign_preflight_tokens(
    token_hash, user_id, source_url, normalized_url, domain, final_url,
    http_status, redirect_count, response_ms, content_type, content_length,
    viewer_compatibility, quality_score, diagnostics, created_at, expires_at, consumed_at,
    referral_site_key
)
VALUES(
    :'token_hash',
    :'owner_id'::uuid,
    :'url',
    :'url',
    :'domain',
    :'url',
    200, 0, 100, 'text/html', 2048,
    'COMPATIBLE', 95,
    jsonb_build_object('referral_site_key', :'domain'),
    clock_timestamp(), clock_timestamp() + interval '10 minutes',
    clock_timestamp(),
    :'domain'
);

INSERT INTO public.campaigns(
    owner_id, url, normalized_url, domain, duration_seconds,
    target_views, completed_views, cost_per_view, total_budget,
    spent_budget, reserved_budget, refunded_budget, status,
    created_at, updated_at
)
VALUES(
    :'owner_id'::uuid, :'url', :'url', :'domain', 5,
    1, 0, 5, 5, 0, 5, 0, 'ACTIVE',
    clock_timestamp(), clock_timestamp()
);

INSERT INTO public.daily_view_leaderboard(
    leaderboard_date, user_id, user_handle, completed_views, updated_at
)
SELECT
    (clock_timestamp() AT TIME ZONE 'UTC')::date,
    p.id,
    p.user_handle,
    CASE
        WHEN p.id = :'viewer_a_id'::uuid THEN 1200
        WHEN p.id = :'viewer_b_id'::uuid THEN 1100
        ELSE 1000
    END,
    clock_timestamp()
FROM public.profiles p
WHERE p.id IN (:'viewer_a_id'::uuid, :'viewer_b_id'::uuid, :'owner_id'::uuid);

COMMIT;
SQL

cat > "$tmp_dir/request.sql" <<'SQL'
BEGIN;
SELECT set_config(
    'request.jwt.claims',
    jsonb_build_object(
        'sub', :'viewer_id',
        'role', 'authenticated',
        'is_anonymous', false
    )::text,
    true
) AS jwt \gset
SELECT set_config('request.jwt.claim.sub', :'viewer_id', true) AS uid \gset
SELECT COALESCE(public.request_view_session()::text, 'NULL');
COMMIT;
SQL

run_request() {
  local viewer_id="$1"
  local output="$2"
  psql "$DB_URL" -X -q -A -t -v ON_ERROR_STOP=1 \
    -v viewer_id="$viewer_id" \
    -f "$tmp_dir/request.sql" >"$output"
}

run_request "$viewer_a_id" "$tmp_dir/a.out" &
pid_a=$!
run_request "$viewer_b_id" "$tmp_dir/b.out" &
pid_b=$!
wait "$pid_a"
wait "$pid_b"

result_a="$(tr -d '\r' <"$tmp_dir/a.out" | tail -n 1)"
result_b="$(tr -d '\r' <"$tmp_dir/b.out" | tail -n 1)"

campaign_id="$(psql "$DB_URL" -X -qAt -v ON_ERROR_STOP=1 \
  -c "SELECT id FROM public.campaigns WHERE domain = '$domain'")"

extract_campaign_id() {
  local raw="$1"
  if [[ -z "$raw" || "$raw" == "NULL" ]]; then
    printf ''
    return
  fi
  jq -r '.campaign_id // empty' <<<"$raw"
}

a_campaign_id="$(extract_campaign_id "$result_a")"
b_campaign_id="$(extract_campaign_id "$result_b")"
target_reservations=0
[[ "$a_campaign_id" == "$campaign_id" ]] && target_reservations=$((target_reservations + 1))
[[ "$b_campaign_id" == "$campaign_id" ]] && target_reservations=$((target_reservations + 1))

if [[ "$target_reservations" -ne 1 ]]; then
  echo "FAIL: expected exactly one reservation for the single-capacity campaign; got $target_reservations" >&2
  echo "viewer A: $result_a" >&2
  echo "viewer B: $result_b" >&2
  exit 1
fi

# Once the featured campaign is exhausted, the second viewer may legitimately
# receive an ordinary fallback campaign. It must never receive the same campaign.
if [[ "$a_campaign_id" == "$campaign_id" && "$b_campaign_id" == "$campaign_id" ]]; then
  echo "FAIL: both viewers received the same single-capacity campaign" >&2
  exit 1
fi

active_count="$(psql "$DB_URL" -X -qAt -v ON_ERROR_STOP=1 -v campaign_id="$campaign_id" \
  -c "SELECT count(*) FROM public.view_sessions WHERE campaign_id = '$campaign_id'::uuid AND status IN ('INITIALIZED','CONTENT_READY') AND started_at > clock_timestamp() - interval '3 minutes'")"

completed_count="$(psql "$DB_URL" -X -qAt -v ON_ERROR_STOP=1 -v campaign_id="$campaign_id" \
  -c "SELECT completed_views FROM public.campaigns WHERE id = '$campaign_id'::uuid")"

target_count="$(psql "$DB_URL" -X -qAt -v ON_ERROR_STOP=1 -v campaign_id="$campaign_id" \
  -c "SELECT target_views FROM public.campaigns WHERE id = '$campaign_id'::uuid")"

assignment_count="$(psql "$DB_URL" -X -qAt -v ON_ERROR_STOP=1 -v campaign_id="$campaign_id" \
  -c "SELECT count(*) FROM private.daily_featured_campaign_assignment WHERE campaign_id = '$campaign_id'::uuid AND reservation_status = 'RESERVED'")"

if (( completed_count + active_count > target_count )); then
  echo "FAIL: target capacity exceeded: completed=$completed_count active=$active_count target=$target_count" >&2
  exit 1
fi

if [[ "$active_count" -ne 1 || "$completed_count" -ne 0 || "$assignment_count" -ne 1 ]]; then
  echo "FAIL: inconsistent capacity state: completed=$completed_count active=$active_count assignments=$assignment_count target=$target_count" >&2
  exit 1
fi

echo "PASS: two concurrent viewers contended for one slot; exactly one reservation was created for the target campaign (target=1), with fallback permitted."
