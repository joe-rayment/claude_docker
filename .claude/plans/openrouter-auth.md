# `/tier` OpenRouter auth that just works

User request, 2026-09-08: make the OpenRouter side of `/tier` intuitive from
the slash command alone, with an example on GLM 5.3 Flash, and handle a
session that is not authenticated yet — auth in a new tab.

## What is wrong today

`/tier worker openrouter:<vendor/model>` binds happily whether or not the
folder has a credential. `tier-set.sh:286-289` sets backend orca, agent
opencode, model `openrouter/<rest>`, pinned, and says nothing about auth.
The failure surfaces much later, inside a dispatched worker that cannot
authenticate — the least useful place for it.

Getting a key is worse: `./claude-dev key openrouter` runs on the **Mac**,
writes `<project>/.claude-dev/home/.openrouter.key` (launcher.sh:918), and
the value only reaches the container as `OPENROUTER_API_KEY` on the **next**
`./claude-dev` (launcher.sh:1233). So the answer to "I'm not authenticated"
is currently "leave the session, run a command on your Mac, restart the
container". That is the opposite of the ask.

## Ground truth this plan stands on (verified on this box, 2026-09-08)

- The guard is started at boot **only** when `OPENROUTER_API_KEY` is
  non-empty (entrypoint.sh:560), reads the real key **once** at startup
  (openrouter-guard.py:343) and has no reload signal or control route.
- It runs as the **agent** user. Verified by starting one by hand on port
  4242 with a dummy key: it bound the port, wrote `openrouter-guard.token`
  mode 600, logged `16 providers allowed, fallbacks False, data_collection
  deny`, forwarded a correctly-tokened request upstream (`providers_forced:
  true`, upstream 401 for the fake key) and refused a wrong guard token
  locally without forwarding. **Starting a guard mid-session needs no root
  and no container restart.** Only *reloading a running* guard is impossible.
- `seed-orca-state.sh` runs at entrypoint.sh:584, **before** Orca starts, and
  Orca locks its user-data-dir when `--serve` starts. Rewriting Orca's
  per-agent env mid-session is therefore invisible to it. With no key at
  boot, Orca's `agentDefaultEnv.opencode` carries **no** OpenRouter entries
  at all, so a dispatched opencode worker gets no credential — even after a
  guard exists.
- `config/opencode/opencode.json` hardcodes `baseURL` to the guard loopback
  and takes `apiKey` from `{env:OPENROUTER_API_KEY}`, i.e. from whatever env
  the terminal is launched with.
- `orca terminal create --worktree <sel> --title <t> --command <c> --focus`
  opens a real, visible, focused tab. Verified live: created a tab titled
  "OpenRouter sign-in", its command ran (`preview` showed the output),
  `terminal list` reported `writable: true`, and `terminal close --tab`
  removed it.
- `z-ai/glm-5.3-flash` is the real OpenRouter slug (`Z.ai: GLM 5.3 Flash`).
  Its endpoints include DeepInfra, CoreWeave, Fireworks, Together, Parasail,
  BaseTen, DigitalOcean and Venice — all on `provider-policy.json`'s allow
  list — while `z-ai` itself is denied. So the worked example routes to a
  permitted provider under the existing no-China rule, with no policy edit.

## The design

**Readiness, not optimism.** A new `tier_openrouter_ready` helper answers
one question: can an OpenRouter worker actually run right now? True when the
guard's token file exists and its port answers, or when `OPENROUTER_API_KEY`
is set. Nothing else counts — a key file that has not reached a guard is not
readiness.

**The bind still binds.** `/tier worker openrouter:…` with no credential
saves the binding and says, in the same breath, that it cannot run yet and
exactly which command fixes it. Refusing the bind would lose the user's
stated intent over a condition that takes ten seconds to clear.

**Auth happens in a tab.** `/tier auth openrouter` opens a focused Orca tab
running `scripts/openrouter-auth.sh`: it prints where to get a key, reads it
with `read -rs` so it never lands in scrollback, validates it against
`GET https://openrouter.ai/api/v1/key`, writes
`.claude-dev/home/.openrouter.key` mode 600 (the same file the Mac side
uses, so it survives the next restart), starts the guard on the normal port
if one is not already up, and prints the `/tier` line to run next. If Orca
is unreachable it prints the command to run by hand rather than failing.

**Dispatch carries the credential.** Because Orca's env seed is frozen at
boot, `orca-dispatch` composes opencode/codex terminal commands with the
guard token and base URL taken from `.claude-dev/run/`, so a worker
authenticated mid-session works without restarting Orca.

## Slices

- **S1** `tier_openrouter_ready` + `tier-set` guidance on an `openrouter:`
  bind. CHECK: bind with no guard prints the not-authenticated block naming
  `/tier auth openrouter`, still writes the binding, exits 0.
- **S2** `scripts/openrouter-auth.sh`. CHECK: rejects a malformed key without
  writing anything; on a validator that says 200, writes the key file 600 and
  starts a guard that answers on its port; never echoes the key.
- **S3** `tier-set auth openrouter` opens the tab. CHECK: with Orca reachable
  a titled focused terminal is created; with Orca unreachable it prints the
  manual command and exits 0.
- **S4** `orca-dispatch` injects guard env into opencode/codex terminals.
  CHECK: the composed command carries `OPENROUTER_API_KEY`/`OPENROUTER_BASE_URL`
  when a guard token exists, and is unchanged when it does not.
- **S5** Docs: the worked GLM 5.3 Flash example in the `/tier` command help
  and README.

FROZEN for every slice: `config/provider-policy.json` — the allow list is the
user's rule, not this feature's to touch.
