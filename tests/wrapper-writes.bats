#!/usr/bin/env bats
#
# V2d acceptance contract (claude-orca-qt9.9) -- FROZEN from RED-AT onward.
# The wrapper (claude-orca-shell) and config-sync run INSIDE layer 1 -- the
# Seatbelt profile Orca itself is launched under -- whenever Orca opens a
# terminal in a bootstrapped folder, and layer 1 write-denies every
# host-owned path, .claude-dev/state among them. Two wrapper outputs still
# targeted that tree: the srt settings file and config-sync's checksum
# gate. On a Mac that is a terminal that cannot start, and a config dir
# that re-syncs on every single launch.
#
# Where the settings file lands matters twice over: it IS the definition of
# layer 2, so it must sit somewhere layer 1 may write and layer 2 may not.
# .claude-dev/run and .claude-dev/tmp are therefore both out -- an agent
# can write them, and could race the wrapper between the write and the exec
# into srt. The per-user temp dir is the one place that is neither: the
# Orca profile allows file-write* under /private/var/folders, and srt's
# allowWrite can never reach outside the folder (gen-settings.sh rejects an
# extraAllowWrite entry that resolves anywhere else). The checksum has no
# such property to protect -- it only gates re-sync, and an agent that can
# forge it can at worst force or skip a sync it could already force by
# editing the config dir -- so it moves to .claude-dev/run with everything
# else the sandbox writes. See .claude/plans/orca-port.md S9.2.

load helpers/setup

CONFIG_SYNC() {
    "$ORCA_HOST/template/scripts/config-sync.sh" "$@"
}

# A child bats run with this run's own BATS_* state stripped and the
# unstubbed PATH restored, so the suite below sees the same environment it
# gets from run-tests.sh.
nested_bats() {
    env -u BATS_TEST_TMPDIR -u BATS_RUN_TMPDIR -u BATS_SUITE_TMPDIR \
        -u BATS_TMPDIR -u BATS_TEST_NAME -u BATS_TEST_FILENAME \
        -u CLAUDE_ORCA_SELFTEST_FAKE -u CLAUDE_ORCA_ROOT \
        PATH="${ORIGINAL_PATH:-$PATH}" bats "$@"
}

# --- the state/ write gate ------------------------------------------------
#
# Prints "<path relative to $1>:<n>: <text>" for every logical line under a
# scripts/ tree that WRITES into a .claude-dev/state path -- named
# literally ("$project/.claude-dev/state", "$HOST/state") or through a
# variable the same file assigned from one, resolved three assignments deep
# (STATE_DIR=... -> PROFILE="$STATE_DIR/orca.sb" -> "$PROFILE.tmp").
# Backslash continuations are joined first, so a mkdir whose target sits on
# the next physical line still counts, and <n> is the logical line number
# in that joined stream. Comment lines never count. A write is a redirect
# or one of the commands that create/replace/remove a path. Prints nothing
# for a clean tree.
state_writers() {
    local root="$1" rel joined vars pat v
    ( cd "$root" && find . -type f ) | sed 's|^\./||' | LC_ALL=C sort |
    while IFS= read -r rel; do
        joined="$(awk '{ line = $0
                         while (sub(/\\$/, "", line) && (getline nxt) > 0)
                             line = line " " nxt
                         print line }' "$root/$rel" \
                  | grep -vE '^[[:space:]]*#')"
        [ -n "$joined" ] || continue

        vars=""
        pat='(\.claude-dev/state|/state)(/|"|$|[[:space:]])'
        for _ in 1 2 3; do
            for v in $(printf '%s\n' "$joined" \
                | grep -E "^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=.*($pat)" \
                | sed -E 's/^[[:space:]]*(local[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/' \
                | LC_ALL=C sort -u); do
                case " $vars " in
                    *" $v "*) ;;
                    *) vars="$vars $v "; pat="$pat|\\\$\\{?$v([^A-Za-z0-9_]|$)" ;;
                esac
            done
        done

        printf '%s\n' "$joined" | grep -nE "($pat)" \
            | grep -E '(^|[^A-Za-z0-9_])(mkdir|cp|mv|tee|touch|install|rm|ln|dd|chmod|chown)([^A-Za-z0-9_]|$)|[^0-9A-Za-z_&]>>?[[:space:]]*[^&]' \
            | sed "s|^|$rel:|"
    done
}

@test "the wrapper writes the srt settings file under a private per-launch directory outside the project (DARWIN_USER_TEMP_DIR on Darwin, mktemp elsewhere) with mode 600 and passes that path to srt" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    real_home="$(make_real_home)"

    # --- everywhere but Darwin: mktemp under the host's own TMPDIR -------
    host_tmp="$BATS_TEST_TMPDIR/host-tmp"
    mkdir -p "$host_tmp"
    stale="$host_tmp/claude-orca.stale"
    mkdir -p "$stale"
    touch -t 200001010000 "$stale"

    : > "$STUB_LOG"
    run env CLAUDE_ORCA_REAL_HOME="$real_home" STUB_SRT_NOEXEC=1 TMPDIR="$host_tmp" \
        "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]

    # the path srt was actually handed, not one the test reconstructs
    settings="$(grep -A1 -Fx -- '--settings' "$STUB_LOG" | sed -n 2p)"
    [ -n "$settings" ]
    [ -f "$settings" ]
    run jq -e '.filesystem.allowWrite | length > 0' "$settings"
    [ "$status" -eq 0 ]

    # nowhere in the folder: state/ is host-owned (layer 1 write-denies it,
    # so on a Mac the terminal could not even start), and run/ and tmp/ are
    # agent-writable (layer 2 could rewrite it between here and the exec).
    [ "${settings#$primary/}" = "$settings" ]
    [ -z "$(find "$primary/.claude-dev" -name 'srt-*.json' 2>/dev/null)" ]

    # private per-launch directory: 700 on the directory, 600 on the file
    dir="$(dirname "$settings")"
    [ "$(file_mode "$settings")" = "600" ]
    [ "$(file_mode "$dir")" = "700" ]
    [ "$(dirname "$dir")" = "$(abspath "$host_tmp")" ]
    [ "${dir##*/claude-orca.}" != "$dir" ]

    # per LAUNCH -- a fresh directory each time, and the stale ones a
    # previous launch left behind (nothing survives the exec to clean up
    # after itself) are removed by the next one.
    [ ! -d "$stale" ]
    : > "$STUB_LOG"
    run env CLAUDE_ORCA_REAL_HOME="$real_home" STUB_SRT_NOEXEC=1 TMPDIR="$host_tmp" \
        "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    settings2="$(grep -A1 -Fx -- '--settings' "$STUB_LOG" | sed -n 2p)"
    [ -n "$settings2" ]
    [ "$(dirname "$settings2")" != "$dir" ]

    # --- Darwin: the per-user temp dir, never $TMPDIR --------------------
    # /private/var/folders on a real Mac: the Orca profile allows
    # file-write* there and srt's allowWrite can never include it. Faked
    # here (uname/getconf/sandbox-exec) so the branch is exercised, not
    # merely read.
    darwin_tmp="$BATS_TEST_TMPDIR/darwin-user-temp"
    mkdir -p "$darwin_tmp"
    dbin="$BATS_TEST_TMPDIR/darwin-stubs"
    mkdir -p "$dbin"
    cat > "$dbin/uname" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-s" ] && { echo Darwin; exit 0; }
PATH="${ORIGINAL_PATH:-/usr/bin:/bin}" exec uname "$@"
STUB
    cat > "$dbin/getconf" <<'STUB'
#!/usr/bin/env bash
# real macOS getconf prints this one WITH a trailing slash
[ "$1" = "DARWIN_USER_TEMP_DIR" ] && { printf '%s/\n' "$FAKE_DARWIN_TEMP"; exit 0; }
PATH="${ORIGINAL_PATH:-/usr/bin:/bin}" exec getconf "$@"
STUB
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dbin/sandbox-exec"
    chmod +x "$dbin/uname" "$dbin/getconf" "$dbin/sandbox-exec"

    : > "$STUB_LOG"
    run env CLAUDE_ORCA_REAL_HOME="$real_home" STUB_SRT_NOEXEC=1 TMPDIR="$host_tmp" \
        FAKE_DARWIN_TEMP="$darwin_tmp" PATH="$dbin:$PATH" \
        "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]

    settings3="$(grep -A1 -Fx -- '--settings' "$STUB_LOG" | sed -n 2p)"
    [ -n "$settings3" ]
    [ -f "$settings3" ]
    [ "$(file_mode "$settings3")" = "600" ]
    dir3="$(dirname "$settings3")"
    [ "$(file_mode "$dir3")" = "700" ]
    [ "$(dirname "$dir3")" = "$(abspath "$darwin_tmp")" ]
    [ "${dir3##*/claude-orca.}" != "$dir3" ]
}

@test "no wrapper or config-sync write targets .claude-dev/state; the only state/ writers are orca-launch, install-orca and the profile generator (grep gate over scripts/)" {
    # What may still write there: the three the HOST runs outside both
    # sandboxes -- orca-launch (renders the Seatbelt profile from the
    # generator's stdout, and the launch log beside it), install-orca (the
    # DMG checksum) and the profile generator itself -- plus the launcher,
    # whose `register` creates the directory in the first place.
    allowed="sandbox/orca-launch install-orca.sh sandbox/gen-orca-profile.sh launcher.sh"

    offenders="$(state_writers "$REPO_ROOT/scripts")"
    printf 'offenders:\n%s\n' "$offenders"

    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        case " $allowed " in
            *" ${hit%%:*} "*) ;;
            *) echo "unexpected .claude-dev/state writer: $hit"; false ;;
        esac
    done <<<"$offenders"

    # the two that now run inside layer 1, named outright
    ! grep -q '^sandbox/claude-orca-shell:' <<<"$offenders"
    ! grep -q '^config-sync\.sh:' <<<"$offenders"

    # and neither output is merely renamed within the same tree
    ! grep -rn 'state/srt-' "$REPO_ROOT/scripts"
    ! grep -rn 'state/config-hash' "$REPO_ROOT/scripts"

    # The gate bites: planted into two files that are clean today, once
    # through a literal path and once through a variable -- so a pass above
    # is the tree being clean, never the gate failing to look.
    planted="$BATS_TEST_TMPDIR/planted"
    rm -rf "$planted"
    cp -R "$REPO_ROOT/scripts" "$planted"
    printf '\nprintf x > "$project/.claude-dev/state/planted"\n' >> "$planted/lib/paths.sh"
    printf '\nPLANT_DIR="$root/.claude-dev/state"\nmkdir -p "$PLANT_DIR/deep"\n' \
        >> "$planted/context-detect.sh"

    planted_hits="$(state_writers "$planted")"
    printf 'planted:\n%s\n' "$planted_hits"
    grep -q '^lib/paths\.sh:' <<<"$planted_hits"
    grep -q '^context-detect\.sh:' <<<"$planted_hits"
}

@test "config-sync's checksum lives at .claude-dev/run/config-hash and the checksum gate still skips unchanged templates" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    dest="$primary/.claude-dev/home/.claude"
    hash_file="$primary/.claude-dev/run/config-hash"

    # registration already ran one sync, and it landed in run/
    [ -s "$hash_file" ]
    [ ! -e "$primary/.claude-dev/state/config-hash" ]

    # ... and a sync still works with the whole host-owned tree read-only,
    # which is what layer 1 enforces on the Mac.
    rm -f "$hash_file"
    chmod 500 "$primary/.claude-dev/state"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    st="$status"
    chmod 700 "$primary/.claude-dev/state"
    [ "$st" -eq 0 ]
    [ -s "$hash_file" ]
    [ -f "$dest/settings.json" ]
    [ ! -e "$primary/.claude-dev/state/config-hash" ]
    hash1="$(cat "$hash_file")"

    # unchanged template -> a genuine skip: the canary a real re-sync would
    # remove is still there afterwards.
    echo canary > "$dest/agents/CANARY.md"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ -f "$dest/agents/CANARY.md" ]
    [ "$(cat "$hash_file")" = "$hash1" ]

    # changed template -> a real rewrite, and a new hash in the same place
    echo "# changed" >> "$ORCA_HOST/template/config/claude-user-memory.md"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ ! -f "$dest/agents/CANARY.md" ]
    [ "$(cat "$hash_file")" != "$hash1" ]
    diff "$ORCA_HOST/template/config/claude-user-memory.md" "$dest/CLAUDE.md"
}

@test "every pre-existing config-sync case still passes" {
    # The count this slice inherited: nothing here may quietly drop a case
    # to make the move green.
    run nested_bats --count "$REPO_ROOT/tests/config-sync.bats"
    [ "$status" -eq 0 ]
    [ "$output" = "6" ]

    run nested_bats --tap "$REPO_ROOT/tests/config-sync.bats"
    printf '%s\n' "$output"
    [ "$status" -eq 0 ]
    grep -qx '1\.\.6' <<<"$output"
    ! grep -q '^not ok' <<<"$output"
    ! grep -q '# skip' <<<"$output"
}
