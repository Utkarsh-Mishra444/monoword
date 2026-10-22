---
description: Play the previous reply again, above the prompt in terminal mode or in the Monoword app in app mode (works with the mode off too).
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-last.sh":*)
---
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-last.sh" "${CLAUDE_PLUGIN_DATA}" "${CLAUDE_SESSION_ID}"`

The line above is the result of opening your previous reply in Monoword. Repeat it to the user in one short sentence and do nothing else.
