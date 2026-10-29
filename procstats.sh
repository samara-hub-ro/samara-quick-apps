#!/usr/bin/env bash
# One sample of what the open windows are costing, for the Quick Apps monitor.
#
#   procstats.sh
#
# Prints tab-separated lines and nothing else:
#
#   ncpu  <n>
#   win   <class>  <pid>  <group>
#   grp   <group>  <memory-bytes>  <cpu-usec>
#   sock  <group>  <key>  <bytes-received>  <bytes-sent>
#
# A <group> is what one application's processes add up to. Omarchy starts each
# application in its own systemd scope, so for nearly everything it is that
# scope's cgroup path, and memory and CPU are the cgroup's own counters — every
# helper and renderer process included, which is the only honest answer for a
# browser. A window whose process is not in an application scope falls back to
# `pid:<pid>`, counted from that one process.
#
# Sockets are TCP only, from `ss -tinp`, for the groups above and nothing else.
# UDP (QUIC included) carries no byte counters an unprivileged user can read,
# so it is not in these numbers; the caller says so where it shows them.
set -u
export LC_ALL=C

cgroot=/sys/fs/cgroup
clk=$(getconf CLK_TCK 2>/dev/null || echo 100)

printf 'ncpu\t%s\n' "$(nproc 2>/dev/null || echo 1)"

declare -A group_of_pid wanted

# Sets REPLY to the group for a pid, or "" when the pid is gone.
group_for() {
  local pid=$1
  if [[ -n "${group_of_pid[$pid]+x}" ]]; then REPLY=${group_of_pid[$pid]}; return; fi
  local cg=""
  [[ -r /proc/$pid/cgroup ]] && cg=$(sed -n 's/^0:://p' "/proc/$pid/cgroup" 2>/dev/null)
  if [[ "$cg" == */app.slice/*.scope ]]; then REPLY=$cg
  elif [[ -n "$cg" ]]; then REPLY="pid:$pid"
  else REPLY=""
  fi
  group_of_pid[$pid]=$REPLY
}

# ---- windows
while IFS=$'\t' read -r cls pid; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  group_for "$pid"
  [[ -z "$REPLY" ]] && continue
  wanted[$REPLY]=1
  printf 'win\t%s\t%s\t%s\n' "${cls//$'\t'/ }" "$pid" "$REPLY"
done < <(hyprctl clients -j 2>/dev/null | jq -r '.[] | [.class, (.pid|tostring)] | @tsv' 2>/dev/null)

# ---- memory and CPU per group
for g in "${!wanted[@]}"; do
  if [[ "$g" == pid:* ]]; then
    p=${g#pid:}
    rss=$(awk '/^VmRSS:/ { print $2 * 1024; exit }' "/proc/$p/status" 2>/dev/null)
    # utime + stime are fields 14 and 15, counted after the ")" that ends comm.
    ticks=$(sed 's/^.*) //' "/proc/$p/stat" 2>/dev/null | awk '{ print $12 + $13 }')
    [[ -n "$rss" && -n "$ticks" ]] || continue
    printf 'grp\t%s\t%s\t%s\n' "$g" "$rss" "$(( ticks * 1000000 / clk ))"
  else
    d="$cgroot$g"
    mem=$(cat "$d/memory.current" 2>/dev/null)
    cpu=$(awk '$1 == "usage_usec" { print $2; exit }' "$d/cpu.stat" 2>/dev/null)
    [[ -n "$mem" && -n "$cpu" ]] || continue
    printf 'grp\t%s\t%s\t%s\n' "$g" "$mem" "$cpu"
  fi
done

# ---- TCP traffic per group
while read -r pid key rx tx; do
  group_for "$pid"
  [[ -n "$REPLY" && -n "${wanted[$REPLY]+x}" ]] || continue
  printf 'sock\t%s\t%s\t%s\t%s\n' "$REPLY" "$key" "$rx" "$tx"
done < <(ss -tinpH 2>/dev/null | awk '
  /^[^ \t]/ {
    pid = ""; key = $4 ">" $5
    if (match($0, /pid=[0-9]+/)) pid = substr($0, RSTART + 4, RLENGTH - 4)
    next
  }
  pid != "" {
    rx = 0; tx = 0
    if (match($0, /bytes_received:[0-9]+/)) rx = substr($0, RSTART + 15, RLENGTH - 15)
    if (match($0, /bytes_sent:[0-9]+/)) tx = substr($0, RSTART + 11, RLENGTH - 11)
    print pid, key, rx, tx
    pid = ""
  }')
exit 0
