#!/usr/bin/env bash
# Authenticated Bitbucket Cloud API transport.
#
# Usage: fm-bitbucket-api.sh GET <api-path>
#        fm-bitbucket-api.sh POST /2.0/repositories/<workspace>/<repository>/pullrequests <json-file>
#        fm-bitbucket-api.sh POST /2.0/repositories/<workspace>/<repository>/pullrequests/<n>/comments <json-file>
#        fm-bitbucket-api.sh reply <pull-request-url> <comment-id> <message>
#        fm-bitbucket-api.sh render-launcher
#
# GET reads any relative Bitbucket Cloud v2 path beginning with /2.0/. POST
# only creates a pull request, or posts a reply under an existing pull-request
# comment, from a JSON body file; the launcher bin/fm-bitbucket-av.sh owns the
# exact accepted paths and body shapes. reply builds that reply body for the
# canonical https://bitbucket.org/<workspace>/<repository>/pull-requests/<n>
# URL, the parent comment's numeric id, and the message text, then posts it
# through POST. The response body is written to stdout and curl errors to
# stderr.
#
# Each request authenticates with one Secret Name. A request whose path is
# /2.0/repositories/<workspace>/<repository> or beneath it uses the name mapped
# to that repository in the optional gitignored config file
# $FM_HOME/config/bitbucket-repo-tokens (FM_CONFIG_OVERRIDE replaces the
# config directory). Each non-blank line is `<workspace>/<repository>
# <SECRET_NAME>`, matched case-insensitively; `#` starts a comment. Every other
# request, including one for an unmapped repository, uses
# BITBUCKET_ACCESS_TOKEN. A mapped repository never falls back to
# BITBUCKET_ACCESS_TOKEN, so its pull requests keep the mapped identity. A
# malformed or duplicate line refuses the request with exit status 2.
#
# The selected name's value wins when it is already present in the
# environment, followed by the active home's gitignored .env; either value
# reaches the tracked launcher bin/fm-bitbucket-av.sh only on its stdin.
# Otherwise the request runs under Automic Vault exactly as the Vault launcher's
# shebang declares (`av inject ... /bin/sh <launcher> --secret <NAME> ...`),
# so a Blessing of that one file lets these calls skip per-run approval. The
# Vault launcher is the rendered per-home copy $FM_HOME/config/bitbucket-av.sh
# when it exists, else the tracked launcher, whose shebang declares only
# BITBUCKET_ACCESS_TOKEN. A selected name that launcher does not declare is
# refused with exit status 2 before Automic Vault is asked. Only Secret Names
# appear in process arguments, and the token reaches curl only through its
# stdin config. Automic Vault approval policy remains the operator's
# authority; this helper never reads or copies a stored value.
#
# render-launcher writes the per-home copy: the tracked launcher with its
# shebang replaced by `av inject --allow-missing-keys` plus BITBUCKET_ACCESS_TOKEN
# and every mapped name, so one missing Vault Secret fails only the requests
# that select it. It prints the copy's path and whether it changed; a changed
# copy needs `av bless --endorse-launcher <path>`, which this helper never runs.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LAUNCHER="$SCRIPT_DIR/fm-bitbucket-av.sh"
HOME_LAUNCHER="$CONFIG_DIR/bitbucket-av.sh"
REPO_TOKENS="$CONFIG_DIR/bitbucket-repo-tokens"
DEFAULT_SECRET=BITBUCKET_ACCESS_TOKEN
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

die() {
  printf 'fm-bitbucket-api: %s\n' "$*" >&2
  exit 2
}

lower() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# repo_tokens prints each validated mapping as `<workspace>/<repository> <NAME>`
# with a lowercased repository key.
repo_tokens() {
  local line repo secret extra key seen='' n=0
  [ -e "$REPO_TOKENS" ] || return 0
  [ -f "$REPO_TOKENS" ] && [ ! -L "$REPO_TOKENS" ] \
    || die "$REPO_TOKENS must be a regular file"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    read -r repo secret extra <<< "$line" || true
    [ -n "$repo" ] || continue
    if [ -z "$secret" ] || [ -n "$extra" ] \
      || ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
      || [[ "/$repo/" == */./* || "/$repo/" == */../* ]] \
      || ! [[ "$secret" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      die "$REPO_TOKENS line $n must be '<workspace>/<repository> <SECRET_NAME>'"
    fi
    key=$(lower "$repo")
    case " $seen " in *" $key "*) die "$REPO_TOKENS maps $key more than once" ;; esac
    seen="$seen $key"
    printf '%s %s\n' "$key" "$secret"
  done < "$REPO_TOKENS"
}

# secret_for_path prints the Secret Name that authenticates <api-path>.
secret_for_path() {
  local path=$1 map key mapped_key secret
  map=$(repo_tokens) || exit 2
  if [[ "$path" =~ ^/2\.0/repositories/([^/?]+)/([^/?]+)([/?].*)?$ ]]; then
    key=$(lower "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}")
    while read -r mapped_key secret; do
      [ "$mapped_key" = "$key" ] || continue
      printf '%s\n' "$secret"
      return 0
    done <<< "$map"
  fi
  printf '%s\n' "$DEFAULT_SECRET"
}

# shebang_words <file> fills WORDS with the words of the file's shebang line.
shebang_words() {
  local line
  IFS= read -r line < "$1" || true
  [ "${line#\#!}" != "$line" ] || die "$1 has no shebang"
  set -f
  # shellcheck disable=SC2206 # the shebang is split into words exactly as macOS does.
  WORDS=(${line#\#!})
  set +f
}

render_launcher() {
  local map names shebang name tmp
  map=$(repo_tokens) || exit 2
  names=$( { printf '%s\n' "$DEFAULT_SECRET"; [ -z "$map" ] || printf '%s\n' "$map" | cut -d' ' -f2; } \
    | LC_ALL=C sort -u)
  shebang_words "$LAUNCHER"
  shebang="#!${WORDS[0]} inject --allow-missing-keys"
  for name in $names; do
    shebang="$shebang +$name"
  done
  shebang="$shebang ${WORDS[${#WORDS[@]} - 1]}"
  [ "${#shebang}" -lt 512 ] || die 'too many mapped Secret Names for one shebang line'
  mkdir -p "$CONFIG_DIR"
  if [ -e "$HOME_LAUNCHER" ] || [ -L "$HOME_LAUNCHER" ]; then
    [ -f "$HOME_LAUNCHER" ] && [ ! -L "$HOME_LAUNCHER" ] \
      || die "$HOME_LAUNCHER must be a regular file"
  fi
  tmp=$(mktemp "$CONFIG_DIR/.bitbucket-av.XXXXXX")
  { printf '%s\n' "$shebang"; tail -n +2 "$LAUNCHER"; } > "$tmp"
  chmod 700 "$tmp"
  if cmp -s "$tmp" "$HOME_LAUNCHER" 2>/dev/null; then
    rm -f "$tmp"
    printf 'unchanged %s\n' "$HOME_LAUNCHER"
    return 0
  fi
  mv -f "$tmp" "$HOME_LAUNCHER"
  printf 'changed %s\n' "$HOME_LAUNCHER"
  printf 'bless it: av bless --endorse-launcher %s\n' "$HOME_LAUNCHER"
}

# reply_comment <pull-request-url> <comment-id> <message> posts the reply
# through this helper's own POST path and removes its body file.
reply_comment() {
  local body api_path status=0
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  if ! fm_pr_url_parse "$1" || [ "$FM_PR_PROVIDER" != bitbucket ]; then
    die 'reply needs a canonical https://bitbucket.org/<workspace>/<repository>/pull-requests/<n> URL'
  fi
  [[ "$2" =~ ^[1-9][0-9]{0,14}$ ]] || die 'comment id must be a positive integer'
  command -v jq >/dev/null 2>&1 || die 'jq is required to build a comment reply'
  api_path=$(fm_pr_bitbucket_api_path "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER" /comments) \
    || die 'reply could not derive the pull-request comment path'
  body=$(mktemp "${TMPDIR:-/tmp}/fm-bitbucket-reply.XXXXXX")
  jq -cS -n --arg raw "$3" --argjson id "$2" '{content:{raw:$raw},parent:{id:$id}}' > "$body" \
    && "$SCRIPT_DIR/fm-bitbucket-api.sh" POST "$api_path" "$body" || status=$?
  rm -f "$body"
  return "$status"
}

case "${1:-}" in
  GET|POST) ;;
  reply)
    [ "$#" -eq 4 ] || die 'reply takes a pull-request URL, a comment id, and a message'
    shift
    reply_comment "$@"
    exit
    ;;
  render-launcher)
    [ "$#" -eq 1 ] || die 'render-launcher takes no arguments'
    render_launcher
    exit
    ;;
  *) die 'method must be GET or POST' ;;
esac
/bin/sh "$LAUNCHER" --check "$@" || exit 2

SECRET=$(secret_for_path "$2") || exit 2
TOKEN=${!SECRET:-}
export -n TOKEN 2>/dev/null || true
if [ -z "$TOKEN" ]; then
  TOKEN=$(fmx_env_get "$SECRET" "$FM_HOME/.env")
fi
unset "$SECRET" "$DEFAULT_SECRET"
if [ -n "$TOKEN" ]; then
  printf '%s\n' "$TOKEN" | /bin/sh "$LAUNCHER" --token-stdin --secret "$SECRET" "$@"
  exit
fi

VAULT_LAUNCHER=$LAUNCHER
[ ! -f "$HOME_LAUNCHER" ] || VAULT_LAUNCHER=$HOME_LAUNCHER
shebang_words "$VAULT_LAUNCHER"
DECLARED=0
for word in "${WORDS[@]}"; do
  case "$word" in
    "+$SECRET") DECLARED=1; unset "$SECRET" ;;
    +*) unset "${word#+}" ;;
  esac
done
[ "$DECLARED" -eq 1 ] \
  || die "$SECRET is not declared by $VAULT_LAUNCHER; run fm-bitbucket-api.sh render-launcher, then av bless --endorse-launcher $HOME_LAUNCHER"
AV=$(command -v av 2>/dev/null) || {
  printf 'fm-bitbucket-api: %s is unset and Automic Vault (av) is unavailable\n' "$SECRET" >&2
  exit 1
}
exec "$AV" "${WORDS[@]:1}" "$VAULT_LAUNCHER" --secret "$SECRET" "$@"
