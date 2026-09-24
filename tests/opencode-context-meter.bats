#!/usr/bin/env bats
#
# opencode-context-meter.bats -- claude-orca-7lz.4, amending claude-orca-7lz.2:
# a plugin at config/opencode/plugin/context-meter.js enforces the same
# CLAUDE_ORCA_CONTEXT_BUDGET / _CEILING / _WINDOW settings and the same
# SOFT NOTICE / HARD REFUSAL text in headless opencode runs (Orca workers,
# recon) that scripts/context-meter.sh enforces for in-process Claude
# sub-agents -- but the SOFT NOTICE now rides in every model call's system
# prompt (experimental.chat.system.transform), not appended to tool output:
# a real run proved models ignore an instruction embedded in a tool result,
# and the crossing step-finish arrives after that step's tool calls anyway.
#
# Cases 1-11 run node directly against the pinned plugin file through a
# small ESM harness (written once per test to $BATS_TEST_TMPDIR): it
# imports { ContextMeter }, builds a fake `client` (config.providers()
# returns the shape client.config.providers() really returns; session.abort
# records its calls), replays events, calls the hooks, and prints one JSON
# result object bats reads back with jq. Case 12 exercises
# scripts/config-sync.sh against a temp home, the way tests/config-sync.bats
# does.
#
# tests/helpers/setup.bash's setup() puts a stub node (always exit 0, no
# output) first on PATH for the template fixture it builds, so NODE_BIN is
# resolved to the REAL node ONCE, at file load, before any setup() runs, and
# every harness invocation below goes through "$NODE_BIN" -- never a bare
# `node` -- so cases 1-11 actually exercise the plugin instead of silently
# no-op'ing against the stub.
#
# FROZEN from RED-AT onward: this file must not be edited after its RED
# commit. If a case here turns out to be wrong, stop and report -- do not
# edit it.

bats_require_minimum_version 1.5.0

NODE_BIN="$(command -v node)"

load helpers/setup

PLUGIN_SRC="$BATS_TEST_DIRNAME/../config/opencode/plugin/context-meter.js"

# Writes the harness lazily, into this TEST's own tmpdir -- helpers/setup.bash
# owns setup_file()/setup() for the template fixture make_project() (case
# 12) needs, so nothing here may redefine either hook.
write_harness() {
    HARNESS="$BATS_TEST_TMPDIR/context-meter-harness.mjs"
    cat > "$HARNESS" <<'HARNESS_EOF'
// Scenario JSON on stdin:
//   { "env": {...}, "providers": {providers:[...], default:{}}, "steps": [...] }
// steps, applied in order:
//   {"op":"message.updated","sessionID":..,"providerID":..,"modelID":..}
//   {"op":"step-finish","sessionID":..,"tokens":{...}}
//   {"op":"system","sessionID":..,"model":..,"system":[...]}
//   {"op":"before","sessionID":..,"callID":..,"tool":..}
// Prints {results:[...], abortCalls:[...]} -- one results[] entry per
// "system"/"before" step, in order.
async function main() {
    const { ContextMeter } = await import(process.argv[2]);
    const raw = await new Promise((resolve) => {
        let buf = "";
        process.stdin.on("data", (d) => (buf += d));
        process.stdin.on("end", () => resolve(buf));
    });
    const scenario = JSON.parse(raw);

    for (const [k, v] of Object.entries(scenario.env || {})) {
        process.env[k] = v;
    }

    const abortCalls = [];
    const client = {
        config: {
            providers: async () => {
                if (scenario.providersError) throw new Error("providers boom");
                return { data: scenario.providers || { providers: [], default: {} } };
            },
        },
        session: {
            abort: async (opts) => {
                abortCalls.push(opts);
                return {};
            },
        },
    };

    const hooks = await ContextMeter({ client });
    const results = [];

    for (const step of scenario.steps || []) {
        if (step.op === "message.updated") {
            if (hooks.event) {
                await hooks.event({
                    event: {
                        type: "message.updated",
                        properties: {
                            info: {
                                role: "assistant",
                                sessionID: step.sessionID,
                                providerID: step.providerID,
                                modelID: step.modelID,
                            },
                        },
                    },
                });
            }
        } else if (step.op === "step-finish") {
            if (hooks.event) {
                await hooks.event({
                    event: {
                        type: "message.part.updated",
                        properties: {
                            part: {
                                type: "step-finish",
                                sessionID: step.sessionID,
                                tokens: step.tokens || {},
                            },
                        },
                    },
                });
            }
        } else if (step.op === "system") {
            const output = { system: JSON.parse(JSON.stringify(step.system || ["SYSTEM_ORIGINAL"])) };
            let threw = false;
            let error = null;
            try {
                const fn = hooks["experimental.chat.system.transform"];
                if (fn) {
                    await fn(
                        { sessionID: step.sessionID, model: step.model || { id: "m", providerID: "p", modelID: "m" } },
                        output
                    );
                }
            } catch (e) {
                threw = true;
                error = String(e && e.message ? e.message : e);
            }
            results.push({ op: "system", system: output.system, threw, error });
        } else if (step.op === "before") {
            const output = { args: {} };
            let threw = false;
            let error = null;
            try {
                const fn = hooks["tool.execute.before"];
                if (fn) await fn({ tool: step.tool, sessionID: step.sessionID, callID: step.callID }, output);
            } catch (e) {
                threw = true;
                error = String(e && e.message ? e.message : e);
            }
            results.push({ op: "before", threw, error });
        }
    }

    process.stdout.write(JSON.stringify({ results, abortCalls, hookKeys: Object.keys(hooks).sort() }));
}

main().catch((e) => {
    process.stderr.write(String(e && e.stack ? e.stack : e) + "\n");
    process.exit(1);
});
HARNESS_EOF
}

# Runs the harness against the pinned plugin file with a JSON scenario
# piped on stdin; sets $output to its printed JSON (via jq for assertions)
# and $status to node's exit code.
run_scenario() {
    write_harness
    run "$NODE_BIN" "$HARNESS" "$PLUGIN_SRC" <<<"$1"
}

@test "the module has exactly one export, ContextMeter" {
    run "$NODE_BIN" --input-type=module -e "
import * as m from '$PLUGIN_SRC';
process.stdout.write(JSON.stringify(Object.keys(m)));
"
    [ "$status" -eq 0 ]
    run jq -c '. | sort' <<<"$output"
    [ "$output" = '["ContextMeter"]' ]
}

@test "below budget -- system.transform leaves output.system unchanged" {
    run_scenario '{
        "env": {"CLAUDE_ORCA_CONTEXT_WINDOW": "100000"},
        "steps": [
            {"op":"step-finish","sessionID":"A","tokens":{"total":20000}},
            {"op":"system","sessionID":"A","system":["SYSTEM_ORIGINAL"]}
        ]
    }'
    [ "$status" -eq 0 ]
    run jq -c '.results[0].system' <<<"$output"
    [ "$output" = '["SYSTEM_ORIGINAL"]' ]
}

@test "at 35% -- system.transform's last element is the SOFT NOTICE" {
    run_scenario '{
        "env": {"CLAUDE_ORCA_CONTEXT_WINDOW": "100000"},
        "steps": [
            {"op":"step-finish","sessionID":"A","tokens":{"total":35000}},
            {"op":"system","sessionID":"A","system":["SYSTEM_ORIGINAL"]}
        ]
    }'
    [ "$status" -eq 0 ]
    RAW="$output"
    run jq -r '.results[0].system | length' <<<"$RAW"
    [ "$output" = "2" ]
    run jq -r '.results[0].system[-1]' <<<"$RAW"
    NOTICE="$output"
    run grep -qF "context is at 35% of this agent's window (budget 30%)" <<<"$NOTICE"
    [ "$status" -eq 0 ]
    run bash -c "grep -qxE '[[:space:]]*HANDOFF[[:space:]]*' <<<\"\$1\"" _ "$NOTICE"
    [ "$status" -eq 0 ]
    run bash -c "grep -qE '^relay: ' <<<\"\$1\"" _ "$NOTICE"
    [ "$status" -eq 0 ]
}

@test "sessions are separate: session A at 35%, session B at 10% -> B unchanged" {
    run_scenario '{
        "env": {"CLAUDE_ORCA_CONTEXT_WINDOW": "100000"},
        "steps": [
            {"op":"step-finish","sessionID":"A","tokens":{"total":35000}},
            {"op":"step-finish","sessionID":"B","tokens":{"total":10000}},
            {"op":"system","sessionID":"B","system":["SYSTEM_ORIGINAL"]}
        ]
    }'
    [ "$status" -eq 0 ]
    run jq -c '.results[0].system' <<<"$output"
    [ "$output" = '["SYSTEM_ORIGINAL"]' ]
}

@test "total absent/0 -- summed fields are used (62001 of 200000 -> at 31%)" {
    run_scenario '{
        "env": {},
        "providers": {"providers": [{"id":"openrouter","models":{"other-model":{"limit":{"context":999}}}}], "default": {}},
        "steps": [
            {"op":"message.updated","sessionID":"A","providerID":"openrouter","modelID":"unknown-model"},
            {"op":"step-finish","sessionID":"A","tokens":{"total":0,"input":1,"output":2000,"reasoning":0,"cache":{"read":50000,"write":10000}}},
            {"op":"system","sessionID":"A","system":["SYSTEM_ORIGINAL"]}
        ]
    }'
    [ "$status" -eq 0 ]
    run jq -r '.results[0].system[-1]' <<<"$output"
    run grep -qF "at 31%" <<<"$output"
    [ "$status" -eq 0 ]
}

@test "window from client.config.providers() -- 400000 of 1310720 -> at 30%" {
    run_scenario '{
        "env": {},
        "providers": {"providers": [{"id":"openrouter","models":{"z-ai/glm-5.3-flash":{"limit":{"context":1310720}}}}], "default": {}},
        "steps": [
            {"op":"message.updated","sessionID":"A","providerID":"openrouter","modelID":"z-ai/glm-5.3-flash"},
            {"op":"step-finish","sessionID":"A","tokens":{"total":400000}},
            {"op":"system","sessionID":"A","system":["SYSTEM_ORIGINAL"]}
        ]
    }'
    [ "$status" -eq 0 ]
    run jq -r '.results[0].system[-1]' <<<"$output"
    run grep -qF "at 30%" <<<"$output"
    [ "$status" -eq 0 ]
}

# A scenario with N consecutive refusals at 45% (window 100000, ceiling
# 40%); leaves the full harness JSON in $FULL for the caller to inspect.
refusals_scenario() {
    local n="$1" steps
    steps='{"op":"step-finish","sessionID":"A","tokens":{"total":45000}}'
    for i in $(seq 1 "$n"); do
        steps="$steps,{\"op\":\"before\",\"sessionID\":\"A\",\"callID\":\"c$i\",\"tool\":\"bash\"}"
    done
    run_scenario "{\"env\":{\"CLAUDE_ORCA_CONTEXT_WINDOW\":\"100000\"},\"steps\":[$steps]}"
    [ "$status" -eq 0 ]
    FULL="$output"
}

@test "at 45% -- before() throws, aborts once on the 3rd consecutive refusal" {
    refusals_scenario 1
    run jq -r '.results[-1].threw' <<<"$FULL"
    [ "$output" = "true" ]
    run jq -r '.results[-1].error' <<<"$FULL"
    run grep -qF "at 45%" <<<"$output"
    [ "$status" -eq 0 ]
    run jq -r '.results[-1].error' <<<"$FULL"
    run grep -qF "past the 40% ceiling" <<<"$output"
    [ "$status" -eq 0 ]
    run jq -r '.abortCalls | length' <<<"$FULL"
    [ "$output" = "0" ]

    refusals_scenario 2
    run jq -r '.abortCalls | length' <<<"$FULL"
    [ "$output" = "0" ]

    refusals_scenario 3
    run jq -r '.abortCalls | length' <<<"$FULL"
    [ "$output" = "1" ]
    run jq -r '.abortCalls[0].path.id' <<<"$FULL"
    [ "$output" = "A" ]

    refusals_scenario 4
    run jq -r '.abortCalls | length' <<<"$FULL"
    [ "$output" = "1" ]
}

@test "back under the ceiling -- a new, lower step-finish -- before() does not throw" {
    run_scenario '{
        "env": {"CLAUDE_ORCA_CONTEXT_WINDOW": "100000"},
        "steps": [
            {"op":"step-finish","sessionID":"A","tokens":{"total":45000}},
            {"op":"before","sessionID":"A","callID":"c1","tool":"bash"},
            {"op":"step-finish","sessionID":"A","tokens":{"total":5000}},
            {"op":"before","sessionID":"A","callID":"c2","tool":"bash"}
        ]
    }'
    [ "$status" -eq 0 ]
    RAW="$output"
    run jq -r '.results[0].threw' <<<"$RAW"
    [ "$output" = "true" ]
    run jq -r '.results[1].threw' <<<"$RAW"
    [ "$output" = "false" ]
}

@test "CLAUDE_ORCA_CONTEXT_BUDGET=0 -- system.transform unchanged and before() never throws at 90%" {
    run_scenario '{
        "env": {"CLAUDE_ORCA_CONTEXT_BUDGET": "0", "CLAUDE_ORCA_CONTEXT_WINDOW": "100000"},
        "steps": [
            {"op":"step-finish","sessionID":"A","tokens":{"total":90000}},
            {"op":"system","sessionID":"A","system":["SYSTEM_ORIGINAL"]},
            {"op":"before","sessionID":"A","callID":"c2","tool":"bash"}
        ]
    }'
    [ "$status" -eq 0 ]
    RAW="$output"
    run jq -c '.results[0].system' <<<"$RAW"
    [ "$output" = '["SYSTEM_ORIGINAL"]' ]
    run jq -r '.results[1].threw' <<<"$RAW"
    [ "$output" = "false" ]
}

@test "the hooks object has no tool.execute.after key" {
    run_scenario '{
        "env": {"CLAUDE_ORCA_CONTEXT_WINDOW": "100000"},
        "steps": [
            {"op":"system","sessionID":"A"}
        ]
    }'
    [ "$status" -eq 0 ]
    RAW="$output"
    run jq -r '.hookKeys | index("tool.execute.after")' <<<"$RAW"
    [ "$output" = "null" ]
    run jq -r '.hookKeys | index("experimental.chat.system.transform")' <<<"$RAW"
    [ "$output" != "null" ]
    run jq -r '.hookKeys | index("tool.execute.before")' <<<"$RAW"
    [ "$output" != "null" ]
}

@test "system.transform without input.sessionID -- output.system unchanged" {
    run_scenario '{
        "env": {"CLAUDE_ORCA_CONTEXT_WINDOW": "100000"},
        "steps": [
            {"op":"step-finish","sessionID":"A","tokens":{"total":90000}},
            {"op":"system","system":["SYSTEM_ORIGINAL"]}
        ]
    }'
    [ "$status" -eq 0 ]
    run jq -c '.results[0].system' <<<"$output"
    [ "$output" = '["SYSTEM_ORIGINAL"]' ]
}

@test "config-sync installs the plugin byte-identical at .config/opencode/plugin/context-meter.js" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    src="$ORCA_HOST/template/config/opencode/plugin/context-meter.js"
    dest="$primary/.claude-dev/home/.config/opencode/plugin/context-meter.js"

    [ -f "$src" ]

    rm -f "$PROJECT_DIR/.claude-dev/run/config-hash"
    run "$ORCA_HOST/template/scripts/config-sync.sh" --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ -f "$dest" ]
    diff "$src" "$dest"
}
