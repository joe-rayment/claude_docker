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
#     bead. The override is honored two ways: an exported BD_GUARD_ALLOW=1 in
#     the hook's environment, OR a literal `BD_GUARD_ALLOW=1 ` assignment
#     written as a prefix on the command string (the form the block message
#     suggests — it never reaches this process's environment, so we detect it
#     in the command text and apply it ourselves).
#
# Bypass resistance: every rule runs against a *normalized* view of the
# command, not the raw string. Tabs are folded to spaces (so a tab between a
# flag and its value can't hide it), and command-position noise — leading
# environment assignments (`FOO=1 bd …`) and wrapper words (`command bd …`,
# `env bd …`, `nohup bd …`) — is stripped so `bd` is exposed at a command
# position for the anchors below. This closes the column-0/`;&|(`-only anchor
# that previously let `  bd`, `command bd`, `FOO=1 bd`, and tab-separated forms
# slip past.
#
# Contract: reads the Claude Code hook JSON on stdin; exit 0 = allow,
# exit 2 = block (stderr is fed back to the model).
# POSIX sh (dash) clean; uses GNU grep/sed -E (the container's) — `\b` is a GNU
# ERE extension and is intentionally avoided here in favor of explicit
# [[:space:]]/anchors so behavior is stable.

set -u

# Deliberate fail-open: if stdin is not parseable JSON (jq errors), allow the
# command. A bug in this hook must never brick every Bash call in the session.
command_str=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$command_str" ] || exit 0

# Fold tabs to spaces up front so tab separators (bd<TAB>create, -a<TAB>joe,
# --assignee<TAB>joe) can never split a token from what follows it.
cmd_tabs=$(printf '%s' "$command_str" | tr '\t' ' ')

# Cheap pre-filter: the vast majority of Bash calls never mention a bd verb —
# skip all normalization for them.
printf '%s' "$cmd_tabs" | grep -qE 'bd[[:space:]]+(create|new|update|assign|close)' || exit 0

# Strip command-position noise that would otherwise hide `bd` from the anchors:
# at the start of the string or right after a ; && || | ( ) separator, remove a
# leading run of VAR=value environment assignments and wrapper words. Looped
# because several may stack, e.g. `  FOO=1 command bd create`.
norm_cmd=$cmd_tabs
i=0
while [ "$i" -lt 20 ]; do
  stripped=$(printf '%s' "$norm_cmd" | sed -E 's/(^|[;&|(){])([[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|command|builtin|env|nohup|time|exec|sudo)[[:space:]]+/\1\2/g')
  [ "$stripped" = "$norm_cmd" ] && break
  norm_cmd=$stripped
  i=$((i + 1))
done

# Precise gate on the normalized command: bd + verb at a command position
# (string start or right after ; && || | ( ), with leading whitespace allowed).
printf '%s' "$norm_cmd" | grep -qE '(^|[;&|(){])[[:space:]]*bd[[:space:]]+(create|new|update|assign|close)([[:space:]]|$)' || exit 0

# Override resolution (SOFT rule only). An exported env var is honored, and so
# is a literal `BD_GUARD_ALLOW=1` assignment written as a command prefix — that
# assignment is scoped to the not-yet-run command and never reaches this
# process, so we read it from the command text and apply it ourselves.
allow=0
[ "${BD_GUARD_ALLOW:-0}" = "1" ] && allow=1
# Honor a literal BD_GUARD_ALLOW=1 only in genuine command-prefix position — as
# one of the leading env-assignments/wrappers before the (possibly wrapped) bd
# word — so a trailing `# BD_GUARD_ALLOW=1` comment or an embedded value cannot
# unlock the soft rule.
printf '%s' "$cmd_tabs" | grep -qE '(^|[;&|(){])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|(command|builtin|env|nohup|time|exec|sudo)[[:space:]]+)*BD_GUARD_ALLOW=1[[:space:]]' && allow=1

block() {
  printf '%s\n' "$1" >&2
  exit 2
}

# --- HARD RULE: assignee must be Claude/agent, never a human -----------------
# Covers: bd create/update ... --assignee X | --assignee=X | -a X | -a=X | -aX
#         bd assign <id> <name>
# The short flag -a is anchored at a token boundary (start or whitespace) so it
# never matches inside a long flag like --all or --assignee; bd's parser accepts
# the spaced, =-glued, and value-glued spellings, so all three are extracted.
assignees=$(printf '%s' "$norm_cmd" \
  | grep -oE -- '(--assignee(=|[[:space:]]+)|(^|[[:space:]])-a(=|[[:space:]]+)?)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|)]+)' \
  | sed -E 's/^.*(--assignee(=|[[:space:]]+)|-a(=|[[:space:]]+)?)//; s/^["'"'"']//; s/["'"'"']$//')
printf '%s' "$norm_cmd" | grep -qE '(^|[;&|(){])[[:space:]]*bd[[:space:]]+assign([[:space:]]|$)' && \
  assignees="$assignees
$(printf '%s' "$norm_cmd" | sed -nE 's/.*bd +assign +[^ ]+ +("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^ ;&|]+)).*/\2\3\4/p')"

while IFS= read -r a; do
  [ -z "$a" ] && continue
  case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in
    claude|claude[-_]*|agent|agent[-_]*|ai|bot|"") ;;  # agent identities OK
    *) block "BLOCKED (bd-guard): assignee '$a' is not an agent identity. Beads are Claude Code's own work items and are NEVER assigned to a human — no override exists for this. If the underlying work needs a human decision or action, do not file a bead: ask the user directly in chat, right now, in your reply. If the work is Claude's, use --claim (or leave unassigned)." ;;
  esac
done <<EOF
$assignees
EOF

# --- SOFT RULE: user-directed phrasing in bead text --------------------------
# Two tiers: "joe|human" gets broad matching; "user" gets directive-only
# patterns, because "user input", "user review", "allow the user to ...",
# "tasks assigned to the user" are ordinary feature language and must not trip
# the guard. ("assigned to" therefore matches only a named human, not "user".)
joined='ask (the )?(user|human|joe)|wait(ing)? (on|for) (the )?(user|human|joe)|blocked (on|by) (the )?(user|human|joe)|(user|human|joe)('"'"'s)? (decision|approval|sign.?off)|(confirm|check|clarify) with (the )?(user|human|joe)|hand(ed|s)?.?off to (the )?(user|human|joe)|assigned to (the )?(human|joe)|(user|human|joe) (should|must|needs? to|has to) (review|decide|approve|confirm|test|verify|run|check)|(human|joe) (should|must|needs? to|has to|will|to) |(human|joe) (input|review|feedback|action)|for (the )?(human|joe) to '

if printf '%s' "$norm_cmd" | grep -qiE "$joined"; then
  [ "$allow" = "1" ] && exit 0
  block "BLOCKED (bd-guard): this bead's text describes work or a decision belonging to the user (matched a phrase like 'ask the user' / 'waiting for user' / 'blocked on Joe'). Beads are Claude-only; questions are handled in chat. Do this instead, at the point of creation: (1) if a user decision is needed, ask it in your reply NOW — do not park it in a bead; (2) rewrite the bead as work Claude itself will do, including how Claude will verify it in the running program; (3) capture any already-made decision in the bead as a fact, not as a pending request. Only if this is a genuine false positive (the phrase is quoted content/code, not pending user work) re-run the exact command with a 'BD_GUARD_ALLOW=1 ' prefix on the command string."
fi

# --- SOFT RULE (close only): residual work discharged in prose ---------------
# Observed violation shape (2026-07-17 audit): a close_reason that admits
# leftover or unverified work in prose ("the sole residual step is 'git
# push'", "carried outside the tracker", "NOT verified in-container") —
# discharging real work out of the tracker instead of filing a Claude-owned
# follow-up bead. Patterns are tightened to the admission shape: the residual
# noun is a pending *step* (not generic "work items"), "unverified" must stand
# alone (not "unverified-email"), and "not pushed/tested twice" (a feature-
# behavior spec) is excluded. Reasons that already point at a follow-up bead
# are exempt.
if printf '%s' "$norm_cmd" | grep -qE '(^|[;&|(){])[[:space:]]*bd[[:space:]]+close([[:space:]]|$)'; then
  residual_re='(residual|outstanding|left.?over|remaining) (step|steps)|carried outside the tracker|not (yet )?(verified|tested|pushed)|unverified([^[:alnum:]-]|$)|auth.?blocked'
  innocuous_re='not (yet )?(verified|tested|pushed) (twice|again|repeatedly|more than once)'
  followup_re='(follow.?up|filed|tracked|moved|captured) (as|in|to)? *(bead|bd[-_ ]|beads_|issue)'
  if printf '%s' "$norm_cmd" | grep -qiE "$residual_re" \
     && ! printf '%s' "$norm_cmd" | grep -qiE "$innocuous_re" \
     && ! printf '%s' "$norm_cmd" | grep -qiE "$followup_re"; then
    [ "$allow" = "1" ] && exit 0
    block "BLOCKED (bd-guard): this close reason admits residual or unverified work in prose. Closing a bead does not discharge the work — prose in a close reason is where tasks go to die. Before closing: (1) file a Claude-owned follow-up bead for the residual step (never assigned to the user) and mention its id in the close reason, or simply keep this bead open; (2) if the step is blocked on something only the user can do (e.g. credentials), the follow-up bead still carries it as Claude's open item — and ask the user for the unblocking action in chat NOW. Then re-run the close (add a 'BD_GUARD_ALLOW=1 ' prefix to the command only if the wording is a false positive)."
  fi
fi

exit 0
