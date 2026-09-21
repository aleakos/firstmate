#!/usr/bin/env bash
# Authenticated Bitbucket Cloud API transport.
#
# Usage: fm-bitbucket-api.sh GET <api-path>
#
# api-path must be a relative Bitbucket Cloud v2 path beginning with /2.0/.
# The response body is written to stdout and curl errors to stderr.
#
# BITBUCKET_ACCESS_TOKEN wins when it is already present in the environment,
# followed by the active home's gitignored .env. Otherwise this command
# re-enters itself through Automic Vault as
# `av inject +BITBUCKET_ACCESS_TOKEN -- ...`; only the secret name appears in
# process arguments. The injected value is removed from the curl environment
# and delivered to curl only through its stdin config, so the token is never a
# command-line argument or a file. Automic Vault approval policy remains the
# operator's authority; this helper never reads or copies the stored value.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
SELF="$SCRIPT_DIR/$(basename "$0")"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
INJECTED=0
if [ "${1:-}" = --vault-injected ]; then
  INJECTED=1
  shift
fi

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-bitbucket-api: %s\n' "$*" >&2
  exit 2
}

[ "$#" -eq 2 ] || die 'usage: fm-bitbucket-api.sh GET <api-path>'
METHOD=$1
API_PATH=$2
case "$METHOD" in GET) ;; *) die 'method must be GET' ;; esac
case "$API_PATH" in
  /2.0/*) ;;
  *) die 'API path must begin with /2.0/' ;;
esac
case "$API_PATH" in
  *[[:space:]]*|*[[:cntrl:]]*|*'\'*|*'"'*|*'#'*) die 'invalid API path' ;;
esac

TOKEN=${BITBUCKET_ACCESS_TOKEN:-}
export -n TOKEN 2>/dev/null || true
if [ -z "$TOKEN" ]; then
  TOKEN=$(fmx_env_get BITBUCKET_ACCESS_TOKEN "$FM_HOME/.env")
fi
if [ -z "$TOKEN" ]; then
  [ "$INJECTED" -eq 0 ] || {
    printf 'fm-bitbucket-api: BITBUCKET_ACCESS_TOKEN was not supplied by Automic Vault\n' >&2
    exit 1
  }
  command -v av >/dev/null 2>&1 || {
    printf 'fm-bitbucket-api: BITBUCKET_ACCESS_TOKEN is unset and Automic Vault (av) is unavailable\n' >&2
    exit 1
  }
  unset BITBUCKET_ACCESS_TOKEN
  exec av inject +BITBUCKET_ACCESS_TOKEN -- "$SELF" --vault-injected "$METHOD" "$API_PATH"
fi
case "$TOKEN" in
  *[[:space:]]*|*[[:cntrl:]]*|*'"'*|*'\'*)
    printf 'fm-bitbucket-api: BITBUCKET_ACCESS_TOKEN has an unsafe value\n' >&2
    exit 1
    ;;
esac
command -v curl >/dev/null 2>&1 || {
  printf 'fm-bitbucket-api: curl is required\n' >&2
  exit 1
}
# Keep the copied value only in this shell's unexported TOKEN variable. Neither
# side of the config pipe inherits the provider-named credential.
unset BITBUCKET_ACCESS_TOKEN

# Curl's config parser treats backslash and quote specially. They were refused
# above, so this line is an exact in-memory representation of the token and no
# additional escaping can change which credential is sent.
run_curl() {
  printf '%s\n' \
    'silent' \
    'show-error' \
    'fail' \
    'connect-timeout = 5' \
    'max-time = 20' \
    "request = \"$METHOD\"" \
    'header = "Accept: application/json"' \
    "header = \"Authorization: Bearer $TOKEN\"" \
    "url = \"https://api.bitbucket.org$API_PATH\"" \
    | env -u BITBUCKET_ACCESS_TOKEN curl --config -
}

run_curl
