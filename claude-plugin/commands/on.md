---
description: Monoword mode on. Replies become plain spoken prose and each one opens in the Monoword reader.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh":*)
---
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" on "${CLAUDE_PLUGIN_DATA}" "${CLAUDE_SESSION_ID}"`

Monoword mode is now on for this session: the user will read each of your replies one word at a time in Monoword, so from now on follow the Monoword style notes that arrive with each prompt. Reply now with one short plain sentence saying Monoword mode is on, repeating any warning printed above, and nothing else.
