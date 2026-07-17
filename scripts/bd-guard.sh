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

# --- SOFT RULE (close only): residual work discharged in prose ---------------
# Observed violation shape (2026-07-17 audit): a close_reason that admits
# leftover or unverified work in prose ("the sole residual step is 'git
# push'", "carried outside the tracker", "NOT verified in-container") —
# discharging real work out of the tracker instead of filing a Claude-owned
# follow-up bead. Exempt reasons that already point at a follow-up bead.
if printf '%s' "$command_str" | grep -qE '(^|[;&|(] *)bd +close\b'; then
  residual_re='(residual|remaining|outstanding|left.?over) (step|work|task|item)|carried outside the tracker|not (yet )?(verified|tested|pushed)|unverified|auth.?blocked'
  followup_re='(follow.?up|filed|tracked|moved|captured) (as|in|to)? *(bead|bd[-_ ]|beads_|issue)'
  if printf '%s' "$command_str" | grep -qiE "$residual_re" && \
     ! printf '%s' "$command_str" | grep -qiE "$followup_re"; then
    [ "${BD_GUARD_ALLOW:-0}" = "1" ] && exit 0
    block "BLOCKED (bd-guard): this close reason admits residual or unverified work in prose. Closing a bead does not discharge the work — prose in a close reason is where tasks go to die. Before closing: (1) file a Claude-owned follow-up bead for the residual step (never assigned to the user) and mention its id in the close reason, or simply keep this bead open; (2) if the step is blocked on something only the user can do (e.g. credentials), the follow-up bead still carries it as Claude's open item — and ask the user for the unblocking action in chat NOW. Then re-run the close (BD_GUARD_ALLOW=1 only if the wording is a false positive)."
  fi
fi

exit 0
