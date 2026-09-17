#!/bin/bash
# Claude Code subagentStatusLine -- suppresses the native sub-agent rows under
# the status bar (claude-orca-640): Claude Code consults this command once per
# running agent, and an agent whose command returns empty content is not
# rendered. The Orca sidebar is the agent display now; Orca's managed
# SubagentStart/SubagentStop hook entries feed it and stay. Echoing the id
# keeps the output a valid per-agent status payload.
input=$(cat)
printf '%s' "$input" | jq -c '{id: (.id // ""), content: ""}' 2>/dev/null \
    || printf '{"id":"","content":""}\n'