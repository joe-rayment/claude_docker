#!/usr/bin/env bash
# prime-memories — SessionStart/PreCompact hook: bd's persistent memories,
# budgeted, and nothing else.
#
# `bd prime` (no flags) also injects a compiled-in workflow rulebook: a
# session-close checklist ("git push … NEVER skip this. Work is not done
# until pushed"), "Create beads issue BEFORE writing code", a "Write tests
# for X" separate-bead example, "use parallel subagents" to file issues.
# The only place any of that gets contradicted is this repo's own
# CLAUDE.md, which never ships to a user project — config/claude-user-
# memory.md does. `bd prime --memories-only` drops all of it and prints
# only the memories (verified: zero hits for "git push", "BEFORE writing
# code", "Write tests for", "parallel subagents", "SESSION CLOSE" in its
# output — see tests/prime-hook.bats). This wrapper is that flag, plus a
# byte budget: memories are Claude-written and unbounded, and can grow
# past the rulebook they replaced, so whole memories print in bd's own
# order (the order bd prime --memories-only itself prints them in) until
# PRIME_MEMORY_BUDGET bytes is spent, and whatever didn't fit is named
# instead of silently dropped or truncated mid-sentence.
#
# PRIME_MEMORY_BUDGET overrides the byte budget applied to the memories
# themselves (default 8000). The shared preamble bd prints above them
# (banner + section header + explanation) is not counted against it — it
# always prints in full. Invalid or unset falls back to the default.
#
# MUST fail open: bd absent, bd erroring, or genuinely zero memories all
# mean "print bd's own output (or nothing) and exit 0" — never a non-zero
# exit, never blocking a session.

set -u

command -v bd >/dev/null 2>&1 || exit 0

budget="${PRIME_MEMORY_BUDGET:-8000}"
case "$budget" in
    ''|*[!0-9]*) budget=8000 ;;
esac

raw=$(bd prime --memories-only 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || exit 0
[ -n "$raw" ] || exit 0

printf '%s\n' "$raw" | LC_ALL=C awk -v budget="$budget" '
# bd prime --memories-only formats each memory as its own "### <key>"
# heading followed by the stored text, with a blank separator line before
# the next heading (or EOF). Everything before the first heading — the
# "[bd prime] ..." banner, the "## Persistent Memories (N)" section
# title, and the explanation paragraph — is the shared preamble: it
# always prints in full and is never counted against the budget, only
# the memory blocks themselves are.
/^### / {
    n++
    keys[n] = substr($0, 5)
    blocks[n] = $0 "\n"
    inblock = 1
    next
}
{
    if (inblock) {
        blocks[n] = blocks[n] $0 "\n"
    } else {
        preamble = preamble $0 "\n"
    }
}
END {
    printf "%s", preamble
    spent = 0
    stop = 0
    omitted_n = 0
    for (i = 1; i <= n; i++) {
        len = length(blocks[i])
        if (!stop && spent + len <= budget) {
            printf "%s", blocks[i]
            spent += len
        } else {
            # Budget spent: this block and every remaining one (regardless
            # of its own size) is omitted, never truncated — a whole
            # memory either fits or it does not print at all.
            stop = 1
            omitted_n++
            omitted[omitted_n] = keys[i]
        }
    }
    if (omitted_n > 0) {
        line = "[prime-memories] omitted " omitted_n " over budget ("
        for (i = 1; i <= omitted_n; i++) {
            line = line omitted[i]
            if (i < omitted_n) line = line ", "
        }
        line = line ") -- see: bd memories <keyword>"
        print line
    }
}
'
exit 0
