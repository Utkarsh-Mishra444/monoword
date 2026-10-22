#!/bin/bash
# Stop hook. Saves the finished reply (for /monoword:read and the terminal player) and, in app mode
# only, opens it in the Monoword app. In terminal mode the plugin's mod (hooks/band.mjs) plays it
# above the prompt; nothing is opened. Never blocks Claude from stopping.
set -u
. "$(dirname "$0")/common.sh"

input="$(cat)"
state="$(monoword_state_dir "")"
sid="$(monoword_session_id "$(printf '%s' "$input" | monoword_json_string session_id)")"
text="$(printf '%s' "$input" | monoword_json_string last_assistant_message)"
[ -n "$text" ] || exit 0

mkdir -p "$state/replies" "$state/sessions"

# After /monoword:read, this reply is only the confirmation: keep the saved reply and the reader as they are.
skip="$state/sessions/$sid.skip"
if [ -f "$skip" ] && [ "$(cat "$skip")" = "1" ]; then
    printf '0' > "$skip"
    exit 0
fi

file="$state/replies/$sid.txt"
printf '%s\n' "$text" > "$file"

[ "$(monoword_mode "$state" "$sid")" = "app" ] || exit 0
if ! monoword_open_file "$file"; then
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg m "$monoword_install_hint" '{systemMessage: $m}'
    else
        printf '{"systemMessage": "%s"}\n' "$monoword_install_hint"
    fi
fi
exit 0
