# Knowledge base

Reference material for working inside this template. Each page answers one
class of question; the rulebook (`config/claude-user-memory.md`, synced to
the agent's `CLAUDE.md`) carries the short policy version and points here for
the details. Start with [../README.md](../README.md) for setup and daily use.

## The sandbox and the host

| Page | Read it when |
|---|---|
| [SANDBOX.md](SANDBOX.md) | You need the trust boundary, the write/read/network scope, what the 13 self-test probes assert, or how to audit the generated Seatbelt profile. Also: the bash 3.2 rule every script here obeys. |
| [ORCA_INTEGRATION.md](ORCA_INTEGRATION.md) | Status dots or sub-agent rows stopped moving, the session-history panel is empty, worktrees land somewhere unexpected, or you are considering the opt-in Orca CLI mode. |
| [CONFIG_SYNC.md](CONFIG_SYNC.md) | A hook, agent, command or skill is missing or stale in a project; you want a local override that survives; you want to know where `/tier` state actually lives. |
| [TEARDOWN_RECOVERY.md](TEARDOWN_RECOVERY.md) | Before `claude-dev --teardown` or `--uninstall`, and when restoring beads from a snapshot afterwards. |

## Orchestration

| Page | Read it when |
|---|---|
| [TIERED_ORCHESTRATION.md](TIERED_ORCHESTRATION.md) | Choosing models for orchestrator / executor / scout / verifier, debugging `/tier`, or reasoning about cost. The long one — skim the headings. |
| [ACCEPTANCE_CONTRACTS.md](ACCEPTANCE_CONTRACTS.md) | Writing a `CHECK`/`PASS-IF`/`FROZEN`/`CLASS` contract on a bead, or running the verifier's five checks against a `RED-AT`/`GREEN-AT` pair. |
| [DELEGATION_ROUTES.md](DELEGATION_ROUTES.md) | Dispatching a slice onto an external model (`delegate run --route …`), reading a receipt, or debugging a `delegate check` reason. |

## Hooks, transcripts, issues

| Page | Read it when |
|---|---|
| [HOOK_AUTHORING.md](HOOK_AUTHORING.md) | Writing or debugging a Claude Code hook — the JSON contract, exit codes, and the portability traps. |
| [TRANSCRIPT_FORENSICS.md](TRANSCRIPT_FORENSICS.md) | Reconstructing what an agent actually did from the session transcripts, including sub-agent files. |
| [BEADS_TROUBLESHOOTING.md](BEADS_TROUBLESHOOTING.md) | `bd` misbehaves: a database holding 0 issues, a missing `issue_prefix`, a hung `bd edit`, sync trouble. |
