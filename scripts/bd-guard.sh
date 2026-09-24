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
#     person's decision (indirect routing via status instead of --assignee);
#     a close/done reason that admits residual work in prose; rule-shaped
#     `bd remember` text; `bd init --reinit-local`/`--force`/
#     `--discard-remote` when `.beads/issues.jsonl` has uncommitted changes
#     (can delete the passive export that is the only rebuild path for the
#     database). Override is for false positives only — e.g. the phrase is
#     quoted content or code under discussion, or the jsonl really is backed
#     up some other way — never to park user work in a bead or skip a real
#     backup. The override is honored two ways: an exported BD_GUARD_ALLOW=1
#     in the hook's environment, OR a literal `BD_GUARD_ALLOW=1 ` assignment
#     written as a prefix on the command string (the form the block message
#     suggests — it never reaches this process's environment, so we detect it
#     in the command text and apply it ourselves).
#
# Contract: wired as a PreToolUse hook on the Bash matcher
# (config/claude-settings.json runs template/bin/bd-guard). Reads the Claude
# Code hook JSON on stdin; exit 0 = allow, exit 2 = block (stderr is fed back
# to the model). Fail-open throughout: unparseable input, and every bound
# below (unwrap depth, node budget, unswallow iterations, candidate cap),
# only ever stops scanning — never itself a block reason — so a bug here
# can't brick every Bash call. Tests: tests/bd-guard.bats (its wrapper scope
# table lists what is BLOCKED, OUT-OF-SCOPE, and pinned). The incident
# narrative behind the rules is in knowledge-base/BEADS_TROUBLESHOOTING.md
# and `git log -p scripts/bd-guard.sh`.
#
# POSIX sh (dash) clean; uses GNU grep/sed -E (the container's) — `\b` is a GNU
# ERE extension and is intentionally avoided here in favor of explicit
# [[:space:]]/anchors so behavior is stable.
#
# How a command is read (each step is explained again where it's built):
#   - Normalization. Every rule runs against a *normalized* view of the
#     command, not the raw string. Tabs are folded to spaces (so a tab
#     between a flag and its value can't hide it), and command-position noise
#     — leading environment assignments (`FOO=1 bd …`), wrapper words
#     (`command bd …`, `env bd …`, `timeout 10 bd …`), shell keywords (`do bd
#     …`) and a self-quoted or escaped `'bd'`/`\bd` — is stripped so `bd` is
#     exposed at a command position for the anchors below.
#   - Segment scoping. The label/gate/human/reinit rules additionally split
#     the command into pseudo-segments on `;`, `&&`, `||`, `|`, and newline,
#     and run per-segment, so a flag that belongs to a *different* bd
#     invocation (after a separator, or on another line) is not read as this
#     one's — e.g. `bd gate create --blocks bd-1 && bd update bd-1 -t chore`
#     must not let the second command's `-t chore` stand in for the gate
#     type. The split is deliberately NOT quote-aware; the soft rules further
#     down (user-directed phrasing, residual-work-in-prose) stay whole-string
#     on purpose instead of adopting it, since legitimate reason/description
#     text may itself contain `;` or `|` as ordinary punctuation — fine for a
#     "does this phrase appear" substring check, not for scoping a flag
#     extraction.
#   - Quote-aware masking. masked_cmd blanks the CONTENT of quoted free-text
#     values (-d/--description, --title, -r/--reason, -m, …) so prose that
#     quotes a prohibited flag or a wrapper is DATA, not command syntax. It
#     feeds every structural extraction, never the prose soft rules, which
#     must keep reading exactly that text. See masked_cmd in scan_cmd().
#   - Shell-wrapper unwrapping. A string matcher never sees `bd` inside
#     `bash -c "bd create ... -a joe"` or `eval '...'` — the payload sits
#     behind a quote character, not one of the `;&|(){` separators every
#     anchor requires. Rather than duplicate the rule logic against a second,
#     wrapper-shaped grammar, scan_cmd() extracts the payload and RECURSES on
#     itself (bounded by MAX_UNWRAP_DEPTH). Nesting cascades only when the
#     inner payload's quotes differ in type from the outer's (`bash -c "eval
#     '...'"` is caught); an escaped same-type inner quote is not (see KNOWN
#     LIMITATIONS).
#
# Flag spellings come from probing bd 1.0.4's own parser in a throwaway
# sandbox, not from --help, which describes only what bd's authors chose to
# publish (beads_claude_docker-v5p, -j72). That found: `bd create` honours an
# undocumented singular `--label` (`bd update`/`bd q` reject it); `done` is
# `bd close`'s alias; create/update/close accept hidden free-text aliases
# (`-m`, `--message`, `--body`, `--resolution`, `--comment` — see
# masked_cmd). Other plausible spellings (`--assign`/`-A`/`--owner` for
# assignee, `--gate-type`/`-T` for gate type, any flag at all on the
# positional-only `bd tag`/`bd label add`/`bd label propagate`/`bd assign`)
# are rejected by bd itself, so they need no rule. Re-probe rather than trust
# --help or an earlier probe when bd is upgraded.
#
# File indirection (--body-file, --design-file, -f, --graph, --stdin/-) is
# deliberately OUT OF SCOPE: those flags need a markdown/JSON issue-format
# parser, not a reuse of this shell-token rule engine; reading the file is a
# TOCTOU race; and it adds a file-I/O fail-open surface out of proportion to
# the gain.
#
# KNOWN LIMITATIONS (accepted, not bugs — read this before assuming argv-
# wrapper evasion is fully closed): ten residual classes are NOT reached by
# the recursion/normalization above, each pinned in tests/bd-guard.bats so
# the gap is mechanically true, not just a claim in this comment:
#   - stdin-fed payloads (`bash <<< "…"`, `echo … | bash`, `bash -s`,
#     `source /dev/stdin`): this hook only ever sees the command STRING,
#     never a future stdin stream, so there is nothing to extract.
#   - single-quote concatenation (`bash -c 'bd create x -d '\''n'\'' -a
#     joe'`): the payload regex has no concatenation grammar, so it stops at
#     the first embedded quote boundary and truncates the payload before the
#     real violation.
#   - nested wrapping through an escaped same-type inner quote (`bash -c
#     "bash -c \"bd create x -a joe\""`, `eval "bash -c \"…\""`, …): the
#     escape-aware capture finds the outer span, but the dequote step strips
#     only the outermost quote pair and never unescapes `\"`, so one level
#     down the candidate match (which needs a BARE quote right after the
#     flag cluster) meets a `\` and fails.
#   - command substitution (`sh -c "$(echo bd create x -a joe)"`, or `bd
#     gate create --blocks bd-1 --type "`echo human`"`): this hook has no
#     shell evaluator, so it sees unevaluated source text — `bd` as an
#     argument to `echo` in the first, a --type value that is literally
#     `` `echo human` ``, not `human`, in the second.
#   - env-assignment strip swallowing an adjacent `$(` (`X=$(bd create x -a
#     joe)`): not a command-position gap — `echo $(bd create x -a joe)` is
#     blocked. The env-assignment strip's greedy `NAME=[^[:space:]]*` value
#     has no notion of `$(...)`, runs to the first whitespace inside it, and
#     deletes `X=$(bd ` before any rule runs.
#   - backtick before `bd` in the per-verb anchors (`bd create x -m "`bd tag
#     bd-1 human`"`): the text is literal and left unmasked, but the tag /
#     label add|propagate / gate create / human / init rules find their
#     invocation through an anchor class (`;&|(){` or whitespace/`{`/`(`)
#     that has no backtick, so to them it is not a command-position boundary.
#     Not the command-substitution class (nothing here needs evaluating),
#     and not the intra-word class below (that one hides `bd` from the
#     prefilter; this one hides an already-found `bd`'s verb from its rule).
#   - variable indirection (`B=bd; $B create x -a joe`): the literal string
#     never contains `bd` followed by a verb, so even the cheap prefilter
#     never engages.
#   - intra-word quoting/escaping of `bd` itself (`b\d create …`, `'b'd
#     create …`, `bd'' create …`, `bash -c $'bd create …'`): normalization
#     and the wrapper grammar both need `bd` as a complete, cleanly delimited
#     token, and `$'…'` is a quote form the candidate regex doesn't know.
#   - flag-VALUE quote/escape concatenation (`--labels hu\man`, `--labels
#     "hu""man"`): the shell yields `human`, but the label extraction keeps
#     the literal token and the rule is an EXACT match. The assignee rule
#     isn't exposed the same way because its check is inverted (anything
#     not an allow-listed agent name blocks).
#   - wrapper-flag arity-table gaps (`sudo -E --preserve-env=PATH bd …`,
#     `env -S "…" bd …`, `command -p bd …`): wrapper-argument stripping is
#     closed, explicit allowlists, not argument parsing, so a flag outside
#     the tables leaves `bd` stranded. Some arities depend on spelling
#     (`--preserve-env` takes an optional value only in its long form; `-E`
#     is bare), so they are left unmodeled rather than guessed at, and
#     widening the tables further trades one enumerable, auditable gap for a
#     larger one of the same shape.
# Threat model: the "attacker" is Claude Code itself drifting toward a
# shortcut, not a determined adversary — this is a guardrail, not a sandbox.
# Most of these classes need knowingly constructed shell syntax to hide
# intent, a different act from typing `timeout 10 bd create x -a joe`
# without thinking, and most would need a real shell-grammar parser (quote
# concatenation, command substitution, variable expansion) — a second, much
# larger rule engine — to close. Two are different: the backtick gap is
# mechanically a one-character widening of two anchor classes, left because
# that would also make them fire on a backtick inside a genuinely inert
# single-quoted value, which this hook can't tell from the live case (see
# the masked_cmd single-quote trade-off); and an arity gap IS the accidental
# shape this hook means to catch — it just misses that one flag until its
# table is widened, and is listed so the picture of coverage stays accurate.
#
# KNOWN FALSE POSITIVES (accepted, not bugs — the mirror image of KNOWN
# LIMITATIONS: the guard BLOCKING something safe. Decision record in
# beads_claude_docker-egc; pinned in tests/bd-guard.bats):
#   - multi-line inline text — heredoc-carried or not — whose embedded
#     EXAMPLE of a bd invocation starts its own line, e.g. a `git commit`
#     message documenting `bd create x -a joe`: hard-blocked, with no
#     override. Two ordinary mechanisms compound. (1) Every command-position
#     anchor includes `^`, and grep/sed read a multi-line string one line at
#     a time, so `^` matches the start of EVERY line — deliberate, since that
#     is what catches a real `do\nbd create x -a joe\ndone`, and a live `bash
#     <<'EOF'` body (quoting the delimiter suppresses expansion, never
#     execution). (2) This file has no model of heredocs or other multi-line
#     values, so inert prose fed to `cat`/`tee`/`git commit -F -` gets the
#     same per-line treatment, and the unscoped assignee extraction then
#     reads the whole $masked_cmd.
#     Rejected fixes, both on empirical grounds: "treat a quoted-delimiter
#     heredoc body as inert" is unsound — whether a body runs depends on its
#     consumer (bash/sh/eval/source vs. cat/tee/git), an open-ended
#     classification on top of delimiter parsing (and `<<-` tab evidence is
#     already gone once tabs are folded), and a probe that blanked such
#     bodies flipped the live `bash <<'EOF'` case from blocked to allowed.
#     "Narrow the masked_cmd substitution fall-back" never reaches this
#     class: no quoted -d/-m value is involved, and even a plain multi-line
#     `-m "..."` can't be masked by per-line sed — fixing that means scanning
#     a joined buffer, a larger change that must keep the `do` keyword catch.
#     Accepted rather than fixed because masking is the highest-risk
#     mechanism in this file (its last two changes each regressed).
#     Workaround: write the text to a FILE and pass the file (`git commit -F
#     /path/to/message.txt`) — file content is the out-of-scope indirection
#     class above. BD_GUARD_ALLOW=1 does NOT help: the rules that fire are
#     HARD. So a bead whose text quotes a prohibited flag can be filed as
#     plain prose, but not once that prose is multi-line with the flag-shaped
#     text starting its own line.

set -u

# Deliberate fail-open: if stdin is not parseable JSON (jq errors), allow the
# command. A bug in this hook must never brick every Bash call in the session.
command_str=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$command_str" ] || exit 0

# Unwrap depth bound: a self-referential or deeply stacked bash -c/eval
# wrapper must not spin. Hitting this bound simply stops unwrapping deeper —
# fail-open, never itself a block reason. 5 comfortably covers realistic
# nesting (`bash -c "eval '...'"` only needs 2 levels).
MAX_UNWRAP_DEPTH=5

# Total-work node budget: depth alone does not bound COST — several wrapper
# candidates at each of several levels cost O(branch^depth) scan_cmd calls,
# since every candidate at every level recurses independently (a hand-built
# 34KB branching input took over 15s unbounded). SCAN_NODE_COUNT is a
# script-global (never `local`ed) counter incremented once at the top of
# every scan_cmd call, across the WHOLE recursion tree — once it exceeds
# MAX_SCAN_NODES, every further call returns immediately, which collapses
# the remaining fan-out to near-zero cost. Fail-open like the depth bound: a
# pathological input degrades to "allow unexamined past this point". 200 is
# far above any realistic command while keeping the worst case fast.
MAX_SCAN_NODES=200
SCAN_NODE_COUNT=0

# Decoy-chain unswallow bound: the iterative-unswallow retry (below) strips
# one swallowing decoy's own header per iteration and re-scans, so a real
# wrapper payload buried behind N chained decoys costs N+1 iterations. This
# is a BOUND, not a promise, like MAX_UNWRAP_DEPTH: more than
# MAX_UNSWALLOW_ITERS decoys and the real payload is not found this way
# (fail-open; see the paired depth-bound tests in tests/bd-guard.bats). 10
# handles any realistic chain while keeping the cost of a FALSE trigger
# (genuinely nested wrappers also show a header/match-count mismatch and
# enter this loop) bounded rather than open-ended.
MAX_UNSWALLOW_ITERS=10

# Per-extraction candidate cap: every wrapper-candidate extraction site runs
# a `head=$(sed ...); grep -qF ...` containment check per raw regex match
# BEFORE any match reaches recursion, so SCAN_NODE_COUNT can't bound it —
# thousands of sibling candidates at one level (`bash -c "..." ; ` repeated
# 8000 times) measured ~50s, and this hook runs before EVERY Bash call.
# Piping the raw `grep -oE` matches through `head -n
# "$MAX_WRAPPER_CANDIDATES"` (all 5 sites) caps that in the same shell; a
# counter threaded through the `| while read` loop would be lost the moment
# that subshell exits. Fail-open: candidates beyond the cap are simply never
# considered. 64 is far above anything a real command needs (the tests top
# out around 10 siblings).
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
# returns; the rule-section working variables get one `local` declaration too,
# for the same guarantee at negligible cost.
scan_cmd() {
  local cmd="$1"
  local depth="${2:-0}"
  local inherited_allow="${3:-0}"

  # Node budget (see MAX_SCAN_NODES above): count this call FIRST, so a call
  # made once the budget is spent costs one comparison. Fail-open.
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
  # as a way to flag an issue for a person. `remember` has its own soft rule
  # outside the create/update/…/init gate below, but must survive this
  # pre-filter to reach it. A wrapped payload is still literal text here, so
  # this works at any depth; and it is `return`, not `exit`, so a sibling
  # wrapper elsewhere in an outer call keeps being checked.
  #
  # `['"]?` after `bd`: a self-quoted `'bd'`/`"bd"` puts its closing quote
  # between "bd" and the space before the verb; without it this check would
  # return before the normalization loop below ever un-quotes it. `\bd` needs
  # no help — its backslash sits before "bd", not after.
  printf '%s' "$cmd_tabs" | grep -qE "bd['\"]?[[:space:]]+(create|new|update|assign|close|done|gate|label|tag|q|human|init|remember)" || return 0

  # Strip command-position noise that would otherwise hide `bd` from the anchors:
  # at the start of the string or right after a ; && || | ( ) separator, remove a
  # leading run of VAR=value environment assignments and wrapper words. Looped
  # because several may stack, e.g. `  FOO=1 command bd create`. sed applies
  # every -e in sequence to the running buffer, so a word stripped by an
  # earlier -e can expose one for a later -e in the same iteration. The
  # clauses, in order:
  #   - timeout|stdbuf|setsid|nice|ionice|script|chrt|taskset take their OWN
  #     leading arguments before the real command (`timeout -k 5 10 bd …`,
  #     `nice -n 10 bd …`, `timeout 10 -- bd …`), so each may be followed by
  #     any mix, in any order, of dash-flags (optionally with one numeric
  #     value) and bare numeric/duration tokens. Both alternatives use
  #     POSITIVE character classes (must start with `-`, or with a digit), so
  #     they can never strip the word `bd` itself; the flag value is
  #     numeric-only for the same reason (every value-taking flag of these 8
  #     words takes a number). A generic "strip any leading token that isn't
  #     `bd`" rule was rejected: at every command position it would also
  #     strip xargs' own `-I{}` and turn the pinned out-of-scope `xargs -I{}
  #     bd create x -a {}` into a false block.
  #   - env/sudo/time get explicit per-tool flag tables (from this
  #     container's `env --help`/`sudo --help`; the `time` keyword takes only
  #     `-p`), in the same bare vs. value-taking shape as the `label add`
  #     flag-strip further down. The tables are deliberately asymmetric:
  #     listing a bare flag as value-taking would swallow the real `bd` as its
  #     argument (unsafe); missing a flag only leaves it stranded (incomplete,
  #     the status quo). `sudo -h` is listed nowhere — it is bare `--help` or
  #     value-taking `--host` depending on build. Flags outside the tables
  #     are a KNOWN LIMITATION.
  #   - VAR=value assignments and the bare words command|builtin|nohup|exec|
  #     xargs. `xargs` passes its own literal argv straight to the child
  #     (`echo x | xargs bd create -a joe` really runs with `-a joe`), so it's
  #     as safe to strip as `command`/`env`. Only the bare `xargs CMD` form is
  #     covered — xargs' own flags and values it appends from stdin stay out
  #     of scope.
  #   - shell reserved words do|then|else|elif|if|while|until|!: neither a
  #     separator nor a wrapper, so `bd` right after one was invisible to
  #     EVERY rule (the gate below decides whether any rule runs at all), and
  #     a for-loop body (`for i in 1 2; do bd update bd-$i -a joe; done`) is
  #     an ordinary way to batch bd calls; `if`/`while`/`until` cover `bd` as
  #     the condition. The COMPLETE word plus trailing whitespace is required,
  #     so `ifconfig bd …`/`doit bd …` are never mistaken for keywords. Like
  #     every clause here this is not quote-aware, so a keyword inside a
  #     free-text value can be stripped too — harmless, since stripping only
  #     widens what reaches the gate, and the hard rules read $masked_cmd,
  #     not this loop's output. A multi-line `do`\n`bd …` needs no clause:
  #     sed reads line by line, so `^` matches the second line's own start.
  #   - `\bd`, `"bd"`, `'bd'` → `bd`: a leading backslash or whole-word quotes
  #     are shell no-ops, and exactly the next thing to try once
  #     `command`/`env` stop working. Only at command position and only as a
  #     complete token (trailing whitespace required), so `\bdaily` or a
  #     quoted `bd` inside prose is never touched.
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

  # Quote-aware masking: text inside the quoted VALUE of a free-text bd field
  # is DATA, never command syntax -- e.g. -d "example: bd create x -a joe"
  # must not read as a real -a flag, and -d "example: (bash -c 'bd create x
  # -a joe')" must not read as a real wrapper. masked_cmd blanks the CONTENT
  # of quoted values of the flags below (quote characters kept, interior
  # emptied) and feeds every STRUCTURAL extraction site below (segments,
  # assignee, labels, gate --type, bare `bd human <id>`, and wrapper-candidate
  # filtering further down) -- it is deliberately never used by the prose
  # SOFT rules (user-directed phrasing / blocked-status prose / residual-
  # work-in-close-reason), which stay on the unmasked $norm_cmd because
  # reading the real text of exactly these fields IS their job: "does this
  # bead's own description/notes/reason say 'ask the user'".
  #
  # Flag list: -d/--description, --title, --notes, --design, --acceptance,
  # -r/--reason, plus the hidden aliases found by probing bd 1.0.4 (in no
  # --help; each confirmed by running it and reading back `bd show --json`):
  # `-m`/`--message` on create/update, `--body` on create, and `-m`/
  # `--message`/`--resolution`/`--comment` on close (beads_claude_docker-j72).
  # Plausible near-misses (`--desc`, `--text`, `--note`, `--ac`, `--name`,
  # `-T`, …) are rejected by bd. The aliases are also rejected on every other
  # guarded verb, so masking them there only blanks prose that could never be
  # a real flag. Bare `-t` is deliberately NOT included: it is ALWAYS --type
  # (issue type on create/update, gate type on gate create), a structural,
  # security-relevant enum, and --title has no short form; masking bare -t
  # would let a quoted `bd gate create -t "human"` slip the hard gate-type
  # rule. `bd edit` is out of scope everywhere in this file: its flags only
  # select fields to open in $EDITOR, so it can express no hard-rule
  # violation and can't run non-interactively from a Bash tool call.
  #
  # The separator is OPTIONAL for the short flags (-d, -r, -m) because bd
  # honours the glued `-d"text"`/`-dtext` form, same as `-a` in the assignee
  # rule. Long flags require `=` or whitespace because bd rejects a glued long
  # flag (`--descriptionGLUED "x"` -> unknown flag), so widening there would
  # only mask text that could never be that flag's real value.
  #
  # Only QUOTED values are masked: an unquoted value is shell-split on
  # whitespace into separate argv tokens, so it can never smuggle a
  # space-containing flag like `-a joe` as a single word. An unterminated
  # quote fails to match and is left untouched -- fail-open by construction
  # (fixes nothing, invents no new bypass), never a crash.
  #
  # Neither quote style masks a span containing `$` or a backtick (all four
  # character classes exclude both); such a span is left whole and scanned
  # raw, never partially masked around the substitution. Double quotes are
  # not inert: bash EXECUTES `$(...)`/backticks inside them before bd runs,
  # so blanking `-m "$(bd create y --labels human)"` would destroy the only
  # evidence of a live payload. Single quotes are inert only when they are
  # the real, active delimiters, which scan_cmd cannot know: a wrapper's
  # payload is re-scanned as a literal substring, so in `bash -c "bd create x
  # -m 'hi $(bd create y --labels human)'"` the `'...'` sits inside the OUTER
  # double quotes, where the substitution runs while bash -c's argument is
  # built. Both were live bypasses (beads_claude_docker-j72). The price is an
  # occasional false positive: inert prose with a stray `$`/backtick ("costs
  # $5", `'run $(date) first'`) is scanned raw, which only blocks if that
  # text ALSO matches a rule. This is not the "command substitution" KNOWN
  # LIMITATION: that one needs evaluation; here the payload is already
  # literal text, and the bug was masking away what the hook could see.
  #
  # Alternation order is safe: POSIX/GNU ERE alternation is leftmost-longest
  # per position, not first-alternative-wins (the same argument as `--label`
  # vs `--labels` at label_flags_raw), and no alternative in these lists is a
  # textual prefix of another.
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

  # Pseudo-segments of the MASKED command, one per single command/pipeline
  # stage: split on ; && || | and newline (see header comment for why this is
  # deliberately not quote-aware). Built from masked_cmd, not norm_cmd, so
  # text like `-d "example: bd gate create --blocks bd-1"` or `-d "see also bd
  # human bd-1"` can't look like a second bd invocation to the per-segment
  # gate/label/human checks below. A command with no free-text-flag content
  # is unaffected (masked_cmd == norm_cmd for it). Consumed with
  # `while IFS= read -r` below so each rule that needs single-invocation
  # scope can check every segment independently.
  segments=$(printf '%s' "$masked_cmd" | sed -E 's/(&&|\|\||[;|])/\n/g')

# --- HARD RULE: assignee must be Claude/agent, never a human -----------------
# Covers: bd create/update ... --assignee X | --assignee=X | -a X | -a=X | -aX
#         bd assign <id> <name>
# The short flag -a is anchored at a token boundary (start or whitespace) so it
# never matches inside a long flag like --all or --assignee; bd's parser accepts
# the spaced, =-glued, and value-glued spellings, so all three are extracted.
# Reads $masked_cmd, so `-a joe` appearing only inside the quoted value of
# -d/--notes/--reason/etc is DATA, not a real assignee.
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
#   bd create ... --labels X | --label X | -l X   (--label: undocumented,
#                                                   honoured on create only)
#   bd update ... --add-label X | --set-labels X
#   bd q ... -l X | --labels X             (quick-capture's own label flags)
#   bd tag <id> <label>                    (shorthand for --add-label)
#   bd label add <id...> <label> [flags]   (flags may trail the label)
#   bd label propagate <parent-id> <label> [flags]
# --remove-label is deliberately NOT matched — removing the label un-flags the
# bead and is never itself a violation. Values are comma-splittable since
# --labels/--label/--add-label/--set-labels accept comma lists.
# `bd tag` checks EVERY token after the id, not just the first: bd takes one
# label and would reject a third token, but reading only the first let `bd
# tag bd-1 "x" human` through uninspected, and catching the extra token is
# the safe direction (an occasional false positive beats any bypass). Each
# token lands on its own line for the per-line loop below.
tag_label=""
if printf '%s' "$masked_cmd" | grep -qE '(^|[;&|(){])[[:space:]]*bd[[:space:]]+tag[[:space:]]+'; then
  tag_label=$(printf '%s' "$masked_cmd" \
    | sed -nE 's/.*bd +tag +[^ ]+ +(.*)/\1/p' \
    | grep -oE -- '"[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|)]+' \
    | sed -E 's/^["'"'"']//; s/["'"'"']$//')
fi
# `label add`/`label propagate`: bd's flag parser accepts flags after
# positional args (`label add <id> human --json`), so the label is not
# reliably the LAST token of the whole string, and a whole-string grab also
# reads past this invocation into a later command (`label add bd-1 human &&
# echo done`). So: scope to the single-invocation segment, strip every known
# global/command flag (with its value where it takes one), then take the
# last remaining token as the label.
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
# --label (bare singular, beads_claude_docker-v5p): NOT in `bd create --help`,
# but a real, honoured alias for --labels (space- or =-glued,
# comma-splittable). Matched blind to which verb precedes it: `bd update`/
# `bd q` reject this flag (`Error: unknown flag: --label`), so blocking it
# there is a harmless over-block of a command that would fail anyway. The
# mandatory trailing `(=|[[:space:]]+)` keeps it from matching as a prefix of
# `--labels` itself: `--labels human` has `s`, not `=`/space, after
# `--label`.
# The trailing strip removes a whole RUN of quote/apostrophe/BACKTICK (`+$`),
# not one character: when masked_cmd leaves a `$`/backtick value unmasked,
# `-m "`bd create y --labels human`"` reaches this extraction with its
# enclosing delimiters attached, and the bare-token branch grabs `human` +
# backtick + `"` as one token, which then fails the exact `= "human"` match.
# Narrowing the extraction class instead was tried and reverted: it breaks
# genuine concatenated values like `--labels "a",human` (one argv word,
# pinned by the "sh -c with an escaped inner quote in a labels list" test) by
# stopping at `"a"`. Only this site needs it: of the sites a backtick can
# reach, only the label check is an EXACT match — the assignee check is
# inverted (a stray backtick still isn't an agent name), and tag/label add/
# gate --type can't be reached through a backtick at all (see KNOWN
# LIMITATIONS).
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
# Scoped to the single `bd gate create ...` segment; within it the LAST
# --type/-t wins, because that is the type bd itself applies (confirmed
# against a sandbox bd: `--type=timer --type=human` creates a human gate).
# Segments come from $masked_cmd, so flag-shaped prose in a -r/--reason value
# (`-r "then use -t timer"`) is blanked and can't pose as a real --type
# (beads_claude_docker-v5p). Segment scoping also stops a later command's
# `-t chore` (`... --type=human && bd update bd-1 -t chore`) from standing in
# for this one's.
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
# subcommands list/respond/dismiss/stats (`bd human <id>` just prints the
# help menu and leaves the issue untouched). Block the bare form anyway: it
# is still the documented-but-wrong path an agent would reach for to route a
# bead to a person, and blocking it defends against both that confusion and
# a future bd version where it does something. The real subcommands view or
# discharge issues that are ALREADY human-labeled (not a new routing action)
# and pass through, as does `--help`/no-argument.
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
# (beads_claude_docker-o15) issues.jsonl is the passive, git-tracked export
# and the only way to rebuild the database if the live Dolt DB is lost; a
# reinit once committed its removal. bd's OWN init-safety contract (`bd help
# init-safety`) only gates REMOTE Dolt-history divergence, not this local
# file, which is exactly the gap this rule closes. A plain `bd init` (no
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
# (beads_claude_docker-v5p failure shape 2) `bd update bd-1 -s blocked --notes
# "pending decision"` parks a bead on a person exactly as much as a human
# --assignee does, just via the status field. Reuses $joined (the same "ask
# the user"/"waiting for Joe" phrasing above) plus a second, person-agnostic
# pattern for phrasing that doesn't name anyone but still reads as "a human
# must act" in a blocked-status context — a *bead* can't itself be "pending a
# decision"; only a person can be. SOFT, not hard: free text has legitimate
# false-positive shapes here exactly like the general user-directed-phrasing
# rule above.
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
# are exempt. `done` is `bd close`'s own alias and must be matched here too:
# this `if` re-derives close-ness itself rather than reusing the outer gate's
# match, so without it `bd done <id> --reason "..."` would pass every other
# rule and silently skip this one.
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
  # Checked OUTSIDE the create/update/…/init gate above: `remember` has none
  # of the structural flags that gate scopes segments/masking for, so it
  # needs only the pre-filter plus $norm_cmd/$allow, both computed above
  # regardless of which verb matched.
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

  # --- Shell-wrapper unwrapping ---------------------------------------------
  # bash -c/sh -c/zsh -c and eval hide a bd invocation from every rule above:
  # the payload sits inside a quoted (or, for bare eval, unquoted) string, so
  # `bd` is preceded by a quote character, not a `;&|(){` separator. This
  # extracts the payload and RECURSES scan_cmd on it, so the exact same rules
  # above apply to whatever is actually going to run. Runs regardless of
  # whether the `if` above matched, since the bd verb this level is looking
  # for may be exactly one wrapper layer down. Depth is bounded
  # (MAX_UNWRAP_DEPTH) -- hitting the bound simply stops unwrapping
  # (fail-open). `allow` is threaded to children because a leading
  # `BD_GUARD_ALLOW=1` (literal or exported) genuinely IS inherited by a
  # spawned bash -c/eval child's environment, same as any other env var.
  #
  # Candidate filtering against masked_cmd: raw candidates are found in the
  # UNMASKED $norm_cmd, because a genuine wrapper's payload must keep its real
  # text (`bash -c "bd create x -d 'ask Joe to decide'"` must still reach the
  # soft rule one level down; extracting from masked_cmd would blank that
  # value and turn a real evasion into a silent bypass). masked_cmd decides
  # only whether a match is a REAL wrapper: `head` is the match cut at its
  # first quote character (for bare eval, the whole match) -- the wrapper
  # word and flags, none of the payload. A genuine wrapper's head sits outside
  # any quoted free-text value, so it survives masking as a literal substring
  # of masked_cmd; a wrapper-SHAPED example inside another flag's quoted value
  # (`-d "... (bash -c '...') ..."`) is blanked, head included, so it is
  # discarded before recursion. A head that coincidentally matches unrelated
  # real wrapper text elsewhere is kept -- the safe direction.
  if [ "$depth" -lt "$MAX_UNWRAP_DEPTH" ]; then
    local candidates=""
    local raw head

    # bash -c "PAYLOAD" / sh -c 'PAYLOAD' / zsh -c "PAYLOAD" (also dash —
    # /bin/sh in this image — ash and ksh), optionally path-prefixed (/bin/sh
    # -c, /usr/bin/bash -c) and optionally behind `env`/`/usr/bin/env`. Anchored
    # the same way as every command-position rule above; the sed strip mirrors
    # the grep anchor exactly (no leading .*) so a payload that itself contains
    # " -c " or " eval " can't cause the wrong substring to be stripped.
    #
    # Flag cluster: bash reaches -c's "next arg is the command string" mode
    # through `-lc`, `-ec`, `--norc -c`, `-O extglob -c`, and `-c -x`/`-x -c`
    # in either order (`bash -c -x "echo hi"` does run it). So the cluster
    # group accepts ANY 1-or-more tokens that aren't whitespace, a separator,
    # a quote or `<`/`>`, with no letter or order requirement -- simpler,
    # closes the ordering gap, and only ever WIDENS what's a candidate (the
    # safe direction). `<`/`>` are excluded so `bash <<< "..."` stays the
    # pinned stdin-fed limitation rather than a false block. It does NOT match
    # a bare `bash "quoted"` with zero flags (`+`, not `*`): without -c, bash
    # treats a bare quoted argument as a script FILENAME, not inline code.
    #
    # Escape-aware payload capture: `"([^"\\]|\\.)*"` consumes an escaped pair
    # (backslash + any one character) as one unit, so an escaped `\"` in the
    # payload (`bash -c "bd create x -d \"n\" -a joe"`) can't end the match and
    # truncate `-a joe` away from recursion. The single-quote alternative stays
    # `'[^']*'`: single-quoted shell strings have no escape mechanism at all,
    # so there is no equivalent truncation to fix there.
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

    # Iterative unswallow: `grep -oE` finds the LEFTMOST, non-overlapping
    # match, so a decoy quoted string ending in the SAME "interpreter -flags-
    # open-quote" header as a real wrapper gets its match consumed all the way
    # THROUGH the real wrapper's own opening quote -- in `echo "; bash -c " ;
    # bash -c "bd gate create --blocks bd-1"` the real payload is never found
    # as an independent match at all.
    #
    # Gated on a cheap count mismatch so the common case pays nothing extra
    # (running the retry unconditionally cost a full re-extraction pass per
    # header even when nothing was swallowed): bashc_header_count counts the
    # SHORT "interpreter+flags+open-quote" header shape, bashc_match_count the
    # FULL header+content+closequote matches the single pass above found. They
    # are equal when nothing was swallowed; a real swallow leaves more headers
    # than full matches, which is exactly when the retry is worth paying for.
    local bashc_header_count bashc_match_count
    bashc_header_count=$(printf '%s' "$norm_cmd" \
      | grep -oE -- '(^|[;&|(){])[[:space:]]*(([^[:space:]]*/)?env[[:space:]]+)?([^[:space:]]*/)?(bash|sh|zsh|dash|ash|ksh)([[:space:]]+[^[:space:];&|(){}"'"'"'<>]+)+[[:space:]]+["'"'"']' \
      | grep -c '.')
    bashc_match_count=$(printf '%s' "$norm_cmd" \
      | grep -oE -- '(^|[;&|(){])[[:space:]]*(([^[:space:]]*/)?env[[:space:]]+)?([^[:space:]]*/)?(bash|sh|zsh|dash|ash|ksh)([[:space:]]+[^[:space:];&|(){}"'"'"'<>]+)+[[:space:]]+("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"')' \
      | grep -c '.')
    if [ "$bashc_header_count" -gt "$bashc_match_count" ]; then
      # Each pass removes only the FIRST short header (short matches do NOT
      # swallow each other, confirmed empirically; plain `s///` without `/g`
      # replaces just the first occurrence), keeping the separator before it
      # (`\1`), so whatever it had swallowed stands on its own as a fresh
      # match on the next pass. Bounded by MAX_UNSWALLOW_ITERS and a fixed
      # point (stops when no header is left to strip), and the text only ever
      # shortens, so this can never spin. The decoy's own content is
      # harmlessly added as a candidate too (it has no bd verb, so the
      # pre-filter at the top of scan_cmd drops it), and every recursive call
      # stays bounded by MAX_SCAN_NODES.
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

    # eval "PAYLOAD" / eval 'PAYLOAD' -- same anchor+strip-mirror approach, and
    # the same escape-aware double-quote capture for the same reason: `eval
    # "bd create x -d \"n\" -a joe"` would otherwise truncate at the escaped
    # inner quote.
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
    # bash/sh/zsh -c block above: `echo "; eval " ; eval "bd gate create
    # --blocks bd-1"` swallows the real eval payload through the same
    # `grep -oE` leftmost-match mechanism.
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
    # double-extracts a case the quoted pattern above already covers. With no
    # quote, `head` (above) is the whole raw match, so the filter reduces to
    # "is this bare-eval text, verbatim, still present in masked_cmd" --
    # false only when the bare eval itself sits inside another flag's quoted
    # value.
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
