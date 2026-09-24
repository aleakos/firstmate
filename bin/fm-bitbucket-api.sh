#!/usr/bin/env bash
# Authenticated Bitbucket Cloud API transport.
#
# Usage: fm-bitbucket-api.sh GET <api-path>
#        fm-bitbucket-api.sh POST /2.0/repositories/<workspace>/<repository>/pullrequests <json-file>
#
# GET reads any relative Bitbucket Cloud v2 path beginning with /2.0/. POST
# only creates a pull request from a JSON body file. The response body is
# written to stdout and curl errors to stderr.
#
# Every request runs through the blessable launcher bin/fm-bitbucket-av.sh,
# which owns request validation and the curl call. BITBUCKET_ACCESS_TOKEN wins
# when it is already present in the environment, followed by the active home's
# gitignored .env; either value reaches the launcher only on its stdin.
# Otherwise the launcher runs under Automic Vault exactly as its shebang
# declares (`av inject +BITBUCKET_ACCESS_TOKEN /bin/sh <launcher> ...`), so a
# Blessing of that one file lets these calls skip per-run approval. Only the
# secret name appears in process arguments, and the token reaches curl only
# through its stdin config. Automic Vault approval policy remains the
# operator's authority; this helper never reads or copies the stored value.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
LAUNCHER="$SCRIPT_DIR/fm-bitbucket-av.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

case "${1:-}" in
  GET|POST) ;;
  *) printf 'fm-bitbucket-api: method must be GET or POST\n' >&2; exit 2 ;;
esac
/bin/sh "$LAUNCHER" --check "$@" || exit 2

TOKEN=${BITBUCKET_ACCESS_TOKEN:-}
export -n TOKEN 2>/dev/null || true
if [ -z "$TOKEN" ]; then
  TOKEN=$(fmx_env_get BITBUCKET_ACCESS_TOKEN "$FM_HOME/.env")
fi
unset BITBUCKET_ACCESS_TOKEN
if [ -n "$TOKEN" ]; then
  printf '%s\n' "$TOKEN" | /bin/sh "$LAUNCHER" --token-stdin "$@"
  exit
fi
AV=$(command -v av 2>/dev/null) || {
  printf 'fm-bitbucket-api: BITBUCKET_ACCESS_TOKEN is unset and Automic Vault (av) is unavailable\n' >&2
  exit 1
}
exec "$AV" inject +BITBUCKET_ACCESS_TOKEN /bin/sh "$LAUNCHER" "$@"
