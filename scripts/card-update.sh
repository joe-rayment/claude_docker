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
You are writing ONE INDEX CARD about a coding session, for someone glancing at
a side panel. It must fit on a card: at most 12 lines, no line over 68
characters, no scrolling, no markdown headers, no preamble, no sign-off.

Exactly this shape, and nothing else:

NOW: <one line: what is being worked on this minute>
WHY: <one line: what the person actually asked for>
DONE: <up to 3 lines, one fact each, past tense, concrete>
NEXT: <one line, or "-" if unclear>
SNAG: <one line, or "-" if nothing is wrong>

Rules: plain words. Name files, commands and numbers rather than describing
them. Never say "the assistant" or "the user" -- say what happened. If the
transcript is mostly one long explanation, say what it concluded in one line;
do not summarise the explaining.

Transcript tail follows.
P

card="$(printf '%s\n\n%s\n' "$PROMPT" "$material" \
    | timeout "$CARD_TIMEOUT" claude -p --model "$CARD_MODEL" 2>/dev/null)"
[ -n "$card" ] || exit 0

mkdir -p "$(dirname "$CARD_FILE")" 2>/dev/null || exit 0
tmp="$CARD_FILE.tmp.$$"
{ printf '%s\n' "$card"; printf '\n@ %s\n' "$(date '+%H:%M:%S')"; } > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; exit 0; }
mv -f "$tmp" "$CARD_FILE" 2>/dev/null
exit 0
