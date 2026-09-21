#!/usr/bin/env bash
# Report the blockers this command can see on one GitHub or Bitbucket Cloud
# pull request.
#
# This is a one-shot, read-only command. It reads the current pull request,
# reported checks, and available review state from the selected provider at
# invocation time. It never posts, requests, approves, or merges.
# It reports on checks that have reported. On GitHub, a required context that
# has never reported on this head is absent from what this command reads and
# cannot be enumerated here; advisory checks are omitted. Bitbucket Cloud's
# status records do not declare branch-restriction requirements, so the latest
# status for each reported key is considered and no absent requirement is
# invented. Empty output therefore means that no check this command could read
# is failing or pending; it does not mean the pull request is ready to merge.
# When nothing has reported, that is printed rather than read as ready.
# A pull request that only awaits an approval (reviewDecision REVIEW_REQUIRED)
# is not reported as blocked. GitHub's reviewDecision owns whether reviews
# block; review history is printed only to explain CHANGES_REQUESTED, naming
# each reviewer whose latest verdict still requests changes and marking it
# STALE when it was left at a superseded head.
# A closed or merged pull request reports that terminal state and nothing else.
# Unresolved review-thread state is out of this command's scope.
#
# Usage: fm-pr-state.sh <pr-url>
#   Prints one line per blocker it can see and nothing when it sees none.
#   Blockers do not change the successful exit status; lookup or usage refusal
#   exits non-zero.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-pr-state: %s\n' "$*" >&2
  exit 2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || die "usage: fm-pr-state.sh <pr-url>"

URL=$1
if ! fm_pr_url_parse "$URL"; then
  die "expected a GitHub pull-request URL or canonical Bitbucket Cloud pull-request URL"
fi
PROVIDER=$FM_PR_PROVIDER
PATH_PART=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

bitbucket_state() {
  local workspace repo api_path core statuses fields state draft head tasks
  workspace=${PATH_PART%%/*}
  repo=${PATH_PART#*/}
  command -v jq >/dev/null 2>&1 || die "jq is required for Bitbucket Cloud"
  api_path=$(fm_pr_bitbucket_api_path "$workspace" "$repo" "$NUMBER") \
    || die "invalid Bitbucket Cloud pull-request identity"
  core=$("$SCRIPT_DIR/fm-bitbucket-api.sh" GET "$api_path") \
    || die "could not read $URL"
  fields=$(printf '%s' "$core" | jq -r --argjson number "$NUMBER" '
    if type == "object" and .id == $number
      and (.state | IN("OPEN","MERGED","DECLINED","SUPERSEDED"))
      and (.draft | type) == "boolean"
      and (.source.commit.hash | type) == "string"
      and (.task_count | type) == "number" then
      "state=" + .state,
      "draft=" + (.draft | tostring),
      "head=" + .source.commit.hash,
      "tasks=" + (.task_count | tostring)
    else error("invalid pull request") end' 2>/dev/null) \
    || die "Bitbucket Cloud returned incomplete pull-request state for $URL"
  state=$(printf '%s\n' "$fields" | sed -n 's/^state=//p')
  draft=$(printf '%s\n' "$fields" | sed -n 's/^draft=//p')
  head=$(printf '%s\n' "$fields" | sed -n 's/^head=//p')
  tasks=$(printf '%s\n' "$fields" | sed -n 's/^tasks=//p')
  fm_pr_head_valid "$head" || die "Bitbucket Cloud returned incomplete pull-request state for $URL"
  case "$state" in
    MERGED) printf 'STATE: merged\n'; return 0 ;;
    OPEN) ;;
    *) printf 'STATE: %s\n' "$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"; return 0 ;;
  esac
  [ "$draft" = false ] || printf 'DRAFT: pull request is not ready for review\n'
  [ "$tasks" -eq 0 ] || printf 'OPEN TASKS: %s unresolved task(s)\n' "$tasks"
  statuses=$(fm_pr_bitbucket_get_paginated "$api_path/statuses?pagelen=100") \
    || die "could not read reported checks for $URL"
  if [ "$(printf '%s' "$statuses" | jq 'length')" -eq 0 ]; then
    printf 'CHECKS: none reported yet\n'
  else
    printf '%s' "$statuses" | jq -r '
      sort_by([.key, (.updated_on // .created_on // "")])
      | group_by(.key)
      | map(last)
      | .[]
      | select(.state != "SUCCESSFUL")
      | "REPORTED CHECK: " + (.name // .key // "(unnamed check)") + " (" + (.state // "UNKNOWN") + ")"'
  fi
  printf '%s' "$core" | jq -r '
    [.participants[]? | select(.state == "changes_requested")
      | (.user.nickname // .user.display_name // .user.uuid // "unknown reviewer")]
    | unique[] | "REVIEW: " + . + " CHANGES_REQUESTED"'
}

case "$PROVIDER" in
  bitbucket) bitbucket_state; exit 0 ;;
  github) ;;
  *) die "fm-pr-state supports GitHub and Bitbucket Cloud pull requests" ;;
esac
command -v gh >/dev/null 2>&1 || die "gh is required"

PATH_PART=$FM_PR_PATH
ENDPOINT="/repos/$PATH_PART/pulls/$NUMBER"

CORE=$(gh pr view "$URL" \
  --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision --jq '
  "state=\(.state | ascii_downcase)",
  "merged_at=\(.mergedAt // "")",
  "draft=\(.isDraft)",
  "head=\(.headRefOid)",
  "author=\(.author.login)",
  "mergeability=\(if .mergeable == null or .mergeable == "UNKNOWN" then "unknown" else (.mergeable | ascii_downcase) end)",
  "review_decision=\(.reviewDecision // "")"') || die "could not read $URL"

STATE=
MERGED_AT=
DRAFT=
MERGEABILITY=
HEAD=
AUTHOR=
REVIEW_DECISION=
while IFS= read -r row; do
  case "$row" in
    state=*) STATE=${row#state=} ;;
    merged_at=*) MERGED_AT=${row#merged_at=} ;;
    draft=*) DRAFT=${row#draft=} ;;
    head=*) HEAD=${row#head=} ;;
    author=*) AUTHOR=${row#author=} ;;
    mergeability=*) MERGEABILITY=${row#mergeability=} ;;
    review_decision=*) REVIEW_DECISION=${row#review_decision=} ;;
  esac
done <<EOF_CORE
$CORE
EOF_CORE
[ -n "$STATE" ] && [ -n "$DRAFT" ] && [ -n "$HEAD" ] && [ -n "$AUTHOR" ] \
  && [ -n "$MERGEABILITY" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

if [ -n "$MERGED_AT" ]; then
  printf 'STATE: merged at %s\n' "$MERGED_AT"
  exit 0
elif [ "$STATE" != open ]; then
  printf 'STATE: %s\n' "$STATE"
  exit 0
fi
[ "$DRAFT" = false ] || printf 'DRAFT: pull request is not ready for review\n'
case "$MERGEABILITY" in
  mergeable) ;;
  unknown) printf 'MERGEABILITY: unknown\n' ;;
  conflicting) printf 'MERGEABILITY: conflicting\n' ;;
  *) die "GitHub returned invalid mergeability for $URL" ;;
esac

GH_STDERR=$(mktemp "${TMPDIR:-/tmp}/fm-pr-state.XXXXXX") \
  || die "could not create temporary file"
trap 'rm -f "$GH_STDERR"' EXIT INT TERM
if ! REQUIRED=$(gh pr checks "$URL" --required --json name,state,bucket --jq '
  .[]
  | select(.bucket != "pass" and .bucket != "skipping")
  | "REQUIRED CHECK: \(.name) (\(.state))"' 2>"$GH_STDERR"); then
  # These two sentences are gh's own human-readable error text, verified against
  # gh 2.100.0 on 2026-09-12. gh reports "nothing reported" as an error rather
  # than as structured data, so matching its text is the only way to tell that
  # apart from a real lookup failure. An unrecognised message falls through to
  # the refusal below, so a reword degrades loudly rather than silently.
  if grep -q "^no checks reported on the '" "$GH_STDERR"; then
    REQUIRED="CHECKS: none reported yet"
  elif grep -q "^no required checks reported on the '" "$GH_STDERR"; then
    REQUIRED="CHECKS: no required check has reported; readiness unconfirmed"
  else
    cat "$GH_STDERR" >&2
    die "could not read required checks for $URL"
  fi
fi
[ -z "$REQUIRED" ] || printf '%s\n' "$REQUIRED"

if [ "$REVIEW_DECISION" = CHANGES_REQUESTED ]; then
  printf 'REVIEW DECISION: CHANGES_REQUESTED\n'
  REVIEWS=$(gh api "$ENDPOINT/reviews?per_page=100" --paginate --jq '
    .[]
    | select(.user.login != null and .commit_id != null and .submitted_at != null)
    | [.user.login, .state, .commit_id, .submitted_at]
    | @tsv') || die "could not read reviews for $URL"
  printf '%s\n' "$REVIEWS" | awk -F '\t' -v author="$AUTHOR" -v head="$HEAD" '
    NF == 4 && $1 != author && $2 != "COMMENTED" && (!seen[$1] || $4 >= latest[$1]) {
      seen[$1] = 1
      latest[$1] = $4
      state[$1] = $2
      commit[$1] = $3
    }
    END {
      for (reviewer in state) {
        if (state[reviewer] != "CHANGES_REQUESTED") continue
        if (commit[reviewer] == head)
          printf "REVIEW: %s CHANGES_REQUESTED\n", reviewer
        else
          printf "STALE BLOCKING REVIEW: %s CHANGES_REQUESTED at %s\n", \
            reviewer, commit[reviewer]
      }
    }' | LC_ALL=C sort
fi
