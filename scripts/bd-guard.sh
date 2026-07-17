#!/usr/bin/env bash
# bd-guard — PreToolUse(Bash) hook: keep beads Claude-only.
#
# Beads are Claude Code's own task memory. A bead assigned to a human, or
# describing work the user must do ("ask Joe", "waiting for user review"),
# violates the Ownership rule in CLAUDE.md: questions go to chat, decisions
# are asked in conversation, and every bead stays Claude-owned work.
#
# This hook enforces that at the point of creation:
#   - HARD block (no override): bd create/update/assign with a non-agent
#     assignee.
#   - SOFT block (override with BD_GUARD_ALLOW=1): user-directed phrasing in
#     the bead text. Override is for false positives only — e.g. the phrase is
#     quoted content or code under discussion — never to park user work in a
#     bead.
#
# Contract: reads the Claude Code hook JSON on stdin; exit 0 = allow,
# exit 2 = block (stderr is fed back to the model).

set -u

command_str=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$command_str" ] || exit 0

# Fast path: only inspect commands that touch bead creation/mutation.
# `close` is included for its --reason text: leaving "user should push X"
# in a close reason is the same violation as filing it as a bead.
printf '%s' "$command_str" | grep -qE '(^|[;&|(] *)bd +(create|new|update|assign|close)\b' || exit 0

block() {
  printf '%s\n' "$1" >&2
  exit 2
}

# --- HARD RULE: assignee must be Claude/agent, never a human -----------------
# Covers: bd create/update ... -a X | --assignee X | --assignee=X
#         bd assign <id> <name>
assignees=$(printf '%s' "$command_str" \
  | grep -oE -- '(--assignee(=| +)|[^-]-a +)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^ ]+)' \
  | sed -E 's/^.*(--assignee(=| +)|-a +)//; s/^["'"'"']//; s/["'"'"']$//')
printf '%s' "$command_str" | grep -qE '(^|[;&|(] *)bd +assign\b' && \
  assignees="$assignees
$(printf '%s' "$command_str" | sed -nE 's/.*bd +assign +[^ ]+ +("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^ ;&|]+)).*/\2\3\4/p')"

while IFS= read -r a; do
  [ -z "$a" ] && continue
  case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in
    claude*|agent*|ai|bot|"") ;;  # agent identities OK
    *) block "BLOCKED (bd-guard): assignee '$a' is not an agent identity. Beads are Claude Code's own work items and are NEVER assigned to a human — no override exists for this. If the underlying work needs a human decision or action, do not file a bead: ask the user directly in chat, right now, in your reply. If the work is Claude's, use --claim (or leave unassigned)." ;;
  esac
done <<EOF
$assignees
EOF

# --- SOFT RULE: user-directed phrasing in bead text --------------------------
# Two tiers: "joe|human" gets broad matching; "user" gets directive-only
# patterns, because "user input", "user review", "allow the user to ..." are
# ordinary feature language and must not trip the guard.
patterns=(
  # narrow, directive-only — safe for the word "user"
  "ask (the )?(user|human|joe)"
  "wait(ing)? (on|for) (the )?(user|human|joe)"
  "blocked (on|by) (the )?(user|human|joe)"
  "(user|human|joe)('s)? (decision|approval|sign.?off)"
  "(confirm|check|clarify) with (the )?(user|human|joe)"
  "hand(ed|s)?.?off to (the )?(user|human|joe)"
  "assigned to (the )?(user|human|joe)"
  "(user|human|joe) (should|must|needs? to|has to) (review|decide|approve|confirm|test|verify|run|check)"
  # broad — only for an explicitly named human
  "(human|joe) (should|must|needs? to|has to|will|to) "
  "(human|joe) (input|review|feedback|action)"
  "for (the )?(human|joe) to "
)
joined=$(IFS='|'; printf '%s' "${patterns[*]}")

if printf '%s' "$command_str" | grep -qiE "$joined"; then
  [ "${BD_GUARD_ALLOW:-0}" = "1" ] && exit 0
  block "BLOCKED (bd-guard): this bead's text describes work or a decision belonging to the user (matched a phrase like 'ask the user' / 'waiting for user' / 'user review'). Beads are Claude-only; questions are handled in chat. Do this instead, at the point of creation: (1) if a user decision is needed, ask it in your reply NOW — do not park it in a bead; (2) rewrite the bead as work Claude itself will do, including how Claude will verify it in the running program; (3) capture any already-made decision in the bead as a fact, not as a pending request. Only if this is a genuine false positive (the phrase is quoted content/code, not pending user work) re-run prefixed with BD_GUARD_ALLOW=1."
fi

exit 0
