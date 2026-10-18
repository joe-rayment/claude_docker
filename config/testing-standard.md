<!-- Copied from joe-rayment/test-suite docs/TESTING.md @ 135a625 (2026-10-18); config-sync ships it as ~/.claude/TESTING.md. Edit it there, then re-copy. -->

# Testing standard

How automated code tests are written, sized and run, for any codebase and any
CI/CD pipeline, whoever or whatever writes or runs them. It follows
*Software Engineering at Google* (ch. 11–14, 23, free at
https://abseil.io/resources/swe-book). Where Google weighed a trade-off and
chose *less* (fewer tests per run, fewer tests kept, less fidelity where it
doesn't pay), we take their trade-off. The goal is not more testing. It is
fast feedback you can trust.

## In one screen

1. **Every test has a size** (small, medium or large), set by what the test
   does. The size sets its time limit and the pipeline stage it runs in.
2. **Gate merges on fast, reliable tests.** Larger tests run after merge or
   before release, in batches. Broken builds are fixed or rolled back
   quickly.
3. **A test exists because someone relies on that behavior.** It is never
   there to raise coverage or to pin wording.
4. **Write every test for a stranger reading it at failure time.** The name
   gives the scenario and the outcome, a comment says why, and the body shows
   cause then effect with the expected values written out.
5. **Unreliable tests leave the gate the day they're seen.** Tag them
   `flaky`, then fix or delete them.
6. **Overhaul by labeling and pruning, not rewriting.** A good test never
   needs to change.
7. **Make failures cheap to explain.** The machine finds the breaking commit
   (`git bisect run`), fakes are checked against the real thing, and rules
   about code shape live in linters, not tests.

## Sizes

"The most important qualities we want from our test suite are speed and
determinism." (ch. 11) Size is a promise about both. It is defined by what a
test is *allowed to do*, not by how long it happened to take.

| Size | Allowed | Time limit | Runs in |
|---|---|---|---|
| **small** | its own temp files and the programs it starts and waits for. No network, no `sleep`, no fixed ports, nothing shared with other tests | 60 s | local edit loop, pre-merge CI |
| **medium** | everything small may do, plus localhost services, background processes, waiting or polling, and containers on the same machine | 300 s | pre-merge CI if hermetic, else post-merge |
| **large** | everything medium may do, plus the network, real external services, browsers and other machines | 900 s | post-merge, nightly, release candidates |

**Trade-offs we make on purpose:**
- Google's small test runs in a single process. For command-line tools, the
  thing under test *is* a process, so we keep the purpose (fast,
  deterministic) and allow child processes and temp files.
- Bazel treats an untagged test as medium. We run untagged tests with the
  small ones, under the 60 s limit. That gives a suite a fast lane before
  anyone has tagged anything, and a slow untagged test shows itself the first
  time it hits the limit.

### Tagging and selecting, per framework

| Framework | Tag a test | Run the fast set (small, not flaky) |
|---|---|---|
| bats | `# bats test_tags=size:medium` above `@test` · `# bats file_tags=size:large` for a whole file | `timeout 60 bats --filter-tags '!size:medium,!size:large,!flaky' -r tests` |
| pytest | `@pytest.mark.medium` · whole module: `pytestmark = pytest.mark.large` (register the markers in `pytest.ini`) | `timeout 60 pytest -m 'not medium and not large and not flaky'` |
| JUnit 5 | `@Tag("medium")` | Maven `-DexcludedGroups=medium,large,flaky` · Gradle `excludeTags 'medium', 'large', 'flaky'` |
| Go | `if testing.Short() { t.Skip("medium") }` in tests that aren't small | `go test -short -timeout 60s ./...` |
| JS (node:test, Jest, Vitest) | name the file `*.medium.test.js` or `*.large.test.js` | point the fast run at the remaining `*.test.js` files |

The time limit comes from the shell (`timeout 60 …`; on macOS `gtimeout` from
coreutils), from the runner (`go test -timeout`), or from a timeout on the CI
step. Exit code 124 means `timeout` stopped the run, so the test isn't the
size it claims. Tag it larger or make it faster.

## When tests run

Google: "Most teams at Google run their small tests (like unit tests) on
presubmit — these are the obvious ones to run as they tend to be the fastest
and most reliable." Why not run everything before every merge? "It's too
expensive. Engineer productivity is extremely valuable, and waiting a long
time to run every test during code submission can be severely disruptive."
The price is spelled out too: "You can accept some loss of coverage on
presubmit, but that means you need to catch any issues that slip by on
post-submit, and accept some number of rollbacks." (ch. 23)

| Stage | What runs | Gates? | Typical time |
|---|---|---|---|
| **Edit loop** (your machine) | small tests for the code you changed: `grep -rl <changed file name> tests/` finds them | — | seconds |
| **Pre-merge** (CI on each pull request or push) | all small tests, plus medium tests that are hermetic and reliable; never `flaky` | yes | a few minutes |
| **Post-merge** (CI on the main branch, or nightly) | everything, `flaky` included (reported, not gating) | no, but a red main gets fixed or reverted first | as long as it takes |
| **Release candidate** (CD, before deploy) | large end-to-end tests against a production-like environment | blocks the release | as long as it takes |

- **Let the machine find the culprit.** When a batched run goes red, don't
  rerun suites by hand to see what broke. `git bisect run <that one test's
  command>` checks out the commit halfway between the last green run and the
  first red one, runs the test there, and keeps halving. 1,000 commits take
  about 10 runs. Google's TAP does the same with batches ("culprit finding").
  The Test Hub's History offers it as "find the commit".
- **Revert first, investigate second.** On a red main, "it is imperative that
  the change be fixed quickly". Reverting the culprit is the quickest fix, and
  "accept some number of rollbacks" is part of the price of a fast gate
  (ch. 23).
- **Parallel runs trade CPU for people's time.** "Parallelization… increases
  the cost of CPU time, but it can provide a large savings in developer time."
  (ch. 13) Use `bats --jobs 8` (needs GNU `parallel`), `pytest -n 8` (needs
  `pytest-xdist`), or CI sharding. They only work once tests are hermetic
  (below).
- **Results are machine-readable.** Every run writes JUnit XML
  (`bats --report-formatter junit`, `pytest --junitxml`). CI systems, the Test
  Hub and humans all read that one format.

## What deserves a test

- **The Beyoncé Rule:** "If you liked it, then you shoulda put a test on it."
  Test the behaviors people rely on, and every bug you have fixed.
- **Not coverage.** When coverage becomes a target, "instead of treating 80%
  like a floor, engineers treat it like a ceiling." (ch. 11) Look at it, but
  never make it a bar.
- **Not wording.** A test that greps a document or source file for a phrase
  breaks when someone rewords it and protects no behavior. Google calls a test
  brittle when it "fails in the face of an unrelated change… that does not
  introduce any real bugs" (ch. 12). If a program reads that text (a parser
  that looks for a marker), test the program instead.
- **Mostly narrow tests.** As a rough mix, Google aims for "around 80%…
  narrow-scoped unit tests… 15%… integration tests… and 5% end-to-end tests"
  (ch. 11). A suite that is mostly end-to-end (the "ice cream cone") is "slow,
  unreliable, and difficult to work with".
- **Large tests cover what small ones can't.** Google lists the reasons for
  larger tests: unfaithful doubles, configuration issues, issues under load,
  unanticipated behaviors, and emergent behaviors (ch. 14). A large test that
  re-checks logic a small test already covers is slow duplication, so each
  large test should name the risk it covers. Start with one **deployment
  smoke test** per deployable: start it with its real configuration and
  check that it comes up. "At Google, configuration changes are the number
  one reason for our major outages." (ch. 14)
- **Every test has a price.** It is code to maintain and time on every run:
  "one second extra per test case may be reasonable if there are five test
  cases, but not if there are 500." (ch. 13)

## Readable tests

Write every test for someone who has never seen it and is reading it because
it just failed. "Tests do not test themselves, and we rarely write tests for
our tests—a human must ensure that tests are valid." ([Google code review
guide][review]) A test that can't be read can't be trusted.

- **The name says the scenario and the outcome.** "Make sure test names
  contain both the scenario being tested and the expected outcome." Then
  "when a test fails, you can immediately see what functionality is broken
  without looking at the test's source code." `isUserLockedOut_invalidLogin`
  names only a scenario; `isUserLockedOut_lockOutUserAfterThreeInvalidLoginAttempts`
  says what should happen. ([Writing Descriptive Test Names][names])
- **Comments say why, and live next to the code.** "Most of the documentation
  an engineer at Google writes comes in the form of code comments" (ch. 10),
  because a comment travels with the code it explains. Use one to "reveal your
  intent: explain why the code does something (as opposed to what it does)",
  and "avoid comments that just repeat what the code does". Before writing a
  comment that says *what*, try a better name or an explaining variable.
  ([To Comment or Not to Comment?][comment]) A test's reason sits in a comment
  right above it (`# Guards:` or a docstring).
- **One scenario per test.** "One sign that you might be testing more than one
  scenario: after asserting the output of one call to the system under test,
  the test makes another call to the system under test." Split the test, so
  each scenario fails and is named on its own. ([Keep Tests Focused][focused])
- **Cause, then effect, in the same test.** "Write tests where the effects
  immediately follow the causes." An assertion whose setup is 200 lines away
  in a shared `setUp` can't be checked by eye. ([Keep Cause and Effect
  Clear][cause])
- **State inputs and outputs. Don't compute them.** "Tests can avoid
  complexity by stating their inputs and outputs directly rather than
  computing them. Otherwise it's easy for tests to develop their own bugs."
  Google's example builds an expected URL as `baseUrl + "/u/0/photos"`, which
  hides a doubled slash. Written out as a literal, the bug is obvious. Loops
  and branches in a test need their own scrutiny. ([Don't Put Logic in
  Tests][logic])
- **DAMP over DRY.** "Since tests don't have tests, it should be easy for
  humans to manually inspect them for correctness, even at the expense of
  greater code duplication." Use helpers to hide irrelevant detail, never the
  part the test is about. ([Tests Too DRY? Make Them DAMP!][damp])
- **Complete and concise.** "A test is complete when its body contains all of
  the information you need to understand it, and concise when it doesn't
  contain any other distracting information." A bare `assertEquals(5, result)`
  leaves the reader asking where 5 came from. ([What Makes a Good Test?][good])
- **Check the goal, not the code's current shape.** A test that mirrors the
  implementation, such as a list of which calls happened in which order, is a
  change detector. "Change detectors provide negative value, since the tests
  do not catch any defects, and the added maintenance cost slows down
  development." ([Change-Detector Tests Considered Harmful][detector]) The
  review guide asks: "Will the tests actually fail when the code is broken?…
  Does each test make simple and useful assertions?"
- **Say what went wrong.** "An engineer could diagnose a problem just from
  reading its failure message" (ch. 12). Show expected and actual values
  (`assert_output` in bats-assert, `assert x == y` in pytest, `assertEquals`),
  not a bare true/false.

The Test Hub shows each test in this order: why it exists, what it does, then
what it checks. Next to each other, these show whether the checks really
express the goal. It adds a short note, linked to the Google source, only when
it can tell for certain:
- a second scenario;
- a loop or branch;
- a `sleep`;
- a one-word name;
- a failure that hides the values.

## How to write one

- **Through the front door.** Call the code the way its users do (the CLI, the
  public function, the HTTP endpoint), then check what comes back. "In most
  cases, tests should focus on testing your code's public API, and your code's
  implementation details shouldn't need to be exposed to tests." ([Test
  Behavior, Not Implementation][behavior])
- **Check results, not calls.** Assert on outputs and resulting state, not on
  which functions or commands ran. "Interaction testing should be avoided when
  possible" (ch. 13). The exception is when the call *is* the behavior ("never
  sends the email twice") and a recording fake is the only witness.
- **Real, then fake, then stub.** "Our first choice for tests is to use the
  real implementations" (ch. 13). A real `git` in a temp folder or an
  in-memory database is fine. External systems (cloud services, third-party
  APIs, databases you can't run locally) get a fake. A recorded real response
  saved as a fixture also works: re-record it when the service changes
  (ch. 14, record/replay).
- **Fakes get contract tests.** "A fake must have its own tests to ensure that
  it conforms to the API of its corresponding real implementation" (ch. 13).
  Write one test file against the interface and run it twice: against the
  fake (small, every pull request) and against the real service (large,
  nightly, in the CI job that holds the credentials). When the real service
  changes, the nightly run goes red before the faked suite starts passing on
  a lie.
- **Refactors don't touch tests.** Google sorts changes into four kinds: pure
  refactorings, new features, bug fixes and behavior changes. A behavior
  change "is the one case when we expect to have to make updates to the
  system's existing tests" (ch. 12). If a refactor forces test edits, those
  tests check implementation details. Fix how they test, not only what they
  assert.
- **Never sleep to wait.** Poll for the state with a short deadline: "A better
  solution is to actively poll for a state transition" (ch. 11). A test that
  waits is at least medium. A fake should answer at once, never after a delay.
- **Hermetic.** Use only the test's own temp folder (`$BATS_TEST_TMPDIR`,
  pytest's `tmp_path`, `t.TempDir()`), no fixed ports, no shared files, no
  dependence on run order. Then tests can run in parallel and in any CI.
- **A header that says why.** Each test file opens with what it protects
  (`Guards:`), a concrete way to break it (`Fails if:`), and the command that
  runs it (`Run:`).

## Checks that aren't tests

Rules about what code *looks like* belong in a linter, not in tests that grep
source files. Examples: "every script sets `-euo pipefail`", "no hard-coded
home paths", "the Dockerfile pins its versions". A linter (shellcheck, ruff,
eslint, hadolint, or a ten-line custom rule) runs in milliseconds, points at
the exact line, and often fixes it. Static analysis lets "more expensive
processes (such as human review and testing) to focus on issues that are not
mechanically verifiable" (ch. 20).

Google's bar for a check:
- it is actionable;
- it has under 10% "effective false positives", meaning findings developers
  don't act on;
- a check people learn to ignore gets fixed or removed.

Run linters in the edit loop and the pre-merge gate.

## Flaky tests

"As you approach 1% flakiness, the tests begin to lose value" (ch. 11). A
failure you can't trust is worse than no test.

- A test that fails and then passes with no code change is flaky. Tag it
  `flaky` the same day. It leaves the pre-merge gate but still runs post-merge,
  where its failures are reported but don't block anyone. Then fix it (usually
  a sleep, a shared file, or ordering) or delete it.
- Google accepts automatic reruns at low flake rates ("trading CPU cycles for
  engineering time"), but warns that "rerunning a test is only delaying the
  need to address the root cause". We don't auto-retry. The tag keeps the
  debt visible.
- For large tests that fail for reasons unrelated to the change, Google's
  advice is to "disable them aggressively when they start failing" (ch. 23),
  then repair them off the critical path.

## Indicators, not gates

Track each test's duration and flag big slowdowns (the Test Hub marks a test
more than 2× slower than its last run). Track coverage if you like. Neither
ever fails a build: Google's Project Health tracks "test coverage and test
latency" as information, not as bars.

## Overhauling an existing suite

Google rolled testing out through "Test Certified". Level 1 was to "classify
all your tests as small, medium, or large; identify (but don't necessarily
fix) flaky tests; and create a set of fast (not necessarily comprehensive)
tests that can be run quickly." (ch. 11) Rewriting everything is the
maximalist trap: "the ideal test is unchanging." (ch. 12)

1. **Label.** Run each test file once, timed. Files that sleep, start
   services, or take more than 60 s become medium or large. Goal: a fast set
   that finishes in under a minute.
2. **Quarantine.** Tag `flaky` on anything that flips without a code change.
3. **Prune.** Turn source-text checks into lint rules, delete wording
   checks, and delete repeats of the same behavior at a bigger size.
4. **Speed up the worst offenders.** Turn sleeps into polls, slow fakes into
   instant ones, and heavy shared setup into minimal per-test setup.
5. **Leave the rest alone.** Rewrite a test only when you are changing its
   code and it gets in the way.

**Signs a suite has grown maximalist:**
- nothing is sized, so every run is the whole run;
- there are no time limits;
- tests use `sleep` (fakes that sleep for seconds are the worst);
- one giant shared setup file;
- tests grep docs or source for wording (make them lint rules or delete them);
- fakes that nothing checks against the real thing;
- large tests that repeat what small tests already check;
- many assertions check how a stub was called;
- the habit of running everything after every change and waiting for it.

Often the tests themselves are fine, with Google's shape of
"give it input, check the output". The cost is in how they are sized and run.

## Where we differ from Google, on purpose

- Small tests may start processes and write temp files.
- Untagged tests run with the small ones, under the 60 s limit, instead of
  defaulting to medium.
- Coverage is never a target, and failing tests are not retried
  automatically.

## Sources

- *Software Engineering at Google*, ch. 10–14, 20, 23: https://abseil.io/resources/swe-book
- Google code review guide, "What to look for in a code review" (Tests,
  Naming, Comments): https://google.github.io/eng-practices/review/reviewer/looking-for.html
- Google Testing Blog, Testing on the Toilet episodes linked above.

[review]: https://google.github.io/eng-practices/review/reviewer/looking-for.html
[names]: https://testing.googleblog.com/2014/10/testing-on-toilet-writing-descriptive.html
[comment]: https://testing.googleblog.com/2017/07/code-health-to-comment-or-not-to-comment.html
[focused]: https://testing.googleblog.com/2018/06/testing-on-toilet-keep-tests-focused.html
[cause]: https://testing.googleblog.com/2017/01/testing-on-toilet-keep-cause-and-effect.html
[logic]: https://testing.googleblog.com/2014/07/testing-on-toilet-dont-put-logic-in.html
[damp]: https://testing.googleblog.com/2019/12/testing-on-toilet-tests-too-dry-make.html
[good]: https://testing.googleblog.com/2014/03/testing-on-toilet-what-makes-good-test.html
[detector]: https://testing.googleblog.com/2015/01/testing-on-toilet-change-detector-tests.html
[behavior]: https://testing.googleblog.com/2013/08/testing-on-toilet-test-behavior-not.html
