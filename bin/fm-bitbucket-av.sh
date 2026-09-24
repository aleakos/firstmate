#!/usr/local/bin/av inject +BITBUCKET_ACCESS_TOKEN /bin/sh
# shellcheck shell=sh disable=SC2096 # macOS splits this documented Automic Vault shebang into its words.
# Blessable Automic Vault launcher for the Bitbucket Cloud API token.
#
# Usage: fm-bitbucket-av.sh [--check|--token-stdin] GET <api-path>
#        fm-bitbucket-av.sh [--check|--token-stdin] POST <pullrequests-path> <json-file>
#
# GET accepts any relative Bitbucket Cloud v2 path beginning with /2.0/.
# POST accepts only /2.0/repositories/<workspace>/<repository>/pullrequests,
# which creates a pull request from a regular JSON body file of at most 1 MiB.
# Requests go only to https://api.bitbucket.org; the response body is written
# to stdout and curl errors to stderr.
#
# Run directly, the shebang asks Automic Vault to inject BITBUCKET_ACCESS_TOKEN.
# --token-stdin reads the token from the first stdin line instead, and --check
# validates the request and exits without reading any token or calling curl.
# The token reaches curl only through its stdin config, never argv, a child
# environment, or a file.
#
# This file is self-contained so an Automic Vault Blessing of it stays valid
# across ordinary Firstmate updates. Any edit, move, or mode change requires a
# new `av bless` (docs/configuration.md "Bitbucket Cloud authentication").
set -eu

die() {
  printf 'fm-bitbucket-av: %s\n' "$*" >&2
  exit 2
}

safe_text() {
  case "$1" in
    ''|*[[:space:]]*|*[[:cntrl:]]*|*\\*|*\"*) return 1 ;;
  esac
}

safe_slug() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

MODE=inject
case "${1:-}" in
  --check|--token-stdin) MODE=${1#--}; shift ;;
esac
[ "$#" -ge 2 ] || die 'usage: fm-bitbucket-av.sh [--check|--token-stdin] GET <api-path> | POST <pullrequests-path> <json-file>'
METHOD=$1
API_PATH=$2
BODY=
case "$METHOD" in
  GET)
    [ "$#" -eq 2 ] || die 'GET takes exactly one API path'
    case "$API_PATH" in /2.0/*) ;; *) die 'API path must begin with /2.0/' ;; esac
    case "$API_PATH" in *"#"*) die 'invalid API path' ;; esac
    safe_text "$API_PATH" || die 'invalid API path'
    ;;
  POST)
    [ "$#" -eq 3 ] || die 'POST takes a pull-request collection path and a JSON body file'
    BODY=$3
    REPO=${API_PATH#/2.0/repositories/}
    REPO=${REPO%/pullrequests}
    WORKSPACE=${REPO%%/*}
    SLUG=${REPO#*/}
    if [ "$API_PATH" != "/2.0/repositories/$WORKSPACE/$SLUG/pullrequests" ] \
      || ! safe_slug "$WORKSPACE" || ! safe_slug "$SLUG"; then
      die 'POST path must be /2.0/repositories/<workspace>/<repository>/pullrequests'
    fi
    safe_text "$BODY" || die 'invalid body file path'
    [ -f "$BODY" ] && [ ! -L "$BODY" ] && [ -r "$BODY" ] \
      || die 'body must be a readable regular file'
    [ "$(($(wc -c < "$BODY")))" -le 1048576 ] || die 'body file exceeds 1 MiB'
    ;;
  *) die 'method must be GET or POST' ;;
esac
[ "$MODE" != check ] || exit 0

# Clear any inherited copy so the assignment below stays unexported.
unset FM_BB_TOKEN
if [ "$MODE" = token-stdin ]; then
  IFS= read -r FM_BB_TOKEN || [ -n "${FM_BB_TOKEN:-}" ] || FM_BB_TOKEN=
else
  FM_BB_TOKEN=${BITBUCKET_ACCESS_TOKEN:-}
fi
unset BITBUCKET_ACCESS_TOKEN
[ -n "$FM_BB_TOKEN" ] || {
  printf 'fm-bitbucket-av: BITBUCKET_ACCESS_TOKEN was not supplied\n' >&2
  exit 1
}
safe_text "$FM_BB_TOKEN" || {
  printf 'fm-bitbucket-av: BITBUCKET_ACCESS_TOKEN has an unsafe value\n' >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  printf 'fm-bitbucket-av: curl is required\n' >&2
  exit 1
}

# Curl's config parser treats backslash and quote specially. Both were refused
# above, so each quoted line is an exact representation of its value.
{
  printf '%s\n' silent show-error 'connect-timeout = 5' 'max-time = 20' \
    "request = \"$METHOD\"" 'header = "Accept: application/json"' \
    "header = \"Authorization: Bearer $FM_BB_TOKEN\"" \
    "url = \"https://api.bitbucket.org$API_PATH\""
  if [ "$METHOD" = POST ]; then
    printf '%s\n' fail-with-body 'header = "Content-Type: application/json"' \
      "data-binary = \"@$BODY\""
  else
    printf '%s\n' fail
  fi
} | curl --config -
