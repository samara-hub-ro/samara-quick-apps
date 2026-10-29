#!/usr/bin/env bash
# Facts about one desktop entry, for the Quick Apps details card.
#
#   appinfo.sh -- <desktop-id>
#
# Prints `key=value` lines and nothing else: file, source, pkg, version,
# installed, updated, size, url, exec. Dates are ISO 8601. Any key that cannot
# be found is simply left out — the card shows what is there and nothing it had
# to guess.
#
# The id arrives as an argument, never as part of a command line, and is only
# ever used as a file name inside the XDG application directories: a value with
# a slash in it, a leading dot or an unreasonable length is refused outright.
set -u
export LC_ALL=C

[[ "${1:-}" == "--" ]] && shift
id="${1:-}"
[[ -z "$id" || ${#id} -gt 255 || "$id" == */* || "$id" == .* ]] && exit 0

emit() { [[ -n "$2" ]] && printf '%s=%s\n' "$1" "${2//$'\n'/ }"; }
iso() { date -d "$1" -Iseconds 2>/dev/null; }
epoch_iso() { [[ "$1" =~ ^[0-9]+$ && "$1" != 0 ]] && date -d "@$1" -Iseconds 2>/dev/null; }

# ---- locate the .desktop file, in XDG precedence order
dirs=("${XDG_DATA_HOME:-$HOME/.local/share}")
IFS=: read -r -a more <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
dirs+=("${more[@]}")

file=""
for d in "${dirs[@]}"; do
  candidate="$d/applications/$id.desktop"
  if [[ -f "$candidate" ]]; then file="$candidate"; break; fi
done
[[ -z "$file" ]] && exit 0
emit file "$file"

# One value from the [Desktop Entry] group, not from an action group below it.
entry_value() {
  awk -F= -v k="$1" '
    /^\[/ { in_main = ($0 == "[Desktop Entry]"); next }
    in_main && $1 == k { sub(/^[^=]*=/, ""); print; exit }
  ' "$file" 2>/dev/null
}

exec_line="$(entry_value Exec)"
emit exec "${exec_line:0:200}"

# ---- pacman
real="$(readlink -f -- "$file" 2>/dev/null || printf '%s' "$file")"
pkg=""
if command -v pacman >/dev/null 2>&1; then
  pkg="$(pacman -Qqo -- "$real" 2>/dev/null | head -n1)"
  # A hand-made or overriding entry in ~/.local still usually starts a
  # packaged binary, and that package is the one whose version matters.
  if [[ -z "$pkg" ]]; then
    read -r -a words <<< "$exec_line"
    for w in "${words[@]}"; do
      [[ "$w" == env || "$w" == *=* ]] && continue
      w="${w//\"/}"
      bin="$(command -v -- "$w" 2>/dev/null)"
      [[ "$bin" == /* ]] && pkg="$(pacman -Qqo -- "$(readlink -f -- "$bin")" 2>/dev/null | head -n1)"
      break
    done
    # Launchers that only wrap something else say nothing about the app.
    [[ "$pkg" == omarchy* || "$pkg" == bash || "$pkg" == coreutils ]] && pkg=""
  fi
fi

if [[ -n "$pkg" ]]; then
  emit source pacman
  emit pkg "$pkg"
  info="$(pacman -Qi -- "$pkg" 2>/dev/null)"
  field() { sed -n "s/^$1 *: //p" <<< "$info" | head -n1; }
  emit version "$(field Version)"
  emit size "$(field 'Installed Size')"
  emit url "$(field URL)"
  # Install Date is when the version on disk went in — the last update.
  emit updated "$(iso "$(field 'Install Date')")"
  # The first install is only in the log. A missing or rotated log leaves the
  # key out rather than repeating the update date as if it were the install.
  first=""
  if [[ -r /var/log/pacman.log ]]; then
    first="$(grep -m1 -F "] [ALPM] installed $pkg (" /var/log/pacman.log 2>/dev/null \
      | sed -n 's/^\[\([^]]*\)\].*/\1/p')"
  fi
  emit installed "$(iso "$first")"
  exit 0
fi

# ---- flatpak
if [[ "$real" == */flatpak/exports/share/applications/* ]] && command -v flatpak >/dev/null 2>&1; then
  emit source flatpak
  emit pkg "$id"
  finfo="$(flatpak info -- "$id" 2>/dev/null)"
  emit version "$(sed -n 's/^ *Version: //p' <<< "$finfo" | head -n1)"
  emit size "$(sed -n 's/^ *Installed: //p' <<< "$finfo" | head -n1)"
  dir="$(sed -n 's/^ *Location: //p' <<< "$finfo" | head -n1)"
  [[ -n "$dir" ]] && emit updated "$(epoch_iso "$(stat -c %Y -- "$dir" 2>/dev/null)")"
  exit 0
fi

# ---- a local entry: a web app, an AppImage, something hand-made
if [[ "$exec_line" == *omarchy-launch-webapp* || "$exec_line" == *--app=http* ]]; then
  emit source webapp
  emit url "$(grep -oE 'https?://[^" ]+' <<< "$exec_line" | head -n1)"
elif [[ "$exec_line" == *.AppImage* || "$exec_line" == *.appimage* ]]; then
  emit source appimage
else
  emit source local
fi
born="$(stat -c %W -- "$real" 2>/dev/null)"
changed="$(stat -c %Y -- "$real" 2>/dev/null)"
# A copied file keeps its old mtime and gets a fresh birth time; whichever is
# earlier is the closer answer to "when did this arrive".
[[ "$born" =~ ^[0-9]+$ && "$changed" =~ ^[0-9]+$ && "$born" -gt "$changed" ]] && born="$changed"
emit installed "$(epoch_iso "$born")"
emit updated "$(epoch_iso "$changed")"
exit 0
