# Activity panel: a one-page, plain-English view of what Claude Code is doing

Asked for 2026-10-17: a panel beside Claude Code (in Ghostty) that says, in
brief plain English, what the work in front of you has done and what comes
next -- most useful when an executor has been running for 10-20 minutes.
Written by a cheap model; a lag of a minute is fine. One page for whatever
is current, zero scrolling, never exhaustive, and it knows when to clear:
when the work moves on, the page starts over.

## What it is

- `activity` -- a command inside the container (bin/activity). Run it in
  any split and leave it open; it redraws a full screen in place and never
  scrolls. A Ghostty key (cmd+shift+a, from the `claude-dev ghostty`
  include) opens a split on the right and starts it.
- Nothing to turn on. It reads what Claude Code already writes; no hook, no
  daemon. The summaries are made only while a panel is open, so a folder
  nobody is watching costs nothing.

## Sources (read-only)

- This folder's Claude Code sessions: `$(claude_config_dir)/projects/<slug>/`
  -- `<session>.jsonl` (the main loop) and `<session>/subagents/agent-<id>.jsonl`
  with `agent-<id>.meta.json` (agentType, description, model) for every
  executor/scout the session spawned. Slug = the project path with `/` -> `-`.
- Headless workers: `.claude-dev/run/workers/<job>/job.json` (state, pid),
  `spec.md`, `log.jsonl` (claude stream-json or opencode JSON events).
- "Running" = written to in the last 2 minutes (a worker: state running and
  its runner pid alive). "Just finished" = went quiet with a final message,
  shown as one line for 10 minutes, then dropped.

## What is current, and when the page clears

The page is about the current unit of work: the newest user request in the
most recently active session, plus every executor/worker running for it.
It starts over when a new user request arrives, and an executor's section
collapses to one "finished" line when it ends. Between those, each refresh
hands the model the previous page and the new events and tells it to keep
what is still true, drop what is no longer current, and start fresh if the
work has moved on.

## Digest -> model -> page

1. Digest (deterministic, stdlib python): per running source, the task (the
   executor's prompt/description, trimmed), elapsed time, model, and its last
   ~40 events condensed to one short line each (what it said, which tool on
   what, ok/failed). Key-shaped strings are redacted before anything leaves
   (sk-or-, sk-ant-, ghp_/gho_/github_pat_, Bearer ..., long base64). Capped
   at ~8k tokens.
2. Model: one chat completion through the OpenRouter guard (OPENROUTER_BASE_URL
   + the guard token -- the same residency policy as every worker route), with
   the cheap scout model from config/delegate-routes.json (glm-flash) unless
   claude-orca.json names another (`activityModel`). The prompt fixes the
   shape and the budget: at most the panel's rows-2 lines of its width; for
   each running executor "Done / Now / Next" in a sentence each; no paths
   unless they matter, no jargon, no lists of every step.
3. Page: `.claude-dev/run/activity/page.md` (atomic write) + `meta.json`
   (updated, model, tokens). The viewer hard-truncates to the screen, so even
   a disobedient model cannot make it scroll.
- Cadence: while a panel is open, a refresh when something changed and the
  last one is 60 s old, immediately (but not within 20 s of the last) when a
  request starts or an executor starts/finishes. One summarizer at a time
  (flock), so two panels share one page and one bill. Measured cost goes to
  `calls.log`; expected well under a cent per 20-minute executor.
- No guard / no key / `"activity": false` in claude-orca.json / the call
  fails: the page is the deterministic digest headline (task, elapsed, last
  action per source) with one line saying why there is no summary. Errors
  back off 5 minutes.

## Slices (beads under the epic)

- P1 digest: scripts/activity-digest.py -- sources, running/finished, current
  unit, condense, redact; bats with fixture transcripts shaped like the real
  ones; a real run against this folder's live transcripts.
- P2 summarize: the guard call, prompt, budget enforcement, page/meta, lock,
  backoff, fallback; bats against a fake guard (request shape, no secret in the
  body, budget kept); one real call through a real guard.
- P3 viewer: bin/activity -- full-screen redraw, wrap + truncate, footer
  ("updated 40 s ago · glm-flash · q quits"), resize, quit restores the
  terminal, drives P2 on the cadence; `--frame --rows R --cols C` prints one
  frame for tests.
- P4 Ghostty key + docs: the include file's cmd+shift+a chain (new_split:right,
  then text:activity) with the version stamp bumped so `claude-dev ghostty`
  refreshes it; README and knowledge-base/TERMINAL.md paragraphs.
- Check: the panel open in a real pty beside real executors in this session,
  rendered and screenshotted; the frame fits 24x80 with no line over 80.
