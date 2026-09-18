#!/usr/bin/env bats

# rulebook.bats — beads_claude_docker-bw66 (B3 of the "one rulebook" plan,
# .claude/plans/instruction-surface-fix.md): config/claude-user-memory.md
# is the complete, short behavioural rulebook that ships to every project
# as its CLAUDE.md; enforces the word budget, the seven now-banned
# phrases from the pre-rewrite text, the seven required Appendix A
# headings, and that no '## ' heading is duplicated between this repo's
# own CLAUDE.md and config/claude-user-memory.md — every rule stated
# once, in the file that ships.
#
# S7 port (claude-orca-3sk.7) drops two cases tied to the old template's
# specific CLAUDE.md evolution, which this repo's own CLAUDE.md (a
# beads-workflow doc with its own, independently-authored structure) and
# AGENTS.md (bd's own generated boilerplate, not hand-authored as a
# "pointer to the rulebook") don't share:
#   - the CLAUDE.md '## ' heading whitelist + banned-heading list
#     (beads_claude_docker-b56o) -- pinned to the old template's exact
#     heading set after its own rewrite history, not this repo's.
#   - AGENTS.md's <=200 word budget -- this repo's AGENTS.md is bd's own
#     generated file, not authored under the "tiny pointer" design.
# The remaining word-budget, banned-phrase, required-heading and
# no-overlap cases are unmodified and still the substantive check that a
# rule lives once, in the file that ships.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
USER_MEMORY="$REPO_ROOT/config/claude-user-memory.md"
PLAYBOOK="$REPO_ROOT/knowledge-base/TIERED_ORCHESTRATION.md"

# The seven phrases the pre-rewrite text carried (Opus Answer Protocol,
# the old file-count lane trigger, the old verifier-per-bead phrasing, the
# override-by-name paragraphs, bd's push boilerplate, the environment-
# limitation escape hatch) — none may survive the rewrite in either file.
BANNED_PHRASES=(
    'overrides, by name'
    'physically painful'
    'Work is not done until pushed'
    'verifier` per bead'
    '≥3 files'
    'environment limitation'
    'Opus Answer Protocol'
)

# Appendix A's seven section headings (two are matched as prefixes: the
# shipped headings are "## Push and deploy are the user's actions" and
# "## Delegation — roles, not models").
REQUIRED_HEADINGS=(
    '## Sandbox vs. your systems'
    '## Push and deploy'
    '## Ownership'
    '## Finishing a message'
    '## Beads'
    '## Lanes'
    '## Delegation'
)

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

# The cap moved 1000 -> 1150 in Sept 2026: the message-contract section
# gained the self-contained-question rule and the interim-update/notification
# rule, and § Delegation gained the unnamed-spawn rule -- all three are
# verbatim user text, so the budget moved rather than the words. It moved
# 1150 -> 1300 the same week (claude-orca-rdk): the file had been running
# red at 1327 words on main since the token-diet bead, and the budget
# moves rather than the words, per this file's own precedent.
@test "rulebook: config/claude-user-memory.md is at most 1300 words" {
    local words
    words=$(wc -w < "$USER_MEMORY")
    [ "$words" -le 1300 ]
}

# The cap moved 1700 -> 1900 in Sept 2026 (claude-orca-rdk): the
# Architecture Overview gained the worktree-gc/branch-guard paragraph the
# hook-wiring bead mandates -- the budget moved rather than the words,
# the same call the 1000 -> 1150 move made for verbatim rulebook text.
@test "rulebook: CLAUDE.md is at most 1900 words" {
    local words
    words=$(wc -w < "$CLAUDE_MD")
    [ "$words" -le 1900 ]
}

@test "rulebook: none of the seven banned phrases appear in CLAUDE.md" {
    for phrase in "${BANNED_PHRASES[@]}"; do
        run grep -F -- "$phrase" "$CLAUDE_MD"
        [ "$status" -ne 0 ]
    done
}

@test "rulebook: none of the seven banned phrases appear in config/claude-user-memory.md" {
    for phrase in "${BANNED_PHRASES[@]}"; do
        run grep -F -- "$phrase" "$USER_MEMORY"
        [ "$status" -ne 0 ]
    done
}

@test "rulebook: config/claude-user-memory.md contains all seven required headings" {
    for heading in "${REQUIRED_HEADINGS[@]}"; do
        run grep -F -- "$heading" "$USER_MEMORY"
        [ "$status" -eq 0 ]
    done
}

# claude-orca-qa2.14 (O4): Orca workers replace the in-process Agent tool as
# the DEFAULT executor seat. Both the shipped rulebook and the playbook must
# say so, name the fallback, and carry the parallel-by-default invariant that
# replaces "slices run sequentially, fan-out is for recon".
@test "the playbook and rulebook route executor slices through orca-dispatch when Orca is reachable and the Agent tool otherwise" {
    [ -f "$PLAYBOOK" ]

    # --- the rulebook's own § Delegation (it is the last section) ---
    local deleg
    deleg="$(sed -n '/^## Delegation/,$p' "$USER_MEMORY")"
    [ -n "$deleg" ]

    local phrase
    for phrase in 'orca-dispatch' 'Agent tool' 'reachable' \
                  'checkers and recon stay in-process' \
                  'independent slices run in parallel' \
                  'share files run sequentially' \
                  'recon fans out freely' \
                  'Spawns are unnamed'; do
        case "$deleg" in
            *"$phrase"*) ;;
            *) printf 'rulebook § Delegation missing: %s\n' "$phrase"; return 1 ;;
        esac
    done

    # the retired invariant must be gone from the whole rulebook
    run grep -F -- 'slices run sequentially, fan-out is for recon' "$USER_MEMORY"
    [ "$status" -ne 0 ]

    # --- the playbook: backends, the dispatch loop, parallel, fallback ---
    local heading
    for heading in '^#+ .*Backends' '^#+ .*[Tt]he dispatch loop' \
                   '^#+ .*Parallel by default' '^#+ .*Fallback'; do
        run grep -E -- "$heading" "$PLAYBOOK"
        [ "$status" -eq 0 ] || { printf 'playbook missing heading: %s\n' "$heading"; return 1; }
    done

    # the tools it documents, and the loop's own vocabulary
    for phrase in 'orca-dispatch' 'orca-wait' 'orca-reply' 'orca-workers' \
                  'orca-run' 'worker_done' 'worker-release' 'merge_ready' \
                  'nestedWorkerMaxDepth' 'WORKER RULES'; do
        run grep -F -- "$phrase" "$PLAYBOOK"
        [ "$status" -eq 0 ] || { printf 'playbook missing: %s\n' "$phrase"; return 1; }
    done

    # the fallback rule, including the explicit-model clause
    local fb
    fb="$(sed -n '/^#\+ .*Fallback/,/^#\+ /p' "$PLAYBOOK")"
    for phrase in 'exits 3' 'an explicit `model`'; do
        case "$fb" in
            *"$phrase"*) ;;
            *) printf 'playbook Fallback section missing: %s\n' "$phrase"; return 1 ;;
        esac
    done

    # a mixed Run: one claude worker and one openrouter worker
    run grep -F -- 'claude:sonnet' "$PLAYBOOK"
    [ "$status" -eq 0 ]
    run grep -F -- 'openrouter:qwen/qwen3-coder' "$PLAYBOOK"
    [ "$status" -eq 0 ]
}

@test "rulebook: no '## ' heading text is shared between CLAUDE.md and config/claude-user-memory.md" {
    grep -E '^## ' "$CLAUDE_MD" | sort > "$BATS_TEST_TMPDIR/claude-headings.txt"
    grep -E '^## ' "$USER_MEMORY" | sort > "$BATS_TEST_TMPDIR/memory-headings.txt"
    run comm -12 "$BATS_TEST_TMPDIR/claude-headings.txt" "$BATS_TEST_TMPDIR/memory-headings.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
