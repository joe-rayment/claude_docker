#!/usr/bin/env bash
# bd-guard — PreToolUse(Bash) hook: keep beads Claude-only.
#
# Beads are Claude Code's own task memory. A bead assigned to a human, or
# describing work the user must do ("ask Joe", "waiting for user review"),
# violates the Ownership rule in CLAUDE.md: questions go to chat, decisions
# are asked in conversation, and every bead stays Claude-owned work.
#
# Routing a bead to a person is not only a literal --assignee: bd also ships
# structural "blocked pending a human" primitives (a human-type gate is the
# *default* `bd gate create` behavior; the reserved `human` label is the
# literal mechanism `bd human list` uses to surface issues to a person) that
# are just as much an assignment as --assignee, wearing a different hat. This
# hook enforces that at the point of creation:
#   - HARD block (no override): bd create/update/assign with a non-agent
#     assignee; the `human` label via --labels/--label/--add-label/
#     --set-labels/-l/`bd tag`/`bd label add`/`bd label propagate`/`bd q -l`;
#     a `bd gate create` left at its default type or explicit `--type=human`
#     (timer/gh:run/gh:pr gates are unaffected — they resolve automatically,
#     not via a person); the bare `bd human <id>` form (its real subcommands
#     -- list/respond/dismiss/stats -- are unaffected).
#   - SOFT block (override with BD_GUARD_ALLOW=1): user-directed phrasing in
#     the bead text; a bead moved to `blocked` status with text describing a
#     person's decision (failure shape 2 — indirect routing via status
#     instead of --assignee); `bd init --reinit-local`/`--force`/
#     `--discard-remote` when `.beads/issues.jsonl` has uncommitted changes
#     (can delete the passive export that is the only rebuild path for the
#     database — beads_claude_docker-o15). Override is for false positives
#     only — e.g. the phrase is quoted content or code under discussion, or
#     the jsonl really is backed up some other way — never to park user work
#     in a bead or skip a real backup. The override is honored two ways: an
#     exported BD_GUARD_ALLOW=1 in the hook's environment, OR a literal
#     `BD_GUARD_ALLOW=1 ` assignment written as a prefix on the command
#     string (the form the block message suggests — it never reaches this
#     process's environment, so we detect it in the command text and apply
#     it ourselves).
#
# Bypass resistance: every rule runs against a *normalized* view of the
# command, not the raw string. Tabs are folded to spaces (so a tab between a
# flag and its value can't hide it), and command-position noise — leading
# environment assignments (`FOO=1 bd …`) and wrapper words (`command bd …`,
# `env bd …`, `nohup bd …`) — is stripped so `bd` is exposed at a command
# position for the anchors below. This closes the column-0/`;&|(`-only anchor
# that previously let `  bd`, `command bd`, `FOO=1 bd`, and tab-separated forms
# slip past.
#
# Segment scoping (beads_claude_docker-v5p round 2): the label/gate/human/
# reinit rules below additionally split the normalized command into pseudo-
# segments on `;`, `&&`, `||`, `|`, and newline, and run per-segment. This
# closes bypasses where a flag/token that actually belongs to a *different*
# bd invocation (after a separator, or on another line) was being read as
# this one's — e.g. `bd gate create --blocks bd-1 && bd update bd-1 -t chore`
# no longer lets the second command's `-t chore` stand in for the first
# command's gate type. The split is deliberately NOT quote-aware; the soft
# rules further down (user-directed phrasing, residual-work-in-prose) stay
# whole-string on purpose instead of adopting it, since legitimate reason/
# description text may itself contain `;` or `|` as ordinary punctuation —
# fine for a "does this phrase appear" substring check, not for scoping a
# flag extraction.
#
# Probed-not-documented flag surface (beads_claude_docker-v5p round 3): round
# 2 above closed a bypass in the RULE LOGIC; this round closes one in the
# FLAG LIST itself, and the root cause is different — the label/assignee/
# gate/human flag spellings below were transcribed from `bd create/update/...
# --help`, but --help is a description of what bd's authors chose to publish,
# not of what bd's flag parser actually accepts. Bd 1.0.4 (ce242a879) was
# probed directly (never against this repo's own .beads — always in a
# throwaway sandbox project) for every spelling bd's parser honors, not just
# every spelling --help lists, across all seven subcommands these rules
# touch: `bd create` accepts an undocumented bare singular `--label` (space-
# or =-glued, comma-splittable exactly like `--labels`) as a fully working,
# HONOURED alias — a bead filed with only `--label human` really does end up
# with the label attached and surfaced by `bd label list`/`bd human list`,
# confirmed end to end. `bd update` and `bd q` reject the identical spelling
# (`Error: unknown flag: --label`) — bd's own parser, not this file, draws
# that line, so the fix below is create-specific in effect even though the
# pattern match itself stays verb-blind (see the comment at
# `label_flags_raw` for why that's still safe). Every other spelling tried
# came back rejected by bd itself, confirmed by running each candidate to
# completion rather than trusting --help's silence about it: `--assign`/`-A`/
# `--owner`/case variants for assignee on create/update; `--gate-type`/`-T`/
# case variants for `bd gate create`'s type; and a flag surface at all
# (`--label`, `--assignee`) on the four positional-only commands (`bd tag`,
# `bd label add`, `bd label propagate`, `bd assign`), which really do take
# only positional arguments as documented. Two adjacent gaps were found here
# and were, at the time, DELIBERATELY left untouched, since neither is a
# label/assignee/gate/human routing mechanism and both live on a verb outside
# this rule block's scope: `bd close` has a `done` alias that IS shown in `bd
# close --help`'s own Aliases line (unlike --label, not even a --help-vs-
# reality gap) but was absent from this file's bd-verb alternation everywhere
# it's used; and `bd close`/`bd create` separately carry several further
# hidden aliases for --reason/--description (`-m`, `--resolution`,
# `--comment`). Both are now CLOSED (beads_claude_docker-j72): see the verb
# alternation below (now includes `done`, at every site including the
# close-only residual-work-in-prose rule, which needed its own separate fix
# since it re-anchors on `close` independently of the gate above) and the
# masked_cmd flag-list comment further down (now includes `-m`/`--message`/
# `--resolution`/`--comment`/`--body`, plus one more hidden alias the bug
# report that opened j72 hadn't named — `--message` on create as well as
# close, and `-m` on `bd update` too — found only by empirically re-probing
# rather than stopping at the two spellings already reported, per that bead's
# own root-lesson warning not to trust even a prior finding as complete).
#
# Shell-wrapper unwrapping (beads_claude_docker-vgr): a string matcher never
# sees `bd` inside `bash -c "bd create ... -a joe"` or `eval '...'` — the
# payload sits behind a quote character, not one of the `;&|(){` separators
# every anchor above requires. Rather than duplicate the rule logic against a
# second, wrapper-shaped grammar, scan_cmd() below extracts the payload and
# RECURSES on itself (bounded by MAX_UNWRAP_DEPTH), so the same hard/soft
# rules apply to whatever is actually going to run for every wrapper SHAPE
# this recursion reaches — including through SOME nested wrapping, e.g.
# `bash -c "eval '...'"` (confirmed: BLOCKED), since each recursive call
# re-runs the same unwrap step. This does NOT extend to every nested-
# wrapping shape (beads_claude_docker-j72, doc-correctness pass, round 2 —
# corrects an unqualified claim that used to sit here): it cascades only
# when the inner payload's quotes differ in type from the outer's, or are
# otherwise unescaped, the way the `eval '...'` example above is. It does
# NOT cascade when the inner payload instead escapes a SAME-type quote
# against its wrapper (`bash -c "bash -c \"bd create x -a joe\""` and
# siblings) — see KNOWN LIMITATIONS below for the mechanism. Nor does it
# reach every OTHER shape a real shell can construct: see KNOWN LIMITATIONS
# below for the remaining residual classes (stdin-fed payloads, single-quote
# concatenation, command substitution, variable indirection) this recursion
# never sees, and why. `xargs` is handled without recursion (folded into the
# wrapper-word strip list below) since it passes its own literal argv
# straight through to the child. File indirection (--body-file,
# --design-file, -f, --graph, --stdin/-) is deliberately OUT OF SCOPE: see
# the scope table in tests/bd-guard.bats and the bead for the full rationale
# (format mismatch — those flags need a markdown/JSON issue-format parser,
# not a reuse of this shell-token rule engine; TOCTOU; and a new file-I/O
# fail-open surface disproportionate to this slice).
#
# Quote-aware masking (beads_claude_docker-vgr, closing slice): the scanner
# above was not quote-aware — it read prose INSIDE a quoted flag value (e.g.
# -d "example: bd create x -a joe") as if it were real command syntax, which
# made it impossible to file a bead whose own text quotes a prohibited flag,
# and let a wrapper-shaped example inside such a value (-d "... (bash -c
# '...') ...") get extracted as if it were a real wrapper. masked_cmd blanks
# the CONTENT of quoted values of the free-text fields (-d/--description,
# --title, --notes, --design, --acceptance, -r/--reason) and feeds every
# structural extraction site (segments, assignee, labels, gate --type, bare
# `bd human`, wrapper-candidate filtering) — never the prose soft rules,
# which must keep reading exactly that text. See the masked_cmd comment
# where it's computed in scan_cmd() for the full detail, including why bare
# -t is deliberately excluded and how the wrapper-candidate filter avoids
# turning a real `bash -c "... -d 'ask Joe'"` evasion into a silent bypass.
#
# Argv-wrapper hardening, round 3 (bd-guard hardening slice): an
# independent check found the mechanisms above still missed
# plain accidental-shape argv wrappers, not the contrived multi-decoy chains
# the bounds elsewhere in this file guard against: leading wrapper words
# outside the original short list (`timeout 10 bd …`, `stdbuf -o0 bd …`,
# `nice bd …`); `bd` itself disguised by a no-op backslash-escape or self-
# quoting (`\bd …`, `'bd' …`, `"bd" …`); and an interpreter-detection
# alternation narrower than the shells actually reachable in this image
# (`/usr/bin/env sh -c "…"` with env's path spelled out, `dash -c "…"` —
# dash IS /bin/sh here, `bash -O extglob -c "…"` — a flag cluster with a
# non-dash-prefixed option argument). All three are now covered (see the
# wrapper-word strip loop and the interpreter alternation below); a fourth,
# unrelated issue in the same audit — the per-candidate wrapper-extraction
# loops paying for a `sed`+`grep` subprocess pair per raw match BEFORE
# SCAN_NODE_COUNT ever got a chance to bound anything — is fixed by
# MAX_WRAPPER_CANDIDATES above. None of this closes the classes named in
# KNOWN LIMITATIONS below; those require deliberate shell-syntax knowledge
# to construct, not the kind of thing the fixes above address.
#
# KNOWN LIMITATIONS (accepted, not bugs — read this before assuming argv-
# wrapper evasion is fully closed): ten residual classes are NOT reached by
# the recursion/normalization above, each pinned in tests/bd-guard.bats so
# the gap is mechanically true, not just a claim in this comment:
#   - stdin-fed payloads: `bash <<< "…"`, `echo … | bash`, `bash -s`,
#     `source /dev/stdin` — the command text is real, but it arrives on the
#     interpreter's STDIN, not argv; this hook only ever sees the Bash tool's
#     command STRING, never a future stdin stream, so there is nothing to
#     extract even in principle.
#   - single-quote concatenation: `bash -c 'bd create x -d '\''n'\'' -a
#     joe'` — real shells concatenate adjacent quoted segments into one argv
#     word; this hook's payload-extraction regex has no such grammar, so it
#     stops at the FIRST embedded `'…'\'''` boundary and silently truncates
#     the recursed payload before the real violation.
#   - nested wrapping through an escaped or same-type inner quote (beads_
#     claude_docker-j72, doc-correctness pass, round 2 — also corrects the
#     unqualified "including through nested wrapping" claim that used to sit
#     in the header comment above, and the equally unqualified nested-
#     wrapping line in tests/bd-guard.bats's own wrapper scope table): the
#     recursion described in the header cascades through nested wrapping
#     only when the inner payload's quotes are a DIFFERENT type than the
#     outer's, or otherwise unescaped — `bash -c "eval '...'"` genuinely
#     cascades (confirmed: BLOCKED) because its single-quoted inner payload
#     needs no escaping inside the double-quoted outer one. It does NOT
#     cascade when the inner payload instead escapes a SAME-type quote
#     against its wrapper: `bash -c "bash -c \"bd create x -a joe\""`, `eval
#     "bash -c \"bd create x -a joe\""`, `bash -c "eval \"bd create x -a
#     joe\""`, `sh -c "sh -c \"bd create x -a joe\""`, and `bash -c "cd /tmp
#     && bash -c \"bd create x -a joe\""` are all real, confirmed bypasses —
#     a fake `bd` on PATH confirms the inner payload genuinely runs in every
#     case. The escape-aware payload CAPTURE in the candidate regex (where
#     candidates is built, below) correctly finds the outer span despite the
#     internal `\"` pairs, but the dequote step right after it strips only
#     the outermost quote pair (`s/^"(.*)"$/\1/`, mirrored at the bash/sh/zsh
#     -c unswallow retry and both eval sites) and never unescapes `\"` to
#     `"` — so the recursed depth+1 payload keeps its literal backslash-
#     quote characters (`bash -c \"bd create x -a joe\"`) instead of clean
#     text. One recursion level deeper, that payload's own wrapper-candidate
#     match needs the byte right after the interpreter's flag cluster to be
#     a BARE `"` or `'` — the flag-cluster character class itself excludes
#     both quote characters — so the literal `\` sitting there instead fails
#     the match outright, and the inner `bd create x -a joe` is never
#     extracted as a candidate at all.
#   - command substitution: `sh -c "$(echo bd create x -a joe)"` — `$(...)`
#     is evaluated by the real shell before -c ever sees the result; this
#     hook recurses on the literal, unevaluated source text instead, where
#     `bd` is an argument to `echo`, not a wrapper's own payload. A second,
#     narrower shape needs no wrapper and no hidden `bd` at all (beads_
#     claude_docker-j72, doc-correctness pass): `bd gate create --blocks
#     bd-1 --type "`echo human`"` is a real, fully-anchored `bd gate
#     create` — the gate-type rule finds it and extracts its --type value
#     correctly — but the extracted value is the literal, unevaluated text
#     `` `echo human` ``, which the rule's exact-match check (`= "human"`)
#     does not consider equal to `human`, even though the real shell
#     evaluates that backtick to exactly `human` before bd ever runs. Both
#     shapes share the same root cause (this hook has no shell evaluator)
#     applied to two different targets: an invocation's IDENTITY in the
#     first example, a flag's TRUE VALUE in this one. (A third example used
#     to sit in this same bullet — `X=$(bd create x -a joe)` — under this
#     same "no shell evaluator" explanation; it does NOT share that root
#     cause, and is now filed separately below with its own, corrected
#     mechanism.)
#   - env-assignment strip swallowing an adjacent `$(` (beads_claude_docker-
#     j72, doc-correctness pass, round 2 — corrects a mis-attribution:
#     `X=$(bd create x -a joe)` used to be filed under "command
#     substitution" above with the same "`bd` is not standing at command
#     position" explanation given for that bullet's own examples): `X=$(bd
#     create x -a joe)` bypasses, but not because `bd` fails to stand at
#     command position — `echo $(bd create x -a joe)` puts `bd` in the exact
#     same position (immediately after the `$(`, and `(` is itself one of
#     this file's own command-position anchor characters, `[;&|(){]`) and IS
#     blocked, which is direct evidence that command position is not what
#     differs between the two commands. The real cause is the env-assignment
#     strip that normalizes away a leading `FOO=` prefix
#     (`[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*`, where the normalization loop
#     is defined below): it has no notion of `$(...)` as a nested unit with
#     its own internal whitespace, so its greedy value-match simply runs to
#     the first whitespace it finds — which is INSIDE the substitution —
#     consuming `X=$(bd ` as one swallowed token before any anchor or rule
#     below ever runs. The literal characters `bd` are DELETED by this
#     normalization pass, not skipped over because of where they sit — an
#     ordinary regex-greediness bug in a normalization rule, not a case of
#     this hook lacking a shell evaluator.
#   - backtick absent from the per-verb command-position anchor (beads_
#     claude_docker-j72, doc-correctness pass): `bd create x -m "`bd tag
#     bd-1 human`"` is fully visible, unhidden text — once its value
#     contains a backtick the -m masking fix above correctly leaves it
#     UNMASKED, so `bd tag bd-1 human` sits in $masked_cmd as literal
#     characters, no evaluation required. But unlike the assignee/label-flag
#     extraction (which greps $masked_cmd for a flag shape anywhere, blind to
#     position), the tag / label add|propagate / gate create / human / init
#     rules must first locate WHICH bd invocation's own positional arguments
#     to read, via a verb-position anchor requiring `bd tag`/`bd gate
#     create`/etc. to sit at the string start or immediately after one of
#     `;&|(){` (`tag`) or whitespace/`{`/`(` (the other four, already
#     segment-scoped) — and backtick is in neither class. A backtick
#     immediately before `bd` is therefore an invisible command-position
#     boundary to exactly these five rules: this is NOT the command-
#     substitution class above (nothing here needs evaluating — the text is
#     already literal and final) and not the intra-word-quoting-of-`bd`
#     class below either (that one hides the bare word `bd` from the cheap
#     prefilter; this one hides a fully-prefiltered `bd`'s own verb from the
#     structural rule that would otherwise act on it). Previously mis-filed
#     under the command-substitution bullet above, whose stated mechanism —
#     "`bd` is not standing at command position" because the real shell
#     hasn't evaluated `$(...)`/backticks yet — does not describe this case
#     at all: no evaluation is needed here, and `bd gate create`'s OWN top-
#     level `--type "`echo human`"` two bullets up is a genuinely different
#     gap from this one despite both involving a backtick.
#   - variable indirection: `B=bd; $B create x -a joe` — the literal string
#     never contains `bd` immediately followed by a verb (the two are split
#     across an assignment and a variable reference), so even the cheap
#     verb-prefilter this hook starts with never engages.
#   - intra-word quoting/escaping of `bd` itself (bd-guard hardening slice,
#     round 4): `b\d create x -a joe` (backslash mid-word — a no-op the real
#     shell strips, unlike `\bd`, which round 3 already normalizes, this
#     backslash sits INSIDE the two letters, not before them); `'b'd create
#     x -a joe` (only "b" is quoted, "d" sits outside — a different shape
#     from the whole-word `'bd'` round 3 already normalizes); `bd'' create x
#     -a joe` (a real shell concatenates `bd` + the empty string back into
#     `bd`, so this genuinely runs it — but the literal text has `bd`
#     immediately followed by a quote character, not the whitespace every
#     rule in this file requires at that position); `bash -c $'bd create x
#     -a joe'` (ANSI-C `$'...'` quoting — a distinct quote FORM from the
#     `"..."`/`'...'` the wrapper-candidate extraction recognizes). None of
#     these four is reached by the wrapper-candidate grammar OR the `\bd`/
#     `'bd'`/`"bd"` normalization, both of which require `bd` to appear as a
#     COMPLETE, cleanly-delimited token — these deliberately construct a
#     token boundary the normalizer doesn't recognize as one.
#   - flag-VALUE quote/escape concatenation (beads_claude_docker-j72, doc-
#     correctness pass, round 2): the bullet just above is about quoting/
#     escaping `bd` itself; the exact same real-shell mechanics apply on the
#     VALUE side of a flag this hook DOES structurally check, and that is
#     not covered by that bullet at all. `bd create x --labels hu\man` and
#     `bd create x --labels "hu""man"` both bypass, and both really attach
#     the plain `human` label (confirmed live, fake `bd` on PATH): a real
#     shell strips the mid-word backslash in the first (a no-op escape) and
#     concatenates the two adjacent double-quoted segments in the second,
#     either way producing the argv word `human`. The label extraction
#     (where label_flags_raw is built, below) has no such grammar — it
#     captures the literal token as written (`hu\man`, or `hu""man` once its
#     own quote-stripping runs) — and the hard rule's comparison right after
#     it is an EXACT match against `human`, so neither literal token reads
#     as equal to the string it evaluates to. This is deliberately narrower
#     than it could be: the assignee rule shares the same bare-token
#     extraction shape but is NOT vulnerable the same way, because its check
#     is INVERTED (block anything NOT an allow-listed agent name) — a stray
#     backslash or quote pair in an assignee value still isn't
#     "claude"/"agent"/etc and still blocks with no change needed, the same
#     asymmetry already noted in the label_flags_raw comment for why a
#     trailing backtick doesn't threaten the assignee rule either.
#   - wrapper-flag arity-table gaps (bd-guard hardening slice, round 4): the
#     round-4 fix (below, where the normalization loop is defined) gives
#     `env`/`sudo` an explicit bare-flag/value-flag table and `time` its
#     lone `-p`, and extends the 8 numeric-arg words (`timeout`/`stdbuf`/
#     `setsid`/`nice`/`ionice`/`script`/`chrt`/`taskset`) to interleaved
#     flag+numeric-value/bare-numeric tokens — but every one of these is a
#     closed, explicitly-enumerated list, not real argument-parsing. A flag
#     outside the table leaves `bd` stranded behind it exactly like the
#     pre-round-4 bug, e.g. `sudo -E --preserve-env=PATH bd create x -a
#     joe` (`--preserve-env` takes an optional value only in its long form;
#     `-E` alone is bare — genuinely different arity depending on spelling,
#     deliberately left unmodeled rather than guessed at) or `env -S "-a
#     joe" bd create x -a joe` (`-S`/`--split-string` not in the table).
#     `command`/`builtin`/`nohup`/`exec`/`xargs` get NO flag grammar at all
#     (bare-word strip only, unchanged since round 3) — `command -p bd
#     create x -a joe` (bash's OWN `command -p` flag) is hidden the same
#     way. Widening these tables further trades one enumerable, auditable
#     gap for a larger one with the same shape; it was deliberately not
#     pursued past what round 4's own reported threats needed, per this
#     round's explicit "then we stop" scope.
# Threat model (see also the top of this file's bead): the "attacker" is
# Claude Code itself drifting toward a shortcut, not a determined adversary
# — this is a guardrail, not a sandbox. The FIRST NINE classes above require
# knowingly constructing shell syntax specifically to hide intent, which is
# a materially different act from typing `timeout 10 bd create x -a joe` or
# `nice bd create x -a joe` without thinking about it. Most would mean
# parsing real shell grammar to close (quote concatenation, command
# substitution, variable expansion) — a second, much larger rule engine,
# not an extension of this one — for a threat this hook is not designed to
# stop. The backtick-anchor gap above is the exception: mechanically it is
# a one-character widening of two character classes, not a grammar problem —
# left alongside the others this round because doing so would also make
# those same anchors recognize a backtick sitting inside a genuinely INERT
# single-quoted value (one whose enclosing quotes really are its own, not
# borrowed from an outer double-quoted wrapper — see the masked_cmd
# single-quote trade-off above, which this hook cannot locally distinguish
# from the live case either), and working through that interaction was not
# this round's scope. The TENTH (wrapper-flag arity gaps) is honestly
# different again: an uncommon-but-ordinary flag falling outside a finite,
# explicit table is not deliberate evasion, it is exactly the kind of
# accidental shape this hook IS designed to catch — it just doesn't, for
# that specific flag, until the table is widened. It's listed here rather
# than silently left out so a reader's picture of coverage stays accurate:
# wrapper-argument stripping is closed allowlists, not general argument
# parsing.
#
# KNOWN FALSE POSITIVES (accepted, not bugs — the mirror image of KNOWN
# LIMITATIONS above: this is the guard BLOCKING something that is actually
# safe, not failing to block something that isn't. The ten classes above are
# never REACHED by the recursion/normalization; the one class below IS
# reached, and mis-scanned). Decided deliberately among three options after
# this was hit while filing the fix for beads_claude_docker-j72 itself (see
# beads_claude_docker-egc for the full decision record), pinned in
# tests/bd-guard.bats:
#   - multi-line inline text — heredoc-carried or not — whose embedded
#     EXAMPLE of a bd invocation starts its own line: a `git commit` whose
#     MESSAGE documented a command-substitution example containing an
#     assignee flag was hard-blocked, with no override, because the
#     assignee rule is hard by design. Root cause is two ordinary
#     mechanisms compounding, neither one heredoc-specific: (1) every
#     command-position anchor in this file — `(^|[;&|(){])` for the
#     top-level/assignee checks, `(^|[[:space:]{(])` for the segment-scoped
#     label-add/gate-create/human checks — includes `^`, and grep/sed
#     process a multi-line string ONE LINE AT A TIME by default (no -z, no
#     N), so `^` matches the START OF EVERY LINE, not just the start of the
#     whole command — deliberate and desired for the general case (it's
#     exactly what lets the round-4 keyword-strip fix above catch a real
#     `do\nbd create x -a joe\ndone`, and it is EXACTLY as correct to catch
#     a real, live-executing `bash <<'EOF'` / `bash <<EOF` heredoc whose
#     body genuinely runs once bash reads it from its own stdin — confirmed
#     with a fake `bd` on PATH through a real shell: the body executes
#     regardless of whether the delimiter is quoted, since quoting only
#     suppresses expansion WITHIN the heredoc, never whether the consuming
#     command treats its content as code); (2) this file has no model of
#     heredoc — or any other multi-line value — syntax at all, so text that
#     is genuinely inert (literal prose in a commit message or a bead field,
#     handed to a data-consuming command like `cat`/`tee`/`git commit -F
#     -`/a plain `VAR=$(...)` assignment rather than an interpreter) gets
#     the exact same per-line treatment as real multi-line shell syntax the
#     instant one of its lines happens to start with `bd <verb>`. Once that
#     anchor fires anywhere in the text, the assignee extraction — unscoped,
#     not segment-limited like the label/gate/human rules — reads the whole
#     $masked_cmd for `-a`/`--assignee`, so an inert documentation line like
#     `bd create x -a joe` inside a heredoc-built commit message trips the
#     same hard rule a live one would.
#
#     Three options were weighed per the bead's own acceptance criteria; two
#     were rejected on EMPIRICAL grounds, not by argument — this file's own
#     standing lesson, after two masking regressions in a row (see the
#     CORRECTED / MIRROR-IMAGE REGRESSION paragraphs above), is to never
#     settle a quoting question by reasoning alone:
#       - "teach the scanner that a quoted heredoc delimiter makes its body
#         inert" (the seemingly-correct fix) is actually UNSOUND, not just
#         complex: a quoted delimiter (`<<'EOF'`, `<<"EOF"`, `<<\EOF`)
#         suppresses only shell EXPANSION inside the body, never whether the
#         body EXECUTES — that depends entirely on what consumes it, an
#         open-ended classification (bash/sh/zsh/dash/ash/ksh/eval/source vs.
#         cat/tee/git commit -F -/a plain assignment) layered on top of the
#         delimiter-parsing itself (`<<-` tab-stripping — cmd_tabs above
#         already folds tabs to spaces before any rule runs, which destroys
#         exactly the leading-tab evidence a `<<-` closing-line check would
#         need; quoted vs. unquoted vs. backslash-quoted delimiters; a
#         delimiter string reappearing inside the body; multiple/back-to-
#         back heredocs on one command). Confirmed empirically: `bash
#         <<'EOF'` with `bd create x -a joe` as its body has a QUOTED
#         delimiter, yet a fake-`bd`-on-PATH probe through a real shell
#         shows the body genuinely runs — and this exact shape is ALREADY
#         correctly blocked today by the accidental per-line mechanism
#         above. A mutation probe that unconditionally blanks quoted-
#         heredoc bodies (modeling this option done the naive way) fixes
#         the two heredoc-carried false positives pinned in
#         tests/bd-guard.bats but ALSO flips this live-executing case from
#         blocked to silently allowed — exactly the
#         "mis-parsed heredoc that swallows live text" the bead ranks worse
#         than the inconvenience being fixed. A correct version would
#         additionally need the consumer classification above, a second,
#         materially different and open-ended parsing problem, not a
#         refinement of the first.
#       - "narrow the substitution fall-back so it only applies where a real
#         expansion context is established" does not even reach the
#         reported class: that fall-back is the masked_cmd `$`/backtick
#         raw-scan-instead-of-mask decision (see the CORRECTED / MIRROR-
#         IMAGE REGRESSION paragraphs above), which only ever engages for a
#         quoted VALUE of -d/-r/-m/--description/etc. The reproduced false
#         positive fires with no such flag in sight at all (`git commit -F -
#         <<'EOF' ... EOF`, piping the heredoc straight in as the commit
#         body) — masked_cmd never runs on it, so narrowing that fall-back
#         cannot touch this class. (Confirmed the false-positive class is
#         wider still: a PLAIN multi-line `-m "..."` argument with no
#         heredoc anywhere — the quotes opened on one line and closed two
#         lines later — reproduces the identical block, since masked_cmd's
#         sed-based masking can't see a quoted span that crosses a line
#         boundary in the first place. Closing that would mean restructuring
#         this scanner to operate on a joined multi-line buffer instead of
#         per line, a still-larger change than heredoc parsing, and one that
#         would also have to preserve the round-4 multi-line `do`/keyword
#         catch above.)
#     Decision: accept as a residual FALSE POSITIVE (leave the behavior) —
#     the safer of the three per the bead's own instruction to implement
#     safely rather than ambitiously, and because masking is the highest-
#     risk mechanism in this file (both prior masking changes, made in the
#     j72 session, regressed — see above). Workaround, stated explicitly so
#     it is discoverable: write the text to a FILE and pass the file, e.g. `git
#     commit -F /path/to/message.txt` instead of `-m "$(cat <<'EOF' ...)"`
#     or a bare `<<'EOF'` piped into `-F -` — this works today with NO guard
#     change, because file CONTENT is the already-documented out-of-scope
#     indirection class (--body-file/--design-file/-f/--graph/--stdin
#     above). BD_GUARD_ALLOW=1 does NOT help here: the rule that fires
#     (assignee, and potentially the human-label rule the same way) is HARD
#     by design and has no override. This also partially undercuts the
#     beads_claude_docker-vgr acceptance criterion that filing a bead whose
#     own text quotes a prohibited flag must remain possible: true for plain
#     prose, false once that prose is ALSO multi-line with the flag-shaped
#     text starting its own line.
#
# Contract: reads the Claude Code hook JSON on stdin; exit 0 = allow,
# exit 2 = block (stderr is fed back to the model).
# POSIX sh (dash) clean; uses GNU grep/sed -E (the container's) — `\b` is a GNU
# ERE extension and is intentionally avoided here in favor of explicit
# [[:space:]]/anchors so behavior is stable.

set -u

# Deliberate fail-open: if stdin is not parseable JSON (jq errors), allow the
# command. A bug in this hook must never brick every Bash call in the session.
command_str=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$command_str" ] || exit 0

# Shell-wrapper unwrap depth bound (beads_claude_docker-vgr): a self-
# referential or deeply stacked bash -c/eval wrapper must not spin. Hitting
# this bound simply stops unwrapping deeper — fail-open, never itself a block
# reason. 5 comfortably covers realistic accidental/adversarial nesting
# (double-wrapping like `bash -c "eval '...'"` only needs 2 levels).
MAX_UNWRAP_DEPTH=5

# Total-work node budget (beads_claude_docker-vgr round 2): depth alone does
# not bound COST — a command string with several wrapper candidates at each
# of several levels costs O(branch^depth) scan_cmd calls, since every
# candidate at every level recurses independently (verifier-measured: a 34KB
# hand-built branching input took over 15s of wall clock against the
# unbounded version of this script; see the bead for the full construction).
# SCAN_NODE_COUNT is a script-global (never `local`ed) counter incremented
# once at the top of every scan_cmd call, across the WHOLE recursion tree —
# once it exceeds MAX_SCAN_NODES, every further call (already-branched
# siblings included) returns immediately without doing any real work, which
# collapses the remaining exponential fan-out to near-zero cost. Fail-open:
# hitting the budget only ever STOPS scanning more of the command, never
# itself a block reason — a hostile/pathological input degrades to "allow
# unexamined past this point", matching the same fail-open contract as the
# depth bound above, just guarding against width instead of depth. 200 is
# generous for any realistic command (a real nested-wrapper chain a few
# levels deep with a handful of siblings each is nowhere near this) while
# keeping the worst case fast.
MAX_SCAN_NODES=200
SCAN_NODE_COUNT=0

# Decoy-chain unswallow bound (beads_claude_docker-vgr round 2): the
# iterative-unswallow retry (where it's used, below) strips one swallowing
# decoy's own header per iteration and re-scans, so recovering a real
# wrapper payload buried behind N chained decoys costs N+1 iterations. This
# is a BOUND, not a promise — exactly like MAX_UNWRAP_DEPTH above: chaining
# more than MAX_UNSWALLOW_ITERS decoys before the real payload exceeds it
# and the real payload is not found via this path (fail-open, never itself
# a block reason; see the paired depth-bound tests in tests/bd-guard.bats
# for the exact same pattern applied here). 10 handles any realistic
# decoy chain (the verifier's own reported bypass used exactly one) while
# keeping the worst-case cost of a FALSE trigger (genuine nested-but-not-
# swallowing wrappers, which also show a header/match-count mismatch and so
# also enter this loop) bounded rather than open-ended.
MAX_UNSWALLOW_ITERS=10

# Per-extraction candidate cap (bd-guard hardening slice, round 3 — item D):
# SCAN_NODE_COUNT above bounds RECURSION width, but every wrapper-candidate
# extraction site (bash/sh/zsh -c and eval, both the main pass and the
# unswallow retry) runs a `head=$(sed ...); grep -qF ...` CONTAINMENT CHECK
# per raw regex match BEFORE any of those matches ever reaches scan_cmd
# recursion or SCAN_NODE_COUNT — so a command with thousands of sibling
# candidates at the SAME level (e.g. `bash -c "..." ; ` repeated 8000 times)
# pays for thousands of `sed`+`grep` subprocess spawns inside a SINGLE
# scan_cmd call, entirely before the recursion budget gets a chance to act
# (measured against the unbounded version: 8000 siblings / ~336KB took
# ~50s wall clock — this hook runs before EVERY Bash call, so that is a
# real per-prompt stall, not a theoretical one). Piping the raw `grep -oE`
# matches through `head -n "$MAX_WRAPPER_CANDIDATES"` before the per-
# candidate loop (all 5 sites below) caps this cost independently of
# SCAN_NODE_COUNT, and does so in the SAME shell (a plain pipe stage, no
# subshell-variable-persistence hazard) rather than trying to thread the
# script-global counter through a `| while read` subshell, where any
# increment would be silently lost the moment that subshell exits. Fail-
# open, same contract as every other bound in this file: candidates beyond
# the cap are simply never considered, never itself a block reason. 64 is
# comfortably above anything a real (even heavily stacked) command needs —
# the existing tests top out around 10 siblings — while keeping the
# worst-case pathological cost small.
MAX_WRAPPER_CANDIDATES=64

block() {
  printf '%s\n' "$1" >&2
  exit 2
}

# scan_cmd — the whole rule engine below, as a function callable on any
# command-shaped string. Runs once on the real Bash command (depth 0), and
# again, recursively, on whatever a bash -c/sh -c/zsh -c/eval wrapper turns
# out to actually run, so a wrapped `bd create ... -a joe` is caught by the
# SAME rules rather than a second copy of them. `depth` bounds the recursion
# (MAX_UNWRAP_DEPTH above); `inherited_allow` carries a BD_GUARD_ALLOW=1 found
# in an OUTER wrapper down to its children, since an env/literal prefix on
# `bash -c`/`eval` really is inherited by whatever they run, same as any other
# env var. `depth`/`inherited_allow`/`allow`/`cmd`/`cmd_tabs` are `local`ed
# because a sibling wrapper occurrence reads them again AFTER a recursive call
# returns (e.g. to compute the next candidate's depth+1); the hard/soft rule
# working variables further down are fully consumed before this function ever
# recurses, so they don't share that hazard, but get one `local` declaration
# where the rules section begins anyway, for the same guarantee at negligible
# cost.
scan_cmd() {
  local cmd="$1"
  local depth="${2:-0}"
  local inherited_allow="${3:-0}"

  # Node budget (see MAX_SCAN_NODES above): count this invocation against the
  # whole-tree total FIRST, before any real work happens, so a call made once
  # the budget is already exhausted costs next to nothing (one arithmetic
  # comparison) instead of paying for its own prefilter/extraction work only
  # to discard the result. Fail-open, not a block reason.
  SCAN_NODE_COUNT=$((SCAN_NODE_COUNT + 1))
  [ "$SCAN_NODE_COUNT" -gt "$MAX_SCAN_NODES" ] && return 0

  # Fold tabs to spaces up front so tab separators (bd<TAB>create, -a<TAB>joe,
  # --assignee<TAB>joe) can never split a token from what follows it.
  local cmd_tabs
  cmd_tabs=$(printf '%s' "$cmd" | tr '\t' ' ')

  # Cheap pre-filter: the vast majority of Bash calls never mention a bd verb —
  # skip all normalization for them. `gate`/`label`/`tag` are included because
  # each can route a bead to a human without ever touching --assignee (see
  # header comment): `bd gate create` defaults to a human-resolved gate, and
  # `label`/`tag` are how the reserved `human` label gets attached. `q` is
  # `bd create`'s quick-capture alias (also takes -l/--labels); `human` is
  # `bd human <id>`, which bd's own injected docs (bd prime) wrongly describe
  # as a way to flag an issue for a person (beads_claude_docker-v5p round 2).
  # `remember` (beads_claude_docker-zcnb) is checked by the rule-shaped-text
  # SOFT rule further down, outside the big create/update/…/init gate below —
  # it needs no entry in that gate's own alternation, but it DOES need to
  # survive this pre-filter or scan_cmd returns before ever reaching it.
  # A wrapped payload is still literal text inside $cmd_tabs even though it's
  # quoted, so this pre-filter is unaffected by recursion depth — and this is
  # `return`, not `exit`, so a sibling wrapper elsewhere in an outer call
  # keeps being checked instead of the whole process ending here.
  #
  # `['"]?` between `bd` and the required whitespace (bd-guard hardening
  # slice, item B follow-up): a self-quoted `'bd'`/`"bd"` puts the CLOSING
  # quote character directly between the literal letters "bd" and the space
  # before the verb, e.g. `'bd' create x -a joe` — without this, the cheap
  # substring check below never matches at all (no `bd[[:space:]]` anywhere
  # in the raw text), short-circuiting via `return 0` before the wrapper-
  # word/quote-normalization loop ever runs, silently reintroducing the
  # exact bypass that loop was added to close. `\bd create` does not need
  # this: the backslash sits BEFORE "bd", not between "bd" and the
  # following space, so it was already found by the unmodified pattern.
  printf '%s' "$cmd_tabs" | grep -qE "bd['\"]?[[:space:]]+(create|new|update|assign|close|done|gate|label|tag|q|human|init|remember)" || return 0

  # Strip command-position noise that would otherwise hide `bd` from the anchors:
  # at the start of the string or right after a ; && || | ( ) separator, remove a
  # leading run of VAR=value environment assignments and wrapper words. Looped
  # because several may stack, e.g. `  FOO=1 command bd create`. `xargs` is
  # included (beads_claude_docker-vgr): it passes its own literal argv straight
  # through to the child (`echo x | xargs bd create -a joe` really does run
  # with `-a joe` in the child's argv), so it's exactly as safe to strip as
  # `command`/`env` — no extraction/recursion needed, unlike bash -c/eval below.
  # Only the bare `xargs CMD` form is covered — see the scope table for what
  # stays out of scope (xargs' own flags, and values it appends from stdin).
  #
  # Hardening slice (round 3, item A) — a second wrapper-word class that
  # takes ITS OWN leading arguments before the real command: `timeout 10 bd
  # …`, `stdbuf -o0 bd …`, `ionice -c3 bd …`, `nice -n 10 bd …`. These are
  # NOT folded into the bare word|word|word alternation above (which strips
  # only `WORD[[:space:]]+`, requiring the very next token to already be
  # `bd`): doing so would leave the intervening flag/argument (`-o0`, `10`)
  # stranded at command position on the NEXT iteration with nothing left to
  # strip it, since there is no earlier wrapper word anymore to scope a
  # generic flag-strip to. A fully generic "strip any leading token that
  # isn't `bd`" rule was considered and rejected: applied at every command
  # position (not just after one of these specific words) it also strips
  # xargs' OWN flag in `xargs -I{} bd create x -a {}` the instant `-I{}`
  # reaches command position after `xargs` is removed by the pattern below —
  # collapsing the deliberately-out-of-scope, PINNED `xargs -I{}` case
  # (tests/bd-guard.bats) into a false block. Scoping the extra-argument
  # grammar to exactly these 8 words avoids that: `timeout|stdbuf|setsid|
  # nice|ionice|script|chrt|taskset`, each optionally followed by any
  # number of dash-flag tokens and/or bare numeric/duration tokens, in ANY
  # ORDER and interleaving — both alternatives use POSITIVE character
  # classes (must start with `-`, or must start with a digit) that can
  # never equal the literal word `bd`, so this can never accidentally strip
  # `bd` itself the way a blind "any word" rule could. `nice -n 10`/
  # `chrt -f 50`/`taskset -c 0` (flag THEN a separate value token) fall out
  # of the same pattern for free, alongside the bare (no-argument) form for
  # all 8 words, which the group's own optionality (`*`, zero repetitions
  # allowed) already covers without a separate alternative.
  #
  # Round 4 (bd-guard hardening slice, beads_claude_docker-vgr, third
  # independent verifier pass) — the round-3 grammar above was `(-TOKEN)*
  # (DIGIT…)?`: any number of dash-flags, THEN at most one trailing bare
  # numeric, flags always before the number. Two real shapes fall outside
  # that: `timeout -k 5 10 bd …` (a flag with its OWN separate numeric
  # VALUE — `-k 5` — followed by a SECOND bare numeric, the actual
  # duration) and `timeout 10 -- bd …` (a bare numeric BEFORE a dash
  # token, the reverse of the old flags-then-number order). Both left `bd`
  # stranded behind an unconsumed token forever (nothing later in the
  # fixed-point loop recognizes a lone `5`/`10`/`--`), an exit-0 bypass.
  # The grammar is now `(-TOKEN(<space>DIGIT…)?|<space>DIGIT…)*` — each
  # repetition is EITHER a dash-flag optionally followed by exactly one
  # numeric value, OR a bare numeric, in any order/count — a strict
  # superset of the round-3 shape (every string the old grammar matched,
  # this one still matches) that additionally covers both. The optional
  # per-flag value is deliberately numeric-only (reusing the same
  # `[0-9][0-9A-Za-z.]*` class as the bare-numeric alternative, not a
  # generic "next token"): every one of these 8 words' flags that takes a
  # separate-token value (`-k SECONDS`, `-n ADJUSTMENT`, `-f PRIORITY`,
  # `-c CPULIST`, …) takes a NUMBER, and constraining it that way keeps the
  # same safety argument as round 3 — a value token starting with a digit
  # can never equal the literal word `bd`, so a flag can never swallow the
  # real command word as if it were the flag's own argument.
  #
  # Round 4 also adds per-tool arity tables for three wrapper words that
  # round 3 left in the plain bare-word list below (`env`/`sudo`/`time`
  # were stripped only as `WORD[[:space:]]+`, requiring the very NEXT
  # token to already be `bd`) — so `env -u FOO bd …`, `env -i bd …`,
  # `sudo -u agent bd …`, and `time -p bd …` all left a flag stranded at
  # command position exactly like the round-3 gap above, and were
  # confirmed-live bypasses. Each word gets its OWN dedicated clause, `WORD
  # ((<space>BARE-FLAG|<space>VALUE-FLAG(=|<space>)VALUE)*)<space>`, listing
  # known flags explicitly rather than accepting any dash token — mirroring
  # the existing `label add`/`label propagate` flag-strip further down this
  # file (`--actor`/`--db`/… value-taking vs `--json`/`--global`/… bare),
  # not a new pattern. The flag tables (verified against this container's
  # `env --help`/`sudo --help`; the bash keyword `time` accepts only `-p`
  # per POSIX, nothing else) are deliberately asymmetric about what they
  # list: getting a BARE flag wrong by calling it value-taking is dangerous
  # (it would swallow the real `bd` token as if it were that flag's
  # argument — the exact failure mode the numeric-only constraint above
  # avoids for the 8-word group); getting a value-taking flag wrong by
  # calling it bare, or simply never listing an obscure flag at all, is
  # merely incomplete (the status quo — that flag/value stays stranded and
  # unstripped, same as any wrapper flag before this round) rather than
  # unsafe. `sudo -h` is deliberately listed nowhere — `sudo --help`
  # confirms it is genuinely overloaded (`-h, --help` bare AND `-h,
  # --host=host` value-taking depending on build), so no single classification
  # is correct; leaving it unrecognized is the safe default. See KNOWN
  # LIMITATIONS below for what this still doesn't reach (any flag outside
  # these tables) and why that residual is accepted rather than chased
  # further.
  #
  # Round 4 also strips shell reserved words at command position: `do`,
  # `then`, `else`, `elif`, `if`, `while`, `until`, `!`. These are neither
  # one of the `;&|(){` separators the anchors below require NOR a
  # stripable wrapper word, so `bd` immediately after any of them was
  # completely invisible to EVERY rule in this file — not a narrow gap in
  # one rule, a bypass of the whole rule block, since the gate at the `if`
  # a few dozen lines below this loop (`bd` + verb at a command position)
  # is what decides whether ANY hard/soft rule below even runs. A for-loop
  # body (`for i in 1 2; do bd update bd-$i -a joe; done`) is an entirely
  # ordinary way to batch bd calls, making this the highest-severity gap
  # found in any hardening round so far. `if`/`while`/`until` cover the
  # sibling shape where `bd` is the CONDITION being tested, not the body
  # (`if bd update bd-1 -a joe; then :; fi`) — not in the original reported
  # list, found and closed in this round's own self-attack pass, same
  # mechanism and same safety argument. Same trailing-whitespace-required
  # shape as every other entry in this loop, so a word that merely STARTS
  # with one of these keywords — `ifconfig bd …`, `doit bd …`, `elifant bd
  # …`, `thenceforth bd …`, `whiledoing bd …` — is never mistaken for the
  # keyword itself: the alternation requires the COMPLETE word (`do`, not
  # `doit`) at a command-position boundary, immediately followed by
  # whitespace, and none of these is even a real bd-adjacent bypass in the
  # first place (the shell would run e.g. `ifconfig` with `bd`/`create`/…
  # as ITS OWN arguments, never invoking `bd` at all). This
  # loop is not quote-aware (same as every other clause here — see the
  # header comment on why): a keyword sitting inside a free-text field's
  # value can be stripped too (e.g. `-d "step 1; do the migration"` loses
  # "do "), but since stripping only ever WIDENS what looks like a `bd`
  # command-position match, and the actual hard-rule extraction reads
  # `$masked_cmd` (quoted-value content already blanked) rather than this
  # loop's raw output, that can only make the outer gate fire more often —
  # never itself produce a false block. The two multi-decoy controls this
  # must not regress: `do :; done; bd create x -a joe` (the real `bd` is
  # reached via the LATER `;`, independent of the leading `do`) and a
  # multi-line `do`\n`bd …` form (already caught pre-round-4 because sed
  # processes the input line-by-line, so `^` matches the second line's own
  # start — this loop's keyword strip does not apply there at all, since a
  # lone `do` with nothing after it on the same line never satisfies the
  # mandatory trailing `[[:space:]]+`, and doesn't need to).
  #
  # Hardening slice (round 3, item B) — `\bd`, `'bd'`, `"bd"`: a backslash
  # before a non-special character or a whole word wrapped in matching
  # quotes are both shell no-ops (the word that actually executes is `bd`
  # either way) — exactly the next thing an agent reaches for once it
  # notices `command`/`env` stop working. Normalized back to bare `bd`
  # (quotes/backslash removed, nothing else touched) only at command
  # position and only when `bd` is a complete token there (required
  # trailing whitespace, so `\bdaily` or a `"bd"` sitting mid-word is never
  # mistaken for the command `bd`); a `'bd'`/`"bd"` span deep inside
  # unrelated prose is never at command position to begin with, so this
  # cannot corrupt free-text field content the way a global substitution
  # would. Folded into the SAME fixed-point loop (not a separate pass) so
  # it composes with wrapper-word stripping in either stacking order in as
  # few iterations as possible, e.g. `command 'bd' create x -a joe` and
  # `nice \bd create x -a joe` both resolve within this loop: sed applies
  # every -e script IN SEQUENCE against the cumulative buffer each
  # iteration, so a wrapper word stripped by an earlier -e in THIS pass can
  # expose a `\bd`/`'bd'`/`"bd"` for a later -e to normalize in the SAME
  # iteration, not just on the next one.
  local norm_cmd=$cmd_tabs
  local i=0
  local stripped
  while [ "$i" -lt 20 ]; do
    stripped=$(printf '%s' "$norm_cmd" | sed -E \
      -e 's/(^|[;&|(){])([[:space:]]*)(timeout|stdbuf|setsid|nice|ionice|script|chrt|taskset)(([[:space:]]+-[^[:space:];&|(){}"'"'"'<>]+([[:space:]]+[0-9][0-9A-Za-z.]*)?|[[:space:]]+[0-9][0-9A-Za-z.]*)*)[[:space:]]+/\1\2/g' \
      -e 's/(^|[;&|(){])([[:space:]]*)env(([[:space:]]+(-i|--ignore-environment|-0|--null|-v|--debug)|[[:space:]]+(-u|--unset|-C|--chdir)(=|[[:space:]]+)[^[:space:];&|(){}"'"'"'<>]+)*)[[:space:]]+/\1\2/g' \
      -e 's/(^|[;&|(){])([[:space:]]*)sudo(([[:space:]]+(-A|-b|-B|-E|-H|-i|-K|-k|-l|-n|-P|-S|-s|-V|-v)|[[:space:]]+(-u|--user|-g|--group|-p|--prompt|-D|--chdir|-C|--close-from)(=|[[:space:]]+)[^[:space:];&|(){}"'"'"'<>]+)*)[[:space:]]+/\1\2/g' \
      -e 's/(^|[;&|(){])([[:space:]]*)time(([[:space:]]+-p)*)[[:space:]]+/\1\2/g' \
      -e 's/(^|[;&|(){])([[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|command|builtin|nohup|exec|xargs)[[:space:]]+/\1\2/g' \
      -e 's/(^|[;&|(){])([[:space:]]*)(do|then|else|elif|if|while|until|!)[[:space:]]+/\1\2/g' \
      -e 's/(^|[;&|(){])([[:space:]]*)\\(bd)([[:space:]])/\1\2\3\4/g' \
      -e 's/(^|[;&|(){])([[:space:]]*)"(bd)"([[:space:]])/\1\2\3\4/g' \
      -e "s/(^|[;&|(){])([[:space:]]*)'(bd)'([[:space:]])/\1\2\3\4/g")
    [ "$stripped" = "$norm_cmd" ] && break
    norm_cmd=$stripped
    i=$((i + 1))
  done

  # Quote-aware masking (beads_claude_docker-vgr, closing slice): text inside
  # the quoted VALUE of a free-text bd field is DATA, never command syntax --
  # e.g. -d "example: bd create x -a joe" must not read as a real -a flag,
  # and -d "example: (bash -c 'bd create x -a joe')" must not read as a real
  # wrapper. masked_cmd blanks the CONTENT of quoted values of the flags
  # below (quote characters kept, interior emptied) and feeds every
  # STRUCTURAL extraction site below (segments, assignee, labels, gate
  # --type, bare `bd human <id>`, and wrapper-candidate filtering further
  # down) -- it is deliberately never used by the three prose SOFT rules
  # further down (user-directed phrasing / blocked-status prose / residual-
  # work-in-close-reason), which stay on the unmasked $norm_cmd because
  # reading the real text of exactly these fields IS their job: "does this
  # bead's own description/notes/reason say 'ask the user'".
  #
  # Flag list: -d/--description, --notes, --design, --acceptance, -r/--reason
  # (the last was already masked ad hoc, scoped to one gate-create segment,
  # before this slice -- now generalized and centralized so every hard rule
  # gets the same protection, not just the gate one) and --title. Bare `-t`
  # is deliberately NOT included even though the bead text says "--title/-t":
  # confirmed empirically against bd 1.0.4 (`bd create --help`, `bd gate
  # create --help`) that -t is ALWAYS --type -- issue type on create/update,
  # gate type on gate create -- a structural, security-relevant enum;
  # --title has no short form at all. Masking bare -t would let a quoted
  # `bd gate create -t "human"` slip the hard gate-type rule below.
  #
  # Hidden free-text flag aliases (beads_claude_docker-j72, probed 2026-08-08
  # against bd 1.0.4 / ce242a879 in a throwaway sandbox -- never this repo's
  # own .beads): `bd create`/`bd update` accept `-m` and `--message`, and `bd
  # create` separately accepts `--body`, as fully working, HONOURED aliases
  # for --description -- none of the three appear in ANY of those commands'
  # own --help output. `bd close` accepts `-m`, `--message`, `--resolution`
  # and `--comment` as HONOURED aliases for --reason, same gap. Every one of
  # these was confirmed by actually running it against a sandbox project and
  # reading back `bd show --json` (create: .description; close: .close_reason;
  # update -m: only .description changed, confirmed via a before/after diff),
  # not inferred from --help or guessed by naming convention -- e.g. plausible
  # near-misses `--desc`, `--text`, `--note`, `--result`, `--outcome`, and
  # hidden aliases for --notes/--design/--acceptance/--title (`-n`, `--note`,
  # `--ac`, `--criteria`, `--name`, `-T`, …) were ALSO tried and confirmed
  # REJECTED (`Error: unknown flag`/`unknown shorthand flag`), so this list is
  # not merely "the two spellings the bug report already named" (the bead's
  # own root-lesson warning) but the actual empirically-closed set. `-m`/
  # `--message`/`--comment`/`--resolution` were separately confirmed REJECTED
  # on every OTHER guarded verb this masking list is blind to the identity of
  # (`tag`, `label add`, `gate create`, `q`, `init`, bare `human`) -- masking
  # them here can only ever blank quoted prose that was never going to be a
  # real flag on those verbs anyway, never hide a real one. `bd edit` (an
  # entirely separate, undocumented-in-the-guard command discovered during
  # this probe) is NOT in scope here or anywhere in this file: it exposes no
  # --assignee/--labels/--type and no inline-text flag at all -- every one of
  # its flags is a bare boolean field SELECTOR that opens $EDITOR, so it can
  # express none of this file's hard-rule violations and can't be driven
  # non-interactively from a Bash tool call in the first place.
  #
  # Short-flag glued/`=` spellings (beads_claude_docker-j72): bd's flag parser
  # honors `-d"text"`/`-dtext` and `-r"text"`/`-rtext` (no separator at all,
  # standard getopt-style shorthand gluing) exactly as it already does for
  # `-a` (see the assignee extraction above, `-a(=|[[:space:]]+)?` -- the same
  # precedent, now applied here too), which the ORIGINAL version of this line
  # missed: it required a literal `=` or whitespace between the short flag and
  # the opening quote, so a genuine, bd-honoured `-d"ask Joe to decide"` was
  # never masked at all. The separator is now OPTIONAL for the short flags
  # (-d, -r, -m) for exactly this reason. Long flags do NOT get the same
  # treatment: confirmed empirically that bd's parser REJECTS a glued long
  # flag (`--descriptionGLUED "x"` -> `Error: unknown flag`), so requiring a
  # real `=`/whitespace separator for the long-flag alternatives is not a gap,
  # it's what bd itself enforces -- widening it there would only ever mask
  # text that could never have been that flag's real value.
  #
  # Only QUOTED values are masked: an unquoted value is shell-split on
  # whitespace into separate argv tokens by construction, so it can never
  # itself smuggle a space-containing flag like `-a joe` as a single word --
  # that class of evasion doesn't exist, so there is nothing to mask there.
  # An unterminated quote (no matching close), OR a double-quoted value that
  # contains a live `$`/backtick substitution (see the next paragraph), simply
  # fails to match either double-quoted pattern below and is left untouched,
  # falling back to the pre-quote-aware scan of that text -- fail-open by
  # construction (fixes nothing, but also invents no new bypass), never a
  # crash.
  #
  # CORRECTED (beads_claude_docker-j72, regression fix): the paragraph above
  # used to also claim, more broadly, that masking a quoted value "can never
  # smuggle a flag" -- true only for the unquoted-splitting case, not as a
  # general property of quoting. A double-quoted span is not inert data: bash
  # genuinely EXECUTES `$(...)` command substitution and backtick
  # substitution found inside double quotes, before `bd` ever sees the
  # resulting argv -- so blanking such a span doesn't neutralize a payload,
  # it destroys the evidence one ever ran. This was live, not theoretical:
  # once -m joined the masked flag list (below), `bd create x -m "$(bd
  # create y --labels human)"` went from correctly BLOCKED to silently
  # ALLOWED, because the entire `$(...)` -- including the real, executing
  # `bd create y --labels human` -- was blanked away before the label rule
  # further down ever ran, even though that inner command genuinely runs and
  # genuinely attaches the human label. The gap pre-dates -m: it was already
  # latent for -d/--description and every other flag in this list, simply
  # unexercised by the report that first added masking. Fix: the double-
  # quoted character classes below now exclude `$` and backtick, so ANY span
  # containing either anywhere is left completely unmasked (never partially
  # masked around just the substitution, which could itself misparse where
  # the real closing quote is) and falls back to the same raw-text scan an
  # unterminated quote already falls back to above -- the fallback that
  # re-exposes the nested `bd` invocation to the structural rules below. This
  # trades an occasional false positive (inert prose that happens to contain
  # a stray `$`/backtick, e.g. "costs $5", stays unmasked and gets raw-
  # scanned too) for never again hiding a live one -- the same "when in
  # doubt" direction this file takes everywhere else.
  #
  # MIRROR-IMAGE REGRESSION (beads_claude_docker-j72, round 2): the paragraph
  # above originally stopped here and left the single-quoted classes below
  # masking unconditionally, on the claim that single-quoted values are
  # "deliberately NOT given the same treatment: bash never expands
  # `$(...)`/backticks/`${...}` inside single quotes at all -- fully inert
  # character-for-character no matter what it contains." That is true only
  # of a `'...'` span where the single quotes are the REAL, ACTIVE quote
  # delimiters as some shell actually parses them -- not an invariant this
  # file can rely on, because scan_cmd does not parse quoting at all: a
  # wrapper's payload is extracted as a literal SUBSTRING of the outer
  # command (see the wrapper-unwrap section below) and re-scanned at the next
  # recursion depth exactly as if it were freestanding. A `'...'` span that
  # looks self-contained in isolation may, in the real (outer) command, sit
  # INSIDE an enclosing double-quoted wrapper -- where double quotes do not
  # treat `'` as special at all, so those characters are ordinary data, not
  # quote delimiters, and any `$(...)`/backtick inside is evaluated by the
  # OUTER shell while it constructs the wrapper's payload string, before `bd`
  # -- wrapped or not -- ever runs. Live, not theoretical, confirmed with a
  # fake `bd` on PATH logging argv: `bash -c "bd create x -m 'hi $(bd create
  # y --labels human)'"` -- the OUTER double quotes make the real shell
  # evaluate `$(bd create y --labels human)` while parsing bash -c's own
  # argument, genuinely attaching the human label, regardless of the single
  # quotes sitting inside that span. scan_cmd masks the same literal text at
  # every depth with no memory of what enclosed it one level up, so it
  # cannot tell "these are real quotes, this span is inert" from "these are
  # just single-quote bytes sitting inside someone else's double quotes" --
  # unconditional single-quote masking blanked a payload that, one recursion
  # level up, had already executed. This closes both the immediate
  # regression (once -m joined the masked list, above) and an identical,
  # wider gap that PRE-DATES -m on -d/--description and every other flag
  # already in this list: `bash -c "bd create x -d 'hi $(bd create y -a
  # joe)'"` was already silently allowed before -m ever existed here, simply
  # unexercised until this fix's own probe went looking.
  #
  # Fix: the single-quoted character classes below now exclude `$` and
  # backtick symmetrically with the double-quoted ones above, so a single-
  # quoted span containing either also falls back to the raw-text scan
  # instead of being blanked -- same mechanism, same fallback, same
  # "occasional false positive beats hiding a live substitution" direction.
  # Trade-off, stated the same way as the double-quoted one above: a single-
  # quoted value that really is inert -- no enclosing double quotes anywhere
  # above it, e.g. a bare, unwrapped `bd create x -d 'run $(date) first'`
  # typed directly -- also stops being masked once it contains `$`/backtick,
  # and falls back to the raw scan too. This is only an observable false
  # positive if that same raw text ALSO matches a hard/soft rule below (a
  # real flag shape, or user-directed phrasing); ordinary prose with a stray
  # `$`/backtick and nothing else rule-shaped -- "costs $5" from the double-
  # quoted fix above, or this paragraph's own "run $(date) first" -- scans
  # clean either way and stays allowed. scan_cmd has no way to tell
  # "genuinely inert" from "inert only because no enclosing double quotes
  # happen to exist this time," so, per this file's standing principle, it
  # no longer tries.
  #
  # This is also a different gap from the "command substitution" class in
  # KNOWN LIMITATIONS at the top of this file: that class is this hook being
  # unable to EVALUATE a dynamically *built* wrapper payload (e.g. `sh -c
  # "$(echo bd create x -a joe)"`) to discover text it cannot see without
  # actually running `echo`. Neither the double-quoted fix above nor this
  # single-quoted one needed any evaluation at all -- `bd create y --labels
  # human` was already sitting in the command string as literal characters
  # in both regressions; the bug was this file masking away text it could
  # already see, not failing to compute text it couldn't.
  #
  # Alternation-order safety: `--reason` sorts before `--resolution`/
  # `--comment` in the list below with no ambiguity risk -- POSIX/GNU ERE
  # alternation with `grep -oE`/`sed -E` is leftmost-longest per position, not
  # first-alternative-wins, the same argument already relied on elsewhere in
  # this file for `--label` vs `--labels` (see the label_flags_raw comment
  # further down) -- and none of `--description`/`--body`/`--message` is a
  # textual prefix of another alternative in this same list either, so no
  # ordering in this alternation can ever cause a partial, wrong match.
  local masked_cmd
  masked_cmd=$(printf '%s' "$norm_cmd" | sed -E 's/(^|[[:space:]])(-d|-r|-m)(=|[[:space:]]+)?"[^"$`]*"/\1\2\3""/g; s/(^|[[:space:]])(--description|--title|--notes|--design|--acceptance|--reason|--resolution|--comment|--message|--body)(=|[[:space:]]+)"[^"$`]*"/\1\2\3""/g; s/(^|[[:space:]])(-d|-r|-m)(=|[[:space:]]+)?'"'"'[^'"'"'$\`]*'"'"'/\1\2\3'"''"'/g; s/(^|[[:space:]])(--description|--title|--notes|--design|--acceptance|--reason|--resolution|--comment|--message|--body)(=|[[:space:]]+)'"'"'[^'"'"'$\`]*'"'"'/\1\2\3'"''"'/g')

  # Override resolution (SOFT rule only). An exported env var is honored, and so
  # is a literal `BD_GUARD_ALLOW=1` assignment written as a command prefix — that
  # assignment is scoped to the not-yet-run command and never reaches this
  # process, so we read it from the command text and apply it ourselves.
  # Computed unconditionally, not gated on bd being at THIS level's command
  # position: a wrapper's own outer prefix (`BD_GUARD_ALLOW=1 bash -c '...'`)
  # must still unlock the soft rule for what's INSIDE the wrapper — carried
  # down via inherited_allow when this level recurses, below.
  local allow=0
  [ "${BD_GUARD_ALLOW:-0}" = "1" ] && allow=1
  [ "$inherited_allow" = "1" ] && allow=1
  # Honor a literal BD_GUARD_ALLOW=1 only in genuine command-prefix position — as
  # one of the leading env-assignments/wrappers before the (possibly wrapped) bd
  # word — so a trailing `# BD_GUARD_ALLOW=1` comment or an embedded value cannot
  # unlock the soft rule.
  printf '%s' "$cmd_tabs" | grep -qE '(^|[;&|(){])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|(command|builtin|env|nohup|time|exec|sudo)[[:space:]]+)*BD_GUARD_ALLOW=1[[:space:]]' && allow=1

  # Precise gate on the normalized command: bd + verb at a command position
  # (string start or right after ; && || | ( ), with leading whitespace
  # allowed). An `if`, not `|| return 0`: bd being absent from THIS level's
  # command position no longer means there is nothing left to check — it may
  # still be one wrapper layer down, handled by the unwrap step after this
  # block closes.
  if printf '%s' "$norm_cmd" | grep -qE '(^|[;&|(){])[[:space:]]*bd[[:space:]]+(create|new|update|assign|close|done|gate|label|tag|q|human|init)([[:space:]]|$)'; then

  # Rule-section working variables, all scoped to this invocation so a
  # recursive call later in this same function can never leak into them (see
  # the scan_cmd header comment).
  local segments assignees a tag_label label_add_val seg seg_tail la_stripped la_i la_s seg_val label_flags_raw lbl gate_type gate_type_lc human_tail jsonl joined blocked_pending_re residual_re innocuous_re followup_re

  # Pseudo-segments of the MASKED command (beads_claude_docker-vgr, closing
  # slice: was $norm_cmd), one per single command/pipeline stage: split on
  # ; && || | and newline (see header comment for why this is deliberately
  # not quote-aware about ; and |, and why the rules below that need that are
  # the flag/segment-position ones, not the prose ones). Using masked_cmd
  # here closes the same root cause for the gate/label/human rules below, not
  # just assignee: text like `-d "example: bd gate create --blocks bd-1"` or
  # `-d "see also bd human bd-1"` would otherwise itself look like a second
  # bd invocation to the per-segment `grep -qE 'bd ... gate create'`-style
  # checks below, purely because segment-splitting and those checks run on
  # raw text and don't know that span is inside a quoted flag value — the
  # exact same failure shape the assignee/label extraction below has, just
  # reached through segments instead of a direct flag-value grab. A genuine
  # single-invocation command with no free-text-flag content is completely
  # unaffected (masked_cmd == norm_cmd for it). Consumed with
  # `while IFS= read -r` below so each rule that needs single-invocation
  # scope can check every segment independently instead of grepping the
  # whole (possibly multi-command) string at once.
  segments=$(printf '%s' "$masked_cmd" | sed -E 's/(&&|\|\||[;|])/\n/g')

# --- HARD RULE: assignee must be Claude/agent, never a human -----------------
# Covers: bd create/update ... --assignee X | --assignee=X | -a X | -a=X | -aX
#         bd assign <id> <name>
# The short flag -a is anchored at a token boundary (start or whitespace) so it
# never matches inside a long flag like --all or --assignee; bd's parser accepts
# the spaced, =-glued, and value-glued spellings, so all three are extracted.
# Reads $masked_cmd (beads_claude_docker-vgr, closing slice), not $norm_cmd, so
# `-a joe` appearing only inside the quoted value of -d/--notes/--reason/etc is
# DATA, not a real assignee — while a real `-a joe` in genuine command position
# (never inside one of those quoted values) is completely unaffected, since
# masking only blanks quoted-value interiors, never text outside them.
assignees=$(printf '%s' "$masked_cmd" \
  | grep -oE -- '(--assignee(=|[[:space:]]+)|(^|[[:space:]])-a(=|[[:space:]]+)?)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|)]+)' \
  | sed -E 's/^.*(--assignee(=|[[:space:]]+)|-a(=|[[:space:]]+)?)//; s/^["'"'"']//; s/["'"'"']$//')
printf '%s' "$masked_cmd" | grep -qE '(^|[;&|(){])[[:space:]]*bd[[:space:]]+assign([[:space:]]|$)' && \
  assignees="$assignees
$(printf '%s' "$masked_cmd" | sed -nE 's/.*bd +assign +[^ ]+ +("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^ ;&|]+)).*/\2\3\4/p')"

while IFS= read -r a; do
  [ -z "$a" ] && continue
  case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in
    claude|claude[-_]*|agent|agent[-_]*|ai|bot|"") ;;  # agent identities OK
    *) block "BLOCKED (bd-guard): assignee '$a' is not an agent identity. Beads are Claude Code's own work items and are NEVER assigned to a human — no override exists for this. If the underlying work needs a human decision or action, do not file a bead: ask the user directly in chat, right now, in your reply. If the work is Claude's, use --claim (or leave unassigned)." ;;
  esac
done <<EOF
$assignees
EOF

# --- HARD RULE: the reserved `human` label is an assignee in disguise --------
# `bd human list` surfaces "issues with 'human' label" to a person — attaching
# that exact label is structurally the same act as --assignee joe, just via a
# different field. Ways to attach it, all extracted the same way as the
# assignee flags above:
#   bd create ... --labels X | --label X | -l X   (--label: bare singular,
#                                                   undocumented in `bd
#                                                   create --help` but a
#                                                   real, honoured alias —
#                                                   see round-3 note above
#                                                   scan_cmd; `bd update`/
#                                                   `bd q` reject this exact
#                                                   spelling)
#   bd update ... --add-label X | --set-labels X
#   bd q ... -l X | --labels X             (quick-capture's own label flags)
#   bd tag <id> <label>                    (shorthand for --add-label)
#   bd label add <id...> <label> [flags]   (flags may trail the label)
#   bd label propagate <parent-id> <label> [flags]
# --remove-label is deliberately NOT matched — removing the label un-flags the
# bead and is never itself a violation. Values are comma-splittable since
# --labels/--label/--add-label/--set-labels accept comma lists.
# Captures EVERY token after the id, not just the first (beads_claude_docker-
# vgr round 2): bd's real CLI takes exactly one label positional for `tag`
# (confirmed via `bd tag --help`) and would reject a 3rd, but grabbing only
# the FIRST value-shaped token after the id and silently discarding anything
# past it let a planted violation two tokens deep slip by uninspected --
# `bd tag bd-1 "x" human` extracted only "x", never looking at `human` at
# all. Whether or not bd itself would accept the extra token, catching it
# here is the safe direction (an occasional false positive beats any
# bypass) and costs nothing when there genuinely is only one token. Each
# trailing token (quoted or bare) is emitted on its own line via grep -oE,
# same tokenizer shape as the label-flags extraction below, so the existing
# per-line consumption loop already checks every one of them for "human".
tag_label=""
if printf '%s' "$masked_cmd" | grep -qE '(^|[;&|(){])[[:space:]]*bd[[:space:]]+tag[[:space:]]+'; then
  tag_label=$(printf '%s' "$masked_cmd" \
    | sed -nE 's/.*bd +tag +[^ ]+ +(.*)/\1/p' \
    | grep -oE -- '"[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|)]+' \
    | sed -E 's/^["'"'"']//; s/["'"'"']$//')
fi
# `label add`/`label propagate`: bd's flag parser accepts flags after
# positional args (`label add <id> human --json`), so the label is not
# reliably the LAST token of the whole string as a naive grab assumes, and a
# whole-string grab also reads past this invocation into a later command
# (beads_claude_docker-v5p round-2 bypass: `label add bd-123 human --json`;
# also -q, --db /x; also `label add bd-1 human && echo done`). Fix: scope to
# the single-invocation segment (see `segments` above), then strip every
# known global/command flag (with its value where it takes one) before
# taking the last remaining token as the label.
label_add_val=""
while IFS= read -r seg; do
  printf '%s' "$seg" | grep -qE '(^|[[:space:]{(])[[:space:]]*bd[[:space:]]+label[[:space:]]+(add|propagate)[[:space:]]+' || continue
  seg_tail=$(printf '%s' "$seg" | sed -nE 's/.*bd[[:space:]]+label[[:space:]]+(add|propagate)[[:space:]]+(.*)/\2/p')
  # Loop to a fixed point (like the wrapper-strip near the top of the file):
  # removing one flag can expose the boundary space the next flag's anchor
  # needs, so a single non-/g pass can leave a stacked flag behind.
  la_stripped=$seg_tail
  la_i=0
  while [ "$la_i" -lt 20 ]; do
    la_s=$(printf '%s' "$la_stripped" | sed -E \
      -e 's/(^|[[:space:]])(--actor|--db|-C|--directory|--dolt-auto-commit)(=|[[:space:]]+)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|)]+)/\1/' \
      -e 's/(^|[[:space:]])(--json|--global|--profile|--readonly|--sandbox|-v|--verbose|-q|--quiet|-h|--help)([[:space:]]|$)/\1\3/')
    [ "$la_s" = "$la_stripped" ] && break
    la_stripped=$la_s
    la_i=$((la_i + 1))
  done
  # Trailing whitespace left behind by a stripped flag (e.g. "human --json"
  # loses "--json" but keeps the space before it) would otherwise defeat the
  # $-anchored "last token" match below, since the token would no longer be
  # adjacent to the true end of the string.
  la_stripped=$(printf '%s' "$la_stripped" | sed -E 's/[[:space:]]+$//')
  seg_val=$(printf '%s' "$la_stripped" | grep -oE '("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|)]+)$' | sed -E 's/^["'"'"']//; s/["'"'"']$//')
  label_add_val="$label_add_val
$seg_val"
done <<EOF
$segments
EOF
# --label (bare singular, beads_claude_docker-v5p round 3): NOT in `bd create
# --help` — probed directly against a live bd 1.0.4 sandbox, where it is a
# real, honoured alias for --labels (space- or =-glued, comma-splittable).
# Added as a plain extra alternative, matched blind to which bd verb precedes
# it, same as every other spelling here: `bd update`/`bd q` reject this exact
# flag (`Error: unknown flag: --label`), so an `update`/`q` command carrying
# it was never going to succeed regardless of this guard — blocking it early
# is a harmless over-block, not a false positive against real usage, so no
# extra scoping is needed to keep it verb-safe. The trailing `(=|[[:space:]]+)`
# requirement (mandatory, not optional, same as --labels/--add-label/
# --set-labels above) is also what keeps this alternative from ever matching
# as a false-start prefix of `--labels` itself: `--labels human` has `s`, not
# `=`/space, immediately after `--label`, so only the `--labels` alternative
# can match there.
# Trailing-punctuation strip widened to a RUN of quote/apostrophe/BACKTICK
# (beads_claude_docker-j72, regression-fix follow-on): once the masked_cmd fix
# above stops blanking a `$`/backtick-containing quoted value, raw text like
# `-m "`bd create y --labels human`"` reaches this extraction with its own
# ENCLOSING delimiters still attached -- the bare-token branch of the value
# alternation below (deliberately left AS-IS, see next paragraph) grabs
# `human`+backtick+`"` as one token, since neither is one of ITS excluded
# characters. The single-char `s/["']$//` this replaced only ever stripped
# ONE trailing quote, leaving a stray backtick behind and failing the exact
# `= "human"` match a few lines down -- silently allowing the attached-human
# case through. `+$` strips the whole trailing run (both characters, either
# order) in one pass, no loop needed. Narrowing the EXTRACTION class itself
# (excluding `"`/backtick from the bare-token branch, matching the masked_cmd
# fix's shape) was tried first and reverted: it breaks genuine bash quote-
# concatenation values like `--labels "a",human` (a real single argv word,
# pinned by the "sh -c with an escaped inner quote in a labels list" test) by
# making the quoted-value alternative win outright and stop at `"a"`, losing
# `,human` entirely. Stripping only the FINAL trailing run, after extraction,
# fixes the attached-delimiter case without touching that concatenation shape
# (nothing trails a mid-string `"a",human` list, so this strip is a no-op for
# it). Scoped to label_flags_raw only -- not its sibling bare-token sites
# (assignee, tag, label add, gate --type) -- because label matching alone
# needs an EXACT `= "human"` comparison that a stray trailing character
# defeats; assignee's check is inverted (block anything NOT an allow-listed
# agent name), so `joe` + a stray backtick still isn't "claude"/"agent"/etc
# and still blocks with no change needed; tag/label-add/gate --type are not
# reachable through a backtick at all (their own `bd <verb>` gates require a
# `[;&|(){]`-class character immediately before `bd`, and backtick isn't one
# -- a separate, pre-existing, out-of-scope gap, not one this fix touches or
# worsens).
label_flags_raw=$(printf '%s' "$masked_cmd" \
  | grep -oE -- '(--labels(=|[[:space:]]+)|--label(=|[[:space:]]+)|--add-label(=|[[:space:]]+)|--set-labels(=|[[:space:]]+)|(^|[[:space:]])-l(=|[[:space:]]+)?)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|)]+)' \
  | sed -E 's/^.*(--labels(=|[[:space:]]+)|--label(=|[[:space:]]+)|--add-label(=|[[:space:]]+)|--set-labels(=|[[:space:]]+)|-l(=|[[:space:]]+)?)//; s/^["'"'"']//; s/["`'"'"']+$//')

while IFS= read -r lbl; do
  lbl=$(printf '%s' "$lbl" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  [ -z "$lbl" ] && continue
  if [ "$(printf '%s' "$lbl" | tr '[:upper:]' '[:lower:]')" = "human" ]; then
    block "BLOCKED (bd-guard): the 'human' label routes this bead to bd's human-facing queue (bd human list/respond/dismiss) — that IS assigning it to a person, just via a label instead of --assignee. NEVER attach the 'human' label — no override exists for this. If a human decision is genuinely needed, ask it in chat now instead of filing or flagging a bead; do not park it as human-labeled work."
  fi
done <<EOF
$tag_label
$label_add_val
$(printf '%s' "$label_flags_raw" | tr ',' '\n')
EOF

# --- HARD RULE: a human-type gate is a blocked-on-a-person dependency -------
# `bd gate create --blocks <id>` defaults to --type=human ("Requires manual
# 'bd gate resolve'") when --type/-t is omitted, and accepts --type=human
# explicitly — either way the blocked bead cannot proceed until a person acts,
# which is the assignee rule wearing a dependency instead of a field. The
# automated gate types (timer, gh:run, gh:pr) resolve without a person and are
# unaffected. `bd dep add`/`--waits-for`/`--await-id` are deliberately NOT
# guarded here: every value they accept is another issue ID (or a GH run/PR
# number), never a person, so they cannot express this violation directly —
# and the bead they'd point at can no longer be created as human-owned in the
# first place, since the assignee and label rules above already block that.
#
# Scoped to the single `bd gate create ...` segment and, within it, the FIRST
# --type/-t is discarded in favor of the type bd itself would actually apply
# (repeated flags: last one wins, confirmed empirically against a sandbox bd
# instance — `--type=timer --type=human` really does create a human gate).
# $seg comes from $segments, which is itself built from $masked_cmd
# (beads_claude_docker-vgr, closing slice) — so a -r/--reason argument's
# CONTENT is already blanked before this loop ever sees it, and prose there
# can no longer contain flag-shaped text that gets mistaken for a real flag
# (beads_claude_docker-v5p round-2 bypass: `-r "then use -t timer"` was being
# read as --type=timer with no real --type present at all; this used to be a
# bespoke per-segment reason-strip right here, now subsumed by the general
# mechanism so every hard rule gets it, not just this one). The cross-segment
# bypass (`bd gate create --blocks bd-1 --type=human && bd update bd-1 -t
# chore` picking up the second command's `-t chore`) is closed by the segment
# scoping itself.
while IFS= read -r seg; do
  printf '%s' "$seg" | grep -qE '(^|[[:space:]{(])[[:space:]]*bd[[:space:]]+gate[[:space:]]+create([[:space:]]|$)' || continue
  gate_type=$(printf '%s' "$seg" \
    | grep -oE -- '(--type(=|[[:space:]]+)|(^|[[:space:]])-t(=|[[:space:]]+)?)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|)]+)' \
    | tail -n1 \
    | sed -E 's/^.*(--type(=|[[:space:]]+)|-t(=|[[:space:]]+)?)//; s/^["'"'"']//; s/["'"'"']$//')
  gate_type_lc=$(printf '%s' "$gate_type" | tr '[:upper:]' '[:lower:]')
  if [ -z "$gate_type_lc" ] || [ "$gate_type_lc" = "human" ]; then
    block "BLOCKED (bd-guard): 'bd gate create' with no --type (or --type=human) creates a gate that only a person can close — the bead stays blocked pending a human decision, which is the assignee rule wearing a dependency instead of a field. No override exists for this. Use --type=timer/gh:run/gh:pr for a gate that resolves automatically, or if a human decision is genuinely required, ask it in chat now instead of parking it as a gate."
  fi
done <<EOF
$segments
EOF

# --- HARD RULE: bare `bd human <id>` is documented (wrongly) as a way to ----
# --- flag an issue for a person ---------------------------------------------
# bd's own injected `bd prime` text lists `bd human <id>` as a way to "flag
# for human decision" -- but bd 1.0.4's real `bd human` only takes the
# subcommands list/respond/dismiss/stats (confirmed empirically in a sandbox:
# `bd human <id>` with no matching subcommand just prints the human-commands
# help menu and leaves the issue completely untouched -- functionally inert
# in this version). Block the bare form anyway: it is still the documented-
# but-wrong path an agent would reach for to route a bead to a person, and
# blocking it defends against both that confusion and a future bd version
# where it does something. The real subcommands view or discharge issues
# that are ALREADY human-labeled (not a new routing action) and pass through,
# as does `--help`/no-argument.
while IFS= read -r seg; do
  printf '%s' "$seg" | grep -qE '(^|[[:space:]{(])[[:space:]]*bd[[:space:]]+human([[:space:]]|$)' || continue
  human_tail=$(printf '%s' "$seg" | sed -nE 's/.*bd[[:space:]]+human([[:space:]]+(.*))?$/\2/p')
  human_tail=$(printf '%s' "$human_tail" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  case "$human_tail" in
    ""|-h|--help) ;;
    list*|respond*|dismiss*|stats*) ;;
    *) block "BLOCKED (bd-guard): 'bd human $human_tail' -- the bare 'bd human <id>' form is not a real assignment mechanism in this bd version (it only prints a help menu) but bd's own injected docs describe it as a way to flag an issue for a human. Treat it the same as the 'human' label / a human gate: NEVER route a bead to a person this way -- no override exists for this. If a human decision is genuinely needed, ask it in chat now instead." ;;
  esac
done <<EOF
$segments
EOF

# --- SOFT RULE: `bd init --reinit-local`/`--force`/`--discard-remote` can --
# --- delete/overwrite .beads/issues.jsonl without a backup ------------------
# (beads_claude_docker-o15: `bd init --reinit-local --non-interactive`
# repaired a missing issue_prefix but committed the REMOVAL of
# issues.jsonl -- the passive, git-tracked export that is the only way to
# rebuild the database if the live Dolt DB is ever lost or corrupted again.
# bd's OWN init-safety contract only gates REMOTE Dolt-history divergence
# behind a --discard-remote/--destroy-token confirmation -- confirmed via
# `bd help init-safety` -- it does not protect the local issues.jsonl file at
# all, which is exactly the gap this rule closes. A plain `bd init` (no
# reinit flag) is unaffected: it refuses outright against an existing DB and
# never touches issues.jsonl -- see knowledge-base/BEADS_TROUBLESHOOTING.md
# for the safe repair recipe. SOFT (not hard) because the backup check below
# is a heuristic (git-committed state of one file) that can have legitimate
# false negatives -- e.g. a snapshot kept outside the repo -- so there must
# be an escape hatch, unlike the structural human-routing rules above where
# the correct action is always simply "don't".
while IFS= read -r seg; do
  printf '%s' "$seg" | grep -qE '(^|[[:space:]{(])[[:space:]]*bd[[:space:]]+init([[:space:]]|$)' || continue
  printf '%s' "$seg" | grep -qE -- '(^|[[:space:]])(--reinit-local|--force|--discard-remote)([[:space:]=]|$)' || continue
  jsonl=".beads/issues.jsonl"
  if [ -f "$jsonl" ] && [ -n "$(git status --porcelain -- "$jsonl" 2>/dev/null)" ]; then
    [ "$allow" = "1" ] || block "BLOCKED (bd-guard): 'bd init --reinit-local/--force/--discard-remote' can delete or overwrite $jsonl, and it currently has uncommitted changes -- NOT safely recoverable from git if this reinit destroys or corrupts it (beads_claude_docker-o15: this exact sequence committed the removal of 91 closed issues' history, recovered only because an OLDER commit still had a copy). Commit the current $jsonl first (git add $jsonl && git commit), or run 'bd export' and commit that, then re-run. See knowledge-base/BEADS_TROUBLESHOOTING.md for the safe recipe to repair a missing issue_prefix WITHOUT reinit. Only override with a 'BD_GUARD_ALLOW=1 ' prefix if the export truly is backed up some other way (e.g. a snapshot outside the repo)."
  fi
done <<EOF
$segments
EOF

# --- SOFT RULE: user-directed phrasing in bead text --------------------------
# Two tiers: "joe|human" gets broad matching; "user" gets directive-only
# patterns, because "user input", "user review", "allow the user to ...",
# "tasks assigned to the user" are ordinary feature language and must not trip
# the guard. ("assigned to" therefore matches only a named human, not "user".)
joined='ask (the )?(user|human|joe)|wait(ing)? (on|for) (the )?(user|human|joe)|blocked (on|by) (the )?(user|human|joe)|(user|human|joe)('"'"'s)? (decision|approval|sign.?off)|(confirm|check|clarify) with (the )?(user|human|joe)|hand(ed|s)?.?off to (the )?(user|human|joe)|assigned to (the )?(human|joe)|(user|human|joe) (should|must|needs? to|has to) (review|decide|approve|confirm|test|verify|run|check)|(human|joe) (should|must|needs? to|has to|will|to) |(human|joe) (input|review|feedback|action)|for (the )?(human|joe) to '

if printf '%s' "$norm_cmd" | grep -qiE "$joined"; then
  [ "$allow" = "1" ] || block "BLOCKED (bd-guard): this bead's text describes work or a decision belonging to the user (matched a phrase like 'ask the user' / 'waiting for user' / 'blocked on Joe'). Beads are Claude-only; questions are handled in chat. Do this instead, at the point of creation: (1) if a user decision is needed, ask it in your reply NOW — do not park it in a bead; (2) rewrite the bead as work Claude itself will do, including how Claude will verify it in the running program; (3) capture any already-made decision in the bead as a fact, not as a pending request. Only if this is a genuine false positive (the phrase is quoted content/code, not pending user work) re-run the exact command with a 'BD_GUARD_ALLOW=1 ' prefix on the command string."
fi

# --- SOFT RULE: bead parked in `blocked` status pending a person -------------
# (beads_claude_docker-v5p failure shape 2, previously entirely unenforced:
# `bd update bd-1 -s blocked --notes "pending decision"` parks a bead on a
# person exactly as much as a human --assignee does, just via the status
# field instead — indirect routing, not direct assignment. Reuses $joined
# (the same "ask the user"/"waiting for Joe" phrasing above) plus a second,
# person-agnostic pattern for phrasing that doesn't name anyone but still
# reads as "a human must act" in a blocked-status context specifically — a
# *bead* can't itself be "pending a decision"; only a person can be. SOFT,
# not hard: free text has legitimate false-positive shapes here exactly like
# the general user-directed-phrasing rule above.)
if printf '%s' "$norm_cmd" | grep -qiE -- '(^|[[:space:]])(-s|--status)(=|[[:space:]]+)("blocked"|'"'"'blocked'"'"'|blocked)([[:space:]]|$)'; then
  blocked_pending_re='(pending|awaiting|needs?|requires?)[[:space:]]+(a[[:space:]]|an[[:space:]]|the[[:space:]])?(decision|approval|sign.?off|input|response|feedback|review)|decision[[:space:]]+(pending|needed|required)|awaiting[[:space:]]+(a[[:space:]]|an[[:space:]]|the[[:space:]])?(response|reply)'
  if printf '%s' "$norm_cmd" | grep -qiE "$joined|$blocked_pending_re"; then
    [ "$allow" = "1" ] || block "BLOCKED (bd-guard): this bead is being set to --status blocked with text describing a person's decision or action (matched a phrase like 'ask the user' / 'waiting for Joe' / 'pending decision' / 'needs approval'). A blocked-pending-a-human status is the assignee rule wearing a status field — it is not ordinary work-tracking, it IS routing this bead to a person. Do this instead: (1) if a user decision is needed, ask it in your reply NOW — do not park it in a bead; (2) if this is genuinely Claude's own blocked-on-a-dependency work, rephrase the notes/description to name the actual blocking bead or condition, not a person or an unnamed pending decision. Only if this is a genuine false positive (quoted content, not real pending user work) re-run with a 'BD_GUARD_ALLOW=1 ' prefix."
  fi
fi

# --- SOFT RULE (close/done only): residual work discharged in prose ---------
# Observed violation shape (2026-07-17 audit): a close_reason that admits
# leftover or unverified work in prose ("the sole residual step is 'git
# push'", "carried outside the tracker", "NOT verified in-container") —
# discharging real work out of the tracker instead of filing a Claude-owned
# follow-up bead. Patterns are tightened to the admission shape: the residual
# noun is a pending *step* (not generic "work items"), "unverified" must stand
# alone (not "unverified-email"), and "not pushed/tested twice" (a feature-
# behavior spec) is excluded. Reasons that already point at a follow-up bead
# are exempt. `close|done` (beads_claude_docker-j72): `done` is `bd close`'s
# own documented alias (`bd close --help` prints "Aliases: close, done", and
# `bd done <id> ...` really runs close's own logic, confirmed empirically) --
# matching only `close` here left `bd done <id> --reason "..."` completely
# unreachable by this rule even after the two verb-alternation gate sites
# above were widened to admit `done` into the rule block at all: without this
# anchor also covering `done`, a `bd done` command would clear the precise
# gate a few dozen lines up, run every OTHER hard rule, and then silently
# skip past this one soft rule alone, since this `if` re-derives close-ness
# from scratch rather than reusing the outer gate's match.
if printf '%s' "$norm_cmd" | grep -qE '(^|[;&|(){])[[:space:]]*bd[[:space:]]+(close|done)([[:space:]]|$)'; then
  residual_re='(residual|outstanding|left.?over|remaining) (step|steps)|carried outside the tracker|not (yet )?(verified|tested|pushed)|unverified([^[:alnum:]-]|$)|auth.?blocked'
  innocuous_re='not (yet )?(verified|tested|pushed) (twice|again|repeatedly|more than once)'
  followup_re='(follow.?up|filed|tracked|moved|captured) (as|in|to)? *(bead|bd[-_ ]|beads_|issue)'
  if printf '%s' "$norm_cmd" | grep -qiE "$residual_re" \
     && ! printf '%s' "$norm_cmd" | grep -qiE "$innocuous_re" \
     && ! printf '%s' "$norm_cmd" | grep -qiE "$followup_re"; then
    [ "$allow" = "1" ] || block "BLOCKED (bd-guard): this close reason admits residual or unverified work in prose. Closing a bead does not discharge the work — prose in a close reason is where tasks go to die. Before closing: (1) file a Claude-owned follow-up bead for the residual step (never assigned to the user) and mention its id in the close reason, or simply keep this bead open; (2) if the step is blocked on something only the user can do (e.g. credentials), the follow-up bead still carries it as Claude's open item — and ask the user for the unblocking action in chat NOW. Then re-run the close (add a 'BD_GUARD_ALLOW=1 ' prefix to the command only if the wording is a false positive)."
  fi
fi

  fi

  # --- SOFT RULE: `bd remember` text that reads as a RULE, not a fact -------
  # (beads_claude_docker-zcnb) A rule ("Never use git stash", "Always commit
  # with pathspecs") that lands in `bd remember` instead of a rulebook is
  # invisible to every OTHER project this container runs — bd remember is
  # per-repo project memory (facts and lessons), not a channel that ships
  # anywhere else, while config/claude-user-memory.md IS what ships to every
  # project (as the config dir's CLAUDE.md) and a knowledge-base/ doc is the home
  # for a solved-once technical playbook. SOFT, not hard: matching on the
  # first word of free text is a heuristic with real false-positive shapes
  # (a fact that genuinely happens to start with one of these words), same
  # rationale as the other prose rules above.
  #
  # Deliberately checked here, OUTSIDE the big create/update/…/init gate
  # above, rather than adding `remember` to that gate's own alternation:
  # `remember` has none of the structural flags (--assignee/--labels/
  # gate --type/blocked status) that gate exists to scope segments/masking
  # for, so it needs no share of that machinery — only the pre-filter above
  # (which it DOES need, to reach this point at all) and $norm_cmd/$allow,
  # both already computed unconditionally above this point regardless of
  # which verb matched.
  if printf '%s' "$norm_cmd" | grep -qE '(^|[;&|(){])[[:space:]]*bd[[:space:]]+remember([[:space:]]|$)'; then
    local remember_tail remember_text
    remember_tail=$(printf '%s' "$norm_cmd" | sed -E 's/^.*bd[[:space:]]+remember[[:space:]]+//')
    # Strip a LEADING --key <value> (bd remember --key k "text"); a --key
    # that instead follows the text (bd remember "text" --key k — bd
    # remember's own --help example order) needs no stripping here since
    # the text already leads.
    remember_tail=$(printf '%s' "$remember_tail" | sed -E 's/^--key(=|[[:space:]]+)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)[[:space:]]*//')
    remember_text=$(printf '%s' "$remember_tail" | sed -E 's/^[[:space:]]*"//; s/^[[:space:]]*'"'"'//')
    if printf '%s' "$remember_text" | grep -qiE "^[[:space:]]*(never|always|rules?|do[[:space:]]+not|don'?t)([[:space:]]|:|,|\$)"; then
      [ "$allow" = "1" ] || block "BLOCKED (bd-guard): this bd remember text is rule-shaped (starts with Never/Always/Rule(s)/Do not/Don't) rather than a project fact. bd remember holds facts and lessons for THIS project; a rule that should apply everywhere belongs in config/claude-user-memory.md (it ships to every project as the config dir's CLAUDE.md), and a solved-once technical recipe belongs in a knowledge-base/ playbook — see CLAUDE.md's Beads section. Move it there, or rewrite this as a fact ('X does Y because Z'). Only override with a 'BD_GUARD_ALLOW=1 ' prefix if this really is a fact that happens to start with one of those words."
    fi
  fi

  # --- Shell-wrapper unwrapping (beads_claude_docker-vgr) --------------------
  # bash -c/sh -c/zsh -c and eval hide a bd invocation from every rule above:
  # the payload sits inside a quoted (or, for bare eval, unquoted) string, so
  # `bd` is never at a "command position" the anchors above recognize -- it's
  # preceded by a quote character, not a `;&|(){` separator. Rather than
  # duplicate the rule logic against a second, wrapper-shaped grammar, this
  # extracts the payload and RECURSES scan_cmd on it, so the exact same rules
  # above apply to whatever is actually going to run. Runs regardless of
  # whether the `if` above matched, since the bd verb this level is looking
  # for may be exactly one wrapper layer down. Depth is bounded
  # (MAX_UNWRAP_DEPTH) so a self-referential or deeply stacked wrapper cannot
  # spin -- hitting the bound simply stops unwrapping (fail-open: never a
  # block reason by itself). `allow` is threaded to children because a
  # leading `BD_GUARD_ALLOW=1` (literal or exported) genuinely IS inherited by
  # a spawned bash -c/eval child's environment, same as any other env var.
  #
  # Candidate filtering against masked_cmd (beads_claude_docker-vgr, closing
  # slice): raw candidate matches are still found in $norm_cmd (UNMASKED),
  # same as before this slice -- a genuine wrapper's payload must keep its
  # real text (e.g. `bash -c "bd create x -d 'ask Joe to decide'"` must still
  # reach the soft rule one recursion level down; extracting from masked_cmd
  # instead would blank that -d value before recursion ever saw it, turning a
  # real evasion into a silent bypass). What masked_cmd decides is not the
  # payload's TEXT but whether the match is even a REAL wrapper at all: for
  # each raw match, `head` is that match truncated at its first quote
  # character (or, for bare eval, the whole match, which never contains one)
  # -- the wrapper-word/interpreter-flag prefix with none of the payload. A
  # genuine wrapper's head sits in genuine command position, entirely outside
  # any quoted free-text-flag value, so masking never touches it and it
  # always survives as a literal substring of masked_cmd. A wrapper-SHAPED
  # example sitting inside another flag's quoted value (e.g. -d "... (bash -c
  # '...') ...", beads_claude_docker-vgr's second named evasion) has its
  # whole span -- head included -- blanked away by the masking pass, so the
  # head is no longer found in masked_cmd and the candidate is discarded
  # before ever reaching recursion. (A head that coincidentally collides with
  # unrelated real wrapper text elsewhere in the same command is kept rather
  # than discarded -- the safe direction per the bead's hard constraint that
  # an occasional false positive beats any bypass.)
  if [ "$depth" -lt "$MAX_UNWRAP_DEPTH" ]; then
    local candidates=""
    local raw head

    # bash -c "PAYLOAD" / sh -c 'PAYLOAD' / zsh -c "PAYLOAD", optionally
    # path-prefixed (/bin/sh -c, /usr/bin/bash -c). Anchored the same way as
    # every command-position rule above; the sed strip mirrors the grep
    # anchor exactly (no leading .*) so a payload that itself contains " -c "
    # or " eval " can't cause the wrong substring to be stripped.
    #
    # Flag cluster (beads_claude_docker-vgr round 2): the interpreter word
    # may be followed by ANY number of dash-flag tokens before the payload,
    # not just a bare literal "-c" -- `-lc` (POSIX-style clustered short
    # flags), `-ec`, `--norc -c`, and `-c -x`/`-x -c` (either order) are all
    # real, empirically-confirmed ways bash reaches -c's "next arg is the
    # command string" mode (verified directly: `bash -c -x "echo hi"` DOES
    # execute "echo hi", proving bash's own option parser does not require
    # -c to be positionally last). Rather than special-case every letter/
    # order combination, the cluster group (`([[:space:]]+-[A-Za-z-]+)+`)
    # accepts ANY 1-or-more dash-flag tokens with no letter or order
    # requirement at all -- deliberately broader than "must contain c":
    # simpler, provably closes the ordering gap, and only ever WIDENS what's
    # treated as a candidate (the safe direction per this file's own
    # documented principle -- an occasional false positive beats any
    # bypass). It does NOT match a bare `bash "quoted"` with zero flags
    # (requires `+`, not `*`) -- unchanged from before, since real bash
    # without -c treats a bare quoted argument as a script FILENAME, not
    # inline code.
    #
    # Escape-aware payload capture (beads_claude_docker-vgr round 2): the
    # double-quote alternative was `"[^"]*"`, which stops at the FIRST `"`
    # byte with no regard for an escaping backslash -- so
    # `bash -c "bd create x -d \"n\" -a joe"` was captured only through the
    # first `\"`, truncating the payload to `bd create x -d \` and silently
    # dropping the trailing `-a joe` from recursion entirely (a real,
    # confirmed bypass). `"([^"\\]|\\.)*"` instead consumes an escaped pair
    # (`\\.` -- backslash + any one character) as a single unit, so it never
    # treats an escaped `\"` as the closing quote; a real, unescaped `"`
    # still ends the match exactly as before. The single-quote alternative
    # is deliberately left as `'[^']*'`: single-quoted shell strings have no
    # escape mechanism at all (a literal `\` inside `'...'` is just a `\`
    # character, and embedding a real `'` requires closing/reopening the
    # quote, a different shape entirely), so there is no equivalent
    # truncation bug to fix there.
    candidates="$candidates
$(printf '%s' "$norm_cmd" \
  | grep -oE -- '(^|[;&|(){])[[:space:]]*(([^[:space:]]*/)?env[[:space:]]+)?([^[:space:]]*/)?(bash|sh|zsh|dash|ash|ksh)([[:space:]]+[^[:space:];&|(){}"'"'"'<>]+)+[[:space:]]+("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"')' \
  | head -n "$MAX_WRAPPER_CANDIDATES" \
  | while IFS= read -r raw; do
      head=$(printf '%s' "$raw" | sed -E 's/".*$//; s/'"'"'.*$//')
      [ -n "$head" ] || continue
      printf '%s' "$masked_cmd" | grep -qF -- "$head" && printf '%s\n' "$raw"
    done \
  | sed -E 's#^[;&|(){]?[[:space:]]*(([^[:space:]]*/)?env[[:space:]]+)?([^[:space:]]*/)?(bash|sh|zsh|dash|ash|ksh)([[:space:]]+[^[:space:];&|(){}"'"'"'<>]+)+[[:space:]]+##' \
  | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"

    # Iterative unswallow (beads_claude_docker-vgr round 2): `grep -oE`
    # finds the LEFTMOST, non-overlapping match, so a decoy quoted string
    # ending in the SAME "interpreter -flags- open-quote" header as a real
    # wrapper gets its match consumed all the way THROUGH the real
    # wrapper's own opening quote -- e.g. `echo "; bash -c " ; bash -c "bd
    # gate create --blocks bd-1"`: the first (decoy) match runs from the
    # semicolon inside echo's own argument through the SECOND `bash -c "`,
    # so the real wrapper's payload is never found as an independent match
    # at all (a real, confirmed bypass -- traced and reproduced).
    #
    # Gated on a cheap count mismatch (beads_claude_docker-vgr round 2,
    # perf follow-up): an EARLIER version of this fix ran the iterative
    # retry unconditionally, which cost an extra full re-extraction PASS
    # PER remaining header even when nothing was swallowed at all -- e.g. a
    # command with 28 genuinely separate, cleanly non-overlapping sibling
    # wrappers paid for ~28 redundant re-scans instead of the single pass
    # above already having found all 28 (measured: this alone was most of
    # a 34KB adversarial input's remaining cost after the node budget was
    # already in place). bashc_header_count counts just the SHORT
    # "interpreter+flags+open-quote" header shape (cheap: no per-candidate
    # containment check); bashc_match_count counts how many FULL
    # header+content+closequote matches the single pass above actually
    # found. When nothing was swallowed these are equal (one full match per
    # header) and the block below never runs -- the common case pays
    # exactly what it did before this round. A real swallow makes
    # header_count strictly greater (the decoy and the real wrapper both
    # have a header, but only one span survived as a full match), which is
    # exactly when it's worth paying for the retry.
    local bashc_header_count bashc_match_count
    bashc_header_count=$(printf '%s' "$norm_cmd" \
      | grep -oE -- '(^|[;&|(){])[[:space:]]*(([^[:space:]]*/)?env[[:space:]]+)?([^[:space:]]*/)?(bash|sh|zsh|dash|ash|ksh)([[:space:]]+[^[:space:];&|(){}"'"'"'<>]+)+[[:space:]]+["'"'"']' \
      | grep -c '.')
    bashc_match_count=$(printf '%s' "$norm_cmd" \
      | grep -oE -- '(^|[;&|(){])[[:space:]]*(([^[:space:]]*/)?env[[:space:]]+)?([^[:space:]]*/)?(bash|sh|zsh|dash|ash|ksh)([[:space:]]+[^[:space:];&|(){}"'"'"'<>]+)+[[:space:]]+("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"')' \
      | grep -c '.')
    if [ "$bashc_header_count" -gt "$bashc_match_count" ]; then
      # After each extraction pass, also find just the FIRST header (no
      # content -- confirmed empirically that these SHORT matches do NOT
      # swallow each other the way the full header+content+closequote match
      # does) and remove ONLY that header text (plain `s/PATTERN/repl/`, no
      # `/g`, already replaces just the first occurrence per POSIX/GNU sed),
      # keeping the separator character before it (`\1`) in place.
      # Re-running extraction on the shortened text lets whatever the
      # removed header had swallowed stand on its own as a fresh match on
      # the next iteration. Bounded by MAX_UNSWALLOW_ITERS (see its own
      # comment above scan_cmd for why this is a bound, not a promise) and
      # a fixed point (stops the moment stripping finds no more header to
      # strip) so this can never spin -- it only ever shortens
      # unswallow_text, so it terminates in at most that many iterations
      # regardless. The decoy's OWN "swallowed" content is
      # harmlessly ALSO added as a candidate along the way (it never
      # contains a bd verb, so the cheap prefilter at the top of scan_cmd
      # discards it immediately) and every recursive call remains bounded
      # by MAX_SCAN_NODES regardless of how many extra candidates this
      # produces.
      local unswallow_text unswallow_i unswallow_stripped
      unswallow_text="$norm_cmd"
      unswallow_i=0
      while [ "$unswallow_i" -lt "$MAX_UNSWALLOW_ITERS" ]; do
        candidates="$candidates
$(printf '%s' "$unswallow_text" \
  | grep -oE -- '(^|[;&|(){])[[:space:]]*(([^[:space:]]*/)?env[[:space:]]+)?([^[:space:]]*/)?(bash|sh|zsh|dash|ash|ksh)([[:space:]]+[^[:space:];&|(){}"'"'"'<>]+)+[[:space:]]+("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"')' \
  | head -n "$MAX_WRAPPER_CANDIDATES" \
  | while IFS= read -r raw; do
      head=$(printf '%s' "$raw" | sed -E 's/".*$//; s/'"'"'.*$//')
      [ -n "$head" ] || continue
      printf '%s' "$masked_cmd" | grep -qF -- "$head" && printf '%s\n' "$raw"
    done \
  | sed -E 's#^[;&|(){]?[[:space:]]*(([^[:space:]]*/)?env[[:space:]]+)?([^[:space:]]*/)?(bash|sh|zsh|dash|ash|ksh)([[:space:]]+[^[:space:];&|(){}"'"'"'<>]+)+[[:space:]]+##' \
  | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"

        unswallow_stripped=$(printf '%s' "$unswallow_text" | sed -E 's#(^|[;&|(){])[[:space:]]*(([^[:space:]]*/)?env[[:space:]]+)?([^[:space:]]*/)?(bash|sh|zsh|dash|ash|ksh)([[:space:]]+[^[:space:];&|(){}"'"'"'<>]+)+[[:space:]]+["'"'"']#\1#')
        [ "$unswallow_stripped" = "$unswallow_text" ] && break
        unswallow_text="$unswallow_stripped"
        unswallow_i=$((unswallow_i + 1))
      done
    fi

    # eval "PAYLOAD" / eval 'PAYLOAD' -- same anchor+strip-mirror approach.
    # Same escape-aware double-quote capture as the bash/sh/zsh -c block
    # above and for the identical reason: `eval "bd create x -d \"n\" -a
    # joe"` would otherwise truncate at the escaped inner quote via this
    # call site instead, just as much a bypass as the -c one.
    candidates="$candidates
$(printf '%s' "$norm_cmd" \
  | grep -oE -- '(^|[;&|(){])[[:space:]]*eval[[:space:]]+("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"')' \
  | head -n "$MAX_WRAPPER_CANDIDATES" \
  | while IFS= read -r raw; do
      head=$(printf '%s' "$raw" | sed -E 's/".*$//; s/'"'"'.*$//')
      [ -n "$head" ] || continue
      printf '%s' "$masked_cmd" | grep -qF -- "$head" && printf '%s\n' "$raw"
    done \
  | sed -E 's/^[;&|(){]?[[:space:]]*eval[[:space:]]+//' \
  | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"

    # Iterative unswallow for eval, same mechanism and same gating as the
    # bash/sh/zsh -c block above (beads_claude_docker-vgr round 2, own
    # adversarial follow-up after the initial fix: `echo "; eval " ; eval
    # "bd gate create --blocks bd-1"` swallows the real `eval` payload
    # through the exact same grep -oE leftmost-match mechanism -- eval was
    # not covered by the first pass of this fix, only bash/sh/zsh -c was).
    local evalq_header_count evalq_match_count
    evalq_header_count=$(printf '%s' "$norm_cmd" \
      | grep -oE -- '(^|[;&|(){])[[:space:]]*eval[[:space:]]+["'"'"']' \
      | grep -c '.')
    evalq_match_count=$(printf '%s' "$norm_cmd" \
      | grep -oE -- '(^|[;&|(){])[[:space:]]*eval[[:space:]]+("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"')' \
      | grep -c '.')
    if [ "$evalq_header_count" -gt "$evalq_match_count" ]; then
      local unswallow_text unswallow_i unswallow_stripped
      unswallow_text="$norm_cmd"
      unswallow_i=0
      while [ "$unswallow_i" -lt "$MAX_UNSWALLOW_ITERS" ]; do
        candidates="$candidates
$(printf '%s' "$unswallow_text" \
  | grep -oE -- '(^|[;&|(){])[[:space:]]*eval[[:space:]]+("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"')' \
  | head -n "$MAX_WRAPPER_CANDIDATES" \
  | while IFS= read -r raw; do
      head=$(printf '%s' "$raw" | sed -E 's/".*$//; s/'"'"'.*$//')
      [ -n "$head" ] || continue
      printf '%s' "$masked_cmd" | grep -qF -- "$head" && printf '%s\n' "$raw"
    done \
  | sed -E 's/^[;&|(){]?[[:space:]]*eval[[:space:]]+//' \
  | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"

        unswallow_stripped=$(printf '%s' "$unswallow_text" | sed -E 's#(^|[;&|(){])[[:space:]]*eval[[:space:]]+["'"'"']#\1#')
        [ "$unswallow_stripped" = "$unswallow_text" ] && break
        unswallow_text="$unswallow_stripped"
        unswallow_i=$((unswallow_i + 1))
      done
    fi

    # eval PAYLOAD (bare, no quotes) -- eval joins its argv with spaces and
    # evaluates it, so the text from `eval` to the next separator IS the
    # command about to run, same as deleting the word `eval `. Requires the
    # first character after `eval` to not be a quote so this never
    # double-extracts a case the quoted pattern above already covers. No
    # quote means `head` (above) always equals the whole raw match here, so
    # the filter reduces to "is this bare-eval text, verbatim, still present
    # in masked_cmd" -- unaffected unless the bare eval itself sits inside
    # another flag's quoted value.
    candidates="$candidates
$(printf '%s' "$norm_cmd" \
  | grep -oE -- '(^|[;&|(){])[[:space:]]*eval[[:space:]]+[^"'"'"'[:space:];&|)}][^;&|)}]*' \
  | head -n "$MAX_WRAPPER_CANDIDATES" \
  | while IFS= read -r raw; do
      head=$(printf '%s' "$raw" | sed -E 's/".*$//; s/'"'"'.*$//')
      [ -n "$head" ] || continue
      printf '%s' "$masked_cmd" | grep -qF -- "$head" && printf '%s\n' "$raw"
    done \
  | sed -E 's/^[;&|(){]?[[:space:]]*eval[[:space:]]+//' \
  | sed -E 's/[[:space:]]+$//')"

    while IFS= read -r inner; do
      [ -z "$inner" ] && continue
      scan_cmd "$inner" $((depth + 1)) "$allow"
    done <<EOF
$candidates
EOF
  fi

  return 0
}

scan_cmd "$command_str" 0 0
exit 0
