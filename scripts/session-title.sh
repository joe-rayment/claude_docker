#!/usr/bin/env bash
#
# session-title -- UserPromptSubmit hook. Makes every session's name start
# with the project: "<project>: <task>" (claude-orca-gcm).
#
# Why: several Claude Code sessions run at once (several folders, several
# tasks), and names like "do beads" in the /resume picker, in claude.ai/code
# (Remote Control) and in the terminal title do not say which is which.
#
# How Claude Code names a session (2.1.301, read from the binary): the
# visible title is the NEWEST title record in the session transcript --
# {"type":"ai-title","aiTitle":...} (its own model call on the first prompt)
# or {"type":"custom-title","customTitle":...} (/rename, --name, or a hook).
# A UserPromptSubmit hook may print
#   {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"..."}}
# to set the title, so this hook looks at the title the session has now and,
# when it does not already start with "<project>: ", prints one that does.
#
# Usage: session-title            (hook JSON on stdin: transcript_path, cwd,
#                                  prompt; nothing else is read)
#
# Project name: $CLAUDE_ORCA_PROJECT_NAME, else basename of $PROJECT_DIR,
# else basename of the git toplevel of the hook's cwd, else basename of cwd.
# Task: the current title if the session has one, else the prompt's first
# non-blank line, whitespace collapsed, cut at a word boundary to <= 50
# chars. Control characters are stripped; the whole title is <= 80 chars.
# Nothing is printed when the current title already starts with
# "<project>: " (or is exactly <project>).
#
# Speed: the transcript can be tens of MB, so it is never parsed whole --
# grep -F finds the title records, tail keeps the newest, and only that one
# line goes through jq.
#
# Exit codes: always 0. A hook must never block a prompt; a missing jq, a
# missing or unreadable transcript, or garbage on stdin just means no output
# (or a title built from the prompt alone). Prints nothing but the JSON.

set -u
exec 2>/dev/null

[ -t 0 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
[ -n "$input" ] || exit 0

# transcript_path and cwd, one per line.
fields="$(printf '%s' "$input" | jq -r '(.transcript_path // ""), (.cwd // "")')"
transcript="$(printf '%s\n' "$fields" | sed -n 1p)"
cwd="$(printf '%s\n' "$fields" | sed -n 2p)"

project="${CLAUDE_ORCA_PROJECT_NAME:-}"
if [ -z "$project" ] && [ -n "${PROJECT_DIR:-}" ]; then
    project="$(basename "$PROJECT_DIR")"
fi
if [ -z "$project" ] && [ -n "$cwd" ] && [ -d "$cwd" ]; then
    top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$top" ]; then
        project="$(basename "$top")"
    else
        project="$(basename "$cwd")"
    fi
fi
[ -n "$project" ] || exit 0

# The newest title record, or nothing. LC_ALL=C: bytes, not characters --
# the fastest grep, and a title record is found the same either way.
rec=""
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
    rec="$(LC_ALL=C grep -F -e '{"type":"ai-title"' -e '{"type":"custom-title"' "$transcript" | tail -n 1)"
fi

printf '%s' "$input" | jq -c --arg project "$project" --arg rec "$rec" '
  # Control characters and every whitespace run become one space; trim.
  def clean:
    if type != "string" then ""
    else explode
         | map(if . < 32 or . == 127 or (. >= 128 and . <= 159) then 32 else . end)
         | implode
         | gsub("[ \u00a0]+"; " ") | sub("^ "; "") | sub(" $"; "")
    end;
  # At most $n characters, backed up to a word boundary when that leaves
  # something; a single over-long word is cut hard.
  def cut($n):
    if length <= $n then .
    else .[0:$n] as $h
         | (if .[$n:$n+1] == " " then $h else ($h | sub(" [^ ]*$"; "")) end) as $c
         | (if ($c | length) > 0 then $c else $h end) | sub(" +$"; "")
    end;
  ($project | clean) as $p
  | ($rec | try fromjson catch null) as $r
  | (if ($r | type) == "object" then
       (if $r.type == "ai-title" then $r.aiTitle
        elif $r.type == "custom-title" then $r.customTitle
        else null end)
     else null end | clean) as $cur
  | if $p == "" or $cur == $p or ($cur | startswith($p + ": ")) then empty
    else
      (if $cur != "" then $cur
       else ((.prompt // "") | tostring | split("\n") | map(clean)
             | map(select(length > 0)) | (.[0] // "") | cut(50))
       end) as $task
      | (if $task == "" then $p else $p + ": " + $task end | cut(80)) as $title
      | {hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: $title}}
    end'

exit 0
