---
description: "Run the project's tests and explain the results in plain English: /test (everything), /test <file or words> (a subset), /test explain [file or words] (explain without running)"
argument-hint: "[explain] [file | test name | words]"
---

The user asked for this run — that ask is what makes running tests yours (rulebook § Tests). The user is new to automated tests: every answer below is written for someone who has never read a test before. Gloss any jargon the first time you use it (test suite, test case, fixture, stub, assertion…).

Arguments: `$ARGUMENTS`

## 1. Find the test command

Look, in this order, and use the first that exists: the project's `CLAUDE.md` (a Build & Test or similar section), a `run-tests.sh`, `package.json` `scripts.test`, a `Makefile` `test` target, `pyproject.toml`/`pytest.ini` (pytest), `go.mod` (`go test ./...`), `Cargo.toml` (`cargo test`), a `tests/` folder of `.bats` files (`bats tests/`). If a `tests/INDEX.md` or similar map exists, read it — it says what each file guards. If there are no tests at all, say so in one line and stop.

## 2. Run, or explain

- **No arguments** — run the whole suite.
- **A file, test name, or words** — run only the matching tests (a file path, the runner's name filter such as `bats -f`, `pytest -k`, `go test -run`, `npm test -- -t`).
- **`explain …`** — do NOT run anything. For each matching test file (or the whole suite, if nothing follows `explain`), explain it using section 4.

Never edit code or tests during `/test`. Run each command once; do not retry to get a different result.

## 3. Report a run

**What ran** — the exact command, how many tests, how long it took.

**Result** — passed / failed / skipped counts, in one line. If everything passed, say what that tells the user in one sentence and stop.

**Each failure**, one block:
- **Test:** its name and file.
- **Guards:** what behavior it protects — from its `Guards:` header if it has one, otherwise read the test and say it in plain words.
- **What went wrong:** the failure output translated into plain words (expected X, got Y), plus the one or two lines of real output that show it.
- **Why, most likely:** compare the code it covers against recent commits (`git log`, `git diff`). Say whether it looks caused by recent work, pre-existing, or only a wording/format check, and how sure you are.
- **Rerun just this:** the exact command for that one test.

End with one question only when there are failures: which of them the user wants fixed, each option inline. Do not fix anything without that answer.

## 4. Explaining a test

For each test (or, for a big file, each group of similar tests):
- **What it checks**, in one plain sentence — the real behavior, not the code.
- **How**: what it sets up, what it does, what it expects — one line each.
- **Size**: small, medium or large (its `size:` tag; untagged is small) — what it is allowed to do and its time limit, per `~/.claude/TESTING.md`.
- **Kind**: *behavior* (runs the code and checks what happens) or *wording* (only checks that some text or document says certain words). Say plainly that wording tests protect phrasing, not behavior.
- **Run it:** the exact command for this one file or test.
- **Pass / fail means:** what the user learns from each.
