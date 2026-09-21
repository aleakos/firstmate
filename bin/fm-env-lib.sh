# shellcheck shell=bash
# Shared .env-style file accessor.
# Usage: . bin/fm-env-lib.sh
#
# This file is the single owner of the one-key .env read: the Relay pairing
# token (bin/fm-x-lib.sh and its callers), Bitbucket Cloud access token
# (bin/fm-bitbucket-api.sh), and the optional typesafe.ai dispatch key
# (bin/fm-dispatch-resolve.sh) resolve their values through fmx_env_get, so
# those opt-in secrets in $FM_HOME/.env are parsed by one rule.
# (bin/fm-mail.sh loads its whole .env block itself under the same env-wins
# contract.) The value is printed to the caller's command substitution only;
# nothing is logged.

# Detect which hosted forges this home actually uses. Evidence comes from
# project origins and durable GitHub/Bitbucket pull-request or issue URLs.
# Outputs: FM_FORGE_USE_GITHUB, FM_FORGE_USE_BITBUCKET, and the first detected
# Bitbucket workspace/repository in FM_FORGE_BITBUCKET_REPO.
fm_detect_forge_usage() { # [projects-dir] [data-dir] [state-dir]
  local projects_dir=${1:-${FM_HOME:-}/projects}
  local data_dir=${2:-${FM_HOME:-}/data}
  local state_dir=${3:-${FM_HOME:-}/state}
  local value relative dir file
  FM_FORGE_USE_GITHUB=0
  FM_FORGE_USE_BITBUCKET=0
  FM_FORGE_BITBUCKET_REPO=

  fm_forge_note_value() {
    value=$1
    case "$value" in
      https://github.com/*|https://*@github.com/*|ssh://git@github.com/*|git@github.com:*)
        FM_FORGE_USE_GITHUB=1
        ;;
    esac
    case "$value" in
      https://bitbucket.org/*|https://*@bitbucket.org/*|ssh://git@bitbucket.org/*|git@bitbucket.org:*)
        FM_FORGE_USE_BITBUCKET=1
        if [ -z "$FM_FORGE_BITBUCKET_REPO" ]; then
          relative=$(printf '%s\n' "$value" \
            | sed -E 's#^.*bitbucket\.org[:/]##; s#[?#].*$##; s#\.git$##' \
            | awk -F/ 'NF >= 2 { print $1 "/" $2 }')
          case "$relative" in
            */*) FM_FORGE_BITBUCKET_REPO=$relative ;;
          esac
        fi
        ;;
    esac
  }

  if [ -d "$projects_dir" ] && command -v git >/dev/null 2>&1; then
    for dir in "$projects_dir"/*; do
      [ -d "$dir" ] || continue
      value=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
      [ -z "$value" ] || fm_forge_note_value "$value"
    done
  fi
  for file in "$data_dir/backlog.md" "$data_dir"/*/contributions.json "$state_dir"/*.meta; do
    [ -f "$file" ] || continue
    while IFS= read -r value; do
      fm_forge_note_value "$value"
    done < <(grep -Eo 'https://(github\.com|bitbucket\.org)/[^[:space:]"<>()]+' "$file" 2>/dev/null || true)
  done
  unset -f fm_forge_note_value
  export FM_FORGE_USE_GITHUB FM_FORGE_USE_BITBUCKET FM_FORGE_BITBUCKET_REPO
}

# fmx_env_get <key> <file>
# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fmx_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}
