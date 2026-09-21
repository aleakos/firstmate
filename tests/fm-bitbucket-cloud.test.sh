#!/usr/bin/env bash
# Focused provider-contract tests for Bitbucket Cloud URL identity, Automic Vault
# credential injection, direct API reads, and exact merged-state polling.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

API="$ROOT/bin/fm-bitbucket-api.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
PR_LIB="$ROOT/bin/fm-pr-lib.sh"
PR_STATE="$ROOT/bin/fm-pr-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-bitbucket-cloud-tests)
BASE_PATH=$PATH
TOKEN='test-bitbucket-token-not-a-real-secret'

make_fake_curl() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
config=$(cat)
[ -z "${BITBUCKET_ACCESS_TOKEN:-}" ] || { printf 'provider token leaked into curl environment\n' >&2; exit 90; }
printf '%s\n' "$*" > "$FM_TEST_CURL_ARGS"
printf '%s\n' "$config" > "$FM_TEST_CURL_CONFIG"
case "$config" in
  *"Authorization: Bearer $FM_TEST_EXPECT_TOKEN"*) ;;
  *) printf 'missing bearer credential\n' >&2; exit 91 ;;
esac
cat "$FM_TEST_CURL_RESPONSE"
SH
  chmod +x "$dir/fakebin/curl"
}

run_api() {
  local dir=$1
  shift
  FM_TEST_CURL_ARGS="$dir/curl.args" \
  FM_TEST_CURL_CONFIG="$dir/curl.config" \
  FM_TEST_CURL_RESPONSE="$dir/response.json" \
  FM_TEST_EXPECT_TOKEN="$TOKEN" \
  PATH="$dir/fakebin:$BASE_PATH" \
    "$API" "$@"
}

test_ambient_token_never_enters_curl_arguments() {
  local dir out
  dir="$TMP_ROOT/ambient"
  mkdir -p "$dir"
  make_fake_curl "$dir"
  printf '%s\n' '{"state":"OPEN"}' > "$dir/response.json"

  out=$(BITBUCKET_ACCESS_TOKEN="$TOKEN" run_api "$dir" GET \
    /2.0/repositories/workspace/repository/pullrequests/7)

  assert_contains "$out" '"state":"OPEN"' "ambient token: API response was not relayed"
  assert_not_contains "$(cat "$dir/curl.args")" "$TOKEN" \
    "ambient token: credential leaked into curl process arguments"
  assert_contains "$(cat "$dir/curl.config")" 'Authorization: Bearer test-bitbucket-token-not-a-real-secret' \
    "ambient token: bearer credential did not reach curl through its private config input"
  pass "Bitbucket API uses an ambient token without placing it in process arguments"
}

test_home_env_token_never_enters_arguments() {
  local dir out
  dir="$TMP_ROOT/home-env"
  mkdir -p "$dir/home"
  make_fake_curl "$dir"
  printf '%s\n' "BITBUCKET_ACCESS_TOKEN=$TOKEN" > "$dir/home/.env"
  printf '%s\n' '{"state":"OPEN"}' > "$dir/response.json"

  out=$(FM_HOME="$dir/home" BITBUCKET_ACCESS_TOKEN= run_api "$dir" GET \
    /2.0/repositories/workspace/repository/pullrequests/7)

  assert_contains "$out" '"state":"OPEN"' "home .env token: API response was not relayed"
  assert_not_contains "$(cat "$dir/curl.args")" "$TOKEN" \
    "home .env token: credential leaked into curl process arguments"
  pass "Bitbucket API reads the active home's gitignored token without argument leakage"
}

test_vault_injection_names_only_the_secret() {
  local dir out
  dir="$TMP_ROOT/vault"
  mkdir -p "$dir/fakebin"
  make_fake_curl "$dir"
  printf '%s\n' '{"uuid":"{repository}"}' > "$dir/response.json"
  cat > "$dir/fakebin/av" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_AV_LOG"
[ "${1:-}" = inject ] || exit 92
[ "${2:-}" = +BITBUCKET_ACCESS_TOKEN ] || exit 93
[ "${3:-}" = -- ] || exit 94
shift 3
BITBUCKET_ACCESS_TOKEN="$FM_TEST_EXPECT_TOKEN" exec "$@"
SH
  chmod +x "$dir/fakebin/av"

  out=$(FM_TEST_AV_LOG="$dir/av.log" BITBUCKET_ACCESS_TOKEN= run_api "$dir" GET \
    /2.0/repositories/workspace/repository)

  assert_contains "$out" '"uuid":"{repository}"' "vault token: API response was not relayed"
  assert_contains "$(cat "$dir/av.log")" 'inject +BITBUCKET_ACCESS_TOKEN -- ' \
    "vault token: API helper did not use the named Automic Vault secret"
  assert_no_grep "$TOKEN" "$dir/av.log" "vault token: credential leaked into Automic Vault arguments"
  assert_not_contains "$(cat "$dir/curl.args")" "$TOKEN" \
    "vault token: credential leaked into curl process arguments"
  pass "Bitbucket API obtains the named token through Automic Vault without exposing its value"
}

test_api_transport_is_read_only_and_rejects_fragments() {
  local dir rc
  dir="$TMP_ROOT/read-only-api"
  mkdir -p "$dir"
  make_fake_curl "$dir"
  printf '%s\n' '{}' > "$dir/response.json"

  set +e
  BITBUCKET_ACCESS_TOKEN="$TOKEN" run_api "$dir" POST \
    /2.0/repositories/workspace/repository/pullrequests/7 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "Bitbucket API transport accepted a write method"
  [ ! -e "$dir/curl.args" ] || fail "read-only Bitbucket API refusal still invoked curl"

  set +e
  BITBUCKET_ACCESS_TOKEN="$TOKEN" run_api "$dir" GET \
    '/2.0/repositories/workspace/repository#fragment' > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "Bitbucket API transport accepted a URL fragment"
  [ ! -e "$dir/curl.args" ] || fail "fragment refusal still invoked curl"
  pass "Bitbucket API transport exposes only fixed-host reads"
}

test_forge_detection_uses_exact_hosts() {
  local dir detected
  dir="$TMP_ROOT/forge-detection"
  mkdir -p "$dir/projects/repository" "$dir/data" "$dir/state"
  git -C "$dir/projects/repository" init -q
  git -C "$dir/projects/repository" remote add origin https://notbitbucket.org/workspace/repository.git
  detected=$(bash -c '
    . "$1"
    fm_detect_forge_usage "$2/projects" "$2/data" "$2/state"
    printf "%s|%s|%s" "$FM_FORGE_USE_GITHUB" "$FM_FORGE_USE_BITBUCKET" "$FM_FORGE_BITBUCKET_REPO"
  ' _ "$ROOT/bin/fm-env-lib.sh" "$dir")
  [ "$detected" = '0|0|' ] || fail "lookalike forge hostname was detected: $detected"

  git -C "$dir/projects/repository" remote set-url origin git@bitbucket.org:workspace/repository.git
  printf '%s\n' 'pr=https://github.com/o/r/pull/1' > "$dir/state/task.meta"
  detected=$(bash -c '
    . "$1"
    fm_detect_forge_usage "$2/projects" "$2/data" "$2/state"
    printf "%s|%s|%s" "$FM_FORGE_USE_GITHUB" "$FM_FORGE_USE_BITBUCKET" "$FM_FORGE_BITBUCKET_REPO"
  ' _ "$ROOT/bin/fm-env-lib.sh" "$dir")
  [ "$detected" = '1|1|workspace/repository' ] \
    || fail "exact mixed forge evidence was not detected: $detected"
  pass "forge-specific startup requirements use exact supported hosts"
}

test_url_parser_accepts_only_canonical_bitbucket_pull_requests() {
  local parsed rejected url
  parsed=$(bash -c '
    . "$1"
    fm_pr_url_parse "$2"
    printf "%s\n%s\n%s\n%s\n" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"
  ' _ "$PR_LIB" 'https://bitbucket.org/my-workspace/repo_slug/pull-requests/42') \
    || fail "canonical Bitbucket pull request URL was rejected"
  [ "$parsed" = $'bitbucket\nbitbucket.org\nmy-workspace/repo_slug\n42' ] \
    || fail "canonical Bitbucket identity was parsed incorrectly: $parsed"

  for url in \
    'http://bitbucket.org/my-workspace/repo/pull-requests/42' \
    'https://api.bitbucket.org/2.0/repositories/my-workspace/repo/pullrequests/42' \
    'https://bitbucket.org/my-workspace/repo/pull-requests/0' \
    'https://bitbucket.org/my-workspace/repo/pull-requests/42/' \
    'https://bitbucket.org/my-workspace/repo/pull-requests/42?x=1' \
    'https://bitbucket.org/my-workspace/repo/pull/42' \
    'https://bitbucket.org/my workspace/repo/pull-requests/42'; do
    rejected=0
    bash -c '. "$1"; ! fm_pr_url_parse "$2"' _ "$PR_LIB" "$url" || rejected=$?
    [ "$rejected" -eq 0 ] || fail "unsafe or noncanonical Bitbucket URL was accepted: $url"
  done
  pass "Bitbucket pull request identity accepts the canonical URL and rejects near misses"
}

test_poll_emits_only_exact_merged_state() {
  local dir out state
  dir="$TMP_ROOT/poll"
  mkdir -p "$dir"
  make_fake_curl "$dir"
  for state in OPEN DECLINED SUPERSEDED MERGED merged 'MERGED '; do
    printf '{"state":"%s"}\n' "$state" > "$dir/response.json"
    out=$(FM_TEST_CURL_ARGS="$dir/curl.args" \
      FM_TEST_CURL_CONFIG="$dir/curl.config" \
      FM_TEST_CURL_RESPONSE="$dir/response.json" \
      FM_TEST_EXPECT_TOKEN="$TOKEN" \
      BITBUCKET_ACCESS_TOKEN="$TOKEN" \
      PATH="$dir/fakebin:$BASE_PATH" \
      "$POLL" --validated bitbucket \
      'https://bitbucket.org/my-workspace/repo/pull-requests/42' \
      bitbucket.org my-workspace/repo 42)
    if [ "$state" = MERGED ]; then
      [ "$out" = merged ] || fail "exact MERGED state did not emit merged"
    else
      [ -z "$out" ] || fail "nonterminal or noncanonical state '$state' emitted a merge"
    fi
  done

  cp "$POLL" "$dir/copied-check.sh"
  chmod +x "$dir/copied-check.sh"
  printf '%s\n' '{"state":"MERGED"}' > "$dir/response.json"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_TEST_CURL_ARGS="$dir/curl.args" \
    FM_TEST_CURL_CONFIG="$dir/curl.config" FM_TEST_CURL_RESPONSE="$dir/response.json" \
    FM_TEST_EXPECT_TOKEN="$TOKEN" BITBUCKET_ACCESS_TOKEN="$TOKEN" \
    PATH="$dir/fakebin:$BASE_PATH" "$dir/copied-check.sh" --validated bitbucket \
    'https://bitbucket.org/my-workspace/repo/pull-requests/42' \
    bitbucket.org my-workspace/repo 42)
  [ "$out" = merged ] || fail "copied Bitbucket merge poll could not locate the code-root API helper"
  pass "Bitbucket merge polling emits only for the exact merged state"
}

test_live_record_read_maps_bitbucket_states() {
  local dir state record
  dir="$TMP_ROOT/read-record"
  mkdir -p "$dir"
  make_fake_curl "$dir"
  for state in OPEN MERGED DECLINED; do
    printf '{"state":"%s"}\n' "$state" > "$dir/response.json"
    record=$(FM_TEST_CURL_ARGS="$dir/curl.args" \
      FM_TEST_CURL_CONFIG="$dir/curl.config" \
      FM_TEST_CURL_RESPONSE="$dir/response.json" \
      FM_TEST_EXPECT_TOKEN="$TOKEN" \
      BITBUCKET_ACCESS_TOKEN="$TOKEN" \
      PATH="$dir/fakebin:$BASE_PATH" \
      bash -c '
        . "$1"
        fm_pr_bitbucket_read_record workspace repository 42
        printf "%s\n%s\n" "$FM_PR_RECORD_STATE" "$FM_PR_RECORD_MERGED"
      ' _ "$PR_LIB") || fail "Bitbucket live record read failed for $state"
    case "$state" in
      MERGED) [ "$record" = $'MERGED\ntrue' ] || fail "MERGED record was mapped incorrectly: $record" ;;
      *) [ "$record" = "$state"$'\nfalse' ] || fail "$state record was mapped incorrectly: $record" ;;
    esac
  done
  pass "Bitbucket live task-state reads preserve exact forge state and merged truth"
}

make_merge_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/data" "$dir/home/config" "$dir/state" "$dir/fakebin" "$dir/wt"
  cp "$ROOT/.tasks.toml" "$dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$dir/home/data/backlog.md"
  fm_write_meta "$dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=direct-PR'
  cat > "$dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
config=$(cat)
printf '%s\n---\n' "$config" >> "$FM_TEST_BB_API_LOG"
case "$config" in
  *'/statuses?pagelen=100'*)
    printf '{"values":[{"key":"ci","name":"ci","state":"%s","updated_on":"2026-01-01T00:00:00Z"}],"next":null}\n' "${FM_TEST_BB_STATUS:-SUCCESSFUL}"
    ;;
  *'/pullrequests/42'*)
    count=$(cat "$FM_TEST_BB_CORE_COUNT" 2>/dev/null || printf 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_TEST_BB_CORE_COUNT"
    head=$FM_TEST_BB_HEAD
    if [ -n "${FM_TEST_BB_RACE_AT:-}" ] && [ "$count" -ge "$FM_TEST_BB_RACE_AT" ]; then
      head=$FM_TEST_BB_RACE_HEAD
    fi
    participants='[]'
    if [ "${FM_TEST_BB_CHANGES:-0}" = 1 ]; then
      participants='[{"state":"changes_requested","user":{"uuid":"{reviewer}"}}]'
    fi
    printf '{"id":42,"state":"OPEN","draft":false,"task_count":%s,"participants":%s,"source":{"commit":{"hash":"%s"}}}\n' \
      "${FM_TEST_BB_TASKS:-0}" "$participants" "$head"
    ;;
  *) exit 97 ;;
esac
SH
  chmod +x "$dir/fakebin/curl"
  printf '%s\n' "$dir"
}

run_merge_case() {
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" \
  FM_TEST_BB_API_LOG="$dir/api.log" FM_TEST_BB_CORE_COUNT="$dir/core.count" \
  FM_TEST_BB_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  FM_TEST_BB_RACE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  BITBUCKET_ACCESS_TOKEN="$TOKEN" PATH="$dir/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-pr-merge.sh" task-x1 \
      https://bitbucket.org/workspace/repository/pull-requests/42 "$@"
}

test_pr_state_reports_bitbucket_blockers() {
  local dir out
  dir=$(make_merge_case pr-state-blockers)
  out=$(FM_TEST_BB_API_LOG="$dir/api.log" FM_TEST_BB_CORE_COUNT="$dir/core.count" \
    FM_TEST_BB_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    FM_TEST_BB_STATUS=FAILED BITBUCKET_ACCESS_TOKEN="$TOKEN" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_STATE" https://bitbucket.org/workspace/repository/pull-requests/42) \
    || fail "Bitbucket pull-request state read failed"
  assert_contains "$out" 'REPORTED CHECK: ci (FAILED)' \
    "Bitbucket pull-request state did not report its failed build"
  pass "Bitbucket pull-request state reports current build blockers"
}

test_merge_preconditions_refuse_red_builds() {
  local dir rc
  dir=$(make_merge_case merge-red)
  set +e
  FM_TEST_BB_STATUS=FAILED run_merge_case "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "red Bitbucket build was accepted for merge"
  assert_grep "check 'ci (FAILED)' is not green" "$dir/stderr" \
    "red Bitbucket build refusal did not name the failing check"
  assert_no_grep 'request = "POST"' "$dir/api.log" \
    "red Bitbucket build reached the merge endpoint"
  assert_grep 'pr=https://bitbucket.org/workspace/repository/pull-requests/42' "$dir/state/task-x1.meta" \
    "red Bitbucket build lost the canonical PR registration"
  assert_grep 'pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$dir/state/task-x1.meta" \
    "Bitbucket ready registration did not capture the exact source head"
  pass "Bitbucket merge preconditions refuse a non-green current build"
}

test_merge_preconditions_refuse_change_requests() {
  local dir rc
  dir=$(make_merge_case merge-change-request)
  set +e
  FM_TEST_BB_CHANGES=1 run_merge_case "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Bitbucket reviewer change request was accepted for merge"
  assert_grep 'reviewer change requests remain from {reviewer}' "$dir/stderr" \
    "Bitbucket change-request refusal did not name the reviewer identity"
  assert_no_grep 'request = "POST"' "$dir/api.log" \
    "Bitbucket change request reached the merge endpoint"
  pass "Bitbucket merge preconditions preserve reviewer change requests"
}

test_merge_head_race_refuses_before_submission() {
  local dir rc
  dir=$(make_merge_case merge-head-race)
  set +e
  FM_TEST_BB_RACE_AT=3 run_merge_case "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Bitbucket head race was accepted for merge"
  assert_grep 'head changed from aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa to bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb during verification' \
    "$dir/stderr" "Bitbucket head-race refusal did not name both heads"
  assert_no_grep 'request = "POST"' "$dir/api.log" \
    "Bitbucket head race reached the merge endpoint"
  pass "Bitbucket merge refuses a source-head race before any submission"
}

test_stable_green_merge_preserves_exact_head_invariant() {
  local dir rc
  dir=$(make_merge_case merge-no-atomic-head)
  set +e
  run_merge_case "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Bitbucket merge without an atomic expected-head primitive was accepted"
  assert_grep 'documented API has no atomic expected-head precondition' "$dir/stderr" \
    "Bitbucket exact-head gap was not reported precisely"
  assert_no_grep 'request = "POST"' "$dir/api.log" \
    "Bitbucket exact-head gap still submitted a merge"
  [ -f "$dir/state/task-x1.check.sh" ] || fail "Bitbucket exact-head refusal did not leave merge confirmation armed"
  pass "Bitbucket preserves exact-head safety and leaves confirmation to the merged-state poll"
}

test_ambient_token_never_enters_curl_arguments
test_home_env_token_never_enters_arguments
test_vault_injection_names_only_the_secret
test_api_transport_is_read_only_and_rejects_fragments
test_forge_detection_uses_exact_hosts
test_url_parser_accepts_only_canonical_bitbucket_pull_requests
test_poll_emits_only_exact_merged_state
test_live_record_read_maps_bitbucket_states
test_pr_state_reports_bitbucket_blockers
test_merge_preconditions_refuse_red_builds
test_merge_preconditions_refuse_change_requests
test_merge_head_race_refuses_before_submission
test_stable_green_merge_preserves_exact_head_invariant
