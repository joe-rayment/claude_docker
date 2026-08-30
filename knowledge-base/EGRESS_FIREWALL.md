# Egress Firewall: opt-in default-deny OUTPUT, off everywhere by default

When to use: deciding whether/how to lock down this container's outbound
network to only the services it actually needs (matching the default-deny
egress firewall the official Anthropic devcontainer ships), or debugging why
`--dry-run` shows a rule you didn't expect.

## What it is

`scripts/egress-firewall.sh` (staged at `/usr/local/bin/egress-firewall.sh`)
builds a default-deny `iptables` `OUTPUT` policy that allows only:

- loopback
- established/related connections
- DNS (UDP+TCP/53)
- HTTPS (443) to the current A records of an explicit allowlist:
  `api.anthropic.com`, `claude.ai`, `statsig.anthropic.com`, `sentry.io`,
  `github.com`, `api.github.com`, `objects.githubusercontent.com`,
  `raw.githubusercontent.com`, `registry.npmjs.org`, `pypi.org`,
  `files.pythonhosted.org`

Everything else outbound is dropped.

## It is OFF everywhere by default

Nothing in this repo enables the firewall on its own. `scripts/entrypoint.sh`
only invokes it when `CLAUDE_DEV_FIREWALL=1` is set in the container's
environment, and even a failed/refused apply under that flag only logs a
warning (`dev-log error`) — it never aborts container startup. A wrong
allowlist must never brick the container.

To opt in, set `CLAUDE_DEV_FIREWALL=1` for the container (e.g. in
`.claude-dev/docker-compose.override.yml`'s `environment:`) **and** grant the
capability the apply path requires:

```yaml
cap_add:
  - NET_ADMIN
```

Without `NET_ADMIN`, a real apply refuses outright (see below) rather than
half-applying a policy this process can't actually enforce.

## Usage

```bash
egress-firewall.sh --dry-run   # print the rules; touches no live iptables state
egress-firewall.sh             # apply for real; requires CAP_NET_ADMIN
```

`--dry-run` is always safe to run, with or without the capability — it never
calls `iptables`, so it's the way to inspect the policy before opting in.

## Refusal path

Without `CAP_NET_ADMIN`, running it for real (no `--dry-run`) exits nonzero
with a clear message instead of attempting a doomed `iptables` call:

```
$ egress-firewall.sh
egress-firewall: refusing to apply -- CAP_NET_ADMIN is not available to this process.
Run the container with --cap-add NET_ADMIN, or use --dry-run to preview the rules.
```

The check reads `CapEff` from `/proc/self/status` and tests bit 12
(`CAP_NET_ADMIN`, `linux/capability.h`) — no extra dependency on `capsh` or
`getpcaps`, which aren't guaranteed installed.

## Known limitation: only port 443 is allowlisted

Each host is resolved (`dig +short A`) and allowlisted for TCP/443 only.
Git-over-SSH to `github.com` (port 22) is not covered — this container's
`gh`/git usage is HTTPS-based, so that wasn't added; widen `apply_rules()` in
`scripts/egress-firewall.sh` if a workflow here starts needing it.

## Environment limitation: live apply is untestable in-container

This dev container itself has no `CAP_NET_ADMIN` (confirmed: `/proc/self/
status`'s `CapEff` reads all-zero here), so `tests/egress-firewall.bats` can
only drive the script as far as the refusal path — the same real refusal a
host running without `--cap-add NET_ADMIN` would see. `--dry-run` and that
refusal path are the full testable surface in-container; verifying a live
apply (rules actually block/allow the right traffic) needs a host opt-in run
with the capability granted.
