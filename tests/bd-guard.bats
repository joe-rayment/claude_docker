#!/usr/bin/env bats

# bd-guard — PreToolUse(Bash) hook that keeps beads Claude-only.
# Tests run the repo script directly (not the baked /usr/local/bin copy).

# The script under test is overridable so the suite can be pointed at the OLD
# script (e.g. `BD_GUARD_BIN=/tmp/old.sh bats …`) to prove the new adversarial
# tests actually fail against it — i.e. they are not defanged.
GUARD=${BD_GUARD_BIN:-/workspace/scripts/bd-guard.sh}

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    unset BD_GUARD_ALLOW
}

# run_guard <command-string>; sets $status / $output (stderr). The command
# string may contain tabs/leading whitespace — passed verbatim through jq.
run_guard() {
    run bash -c 'jq -n --arg c "$1" "{tool_input:{command:\$c}}" | '"$GUARD"' 2>&1' _ "$1"
}

@test "bd-guard: human assignee on create is hard-blocked" {
    run_guard 'bd create "Fix parser" -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: human assignee via --assignee= and bd assign is blocked" {
    run_guard 'bd update wp9 --assignee=Joe'
    [ "$status" -eq 2 ]
    run_guard 'bd assign wp9 joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: hard rule ignores BD_GUARD_ALLOW override" {
    export BD_GUARD_ALLOW=1
    run bash -c 'jq -n --arg c "bd create x -a joe" "{tool_input:{command:\$c}}" | BD_GUARD_ALLOW=1 '"$GUARD"' 2>&1'
    [ "$status" -eq 2 ]
}

@test "bd-guard: agent assignees and claim pass" {
    run_guard 'bd create "Fix parser" --assignee claude'
    [ "$status" -eq 0 ]
    run_guard 'bd update wp9 --claim'
    [ "$status" -eq 0 ]
    run_guard 'bd assign wp9 ""'
    [ "$status" -eq 0 ]
}

@test "bd-guard: user-directed close reason is soft-blocked" {
    run_guard 'bd close wp9 --reason "Done except push; Joe should run gh auth login and push the branch"'
    [ "$status" -eq 2 ]
    run_guard 'bd close wp9 --reason "Fixed the parser and verified via take-screenshot term"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: close reason discharging residual work in prose is blocked" {
    run_guard 'bd close vrv --reason "All subtasks done; the sole residual step is git push, auth-blocked, carried outside the tracker"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"follow-up bead"* ]]
    run_guard 'bd close wp9 --reason "Closing per user direction. NOT verified in-container until rebuild"'
    [ "$status" -eq 2 ]
}

@test "bd-guard: close reason naming a follow-up bead passes" {
    run_guard 'bd close vrv --reason "Done; residual step (git push) filed as bead bd-x9 which Claude will run after auth is restored"'
    [ "$status" -eq 0 ]
    run_guard 'bd create "Track the remaining work items in the sprint board UI"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: user-directed bead text is soft-blocked with chat redirect" {
    run_guard 'bd create "Ask the user which DB to use"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"ask it in your reply NOW"* ]]
    run_guard 'bd create "Migrate" -d "waiting for user approval"'
    [ "$status" -eq 2 ]
    run_guard 'bd update wp9 --notes "blocked on Joe deciding the region"'
    [ "$status" -eq 2 ]
}

@test "bd-guard: ordinary feature language about users passes" {
    run_guard 'bd create "Sanitize user input in the login form"'
    [ "$status" -eq 0 ]
    run_guard 'bd create "Allow the user to upload avatars"'
    [ "$status" -eq 0 ]
    run_guard 'bd create "Add user review feature to the store page"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: BD_GUARD_ALLOW=1 overrides soft rule only" {
    run bash -c 'jq -n --arg c "bd create \"Fix the ask-the-user detection\"" "{tool_input:{command:\$c}}" | BD_GUARD_ALLOW=1 '"$GUARD"' 2>&1'
    [ "$status" -eq 0 ]
}

@test "bd-guard: non-bd commands and empty input pass untouched" {
    run_guard 'git commit -m "ask the user later"'
    [ "$status" -eq 0 ]
    run_guard 'echo bd create'
    [ "$status" -eq 0 ]
    run bash -c "printf '' | $GUARD"
    [ "$status" -eq 0 ]
}

# --- Bypass resistance: hard rule must fire despite obfuscated prefixes -------

@test "bd-guard: env-assignment prefix does not hide a human assignee" {
    run_guard 'BEADS_ACTOR=claude bd create "x" -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: leading whitespace does not hide a human assignee" {
    run_guard '  bd create "x" -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: wrapper words (command/builtin/env/nohup/time) do not hide it" {
    for w in command builtin env nohup time; do
        run_guard "$w bd create \"x\" -a joe"
        [ "$status" -eq 2 ] || { echo "wrapper '$w' bypassed"; false; }
    done
}

@test "bd-guard: tab separators do not hide bd verb or assignee flags" {
    run_guard "$(printf 'bd\tcreate "x" -a joe')"
    [ "$status" -eq 2 ]
    run_guard "$(printf 'bd create "x" -a\tjoe')"
    [ "$status" -eq 2 ]
    run_guard "$(printf 'bd create "x" --assignee\tjoe')"
    [ "$status" -eq 2 ]
}

@test "bd-guard: stacked whitespace+env+wrapper+tab combo still blocks" {
    run_guard "$(printf '  FOO=1 command bd\tcreate "x" -a\tjoe')"
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: bd assign behind a wrapper word still extracts the assignee" {
    run_guard 'command bd assign wp9 joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: soft rule fires through an obfuscating prefix" {
    run_guard 'BEADS_ACTOR=claude bd create "Ask the user which DB to use"'
    [ "$status" -eq 2 ]
    run_guard 'command bd create -d "waiting for user approval"'
    [ "$status" -eq 2 ]
}

# --- Working BD_GUARD_ALLOW override (literal command prefix) -----------------

@test "bd-guard: literal BD_GUARD_ALLOW=1 command prefix overrides soft rule" {
    run_guard 'BD_GUARD_ALLOW=1 bd create "Ask the user which DB to use"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: literal BD_GUARD_ALLOW=1 prefix does NOT override hard rule" {
    run_guard 'BD_GUARD_ALLOW=1 bd create "x" -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

# --- P2 false positives that must be ALLOWED ---------------------------------

@test "bd-guard: feature text 'assigned to the user' is not a violation" {
    run_guard 'bd create "Show tasks assigned to the user on their dashboard"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: close reasons describing done feature/doc work pass" {
    run_guard 'bd close wp9 --reason "Removed the unverified-email warning banner"'
    [ "$status" -eq 0 ]
    run_guard 'bd close wp9 --reason "Documented remaining work items in the roadmap"'
    [ "$status" -eq 0 ]
    run_guard 'bd close wp9 --reason "Guarded so the form is not pushed twice"'
    [ "$status" -eq 0 ]
}

# --- Hard rule: all three -a short-flag spellings extract the assignee --------

@test "bd-guard: -a=joe (equals-glued short flag) is blocked" {
    run_guard 'bd create x -a=joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: -ajoe (value-glued short flag) is blocked" {
    run_guard 'bd create x -ajoe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: -a short-flag anchoring does not misfire on --all or --claim" {
    run_guard 'bd create x --all'
    [ "$status" -eq 0 ]
    run_guard 'bd update wp9 --claim'
    [ "$status" -eq 0 ]
    run_guard 'bd create x -aclaude'
    [ "$status" -eq 0 ]
}

# --- Soft rule: unverified boundary restored for closing quote/punctuation ----

@test "bd-guard: 'unverified' followed by quote or punctuation blocks a close" {
    run_guard 'bd close wp9 --reason "left unverified"'
    [ "$status" -eq 2 ]
    run_guard 'bd close wp9 --reason "deployed unverified."'
    [ "$status" -eq 2 ]
    # ...but the hyphenated feature term stays allowed.
    run_guard 'bd close wp9 --reason "Removed the unverified-email warning banner"'
    [ "$status" -eq 0 ]
}

# --- Override: only a genuine command-prefix assignment unlocks the soft rule -

@test "bd-guard: trailing BD_GUARD_ALLOW=1 comment does NOT unlock the soft rule" {
    run_guard 'bd create "Ask the user which DB" # BD_GUARD_ALLOW=1'
    [ "$status" -eq 2 ]
}

@test "bd-guard: BD_GUARD_ALLOW=1 after an env-assignment chain still unlocks" {
    run_guard 'FOO=1 BD_GUARD_ALLOW=1 bd create "Ask the user which DB"'
    [ "$status" -eq 0 ]
}

# --- Optional: brace-group command position is caught ------------------------

@test "bd-guard: bd inside a { ...; } brace group is caught" {
    run_guard '{ bd create x -a joe; }'
    [ "$status" -eq 2 ]
}

# --- Hard rule: the reserved 'human' label routes a bead to a person ----------
# (beads_claude_docker-v5p: bd human list surfaces "issues with 'human' label"
# to a person -- attaching it is an assignee in disguise.)

@test "bd-guard: 'human' label via --labels/-l/--add-label/--set-labels is hard-blocked" {
    run_guard 'bd create "Pick a region" --labels human'
    [ "$status" -eq 2 ]
    [[ "$output" == *"'human' label"* ]]
    run_guard 'bd create "x" --labels bug,human,urgent'
    [ "$status" -eq 2 ]
    run_guard 'bd update wp9 --add-label human'
    [ "$status" -eq 2 ]
    run_guard 'bd update wp9 -l human'
    [ "$status" -eq 2 ]
    run_guard 'bd update wp9 --set-labels human'
    [ "$status" -eq 2 ]
}

@test "bd-guard: 'human' label via bd tag / bd label add is hard-blocked" {
    run_guard 'bd tag bd-42 human'
    [ "$status" -eq 2 ]
    [[ "$output" == *"'human' label"* ]]
    run_guard 'bd label add bd-42 human'
    [ "$status" -eq 2 ]
    run_guard 'bd label add bd-42 bd-43 human'
    [ "$status" -eq 2 ]
}

@test "bd-guard: human-label hard rule ignores BD_GUARD_ALLOW override" {
    run bash -c 'jq -n --arg c "bd tag bd-42 human" "{tool_input:{command:\$c}}" | BD_GUARD_ALLOW=1 '"$GUARD"' 2>&1'
    [ "$status" -eq 2 ]
    [[ "$output" == *"'human' label"* ]]
}

@test "bd-guard: ordinary labels and un-flagging (--remove-label human) pass" {
    run_guard 'bd create x --labels bug,urgent'
    [ "$status" -eq 0 ]
    run_guard 'bd tag bd-42 needs-review'
    [ "$status" -eq 0 ]
    run_guard 'bd update wp9 --remove-label human'
    [ "$status" -eq 0 ]
    run_guard 'bd create x --all'
    [ "$status" -eq 0 ]
}

# --- Hard rule: 'bd gate create' defaulting to (or set to) a human gate -------
# (bd gate create --blocks <id> defaults --type to "human", which requires
# manual 'bd gate resolve' -- a blocked-on-a-person dependency, same severity
# as a human assignee.)

@test "bd-guard: 'bd gate create' with no --type (defaults to human) is hard-blocked" {
    run_guard 'bd gate create --blocks bd-42'
    [ "$status" -eq 2 ]
    [[ "$output" == *"only a person can close"* ]]
}

@test "bd-guard: 'bd gate create --type=human' (explicit, both spellings) is hard-blocked" {
    run_guard 'bd gate create --type=human --blocks bd-42 --reason "Need design review"'
    [ "$status" -eq 2 ]
    run_guard 'bd gate create -t human --blocks bd-42'
    [ "$status" -eq 2 ]
}

@test "bd-guard: 'bd gate create' with an automated type passes" {
    run_guard 'bd gate create --type=timer --blocks bd-42 --timeout=2h'
    [ "$status" -eq 0 ]
    run_guard 'bd gate create --type=gh:run --blocks bd-42 --await-id=42'
    [ "$status" -eq 0 ]
    run_guard 'bd gate create --type=gh:pr --blocks bd-42 --await-id=42'
    [ "$status" -eq 0 ]
}

@test "bd-guard: gate hard rule ignores BD_GUARD_ALLOW override" {
    run bash -c 'jq -n --arg c "bd gate create --blocks bd-42" "{tool_input:{command:\$c}}" | BD_GUARD_ALLOW=1 '"$GUARD"' 2>&1'
    [ "$status" -eq 2 ]
}

@test "bd-guard: non-create gate subcommands (list/resolve) pass untouched" {
    run_guard 'bd gate list'
    [ "$status" -eq 0 ]
    run_guard 'bd gate resolve bd-42'
    [ "$status" -eq 0 ]
}

# --- 'bd dep add' cannot express a human dependency and stays unguarded -------
# (Every value bd dep add accepts is an issue ID or external:<project>:<cap>
# reference, never a person -- deliberately not added to the guarded verb
# list. Confirmed by reading 'bd dep add --help'.)

@test "bd-guard: 'bd dep add' is not a bd-guard verb and passes through" {
    run_guard 'bd dep add bd-42 bd-41'
    [ "$status" -eq 0 ]
    run_guard 'bd dep add bd-42 --blocked-by bd-41'
    [ "$status" -eq 0 ]
}

# ============================================================================
# Shell-wrapper / file-indirection evasions (beads_claude_docker-vgr)
#
# bd-guard is a string matcher: bash -c "PAYLOAD" / eval "PAYLOAD" hide `bd`
# behind a quote character, never at the `;&|(){` command position every rule
# above anchors on. scan_cmd (scripts/bd-guard.sh) extracts the payload and
# RECURSES the same rule engine on it (bounded by MAX_UNWRAP_DEPTH=5), rather
# than duplicating rule logic against a second grammar. Full scope table with
# rationale is in the bead and the executor's report; short form (updated in
# round 3 -- see the CORRECTION block below this one for what changed):
#   bash/sh/zsh/dash/ash/ksh -c "PAYLOAD" (+ path-prefixed,
#     + path-prefixed `env sh -c "..."`)                -> BLOCKED (recurse)
#   eval "PAYLOAD" / eval 'PAYLOAD' / eval PAYLOAD     -> BLOCKED (recurse)
#   nested wrapping (bash -c "eval '...'")             -> BLOCKED (cascades)
#   echo x | xargs bd create -a joe (bare xargs)       -> BLOCKED (strip-word)
#   timeout/stdbuf/setsid/nice/ionice/script/chrt/
#     taskset wrapping bd, with or without their own
#     flag/duration argument                            -> BLOCKED (strip-word)
#   \bd / 'bd' / "bd" (backslash-escaped or self-quoted) -> BLOCKED (normalize)
#   xargs own flags / stdin-substituted value           -> OUT-OF-SCOPE
#   printf "bd ..." | sh (payload as interpreter STDIN) -> OUT-OF-SCOPE
#   --body-file/--design-file/-f/--graph/--stdin        -> OUT-OF-SCOPE
#   nesting deeper than MAX_UNWRAP_DEPTH                -> OUT-OF-SCOPE (bounded)
#   stdin-fed payloads (bash <<<, echo|bash, bash -s,
#     source /dev/stdin)                                 -> OUT-OF-SCOPE (pinned)
#   single-quote concatenation truncation                -> OUT-OF-SCOPE (pinned)
#   command substitution ($(...) in a -c payload or a
#     VAR=$(...) assignment)                              -> OUT-OF-SCOPE (pinned)
#   variable indirection (B=bd; $B create ...)            -> OUT-OF-SCOPE (pinned)
#
# CORRECTION (beads_claude_docker-vgr round 2): the "bash -c/sh -c/zsh -c
# 'PAYLOAD' -> BLOCKED (recurse)" line above, stated with NO qualification,
# was FALSE for several real, verifier-confirmed shapes -- all fixed in this
# round, all covered by the new tests below:
#   - a flag between the interpreter word and -c (`bash -x -c "..."`,
#     `bash -c -x "..."`, `bash --norc -c "..."`) was not recognized at all
#     -- the candidate regex required the literal token `-c` immediately
#     after the interpreter word.
#   - a COMBINED short-flag cluster (`bash -lc "..."`, `-ec`) was likewise
#     not recognized for the same reason.
#   - an ESCAPED inner double-quote in the payload (`bash -c "bd create x -d
#     \"n\" -a joe"`) silently TRUNCATED the captured payload at the escape,
#     dropping everything after it (including the actual violation) from
#     recursion entirely -- `"[^"]*"` has no escape awareness.
#   - a DECOY quoted string ending in the same "interpreter -flags-
#     open-quote" header as a real wrapper later in the same command
#     (`echo "; bash -c " ; bash -c "bd gate create --blocks bd-1"`) let
#     grep -oE's leftmost, non-overlapping match consume THROUGH the real
#     wrapper's own opening quote, so the real payload was never found as an
#     independent candidate at all.
# All four are now closed (flag-cluster + escape-aware capture; iterative
# "unswallow" retry for the decoy case, gated on a header/full-match count
# mismatch so the common no-wrapper or cleanly-non-overlapping case pays
# nothing extra). A companion bug in `bd tag`'s label extraction (grabbed
# only the FIRST token after the id, silently ignoring a violation planted
# further along, e.g. `bd tag bd-1 "x" human`) was fixed alongside since the
# escape-aware capture alone wasn't sufficient to close that specific
# reported bypass. Total-work is additionally bounded independently of
# MAX_UNWRAP_DEPTH by MAX_SCAN_NODES (scripts/bd-guard.sh) -- depth alone
# does not bound the O(branch^depth) cost of several wrapper candidates at
# several levels; see the perf tests below.
#
# CORRECTION (bd-guard hardening slice, round 3): an independent check found
# four more accidental-shape gaps -- plain typos an agent could plausibly
# make, not the contrived multi-decoy constructions the round-2 bounds
# guard against -- plus one unrelated perf hole in the same audit:
#   - leading wrapper words outside the original short list (`timeout 10 bd
#     create x -a joe`, `nice bd create x -a joe`, `stdbuf -o0`/`ionice -c3`
#     wrapping bd) were not stripped at all -- ALLOWED.
#   - `bd` itself disguised by a no-op backslash-escape or self-quoting
#     (`\bd create x -a joe`, `'bd' create x -a joe`, `"bd" create x -a
#     joe`) never matched the literal `bd` anchors -- ALLOWED.
#   - the interpreter-detection alternation only recognized `bash|sh|zsh`,
#     required a BARE (non-path) `env` to already be stripped by the
#     wrapper-word pass, and required every flag-cluster token to start
#     with `-` -- so `/usr/bin/env sh -c "..."` (path-prefixed env),
#     `dash -c "..."` (dash IS /bin/sh in this image), and `bash -O extglob
#     -c "..."` (a flag cluster with a non-dash option ARGUMENT) all slipped
#     through -- ALLOWED.
#   - separately, the per-candidate wrapper-extraction loops (the `head=
#     $(sed ...); grep -qF ...` containment check run once per raw regex
#     match) spawned a `sed`+`grep` pair PER CANDIDATE before SCAN_NODE_COUNT
#     ever got a chance to bound anything, since recursion (where the
#     counter increments) only happens AFTER that whole loop finishes --
#     8000 sibling candidates in one command measured ~50s wall clock.
# All four are fixed: the wrapper-word strip loop gained an atomic
# word+optional-flag-cluster+optional-numeric-suffix alternative for
# timeout/stdbuf/setsid/nice/ionice/script/chrt/taskset (positive character
# classes only, so it can never itself match the literal token `bd` the way
# a truly generic "strip any leading word" rule could -- deliberately
# rejected for exactly that reason, see scripts/bd-guard.sh); a
# backslash/quote-`bd` normalization step in the same fixed-point loop;
# `dash|ash|ksh` added to the interpreter alternation, a path-prefixed
# `env` accepted ahead of the interpreter word, and the flag-cluster token
# widened to any non-whitespace/separator/quote/`<`/`>` run (the `<`/`>`
# exclusion specifically preserves the stdin-fed `bash <<< "..."` pin below
# -- without it, `<<<` would itself match as a cluster token and turn a
# documented OUT-OF-SCOPE case into a false block); and a
# MAX_WRAPPER_CANDIDATES cap piped in between each `grep -oE` extraction and
# its per-candidate filter loop (a plain `head -n`, not a counter threaded
# through the loop -- the loop runs inside a piped subshell, where writes to
# a script-global counter would be silently lost the moment that subshell
# exits). None of this closes stdin-fed payloads, single-quote
# concatenation, command substitution, or variable indirection -- see KNOWN
# LIMITATIONS in scripts/bd-guard.sh's header and the OUT-OF-SCOPE (pinned)
# tests below for those, and why they're accepted rather than fixed.
# ============================================================================

# --- BLOCKED: bash -c / sh -c / zsh -c with the payload in a quoted string ---

@test "bd-guard: bash -c \"PAYLOAD\" (double-quoted) with a human assignee is blocked" {
    run_guard 'bash -c "bd create x -a joe"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: sh -c and zsh -c with a single-quoted payload are blocked" {
    run_guard "sh -c 'bd create x -a joe'"
    [ "$status" -eq 2 ]
    run_guard "zsh -c 'bd create x -a joe'"
    [ "$status" -eq 2 ]
}

@test "bd-guard: a path-prefixed wrapper (/bin/sh -c, /usr/bin/env-style bash -c) is blocked" {
    run_guard '/bin/sh -c "bd create x -a joe"'
    [ "$status" -eq 2 ]
    run_guard '/usr/bin/bash -c "bd create x -a joe"'
    [ "$status" -eq 2 ]
}

@test "bd-guard: bash -c with a benign payload (no violation) still passes" {
    run_guard 'bash -c "bd create \"x\" --assignee claude"'
    [ "$status" -eq 0 ]
}

# --- BLOCKED: eval with the payload in a quoted string, and bare eval --------

@test "bd-guard: eval \"PAYLOAD\" (double-quoted) with a human assignee is blocked" {
    run_guard 'eval "bd create x -a joe"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: eval 'PAYLOAD' (single-quoted) with a human assignee is blocked" {
    run_guard "eval 'bd create x -a joe'"
    [ "$status" -eq 2 ]
}

@test "bd-guard: bare eval PAYLOAD (unquoted) with a human assignee is blocked" {
    run_guard 'eval bd create x -a joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: eval with a benign payload (no violation) still passes" {
    run_guard 'eval "bd create x --assignee claude"'
    [ "$status" -eq 0 ]
}

# --- BLOCKED: nested/double wrapping ------------------------------------------

@test "bd-guard: nested wrapping bash -c \"eval '...'\" is blocked" {
    run_guard 'bash -c "eval '"'"'bd create x -a joe'"'"'"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: nested wrapping through the human-label and soft rules also fires" {
    run_guard 'bash -c "bd tag bd-42 human"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"'human' label"* ]]
    run_guard 'bash -c "bd create '"'"'Ask the user which DB to use'"'"'"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"ask it in your reply NOW"* ]]
}

# --- BLOCKED: bare xargs passes its own argv straight through ----------------

@test "bd-guard: echo x | xargs bd create -a joe (bare xargs) is blocked" {
    run_guard 'echo x | xargs bd create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

# --- BD_GUARD_ALLOW propagation through a wrapper (soft rule only) -----------

@test "bd-guard: outer BD_GUARD_ALLOW=1 prefix unlocks a soft rule INSIDE a wrapper" {
    run_guard 'BD_GUARD_ALLOW=1 bash -c "bd create '"'"'Ask the user which DB to use'"'"'"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: outer BD_GUARD_ALLOW=1 prefix does NOT unlock a hard rule inside a wrapper" {
    run_guard 'BD_GUARD_ALLOW=1 bash -c "bd create x -a joe"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

# --- Depth bound: recursion terminates instead of spinning -------------------
# Chained bare `eval` (no quoting needed, so this isn't an artifact of quote-
# nesting limits) -- each layer costs exactly one recursion to strip. 5 layers
# is within MAX_UNWRAP_DEPTH (5) and fully unwraps; 6 exceeds it and the
# violation past the bound is never reached -- documents the bound exists and
# fails open (allow), never blocks, when it's hit.
@test "bd-guard: wrapper nesting within the depth bound (5 eval layers) is blocked" {
    run_guard 'eval eval eval eval eval bd create x -a joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: wrapper nesting beyond the depth bound (6 eval layers) is allowed" {
    run_guard 'eval eval eval eval eval eval bd create x -a joe'
    [ "$status" -eq 0 ]
}

# --- Fail-open under a broken environment, now that wrapper-unwrap adds ------
# --- new grep/sed calls (bead acceptance #2: env -i, missing jq) -------------

@test "bd-guard: env -i (fully stripped environment) still blocks a real violation" {
    run env -i PATH="$PATH" bash -c 'jq -n --arg c "bd create x -a joe" "{tool_input:{command:\$c}}" | '"$GUARD"' 2>&1'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: jq unresolvable on PATH fails open (allow) instead of crashing" {
    # Build the input JSON FIRST, while jq is still on the normal PATH. The
    # old version of this test prefixed PATH=/nonexistent onto the jq call
    # that BUILDS the input -- so jq itself never ran, the guard received
    # EMPTY stdin, and the observed exit 0 came from the (separately tested,
    # above) empty-stdin path, never from the guard's own missing-jq
    # handling at bd-guard.sh:202 at all. This version restricts PATH only
    # around the GUARD's own invocation, after the real input already exists.
    local input="$BATS_TEST_TMPDIR/input.json"
    jq -n --arg c 'bd create x -a joe' '{tool_input:{command:$c}}' > "$input"

    # A PATH shim with everything the guard needs to run its rule engine
    # EXCEPT jq: bash (the #!/usr/bin/env bash shebang resolves it via
    # PATH -- /usr/bin/env itself is invoked by the absolute path baked into
    # the shebang, but env then does its own PATH lookup for "bash"), plus
    # sh/grep/sed/head/tr/cat, which scan_cmd's rule engine calls. This
    # makes the test self-checking in both directions: if jq leaked into the
    # shim, the real violation in the payload would reach the assignee rule
    # and exit 2 (test fails); if the shim were missing something else the
    # guard needs (e.g. bash itself), the process would fail to start rather
    # than exit 0 (test fails). Exit 0 here can only come from the guard's
    # own missing-jq fail-open.
    local shim="$BATS_TEST_TMPDIR/shim"
    mkdir -p "$shim"
    local tool
    for tool in bash sh grep sed head tr cat; do
        ln -s "$(command -v "$tool")" "$shim/$tool"
    done

    run bash -c 'PATH="$1" "$2" < "$3"' _ "$shim" "$GUARD" "$input"
    [ "$status" -eq 0 ]
}

# --- OUT-OF-SCOPE (documented, pinned): xargs' own flags / stdin-substituted -
# --- values are not parsed -- the value is never textually present ----------

@test "OUT-OF-SCOPE (pinned): xargs -I{} substituting a piped-in value is not caught" {
    run_guard 'echo joe | xargs -I{} bd create x -a {}'
    [ "$status" -eq 0 ]
}

# --- OUT-OF-SCOPE (documented, pinned): payload as interpreter STDIN data, --
# --- not argv -- printf/echo/cat piped into sh/bash. The text is technically
# --- present in the command string, but treating "anything piped into an
# --- interpreter" as unwrappable is the sandbox line this fix does not cross
# --- (the bead's DESIGN section: "without pretending to be a sandbox").
@test "OUT-OF-SCOPE (pinned): printf PAYLOAD | sh (stdin data, not argv) is not caught" {
    run_guard 'printf %s "bd create x -a joe" | sh'
    [ "$status" -eq 0 ]
}

# --- OUT-OF-SCOPE (documented, pinned): file indirection ---------------------
# --body-file/--design-file read the description/design from a file;
# -f/--graph batch-create issues (including assignee/labels) from a
# markdown/JSON file. Declared out of scope rather than half-covered:
#   - format mismatch: detecting an assignee/human-label INSIDE the file
#     needs a markdown/JSON issue-format parser (the "Assignee:" key /
#     --graph node fields), not a reuse of this shell-token rule engine --
#     a materially different, second rule engine, not "recurse the existing
#     scan".
#   - TOCTOU: the file may not exist yet at hook time, or its content may
#     change between the hook's read and bd's own read.
#   - --stdin (alias for --body-file -) is unscannable even in principle --
#     the hook has no access to the run's future stdin stream.
#   - new file-I/O fail-open surface (size, encoding, symlinks, permissions)
#     disproportionate to this slice.
@test "OUT-OF-SCOPE (pinned): --body-file pointing at a file with a human assignee is not caught" {
    f="$BATS_TEST_TMPDIR/body.md"
    printf 'Assignee: joe\nPlease review and decide.\n' > "$f"
    run_guard "bd create x --body-file $f"
    [ "$status" -eq 0 ]
}

@test "OUT-OF-SCOPE (pinned): --design-file / -f pointing at a file with a violation is not caught" {
    f="$BATS_TEST_TMPDIR/design.md"
    printf 'ask the user which region to deploy to\n' > "$f"
    run_guard "bd create x --design-file $f"
    [ "$status" -eq 0 ]
    g="$BATS_TEST_TMPDIR/batch.md"
    printf '## Issue\nAssignee: joe\n' > "$g"
    run_guard "bd create -f $g"
    [ "$status" -eq 0 ]
}

# ============================================================================
# Quote-aware masking (beads_claude_docker-vgr, closing slice)
#
# The scanner above was not quote-aware: it read prose INSIDE a quoted flag
# value as if it were real command syntax, so filing a bead whose own text
# quoted a prohibited flag (e.g. -d "example: bd create x -a joe") HARD-
# BLOCKED, with no override -- the bead's unmet acceptance criterion. The
# same gap let a wrapper-shaped example inside such a value (-d "... (bash -c
# '...') ..." ) get extracted as if it were a real wrapper.
#
# scripts/bd-guard.sh now computes masked_cmd: the CONTENT of quoted values
# of -d/--description, --title, --notes, --design, --acceptance, -r/--reason
# is blanked (quote characters kept, interior emptied) before every
# STRUCTURAL rule (assignee, labels, gate --type, bare `bd human`, segments,
# wrapper-candidate filtering) -- never before the prose soft rules, which
# must keep reading exactly that text (that IS their job). Bare -t is
# deliberately NOT masked: confirmed against bd 1.0.4 (`bd create --help` /
# `bd gate create --help`) that -t is ALWAYS --type, never a --title short
# form (--title has none) -- masking it would let a quoted `-t "human"` slip
# the gate rule.
# ============================================================================

# --- The unmet acceptance: a prohibited flag quoted in -d must be fileable --

@test "bd-guard: a prohibited flag quoted inside -d/--description is DATA, not a violation" {
    run_guard 'bd create "Doc example" -d "example: bd create x -a joe"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: a parenthesized wrapper example quoted inside -d is DATA, not a violation" {
    run_guard 'bd create x -d "example: (bash -c '"'"'bd create x -a joe'"'"')"'
    [ "$status" -eq 0 ]
}

# --- Quote-awareness is not a universal bypass: real syntax still blocks ----

@test "bd-guard: a real bash -c wrapper with a real human assignee still blocks (not a bypass)" {
    run_guard 'bash -c "bd create x -a joe"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: a real -a joe in genuine command position still blocks (not a bypass)" {
    run_guard 'bd create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: masking the prose -a inside -d does not hide a REAL -a alongside it" {
    run_guard 'bd create x -d "example uses -a alice" -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: a genuinely wrapped soft-rule violation still blocks (masking is context-scoped, not payload-eating)" {
    # Regression pin: extracting the bash -c payload from the MASKED string
    # instead of the raw one would blank this real wrapper's own -d value
    # before recursion ever saw "ask Joe to decide" -- silently turning a
    # today-blocks case into an allow. The wrapper-candidate filter keeps
    # the raw (unmasked) payload for recursion and uses masked_cmd only to
    # decide whether the match is a genuine wrapper at all.
    run_guard 'bash -c "bd create x -d '"'"'ask Joe to decide'"'"'"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"ask it in your reply NOW"* ]]
}

# --- Same root cause, other hard rules (gate/human/label), fixed alongside --

@test "bd-guard: a 'bd gate create' example quoted inside -d is DATA, not a second invocation" {
    run_guard 'bd create x -d "example: bd gate create --blocks bd-1"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: a bare 'bd human <id>' example quoted inside -d is DATA, not a violation" {
    run_guard 'bd create x -d "example: bd human bd-1"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: a human-label example quoted inside -d (tag / --labels) is DATA, not a violation" {
    run_guard 'bd create x -d "example: bd tag bd-1 human"'
    [ "$status" -eq 0 ]
    run_guard 'bd create x -d "example: bd create x --labels human"'
    [ "$status" -eq 0 ]
}

# --- The rest of the masked-field list: --title, --notes, --design, --------
# --- --acceptance, -r/--reason (gate create's free-text field) -------------

@test "bd-guard: a prohibited flag quoted inside --title is DATA, not a violation" {
    run_guard 'bd create x --title "example: bd create x -a joe"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: a prohibited flag quoted inside --notes is DATA, not a violation" {
    run_guard 'bd create x --notes "example: bd create x -a joe"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: a prohibited flag quoted inside --design / --acceptance is DATA, not a violation" {
    run_guard 'bd create x --design "example: bd create x -a joe"'
    [ "$status" -eq 0 ]
    run_guard 'bd create x --acceptance "example: bd create x -a joe"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: a prohibited flag quoted inside gate create's -r/--reason is DATA, not a violation" {
    run_guard 'bd gate create --blocks bd-42 --type=timer -r "example: bd create x -a joe"'
    [ "$status" -eq 0 ]
    run_guard 'bd gate create --blocks bd-42 --type=timer --reason "example: bd create x -a joe"'
    [ "$status" -eq 0 ]
}

# --- Bare -t is deliberately NOT masked: it is always --type, never --title -

@test "bd-guard: bare -t is never treated as free text -- a quoted gate type is still read as real" {
    run_guard 'bd gate create -t "human" --blocks bd-42'
    [ "$status" -eq 2 ]
    [[ "$output" == *"only a person can close"* ]]
}

# --- Unbalanced/odd quoting: fails open, never crashes ----------------------

@test "bd-guard: an unterminated quote in -d with no violation fails open (allowed, no crash)" {
    run_guard 'bd create x -d "this never closes'
    [ "$status" -eq 0 ]
}

@test "bd-guard: an unterminated quote in -d that DOES contain a real-looking flag stays blocked (conservative, documented direction)" {
    # Masking requires a matching close quote and simply doesn't fire here --
    # the text falls back to the pre-quote-aware scan instead of a bespoke
    # "give up and allow" path, so this can only ever move toward blocking,
    # never toward a new bypass. An unterminated command couldn't run as
    # intended in a real shell anyway, so the block is harmless.
    run_guard 'bd create x -d "oops -a joe'
    [ "$status" -eq 2 ]
}

# ============================================================================
# Round 2: verifier-found bypasses in the wrapper-candidate extraction and
# the tag-label extraction (beads_claude_docker-vgr closing slice, round 2)
#
# All six of these were CONFIRMED LIVE (exit 0 = allowed) against the round-1
# script despite all round-1 tests passing. See the CORRECTION note above the
# shell-wrapper section for the four distinct root causes and the fixes.
# ============================================================================

# --- Flag between the interpreter word and -c, either order, or combined ----

@test "bd-guard: bash -x -c \"PAYLOAD\" (flag BEFORE -c) is blocked" {
    run_guard 'bash -x -c "bd gate create --blocks bd-1"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"only a person can close"* ]]
}

@test "bd-guard: bash -c -x \"PAYLOAD\" (flag AFTER -c) is blocked" {
    # Confirmed empirically against real bash first (bash -c -x "echo hi"
    # DOES execute "echo hi", with xtrace on) -- bash's own option parser
    # does not require -c to be positionally last, so neither does this.
    run_guard 'bash -c -x "bd gate create --blocks bd-1"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"only a person can close"* ]]
}

@test "bd-guard: bash -lc \"PAYLOAD\" (combined short-flag cluster) is blocked" {
    run_guard 'bash -lc "bd create x -a joe"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: bash --norc -c \"PAYLOAD\" (long flag before -c) is blocked" {
    run_guard 'bash --norc -c "bd create x -a joe"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: a flag cluster with no violation still passes (no new false positive)" {
    run_guard 'bash -x -c "bd create x --assignee claude"'
    [ "$status" -eq 0 ]
}

# --- Escaped inner double-quote no longer truncates the captured payload ----

@test "bd-guard: bash -c with an escaped inner quote before the real violation is blocked" {
    run_guard 'bash -c "bd create x -d \"n\" -a joe"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: eval \"PAYLOAD\" with an escaped inner quote before the real violation is blocked" {
    run_guard 'eval "bd create x -d \"n\" -a joe"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: bd tag behind a wrapper with an escaped inner quote is blocked (tag extraction, not just escaping)" {
    # Two stacked root causes: the escape-truncation bug above, AND bd
    # tag's own extraction grabbing only the FIRST token after the id
    # ("x") and silently ignoring "human" two tokens further along.
    run_guard 'bash -c "bd tag bd-1 \"x\" human"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"'human' label"* ]]
}

@test "bd-guard: sh -c with an escaped inner quote in a labels list is blocked" {
    run_guard 'sh -c "bd create x --labels \"a\",human"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"'human' label"* ]]
}

# --- bd tag: every token after the id is checked, not just the first -------

@test "bd-guard: bd tag with a violation planted past the first token is blocked (direct, no wrapper)" {
    run_guard 'bd tag bd-1 "x" human'
    [ "$status" -eq 2 ]
    [[ "$output" == *"'human' label"* ]]
}

@test "bd-guard: bd tag with a single genuine label still passes (no new false positive)" {
    run_guard 'bd tag bd-1 needs-review'
    [ "$status" -eq 0 ]
}

# --- Decoy quoted string swallowing a later real wrapper's opening quote ---

@test "bd-guard: a decoy quoted 'bash -c \"' header does not swallow a real wrapper later in the command" {
    run_guard 'echo "; bash -c " ; bash -c "bd gate create --blocks bd-1"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"only a person can close"* ]]
}

@test "bd-guard: the same command without the decoy (control) still blocks" {
    run_guard 'echo hi ; bash -c "bd gate create --blocks bd-1"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"only a person can close"* ]]
}

@test "bd-guard: an actual decoy-shaped string with no real wrapper after it still passes" {
    run_guard 'echo "; bash -c " ; echo done'
    [ "$status" -eq 0 ]
}

@test "bd-guard: several genuinely separate sibling wrappers (no swallowing) all still work" {
    run_guard 'bash -c "bd create a --assignee claude" ; bash -c "bd create b -a joe" ; bash -c "bd create c --assignee claude"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

# --- Total-work node budget: bounds cost independently of unwrap depth -----
# (MAX_SCAN_NODES in scripts/bd-guard.sh; see the bead for the O(branch^depth)
# construction that made the unbounded version take double-digit seconds.)

@test "bd-guard: a wide-but-shallow branching command still terminates correctly" {
    # Two levels of real nesting, several siblings per level, all benign --
    # a correctness control (no false positive from ordinary nested
    # wrapping), NOT proof the node budget itself did anything: at ~13
    # scan_cmd calls this stays far under MAX_SCAN_NODES (200), so it would
    # pass identically with the budget at 1, at 200, or removed outright.
    # The "a violation planted past the budget is not found" pin -- the
    # actual bound-not-promise property, mirroring the depth/unswallow/
    # candidate-cap tests elsewhere in this file -- is the next test.
    local inner='bash -c "bd create x --assignee claude" ; bash -c "bd create x --assignee claude" ; bash -c "bd create x --assignee claude"'
    local mid="bash -c '$inner' ; bash -c '$inner' ; bash -c '$inner'"
    run_guard "$mid"
    [ "$status" -eq 0 ]
}

@test "bd-guard: a violation planted past MAX_SCAN_NODES fails open -- documented bound" {
    # Mirrors the MAX_UNWRAP_DEPTH / MAX_UNSWALLOW_ITERS / MAX_WRAPPER_
    # CANDIDATES bound-not-promise tests elsewhere in this file: MAX_SCAN_
    # NODES was the only one of the four bounds with no "a violation planted
    # beyond the bound is not found" pin -- the wide-but-shallow test above
    # is a correctness control only (see its comment), never a proof the
    # 200-node cap does anything, since it plants no violation for a budget
    # to hide. 60 mid-level wrappers x 4 inner wrappers each = 1 (root) + 60
    # (mids) + 240 (inners) = 301 scan_cmd calls, comfortably over the
    # 200-node cap (exhausted partway through the 40th mid); each level
    # stays well under MAX_WRAPPER_CANDIDATES (64) so this exercises the
    # node budget specifically, not the candidate cap. The real violation
    # sits in the very LAST inner wrapper of the very LAST mid wrapper,
    # reached only after the budget is already spent -- fail-open, never
    # itself a block reason, same contract as every other bound in this
    # file.
    local benign_inner='bash -c "bd create x --assignee claude"'
    local benign_mid="$benign_inner ; $benign_inner ; $benign_inner ; $benign_inner"
    local last_mid="$benign_inner ; $benign_inner ; $benign_inner ; bash -c \"bd create x -a joe\""
    local mids=""
    local i
    for i in $(seq 1 59); do mids="${mids}bash -c '${benign_mid}' ; "; done
    mids="${mids}bash -c '${last_mid}'"
    run_guard "$mids"
    [ "$status" -eq 0 ]
}

# --- Own adversarial follow-up: the SAME decoy-swallow trick via eval ------
# (found during this round's own required adversarial pass, AFTER the
# bash/sh/zsh -c fix above -- eval "PAYLOAD" was not covered by the first
# pass of the unswallow fix, only bash/sh/zsh -c was, even though it goes
# through the identical grep -oE leftmost-match mechanism.)

@test "bd-guard: a decoy quoted 'eval \"' header does not swallow a real eval wrapper later in the command" {
    run_guard 'echo "; eval " ; eval "bd gate create --blocks bd-1"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"only a person can close"* ]]
}

# --- MAX_UNSWALLOW_ITERS: a bound, not a promise -- same pattern as the -----
# --- MAX_UNWRAP_DEPTH tests above (own adversarial follow-up: chaining -----
# --- decoys is a second way to run past a fixed iteration count) -----------
# Recovering a real payload behind N chained decoys costs N+1 iterations of
# the unswallow retry (scripts/bd-guard.sh); MAX_UNSWALLOW_ITERS=10 means up
# to 9 chained decoys are still fully unswallowed, and 10 or more exceed the
# bound -- fail-open (allowed), never itself a block reason, exactly like
# running past MAX_UNWRAP_DEPTH.

@test "bd-guard: 9 chained decoys (within MAX_UNSWALLOW_ITERS) still blocks" {
    decoys=""
    for i in 1 2 3 4 5 6 7 8 9; do decoys="$decoys"'echo "; bash -c " ; '; done
    run_guard "${decoys}bash -c \"bd gate create --blocks bd-1\""
    [ "$status" -eq 2 ]
    [[ "$output" == *"only a person can close"* ]]
}

@test "bd-guard: 10 chained decoys (beyond MAX_UNSWALLOW_ITERS) is allowed -- documented bound" {
    decoys=""
    for i in 1 2 3 4 5 6 7 8 9 10; do decoys="$decoys"'echo "; bash -c " ; '; done
    run_guard "${decoys}bash -c \"bd gate create --blocks bd-1\""
    [ "$status" -eq 0 ]
}

@test "bd-guard: eval with a benign payload after a decoy-shaped string still passes" {
    run_guard 'echo "; eval " ; echo done'
    [ "$status" -eq 0 ]
}

# ============================================================================
# Round 3 hardening (bd-guard hardening slice): leading wrapper words beyond
# the original short list, backslash/quote-escaped `bd`, a narrower-than-
# reality interpreter alternation, and unbounded per-candidate extraction
# cost. See the CORRECTION (round 3) block above and scripts/bd-guard.sh's
# KNOWN LIMITATIONS section for the full rationale.
# ============================================================================

# --- Item A: leading wrapper words (timeout/stdbuf/setsid/nice/ionice/ -------
# --- script/chrt/taskset), bare and with their own flag/duration argument ---

@test "bd-guard: timeout N bd ... (bare numeric duration argument) is blocked" {
    run_guard 'timeout 10 bd create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: nice bd ... (bare, no argument) is blocked" {
    run_guard 'nice bd create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: setsid bd ... (bare) is blocked" {
    run_guard 'setsid bd create x -a joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: stdbuf -o0 bd ... (glued flag argument) is blocked" {
    run_guard 'stdbuf -o0 bd create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: ionice -c3 bd ... (glued flag argument) is blocked" {
    run_guard 'ionice -c3 bd create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: nice -n 10 / chrt -f 50 / taskset -c 0 (flag + separate value) are blocked" {
    run_guard 'nice -n 10 bd create x -a joe'
    [ "$status" -eq 2 ]
    run_guard 'chrt -f 50 bd create x -a joe'
    [ "$status" -eq 2 ]
    run_guard 'taskset -c 0 bd create x -a joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: script bd ... (bare) is blocked" {
    run_guard 'script bd create x -a joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: these new wrapper words with a benign payload still pass (no new false positive)" {
    run_guard 'timeout 10 bd create x --assignee claude'
    [ "$status" -eq 0 ]
    run_guard 'stdbuf -o0 bd create x --assignee claude'
    [ "$status" -eq 0 ]
}

@test "bd-guard: xargs -I{} (own flags) stays OUT-OF-SCOPE despite the wider wrapper handling" {
    # Regression pin for the rejected "generic strip any leading word" design:
    # a fully generic rule would strip xargs' OWN -I{} flag the same way it
    # strips a new wrapper word's flag, turning this documented, pinned
    # ALLOW into a false block. The word+arg grammar added in this round is
    # scoped to exactly the 8 new words, never to xargs.
    run_guard 'echo joe | xargs -I{} bd create x -a {}'
    [ "$status" -eq 0 ]
}

# --- Item B: backslash-escaped or self-quoted `bd` --------------------------

@test "bd-guard: backslash-escaped \\\\bd is blocked (shell no-op escape)" {
    run_guard '\bd create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: single-quoted 'bd' is blocked (self-quoting is a shell no-op)" {
    run_guard "'bd' create x -a joe"
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: double-quoted \"bd\" is blocked (self-quoting is a shell no-op)" {
    run_guard '"bd" create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: escaped/quoted bd composes with a leading wrapper word" {
    run_guard 'command \bd create x -a joe'
    [ "$status" -eq 2 ]
    run_guard "env 'bd' create x -a joe"
    [ "$status" -eq 2 ]
}

@test "bd-guard: escaped/quoted bd example quoted inside -d stays DATA, not a violation" {
    # \bd / 'bd' / "bd" normalization is scoped to genuine command position
    # (start of string or right after a separator) -- text after -d "..." is
    # neither, so this must stay masked/allowed exactly like the existing
    # quote-aware-masking tests above.
    run_guard 'bd create x -d "example: \bd create x -a joe"'
    [ "$status" -eq 0 ]
}

# --- Item C: interpreter alternation -- path-prefixed env, dash/ash/ksh, ----
# --- flag cluster with a non-dash option argument ---------------------------

@test "bd-guard: /usr/bin/env sh -c \"PAYLOAD\" (path-prefixed env) is blocked" {
    run_guard '/usr/bin/env sh -c "bd create x -a joe"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: dash -c / ash -c / ksh -c are blocked (dash is /bin/sh in this image)" {
    run_guard "dash -c 'bd create x -a joe'"
    [ "$status" -eq 2 ]
    run_guard "ash -c 'bd create x -a joe'"
    [ "$status" -eq 2 ]
    run_guard "ksh -c 'bd create x -a joe'"
    [ "$status" -eq 2 ]
}

@test "bd-guard: bash -O extglob -c \"PAYLOAD\" (flag cluster with a non-dash option argument) is blocked" {
    run_guard 'bash -O extglob -c "bd create x -a joe"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: the widened interpreter alternation with a benign payload still passes" {
    run_guard '/usr/bin/env sh -c "bd create x --assignee claude"'
    [ "$status" -eq 0 ]
    run_guard 'bash -O extglob -c "bd create x --assignee claude"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: bare env sh -c (no path) still works (unaffected by the path-prefixed addition)" {
    run_guard 'env sh -c "bd create x -a joe"'
    [ "$status" -eq 2 ]
}

# --- Item D: per-candidate extraction cost is bounded independently of ------
# --- SCAN_NODE_COUNT (MAX_WRAPPER_CANDIDATES) --------------------------------

@test "bd-guard: several hundred sibling wrapper candidates still terminate correctly" {
    # Exceeds MAX_WRAPPER_CANDIDATES (64): exercises the head-n cap directly,
    # not just the (already-tested) SCAN_NODE_COUNT recursion bound. The real
    # violation sits in the FIRST candidate, so this also proves the cap
    # doesn't throw away the very candidates a real command would care about.
    local siblings="bash -c \"bd create x -a joe\" ; "
    local i
    for i in $(seq 1 300); do siblings="${siblings}bash -c \"bd create x --assignee claude\" ; "; done
    run_guard "$siblings"
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: sibling candidates beyond MAX_WRAPPER_CANDIDATES fail open -- documented bound" {
    # Mirrors the MAX_UNWRAP_DEPTH / MAX_UNSWALLOW_ITERS bound-not-promise
    # tests above: a violation planted well past the cap is not found via
    # this path. Fail-open, never itself a block reason.
    local siblings=""
    local i
    for i in $(seq 1 100); do siblings="${siblings}bash -c \"bd create x --assignee claude\" ; "; done
    siblings="${siblings}bash -c \"bd create x -a joe\" ; "
    for i in $(seq 1 100); do siblings="${siblings}bash -c \"bd create x --assignee claude\" ; "; done
    run_guard "$siblings"
    [ "$status" -eq 0 ]
}

# ============================================================================
# OUT-OF-SCOPE (pinned): residual argv-wrapper classes named in KNOWN
# LIMITATIONS (scripts/bd-guard.sh header) and the round-3 CORRECTION block
# above. Each requires deliberately constructing shell syntax specifically to
# hide intent -- not the kind of accidental typo items A-D above cover -- so
# they stay unfixed per this file's threat model. Pinned here so the
# documented non-coverage is mechanically true.
# ============================================================================

@test "OUT-OF-SCOPE (pinned): bash <<< \"PAYLOAD\" (herestring, stdin not argv) is not caught" {
    run_guard 'bash <<< "bd create x -a joe"'
    [ "$status" -eq 0 ]
}

@test "OUT-OF-SCOPE (pinned): echo PAYLOAD | bash (piped stdin, not argv) is not caught" {
    run_guard 'echo "bd create x -a joe" | bash'
    [ "$status" -eq 0 ]
}

@test "OUT-OF-SCOPE (pinned): bash -s <<< \"PAYLOAD\" / echo PAYLOAD | bash -s (explicit stdin mode) is not caught" {
    run_guard 'bash -s <<< "bd create x -a joe"'
    [ "$status" -eq 0 ]
    run_guard 'echo "bd create x -a joe" | bash -s'
    [ "$status" -eq 0 ]
}

@test "OUT-OF-SCOPE (pinned): source /dev/stdin <<< \"PAYLOAD\" is not caught" {
    run_guard 'source /dev/stdin <<< "bd create x -a joe"'
    [ "$status" -eq 0 ]
}

@test "OUT-OF-SCOPE (pinned): single-quote concatenation truncates the captured payload" {
    # bash -c 'bd create x -d '\''n'\'' -a joe' -- real bash concatenates the
    # three quoted segments into one argv word (`bd create x -d 'n' -a
    # joe`); this hook's payload regex has no such grammar and stops at the
    # first embedded quote boundary, silently dropping "-a joe" from
    # recursion before the real violation is ever seen.
    run_guard "bash -c 'bd create x -d '\\''n'\\'' -a joe'"
    [ "$status" -eq 0 ]
}

@test "OUT-OF-SCOPE (pinned): command substitution in a -c payload is not caught" {
    # sh -c "$(echo bd create x -a joe)" -- a real shell evaluates $(...)
    # BEFORE -c ever sees the result; this hook recurses on the literal,
    # unevaluated source text, where `bd` is an argument to `echo`, not
    # standing at command position.
    run_guard 'sh -c "$(echo bd create x -a joe)"'
    [ "$status" -eq 0 ]
}

@test "OUT-OF-SCOPE (pinned): command substitution in a VAR=\$(...) assignment is not caught" {
    run_guard 'X=$(bd create x -a joe)'
    [ "$status" -eq 0 ]
}

@test "OUT-OF-SCOPE (pinned): variable indirection (B=bd; \$B ...) is not caught" {
    # The literal command text never contains `bd` immediately followed by a
    # verb (create/update/...) -- the two are split across an assignment and
    # a separate variable reference -- so even the cheap verb-prefilter this
    # hook starts every scan with never engages.
    run_guard 'B=bd; $B create x -a joe'
    [ "$status" -eq 0 ]
}

# =============================================================================
# Hardening round 4 (third independent verifier pass, final round): shell
# reserved words at command position (P0), and wrapper words that take their
# own separate-token arguments beyond the round-3 numeric-only grammar (P1).
# =============================================================================

# --- P0: `bd` after a shell reserved word was invisible to EVERY rule below --
# --- (do/then/else/elif/!, per the reported bypass) --------------------------

@test "bd-guard: for ... do bd update ... done (loop body) is blocked" {
    run_guard 'for i in 1 2; do bd update bd-$i -a joe; done'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: for ... do bd tag ... human ... done is blocked" {
    run_guard 'for i in 1 2; do bd tag bd-$i human; done'
    [ "$status" -eq 2 ]
}

@test "bd-guard: for ... do bd gate create ... done is blocked" {
    run_guard 'for i in 1 2; do bd gate create --blocks bd-$i; done'
    [ "$status" -eq 2 ]
}

@test "bd-guard: for ... do bd human ... done is blocked" {
    run_guard 'for i in 1 2; do bd human bd-$i; done'
    [ "$status" -eq 2 ]
}

@test "bd-guard: if ... then bd create --labels human ... fi is blocked" {
    run_guard 'if true; then bd create x --labels human; fi'
    [ "$status" -eq 2 ]
}

@test "bd-guard: if ... then : ; else bd create ... -a joe ... fi is blocked" {
    run_guard 'if false; then :; else bd create x -a joe; fi'
    [ "$status" -eq 2 ]
}

@test "bd-guard: until ... do bd create ... -a joe ... done is blocked" {
    run_guard 'until false; do bd create x -a joe; done'
    [ "$status" -eq 2 ]
}

@test "bd-guard: if [ ... ]; then bd assign ... joe ... fi is blocked" {
    run_guard 'if [ -f f ]; then bd assign bd-1 joe; fi'
    [ "$status" -eq 2 ]
}

@test "bd-guard: ! bd create ... -a joe (negation) is blocked" {
    run_guard '! bd create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

# --- P0, own self-attack follow-up: `bd` as the CONDITION itself, not just --
# --- the loop/if BODY -- if/while/until directly precede `bd`, not do/then --

@test "bd-guard: if bd update ... -a joe; then ... fi (bd in the condition) is blocked" {
    run_guard 'if bd update bd-1 -a joe; then :; fi'
    [ "$status" -eq 2 ]
}

@test "bd-guard: while bd update ... -a joe; do ... done (bd in the condition) is blocked" {
    run_guard 'while bd update bd-1 -a joe; do :; done'
    [ "$status" -eq 2 ]
}

@test "bd-guard: until bd update ... -a joe; do ... done (bd in the condition) is blocked" {
    run_guard 'until bd update bd-1 -a joe; do :; done'
    [ "$status" -eq 2 ]
}

# --- P0 controls: coverage that already worked before round 4 must still ---

@test "bd-guard: do :; done; bd create ... -a joe (real bd reached via the later ;) still blocks" {
    run_guard 'do :; done; bd create x -a joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: multi-line for/do/bd/done (bd on its own line) still blocks" {
    run_guard 'for i in 1 2
do
  bd update bd-$i -a joe
done'
    [ "$status" -eq 2 ]
}

# --- P0: benign bd now visible inside loop/conditional bodies for the FIRST -
# --- time must NOT become a new false positive ------------------------------

@test "bd-guard: for ... do bd update --claim ... done (benign, no violation) passes" {
    run_guard 'for i in 1 2; do bd update bd-$i --claim; done'
    [ "$status" -eq 0 ]
}

@test "bd-guard: while read ... do bd update --claim ... done (benign) passes" {
    run_guard 'cat ids | while read -r id; do bd update $id --claim; done'
    [ "$status" -eq 0 ]
}

@test "bd-guard: for ... do bd create --assignee claude ... done (benign) passes" {
    run_guard 'for i in 1 2; do bd create "task $i" --assignee claude; done'
    [ "$status" -eq 0 ]
}

@test "bd-guard: for ... do bd close with a clean reason ... done (benign) passes" {
    run_guard 'for i in 1 2; do bd close bd-$i --reason "Fixed and verified via take-screenshot term"; done'
    [ "$status" -eq 0 ]
}

@test "bd-guard: reserved-word stripping inside a masked -d value does not defeat masking" {
    # "do " sits right after a `;` INSIDE the quoted -d value; the keyword
    # strip runs on the pre-mask buffer and removes it, but masked_cmd still
    # blanks the whole quoted span regardless (quote characters untouched),
    # so this must stay exactly as allowed as it was before round 4.
    run_guard 'bd create x -d "step 1; do not use -a joe as in the example" --assignee claude'
    [ "$status" -eq 0 ]
}

@test "bd-guard: a title mentioning ; then bd ... in prose (benign, real assignee is claude) passes" {
    run_guard 'bd create "Fix retry; then bd auto-resumes correctly" --assignee claude'
    [ "$status" -eq 0 ]
}

# --- P1: wrapper words that take their own separate-token arguments ---------
# --- beyond the round-3 "flags-then-one-trailing-number" grammar ------------

@test "bd-guard: timeout -k 5 10 bd ... (flag+value then a second, separate numeric) is blocked" {
    run_guard 'timeout -k 5 10 bd create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: timeout 10 -- bd ... (bare numeric BEFORE a dash token) is blocked" {
    run_guard 'timeout 10 -- bd create x -a joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: env -u FOO bd ... (env's own value-taking flag) is blocked" {
    run_guard 'env -u FOO bd create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: env -i bd ... (env's own bare flag) is blocked" {
    run_guard 'env -i bd create x -a joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: sudo -u agent bd ... (sudo's own value-taking flag) is blocked" {
    run_guard 'sudo -u agent bd create x -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: time -p bd ... (time's only real flag) is blocked" {
    run_guard 'time -p bd create x -a joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: env/sudo/time bare forms and a few more common flags still work, no new FP" {
    run_guard 'env -0 bd create x --assignee claude'
    [ "$status" -eq 0 ]
    run_guard 'sudo -A bd create x --assignee claude'
    [ "$status" -eq 0 ]
    run_guard 'sudo -u agent bd create x --assignee claude'
    [ "$status" -eq 0 ]
    run_guard 'timeout -k 5 10 bd create x --assignee claude'
    [ "$status" -eq 0 ]
}

@test "bd-guard: xargs pins are unaffected by the round-4 wrapper-argument grammar" {
    run_guard 'echo x | xargs bd create x -a joe'
    [ "$status" -eq 2 ]
    run_guard 'echo joe | xargs -I{} bd create x -a {}'
    [ "$status" -eq 0 ]
}

# --- OUT-OF-SCOPE (pinned): intra-word quoting/escaping of `bd` itself ------
# --- -- contrived shapes no agent types by accident, deliberately not fixed -

@test "OUT-OF-SCOPE (pinned): b\\d create ... (backslash INSIDE the word) is not caught" {
    run_guard 'b\d create x -a joe'
    [ "$status" -eq 0 ]
}

@test "OUT-OF-SCOPE (pinned): 'b'd create ... (only half the word quoted) is not caught" {
    run_guard "'b'd create x -a joe"
    [ "$status" -eq 0 ]
}

@test "OUT-OF-SCOPE (pinned): bd'' create ... (empty-string concatenation) is not caught" {
    run_guard "bd'' create x -a joe"
    [ "$status" -eq 0 ]
}

@test "OUT-OF-SCOPE (pinned): bash -c \$'bd create ...' (ANSI-C quoting) is not caught" {
    run_guard $'bash -c $\'bd create x -a joe\''
    [ "$status" -eq 0 ]
}

# --- RESIDUAL (documented, pinned): a flag outside the env/sudo/time arity --
# --- table, or any flag at all for command/builtin/nohup/exec/xargs, -------
# --- still leaves bd hidden -- see KNOWN LIMITATIONS in bd-guard.sh --------

@test "RESIDUAL (pinned): sudo -E --preserve-env=PATH bd ... (long-form-only value flag) is not caught" {
    run_guard 'sudo -E --preserve-env=PATH bd create x -a joe'
    [ "$status" -eq 0 ]
}

@test "RESIDUAL (pinned): env -S '...' bd ... (flag outside the env table) is not caught" {
    run_guard 'env -S "-a joe" bd create x -a joe'
    [ "$status" -eq 0 ]
}

@test "RESIDUAL (pinned): command -p bd ... (command gets no flag grammar at all) is not caught" {
    run_guard 'command -p bd create x -a joe'
    [ "$status" -eq 0 ]
}
