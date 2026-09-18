#!/usr/bin/env bats
# branch-guard.bats — the branch discipline a prose rule alone couldn't hold
# (claude-orca-yd9): this template is solo development on main, so a
# PreToolUse (Bash) hook denies branch creation, branch switching and
# worktree-add unless the command is prefixed BRANCH_OK=1. Same payload
# shape as tests/outbound-guard.bats: jq -n builds the hook JSON, `run`
# feeds it to the guard on stdin, status is 0 and the output is either
# empty (allow) or the hookSpecificOutput deny JSON. Like every hook here
# it MUST fail open: malformed/empty stdin, a non-Bash tool, a payload
# without a command — all silent exit 0, never a block.

REPO=${BRANCH_GUARD_REPO:-"$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"}
GUARD=${BRANCH_GUARD_BIN:-"$REPO/scripts/branch-guard.sh"}

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    PAYLOAD="$BATS_TEST_TMPDIR/payload.json"
}

# run_pretool <command> [cwd] — Bash tool payload, optional .cwd key;
# sets $status/$output.
run_pretool() {
    local cmd="$1" cwd="${2:-}"
    jq -n --arg c "$cmd" --arg cwd "$cwd" \
        '{tool_name:"Bash", session_id:"s1", tool_input:{command:$c}}
         + (if $cwd == "" then {} else {cwd:$cwd} end)' > "$PAYLOAD"
    run bash -c '"$0" < "$1"' "$GUARD" "$PAYLOAD"
}

# run_pretool_tool <command> <tool_name> — payload naming another tool.
run_pretool_tool() {
    jq -n --arg c "$1" --arg t "$2" \
        '{tool_name:$t, session_id:"s1", tool_input:{command:$c}}' > "$PAYLOAD"
    run bash -c '"$0" < "$1"' "$GUARD" "$PAYLOAD"
}

# run_raw <text> — raw bytes (or nothing) on the guard's stdin.
run_raw() {
    run bash -c 'printf "%s" "$1" | "$0"' "$GUARD" "$2"
}

# run_no_command — valid Bash payload whose tool_input has no command.
run_no_command() {
    jq -n '{tool_name:"Bash", session_id:"s1", tool_input:{}}' > "$PAYLOAD"
    run bash -c '"$0" < "$1"' "$GUARD" "$PAYLOAD"
}

deny_reason() {
    printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason'
}

assert_deny() {
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null
}

assert_allow() {
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# make_repo — a real git repo with branches main and feature; sets $REPO_DIR.
make_repo() {
    REPO_DIR="$BATS_TEST_TMPDIR/repo"
    git init -q -b main "$REPO_DIR"
    git -C "$REPO_DIR" config user.email t@example.com
    git -C "$REPO_DIR" config user.name tester
    printf 'a\n' > "$REPO_DIR/a.txt"
    git -C "$REPO_DIR" add a.txt
    git -C "$REPO_DIR" commit -qm one
    git -C "$REPO_DIR" branch feature
}

@test "denies git checkout -b, checkout -B, switch -c, switch -C and switch --create" {
    run_pretool 'git checkout -b feat'
    assert_deny
    run_pretool 'git checkout -B feat'
    assert_deny
    run_pretool 'git switch -c feat'
    assert_deny
    run_pretool 'git switch -C feat'
    assert_deny
    run_pretool 'git switch --create feat'
    assert_deny
}

@test "denies git worktree add" {
    run_pretool 'git worktree add ../wt main'
    assert_deny
    run_pretool 'cd /somewhere && git worktree add ../wt'
    assert_deny
    run_pretool 'git worktree list'
    assert_allow
    run_pretool 'git worktree remove ../wt'
    assert_allow
    run_pretool 'git worktree prune'
    assert_allow
}

@test "denies git branch <newname> but allows the list, delete, merged and show-current forms" {
    run_pretool 'git branch newbr'
    assert_deny
    run_pretool 'git status && git branch newbr'
    assert_deny
    for c in 'git branch' \
             'git branch -d oldbr' 'git branch -D oldbr' \
             'git branch -m old new' 'git branch -M old new' \
             'git branch -c src dst' 'git branch -C src dst' \
             'git branch -a' 'git branch -r' 'git branch -l' \
             'git branch -v' 'git branch -vv' \
             'git branch --list x' 'git branch --merged' \
             'git branch --no-merged' 'git branch --contains HEAD' \
             'git branch --show-current' 'git branch --format=%(refname)'; do
        run_pretool "$c"
        assert_allow
    done
}

@test "denies git switch <branch> other than main, master and dash" {
    run_pretool 'git switch feature'
    assert_deny
    run_pretool 'git switch other'
    assert_deny
    run_pretool 'git switch -'
    assert_allow
    run_pretool 'git switch main'
    assert_allow
    run_pretool 'git switch master'
    assert_allow
}

@test "denies git checkout <existing-branch> in the payload's cwd but allows checkout of a path, of -- path, of HEAD~1 -- path and of a word that is not a branch" {
    make_repo
    run_pretool 'git checkout feature' "$REPO_DIR"
    assert_deny
    run_pretool 'git checkout a.txt' "$REPO_DIR"
    assert_allow
    run_pretool 'git checkout -- a.txt' "$REPO_DIR"
    assert_allow
    run_pretool 'git checkout HEAD~1 -- a.txt' "$REPO_DIR"
    assert_allow
    local sha
    sha=$(git -C "$REPO_DIR" rev-parse HEAD)
    run_pretool "git checkout $sha -- a.txt" "$REPO_DIR"
    assert_allow
    run_pretool 'git checkout notabranchword' "$REPO_DIR"
    assert_allow
}

@test "allows git checkout main and git switch main" {
    run_pretool 'git checkout main'
    assert_allow
    run_pretool 'git switch main'
    assert_allow
    run_pretool 'git checkout master'
    assert_allow
    run_pretool 'git switch master'
    assert_allow
}

@test "denies a branch creation chained after cd && or inside a command substitution" {
    run_pretool 'cd /tmp && git switch -c feat'
    assert_deny
    run_pretool 'echo $(git checkout -b feat)'
    assert_deny
    run_pretool 'git status; git worktree add ../w main'
    assert_deny
    run_pretool 'true | git switch -C feat'
    assert_deny
}

@test "allows anything prefixed BRANCH_OK=1" {
    run_pretool 'BRANCH_OK=1 git switch -c feat'
    assert_allow
    run_pretool 'BRANCH_OK=1 git checkout -b feat'
    assert_allow
    run_pretool 'BRANCH_OK=1 git branch newbr'
    assert_allow
    run_pretool 'BRANCH_OK=1 git worktree add ../w main'
    assert_allow
    run_pretool 'BRANCH_OK=1 git switch otherbr'
    assert_allow
}

@test "the deny reason names main, BRANCH_OK=1 and merging back" {
    run_pretool 'git switch -c feat'
    assert_deny
    local reason
    reason=$(deny_reason)
    [[ "$reason" == *"main"* ]]
    [[ "$reason" == *"BRANCH_OK=1"* ]]
    [[ "$reason" == *"merge"* ]]
}

@test "exits 0 with no output on a tty, empty stdin, non-JSON, a non-Bash tool and a payload without a command" {
    run script -qec "$GUARD" /dev/null
    assert_allow
    run_raw ""
    assert_allow
    run_raw "not json at all"
    assert_allow
    run_pretool_tool 'git switch -c feat' 'Read'
    assert_allow
    run_no_command
    assert_allow
}
