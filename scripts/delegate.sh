#!/usr/bin/env bash
# delegate.sh — headless delegation to an external model via opencode, run
# in an ephemeral git worktree with a scrubbed environment (beads_claude_
# docker-z16). Core of Phase 2: this is what actually spends the routes
# config's tokens/dollars, not just declares them.
#
# Routes come from config/delegate-routes.json (overridable via
# $DELEGATE_ROUTES so tests never touch the shipped config): name ->
# runner/model/pin/grade. "grade: executor" routes may take --bead
# dispatch; "grade: scout" routes are prompt-only.
#
# Usage:
#   delegate check
#       Per-route health table (route, status live|degraded, reason).
#       Always exits 0 — informational only.
#
#   delegate run --route <route> (--bead <id> | --prompt <text> | --prompt-file <file>)
#       1. Loads the route; unknown route -> loud error listing known routes.
#       2. Refuses --bead against a scout-grade route (prompt-only there).
#       3. Preflights the route (same checks as `check`); any failure is a
#          loud error with the concrete reason and a nonzero exit. No
#          silent fallback to another route or model.
#       4. Creates job dir .delegate/jobs/<route>-<epoch>-<hex>/ (under
#          $DELEGATE_REPO, default /workspace) with worktree/, config/,
#          home/, and an ephemeral git worktree + branch delegate/<job>.
#       5. Composes the prompt: for --bead, from `bd show <id>` (title,
#          description, acceptance CHECK) plus standing instructions; for
#          --prompt/--prompt-file, verbatim.
#       6. Writes an opencode.json under the job's own XDG_CONFIG_HOME
#          scoped to the route's model/pin.
#       7. Runs opencode headless in a scrubbed env (env -i + only what's
#          needed — never the orchestrator's own ANTHROPIC_* vars).
#       8. Writes receipt.json (tokens, wall time, usd, exit code) with any
#          secret redacted from both the receipt and the log.
#       9. For --bead jobs, appends route/branch/receipt to the bead's
#          notes. Never edits the bead's acceptance field.
#      10. Best-effort, fail-open hand-off to cost-mirror.py if it has
#          grown an ingest hook; silently skipped otherwise.
#
#   delegate ps
#       Lists job dirs: running (pid alive, no receipt yet) vs done
#       (receipt present). Never deletes or touches job state.
#
# $DELEGATE_ROUTES overrides the routes config path; $DELEGATE_REPO
# overrides the repo the worktree/bd commands operate on (both exist so
# the test suite can run entirely against scratch fixtures).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTES_FILE="${DELEGATE_ROUTES:-/workspace/config/delegate-routes.json}"
REPO_DIR="${DELEGATE_REPO:-/workspace}"
DELEGATE_HOME="$REPO_DIR/.delegate"

err() { printf 'delegate: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
    cat <<'USAGE'
Usage:
  delegate run --route <route> (--bead <id> | --prompt <text> | --prompt-file <file>)
  delegate check
  delegate ps
USAGE
}

require_routes_file() {
    [[ -f "$ROUTES_FILE" ]] || die "routes config not found: $ROUTES_FILE"
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

# egress_blocked <host> — best-effort, read-only inspection of the OUTPUT
# chain (same technique as pin-currency.bats: a fake `iptables` on PATH
# stands in for the real one in tests). Anything we can't read is treated
# as open, never as blocked — this is a health hint, not enforcement.
egress_blocked() {
    local host="$1" rules
    if ! rules=$(iptables -S OUTPUT 2>/dev/null); then
        return 1
    fi
    [[ -z "$rules" ]] && return 1
    if grep -q -- '-P OUTPUT DROP' <<<"$rules"; then
        if grep -qi -- "$host" <<<"$rules"; then
            return 1
        fi
        return 0
    fi
    return 1
}

# route_status <route> — prints "<live|degraded>\t<reason>". Shared by
# `check` (all routes) and `run`'s preflight (one route, hard-fails on
# anything but live).
route_status() {
    local route="$1" model provider
    model=$(route_field "$route" ".model")
    provider="${model%%/*}"

    if ! command -v opencode >/dev/null 2>&1; then
        printf 'degraded\topencode not found on PATH\n'
        return 0
    fi

    case "$provider" in
        openrouter)
            if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
                printf 'degraded\tOPENROUTER_API_KEY not set\n'
                return 0
            fi
            if egress_blocked "openrouter.ai"; then
                printf 'degraded\tegress blocked (flag off)\n'
                return 0
            fi
            ;;
        ollama)
            if ! curl -sf -m 2 http://host.docker.internal:11434/api/version >/dev/null 2>&1; then
                printf 'degraded\tollama unreachable\n'
                return 0
            fi
            ;;
    esac

    printf 'live\tok\n'
    return 0
}

cmd_check() {
    require_routes_file
    printf '%-10s %-10s %s\n' "ROUTE" "STATUS" "REASON"
    local route line status reason
    while IFS= read -r route; do
        line=$(route_status "$route")
        status="${line%%$'\t'*}"
        reason="${line#*$'\t'}"
        printf '%-10s %-10s %s\n' "$route" "$status" "$reason"
    done < <(known_routes)
    return 0
}

# redact_secret <file> <secret> — literal (non-regex) replace via python3;
# sed would need the secret escaped as both a BRE and a replacement, which
# is easy to get subtly wrong for arbitrary key material.
redact_secret() {
    local file="$1" secret="$2"
    [[ -z "$secret" || ! -f "$file" ]] && return 0
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

# extract_usage_obj <log-file> — best-effort scan of the NDJSON event
# stream opencode --format json writes: skips any non-JSON line, keeps the
# last object that carries a usage/cost field. Field names are matched
# defensively (several plausible spellings) since a "when present, else
# nulls" contract implies the shape isn't guaranteed stable.
extract_usage_obj() {
    local log="$1" obj
    obj=$(jq -R -s '
        split("\n")
        | map(select(length > 0))
        | map(try fromjson catch empty)
        | map(select(. != null and (has("usage") or has("cost"))))
        | last // {}
    ' "$log" 2>/dev/null) || obj='{}'
    [[ -z "$obj" ]] && obj='{}'
    printf '%s' "$obj"
}

generate_opencode_config() {
    local job_dir="$1" provider="$2" model_id="$3" route="$4"
    local cfg="$job_dir/config/opencode/opencode.json"
    case "$provider" in
        openrouter)
            local order_json allow_fb
            order_json=$(route_field "$route" ".pin.order // []")
            allow_fb=$(route_field "$route" ".pin.allow_fallbacks // false")
            jq -n \
                --arg model "$model_id" \
                --argjson order "$order_json" \
                --argjson allow_fallbacks "$allow_fb" \
                '{
                    "$schema": "https://opencode.ai/config.json",
                    provider: {
                        openrouter: {
                            options: { apiKey: "{env:OPENROUTER_API_KEY}" },
                            models: {
                                ($model): {
                                    options: {
                                        provider: {
                                            order: $order,
                                            allow_fallbacks: $allow_fallbacks
                                        }
                                    }
                                }
                            }
                        }
                    }
                }' >"$cfg"
            ;;
        ollama)
            jq -n \
                --arg model "$model_id" \
                '{
                    "$schema": "https://opencode.ai/config.json",
                    provider: {
                        ollama: {
                            npm: "@ai-sdk/openai-compatible",
                            options: { baseURL: "http://host.docker.internal:11434/v1" },
                            models: { ($model): {} }
                        }
                    }
                }' >"$cfg"
            ;;
        *)
            die "run: unsupported provider '$provider' for route '$route'"
            ;;
    esac
}

# compose_bead_prompt <bead-id> — pulls title/description/acceptance via
# `bd show --json` (structured, not screen-scraped) and appends the
# standing instructions every delegated executor job runs under.
compose_bead_prompt() {
    local bead_id="$1" json title description acceptance count
    json=$(bd -C "$REPO_DIR" show "$bead_id" --json 2>/dev/null) || die "run: bd show '$bead_id' failed"
    count=$(jq 'length' <<<"$json" 2>/dev/null || echo 0)
    [[ "$count" -gt 0 ]] || die "run: bead '$bead_id' not found"
    title=$(jq -r '.[0].title // ""' <<<"$json")
    description=$(jq -r '.[0].description // ""' <<<"$json")
    acceptance=$(jq -r '.[0].acceptance_criteria // ""' <<<"$json")

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

cmd_run() {
    require_routes_file

    local route="" bead="" prompt="" prompt_file=""
    local have_bead=0 have_prompt=0 have_prompt_file=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --route) route="${2:-}"; shift 2 ;;
            --bead) bead="${2:-}"; have_bead=1; shift 2 ;;
            --prompt) prompt="${2:-}"; have_prompt=1; shift 2 ;;
            --prompt-file) prompt_file="${2:-}"; have_prompt_file=1; shift 2 ;;
            *) die "run: unknown argument '$1'" ;;
        esac
    done

    [[ -n "$route" ]] || die "run: --route is required"
    local total=$((have_bead + have_prompt + have_prompt_file))
    [[ "$total" -eq 1 ]] || die "run: exactly one of --bead, --prompt, --prompt-file is required"

    if ! route_exists "$route"; then
        err "unknown route '$route'. known routes:"
        known_routes | sed 's/^/  - /' >&2
        exit 1
    fi

    local grade
    grade=$(route_field "$route" ".grade")
    if [[ "$have_bead" -eq 1 && "$grade" != "executor" ]]; then
        die "run: route '$route' is $grade-grade and cannot take --bead dispatch (prompt-only route) — use --prompt or --prompt-file instead"
    fi

    local status_line status reason
    status_line=$(route_status "$route")
    status="${status_line%%$'\t'*}"
    reason="${status_line#*$'\t'}"
    if [[ "$status" != "live" ]]; then
        die "run: route '$route' preflight failed: $reason"
    fi

    local model runner provider model_id
    model=$(route_field "$route" ".model")
    runner=$(route_field "$route" ".runner")
    [[ "$runner" == "opencode" ]] || die "run: unsupported runner '$runner' for route '$route'"
    provider="${model%%/*}"
    model_id="${model#*/}"

    if [[ "$have_prompt_file" -eq 1 ]]; then
        [[ -f "$prompt_file" ]] || die "run: --prompt-file '$prompt_file' not found"
    fi

    local job_epoch job_hex job_id job_dir
    job_epoch=$(date +%s)
    job_hex=$(printf '%04x' $((RANDOM % 65536)))
    job_id="${route}-${job_epoch}-${job_hex}"
    job_dir="$DELEGATE_HOME/jobs/$job_id"
    mkdir -p "$job_dir/worktree" "$job_dir/config/opencode" "$job_dir/home"

    local branch="delegate/$job_id"
    if ! git -C "$REPO_DIR" worktree add "$job_dir/worktree" -b "$branch" HEAD \
            >"$job_dir/worktree-add.log" 2>&1; then
        cat "$job_dir/worktree-add.log" >&2
        die "run: failed to create worktree for job '$job_id'"
    fi

    local final_prompt
    if [[ "$have_bead" -eq 1 ]]; then
        final_prompt=$(compose_bead_prompt "$bead")
    elif [[ "$have_prompt" -eq 1 ]]; then
        final_prompt="$prompt"
    else
        final_prompt=$(cat "$prompt_file")
    fi

    generate_opencode_config "$job_dir" "$provider" "$model_id" "$route"

    local started_at start_epoch
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    start_epoch=$(date +%s)

    local -a env_args=(PATH="$PATH" HOME="$job_dir/home" XDG_CONFIG_HOME="$job_dir/config" TERM=dumb)
    if [[ "$provider" == "openrouter" ]]; then
        env_args+=(OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}")
    fi

    env -i "${env_args[@]}" \
        opencode run -m "$model" --dir "$job_dir/worktree" --auto --format json "$final_prompt" \
        >"$job_dir/opencode.log" 2>&1 &
    local oc_pid=$!
    echo "$oc_pid" >"$job_dir/pid"

    local exit_code=0
    wait "$oc_pid" || exit_code=$?

    local finished_at end_epoch wall_seconds
    finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    end_epoch=$(date +%s)
    wall_seconds=$((end_epoch - start_epoch))

    redact_secret "$job_dir/opencode.log" "${OPENROUTER_API_KEY:-}"

    local usage_obj tokens_in tokens_out usd
    usage_obj=$(extract_usage_obj "$job_dir/opencode.log")
    tokens_in=$(jq -r '(.usage.inputTokens // .usage.input_tokens // .usage.promptTokens // .tokens.input) // "null"' <<<"$usage_obj")
    tokens_out=$(jq -r '(.usage.outputTokens // .usage.output_tokens // .usage.completionTokens // .tokens.output) // "null"' <<<"$usage_obj")
    usd=$(jq -r '(.usage.cost // .cost) // "null"' <<<"$usage_obj")

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
        '{
            job: $job, route: $route, model: $model,
            bead: (if $bead == "" then null else $bead end),
            branch: $branch,
            tokens_in: $tokens_in, tokens_out: $tokens_out,
            wall_seconds: $wall_seconds, usd: $usd,
            exit_code: $exit_code,
            started_at: $started_at, finished_at: $finished_at
        }' >"$job_dir/receipt.json"

    redact_secret "$job_dir/receipt.json" "${OPENROUTER_API_KEY:-}"

    if [[ "$have_bead" -eq 1 ]]; then
        bd -C "$REPO_DIR" update "$bead" --append-notes \
            "delegated-to: $route
branch: $branch
receipt: $job_dir/receipt.json" >/dev/null
    fi

    local cost_mirror="$SCRIPT_DIR/cost-mirror.py"
    if [[ -f "$cost_mirror" ]] && grep -q -- "ingest-delegate-receipt" "$cost_mirror" 2>/dev/null; then
        python3 "$cost_mirror" --ingest-delegate-receipt "$job_dir/receipt.json" >/dev/null 2>&1 || true
    fi

    echo "branch: $branch"
    echo "receipt: $job_dir/receipt.json"
    echo "job $job_id finished (exit $exit_code, ${wall_seconds}s)"

    exit "$exit_code"
}

cmd_ps() {
    printf '%-28s %-8s %-8s %s\n' "JOB" "ROUTE" "STATE" "AGE"
    local jobs_dir="$DELEGATE_HOME/jobs"
    [[ -d "$jobs_dir" ]] || return 0

    local now d id route state pid epoch age
    now=$(date +%s)
    for d in "$jobs_dir"/*/; do
        [[ -d "$d" ]] || continue
        id=$(basename "$d")
        route=$(awk -F- '{ if (NF>=3) { NF-=2; OFS="-"; print } else { print $1 } }' <<<"$id")

        state="done"
        if [[ ! -f "$d/receipt.json" && -f "$d/pid" ]]; then
            pid=$(cat "$d/pid" 2>/dev/null || echo "")
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                state="running"
            fi
        fi

        epoch=$(awk -F- '{print $(NF-1)}' <<<"$id")
        if [[ "$epoch" =~ ^[0-9]+$ ]]; then
            age="$((now - epoch))s"
        else
            age="?"
        fi

        printf '%-28s %-8s %-8s %s\n' "$id" "$route" "$state" "$age"
    done
    return 0
}

main() {
    local cmd="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "$cmd" in
        run) cmd_run "$@" ;;
        check) cmd_check ;;
        ps) cmd_ps ;;
        ""|-h|--help) usage; exit 0 ;;
        *) die "unknown command '$cmd' (expected: run, check, ps)" ;;
    esac
}

main "$@"
