#!/usr/bin/env bash
set -euo pipefail

: "${DB_URL:?DB_URL must point to the disposable local Supabase PostgreSQL database}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VIEWER_A="51000000-0000-0000-0000-000000000001"
VIEWER_B="51000000-0000-0000-0000-000000000002"
OWNER="51000000-0000-0000-0000-000000000003"
CAMPAIGN_1="52000000-0000-0000-0000-000000000001"
CAMPAIGN_2="52000000-0000-0000-0000-000000000002"
CAMPAIGN_3="52000000-0000-0000-0000-000000000003"

psql "$DB_URL" -X -v ON_ERROR_STOP=1 <<SQL
BEGIN;
INSERT INTO auth.users (
  id, aud, role, email, email_confirmed_at, created_at, updated_at, is_sso_user, is_anonymous
) VALUES
  ('$VIEWER_A', 'authenticated', 'authenticated', 'concurrency-a@sitebin.internal', now(), now(), now(), false, false),
  ('$VIEWER_B', 'authenticated', 'authenticated', 'concurrency-b@sitebin.internal', now(), now(), now(), false, false),
  ('$OWNER', 'authenticated', 'authenticated', 'concurrency-owner@sitebin.internal', now(), now(), now(), false, false);

INSERT INTO public.profiles (
  id, user_handle, app_install_id, available_coins, reserved_coins,
  lifetime_earned, lifetime_spent, trust_score, completed_views_count,
  received_views_count, welcome_bonus_claimed, created_at, updated_at
) VALUES
  ('$VIEWER_A', 'concurrency_a', 'concurrency_install_a', 1000, 100, 1000, 0, 100, 0, 0, true, now(), now()),
  ('$VIEWER_B', 'concurrency_b', 'concurrency_install_b', 1000, 100, 1000, 0, 100, 0, 0, true, now(), now()),
  ('$OWNER', 'concurrency_owner', 'concurrency_install_owner', 1000, 1000, 1000, 0, 100, 0, 0, true, now(), now());

INSERT INTO public.campaigns (
  id, owner_id, url, normalized_url, domain, duration_seconds,
  target_views, completed_views, cost_per_view, total_budget,
  spent_budget, reserved_budget, refunded_budget, status, created_at, updated_at
) VALUES
  ('$CAMPAIGN_1', '$OWNER', 'https://concurrency-1.example.com/', 'https://concurrency-1.example.com/', 'concurrency-1.example.com', 5, 1, 0, 5, 5, 0, 5, 0, 'ACTIVE', now(), now()),
  ('$CAMPAIGN_2', '$OWNER', 'https://concurrency-2.example.com/', 'https://concurrency-2.example.com/', 'concurrency-2.example.com', 5, 1, 0, 5, 5, 0, 5, 0, 'ACTIVE', now(), now()),
  ('$CAMPAIGN_3', '$OWNER', 'https://concurrency-3.example.com/', 'https://concurrency-3.example.com/', 'concurrency-3.example.com', 5, 1, 0, 5, 5, 0, 5, 0, 'ACTIVE', now(), now());
COMMIT;
SQL

request_session() {
  local uid="$1"
  psql "$DB_URL" -X -qAt -v ON_ERROR_STOP=1 -c "
    WITH claims AS MATERIALIZED (
      SELECT set_config(
        'request.jwt.claims',
        json_build_object('sub', '$uid', 'role', 'authenticated', 'is_anonymous', false)::text,
        false
      )
    )
    SELECT COALESCE(public.request_view_session()->>'id', '') FROM claims;
  "
}

cancel_session() {
  local uid="$1" sid="$2"
  psql "$DB_URL" -X -qAt -v ON_ERROR_STOP=1 -c "
    WITH claims AS MATERIALIZED (
      SELECT set_config(
        'request.jwt.claims',
        json_build_object('sub', '$uid', 'role', 'authenticated', 'is_anonymous', false)::text,
        false
      )
    )
    SELECT public.cancel_view_session('$sid'::uuid) FROM claims;
  "
}

complete_session() {
  local uid="$1" sid="$2" key="$3"
  psql "$DB_URL" -X -qAt -v ON_ERROR_STOP=1 -c "
    WITH claims AS MATERIALIZED (
      SELECT set_config(
        'request.jwt.claims',
        json_build_object('sub', '$uid', 'role', 'authenticated', 'is_anonymous', false)::text,
        false
      )
    )
    SELECT public.complete_view_session('$sid'::uuid, '$key') FROM claims;
  "
}

sql() {
  psql "$DB_URL" -X -qAt -v ON_ERROR_STOP=1 -c "$1"
}

# 1. Two concurrent requests from one viewer must return the same active session.
request_session "$VIEWER_A" >"$TMP_DIR/same_a" &
PID_A=$!
request_session "$VIEWER_A" >"$TMP_DIR/same_b" &
PID_B=$!
wait "$PID_A"
wait "$PID_B"

SAME_A="$(tr -d '\r\n' <"$TMP_DIR/same_a")"
SAME_B="$(tr -d '\r\n' <"$TMP_DIR/same_b")"
if [[ -z "$SAME_A" || "$SAME_A" != "$SAME_B" ]]; then
  echo "FAIL: same-viewer concurrent retry created different sessions" >&2
  exit 1
fi
cancel_session "$VIEWER_A" "$SAME_A" >/dev/null

# Isolate one campaign so both viewers compete for the exact same final slot.
sql "UPDATE public.campaigns SET status = 'PAUSED' WHERE id IN ('$CAMPAIGN_2', '$CAMPAIGN_3');" >/dev/null

# 2. Two different viewers racing for one remaining campaign slot cannot over-reserve.
request_session "$VIEWER_A" >"$TMP_DIR/race_a" &
PID_A=$!
request_session "$VIEWER_B" >"$TMP_DIR/race_b" &
PID_B=$!
wait "$PID_A"
wait "$PID_B"

RACE_A="$(tr -d '\r\n' <"$TMP_DIR/race_a")"
RACE_B="$(tr -d '\r\n' <"$TMP_DIR/race_b")"
ACTIVE_COUNT="$(sql "SELECT count(*) FROM public.view_sessions WHERE campaign_id = '$CAMPAIGN_1' AND status IN ('INITIALIZED','CONTENT_READY') AND expires_at > now();")"
if [[ "$ACTIVE_COUNT" != "1" ]]; then
  echo "FAIL: concurrent viewers reserved $ACTIVE_COUNT slots for a one-view campaign" >&2
  exit 1
fi
if [[ -n "$RACE_A" ]]; then cancel_session "$VIEWER_A" "$RACE_A" >/dev/null; fi
if [[ -n "$RACE_B" ]]; then cancel_session "$VIEWER_B" "$RACE_B" >/dev/null; fi
# Keep campaigns 2/3 paused so the completion retry deterministically targets campaign 1.

# 3. Duplicate concurrent completion of one session must consume once.
COMPLETE_ID="$(request_session "$VIEWER_A")"
if [[ -z "$COMPLETE_ID" ]]; then
  echo "FAIL: could not allocate completion-idempotency fixture" >&2
  exit 1
fi
sql "UPDATE public.view_sessions SET content_ready_at = now() - interval '10 seconds', status = 'CONTENT_READY' WHERE id = '$COMPLETE_ID';" >/dev/null
COMPLETE_KEY="concurrent_complete_$COMPLETE_ID"
complete_session "$VIEWER_A" "$COMPLETE_ID" "$COMPLETE_KEY" >"$TMP_DIR/complete_a" 2>"$TMP_DIR/complete_a.err" &
PID_A=$!
complete_session "$VIEWER_A" "$COMPLETE_ID" "$COMPLETE_KEY" >"$TMP_DIR/complete_b" 2>"$TMP_DIR/complete_b.err" &
PID_B=$!
wait "$PID_A" || true
wait "$PID_B" || true

COMPLETED_VIEWS="$(sql "SELECT completed_views FROM public.campaigns WHERE id = '$CAMPAIGN_1';")"
LEDGER_COUNT="$(sql "SELECT count(*) FROM public.coin_ledger WHERE idempotency_key = '$COMPLETE_KEY';")"
if [[ "$COMPLETED_VIEWS" != "1" || "$LEDGER_COUNT" != "1" ]]; then
  echo "FAIL: concurrent completion consumed campaign/reward more than once" >&2
  exit 1
fi
sql "UPDATE public.campaigns SET status = 'ACTIVE' WHERE id IN ('$CAMPAIGN_2', '$CAMPAIGN_3');" >/dev/null

# 4. Concurrent complete/cancel must settle into exactly one terminal assignment state.
RACE_SESSION="$(request_session "$VIEWER_B")"
if [[ -z "$RACE_SESSION" ]]; then
  echo "FAIL: could not allocate complete/cancel race fixture" >&2
  exit 1
fi
sql "UPDATE public.view_sessions SET content_ready_at = now() - interval '10 seconds', status = 'CONTENT_READY' WHERE id = '$RACE_SESSION';" >/dev/null
complete_session "$VIEWER_B" "$RACE_SESSION" "race_complete_$RACE_SESSION" >"$TMP_DIR/race_complete" 2>"$TMP_DIR/race_complete.err" &
PID_A=$!
cancel_session "$VIEWER_B" "$RACE_SESSION" >"$TMP_DIR/race_cancel" 2>"$TMP_DIR/race_cancel.err" &
PID_B=$!
wait "$PID_A" || true
wait "$PID_B" || true

TERMINAL_STATE="$(sql "SELECT vs.status || '|' || a.completed::text || '|' || a.canceled::text FROM public.view_sessions vs JOIN public.special_campaign_assignments a ON a.session_id = vs.id WHERE vs.id = '$RACE_SESSION';")"
case "$TERMINAL_STATE" in
  "COMPLETED|true|false") ;;
  "CANCELLED|false|true") ;;
  *)
    echo "FAIL: complete/cancel race left inconsistent state: $TERMINAL_STATE" >&2
    exit 1
    ;;
esac
sql "UPDATE public.campaigns SET status = 'PAUSED' WHERE id = '$CAMPAIGN_2';" >/dev/null

# 5. Expiration racing completion must expire the old session and free its slot.
EXPIRED_ID="$(request_session "$VIEWER_A")"
if [[ -z "$EXPIRED_ID" ]]; then
  echo "FAIL: could not allocate expiration race fixture" >&2
  exit 1
fi
sql "UPDATE public.view_sessions SET content_ready_at = now() - interval '10 seconds', expires_at = now() - interval '1 second', status = 'CONTENT_READY' WHERE id = '$EXPIRED_ID';" >/dev/null
complete_session "$VIEWER_A" "$EXPIRED_ID" "expired_race_$EXPIRED_ID" >"$TMP_DIR/expired_complete" 2>"$TMP_DIR/expired_complete.err" &
PID_A=$!
request_session "$VIEWER_A" >"$TMP_DIR/after_expiry" &
PID_B=$!
wait "$PID_A" || true
wait "$PID_B"

NEW_ID="$(tr -d '\r\n' <"$TMP_DIR/after_expiry")"
OLD_STATE="$(sql "SELECT vs.status || '|' || a.canceled::text FROM public.view_sessions vs JOIN public.special_campaign_assignments a ON a.session_id = vs.id WHERE vs.id = '$EXPIRED_ID';")"
CAMPAIGN_VIEWS="$(sql "SELECT completed_views FROM public.campaigns WHERE id = '$CAMPAIGN_3';")"
if [[ "$OLD_STATE" != "EXPIRED|true" || "$CAMPAIGN_VIEWS" != "0" || -z "$NEW_ID" || "$NEW_ID" == "$EXPIRED_ID" ]]; then
  echo "FAIL: expiration/complete race did not release the old reservation: $OLD_STATE" >&2
  exit 1
fi
ACTIVE_COUNT="$(sql "SELECT count(*) FROM public.view_sessions WHERE campaign_id = '$CAMPAIGN_3' AND status IN ('INITIALIZED','CONTENT_READY') AND expires_at > now();")"
if [[ "$ACTIVE_COUNT" -gt 1 ]]; then
  echo "FAIL: expiration race oversubscribed campaign 3: $ACTIVE_COUNT" >&2
  exit 1
fi
cancel_session "$VIEWER_A" "$NEW_ID" >/dev/null

echo "PASS: concurrent same-viewer retry, capacity serialization, idempotent completion, complete/cancel race, expiration/complete race"
