---
description: Monoword mode on. Replies become plain spoken prose and play one word at a time above the prompt; "app" opens them in the Monoword app instead.
argument-hint: "[app]"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh":*)
---
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" on "${CLAUDE_PLUGIN_DATA}" "${CLAUDE_SESSION_ID}" "$ARGUMENTS"`

The line above is the result of turning Monoword mode on for this session. While it is on, the user reads each of your replies one word at a time, so follow the Monoword style notes that arrive with each prompt. Reply now with the text above in one or two short plain sentences, and nothing else.
