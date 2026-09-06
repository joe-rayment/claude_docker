# Data residency: no request routes to China

The user's rule (2026-09-06): **their data never routes to China.** This
template builds that rule in rather than relying on anyone remembering it.
This page is the map of where it is enforced and how to check it.

## Why the model name is not enough

On OpenRouter a model id such as `z-ai/glm-5.3` says nothing about *where*
the prompt is processed. The same model is served by many providers, and
for GLM those include China-based hosts (Z.AI itself, Baidu, Alibaba,
SiliconFlow, StreamLake) next to US and EU ones. OpenRouter picks among
them by price and load unless the request says otherwise. So the thing to
pin is the **provider set**, and it has to be pinned somewhere no client
config can undo it.

## The three pieces

1. **`config/provider-policy.json`** is the policy: a default-deny allowlist
   of provider slugs, each with the country it processes requests in, an
   explicit `deny` list with a reason per entry, and the request shape the
   guard forces (`allow_fallbacks: false`, `data_collection: "deny"`). Its
   `_doc` block names the OpenRouter provider-routing fields it drives.
   A provider whose hosting country cannot be established is *not* allowed:
   absence of evidence is denial.

2. **`scripts/container/openrouter-guard.py`** is the chokepoint: a
   python3 stdlib proxy on `127.0.0.1:4141` that is the only process in
   the VM holding the real `OPENROUTER_API_KEY`. For every completion
   request (`/api/v1/chat/completions`, `/completions`, `/responses`,
   `/messages`) it rewrites the body's `provider` object to
   `{only: <allowlist>, allow_fallbacks: false, data_collection: "deny"}`.
   A client-supplied `provider.order` survives only when every entry is on
   the allowlist; otherwise it is dropped and the drop is logged. The guard
   refuses any request that does not carry its token with 401, swaps the
   token for the real key, forwards to `openrouter.ai`, and streams the
   answer back (SSE included). Every request is one JSON line in
   `.claude-dev/run/openrouter-guard.log`
   (`ts`, `path`, `model`, `providers_forced`, `client_order_dropped`, `status`).

3. **Clients never see the key.** Agent terminals get the guard token in
   `OPENROUTER_API_KEY` and the guard's loopback URL as base URL:
   `config/opencode/opencode.json` sets
   `provider.openrouter.options.baseURL`, and `scripts/delegate.sh` points
   its opencode and codex OpenRouter routes at the same URL
   (`OPENROUTER_GUARD_URL` overrides it). A leaked client config therefore
   cannot reach OpenRouter at all, let alone bypass the policy.

## The default stack

With an OpenRouter key present (the env var, or
`.claude-dev/home/.openrouter.key` from `claude-dev key openrouter`), a plain
`/tier <top>` derives the worker as **orca + opencode +
`openrouter/z-ai/glm-5.3`**: Fable orchestrates, the most capable GLM
executes, and the guard decides who serves it. Recon stays a Claude Haiku
subagent and the checker inherits the session model. Without a key the
worker is the Claude rung as before. `/tier worker claude:<model>` and the
explicit 2- or 3-argument pins are explicit requests for a Claude model and
are never overridden by the key. `/tier` (tier-prime) shows the bound
worker as `orca:opencode:openrouter/z-ai/glm-5.3`.

## Allowlist (verified 2026-09-06)

Slugs are the `tag` prefix in `GET /api/v1/models/<model>/endpoints`,
cross-checked against `GET /api/v1/providers` (headquarters, datacenters).

| Slug | Country | | Slug | Country |
|---|---|---|---|---|
| amazon-bedrock | US | | google-vertex | US |
| azure | US | | groq | US |
| baseten | US | | mistral | FR |
| cerebras | US | | nebius | NL |
| coreweave | US | | parasail | US |
| crusoe | US | | together | US |
| deepinfra | US | | venice | US |
| digitalocean | US | | fireworks | US |

Denied: `z-ai`, `baidu`, `alibaba`, `siliconflow`, `streamlake` (China);
`novita`, `atlas-cloud`, `gmicloud`, `phala`, `chutes`, `inceptron`,
`ambient` (hosting not verifiable, or decentralised compute). `lambda` and
`hyperbolic` are no longer in the OpenRouter registry and are not listed.

## Belt and braces on openrouter.ai

The guard is the enforcement. The user's own account settings on
openrouter.ai are a second, independent layer: under Settings, add the
denied providers to *Ignored providers* and turn on *deny data collection*.
Neither the template nor any agent can do this; it is an account setting.

## How to check it

- `bats tests/openrouter-guard.bats` starts the real guard against a stub
  upstream and asserts on the bytes that would have left the VM: the forced
  `provider` object on all four paths, the dropped order plus its log line,
  an SSE body relayed byte-for-byte, and 401 on every non-token key
  (including the real key). It reads the allowlist from the shipped policy,
  so guard and policy cannot drift apart silently.
- `bats tests/tier-hooks.bats` covers the tier default with and without a
  key, and the explicit overrides.
- In a running VM: `jq . .claude-dev/run/openrouter-guard.log` shows every
  request with `providers_forced: true`; a `client_order_dropped: true` line
  means a client asked for a provider outside the allowlist and did not get
  it.

## Changing the policy

Edit `config/provider-policy.json` only. Every `allow` entry needs a `slug`
and a `country`; the guard refuses to start on an empty allowlist or an
entry without a country. Keep `allow` and `deny` disjoint; the policy test
asserts both. Re-verify a slug against the registry before adding it: a
slug OpenRouter does not know is silently ignored inside `provider.only`.
