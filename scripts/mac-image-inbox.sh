#!/usr/bin/env bash
#
# mac-image-inbox -- UserPromptSubmit hook. Lets Claude see an image the
# person dragged or pasted from their Mac as a file path (claude-orca-bmk).
#
# Why: Claude Code runs in this Linux container; the person types into it
# from Ghostty on a Mac over ssh. Dragging an image file onto the terminal,
# or copying it in Finder and pressing cmd+v, makes Ghostty type the file's
# MAC path as text, e.g.
#   /Users/me/Desktop/Screenshot\ 2026-10-16\ at\ 1.02.46<U+202F>PM\ \(2\).png
# The container cannot open that path, so Claude Code attaches nothing and
# Claude never sees the image. This hook finds such paths in the prompt and
# asks the Mac for the file over the clipboard bridge (the socket ssh
# forwards to scripts/mac/clip-serve; bin/xclip talks to the same socket).
#
# How: for each image path in the prompt that the container cannot read,
#   POST /file   body = the Mac path, raw bytes
# goes over the unix socket. 200 returns the image as PNG bytes, saved under
# "$(run_dir)/inbox/". Then one JSON object is printed,
#   {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit",
#                          "additionalContext":"..."}}
# telling Claude which copy stands for which Mac path and to Read it, or why
# a path could not be fetched (403 not on the Mac clipboard / last drag,
# 404, 413 too big, no socket, anything else: the code).
#
# Usage: mac-image-inbox          (hook JSON on stdin; only .prompt is read)
#
# Paths recognised: absolute, ending png|jpg|jpeg|gif|webp|heic|heif|tif|
# tiff|bmp (any case), written backslash-escaped (\X -> X), 'single-quoted',
# "double-quoted" or plain. Several may appear (a multi-file drop is
# space-separated); duplicates are dropped and at most 5 are handled. A path
# the container can read ([ -r ]) is skipped -- Claude Code attaches it.
#
# Speed: a prompt with no image extension in it never reaches jq or python;
# one grep over the raw input ends it.
#
# Env seams:
#   CLAUDE_ORCA_CLIP_SOCK   the forwarded socket (default /tmp/cdev-clip.sock)
#   CLAUDE_ORCA_ROOT        project root for run_dir (see lib/paths.sh)
#
# Exit codes: always 0. A hook must never block a prompt; a missing jq or
# curl or python3, garbage on stdin, a dead bridge just mean no output (or a
# context that says what failed). Prints nothing but the JSON, and nothing
# at all when there is nothing to do.

set -u
exec 2>/dev/null

[ -t 0 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
[ -n "$input" ] || exit 0

EXT='png|jpe?g|gif|webp|heic|heif|tiff?|bmp'

# The common prompt names no image file: out before any other process.
printf '%s' "$input" | LC_ALL=C grep -qiE "\\.($EXT)" || exit 0

command -v python3 >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

_resolve_script_path() {
    local src="${BASH_SOURCE[0]}" link dir
    while [ -L "$src" ]; do
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(case "$src" in (*/*) cd "${src%/*}/" ;; esac && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(_s="$(_resolve_script_path)"; case "$_s" in (*/*) cd "${_s%/*}/" ;; esac && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

prompt="$(printf '%s' "$input" | jq -j '(.prompt // "") | tostring')"
[ -n "$prompt" ] || exit 0

# The paths, NUL-separated, unescaped, deduped, at most 5. The prompt comes
# in on stdin; the program is a constant. Bytes in, bytes out (surrogateescape)
# so a C locale cannot garble U+202F and friends.
PARSE='
import re, sys

EXT = re.compile(r"\.(?:png|jpe?g|gif|webp|heic|heif|tiff?|bmp)\Z", re.I)
TOKEN = re.compile(r"(?:\\.|[^ \t\r\n\\])+", re.S)   # ASCII blanks only: U+202F is part of a name
TRAIL = ".,;:!?)]}>\x27\""
BEFORE = "([{<>,;=\x27\""                            # what may sit right before a plain /path

def unescape(s):
    return re.sub(r"\\(.)", r"\1", s, flags=re.S)

def good(s):
    return s.startswith("/") and "\n" not in s and "\0" not in s \
        and len(s) <= 4096 and EXT.search(s) is not None

text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
found, i, n = [], 0, len(text)
while i < n:
    c = text[i]
    if c in "\x27\"":
        j = i + 1
        while j < n and text[j] != c:
            j += 2 if text[j] == "\\" and c == "\"" else 1
        if j < n:
            body = unescape(text[i + 1:j])
            if good(body):
                found.append(body)
                i = j + 1
                continue
        i += 1                                      # an apostrophe in prose, not a quote
        continue
    if c == "/" and (i == 0 or text[i - 1].isspace() or text[i - 1] in BEFORE):
        m = TOKEN.match(text, i)
        tok = m.group(0)
        i = m.end()
        cand = tok
        while True:
            if good(unescape(cand)):
                found.append(unescape(cand))
                break
            if cand and cand[-1] in TRAIL and not cand.endswith("\\" + cand[-1]):
                cand = cand[:-1]
                continue
            break
        continue
    i += 1

seen, out = set(), []
for p in found:
    if p not in seen:
        seen.add(p)
        out.append(p)
sys.stdout.buffer.write(b"".join(p.encode("utf-8", "surrogateescape") + b"\0" for p in out[:5]))
'

paths=()
while IFS= read -r -d '' p; do
    paths+=("$p")
done < <(printf '%s' "$prompt" | python3 -I -c "$PARSE")
[ "${#paths[@]}" -gt 0 ] || exit 0

SOCK="${CLAUDE_ORCA_CLIP_SOCK:-/tmp/cdev-clip.sock}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mac-image-inbox.XXXXXX")" || exit 0
trap 'rm -rf "$tmp"' EXIT

inbox=""
stamp="$(date +%Y%m%d-%H%M%S)"
n=0
ok=""      # "<mac path> -> <container copy>" lines
bad=""     # "<mac path>: <why>" lines
nl=$'\n'

for p in "${paths[@]}"; do
    # Claude Code attaches what the container can read on its own.
    [ -r "$p" ] && continue
    n=$((n + 1))

    if [ ! -S "$SOCK" ]; then
        bad="${bad}- ${p}: no clipboard bridge in this session (the Mac clipboard socket is not connected), so the image could not be fetched${nl}"
        continue
    fi

    printf '%s' "$p" > "$tmp/path"
    code="$(curl -sS --connect-timeout 2 --max-time 30 --unix-socket "$SOCK" \
        -X POST -H 'Expect:' -H 'Content-Type: application/octet-stream' \
        --data-binary @"$tmp/path" -o "$tmp/body" -w '%{http_code}' http://clip/file)"
    code="${code:-000}"

    case "$code" in
        200)
            if [ ! -s "$tmp/body" ]; then
                bad="${bad}- ${p}: the Mac sent back an empty file${nl}"
                continue
            fi
            if [ -z "$inbox" ]; then
                if root_run="$(run_dir)" && [ -n "$root_run" ]; then
                    inbox="$root_run/inbox"
                else
                    inbox="${TMPDIR:-/tmp}/claude-orca-inbox"
                fi
                mkdir -p "$inbox" || { inbox=""; bad="${bad}- ${p}: could not create the inbox folder${nl}"; continue; }
            fi
            base="${p##*/}"
            base="${base%.*}"
            base="$(printf '%s' "$base" | LC_ALL=C tr -cs 'A-Za-z0-9._-' '_')"
            [ -n "$base" ] || base="image"
            dest="$inbox/$stamp-$n-$base.png"
            if cp "$tmp/body" "$dest"; then
                ok="${ok}- ${p} -> ${dest}${nl}"
            else
                bad="${bad}- ${p}: could not save the image into ${inbox}${nl}"
            fi
            ;;
        403) bad="${bad}- ${p}: it is no longer on the Mac clipboard or the last drag; copy it in Finder or drag it again${nl}" ;;
        404) bad="${bad}- ${p}: the Mac has no such file${nl}" ;;
        413) bad="${bad}- ${p}: the image is too big to bring over from the Mac${nl}" ;;
        400) bad="${bad}- ${p}: the Mac bridge rejected the request as malformed (HTTP 400)${nl}" ;;
        000) bad="${bad}- ${p}: the Mac clipboard bridge did not answer (connection failed or timed out)${nl}" ;;
        *)   bad="${bad}- ${p}: the Mac clipboard bridge answered HTTP ${code}${nl}" ;;
    esac
done

[ -n "$ok" ] || [ -n "$bad" ] || exit 0

ctx="The person attached image(s) from their Mac by pasting or dropping a file path that this Linux container cannot open, so Claude Code did not attach them itself."
if [ -n "$ok" ]; then
    ctx="${ctx}${nl}The clipboard bridge fetched a copy of each of these (Mac path -> container copy):${nl}${ok}Read each copy with the Read tool before answering."
fi
if [ -n "$bad" ]; then
    ctx="${ctx}${nl}These could not be fetched:${nl}${bad}You cannot see these images; tell the person why instead of guessing what they show."
fi

jq -n -c --arg ctx "$ctx" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'

exit 0
