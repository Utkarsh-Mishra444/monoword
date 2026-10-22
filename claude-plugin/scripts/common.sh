#!/bin/bash
# Shared by the Monoword plugin scripts. Sourced, not run.
#
# State lives in the plugin's data directory (Claude Code keeps it across plugin updates):
#   sessions/<session id>   "on" or "off" for that session
#   replies/<session id>.txt  the last finished reply of that session
# Hooks get the directory as $CLAUDE_PLUGIN_DATA; the slash commands pass it as an argument,
# because Claude Code substitutes ${CLAUDE_PLUGIN_DATA} in the command text, not in the shell.

monoword_state_dir() {  # $1: data directory passed by a command, may be empty
    local dir="${1:-${CLAUDE_PLUGIN_DATA:-}}"
    if [ -z "$dir" ]; then dir="${XDG_STATE_HOME:-$HOME/.local/state}/monoword"; fi
    printf '%s' "$dir"
}

monoword_session_id() {  # $1: session id from the hook input or the command, may be empty
    local id="${1:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
    # The command text keeps "${CLAUDE_SESSION_ID}" literally on versions that do not substitute it.
    case "$id" in *'$'*|"") id="${CLAUDE_CODE_SESSION_ID:-default}" ;; esac
    printf '%s' "$id"
}

monoword_mode_is_on() {  # $1: state dir, $2: session id
    local f="$1/sessions/$2"
    if [ -f "$f" ]; then [ "$(cat "$f")" = "on" ]; return; fi
    [ -f "$1/sessions/default" ] && [ "$(cat "$1/sessions/default")" = "on" ]
}

# Reads a JSON object on stdin and prints the string value of key $1, or nothing.
monoword_json_string() {
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$1" '.[$k] | strings'
    else
        python3 -c 'import json, sys
v = json.load(sys.stdin).get(sys.argv[1])
if isinstance(v, str): sys.stdout.write(v)' "$1"
    fi
}

monoword_urlencode() {  # $1: string
    if command -v jq >/dev/null 2>&1; then
        jq -rn --arg s "$1" '$s | @uri'
    else
        python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
    fi
}

# Opens a text file in the Monoword reader. Returns 1 when macOS has no app for monoword:// URLs.
# MONOWORD_PLUGIN_DRY_RUN=<file> appends the URL to that file instead of opening it (for tests).
monoword_open_file() {  # $1: path
    local url="monoword://read?file=$(monoword_urlencode "$1")"
    if [ -n "${MONOWORD_PLUGIN_DRY_RUN:-}" ]; then
        printf '%s\n' "$url" >> "$MONOWORD_PLUGIN_DRY_RUN"
        return 0
    fi
    open -g "$url" 2>/dev/null
}

monoword_install_hint="Monoword is not installed, or has not been opened once yet. Get it at https://github.com/Utkarsh-Mishra444/monoword/releases/latest and open it once."
