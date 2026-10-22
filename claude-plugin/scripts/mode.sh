#!/bin/bash
# Sets the Monoword mode of the current session. Run by /monoword:on and /monoword:off, and the only
# writer of sessions/<session id>.
#   mode.sh on|tty|app|off|status [data directory] [session id] [mode word]
# "on" takes the mode word the user typed after /monoword:on: nothing (or "tty", "terminal") for
# terminal mode, "app" for the Monoword app.
set -u
. "$(dirname "$0")/common.sh"

action="${1:-status}"
state="$(monoword_state_dir "${2:-}")"
sid="$(monoword_session_id "${3:-}")"
word="$(printf '%s' "${4:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
mkdir -p "$state/sessions" "$state/replies"

if [ "$action" = "on" ]; then
    case "$word" in
        ""|tty|terminal) action=tty ;;
        app) action=app ;;
        *)
            echo "Unknown Monoword mode \"$word\"; nothing changed. Use /monoword:on for the terminal, /monoword:on app for the Monoword app, or /monoword:off."
            exit 0
            ;;
    esac
fi

case "$action" in
    tty)
        printf 'tty' > "$state/sessions/$sid"
        echo "Monoword mode is on for this session: replies play one word at a time in the strip above the prompt."
        ;;
    app)
        printf 'app' > "$state/sessions/$sid"
        echo "Monoword mode is on for this session: each reply opens in the Monoword app."
        if ! monoword_app_installed; then
            echo "Monoword.app was not found in /Applications or ~/Applications. Replies will be written for one-word reading, but nothing will open until it is installed: https://github.com/Utkarsh-Mishra444/monoword/releases/latest"
        fi
        ;;
    off)
        printf 'off' > "$state/sessions/$sid"
        echo "Monoword mode is off for this session."
        ;;
    *)
        case "$(monoword_mode "$state" "$sid")" in
            tty) echo "Monoword mode is on for this session, in the terminal." ;;
            app) echo "Monoword mode is on for this session, in the Monoword app." ;;
            *) echo "Monoword mode is off for this session." ;;
        esac
        ;;
esac
exit 0
