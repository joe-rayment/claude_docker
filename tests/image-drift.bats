#!/usr/bin/env bats

# image-drift — SessionStart check comparing repo scripts/* against their
# staged /usr/local/bin/* counterparts (beads_claude_docker-0v3). Tests run
# the repo script directly, never the baked /usr/local/bin copy — see
# knowledge-base/CONFIG_SYNC.md on why the baked copy would test staleness
# itself, not the check.

CHECK=/workspace/scripts/image-drift.py
DOCKERFILE=/workspace/Dockerfile

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    STAGED="$BATS_TEST_TMPDIR/staged"
    mkdir -p "$STAGED"
    # Build a byte-for-byte-clean staged mirror from the real Dockerfile's
    # COPY lines, reusing the checker's own copy_entries() — the single
    # owner of that parser (scripts/image-drift.py) — so this fixture can
    # never silently drift from what the checker reads.
    python3 -c "
import importlib.util, os, shutil
spec = importlib.util.spec_from_file_location('image_drift', '$CHECK')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
with open('$DOCKERFILE') as fh:
    text = fh.read()
for src, dest in m.copy_entries(text):
    shutil.copy(os.path.join('/workspace', src), os.path.join('$STAGED', dest))
"
}

run_check() {
    run env REPO_ROOT=/workspace STAGED_BIN_DIR="$STAGED" python3 "$CHECK"
}

# ── clean state ──────────────────────────────────────────────────────────

@test "image-drift: staged mirror matches repo -> silent, exit 0" {
    run_check
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── drift detection ──────────────────────────────────────────────────────

@test "image-drift: a content-modified staged script is reported by name" {
    printf '\n# drifted\n' >> "$STAGED/cost-mirror"
    run_check
    [ "$status" -eq 0 ]
    [[ "$output" == *"cost-mirror"* ]]
    [[ "$output" == *"claude-dev --rebuild"* ]]
}

@test "image-drift: a staged file absent entirely is reported by name" {
    rm "$STAGED/tier-gate"
    run_check
    [ "$status" -eq 0 ]
    [[ "$output" == *"tier-gate"* ]]
}

@test "image-drift: multiple drifted files are named in a single line" {
    printf '\n# drifted\n' >> "$STAGED/cost-mirror"
    rm "$STAGED/tier-gate"
    run_check
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 1 ]
    [[ "$output" == *"cost-mirror"* ]]
    [[ "$output" == *"tier-gate"* ]]
}

# ── fail-open cases ──────────────────────────────────────────────────────

@test "image-drift: no Dockerfile / not the template repo -> silent, exit 0" {
    OTHER="$BATS_TEST_TMPDIR/other-project"
    mkdir -p "$OTHER"
    run env REPO_ROOT="$OTHER" STAGED_BIN_DIR="$STAGED" python3 "$CHECK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "image-drift: repo dir with no scripts/ subdir -> silent, exit 0 (M3: isdir guard, non-vacuous)" {
    # The Dockerfile references the /opt/claude-dev marker (so the marker
    # check alone won't short-circuit this) and COPYs a file that lives at
    # repo root, NOT under scripts/ — so if the isdir(scripts_dir) guard
    # were ever dropped, this would still reach the hashing loop, find
    # root/run-tests.sh readable, and report it drifted against the
    # deliberately-different staged copy below. With the guard intact it
    # must stay silent.
    OTHER="$BATS_TEST_TMPDIR/other-project2"
    mkdir -p "$OTHER"
    printf 'FROM scratch\nCOPY --chown=agent:agent run-tests.sh /usr/local/bin/run-tests.sh\nCOPY tests/ /opt/claude-dev/tests/\n' > "$OTHER/Dockerfile"
    printf '#!/bin/sh\necho clean\n' > "$OTHER/run-tests.sh"
    STAGED_M3="$BATS_TEST_TMPDIR/staged-m3"
    mkdir -p "$STAGED_M3"
    printf '#!/bin/sh\necho DRIFTED\n' > "$STAGED_M3/run-tests.sh"
    run env REPO_ROOT="$OTHER" STAGED_BIN_DIR="$STAGED_M3" python3 "$CHECK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "image-drift: malformed Dockerfile (no matching COPY lines) -> silent, exit 0" {
    SCRATCH="$BATS_TEST_TMPDIR/scratch-repo"
    mkdir -p "$SCRATCH/scripts"
    printf 'this is not a dockerfile\nSOME GARBAGE mentioning /opt/claude-dev\n<<<<<<<\n' > "$SCRATCH/Dockerfile"
    run env REPO_ROOT="$SCRATCH" STAGED_BIN_DIR="$STAGED" python3 "$CHECK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── blocker 1: production must not depend on tests/ being present ────────

@test "image-drift: still detects drift correctly with no tests/ directory anywhere in the repo" {
    SCRATCH="$BATS_TEST_TMPDIR/no-tests-repo"
    mkdir -p "$SCRATCH/scripts"
    printf 'FROM scratch\nCOPY --chown=agent:agent scripts/cost-mirror.py /usr/local/bin/cost-mirror\nCOPY --chown=agent:agent knowledge-base/ /opt/claude-dev/knowledge-base/\n' > "$SCRATCH/Dockerfile"
    cp /workspace/scripts/cost-mirror.py "$SCRATCH/scripts/cost-mirror.py"
    STAGED_NT="$BATS_TEST_TMPDIR/staged-no-tests"
    mkdir -p "$STAGED_NT"
    cp "$SCRATCH/scripts/cost-mirror.py" "$STAGED_NT/cost-mirror"
    printf '\n# drifted\n' >> "$STAGED_NT/cost-mirror"
    [ ! -e "$SCRATCH/tests" ]
    run env REPO_ROOT="$SCRATCH" STAGED_BIN_DIR="$STAGED_NT" python3 "$CHECK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cost-mirror"* ]]
}

# ── blocker 2: positive marker, not pair-absence ──────────────────────────

@test "image-drift: unrelated Dockerfile+scripts/ pair without /opt/claude-dev marker is silent (no spurious hit)" {
    SCRATCH="$BATS_TEST_TMPDIR/unrelated-project"
    mkdir -p "$SCRATCH/scripts"
    printf 'FROM scratch\nCOPY --chown=app:app scripts/mytool.sh /usr/local/bin/mytool\n' > "$SCRATCH/Dockerfile"
    printf '#!/bin/sh\necho hi\n' > "$SCRATCH/scripts/mytool.sh"
    run env REPO_ROOT="$SCRATCH" STAGED_BIN_DIR="$STAGED" python3 "$CHECK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── blocker 4, M5: mode-only differences must stay silent ─────────────────

@test "image-drift: a staged file with only a mode difference (chmod, same content) is silent" {
    chmod 600 "$STAGED/cost-mirror"
    run_check
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
