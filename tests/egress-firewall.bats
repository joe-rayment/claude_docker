#!/usr/bin/env bats

# egress-firewall.bats — scripts/egress-firewall.sh: an opt-in default-deny
# OUTPUT firewall with an allowlist for the services this container talks to
# (beads_claude_docker-0am). OFF by default everywhere; entrypoint.sh only
# invokes it under CLAUDE_DEV_FIREWALL=1.
#
# FROZEN per beads_claude_docker-0am's acceptance contract: this file must
# not be edited after its RED commit. If a test here turns out to be wrong,
# stop and report -- do not edit it.
#
# ENVIRONMENT LIMITATION: this container has no CAP_NET_ADMIN (confirmed --
# /proc/self/status CapEff reads all-zero here), so a real apply can only be
# driven as far as the refusal path below. Live rule application is
# untestable in-container; --dry-run and the refusal path are the testable
# surface (see knowledge-base/EGRESS_FIREWALL.md).

SCRIPT=/workspace/scripts/egress-firewall.sh
ENTRYPOINT=/workspace/scripts/entrypoint.sh
DOCKERFILE=/workspace/Dockerfile
README=/workspace/knowledge-base/README.md
DOC=/workspace/knowledge-base/EGRESS_FIREWALL.md

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

# ── --dry-run: preview only, never touches live state ─────────────────────

@test "egress-firewall.sh --dry-run: exits 0 and emits a default-deny OUTPUT policy" {
    run bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"OUTPUT"* ]]
    [[ "$output" == *"DROP"* ]]
}

@test "egress-firewall.sh --dry-run: allowlist includes every required host" {
    run bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"api.anthropic.com"* ]]
    [[ "$output" == *"claude.ai"* ]]
    [[ "$output" == *"statsig.anthropic.com"* ]]
    [[ "$output" == *"sentry.io"* ]]
    [[ "$output" == *"github.com"* ]]
    [[ "$output" == *"api.github.com"* ]]
    [[ "$output" == *"objects.githubusercontent.com"* ]]
    [[ "$output" == *"raw.githubusercontent.com"* ]]
    [[ "$output" == *"registry.npmjs.org"* ]]
    [[ "$output" == *"pypi.org"* ]]
    [[ "$output" == *"files.pythonhosted.org"* ]]
}

@test "egress-firewall.sh --dry-run: allows DNS and established/related traffic" {
    run bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"53"* ]]
    [[ "$output" == *"ESTABLISHED"* ]]
    [[ "$output" == *"RELATED"* ]]
}

@test "egress-firewall.sh --dry-run: calls no live iptables/ipset command (positive control)" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
    cat > "$BATS_TEST_TMPDIR/bin/iptables" <<EOF
#!/usr/bin/env bash
echo "iptables \$*" >> "$CALL_LOG"
EOF
    cat > "$BATS_TEST_TMPDIR/bin/ipset" <<EOF
#!/usr/bin/env bash
echo "ipset \$*" >> "$CALL_LOG"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/iptables" "$BATS_TEST_TMPDIR/bin/ipset"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [ ! -e "$CALL_LOG" ]
}

# ── opt-in delegate routes (beads_claude_docker-1t9) ───────────────────────
# Default-deny apply itself needs CAP_NET_ADMIN (see ENVIRONMENT LIMITATION
# above), so these assert against --dry-run's preview text, same as the
# host-list test above.

@test "egress-firewall.sh --dry-run: delegate-route flags unset -- no openrouter.ai and no 11434 rule, default-deny retained" {
    run env -u CLAUDE_DEV_ALLOW_OPENROUTER -u CLAUDE_DEV_ALLOW_HOST_OLLAMA bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" != *"openrouter.ai"* ]]
    [[ "$output" != *"11434"* ]]
    [[ "$output" == *"DROP"* ]]
}

@test "egress-firewall.sh --dry-run: CLAUDE_DEV_ALLOW_OPENROUTER=1 opens openrouter.ai on 443, default-deny retained" {
    run env CLAUDE_DEV_ALLOW_OPENROUTER=1 bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"openrouter.ai"* ]]
    [[ "$output" == *"443"* ]]
    [[ "$output" == *"DROP"* ]]
}

@test "egress-firewall.sh --dry-run: CLAUDE_DEV_ALLOW_HOST_OLLAMA=1 opens the host-gateway IP on 11434, default-deny retained" {
    run env CLAUDE_DEV_ALLOW_HOST_OLLAMA=1 bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"host.docker.internal"* ]]
    [[ "$output" == *"11434"* ]]
    [[ "$output" == *"DROP"* ]]
}

# ── refusal without CAP_NET_ADMIN ──────────────────────────────────────────

@test "egress-firewall.sh: refuses to apply without NET_ADMIN, clear message, nonzero exit" {
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NET_ADMIN"* ]]
}

# ── entrypoint.sh wiring ────────────────────────────────────────────────────

@test "entrypoint.sh: egress-firewall invocation is guarded by CLAUDE_DEV_FIREWALL" {
    run grep -B3 'egress-firewall.sh' "$ENTRYPOINT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLAUDE_DEV_FIREWALL"* ]]
}

@test "entrypoint.sh: CLAUDE_DEV_FIREWALL defaults off, never unconditionally set to 1" {
    run grep -c 'CLAUDE_DEV_FIREWALL:-0' "$ENTRYPOINT"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    ! grep -qE '^[[:space:]]*(export[[:space:]]+)?CLAUDE_DEV_FIREWALL=1' "$ENTRYPOINT"
}

# ── Dockerfile installs iptables ────────────────────────────────────────────

@test "Dockerfile: installs iptables via apt-get" {
    run grep -n 'iptables' "$DOCKERFILE"
    [ "$status" -eq 0 ]
    run grep -B5 'iptables' "$DOCKERFILE"
    [[ "$output" == *"apt-get install"* ]]
}

# ── knowledge-base doc + index ──────────────────────────────────────────────

@test "knowledge-base: EGRESS_FIREWALL.md exists and is indexed in README.md" {
    [ -f "$DOC" ]
    grep -q 'EGRESS_FIREWALL.md' "$README"
}
