#!/bin/bash
# Shared by the Monoword plugin scripts. Sourced, not run.
#
# State lives in the plugin's data directory (Claude Code keeps it across plugin updates):
#   sessions/<session id>   "tty", "app" or "off" for that session (written by mode.sh only;
#                           "on", from plugin 1.0.0, reads as "app")
#   replies/<session id>.txt  the last finished reply of that session
#   settings.json           {"wpm": 500, "align": "center"}: the terminal player's speed (speed.sh)
#                           and where the word sits in the strip (align.sh)
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

monoword_mode() {  # $1: state dir, $2: session id. Prints tty, app or off.
    local f="$1/sessions/$2" word=""
    if [ -f "$f" ]; then word="$(cat "$f")"
    elif [ -f "$1/sessions/default" ]; then word="$(cat "$1/sessions/default")"
    fi
    case "$word" in
        tty) printf 'tty' ;;
        app|on) printf 'app' ;;
        *) printf 'off' ;;
    esac
}

monoword_mode_is_on() {  # $1: state dir, $2: session id. True in terminal and app mode.
    [ "$(monoword_mode "$1" "$2")" != "off" ]
}

monoword_app_installed() {
    [ -d "/Applications/Monoword.app" ] || [ -d "$HOME/Applications/Monoword.app" ]
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

# The terminal player's settings.json. Each key is set on its own, so speed.sh and align.sh never
# wipe each other's value; a file that is not a JSON object is replaced.
monoword_setting_get() {  # $1: settings file, $2: key. Prints the value as text, or nothing.
    [ -f "$1" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$2" 'if type == "object" then (.[$k] // empty | tostring) else empty end' "$1" 2>/dev/null
    else
        python3 -c 'import json, sys
try:
    v = json.load(open(sys.argv[1]))
except Exception:
    v = None
if isinstance(v, dict) and v.get(sys.argv[2]) is not None:
    print(v[sys.argv[2]])' "$1" "$2" 2>/dev/null
    fi
}

monoword_setting_set() {  # $1: settings file, $2: key, $3: value as JSON (500 or "\"left\"")
    local file="$1" tmp="$1.tmp"
    mkdir -p "$(dirname "$file")" || return 1
    if command -v jq >/dev/null 2>&1; then
        if [ -f "$file" ]; then
            jq --arg k "$2" --argjson v "$3" 'if type == "object" then . else {} end | .[$k] = $v' "$file" > "$tmp" 2>/dev/null \
                || jq -n --arg k "$2" --argjson v "$3" '{} | .[$k] = $v' > "$tmp"
        else
            jq -n --arg k "$2" --argjson v "$3" '{} | .[$k] = $v' > "$tmp"
        fi
    else
        python3 -c 'import json, sys
path, key, value = sys.argv[1:4]
try:
    d = json.load(open(path))
except Exception:
    d = None
if not isinstance(d, dict): d = {}
d[key] = json.loads(value)
json.dump(d, open(path + ".tmp", "w"))
print(file=open(path + ".tmp", "a"))' "$file" "$2" "$3" 2>/dev/null
    fi && mv "$tmp" "$file"
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
