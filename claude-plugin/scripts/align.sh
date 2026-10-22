#!/bin/bash
# Sets where the word sits in the strip above the prompt: left, center or right. Run by
# /monoword:align. In terminal mode the plugin's mod runs this itself and moves the word at once.
#   align.sh [left|center|right] [data directory]
set -u
. "$(dirname "$0")/common.sh"

state="$(monoword_state_dir "${2:-}")"
file="$state/settings.json"
want="$(printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"

current() {
    case "$(monoword_setting_get "$file" align)" in
        left) printf 'left' ;;
        right) printf 'right' ;;
        *) printf 'center' ;;
    esac
}

case "$want" in
    "")
        echo "The word sits at the $(current) of the strip. /monoword:align left, center or right moves it."
        exit 0
        ;;
    centre|middle|mid) want=center ;;
    left|center|right) ;;
    *)
        echo "The alignment is left, center or right, such as /monoword:align left. It stays at the $(current)."
        exit 0
        ;;
esac
if monoword_setting_set "$file" align "\"$want\""; then
    case "$want" in
        left) echo "The word now starts at the left of the strip, at the same column every time." ;;
        right) echo "The word now ends at the right of the strip, at the same column every time." ;;
        *) echo "The word is now centred in the strip." ;;
    esac
else
    echo "Could not save the alignment in $file; it stays at the $(current)."
fi
exit 0
