#!/bin/bash
# Opens the last finished reply of this session in Monoword. Run by the /monoword:read command.
#   read-last.sh [data directory] [session id]
set -u
. "$(dirname "$0")/common.sh"

state="$(monoword_state_dir "${1:-}")"
sid="$(monoword_session_id "${2:-}")"

file="$state/replies/$sid.txt"
if [ ! -f "$file" ]; then
    # No reply saved under this session id (an older Claude Code may not pass one): use the newest.
    file="$(ls -t "$state/replies"/*.txt 2>/dev/null | head -n 1)"
fi
if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo "There is no saved reply yet. Monoword keeps the last finished reply of each session; ask something first, then run /monoword:read."
    exit 0
fi

words="$(wc -w < "$file" | tr -d ' ')"
if monoword_open_file "$file"; then
    # The one-line confirmation Claude gives next must not replace this reply in the reader.
    mkdir -p "$state/sessions"
    printf '1' > "$state/sessions/$sid.skip"
    echo "Opened the previous reply ($words words) in Monoword."
else
    echo "Could not open Monoword. $monoword_install_hint"
fi
exit 0
