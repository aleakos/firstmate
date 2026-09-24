#!/usr/local/bin/av inject +BITBUCKET_ACCESS_TOKEN /bin/sh
# shellcheck shell=sh disable=SC2096 # macOS splits this documented Automic Vault shebang into its words.
# Blessable Automic Vault launcher for Bitbucket Cloud API tokens.
#
# Usage: fm-bitbucket-av.sh [--check|--token-stdin] [--secret NAME] GET <api-path>
#        fm-bitbucket-av.sh [--check|--token-stdin] [--secret NAME] POST <pullrequests-path> <json-file>
#        fm-bitbucket-av.sh [--check|--token-stdin] [--secret NAME] POST <comments-path> <json-file>
#
# GET accepts any relative Bitbucket Cloud v2 path beginning with /2.0/.
# POST accepts exactly two collections, each with a regular JSON body file of
# at most 1 MiB:
# - /2.0/repositories/<workspace>/<repository>/pullrequests creates a pull
#   request.
# - /2.0/repositories/<workspace>/<repository>/pullrequests/<n>/comments posts
#   a reply under an existing comment of pull request <n>. The body must be
#   exactly `jq -cS` of {"content":{"raw":<1-4000 characters>},"parent":{"id":<id>}}
#   with a positive integer id, so it can carry no inline anchor, task, or other
#   field. Before posting, the launcher reads that comment through the same
#   pull request's comment endpoint and refuses unless it exists undeleted.
#   Validating a reply needs jq.
# No other write exists: no edit, delete, approval, task, thread resolution, or
# merge. Requests go only to https://api.bitbucket.org; the response body is
# written to stdout and curl errors to stderr.
#
# Run directly, the shebang asks Automic Vault to inject every Secret Name it
# declares; this tracked copy declares only BITBUCKET_ACCESS_TOKEN. --secret
# selects which declared Secret authenticates this request (default
# BITBUCKET_ACCESS_TOKEN) and refuses a name the shebang does not declare.
# bin/fm-bitbucket-api.sh owns the repository-to-Secret mapping and renders a
# per-home copy whose shebang declares the mapped names.
# --token-stdin reads the token from the first stdin line instead, and --check
# validates the request and exits without reading any token or calling curl.
# The token reaches curl only through its stdin config, never argv, a child
# environment, or a file; every declared Secret Name is unset before curl runs.
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

safe_number() {
  case "$1" in
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 15 ]
}

safe_name() {
  case "$1" in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) return 1 ;;
  esac
}

# declared_names prints the +KEY names of this script's own av inject shebang.
# AV_SCRIPT_PATH names the canonical source while av runs a verified snapshot.
declared_names() {
  sed -n '1{s/^#!//;p;}' "${AV_SCRIPT_PATH:-$0}" | tr -s ' \t' '\n' \
    | sed -n 's/^+\([A-Za-z_][A-Za-z0-9_]*\)$/\1/p'
}

MODE=inject
case "${1:-}" in
  --check|--token-stdin) MODE=${1#--}; shift ;;
esac
SECRET=BITBUCKET_ACCESS_TOKEN
if [ "${1:-}" = --secret ]; then
  if [ "$#" -lt 2 ] || ! safe_name "$2"; then die 'invalid --secret name'; fi
  SECRET=$2
  shift 2
fi
[ "$#" -ge 2 ] || die 'usage: fm-bitbucket-av.sh [--check|--token-stdin] [--secret NAME] GET <api-path> | POST <pullrequests-path|comments-path> <json-file>'
METHOD=$1
API_PATH=$2
BODY=
PARENT=
case "$METHOD" in
  GET)
    [ "$#" -eq 2 ] || die 'GET takes exactly one API path'
    case "$API_PATH" in /2.0/*) ;; *) die 'API path must begin with /2.0/' ;; esac
    case "$API_PATH" in *"#"*) die 'invalid API path' ;; esac
    safe_text "$API_PATH" || die 'invalid API path'
    ;;
  POST)
    [ "$#" -eq 3 ] || die 'POST takes a pull-request or comment collection path and a JSON body file'
    BODY=$3
    REPO=${API_PATH#/2.0/repositories/}
    WORKSPACE=${REPO%%/*}
    REST=${REPO#"$WORKSPACE"/}
    SLUG=${REST%%/*}
    TAIL=${REST#"$SLUG"}
    PR_NUMBER=1
    case "$TAIL" in
      /pullrequests) ;;
      /pullrequests/*/comments)
        PR_NUMBER=${TAIL#/pullrequests/}
        PR_NUMBER=${PR_NUMBER%/comments}
        ;;
      *) TAIL=/invalid ;;
    esac
    if [ "$API_PATH" != "/2.0/repositories/$WORKSPACE/$SLUG$TAIL" ] || [ "$TAIL" = /invalid ] \
      || ! safe_slug "$WORKSPACE" || ! safe_slug "$SLUG" || ! safe_number "$PR_NUMBER"; then
      die 'POST path must be /2.0/repositories/<workspace>/<repository>/pullrequests or .../pullrequests/<n>/comments'
    fi
    safe_text "$BODY" || die 'invalid body file path'
    [ -f "$BODY" ] && [ ! -L "$BODY" ] && [ -r "$BODY" ] \
      || die 'body must be a readable regular file'
    [ "$(($(wc -c < "$BODY")))" -le 1048576 ] || die 'body file exceeds 1 MiB'
    if [ "$TAIL" != /pullrequests ]; then
      command -v jq >/dev/null 2>&1 || die 'jq is required to validate a comment reply'
      # Slurping refuses a second JSON value, and comparing the canonical
      # re-serialization with the file bytes refuses duplicate keys, which a
      # parser could otherwise read differently from this check.
      CANONICAL=$(jq -cS -s '
        if length == 1 and (.[0] | type == "object" and keys == ["content", "parent"]
          and (.content | type == "object" and keys == ["raw"]
            and (.raw | type == "string" and length >= 1 and length <= 4000))
          and (.parent | type == "object" and keys == ["id"]
            and (.id | type == "number" and . >= 1 and . == floor)))
        then .[0] else error("invalid") end' "$BODY" 2>/dev/null) \
        && [ "$CANONICAL" = "$(cat "$BODY")" ] \
        || die 'comment reply body must be exactly jq -cS of {"content":{"raw":"<1-4000 characters>"},"parent":{"id":<comment id>}}'
      PARENT=$(jq -r '.parent.id' "$BODY")
      safe_number "$PARENT" || die 'comment reply parent id must be a positive integer'
    fi
    ;;
  *) die 'method must be GET or POST' ;;
esac
[ "$MODE" != check ] || exit 0

DECLARED=$(declared_names)
# Clear any inherited copy so the assignment below stays unexported.
unset FM_BB_TOKEN
if [ "$MODE" = token-stdin ]; then
  IFS= read -r FM_BB_TOKEN || [ -n "${FM_BB_TOKEN:-}" ] || FM_BB_TOKEN=
else
  printf '%s\n' "$DECLARED" | grep -qx "$SECRET" \
    || die "$SECRET is not declared by this launcher's shebang"
  # SECRET passed safe_name, so this expansion reads exactly that variable.
  eval "FM_BB_TOKEN=\${$SECRET:-}"
fi
for name in $DECLARED BITBUCKET_ACCESS_TOKEN; do
  unset "$name"
done
[ -n "$FM_BB_TOKEN" ] || {
  printf 'fm-bitbucket-av: %s was not supplied\n' "$SECRET" >&2
  exit 1
}
safe_text "$FM_BB_TOKEN" || {
  printf 'fm-bitbucket-av: %s has an unsafe value\n' "$SECRET" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  printf 'fm-bitbucket-av: curl is required\n' >&2
  exit 1
}

# request <method> <api-path> [<body-file>] runs one curl call.
# Curl's config parser treats backslash and quote specially. Both were refused
# above, so each quoted line is an exact representation of its value.
request() {
  {
    printf '%s\n' silent show-error 'connect-timeout = 5' 'max-time = 20' \
      "request = \"$1\"" 'header = "Accept: application/json"' \
      "header = \"Authorization: Bearer $FM_BB_TOKEN\"" \
      "url = \"https://api.bitbucket.org$2\""
    if [ -n "${3:-}" ]; then
      printf '%s\n' fail-with-body 'header = "Content-Type: application/json"' \
        "data-binary = \"@$3\""
    else
      printf '%s\n' fail
    fi
  } | curl --config -
}

if [ -n "$PARENT" ]; then
  EXISTING=$(request GET "$API_PATH/$PARENT") || {
    printf 'fm-bitbucket-av: comment %s was not readable on this pull request\n' "$PARENT" >&2
    exit 1
  }
  printf '%s' "$EXISTING" | jq -e --argjson id "$PARENT" \
    'type == "object" and .id == $id and .deleted != true' >/dev/null 2>&1 || {
    printf 'fm-bitbucket-av: comment %s is not an existing comment on this pull request\n' "$PARENT" >&2
    exit 1
  }
fi
if [ "$METHOD" = POST ]; then
  request POST "$API_PATH" "$BODY"
else
  request GET "$API_PATH"
fi
