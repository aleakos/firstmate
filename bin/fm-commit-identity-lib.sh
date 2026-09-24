#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_COMMIT_IDENTITY_* are read by sourcing scripts.
# Worker commit identity: the author and committer a ship or scout worker's
# commits carry, read from the optional gitignored config/commit-identity.
#
# Each non-blank line is `<project|*> [<email> [<name>]]`; `#` starts a comment.
# <project> is the task's project directory name under projects/, matched
# exactly, and `*` applies to every project without its own line. An omitted
# email defaults to `<project>-agent@firstmate.invalid`, whose reserved
# `.invalid` domain never routes mail, and an omitted name defaults to
# `<project> agent (firstmate)`. The name is the rest of the line with
# surrounding whitespace trimmed.
#
# A project with no matching line, and every project when the file is absent,
# keeps the identity git already resolves, because a forge or hook may require
# commits from a verified address and an unrequested identity change would
# turn that repository's pushes into rejections.
#
# The identity only labels commits: pushes still use the operator's own
# credentials, and it never adds a co-author trailer.
#
# fm_commit_identity_resolve <config-file> <project> sets FM_COMMIT_IDENTITY_NAME
# and FM_COMMIT_IDENTITY_EMAIL, both empty when no line applies. A malformed or
# duplicate line, or a present path that is not a readable regular file, prints
# an error naming it and returns 2 so the spawn refuses before any worker exists.

FM_COMMIT_IDENTITY_NAME=
FM_COMMIT_IDENTITY_EMAIL=

fm_commit_identity_resolve() {
  local file=$1 project=$2 line key email name n=0 seen=' ' star_email='' star_name='' star=0
  local LC_ALL=C
  FM_COMMIT_IDENTITY_NAME=
  FM_COMMIT_IDENTITY_EMAIL=
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    printf 'error: %s must be a readable regular file\n' "$file" >&2
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    read -r key email name <<< "$line" || true
    [ -n "$key" ] || continue
    if { [ "$key" != '*' ] && ! [[ "$key" =~ ^[A-Za-z0-9._-]+$ ]]; } ||
      [ "$key" = . ] || [ "$key" = .. ] ||
      { [ -n "$email" ] && { [ "${#email}" -gt 254 ] ||
        ! [[ "$email" =~ ^[^[:space:][:cntrl:]\<\>@]+@[^[:space:][:cntrl:]\<\>@]+$ ]]; }; } ||
      [ "${#name}" -gt 100 ] || [[ "$name" == *[\<\>[:cntrl:]]* ]]; then
      printf "error: %s line %s must be '<project|*> [<email> [<name>]]' with a plain email and a name of at most 100 characters without < or >\n" "$file" "$n" >&2
      return 2
    fi
    case "$seen" in *" $key "*)
      printf 'error: %s names %s more than once\n' "$file" "$key" >&2
      return 2
      ;;
    esac
    seen="$seen$key "
    if [ "$key" = "$project" ]; then
      FM_COMMIT_IDENTITY_EMAIL=${email:-$project-agent@firstmate.invalid}
      FM_COMMIT_IDENTITY_NAME=${name:-$project agent (firstmate)}
    elif [ "$key" = '*' ]; then
      star=1
      star_email=$email
      star_name=$name
    fi
  done < "$file"
  if [ -z "$FM_COMMIT_IDENTITY_EMAIL" ] && [ "$star" = 1 ]; then
    FM_COMMIT_IDENTITY_EMAIL=${star_email:-$project-agent@firstmate.invalid}
    FM_COMMIT_IDENTITY_NAME=${star_name:-$project agent (firstmate)}
  fi
  return 0
}
