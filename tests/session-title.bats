#!/usr/bin/env bats
# Guards:   every Claude Code session title starts with the project ("<project>: <task>"),
#           so several sessions are told apart in /resume, claude.ai/code and the terminal title
# Fails if: the hook prints nothing for an un-prefixed title, prefixes twice, lets a long or
#           multi-line prompt through as a title, or the settings / .zshrc stop wiring it
# Run:      bats tests/session-title.bats

# scripts/session-title.sh is a UserPromptSubmit hook. It reads the hook JSON on
# stdin, finds the session's newest title record in the transcript, and prints
# {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"<project>: <task>"}}
# unless the title already starts with "<project>: ". Every case below runs the
# script against fixtures under $BATS_TEST_TMPDIR; the shell running the suite
# carries CLAUDE_ORCA_PROJECT_NAME and PROJECT_DIR, so setup() replaces both.

ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
HOOK="$ROOT/scripts/session-title.sh"
SETTINGS="$ROOT/config/claude-settings.json"
ZSH_BIN="/usr/bin/z""sh"

setup() {
    FIX="$BATS_TEST_TMPDIR"
    mkdir -p "$FIX/proj-demo" "$FIX/home"
    export HOME="$FIX/home"
    unset CLAUDE_ORCA_PROJECT_NAME
    export PROJECT_DIR="$FIX/proj-demo"
    TR="$FIX/transcript.jsonl"
}

# title_rec ai|custom <title>: one transcript line, shaped like Claude Code writes it.
title_rec() {
    if [ "$1" = ai ]; then
        jq -cn --arg t "$2" '{type:"ai-title",aiTitle:$t,sessionId:"s1"}'
    else
        jq -cn --arg t "$2" '{type:"custom-title",customTitle:$t,sessionId:"s1"}'
    fi
}

# run_hook <prompt> [transcript]: feed the hook JSON on stdin; stdout in $output.
run_hook() {
    jq -cn --arg p "$1" --arg t "${2:-$TR}" --arg c "$PROJECT_DIR" \
        '{session_id:"s1",hook_event_name:"UserPromptSubmit",transcript_path:$t,cwd:$c,prompt:$p}' > "$FIX/in.json"
    run bash "$HOOK" < "$FIX/in.json"
    [ "$status" -eq 0 ]
}

# the sessionTitle in $output ("" when nothing was printed)
title_of() { printf '%s' "$output" | jq -r '.hookSpecificOutput.sessionTitle // empty'; }

@test "session-title: no title yet -> '<project>: <prompt>'" {
    : > "$TR"
    run_hook "do beads"
    [ "$(title_of)" = "proj-demo: do beads" ]
}

@test "session-title: an ai-title without the prefix is re-issued with it" {
    title_rec ai "Fix login bug" > "$TR"
    run_hook "anything"
    [ "$(title_of)" = "proj-demo: Fix login bug" ]
}

@test "session-title: a newest title that already starts '<project>: ' prints nothing" {
    { title_rec ai "Old name"; title_rec custom "proj-demo: x"; } > "$TR"
    run_hook "next prompt"
    [ -z "$output" ]
}

@test "session-title: a title that is exactly the project prints nothing" {
    title_rec custom "proj-demo" > "$TR"
    run_hook "next prompt"
    [ -z "$output" ]
}

@test "session-title: an ai-title newer than our custom-title, lacking the prefix, is re-prefixed" {
    { title_rec custom "proj-demo: do beads"; title_rec ai "Greeting exchange"; } > "$TR"
    run_hook "next prompt"
    [ "$(title_of)" = "proj-demo: Greeting exchange" ]
}

@test "session-title: a long multi-line prompt with control chars becomes one short line cut at a word" {
    : > "$TR"
    p="$(printf 'first\tline\001 has   some words that keep going well past the fifty char limit\nsecond line\r\nthird')"
    run_hook "$p"
    t="$(title_of)"
    [ "${#t}" -le 80 ]
    case "$t" in *[[:cntrl:]]*) false ;; esac
    [ "$t" = "proj-demo: first line has some words that keep going well" ]
}

@test "session-title: the whole title stays within 80 chars even for a long project and one huge word" {
    export CLAUDE_ORCA_PROJECT_NAME="a-very-long-project-name-that-takes-up-thirty-chars"
    : > "$TR"
    run_hook "$(printf 'x%.0s' $(seq 1 200))"
    t="$(title_of)"
    [ "${#t}" -le 80 ]
    [ "${t#"$CLAUDE_ORCA_PROJECT_NAME: x"}" != "$t" ]
}

@test "session-title: CLAUDE_ORCA_PROJECT_NAME beats the PROJECT_DIR basename" {
    export CLAUDE_ORCA_PROJECT_NAME="named-proj"
    : > "$TR"
    run_hook "hello"
    [ "$(title_of)" = "named-proj: hello" ]
}

@test "session-title: with no PROJECT_DIR the project is the git toplevel of the hook's cwd" {
    unset PROJECT_DIR
    mkdir -p "$FIX/repo-x/sub"
    git -C "$FIX/repo-x" init -q
    jq -cn --arg c "$FIX/repo-x/sub" '{transcript_path:"",cwd:$c,prompt:"hi there"}' > "$FIX/in.json"
    run bash "$HOOK" < "$FIX/in.json"
    [ "$status" -eq 0 ]
    [ "$(title_of)" = "repo-x: hi there" ]
}

@test "session-title: a missing transcript still gives a prompt-based title and exits 0" {
    run_hook "do beads" "$FIX/no-such-transcript.jsonl"
    [ "$(title_of)" = "proj-demo: do beads" ]
}

@test "session-title: an empty prompt and no title gives just the project" {
    : > "$TR"
    run_hook ""
    [ "$(title_of)" = "proj-demo" ]
}

@test "session-title: the output is one JSON object naming the UserPromptSubmit event" {
    : > "$TR"
    run_hook "do beads"
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit" and (.hookSpecificOutput.sessionTitle | type == "string") and (keys == ["hookSpecificOutput"])'
}

@test "session-title: garbage or empty stdin exits 0 and prints nothing" {
    run bash "$HOOK" <<< 'not json at all'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run bash "$HOOK" < /dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "session-title: wired last under UserPromptSubmit in config/claude-settings.json, with bin/session-title linked" {
    run jq -e '[.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("template/bin/session-title"))] | length == 1' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ -L "$ROOT/bin/session-title" ]
    [ -x "$ROOT/scripts/session-title.sh" ]
    [ "$(readlink "$ROOT/bin/session-title")" = "../scripts/session-title.sh" ]
}

# --- config/.zshrc: Remote Control names sessions after this prefix. The real
# Z shell sources a copy of the file, then prints the variable.

zsh_prefix() {  # zsh_prefix [VAR=value ...]; prints the exported prefix
    cp "$ROOT/config/.zshrc" "$FIX/home/.zshrc"
    env -i PATH="$PATH" HOME="$FIX/home" "$@" \
        "$ZSH_BIN" -f -c 'source "$HOME/.zshrc" >/dev/null 2>&1; printf %s "$CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX"'
}

@test ".zshrc exports CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX from CLAUDE_ORCA_PROJECT_NAME, else the PROJECT_DIR basename" {
    [ -x "$ZSH_BIN" ] || skip "no zsh on this box"
    run zsh_prefix PROJECT_DIR="$FIX/proj-demo" CLAUDE_ORCA_PROJECT_NAME=named-proj
    [ "$output" = "named-proj" ]
    run zsh_prefix PROJECT_DIR="$FIX/proj-demo"
    [ "$output" = "proj-demo" ]
    run zsh_prefix
    [ -z "$output" ]
}
