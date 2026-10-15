#!/usr/bin/env bats
#
# claude-orca-c3p.3 -- FROZEN from RED-AT onward.
# /tier binds a role to the user's OpenAI (ChatGPT) subscription: a bare
# `openai` (the role's default) and `openai:<family|id>` (a family alias
# follows its newest release, an exact id pins one model), both backend
# orca + agent opencode with the model spelled openai/... -- visibly
# distinct from the same OpenAI model through OpenRouter, whose bare
# names, vendor/model ids and catalogue phrases keep today's meaning. An
# effort rides on the spec like everywhere else; a signed-out folder
# still saves the binding and names /tier auth openai.
#
# Fast and hermetic: no network, no real opencode -- TIER_MODELS_FETCH=0,
# the OpenAI catalogue and auth store are
# fixtures and the OpenRouter catalogue is absent.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

TSET="$REPO_ROOT/scripts/tier-set.sh"
DERIVE="$REPO_ROOT/scripts/tier-derive.sh"

setup() {
    export TIER_STATE_FILE="$BATS_TEST_TMPDIR/tier.json"
    export TIER_SETTINGS_LOCAL="$BATS_TEST_TMPDIR/settings.local.json"
    export TIER_DERIVE="$DERIVE"
    export TIER_MODELS_FETCH=0
    unset OPENROUTER_API_KEY
    export TIER_OPENROUTER_KEY_FILE="$BATS_TEST_TMPDIR/no-such-openrouter.key"

    export TIER_ROUTES_FILE="$REPO_ROOT/config/delegate-routes.json"

    export TIER_OPENAI_MODELS_FILE="$BATS_TEST_TMPDIR/openai-models.json"
    cat > "$TIER_OPENAI_MODELS_FILE" <<'JSON'
[
  {"id": "gpt-5.6-luna", "family": "gpt-luna", "release_date": "2026-07-09"},
  {"id": "gpt-5.6-luna-fast", "family": "gpt-luna", "release_date": "2026-07-09"},
  {"id": "gpt-5.6-terra", "family": "gpt-terra", "release_date": "2026-07-09"},
  {"id": "gpt-5.6-sol", "family": "gpt-sol", "release_date": "2026-07-09"},
  {"id": "gpt-6.1-sol", "family": "gpt-sol", "release_date": "2026-09-29"},
  {"id": "gpt-5.4-mini", "family": "gpt-mini", "release_date": "2026-03-17"}
]
JSON

    # signed in by default: an oauth login with a refresh token
    export TIER_OPENAI_AUTH_FILE="$BATS_TEST_TMPDIR/opencode-auth.json"
    cat > "$TIER_OPENAI_AUTH_FILE" <<'JSON'
{"openai":{"type":"oauth","refresh":"rt-x","access":"a","expires":1,"accountId":"acct"}}
JSON
}

signed_out() {
    export TIER_OPENAI_AUTH_FILE="$BATS_TEST_TMPDIR/no-such-auth.json"
}

tier_set() { run "$TSET" "$@"; }

# ── (1) family specs bind the subscription's newest release, effort rides ───

@test "openai: family specs bind headless:opencode:openai/~<family>-latest per role, with the effort" {
    # Guards: openai:terra / openai:luna resolve through the catalogue's
    #   family column, so a new release needs no re-bind; an @high effort on
    #   recon is stored as the role's variant like on any opencode binding.
    # Fails if: the openai: prefix bound OpenRouter's copy, the family
    #   resolved to a pinned id, or the effort was dropped or errored.
    # Run: bats tests/tier-openai.bats
    tier_set opus openai:terra openai:luna@high
    [ "$status" -eq 0 ]
    bound_output="$output"

    run jq -e '.roles.worker == {backend:"headless", agent:"opencode", model:"openai/~gpt-terra-latest", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon == {backend:"headless", agent:"opencode", model:"openai/~gpt-luna-latest", pinned:true, variant:"high"}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    [[ "$bound_output" == *"headless:opencode:openai/~gpt-luna-latest@high"* ]]
}

# ── (2) the distinction from OpenRouter holds ───────────────────────────────

@test "a bare route name and a bare vendor/model id stay OpenRouter, openai: is the subscription" {
    # Guards: everything that existed before openai: keeps its meaning --
    #   `luna` is still the delegate route (OpenRouter's ~-latest alias) and
    #   `openai/gpt-5.6-luna` (no colon) is still the OpenRouter model.
    # Fails if: an openai/ spelling leaked into a bare-name lookup, or a
    #   bare name was reinterpreted as the ChatGPT subscription.
    # Run: bats -f 'stay OpenRouter' tests/tier-openai.bats
    tier_set opus luna luna@high
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon.model == "openrouter/~openai/gpt-luna-latest"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]

    tier_set opus openai/gpt-5.6-luna
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker.model == "openrouter/openai/gpt-5.6-luna"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (3) an exact id pins one model; spaces normalise; the comma form works ──

@test "an openai: id pins one model, spaces normalise to the id, and the comma form carries the effort" {
    # Guards: openai:gpt-5.6-luna pins exactly that id (no ~-latest alias),
    #   "GPT 5.6 Luna" lower-cases and dashes to the same id, and the
    #   comma-split trio form resolves each OpenAI phrase with its effort.
    # Fails if: an id grew an alias suffix, whitespace broke the id, or the
    #   parenthesised effort was taken as part of the model name.
    # Run: bats -f 'pins one model' tests/tier-openai.bats
    tier_set worker openai:gpt-5.6-luna
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker == {backend:"headless", agent:"opencode", model:"openai/gpt-5.6-luna", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]

    tier_set "opus, openai:GPT 5.6 Luna, openai:luna (high)"
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker.model == "openai/gpt-5.6-luna"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon == {backend:"headless", agent:"opencode", model:"openai/~gpt-luna-latest", pinned:true, variant:"high"}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (4) an unknown family or id binds nothing ───────────────────────────────

@test "an unknown OpenAI family or id exits 1, lists the families, and binds nothing" {
    # Guards: a typo in an openai: spec is an error naming the families the
    #   subscription serves, never a silent free-text bind; tier.json is
    #   byte-identical afterwards.
    # Fails if: openai:nope bound anything (or an openrouter/ model), or the
    #   error did not name the available families.
    # Run: bats -f 'unknown OpenAI family' tests/tier-openai.bats
    tier_set worker openai
    [ "$status" -eq 0 ]
    before="$(cat "$TIER_STATE_FILE")"

    tier_set worker openai:nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"luna"* ]]
    [[ "$output" == *"terra"* ]]
    after="$(cat "$TIER_STATE_FILE")"
    [ "$before" = "$after" ]
}

# ── (5) a bare openai binds the role's default ──────────────────────────────

@test "a bare openai binds the role's default subscription model: recon luna, worker terra" {
    # Guards: `openai` with no colon is the role default form -- recon
    #   recons on the newest GPT Luna, the worker executes on the newest
    #   GPT Terra -- both headless + opencode.
    # Fails if: both roles took the same default, or the bare word bound a
    #   Claude model or the OpenRouter GLM.
    # Run: bats -f "role's default subscription" tests/tier-openai.bats
    tier_set recon openai
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon.model == "openai/~gpt-luna-latest"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]

    tier_set worker openai
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker.model == "openai/~gpt-terra-latest"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (6) signed out: saved, with the sign-in pointer ─────────────────────────

@test "an openai/ bind while signed out saves and names /tier auth openai; signed in says nothing" {
    # Guards: a signed-out folder still records the binding (it runs once
    #   signed in) and prints the /tier auth openai pointer exactly on the
    #   openai/ path; a signed-in bind prints no sign-in pointer.
    # Fails if: the bind failed while signed out, or the OpenRouter
    #   not-authenticated note replaced the OpenAI one.
    # Run: bats -f 'signed out saves and names' tests/tier-openai.bats
    signed_out
    tier_set worker openai:luna
    [ "$status" -eq 0 ]
    signed_out_output="$output"
    run jq -e '.roles.worker.model == "openai/~gpt-luna-latest"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    [[ "$signed_out_output" == *"/tier auth openai"* ]]

    export TIER_OPENAI_AUTH_FILE="$BATS_TEST_TMPDIR/opencode-auth.json"
    tier_set worker openai:sol
    [ "$status" -eq 0 ]
    signed_in_output="$output"
    [[ "$signed_in_output" != *"/tier auth openai"* ]]
}

# ── (7) the positional trio prints the pair exactly once ────────────────────

@test "the positional trio prints the OpenAI sign-in pair exactly once when signed out" {
    # Guards: the trio form, which prints no auth note for OpenRouter,
    #   prints the OpenAI pair once even when BOTH worker and recon are
    #   openai/ and signed out -- never twice, never per role.
    # Fails if: the pair printed zero or two times, or the trio errored.
    # Run: bats -f 'pair exactly once' tests/tier-openai.bats
    signed_out
    tier_set fable openai:terra openai:luna@high
    [ "$status" -eq 0 ]
    [ "$(grep -c 'not signed in to OpenAI' <<<"$output")" -eq 1 ]
    [ "$(grep -c '/tier auth openai' <<<"$output")" -eq 1 ]
}

# ── (8) the checker rung takes the same specs ───────────────────────────────

@test "the checker takes openai: specs: family alias on headless:opencode, pinned" {
    # Guards: the checker role resolves openai: family specs the same way
    #   worker/recon do and pins the binding.
    # Fails if: the checker fell through to the Claude default or lost its
    #   opencode agent or headless backend.
    # Run: bats -f 'checker takes openai' tests/tier-openai.bats
    tier_set checker openai:sol
    [ "$status" -eq 0 ]
    run jq -e '.roles.checker == {backend:"headless", agent:"opencode", model:"openai/~gpt-sol-latest", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (9) models openai: families and pins ────────────────────────────────────

@test "models openai lists each family with its newest release, and word-filters the pin list" {
    # Guards: /tier models openai shows one line per family (openai:<family>
    #   resolving to that family's newest release -- sol's is gpt-6.1-sol)
    #   and `models openai <words>` filters the pin list to matching ids.
    # Fails if: a family line resolved to an older or -fast twin release, or
    #   the word filter listed non-matching ids.
    # Run: bats -f 'word-filters the pin list' tests/tier-openai.bats
    tier_set models openai
    [ "$status" -eq 0 ]
    [[ "$output" == *"openai:luna"* ]]
    [[ "$output" == *"gpt-5.6-luna"* ]]
    sol_line="$(grep 'openai:sol' <<<"$output" | head -1)"
    [[ "$sol_line" == *"gpt-6.1-sol"* ]]

    tier_set models openai mini
    [ "$status" -eq 0 ]
    [[ "$output" == *"openai:gpt-5.4-mini"* ]]
    [[ "$output" != *"openai:gpt-5.6-luna"* ]]
}

# ── (11) no catalogue at all: still binds, unchecked ────────────────────────

@test "with no OpenAI catalogue at all, a family spec still binds, unchecked" {
    # Guards: an empty catalogue (no fixture, signed out, no opencode
    #   cache) degrades to binding the ~-latest alias unchecked, with a
    #   note -- never a hard error.
    # Fails if: the bind failed, or an unchecked family bound a pinned id.
    # Run: bats -f 'binds, unchecked' tests/tier-openai.bats
    printf '[]\n' > "$TIER_OPENAI_MODELS_FILE"
    signed_out
    export TIER_OPENCODE_MODELS_CACHE="$BATS_TEST_TMPDIR/no-such-cache.json"

    tier_set worker openai:luna
    [ "$status" -eq 0 ]
    unchecked_output="$output"
    run jq -e '.roles.worker.model == "openai/~gpt-luna-latest"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    [[ "$unchecked_output" == *"bound unchecked"* ]]
}

# ── (12) auth openai: the sign-in tab, the manual fallback, the usage line ──

# An Orca CLI stub, the exact technique of tests/tier-openrouter-auth.bats:
# records argv one line per arg, answers `terminal create` with the
# envelope orca_call expects.
stub_orca() {
    local mode="${1:-ok}"
    cat > "$BATS_TEST_TMPDIR/orca-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$BATS_TEST_TMPDIR/orca-argv"
if [ "$mode" = "down" ]; then printf '%s' '{"ok":false,"error":{"message":"unreachable"}}'; exit 1; fi
case "\$1 \$2" in
  "terminal create") printf '%s' '{"ok":true,"result":{"terminal":{"handle":"term_stub"}}}' ;;
  "status --json"|"status")   printf '%s' '{"ok":true,"result":{"runtime":{"reachable":true}}}' ;;
  *) printf '%s' '{"ok":true,"result":{}}' ;;
esac
STUB
    chmod +x "$BATS_TEST_TMPDIR/orca-stub"
    export ORCA_CLI_BIN="$BATS_TEST_TMPDIR/orca-stub"
    : > "$BATS_TEST_TMPDIR/orca-argv"
}

@test "auth openai prints the two-line sign-in command for a split and makes no Orca call" {
    # Guards: /tier auth openai opens nothing -- it prints the line telling
    #   the user to open a split (cmd+d) and the command that runs this
    #   folder's scripts/openai-auth.sh there, and exits 0.
    # Fails if: the command ran the OpenRouter helper, the first line was
    #   missing, or the Orca CLI was called (a terminal create).
    # Run: bats -f 'two-line sign-in command for a split' tests/tier-openai.bats
    stub_orca ok
    run "$TSET" auth openai
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "Sign-in runs in a terminal of its own: open a split (cmd+d) and run:" ]
    [[ "${lines[1]}" == "cd "*" && "*"openai-auth.sh" ]]
    [ ! -s "$BATS_TEST_TMPDIR/orca-argv" ]
}

@test "auth openai still prints the command and exits 0 when the Orca CLI is down" {
    # Guards: sign-in no longer depends on any Orca runtime -- an Orca CLI
    #   that would fail is never even called, and the command still prints.
    # Fails if: the code reached for the Orca CLI again (its argv log gets
    #   a line) or exited non-zero because the CLI was unreachable.
    # Run: bats -f 'Orca CLI is down' tests/tier-openai.bats
    stub_orca down
    run "$TSET" auth openai
    [ "$status" -eq 0 ]
    [[ "$output" == *"openai-auth.sh"* ]]
    [ ! -s "$BATS_TEST_TMPDIR/orca-argv" ]
}

@test "auth bogus is a usage error naming both providers" {
    # Guards: the auth subcommand only takes openrouter and openai -- any
    #   other provider is a usage error, exit 1.
    # Fails if: an unknown provider silently succeeded or the usage line
    #   stopped naming the two providers.
    # Run: bats -f 'usage error naming both providers' tests/tier-openai.bats
    run "$TSET" auth bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"openrouter|openai"* ]]
}

# ── (13) openai-auth.sh: the helper behind the tab ─────────────────────────

# A stub opencode for the helper: logs its argv one line per invocation,
# and on `auth login` writes an oauth login to TIER_OPENAI_AUTH_FILE, so
# tier_openai_ready flips true afterwards. `models openai` prints two lines.
stub_opencode() {
    local mode="${1:-ok}"
    cat > "$BATS_TEST_TMPDIR/oc-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/oc-argv"
case "\$1 \$2" in
  "auth login")
      [ "$mode" = "fail" ] && exit 1
      jq -n '{openai: {type: "oauth", refresh: "rt-stub",
                       access: "at-stub-secret", expires: 1, accountId: "acct"}}' \
          > "\${TIER_OPENAI_AUTH_FILE:-$BATS_TEST_TMPDIR/opencode-auth.json}"
      exit 0 ;;
  "models openai")
      printf 'openai/gpt-5.6-luna\nopenai/gpt-5.6-terra\n'
      exit 0 ;;
esac
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/oc-stub"
    export OPENAI_AUTH_OPENCODE_BIN="$BATS_TEST_TMPDIR/oc-stub"
    : > "$BATS_TEST_TMPDIR/oc-argv"
}

helper() {
    run "$REPO_ROOT/scripts/openai-auth.sh"
}

@test "openai-auth.sh signs in through opencode, lists the models, never prints a token" {
    # Guards: the helper runs `opencode auth login --provider openai
    #   --method "ChatGPT Pro/Plus (headless)"` exactly, prints the
    #   subscription's model list indented, ends with the bind-a-role next
    #   step, and never leaks the access or refresh token it just handled.
    # Fails if: the login went out with a different provider/method, the
    #   next-step line went missing, or a token reached stdout/stderr.
    # Run: bats -f 'signs in through opencode' tests/tier-openai.bats
    signed_out
    stub_opencode ok
    helper
    [ "$status" -eq 0 ]
    tr '\n' ' ' < "$BATS_TEST_TMPDIR/oc-argv" > "$BATS_TEST_TMPDIR/oc-argv.flat"
    grep -q 'auth login --provider openai --method ChatGPT Pro/Plus (headless)' \
        "$BATS_TEST_TMPDIR/oc-argv.flat"
    [[ "$output" == *"/tier opus openai:terra openai:luna@high"* ]]
    [[ "$output" != *"at-stub-secret"* ]]
    [[ "$output" != *"rt-stub"* ]]
    [[ "$output" == *"openai/gpt-5.6-luna"* ]]
}

@test "openai-auth.sh reports a failed sign-in and exits 1" {
    # Guards: when the opencode login fails, the folder is still signed
    #   out -- the helper says so, names the retry (/tier auth openai), and
    #   exits 1 instead of printing model lists on a dead credential.
    # Fails if: a failed login was swallowed (exit 0) or the failure line
    #   went missing.
    # Run: bats -f 'reports a failed sign-in' tests/tier-openai.bats
    signed_out
    stub_opencode fail
    helper
    [ "$status" -eq 1 ]
    [[ "$output" == *"did not complete"* ]]
    [[ "$output" != *"Models your subscription serves"* ]]
}

@test "openai-auth.sh skips the login when already signed in, unless --force" {
    # Guards: a signed-in folder is not made to sign in again -- the
    #   helper says "Already signed in" and goes straight to the model
    #   list; --force runs the login anyway.
    # Fails if: the helper re-ran `auth login` on a signed-in folder, or
    #   --force stopped skipping it.
    # Run: bats -f 'already signed in' tests/tier-openai.bats
    stub_opencode ok
    helper
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already signed in to OpenAI in this folder."* ]]
    ! grep -q 'auth login' "$BATS_TEST_TMPDIR/oc-argv"

    : > "$BATS_TEST_TMPDIR/oc-argv"
    run "$REPO_ROOT/scripts/openai-auth.sh" --force
    [ "$status" -eq 0 ]
    grep -q 'auth login' "$BATS_TEST_TMPDIR/oc-argv"
}
