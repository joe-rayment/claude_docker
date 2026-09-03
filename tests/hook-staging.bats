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

# ── bd prime dedup + SessionEnd audit hook (beads_claude_docker-1qf) ───────

@test "hook-staging: project .claude/settings.json has no bd prime registration under SessionStart or PreCompact" {
    run python3 -c "
import json, sys
with open('/workspace/.claude/settings.json') as fh:
    s = json.load(fh)
hooks = s.get('hooks', {})
found = []
for event in ('SessionStart', 'PreCompact'):
    for entry in hooks.get(event, []):
        for h in entry.get('hooks', []):
            if h.get('command', '').strip() == 'bd prime':
                found.append(event)
sys.exit(1 if found else 0)
"
    [ "$status" -eq 0 ]
}

@test "hook-staging: config/claude-settings.json registers prime-memories once at SessionStart; PreCompact carries no hooks at all (beads_claude_docker-mcuw)" {
    # beads_claude_docker-zcnb: bd prime -> prime-memories (memories only,
    # budgeted). beads_claude_docker-mcuw then removed the PreCompact hook
    # entries entirely (channel discipline: SessionStart's matchers already
    # include `compact`, and CLAUDE.md is re-read from disk after /compact,
    # so PreCompact re-injection was redundant) -- this test now asserts
    # that absence honestly instead of pinning the old PreCompact count.
    run python3 -c "
import json, sys
with open('/workspace/config/claude-settings.json') as fh:
    s = json.load(fh)
hooks = s.get('hooks', {})
bad = []
count = sum(1 for entry in hooks.get('SessionStart', []) for h in entry.get('hooks', [])
            if 'prime-memories' in h.get('command', ''))
if count != 1:
    bad.append('SessionStart=%d' % count)
if 'PreCompact' in hooks:
    bad.append('PreCompact key present (should be removed entirely)')
print(' '.join(bad))
sys.exit(1 if bad else 0)
"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook-staging: home settings.json registers a prime-memories hook exactly once per event" {
    # beads_claude_docker-zcnb: bd prime -> prime-memories (memories only,
    # budgeted). The dedup intent is unchanged -- exactly one prime-style
    # hook per event, no duplicates -- only the command it now names.
    run python3 -c "
import json, sys
with open('/home/agent/.claude/settings.json') as fh:
    s = json.load(fh)
hooks = s.get('hooks', {})
bad = []
for event in ('SessionStart', 'PreCompact'):
    count = sum(1 for entry in hooks.get(event, []) for h in entry.get('hooks', [])
                if 'prime-memories' in h.get('command', ''))
    if count != 1:
        bad.append('%s=%d' % (event, count))
print(' '.join(bad))
sys.exit(1 if bad else 0)
"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook-staging: config/claude-settings.json and home settings.json both register a SessionEnd hook invoking session-end-audit" {
    run python3 -c "
import json, sys
missing = []
for path in ('/workspace/config/claude-settings.json', '/home/agent/.claude/settings.json'):
    with open(path) as fh:
        s = json.load(fh)
    hooks = s.get('hooks', {})
    found = any('session-end-audit' in h.get('command', '')
                for entry in hooks.get('SessionEnd', [])
                for h in entry.get('hooks', []))
    if not found:
        missing.append(path)
print(' '.join(missing))
sys.exit(1 if missing else 0)
"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook-staging: session-end-audit.sh logs the dirty file count via dev-log when the tree is dirty" {
    REPO="$BATS_TEST_TMPDIR/dirty-repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email test@example.com
    git -C "$REPO" config user.name test
    echo one > "$REPO/a.txt"
    git -C "$REPO" add a.txt
    git -C "$REPO" commit -q -m init
    echo two >> "$REPO/a.txt"
    echo untracked > "$REPO/b.txt"
    FAKEBIN="$BATS_TEST_TMPDIR/fakebin-dirty"
    mkdir -p "$FAKEBIN"
    CAPTURE="$BATS_TEST_TMPDIR/devlog-dirty.log"
    printf '#!/usr/bin/env bash\necho "$@" >> "%s"\n' "$CAPTURE" > "$FAKEBIN/dev-log"
    chmod +x "$FAKEBIN/dev-log"
    export PATH="$FAKEBIN:$PATH"
    payload="{\"cwd\":\"$REPO\"}"
    run bash -c 'printf "%s" "$1" | /workspace/scripts/session-end-audit.sh' _ "$payload"
    [ "$status" -eq 0 ]
    [ -f "$CAPTURE" ]
    grep -q "2 file" "$CAPTURE"
}

@test "hook-staging: plugin/hooks/hooks.json carries tier-reconcile under PostModelSwitch/ConfigChange/SessionStart, not UserPromptSubmit (beads_claude_docker-v4p)" {
    PLUGIN_HOOKS=/workspace/plugin/hooks/hooks.json
    run jq -r '[.hooks.PostModelSwitch[]?.hooks[]?.command] | map(select(contains("tier-reconcile"))) | length' "$PLUGIN_HOOKS"
    [ "$output" = "1" ]
    run jq -r '[.hooks.ConfigChange[]?.hooks[]?.command] | map(select(contains("tier-reconcile"))) | length' "$PLUGIN_HOOKS"
    [ "$output" = "1" ]
    run jq -r '[.hooks.SessionStart[]?.hooks[]?.command] | map(select(contains("tier-reconcile"))) | length' "$PLUGIN_HOOKS"
    [ "$output" = "1" ]
    run jq -r '[.hooks.UserPromptSubmit[]?.hooks[]?.command] | map(select(contains("tier-reconcile"))) | length' "$PLUGIN_HOOKS"
    [ "$output" = "0" ]
}

@test "hook-staging: TIERED_ORCHESTRATION.md documents PostModelSwitch/ConfigChange as tier-reconcile's triggers, not per-prompt UserPromptSubmit (beads_claude_docker-v4p)" {
    KB=/workspace/knowledge-base/TIERED_ORCHESTRATION.md
    run grep -c "SessionStart + UserPromptSubmit hook" "$KB"
    [ "$status" -eq 1 ]
    grep -q "PostModelSwitch" "$KB"
    grep -q "ConfigChange" "$KB"
}

@test "hook-staging: session-end-audit.sh emits nothing when the tree is clean" {
    REPO="$BATS_TEST_TMPDIR/clean-repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email test@example.com
    git -C "$REPO" config user.name test
    echo one > "$REPO/a.txt"
    git -C "$REPO" add a.txt
    git -C "$REPO" commit -q -m init
    FAKEBIN="$BATS_TEST_TMPDIR/fakebin-clean"
    mkdir -p "$FAKEBIN"
    CAPTURE="$BATS_TEST_TMPDIR/devlog-clean.log"
    printf '#!/usr/bin/env bash\necho "$@" >> "%s"\n' "$CAPTURE" > "$FAKEBIN/dev-log"
    chmod +x "$FAKEBIN/dev-log"
    export PATH="$FAKEBIN:$PATH"
    payload="{\"cwd\":\"$REPO\"}"
    run bash -c 'printf "%s" "$1" | /workspace/scripts/session-end-audit.sh' _ "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$CAPTURE" ]
}
