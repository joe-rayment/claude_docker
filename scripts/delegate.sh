#!/usr/bin/env bash
# delegate.sh -- headless delegation of one slice to an external model,
# run in an ephemeral git worktree with a scrubbed environment (S8,
# claude-orca-3sk.19). Claude Code stays the orchestrator; another model
# executes, takes its brief from a bead, and reports back through a
# receipt and that bead's own notes.
#
# Routes come from config/delegate-routes.json (overridable via
# $DELEGATE_ROUTES so tests never touch the shipped config): name ->
# runner/model/pin/grade. "grade: executor" routes may take --bead
# dispatch; "grade: scout" routes are prompt-only.
#
# Usage:
#   delegate check
#       Per-route health table (route, status live|degraded, reason).
#       Always exits 0 -- informational only.
#
#   delegate run --route <route> (--bead <id> | --prompt <text> | --prompt-file <file>)
#       1. Loads the route; unknown route -> loud error listing known routes.
#       2. Refuses --bead against a scout-grade route (prompt-only there).
#       3. Preflights the route (same checks as `check`); any failure is a
#          loud error with the concrete reason and a nonzero exit. No
#          silent fallback to another route or model.
#       4. Creates the job dir <primary>/.claude-dev/delegate/<job>/ with
#          worktree/, config/, home/, and an ephemeral git worktree +
#          branch delegate/<job>. The primary is discovered from git, so
#          a job dispatched from a linked worktree still lands in the one
#          place the container mounts read-write.
#       5. Composes the prompt: for --bead, from `bd show <id>` (title,
#          description, acceptance CHECK) plus standing instructions; for
#          --prompt/--prompt-file, verbatim.
#       6. Writes the runner's own config under the job's XDG_CONFIG_HOME
#          scoped to the route's model/pin (opencode), or passes the model
#          on argv (codex, gemini).
#       7. Runs the runner headless in a scrubbed env (env -i + only what
#          is needed -- never the orchestrator's own ANTHROPIC_* vars),
#          recording that env, with any key value redacted, to <job>/env.
#       8. Writes receipt.json (tokens, wall time, usd, exit code) with any
#          secret redacted from both the receipt and the log.
#       9. For --bead jobs, appends route/branch/receipt to the bead's
#          notes. Never edits the bead's acceptance field.
#      10. Best-effort, fail-open hand-off of the receipt to cost-mirror's
#          delegate ledger; silently skipped when it has no ingest hook.
#
#   delegate ps
#       Lists job dirs: running (pid alive, no receipt yet) vs done
#       (receipt present). Never deletes or touches job state.
#
#   delegate report
#       Per-route table: jobs and PASS/FAIL/TAMPERED verdict counts read
#       from delegated beads' own notes (`delegated-to: <route>` /
#       `VERIFIED: <verdict>` lines, in the order they were appended -- a
#       VERIFIED line counts against the nearest preceding delegated-to,
#       so a bead redone onto a different route attributes each verdict
#       to the route it actually followed), joined by route name with
#       delegated USD summed from cost-mirror's lifetime.json ledger
#       (honors $COST_MIRROR_STATE_DIR). Always exits 0.
#
# Egress (v3, claude-orca-qa2.3): the VM is the boundary, and it has no
# per-domain allowlist to consult -- so the preflight no longer checks one.
# What is left is what it can actually observe: the runner on PATH, a
# loopback runtime answering, and the provider key being set. If an egress
# allowlist ever lands inside the VM (plan S8 keeps it in view), its check
# belongs here, reading the VM's own rules rather than a Mac-side file.
#
# $DELEGATE_ROUTES overrides the routes config path; $DELEGATE_REPO
# overrides the repo the worktree/bd commands operate on (both exist so
# the test suite can run entirely against scratch fixtures).

set -euo pipefail

# Resolve through a symlink chain (e.g. bin/delegate -> ../scripts/
# delegate.sh) to this script's real directory.
_resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/frozen-hook.sh
. "$SCRIPT_DIR/lib/frozen-hook.sh"

ROUTES_FILE="${DELEGATE_ROUTES:-$SCRIPT_DIR/../config/delegate-routes.json}"

err() { printf 'delegate: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

# The primary checkout: the directory holding the common .git dir, so a
# job dispatched from a linked worktree still lands under the primary --
# the one tree the container mounts read-write.
resolve_repo_dir() {
    local gcd
    gcd="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
    [ -n "$gcd" ] || return 1
    case "$gcd" in
        /*) ;;
        *) gcd="$PWD/$gcd" ;;
    esac
    (cd "$gcd/.." 2>/dev/null && pwd -P)
}

if [ -n "${DELEGATE_REPO:-}" ]; then
    REPO_DIR="$(cd "$DELEGATE_REPO" && pwd -P)"
else
    REPO_DIR="$(resolve_repo_dir)" || die "not inside a git repository (and \$DELEGATE_REPO is unset)"
fi
DELEGATE_HOME="$REPO_DIR/.claude-dev/delegate"

usage() {
    cat <<'USAGE'
Usage:
  delegate run --route <route> (--bead <id> | --prompt <text> | --prompt-file <file>)
  delegate check
  delegate ps
  delegate report
USAGE
}

require_routes_file() {
    [ -f "$ROUTES_FILE" ] || die "routes config not found: $ROUTES_FILE"
    jq -e . "$ROUTES_FILE" >/dev/null 2>&1 || die "routes config is not valid JSON: $ROUTES_FILE"
}

known_routes() {
    jq -r '.routes | keys[]' "$ROUTES_FILE"
}

route_exists() {
    jq -e --arg r "$1" '.routes | has($r)' "$ROUTES_FILE" >/dev/null 2>&1
}

# route_field <route> <jq-path-suffix-starting-with-.>
route_field() {
    jq -r ".routes[\"$1\"]$2" "$ROUTES_FILE"
}

# provider -> the env var carrying its API key, and the host its API lives
# on. Kept in one place, and the preflight below refuses any provider
# missing from here.
provider_key_var() {
    case "$1" in
        openrouter) echo "OPENROUTER_API_KEY" ;;
        openai)     echo "OPENAI_API_KEY" ;;
        gemini)     echo "GEMINI_API_KEY" ;;
        *)          echo "" ;;
    esac
}

provider_host() {
    case "$1" in
        openrouter) echo "openrouter.ai" ;;
        openai)     echo "api.openai.com" ;;
        gemini)     echo "generativelanguage.googleapis.com" ;;
        *)          echo "" ;;
    esac
}

# A locally served runtime needs no allowlist entry at all: it never
# leaves the loopback interface.
OLLAMA_BASE_URL="http://127.0.0.1:11434"

# claude-orca-qa2.20: no delegate job talks to openrouter.ai directly. It
# talks to the in-VM guard (scripts/container/openrouter-guard.py), which is
# the only holder of the real key and forces config/provider-policy.json's
# US/EU provider allowlist onto every request -- the "data never routes to
# China" rule, enforced where a runner config cannot reach it. The key var
# handed to the runner therefore carries the GUARD TOKEN, not the key.
OPENROUTER_BASE_URL="${OPENROUTER_GUARD_URL:-http://127.0.0.1:4141/api/v1}"

# route_status <route> -- prints "<live|degraded>\t<reason>". Shared by
# `check` (all routes) and `run`'s preflight (one route, hard-fails on
# anything but live).
route_status() {
    local route="$1" model provider runner key_var key_value host
    model="$(route_field "$route" ".model")"
    runner="$(route_field "$route" ".runner")"
    provider="${model%%/*}"

    case "$runner" in
        opencode|codex|gemini) ;;
        *) printf 'degraded\tunsupported runner %s\n' "$runner"; return 0 ;;
    esac

    if ! command -v "$runner" >/dev/null 2>&1; then
        printf 'degraded\t%s not found on PATH\n' "$runner"
        return 0
    fi

    if [ "$provider" = "ollama" ]; then
        if ! curl -sf -m 2 "$OLLAMA_BASE_URL/api/version" >/dev/null 2>&1; then
            printf 'degraded\tollama unreachable\n'
            return 0
        fi
        printf 'live\tok\n'
        return 0
    fi

    key_var="$(provider_key_var "$provider")"
    host="$(provider_host "$provider")"
    if [ -z "$key_var" ] || [ -z "$host" ]; then
        printf 'degraded\tunknown provider %s (no key/host mapping)\n' "$provider"
        return 0
    fi
    key_value="${!key_var:-}"

    if [ -z "$key_value" ]; then
        printf 'degraded\t%s not set\n' "$key_var"
        return 0
    fi

    printf 'live\tok\n'
    return 0
}

cmd_check() {
    require_routes_file
    printf '%-10s %-10s %s\n' "ROUTE" "STATUS" "REASON"
    local route line status reason
    while IFS= read -r route; do
        line="$(route_status "$route")"
        status="${line%%$'\t'*}"
        reason="${line#*$'\t'}"
        printf '%-10s %-10s %s\n' "$route" "$status" "$reason"
    done < <(known_routes)
    return 0
}

# ── run helpers ──────────────────────────────────────────────────────────

# redact_secret <file> <secret> -- literal (non-regex) replace via python3;
# sed would need the secret escaped as both a BRE and a replacement, which
# is easy to get subtly wrong for arbitrary key material.
redact_secret() {
    local file="$1" secret="$2"
    if [ -z "$secret" ] || [ ! -f "$file" ]; then
        return 0
    fi
    python3 - "$file" "$secret" <<'PYEOF'
import sys
path, secret = sys.argv[1], sys.argv[2]
with open(path, "r", errors="replace") as f:
    data = f.read()
if secret and secret in data:
    data = data.replace(secret, "***REDACTED***")
    with open(path, "w") as f:
        f.write(data)
PYEOF
}

# extract_usage_obj <log-file> -- best-effort scan of the NDJSON event
# stream every runner emits in its JSON mode: skips any non-JSON line,
# keeps the last object that carries a usage/cost field. Field names are
# matched defensively (several plausible spellings) since no runner
# guarantees that shape stable across versions.
extract_usage_obj() {
    local log="$1" obj
    obj=$(jq -R -s '
        split("\n")
        | map(select(length > 0))
        | map(try fromjson catch empty)
        | map(select(. != null and ((has("usage") or has("cost"))
              or ((.part // {}) | (has("tokens") or has("cost"))))))
        | last // {}
    ' "$log" 2>/dev/null) || obj='{}'
    [ -z "$obj" ] && obj='{}'
    printf '%s' "$obj"
}

# generate_runner_config <job_dir> <provider> <model_id> <route> <variant> --
# only opencode reads a config file; codex and gemini take the model on
# argv. <variant> (a role's reasoning-effort, claude-orca-1w8) adds
# options.reasoning.effort under the model when set; empty means no such
# key at all.
generate_runner_config() {
    local job_dir="$1" provider="$2" model_id="$3" route="$4" variant="${5:-}"
    local cfg="$job_dir/config/opencode/opencode.json"
    case "$provider" in
        openrouter)
            local order_json allow_fb
            order_json="$(route_field "$route" ".pin.order // []")"
            allow_fb="$(route_field "$route" ".pin.allow_fallbacks // false")"
            jq -n \
                --arg model "$model_id" \
                --arg small "$provider/$model_id" \
                --arg base "$OPENROUTER_BASE_URL" \
                --argjson order "$order_json" \
                --argjson allow_fallbacks "$allow_fb" \
                --arg variant "$variant" \
                '{
                    "$schema": "https://opencode.ai/config.json",
                    small_model: $small,
                    provider: {
                        openrouter: {
                            options: { apiKey: "{env:OPENROUTER_API_KEY}", baseURL: $base },
                            models: {
                                ($model): {
                                    options: (
                                        { provider: { order: $order, allow_fallbacks: $allow_fallbacks } }
                                        + (if $variant != "" then { reasoning: { effort: $variant } } else {} end)
                                    )
                                }
                            }
                        }
                    }
                }' > "$cfg"
            ;;
        ollama)
            jq -n \
                --arg model "$model_id" \
                --arg small "$provider/$model_id" \
                --arg base "$OLLAMA_BASE_URL/v1" \
                '{
                    "$schema": "https://opencode.ai/config.json",
                    small_model: $small,
                    provider: {
                        ollama: {
                            npm: "@ai-sdk/openai-compatible",
                            options: { baseURL: $base },
                            models: { ($model): {} }
                        }
                    }
                }' > "$cfg"
            ;;
        *)
            die "run: unsupported provider '$provider' for route '$route'"
            ;;
    esac
}

# compose_bead_prompt <bead-id> -- pulls title/description/acceptance via
# `bd show --json` (structured, not screen-scraped) and appends the
# standing instructions every delegated executor job runs under.
compose_bead_prompt() {
    local bead_id="$1" json title description acceptance count
    json="$(bd -C "$REPO_DIR" show "$bead_id" --json 2>/dev/null)" || die "run: bd show '$bead_id' failed"
    count="$(jq 'length' <<<"$json" 2>/dev/null || echo 0)"
    [ "$count" -gt 0 ] || die "run: bead '$bead_id' not found"
    title="$(jq -r '.[0].title // ""' <<<"$json")"
    description="$(jq -r '.[0].description // ""' <<<"$json")"
    acceptance="$(jq -r '.[0].acceptance_criteria // ""' <<<"$json")"

    cat <<PROMPT
Bead ${bead_id}: ${title}

${description}

Acceptance criteria:
${acceptance}

Standing instructions: work only inside this worktree, implement the slice
described above, run the CHECK from the acceptance criteria above, commit
your work to the current branch when finished, and never edit this bead.
PROMPT
}

# ── run ──────────────────────────────────────────────────────────────────

cmd_run() {
    require_routes_file

    local route="" bead="" prompt="" prompt_file="" variant=""
    local have_bead=0 have_prompt=0 have_prompt_file=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --route) route="${2:-}"; shift 2 ;;
            --bead) bead="${2:-}"; have_bead=1; shift 2 ;;
            --prompt) prompt="${2:-}"; have_prompt=1; shift 2 ;;
            --prompt-file) prompt_file="${2:-}"; have_prompt_file=1; shift 2 ;;
            --variant) variant="${2:-}"; shift 2 ;;
            *) die "run: unknown argument '$1'" ;;
        esac
    done

    [ -n "$route" ] || die "run: --route is required"
    local total=$((have_bead + have_prompt + have_prompt_file))
    [ "$total" -eq 1 ] || die "run: exactly one of --bead, --prompt, --prompt-file is required"

    if ! route_exists "$route"; then
        err "unknown route '$route'. known routes:"
        known_routes | sed 's/^/  - /' >&2
        exit 1
    fi

    # CLI --variant beats the route's own "variant" (a role's reasoning
    # effort, claude-orca-1w8); neither is a requirement.
    [ -n "$variant" ] || variant="$(route_field "$route" '.variant // empty')"

    local grade
    grade="$(route_field "$route" ".grade")"
    if [ "$have_bead" -eq 1 ] && [ "$grade" != "executor" ]; then
        die "run: route '$route' is $grade-grade and cannot take --bead dispatch (prompt-only route) -- use --prompt or --prompt-file instead"
    fi

    local status_line status reason
    status_line="$(route_status "$route")"
    status="${status_line%%$'\t'*}"
    reason="${status_line#*$'\t'}"
    if [ "$status" != "live" ]; then
        die "run: route '$route' preflight failed: $reason"
    fi

    local model runner provider model_id key_var key_value
    model="$(route_field "$route" ".model")"
    runner="$(route_field "$route" ".runner")"
    provider="${model%%/*}"
    model_id="${model#*/}"
    key_var="$(provider_key_var "$provider")"
    key_value=""
    if [ -n "$key_var" ]; then
        key_value="${!key_var:-}"
    fi

    if [ "$have_prompt_file" -eq 1 ]; then
        [ -f "$prompt_file" ] || die "run: --prompt-file '$prompt_file' not found"
    fi

    local job_epoch job_hex job_id job_dir
    job_epoch="$(date +%s)"
    job_hex="$(printf '%04x' $((RANDOM % 65536)))"
    job_id="${route}-${job_epoch}-${job_hex}"
    job_dir="$DELEGATE_HOME/$job_id"
    mkdir -p "$job_dir/worktree" "$job_dir/config/opencode" "$job_dir/home"

    local branch="delegate/$job_id"
    printf '%s\n' "$branch" > "$job_dir/branch"
    if ! git -C "$REPO_DIR" worktree add "$job_dir/worktree" -b "$branch" HEAD \
            > "$job_dir/worktree-add.log" 2>&1; then
        cat "$job_dir/worktree-add.log" >&2
        die "run: failed to create worktree for job '$job_id'"
    fi

    # Frozen contract (claude-orca-ljl): a --bead job's FROZEN files are
    # guarded in git, not by spec text -- the runner may have no Claude-side
    # hooks. Prompt-only jobs have no bead to read the contract from.
    if [ "$have_bead" -eq 1 ]; then
        install_frozen_hook "$job_dir/worktree" "$bead" ||
            err "frozen-hook: could not install pre-commit hook into $job_dir/worktree"
    fi

    local final_prompt
    if [ "$have_bead" -eq 1 ]; then
        final_prompt="$(compose_bead_prompt "$bead")"
    elif [ "$have_prompt" -eq 1 ]; then
        final_prompt="$prompt"
    else
        final_prompt="$(cat "$prompt_file")"
    fi

    if [ "$runner" = "opencode" ]; then
        generate_runner_config "$job_dir" "$provider" "$model_id" "$route" "$variant"
    fi

    local started_at start_epoch
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    start_epoch="$(date +%s)"

    # The scrubbed env, and the job's own record of it. The key rides in
    # the process environment because the runner needs it; the record on
    # disk carries the name only -- the value never lands in a file.
    local -a env_args
    env_args=(PATH="$PATH" HOME="$job_dir/home" XDG_CONFIG_HOME="$job_dir/config" TERM=dumb)
    if [ -n "$key_var" ] && [ -n "$key_value" ]; then
        env_args+=("$key_var=$key_value")
    fi
    # An OpenRouter route is pointed at the guard, never at openrouter.ai:
    # opencode reads the baseURL from the config generated above, codex reads
    # OPENAI_BASE_URL from its environment.
    if [ "$provider" = "openrouter" ]; then
        env_args+=("OPENROUTER_BASE_URL=$OPENROUTER_BASE_URL" "OPENAI_BASE_URL=$OPENROUTER_BASE_URL")
    fi
    local entry name
    : > "$job_dir/env"
    for entry in "${env_args[@]}"; do
        name="${entry%%=*}"
        if [ -n "$key_var" ] && [ "$name" = "$key_var" ]; then
            printf '%s=***REDACTED***\n' "$name" >> "$job_dir/env"
        else
            printf '%s\n' "$entry" >> "$job_dir/env"
        fi
    done

    local log="$job_dir/runner.log"
    case "$runner" in
        opencode)
            env -i "${env_args[@]}" \
                opencode run -m "$model" --dir "$job_dir/worktree" --auto --format json "$final_prompt" \
                > "$log" 2>&1 &
            ;;
        codex)
            env -i "${env_args[@]}" \
                codex exec --model "$model_id" --cd "$job_dir/worktree" --json --full-auto "$final_prompt" \
                > "$log" 2>&1 &
            ;;
        gemini)
            # gemini has no working-directory flag: it reads and writes
            # wherever it is started, so the job worktree must be its cwd.
            ( cd "$job_dir/worktree" && env -i "${env_args[@]}" \
                gemini -m "$model_id" --yolo -p "$final_prompt" ) \
                > "$log" 2>&1 &
            ;;
        *)
            die "run: unsupported runner '$runner' for route '$route'"
            ;;
    esac
    local runner_pid=$!
    echo "$runner_pid" > "$job_dir/pid"

    local exit_code=0
    wait "$runner_pid" || exit_code=$?

    local finished_at end_epoch wall_seconds
    finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    end_epoch="$(date +%s)"
    wall_seconds=$((end_epoch - start_epoch))

    redact_secret "$log" "$key_value"

    local usage_obj tokens_in tokens_out usd
    usage_obj="$(extract_usage_obj "$log")"
    tokens_in="$(jq -r '(.usage.inputTokens // .usage.input_tokens // .usage.promptTokens // .tokens.input // .part.tokens.input) // "null"' <<<"$usage_obj")"
    tokens_out="$(jq -r '(.usage.outputTokens // .usage.output_tokens // .usage.completionTokens // .tokens.output // .part.tokens.output) // "null"' <<<"$usage_obj")"
    usd="$(jq -r '(.usage.cost // .cost // .part.cost) // "null"' <<<"$usage_obj")"

    jq -n \
        --arg job "$job_id" \
        --arg route "$route" \
        --arg model "$model" \
        --arg bead "$bead" \
        --arg branch "$branch" \
        --argjson tokens_in "$tokens_in" \
        --argjson tokens_out "$tokens_out" \
        --argjson wall_seconds "$wall_seconds" \
        --argjson usd "$usd" \
        --argjson exit_code "$exit_code" \
        --arg started_at "$started_at" \
        --arg finished_at "$finished_at" \
        --arg variant "$variant" \
        '{
            job: $job, route: $route, model: $model,
            bead: (if $bead == "" then null else $bead end),
            branch: $branch,
            tokens_in: $tokens_in, tokens_out: $tokens_out,
            wall_seconds: $wall_seconds, usd: $usd,
            exit_code: $exit_code,
            started_at: $started_at, finished_at: $finished_at,
            variant: (if $variant == "" then null else $variant end)
        }' > "$job_dir/receipt.json"

    redact_secret "$job_dir/receipt.json" "$key_value"

    if [ "$have_bead" -eq 1 ]; then
        bd -C "$REPO_DIR" update "$bead" --append-notes \
            "delegated-to: $route
branch: $branch
receipt: $job_dir/receipt.json" >/dev/null
    fi

    # Fail-open hand-off to the delegate ledger; skipped when this copy of
    # cost-mirror has no ingest hook.
    local cost_mirror="$SCRIPT_DIR/cost-mirror.sh"
    local cost_mirror_impl="$SCRIPT_DIR/../python/cost-mirror.py"
    if [ -f "$cost_mirror" ] && [ -f "$cost_mirror_impl" ] \
        && grep -q -- "ingest-delegate-receipt" "$cost_mirror_impl" 2>/dev/null; then
        bash "$cost_mirror" --ingest-delegate-receipt "$job_dir/receipt.json" >/dev/null 2>&1 || true
    fi

    echo "branch: $branch"
    echo "receipt: $job_dir/receipt.json"
    echo "job $job_id finished (exit $exit_code, ${wall_seconds}s)"

    exit "$exit_code"
}

# ── ps ───────────────────────────────────────────────────────────────────

cmd_ps() {
    printf '%-28s %-8s %-8s %s\n' "JOB" "ROUTE" "STATE" "AGE"
    [ -d "$DELEGATE_HOME" ] || return 0

    local now d id route state pid epoch age
    now="$(date +%s)"
    for d in "$DELEGATE_HOME"/*/; do
        [ -d "$d" ] || continue
        id="$(basename "$d")"
        route="$(awk -F- '{ if (NF>=3) { NF-=2; OFS="-"; print } else { print $1 } }' <<<"$id")"

        state="done"
        if [ ! -f "$d/receipt.json" ] && [ -f "$d/pid" ]; then
            pid="$(cat "$d/pid" 2>/dev/null || echo "")"
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                state="running"
            fi
        fi

        epoch="$(awk -F- '{print $(NF-1)}' <<<"$id")"
        if [[ "$epoch" =~ ^[0-9]+$ ]]; then
            age="$((now - epoch))s"
        else
            age="?"
        fi

        printf '%-28s %-8s %-8s %s\n' "$id" "$route" "$state" "$age"
    done
    return 0
}

# ── report ───────────────────────────────────────────────────────────────

cmd_report() {
    # (a) beads: every bead whose notes mention a delegation, then that
    # bead's full notes text, one compact JSON string per line, slurped
    # into a JSON array below. No routes-config dependency: route names
    # come straight out of the notes text.
    local ids_json bead_ids notes_lines="" notes_json
    ids_json="$(bd -C "$REPO_DIR" list --all --notes-contains "delegated-to:" --json 2>/dev/null)" || ids_json='[]'
    [ -z "$ids_json" ] && ids_json='[]'
    bead_ids="$(jq -r '.[]?.id // empty' <<<"$ids_json" 2>/dev/null)" || bead_ids=''

    if [ -n "$bead_ids" ]; then
        local id one
        while IFS= read -r id; do
            [ -z "$id" ] && continue
            one="$(bd -C "$REPO_DIR" show "$id" --json 2>/dev/null | jq -c '.[0].notes // ""' 2>/dev/null)" || one='""'
            notes_lines="$notes_lines$one"$'\n'
        done <<<"$bead_ids"
    fi
    notes_json="$(jq -s '.' <<<"$notes_lines" 2>/dev/null)" || notes_json='[]'
    [ -z "$notes_json" ] && notes_json='[]'

    # (b) dollars: delegate rows (side == "delegate") from cost-mirror's
    # lifetime.json ledger -- same state-dir logic cost-mirror itself uses,
    # honoring $COST_MIRROR_STATE_DIR.
    local state_dir lifetime_file ledger_json='[]'
    state_dir="${COST_MIRROR_STATE_DIR:-$(claude_config_dir)/cache/cost-mirror}"
    lifetime_file="$state_dir/lifetime.json"
    if [ -f "$lifetime_file" ]; then
        ledger_json="$(jq -c '[.sessions[]? | select(.side == "delegate") | {job: .sessionId, usd: (.cost_total // 0)}]' "$lifetime_file" 2>/dev/null)" || ledger_json='[]'
    fi
    [ -z "$ledger_json" ] && ledger_json='[]'

    python3 - "$notes_json" "$ledger_json" <<'PYEOF' || true
import json
import re
import sys

notes_list = json.loads(sys.argv[1])
ledger = json.loads(sys.argv[2])


def route_of(job_id):
    # Mirrors cmd_ps's own awk one-liner: drop the trailing
    # "-<epoch>-<hex>" pair, keep the rest as the route name (a route
    # name may itself contain hyphens).
    parts = job_id.split("-")
    if len(parts) >= 3:
        return "-".join(parts[:-2])
    return parts[0] if parts else job_id


# Scan each bead's notes top-to-bottom: "current route" is whatever the
# nearest preceding "delegated-to: <route>" line named, so a VERIFIED
# line always counts against the route it actually followed -- this is
# what makes a bead redone onto a different route attribute each verdict
# correctly instead of double-counting or misattributing it.
jobs = {}
verdicts = {}
for text in notes_list:
    current = None
    for line in (text or "").splitlines():
        m = re.match(r"^delegated-to:\s*(\S+)", line)
        if m:
            current = m.group(1)
            jobs[current] = jobs.get(current, 0) + 1
            verdicts.setdefault(current, {"PASS": 0, "FAIL": 0, "TAMPERED": 0})
            continue
        m = re.match(r"^VERIFIED:\s*(PASS|FAIL|TAMPERED)\b", line)
        if m and current:
            verdicts[current][m.group(1)] += 1

usd = {}
for row in ledger:
    route = route_of(row.get("job") or "")
    usd[route] = usd.get(route, 0.0) + float(row.get("usd") or 0.0)

routes = sorted(set(jobs) | set(usd))

if not routes:
    print("no delegated beads yet")
    sys.exit(0)

print(f"{'ROUTE':<10} {'JOBS':>4} {'PASS':>4} {'FAIL':>4} {'TAMPERED':>8} {'USD':>10}")
for r in routes:
    v = verdicts.get(r, {"PASS": 0, "FAIL": 0, "TAMPERED": 0})
    usd_str = "${:.2f}".format(usd.get(r, 0.0))
    print(f"{r:<10} {jobs.get(r, 0):>4} {v['PASS']:>4} {v['FAIL']:>4} {v['TAMPERED']:>8} {usd_str:>10}")
PYEOF

    return 0
}

main() {
    local cmd="${1:-}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        run) cmd_run "$@" ;;
        check) cmd_check ;;
        ps) cmd_ps ;;
        report) cmd_report ;;
        ""|-h|--help) usage; exit 0 ;;
        *) die "unknown command '$cmd' (expected: run, check, ps, report)" ;;
    esac
}

main "$@"
