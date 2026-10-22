#!/bin/bash
# UserPromptSubmit hook. While Monoword mode is on for this session, attaches the one-word
# writing notes (style.md) to the prompt. Otherwise it adds nothing.
set -u
. "$(dirname "$0")/common.sh"

input="$(cat)"
state="$(monoword_state_dir "")"
sid="$(monoword_session_id "$(printf '%s' "$input" | monoword_json_string session_id)")"
monoword_mode_is_on "$state" "$sid" || exit 0

style="$(dirname "$0")/../style.md"
if command -v jq >/dev/null 2>&1; then
    jq -Rs '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: .}}' "$style"
else
    python3 -c 'import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                         "additionalContext": open(sys.argv[1]).read()}}))' "$style"
fi
exit 0
