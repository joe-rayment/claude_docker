#!/usr/bin/env bats
#
# First-start failure a real Mac run hit on 2026-09-06: the folder took the
# runtime-install path, the VM had no working DNS, apt printed "Temporary
# failure resolving 'ports.ubuntu.com'" for every line, setup.sh died on
# "E: Unable to locate package fonts-liberation", the container exited --
# and the Mac side kept printing "installing toolchain: ..." for its full
# 1800 s timeout. Four fixes landed at the time, one contract:
#   1. the entrypoint repairs the VM's resolv.conf before anything uses the
#      network (scripts/container/entrypoint.sh, ensure_dns);
#   2. setup.sh names DNS, not a package, when apt cannot resolve;
#   3. the launcher passes --dns on `docker run`, stops waiting the
#      moment the container is gone, and shows the install log's tail;
#   4. bootstrap asked for the read:packages scope that avoided the
#      runtime path altogether -- gone now that the image is built on
#      this machine rather than pulled, so its cases went with it.
#
# The entrypoint and setup.sh cases run natively (this box is the same
# Ubuntu the image is built on); the launcher cases run against the
# Mac-tooling stubs from helpers/setup.

load helpers/setup

ENTRYPOINT="$REPO_ROOT/scripts/container/entrypoint.sh"
SETUP_SH="$REPO_ROOT/scripts/container/setup.sh"

# The entrypoint never exits by itself -- PID 1 waits on the sshd supervisor
# -- so the two cases that read what it did to a resolv.conf boot it with
# run_entrypoint_once (tests/helpers/entrypoint-boot.bash): it waits for the
# "waiting on the sshd supervisor" line, which is printed after ensure_dns
# has run, sends TERM as `docker stop` would, and leaves everything the
# entrypoint printed in $output and its exit status in $ep_status.
#
# That helper also defines setup(), teardown() and make_project(), which
# would replace helpers/setup's for the launcher cases below, so only the
# cases that boot the entrypoint pull it in (bats runs each case in its own
# process, so the override ends with the case).
boot_fixture() {
    load helpers/entrypoint-boot
    setup
}

run_entrypoint_dns() {
    # $1 = project, $2 = resolv.conf, $3 = probe host
    run_entrypoint_once HOME="$1/.claude-dev/home" PROJECT_DIR="$1" \
        CLAUDE_ORCA_SKIP_SETUP=1 CLAUDE_ORCA_SKIP_BEADS=1 \
        CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        CLAUDE_ORCA_RESOLV_CONF="$2" CLAUDE_ORCA_DNS_PROBE_HOST="$3"
}

# The entrypoint's dispatch runs on source, so the DNS functions are lifted
# out of the real file (the way tests/launcher-v3-pull.bats lifts launcher
# functions) to exercise the root-only repair on a box where the suite is
# not root.
lift_dns_fns() {
    sed -n '/^dns_resolves()/,/^}/p;/^ensure_dns()/,/^}/p' "$ENTRYPOINT"
}

@test "the entrypoint repairs a resolv.conf that cannot resolve" {
    # Guards:   a start whose DNS probe fails says so, names the host, and
    #           (non-root) leaves resolv.conf alone; the root-only repair
    #           prepends the fallback nameserver once, keeps the old lines,
    #           leaves no temp file, and is not applied twice.
    # Fails if: the probe failure goes unreported, a non-root start rewrites
    #           resolv.conf, the repair drops the original lines or runs
    #           twice, or the entrypoint stops reaching its steady state.
    # Run:      bats -f 'repairs a resolv.conf that cannot resolve' tests/first-start-dns.bats
    [ -x "$ENTRYPOINT" ]

    # Half of this case is what a NON-root run is told: the entrypoint
    # declines to rewrite resolv.conf and says "only root may repair" it.
    # Run as root that branch is never taken, the file is rewritten in
    # place, and the assertions below would be measuring the opposite
    # behaviour rather than failing honestly.
    need_nonroot "the entrypoint's refusal to rewrite resolv.conf"

    boot_fixture
    proj="$TMP/ep"
    make_project "$proj"
    resolv="$TMP/resolv.conf"
    printf 'nameserver 192.0.2.1\nsearch example.invalid\n' > "$resolv"
    cp "$resolv" "$BATS_TEST_TMPDIR/resolv.before"

    # Not root here: the probe fails, the entrypoint says so and names the
    # host, but it does not touch the file -- and it carries on to its
    # steady state (TERM from the helper is what ends it).
    run_entrypoint_dns "$proj" "$resolv" "no-such-host.invalid"
    [ "$ep_status" = "143" ]
    [[ "$output" == *"waiting on the sshd supervisor"* ]]
    [[ "$output" == *"cannot resolve no-such-host.invalid"* ]]
    [[ "$output" == *"only root may repair $resolv"* ]]
    cmp -s "$resolv" "$BATS_TEST_TMPDIR/resolv.before"

    # The repair itself, with the functions lifted out of the file and `id`
    # answering 0: the fallback becomes the FIRST line, the original
    # contents follow untouched, and the temp file is gone.
    fns="$(lift_dns_fns)"
    [[ "$fns" == *"ensure_dns()"* ]]
    run bash -c "
log()  { printf '[entrypoint] %s\n' \"\$*\"; }
warn() { printf '[entrypoint] %s\n' \"\$*\" >&2; }
id() { echo 0; }
DNS_FALLBACK=1.1.1.1
RESOLV_CONF='$resolv'
DNS_PROBE_HOST=no-such-host.invalid
$fns
ensure_dns || true"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cannot resolve no-such-host.invalid; prepending nameserver 1.1.1.1 to $resolv"* ]]
    [ "$(head -1 "$resolv")" = "nameserver 1.1.1.1" ]
    [ "$(tail -n +2 "$resolv")" = "$(cat "$BATS_TEST_TMPDIR/resolv.before")" ]
    [ ! -e "$resolv.claude-orca.tmp" ]
    # The probe still fails (the name cannot exist), so it says the install
    # is going to fail rather than pretending.
    [[ "$output" == *"toolchain install is going to fail"* ]]

    # Run again: the line is already there, so nothing is prepended twice.
    cp "$resolv" "$BATS_TEST_TMPDIR/resolv.repaired"
    run bash -c "
log()  { printf '[entrypoint] %s\n' \"\$*\"; }
warn() { printf '[entrypoint] %s\n' \"\$*\" >&2; }
id() { echo 0; }
DNS_FALLBACK=1.1.1.1
RESOLV_CONF='$resolv'
DNS_PROBE_HOST=no-such-host.invalid
$fns
ensure_dns"
    [ "$status" -ne 0 ]
    cmp -s "$resolv" "$BATS_TEST_TMPDIR/resolv.repaired"
}

@test "a resolv.conf that already resolves is left alone" {
    # Guards:   when the DNS probe succeeds, the entrypoint neither reports
    #           a resolution problem nor touches resolv.conf.
    # Fails if: the repair runs (or complains) on a name that resolves, or
    #           the file's bytes change.
    # Run:      bats -f 'already resolves is left alone' tests/first-start-dns.bats
    boot_fixture
    proj="$TMP/ep"
    make_project "$proj"
    resolv="$TMP/resolv.conf"
    printf 'nameserver 192.0.2.1\n' > "$resolv"
    cp "$resolv" "$BATS_TEST_TMPDIR/resolv.before"

    run_entrypoint_dns "$proj" "$resolv" "localhost"
    [ "$ep_status" = "143" ]
    [[ "$output" == *"waiting on the sshd supervisor"* ]]
    [[ "$output" != *"cannot resolve"* ]]
    [[ "$output" != *"nameserver"* ]]
    cmp -s "$resolv" "$BATS_TEST_TMPDIR/resolv.before"
}

@test "setup.sh names DNS, not the missing package, when apt cannot resolve" {
    fns="$(sed -n '/^die()/p;/^apt_update_or_die()/,/^}/p' "$SETUP_SH")"
    [[ "$fns" == *"apt_update_or_die()"* ]]

    aptbin="$BATS_TEST_TMPDIR/aptbin"
    mkdir -p "$aptbin"
    cat > "$aptbin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "Ign:1 http://ports.ubuntu.com/ubuntu-ports noble InRelease"
echo "Err:1 http://ports.ubuntu.com/ubuntu-ports noble InRelease"
echo "  Temporary failure resolving 'ports.ubuntu.com'"
echo "Reading package lists..."
exit 0
STUB
    chmod +x "$aptbin/apt-get"

    run bash -c "set -Eeuo pipefail; export PATH='$aptbin:$PATH'; $fns
apt_update_or_die
echo 'apt-get install -y fonts-liberation would run here'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Temporary failure resolving 'ports.ubuntu.com'"* ]]
    [[ "$output" == *"no working DNS"* ]]
    [[ "$output" == *"claude-orca.json"* ]]
    [[ "$output" == *'"dns"'* ]]
    [[ "$output" != *"fonts-liberation"* ]]
    [[ "$output" != *"Unable to locate package"* ]]
}

@test "docker run carries --dns and claude-orca.json overrides it" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    unset CLAUDE_ORCA_DNS
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *" --dns 1.1.1.1 "* ]]

    name="claude-orca-$(basename "$primary")"
    json="$primary/.claude-dev/claude-orca.json"

    jq '.dns = "9.9.9.9"' "$json" > "$json.tmp" && mv "$json.tmp" "$json"
    rm -f "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev"
    [ "$status" -eq 0 ]
    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *" --dns 9.9.9.9 "* ]]
    [[ "$runline" != *"1.1.1.1"* ]]

    jq '.dns = "auto"' "$json" > "$json.tmp" && mv "$json.tmp" "$json"
    rm -f "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev"
    [ "$status" -eq 0 ]
    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [ -n "$runline" ]
    [[ "$runline" != *"--dns"* ]]

    # CLAUDE_ORCA_DNS wins over the file, and set-but-empty means no flag.
    rm -f "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && CLAUDE_ORCA_DNS=8.8.8.8 ./claude-dev"
    [ "$status" -eq 0 ]
    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *" --dns 8.8.8.8 "* ]]
}

@test "the launcher stops waiting as soon as the container is gone" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    # The container is listed as running and sshd never comes up; two
    # seconds in, it is gone -- what setup.sh dying looks like from the Mac.
    name="claude-orca-$(basename "$primary")"
    marker="$CONTAINER_STUB_STATE/containers/$name"
    [ "$(cat "$marker")" = "running" ]
    rm -f "$primary/.claude-dev/run/sshd.ready"
    export CLAUDE_ORCA_TEST_NO_SSHD=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=60

    before=$SECONDS
    run bash -c "( sleep 2; rm -f '$marker' ) >/dev/null 2>&1 &
cd '$primary' && ./claude-dev"
    elapsed=$((SECONDS - before))
    [ "$status" -ne 0 ]
    [ "$elapsed" -lt 20 ]
    [[ "$output" == *"exited during startup"* ]]
    [[ "$output" == *"not running"* ]]
    [[ "$output" == *"./claude-dev logs"* ]]
    [[ "$output" != *"sshd did not come up within"* ]]
    [[ "$output" != *"The VM keeps running"* ]]

    # A container that is never listed at all (removed, or gone before the
    # first poll) must not wait out the timeout either: 20 s of "no such
    # container" with no running state ever seen is dead too. Lifted the
    # way tests/launcher-v3-pull.bats lifts these, with a state stub that
    # never lists anything.
    fns="$(sed -n '/^image_source()/,/^}/p;/^weburl_timeout()/,/^}/p;/^wait_for_sshd_ready()/,/^}/p' \
        "$primary/.claude-dev/template/scripts/launcher.sh")"
    quiet="$BATS_TEST_TMPDIR/quiet"
    mkdir -p "$quiet/.claude-dev/run"
    before=$SECONDS
    run bash -c "export CLAUDE_ORCA_WEBURL_TIMEOUT=60; $fns
container_state() { printf ''; }
wait_for_sshd_ready '$quiet' claude-orca-never-listed"
    elapsed=$((SECONDS - before))
    [ "$status" -eq 2 ]
    [ "$elapsed" -ge 15 ]
    [ "$elapsed" -lt 40 ]
}

@test "a failed start shows the tail of the toolchain install log" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    mkdir -p "$primary/.claude-dev/run"
    printf 'runtime\n' > "$primary/.claude-dev/run/image-source"
    {
        echo "[setup] base: installing apt packages and generating en_US.UTF-8"
        echo "Err:1 http://ports.ubuntu.com/ubuntu-ports noble InRelease"
        echo "  Temporary failure resolving 'ports.ubuntu.com'"
        echo "Reading package lists..."
        echo "E: Unable to locate package fonts-liberation"
    } > "$primary/.claude-dev/run/setup.log"

    # The container runs but sshd never comes up: a short timeout ends the wait.
    name="claude-orca-$(basename "$primary")"
    rm -f "$CONTAINER_STUB_STATE/containers/$name"
    rm -f "$primary/.claude-dev/run/sshd.ready"
    export CLAUDE_ORCA_TEST_NO_SSHD=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=2
    run bash -c "cd '$primary' && ./claude-dev"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sshd did not come up within 2s"* ]]
    [[ "$output" == *"Last lines of the toolchain install:"* ]]
    [[ "$output" == *"E: Unable to locate package fonts-liberation"* ]]

    # And the same tail when the container is gone rather than slow.
    marker="$CONTAINER_STUB_STATE/containers/$name"
    export CLAUDE_ORCA_WEBURL_TIMEOUT=60
    run bash -c "( sleep 2; rm -f '$marker' ) >/dev/null 2>&1 &
cd '$primary' && ./claude-dev"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exited during startup"* ]]
    [[ "$output" == *"E: Unable to locate package fonts-liberation"* ]]
}

@test "an early-exit start shows sshd's log tail" {
    # Guards:   a container that dies before sshd is listening shows sshd's
    #           own last words on the Mac side (run/sshd.log), and no longer
    #           points at Orca's serve log, which the Mac does not read.
    # Fails if: the sshd log tail is dropped from the failure, or the old
    #           'Last lines of Orca's serve log:' block comes back.
    # Run:      bats -f "sshd's log tail" tests/first-start-dns.bats
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    mkdir -p "$primary/.claude-dev/run"
    {
        echo "[sshd] starting up"
        echo "[sshd] Could not load host key: /etc/ssh/host_ed25519"
        echo "[sshd] died"
    } > "$primary/.claude-dev/run/sshd.log"

    name="claude-orca-$(basename "$primary")"
    marker="$CONTAINER_STUB_STATE/containers/$name"
    rm -f "$primary/.claude-dev/run/sshd.ready"
    export CLAUDE_ORCA_TEST_NO_SSHD=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=60
    run bash -c "( sleep 2; rm -f '$marker' ) >/dev/null 2>&1 &
cd '$primary' && ./claude-dev"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exited during startup"* ]]
    [[ "$output" == *"Last lines of sshd's log:"* ]]
    [[ "$output" == *"[sshd] died"* ]]
    [[ "$output" != *"Orca's serve log"* ]]
}

