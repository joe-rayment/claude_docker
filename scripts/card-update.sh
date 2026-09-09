#!/usr/bin/env bash
# card-update.sh -- the Stop hook's worker: turn the tail of a Claude Code
# transcript into one index card for the pane scripts/card-view.sh draws.
#
# Takes .transcript_path from the hook payload on stdin (Stop /
# UserPromptSubmit / PostToolUse all carry it), or a transcript path as $1.
# A small model does the writing on purpose -- the point is a short, clear
# card, not another paragraph from the big model. Writes $CARD_FILE through
# a temp file and `mv` so a reader (scripts/card-view.sh, polling the file's
# mtime) never sees a partial card.
#
# Fails open everywhere: no payload, no transcript, no jq, no claude on
# PATH, a model that answers nothing -- exit 0 and leave the previous card
# alone. This runs from a hook; it must never be the reason a turn fails.
set -uo pipefail

CARD_FILE="${CARD_FILE:-${PROJECT_DIR:-/workspace/claude-orca}/.claude-dev/run/card.md}"
CARD_MODEL="${CARD_MODEL:-claude-haiku-4-5-20251001}"
CARD_TURNS="${CARD_TURNS:-6}"
CARD_BUDGET="${CARD_BUDGET:-6000}"
CARD_ROW_CAP="${CARD_ROW_CAP:-600}"
CARD_TIMEOUT="${CARD_TIMEOUT:-120}"

transcript=""
if [ -n "${1:-}" ]; then
    transcript="$1"
else
    command -v jq >/dev/null 2>&1 || exit 0
    payload="$(cat 2>/dev/null)"
    transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
fi
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

command -v python3 >/dev/null 2>&1 || exit 0
command -v claude >/dev/null 2>&1 || exit 0

# The material: the last few turns, flattened. Thinking blocks are dropped
# entirely -- they are the longest thing in the file and the least useful
# to a reader. The tail is kept under a byte budget, with a per-row cap so
# one runaway message cannot fill it by itself.
material="$(python3 - "$transcript" "$CARD_TURNS" "$CARD_BUDGET" "$CARD_ROW_CAP" <<'PY'
import json, sys

path, turns, budget, row_cap = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
rows = []
try:
    fh = open(path, encoding="utf8", errors="replace")
except OSError:
    sys.exit(0)

with fh:
    for line in fh:
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") not in ("user", "assistant") or o.get("isSidechain"):
            continue
        m = o.get("message") or {}
        content = m.get("content")
        if isinstance(content, str):
            rows.append((m.get("role"), "text", content))
            continue
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            k = b.get("type")
            if k == "text":
                rows.append((m.get("role"), "text", b.get("text", "")))
            elif k == "tool_use":
                name = b.get("name", "?")
                inp = b.get("input") or {}
                hint = inp.get("command") or inp.get("file_path") or inp.get("description") or ""
                rows.append((m.get("role"), "tool", "%s %s" % (name, str(hint)[:160])))
            # "thinking" (and anything else) is dropped on purpose.

out, remaining = [], budget
for role, kind, text in reversed(rows):
    text = " ".join(str(text).split())[:row_cap]
    if not text:
        continue
    piece = "%s/%s: %s" % (role, kind, text)
    if remaining - len(piece) < 0:
        break
    remaining -= len(piece)
    out.append(piece)
    if len([r for r in out if r.startswith("user/text")]) > turns:
        break
print("\n".join(reversed(out)))
PY
)"
[ -n "$material" ] || exit 0

read -r -d '' PROMPT <<'P'
You are writing ONE INDEX CARD about a coding session, for the person running
it, in a tab they glance at. Your job is to say what is actually going on.

The session you are summarising is driven by a model that writes at length:
long preambles, caveats, restated plans, three paragraphs where one clause
would do. The card exists BECAUSE of that. Read past it. A wall of
explanation whose point is "the build was stale" is one line: the build was
stale. Never mirror the transcript's own length or its tone back at it.

At most 12 lines, no line over 68 characters, no scrolling, no markdown
headers, no preamble, no sign-off. Exactly this shape, and nothing else:

NOW: <one line: what is being worked on this minute>
WHY: <one line: what the person actually asked for>
DONE: <up to 3 lines, one fact each, past tense, concrete>
NEXT: <one line, or "-" if unclear>
SNAG: <one line, or "-" if nothing is wrong>

Rules: plain words. Name files, commands, numbers and error strings rather
than describing them -- "run-tests.sh --all: 11 failures, all pre-existing"
beats "the test suite was analysed". Never say "the assistant" or "the user".
Prefer what CHANGED over what was discussed: a decision reached, a file
edited, a command that failed. If a whole turn was explaining, give the
conclusion and drop the explanation. If the session is stuck, SNAG is the
most important line on the card -- say what is blocking and nothing else.

Transcript tail follows.
P

# --disallowed-tools is not a nicety. Seen live on 2026-09-08: a run whose
# material was thin did not fail -- it went and ran `git status`, then wrote
# "I need the session transcript... Can you either: 1. Paste the session
# transcript" onto the card, where it sat until the next turn. The card
# model answers from the prompt it was given or it answers nothing.
card="$(printf '%s\n\n%s\n' "$PROMPT" "$material" \
    | timeout "$CARD_TIMEOUT" claude -p --model "$CARD_MODEL" \
        --disallowed-tools Bash Read Write Edit Glob Grep WebFetch WebSearch Task \
        2>/dev/null)"
[ -n "$card" ] || exit 0

# Small models like to hand back a fenced block however plainly the prompt
# says not to. Strip one leading and one trailing fence rather than argue
# with it in the prompt.
card="$(printf '%s\n' "$card" | sed -e '1{/^[[:space:]]*```/d;}' -e '${/^[[:space:]]*```[[:space:]]*$/d;}')"
[ -n "$card" ] || exit 0

# A card that is answering rather than reporting is a failed run, not a
# card: keep the previous one instead of putting a chat reply on screen.
case "$card" in
    NOW:*|*"NOW:"*) : ;;
    *) exit 0 ;;
esac

mkdir -p "$(dirname "$CARD_FILE")" 2>/dev/null || exit 0
tmp="$CARD_FILE.tmp.$$"
{ printf '%s\n' "$card"; printf '\n@ %s\n' "$(date '+%H:%M:%S')"; } > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; exit 0; }
mv -f "$tmp" "$CARD_FILE" 2>/dev/null
exit 0
