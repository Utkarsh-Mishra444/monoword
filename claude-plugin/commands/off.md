---
description: Monoword mode off. Back to normal formatting; replies no longer open in Monoword.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh":*)
---
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" off "${CLAUDE_PLUGIN_DATA}" "${CLAUDE_SESSION_ID}"`

Monoword mode is now off for this session. Reply with one short sentence saying so, and use your normal formatting from the next reply on.
