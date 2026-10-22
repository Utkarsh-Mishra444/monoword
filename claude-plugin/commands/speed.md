---
description: Set the speed of the terminal player in words a minute, pauses included (100 to 1500; default 500).
argument-hint: "<words a minute>"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/speed.sh":*)
---
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/speed.sh" "$ARGUMENTS" "${CLAUDE_PLUGIN_DATA}"`

The line above is the result of setting Monoword's terminal reading speed. Repeat it to the user in one short sentence and do nothing else.
