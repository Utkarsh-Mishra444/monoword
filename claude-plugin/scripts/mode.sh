#!/bin/bash
# Turns Monoword mode on or off for the current session. Run by the /monoword:on and
# /monoword:off commands.
#   mode.sh on|off|status [data directory] [session id]
set -u
. "$(dirname "$0")/common.sh"

action="${1:-status}"
state="$(monoword_state_dir "${2:-}")"
sid="$(monoword_session_id "${3:-}")"
mkdir -p "$state/sessions" "$state/replies"

case "$action" in
    on)
        printf 'on' > "$state/sessions/$sid"
        echo "Monoword mode is on for this session."
        if [ ! -d "/Applications/Monoword.app" ] && [ ! -d "$HOME/Applications/Monoword.app" ]; then
            echo "Monoword.app was not found in /Applications or ~/Applications. Replies will be written for one-word reading, but nothing will open until it is installed: https://github.com/Utkarsh-Mishra444/monoword/releases/latest"
        fi
        ;;
    off)
        printf 'off' > "$state/sessions/$sid"
        echo "Monoword mode is off for this session."
        ;;
    *)
        if monoword_mode_is_on "$state" "$sid"; then echo "Monoword mode is on for this session."
        else echo "Monoword mode is off for this session."; fi
        ;;
esac
exit 0
