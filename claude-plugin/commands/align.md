---
description: Put the word at the left, the center or the right of the strip above the prompt (center to start with).
argument-hint: "left | center | right"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/align.sh":*)
---
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/align.sh" "$ARGUMENTS" "${CLAUDE_PLUGIN_DATA}"`

The line above is the result of setting where Monoword's terminal strip shows the word. Repeat it to the user in one short sentence and do nothing else.
