#!/usr/bin/env bash
# Behavior tests for the worker commit identity (config/commit-identity).
#
# The resolver cases drive bin/fm-commit-identity-lib.sh directly. The spawn
# cases drive bin/fm-spawn.sh with a fake tmux pane and a real isolated git
# worktree, then run the captured launch command with a fake agent that makes a
# real commit, so the assertions read the identity git actually recorded.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-commit-identity-lib.sh
. "$ROOT/bin/fm-commit-identity-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-commit-identity)
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

resolve_case() {
  local body=$1 project=$2 file
  file="$TMP_ROOT/identity.$RANDOM"
  printf '%b' "$body" > "$file"
  fm_commit_identity_resolve "$file" "$project"
}

test_absent_file_keeps_git_identity() {
  fm_commit_identity_resolve "$TMP_ROOT/no-such-file" agent-factory ||
    fail "an absent file should resolve without error"
  assert_equals "" "$FM_COMMIT_IDENTITY_EMAIL" "an absent file must not set an email"
  assert_equals "" "$FM_COMMIT_IDENTITY_NAME" "an absent file must not set a name"
  pass "an absent identity file leaves every project on git's own identity"
}

test_project_line_defaults_and_overrides() {
  resolve_case 'agent-factory\n' agent-factory || fail "a bare project line should resolve"
  assert_equals "agent-factory agent (firstmate)" "$FM_COMMIT_IDENTITY_NAME" "default name"
  assert_equals "agent-factory-agent@firstmate.invalid" "$FM_COMMIT_IDENTITY_EMAIL" "default email"
  resolve_case '# bots\nagent-factory  amr-agent@noreply.invalid   amr-agent (firstmate)  # the bot\n' agent-factory ||
    fail "an explicit line should resolve"
  assert_equals "amr-agent (firstmate)" "$FM_COMMIT_IDENTITY_NAME" "explicit name"
  assert_equals "amr-agent@noreply.invalid" "$FM_COMMIT_IDENTITY_EMAIL" "explicit email"
  resolve_case 'agent-factory\n' other || fail "an unmatched project should resolve"
  assert_equals "" "$FM_COMMIT_IDENTITY_EMAIL" "an unmatched project must keep git's identity"
  pass "a project line applies its identity or the documented defaults only to that project"
}

test_star_line_is_the_fallback() {
  resolve_case '*\nagent-factory bot@example.invalid Factory Bot\n' web || fail "a star line should resolve"
  assert_equals "web agent (firstmate)" "$FM_COMMIT_IDENTITY_NAME" "star default name uses the project"
  assert_equals "web-agent@firstmate.invalid" "$FM_COMMIT_IDENTITY_EMAIL" "star default email uses the project"
  resolve_case '*\nagent-factory bot@example.invalid Factory Bot\n' agent-factory || fail "a project line should resolve"
  assert_equals "Factory Bot" "$FM_COMMIT_IDENTITY_NAME" "a project line wins over the star line"
  pass "the star line covers only projects without their own line"
}

test_malformed_lines_refuse() {
  local body out
  for body in 'agent-factory not-an-email\n' 'agent-factory a@b Bad <name>\n' \
    'agent-factory\nagent-factory\n' '../x\n' 'agent-factory a@b@c\n'; do
    if out=$(resolve_case "$body" agent-factory 2>&1); then
      fail "malformed identity line was accepted: $body"
    fi
    assert_contains "$out" "error:" "a malformed line should name the error"
  done
  ln -s "$TMP_ROOT/elsewhere" "$TMP_ROOT/identity-link"
  if fm_commit_identity_resolve "$TMP_ROOT/identity-link" agent-factory 2>/dev/null; then
    fail "a symlinked identity file was accepted"
  fi
  pass "malformed, duplicate, and symlinked identity configuration refuses"
}

make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  # The fake agent makes one real commit in the task worktree, as a worker would.
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
git -C "$FM_TEST_WT" -c user.name='Operator' -c user.email='operator@example.com' \
  commit --quiet --allow-empty -m 'worker commit'
SH
  chmod +x "$fakebin/timeout" "$fakebin/claude"
  fm_test_spawn_home "$case_dir/home" claude
  fm_git_worktree "$case_dir/agent-factory" "$case_dir/wt" "wt-$name"
  fm_test_spawn_brief "$case_dir/home" "$name"
  CASE_DIR=$case_dir
  FAKEBIN=$fakebin
}

run_case_spawn() {
  local id=$1
  FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_PANE_LOG="$CASE_DIR/pane.log" \
    fm_test_run_spawn "$CASE_DIR/home" "$CASE_DIR/wt" "$FAKEBIN" \
    "$id" "$CASE_DIR/agent-factory" --mode direct-PR --yolo off
}

run_case_launch() {
  FM_TEST_WT="$CASE_DIR/wt" HOME="$CASE_DIR/home/user-home" PATH="$FAKEBIN:$PATH" \
    bash -c "$(cat "$CASE_DIR/launch.log")" >/dev/null 2>&1 || fail "the captured worker launch failed"
  git -C "$CASE_DIR/wt" log -1 --format='%an <%ae>|%cn <%ce>'
}

test_spawn_exports_configured_identity() {
  local id=commit-identity-set out status config_before recorded
  make_case "$id"
  printf '%s\n' 'agent-factory amr-agent@firstmate.invalid amr-agent (firstmate)' \
    > "$CASE_DIR/home/config/commit-identity"
  config_before=$(cat "$CASE_DIR/agent-factory/.git/config")
  out=$(run_case_spawn "$id")
  status=$?
  expect_code 0 "$status" "a configured identity should allow the spawn: $out"
  assert_grep "export GIT_AUTHOR_NAME='amr-agent (firstmate)'" "$CASE_DIR/pane.log" \
    "the pane shell did not receive the worker commit identity"
  recorded=$(run_case_launch)
  assert_equals "amr-agent (firstmate) <amr-agent@firstmate.invalid>|amr-agent (firstmate) <amr-agent@firstmate.invalid>" \
    "$recorded" "the worker commit did not carry the configured author and committer"
  assert_equals "$config_before" "$(cat "$CASE_DIR/agent-factory/.git/config")" \
    "the spawn changed the repository's shared git config"
  assert_absent "$CASE_DIR/agent-factory/.git/worktrees/wt/config.worktree" \
    "the spawn wrote a worktree-local git config"
  pass "a configured project's worker commits as the configured identity without any git config change"
}

test_spawn_without_config_keeps_git_identity() {
  local id=commit-identity-unset out status recorded
  make_case "$id"
  printf '%s\n' 'other-project' > "$CASE_DIR/home/config/commit-identity"
  out=$(run_case_spawn "$id")
  status=$?
  expect_code 0 "$status" "an unmatched identity file should allow the spawn: $out"
  assert_no_grep "GIT_AUTHOR" "$CASE_DIR/launch.log" "an unmatched project received an identity in its launch"
  assert_no_grep "GIT_AUTHOR" "$CASE_DIR/pane.log" "an unmatched project received an identity in its pane"
  recorded=$(run_case_launch)
  assert_equals "Operator <operator@example.com>|Operator <operator@example.com>" "$recorded" \
    "an unmatched project's worker did not keep git's own identity"
  pass "a project without a matching line keeps git's own identity"
}

test_spawn_refuses_malformed_config_before_metadata() {
  local id=commit-identity-bad out status
  make_case "$id"
  printf '%s\n' 'agent-factory not-an-email' > "$CASE_DIR/home/config/commit-identity"
  out=$(run_case_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed identity file should refuse the spawn"
  assert_contains "$out" "commit-identity line 1" "the refusal should name the malformed line"
  assert_absent "$CASE_DIR/home/state/$id.meta" "a refused spawn wrote task metadata"
  pass "a malformed identity file refuses the spawn before any task record exists"
}

test_absent_file_keeps_git_identity
test_project_line_defaults_and_overrides
test_star_line_is_the_fallback
test_malformed_lines_refuse
test_spawn_exports_configured_identity
test_spawn_without_config_keeps_git_identity
test_spawn_refuses_malformed_config_before_metadata

echo "# all fm-commit-identity tests passed"
