#!/usr/bin/env bash
# Ends one application, for the Quick Apps "Force quit" button.
#
#   killapp.sh -- <group> TERM|KILL
#
# <group> is what procstats.sh reported: an application scope's cgroup path,
# or `pid:<pid>`. Only two shapes are honoured, and both are checked here
# rather than trusted from the caller:
#
#   * a cgroup under this user's own `app.slice`, ending in `.scope` — never
#     `session.slice`, which is where Hyprland and the shell itself live, so
#     there is no value that can take the desktop down with the application;
#   * a single pid owned by this user.
#
# TERM goes to every process in the scope, so the application can still save
# and exit. KILL uses the cgroup's own `cgroup.kill`, which takes the whole
# tree at once, children forked in the meantime included.
set -u
export LC_ALL=C

[[ "${1:-}" == "--" ]] && shift
group="${1:-}"
sig="${2:-}"
[[ "$sig" == TERM || "$sig" == KILL ]] || exit 2

uid=$(id -u)

if [[ "$group" == pid:* ]]; then
  pid=${group#pid:}
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || exit 2
  [[ "$(stat -c %u "/proc/$pid" 2>/dev/null)" == "$uid" ]] || exit 2
  kill -s "$sig" -- "$pid" 2>/dev/null
  exit 0
fi

prefix="/user.slice/user-$uid.slice/user@$uid.service/app.slice/"
[[ "$group" == "$prefix"*.scope && "$group" != *..* && "$group" != */session.slice/* ]] || exit 2

dir="/sys/fs/cgroup$group"
[[ -d "$dir" ]] || exit 0

if [[ "$sig" == KILL && -w "$dir/cgroup.kill" ]]; then
  echo 1 > "$dir/cgroup.kill"
  exit 0
fi

while read -r pid; do
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -s "$sig" -- "$pid" 2>/dev/null
done < "$dir/cgroup.procs"
exit 0
