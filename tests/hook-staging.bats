#!/usr/bin/env bats
# hook-staging.bats — ties config/claude-settings.json hook registrations to
# Dockerfile staging, mechanically (parses the real files, no hardcoded
# script list). Regression coverage for the bfa2d70 defect: a hook script
# (delegation-gate) was registered in claude-settings.json and referenced
# with a bare, unguarded absolute path, but never staged by the Dockerfile
# (no COPY, no chmod) — so a freshly built image errored on every matching
# tool call.

CHECK=/workspace/tests/helpers/hook-staging-check.py
DOCKERFILE=/workspace/Dockerfile
SETTINGS=/workspace/config/claude-settings.json

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

# ── current repo state must be clean ────────────────────────────────────────

@test "hook-staging: every hook command in the real repo is guarded and staged" {
    run python3 "$CHECK" "$DOCKERFILE" "$SETTINGS"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── non-vacuity: GUARD check (defect 2) ─────────────────────────────────────

@test "hook-staging: GUARD check fires on a scratch copy reverted to the pre-fix bare path" {
    SCRATCH="$BATS_TEST_TMPDIR/settings-bare.json"
    python3 -c "
import json
with open('$SETTINGS') as fh:
    s = json.load(fh)
for entry in s['hooks']['PreToolUse']:
    for h in entry['hooks']:
        if h.get('command', '').find('delegation-gate') != -1 and 'command -v' in h['command']:
            h['command'] = '/usr/local/bin/delegation-gate'
with open('$SCRATCH', 'w') as fh:
    json.dump(s, fh)
"
    run python3 "$CHECK" "$DOCKERFILE" "$SCRATCH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GUARD_FAIL"* ]]
    [[ "$output" == *"delegation-gate"* ]]
}

@test "hook-staging: GUARD check is silent once the same scratch copy is guarded again" {
    SCRATCH="$BATS_TEST_TMPDIR/settings-guarded.json"
    cp "$SETTINGS" "$SCRATCH"
    run python3 "$CHECK" "$DOCKERFILE" "$SCRATCH"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── non-vacuity: STAGED check (defect 1) ────────────────────────────────────

@test "hook-staging: STAGED check fires on a scratch Dockerfile with the delegation-gate COPY/chmod reverted" {
    SCRATCH="$BATS_TEST_TMPDIR/Dockerfile.unstaged"
    grep -v 'delegation-gate' "$DOCKERFILE" > "$SCRATCH"
    run python3 "$CHECK" "$SCRATCH" "$SETTINGS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"COPY_FAIL"* ]]
    [[ "$output" == *"delegation-gate"* ]]
}

@test "hook-staging: STAGED check is silent once the same scratch Dockerfile keeps the COPY line" {
    SCRATCH="$BATS_TEST_TMPDIR/Dockerfile.staged"
    cp "$DOCKERFILE" "$SCRATCH"
    run python3 "$CHECK" "$SCRATCH" "$SETTINGS"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── generality: a brand new bare/unstaged hook is caught without list edits ─

@test "hook-staging: a newly added bare-name hook invocation is caught generically" {
    SCRATCH="$BATS_TEST_TMPDIR/settings-newhook.json"
    python3 -c "
import json
with open('$SETTINGS') as fh:
    s = json.load(fh)
s['hooks']['PreToolUse'].append({'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'brand-new-script'}]})
with open('$SCRATCH', 'w') as fh:
    json.dump(s, fh)
"
    SCRATCH_DOCKER="$BATS_TEST_TMPDIR/Dockerfile.newhook"
    printf 'FROM scratch\nCOPY --chown=agent:agent scripts/brand-new-script.sh /usr/local/bin/brand-new-script\n' > "$SCRATCH_DOCKER"
    run python3 "$CHECK" "$SCRATCH_DOCKER" "$SCRATCH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GUARD_FAIL"* ]]
    [[ "$output" == *"brand-new-script"* ]]
}

# ── Hole 1: unguarded AND unstaged bare name (the case the above test masks
# by also adding the COPY line) must still be caught, against the real,
# unmodified Dockerfile — no staging at all, not even a scratch one. ────────

@test "hook-staging: an unguarded bare-name hook that is NOT staged anywhere is still caught" {
    SCRATCH="$BATS_TEST_TMPDIR/settings-ghost.json"
    python3 -c "
import json
with open('$SETTINGS') as fh:
    s = json.load(fh)
s['hooks']['PreToolUse'].append({'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'ghost-script'}]})
with open('$SCRATCH', 'w') as fh:
    json.dump(s, fh)
"
    run python3 "$CHECK" "$DOCKERFILE" "$SCRATCH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GUARD_FAIL"* ]]
    [[ "$output" == *"ghost-script"* ]]
}

@test "hook-staging: a guarded, COPY'd, chmod'd new hook produces no false positive" {
    SCRATCH="$BATS_TEST_TMPDIR/settings-goodhook.json"
    python3 -c "
import json
with open('$SETTINGS') as fh:
    s = json.load(fh)
s['hooks']['PreToolUse'].append({'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'command -v new-good-script >/dev/null 2>&1 && exec new-good-script; exit 0'}]})
with open('$SCRATCH', 'w') as fh:
    json.dump(s, fh)
"
    SCRATCH_DOCKER="$BATS_TEST_TMPDIR/Dockerfile.goodhook"
    cat "$DOCKERFILE" > "$SCRATCH_DOCKER"
    # Reuse an already-755-in-git source (scripts/csearch.sh) under a new
    # dest name: exercises COPY without needing a chmod entry too, proving
    # the CHMOD check doesn't false-positive on an already-executable source.
    printf 'COPY --chown=agent:agent scripts/csearch.sh /usr/local/bin/new-good-script\n' >> "$SCRATCH_DOCKER"
    run python3 "$CHECK" "$SCRATCH_DOCKER" "$SCRATCH"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook-staging: existing multi-command hooks (Stop chain, frontmatter grep chain) are not flagged" {
    SCRATCH="$BATS_TEST_TMPDIR/settings-multicmd.json"
    python3 -c "
import json
with open('$SETTINGS') as fh:
    s = json.load(fh)
keep = {'Stop', 'UserPromptSubmit'}
s['hooks'] = {k: v for k, v in s['hooks'].items() if k in keep}
with open('$SCRATCH', 'w') as fh:
    json.dump(s, fh)
"
    run python3 "$CHECK" "$DOCKERFILE" "$SCRATCH"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── Hole 2: a COPY survives but its chmod +x entry is silently dropped for a
# repo file that is 644 (not already executable in git) ─────────────────────

@test "hook-staging: CHMOD check fires when a chmod entry is stripped for a 644 repo script" {
    SCRATCH_DOCKER="$BATS_TEST_TMPDIR/Dockerfile.nochmod"
    # dev-log.sh is 100644 in git; drop only its chmod line, keep its COPY line.
    grep -vF '/usr/local/bin/dev-log \' "$DOCKERFILE" > "$SCRATCH_DOCKER"
    run python3 "$CHECK" "$SCRATCH_DOCKER" "$SETTINGS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"CHMOD_FAIL"* ]]
    [[ "$output" == *"dev-log"* ]]
}

@test "hook-staging: CHMOD check is silent once the same scratch Dockerfile keeps the chmod line" {
    SCRATCH_DOCKER="$BATS_TEST_TMPDIR/Dockerfile.withchmod"
    cp "$DOCKERFILE" "$SCRATCH_DOCKER"
    run python3 "$CHECK" "$SCRATCH_DOCKER" "$SETTINGS"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
