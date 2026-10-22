#!/bin/bash
# Sets the terminal player's speed, in words a minute with the pauses included (real speed).
# Run by /monoword:speed. The Monoword app keeps its own speed setting; this one is the plugin's.
#   speed.sh [words a minute, 100 to 1500] [data directory]
set -u
. "$(dirname "$0")/common.sh"

state="$(monoword_state_dir "${2:-}")"
file="$state/settings.json"
want="$(printf '%s' "${1:-}" | tr -d '[:space:]')"

current() {
    local wpm=""
    if [ -f "$file" ]; then
        if command -v jq >/dev/null 2>&1; then
            wpm="$(jq -r '.wpm | numbers' "$file" 2>/dev/null)"
        else
            wpm="$(python3 -c 'import json, sys
v = json.load(open(sys.argv[1])).get("wpm")
print(v if isinstance(v, int) else "")' "$file" 2>/dev/null)"
        fi
    fi
    case "$wpm" in ''|*[!0-9]*) wpm=500 ;; esac
    if [ "$wpm" -lt 100 ] || [ "$wpm" -gt 1500 ]; then wpm=500; fi
    printf '%s' "$wpm"
}

if [ -z "$want" ]; then
    echo "The terminal player reads at $(current) words a minute, pauses included. /monoword:speed 600 changes it (100 to 1500)."
    exit 0
fi
case "$want" in
    ''|*[!0-9]*) echo "The speed is a whole number of words a minute from 100 to 1500, such as /monoword:speed 600. It stays at $(current)."; exit 0 ;;
esac
want=$((10#$want))
if [ "$want" -lt 100 ] || [ "$want" -gt 1500 ]; then
    echo "The speed is a whole number of words a minute from 100 to 1500. It stays at $(current)."
    exit 0
fi
if mkdir -p "$state" && printf '{"wpm": %d}\n' "$want" > "$file.tmp" && mv "$file.tmp" "$file"; then
    echo "The terminal player now reads at $want words a minute, pauses included. It applies from the next reply."
else
    echo "Could not save the speed in $file; it stays at $(current)."
fi
exit 0
