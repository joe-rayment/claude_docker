#!/usr/bin/env bats
#
# verifier-doc.bats -- the 2026 reseat's two shipped-config surfaces
# (claude-orca-8a0.2): the verifier's unseen-case check C6, and the
# flash-class scout routes in config/delegate-routes.json. Pure file
# reads -- no scripts, no network, no Docker.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

VERIFIER="$REPO_ROOT/config/agents/verifier.md"
ROUTES="$REPO_ROOT/config/delegate-routes.json"

@test "the verifier definition carries the unseen-case check C6" {
    [ -f "$VERIFIER" ]

    # C6 exists, is named "Unseen case", and lands AFTER C5
    run grep -nF -- '**C6 — Unseen case.**' "$VERIFIER"
    [ "$status" -eq 0 ]
    c5=$(grep -nF -- '**C5 —' "$VERIFIER" | head -1 | cut -d: -f1)
    c6=$(grep -nF -- '**C6 —' "$VERIFIER" | head -1 | cut -d: -f1)
    [ -n "$c5" ]
    [ -n "$c6" ]
    [ "$c6" -gt "$c5" ]

    # the check itself: ONE case derived from the PASS-IF prose that the
    # frozen tests do not already cover, actually run, and a failure is a
    # FAIL that names the case.
    sed -n '/\*\*C6 — /,/^If none/p' "$VERIFIER" > "$BATS_TEST_TMPDIR/c6.md"
    [ -s "$BATS_TEST_TMPDIR/c6.md" ]
    grep -qF -- 'PASS-IF' "$BATS_TEST_TMPDIR/c6.md"
    grep -qiE 'boundary' "$BATS_TEST_TMPDIR/c6.md"
    grep -qiE 'negative path' "$BATS_TEST_TMPDIR/c6.md"
    grep -qF -- 'Verdict: FAIL' "$BATS_TEST_TMPDIR/c6.md"
    grep -qiE 'naming the case' "$BATS_TEST_TMPDIR/c6.md"

    # said out loud, once: a verifier that never fails anything is not working
    grep -qiE 'never returns FAIL' "$VERIFIER"

    # the verdict gate counts C6 in, and the report block carries its line
    grep -qF -- 'C1-C6' "$VERIFIER"
    grep -qE '^ +C6 unseen' "$VERIFIER"

    # the frontmatter model field is untouched -- the checker model is bound
    # in tier state at spawn time, never written into this file.
    grep -qE '^model: inherit' "$VERIFIER"
}

@test "delegate routes carry a flash-class scout route" {
    [ -f "$ROUTES" ]
    run jq -e . "$ROUTES"
    [ "$status" -eq 0 ]

    run jq -e '.routes["glm-flash"] | .runner == "opencode" and .model == "openrouter/~z-ai/glm-flash-latest" and .grade == "scout"' "$ROUTES"
    [ "$status" -eq 0 ]
    run jq -e '.routes["deepseek-flash"] | .runner == "opencode" and .model == "openrouter/~deepseek/deepseek-flash-latest" and .grade == "scout"' "$ROUTES"
    [ "$status" -eq 0 ]

    # the six routes that were already shipped survive unchanged
    run jq -e '.routes | has("glm") and has("deepseek") and has("qwen-coder") and has("local") and has("codex") and has("gemini")' "$ROUTES"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.routes.glm.model' "$ROUTES")" = "openrouter/~z-ai/glm-latest" ]
    [ "$(jq -r '.routes.glm.grade' "$ROUTES")" = "executor" ]

    # every route still declares the shape delegate.sh needs
    run jq -e '(.routes | length) as $n
               | ([ .routes[] | select((.runner|type) == "string"
                                   and (.model|type)  == "string"
                                   and (.grade|type)  == "string") ] | length) == $n' "$ROUTES"
    [ "$status" -eq 0 ]
    # ... and no new grade vocabulary crept in
    [ "$(jq -r '[.routes[].grade] | unique | join(",")' "$ROUTES")" = "executor,scout" ]
}
