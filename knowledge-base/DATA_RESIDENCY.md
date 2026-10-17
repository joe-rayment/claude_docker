# Data residency: requests are served in the US, Canada or Europe

The user's rule, written 2026-09-06 as **"my data never routes to China"**
and restated 2026-09-20 as what it always meant: **a request may only be
served in the United States, Canada or Europe.** This template builds that
rule in rather than relying on anyone remembering it. This page is the map
of where it is enforced and how to check it.

The restatement is not a relaxation. Every provider the old wording allowed
is still allowed; what changed is that the boundary is now written down as
a list of countries and checked by the guard, instead of living in whoever
last curated the provider rows.

## The model is not the question; the host is

Chinese *models* are wanted here — GLM is the default worker rung, with
Qwen, DeepSeek and Kimi behind it — and nothing in this rule is about them.
On OpenRouter a model id such as `z-ai/glm-5.3` says nothing about *where*
the prompt is processed. The same model is served by thirty-odd providers,
and for GLM those include China-based hosts (Z.AI itself, Baidu, Alibaba,
SiliconFlow, StreamLake, Tencent) next to US and European ones. OpenRouter
picks among them by price and load unless the request says otherwise. So
the thing to pin is the **provider set**, and it has to be pinned somewhere
no client config can undo it.

## The four pieces

1. **`allowed_countries` in `config/provider-policy.json`** is the rule
   itself, in machine-readable form: `US`, `CA`, and Europe (EU-27 + EEA +
   Switzerland + the UK). Widening the residency boundary means editing
   that one list, which is the line a human reviews. China is denied as a
   consequence of not being on it — and so is Singapore, which is where
   several Chinese operators' registry entities sit.

2. **The rest of `config/provider-policy.json`** is the allowlist a
   default-deny guard forces: provider slugs, each with the country it
   processes requests in, an explicit `deny` list with a reason per entry,
   and the request shape the guard forces (`allow_fallbacks: false`,
   `data_collection: "deny"`). A provider whose hosting country cannot be
   established is *not* allowed: absence of evidence is denial.

3. **`scripts/container/openrouter-guard.py`** is the chokepoint: a
   python3 stdlib proxy on `127.0.0.1:4141` that is the only process in
   the VM holding the real `OPENROUTER_API_KEY`. At startup it refuses to
   run on a policy whose allow list reaches outside `allowed_countries`,
   names no countries at all, allows a provider with no country note, or
   has an empty allow list. For every completion request
   (`/api/v1/chat/completions`, `/completions`, `/responses`, `/messages`)
   it rewrites the body's `provider` object to
   `{only: <allowlist>, allow_fallbacks: false, data_collection: "deny"}`.
   A client-supplied `provider.order` survives only when every entry is on
   the allowlist; otherwise it is dropped and the drop is logged. The guard
   refuses any request that does not carry its token with 401, swaps the
   token for the real key, forwards to `openrouter.ai`, and streams the
   answer back (SSE included). Every request is one JSON line in
   `.claude-dev/run/openrouter-guard.log`
   (`ts`, `path`, `model`, `providers_forced`, `client_order_dropped`, `status`).

4. **Clients never see the key.** Agent terminals get the guard token in
   `OPENROUTER_API_KEY` and the guard's loopback URL as base URL:
   `config/opencode/opencode.json` sets
   `provider.openrouter.options.baseURL`, and `scripts/delegate.sh` points
   its opencode and codex OpenRouter routes at the same URL
   (`OPENROUTER_GUARD_URL` overrides it). A leaked client config therefore
   cannot reach OpenRouter at all, let alone bypass the policy.

## The default stack

With an OpenRouter key present (the env var, or
`.claude-dev/home/.openrouter.key` from `claude-dev key openrouter`), a plain
`/tier <top>` derives the worker as **headless + opencode +
`openrouter/~z-ai/glm-latest`** (a background `opencode` run, not an
in-process sub-agent): Fable orchestrates, the newest GLM
executes, and the guard decides who serves it. Recon stays a Claude Haiku
subagent and the checker inherits the session model. Without a key the
worker is the Claude rung as before. `/tier worker claude:<model>` and the
explicit 2- or 3-argument pins are explicit requests for a Claude model and
are never overridden by the key. `/tier` (tier-prime) shows the bound
worker as `headless:opencode:openrouter/~z-ai/glm-latest`.

## The OpenAI subscription path (2026-10-02)

opencode's ChatGPT sign-in adds a second provider, and this one needs no
policing: an `openai/…` model's traffic goes from opencode straight to
OpenAI — `chatgpt.com`'s codex endpoint for the model calls,
`auth.openai.com` for the OAuth token dance — and OpenAI itself serves
every request, in the US, which is inside `allowed_countries`. There is no
provider choice to pin, so there is no guard on this path and no entry in
`config/provider-policy.json`: that file governs OpenRouter only and is
unchanged. The credential never passes through the guard either — it lives
in opencode's own auth store
(`~/.local/share/opencode/auth.json`), read and refreshed by opencode
itself.

## Allowlist (verified 2026-09-06, re-read 2026-09-20)

Slugs are the `tag` prefix in `GET /api/v1/models/<model>/endpoints`,
cross-checked against `GET /api/v1/providers` (headquarters, datacenters).

| Slug | Country | | Slug | Country |
|---|---|---|---|---|
| amazon-bedrock | US | | groq | US |
| azure | US | | inceptron | SE |
| baseten | US | | mistral | FR |
| cerebras | US | | nebius | NL |
| coreweave | US | | nextbit | ES |
| crusoe | US | | parasail | US |
| deepinfra | US | | together | US |
| digitalocean | US | | venice | US |
| fireworks | US | | | |
| google-vertex | US | | | |

`inceptron` (Swedish company, Finnish datacenter) and `nextbit` (Spanish
company, Spanish datacenter) joined on 2026-09-20 — admitted by the country
rule rather than by a fresh judgement call, which is the point of writing
the rule as a country list. No Canadian provider is in the OpenRouter
registry today; one would qualify on the same terms the day it appears.

Denied and named, with a reason each: `z-ai`, `baidu`, `alibaba`,
`siliconflow`, `streamlake`, `tencent`, `xiaomi`, `nex-agi`, `deepseek`
(China); `moonshotai`, `seed` (Singapore entities of Chinese operators);
`novita`, `atlas-cloud`, `gmicloud`, `sail-research`, `near-ai`, `makora`,
`reka`, `relace`, `wafer`, `friendli`, `morph`, `decart`, `modal`,
`cloudflare`, `ambient` (hosting not establishable from the registry); and
`phala`, `chutes`, `io-net`, `akashml`, `inference-net` (decentralised
compute — the physical host of any one request is not knowable in advance).
`lambda` and `hyperbolic` are no longer in the OpenRouter registry and are
not listed. The `deny` list is documentation of *why*: with `provider.only`
set to the allowlist, everything not on it is already excluded.

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
  (including the real key). It also asserts the policy's own shape — every
  allow row inside `allowed_countries`, `US`/`CA`/Europe in that list and
  `CN` not — and that the guard refuses to start on a policy that breaks
  either. It reads the allowlist from the shipped policy, so guard and
  policy cannot drift apart silently.
- `bats tests/tier-hooks.bats` covers the tier default with and without a
  key, and the explicit overrides.
- In a running VM: `jq . .claude-dev/run/openrouter-guard.log` shows every
  request with `providers_forced: true`; a `client_order_dropped: true` line
  means a client asked for a provider outside the allowlist and did not get
  it.

## Changing the policy

Edit `config/provider-policy.json` only. Every `allow` entry needs a `slug`
and a `country`, and that country has to be in `allowed_countries`; the
guard refuses to start otherwise, and on an empty allowlist, a missing
`allowed_countries`, or an `order` naming a provider outside `allow`. Keep
`allow` and `deny` disjoint; the policy test asserts both. Re-verify a slug
against the registry before adding it: a slug OpenRouter does not know is
silently ignored inside `provider.only`.

**A policy edit reaches a running folder only through the image.** The
guard loads the policy next to its own script — `/opt/claude-orca/config/`,
the copy baked into the image — and never from the project tree, because
the project tree is writable by the agents the guard exists to police. So
an edit here takes effect on the next container start *after* the image is
rebuilt at this commit; the folder's `.claude-dev/template` clone and the
running guard both keep the old policy until then. That is the intended
direction of trust, not a gap to close.
