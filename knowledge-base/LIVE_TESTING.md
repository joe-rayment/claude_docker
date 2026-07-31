# Live Testing Playbook

When verifying that code changes work, always prefer live behavioral testing over code-based tests. This guide provides concrete patterns.

## Web Applications

```bash
# Start the app (install deps if needed)
npm install && npm start    # or pip install -r requirements.txt && python app.py

# Screenshot the running app
take-screenshot url http://localhost:3000
take-screenshot url --full-page http://localhost:3000/dashboard

# Mobile view
take-screenshot url --device "iPhone 11" http://localhost:3000
```

## APIs and Endpoints

```bash
# Install httpie if not available
pip install httpie 2>/dev/null

# Test endpoints
curl -s http://localhost:8080/api/health | jq .
http GET localhost:8080/api/users
http POST localhost:8080/api/items name="Test" value=42

# Test with authentication
curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/protected
```

## CLI Tools

```bash
# Run the tool
my-tool --help
my-tool process input.txt

# Capture output as screenshot
take-screenshot term "my-tool --version"
take-screenshot term "my-tool process sample.txt"
```

## Desktop / GUI Applications

```bash
# Start with X11 display (Xvfb is running on :99)
DISPLAY=:99 my-app &

# Wait for it to render, then screenshot
sleep 2
take-screenshot display
```

## Database Changes

```bash
# Verify migrations ran
sqlite3 db.sqlite3 ".schema tablename"
psql -c "SELECT * FROM new_table LIMIT 5;"

# Verify data integrity
sqlite3 db.sqlite3 "SELECT COUNT(*) FROM users;"
```

## What NOT To Do

- Don't just read the code and say "this should work"
- Don't rely solely on unit tests passing to verify a new feature
- Don't skip verification because "the change is small"
- Don't report completion without seeing the actual output
- Don't guess at behavior — run it and check

## Installing Missing Tools

If a tool is needed for verification, install it:

```bash
# System packages
apt-get update && apt-get install -y <package>

# Python tools
pip install httpie requests pytest

# Node tools
npm install -g serve json-server

# Go tools
go install github.com/some/tool@latest
```

The goal is always: **see it working with your own eyes** (via screenshots, command output, or browser interaction).

## Writing bats regression tests

Two rules learned from real test failures in this repo, not just style
preferences.

**One assertion per line.** An `A && B` chain is defanged by `set -e`: bash
only applies `-e` to the *last* command in a `&&`/`||` list, so a false `A`
that is not the test's last line lets execution fall through to the next
line, silently masking the failure. Verified 2026-07-31 — a failing chain
mid-body prints the next line and the enclosing function returns 0:

```bash
bash -c 'set -e; f(){ false && echo unreachable; echo "MASKED: reached"; }; f; echo "exit=$?"'
# → MASKED: reached
#   exit=0
```

The same chain as the function's *last* line does abort (bats would then
correctly fail the test):

```bash
bash -c 'set -e; f(){ echo before; false && echo unreachable; }; f; echo AFTER'
# → before          (AFTER never prints — function returned 1, script exited)
```

So `A && B` is only safe for genuine flow control (`cd x && y`), never as a
stand-in for two separate assertions — write them as two lines instead.

**Never `mktemp` your own scratch directory.** `setup()` must do
`export TMPDIR="$BATS_TEST_TMPDIR"` (see `tests/context-detect.bats`,
`tests/hook-staging.bats` for the pattern in this repo) so bats removes the
directory whether the test passes or fails. An inline `rm -rf` at the end
of the test body leaks the directory on every run where an assertion
aborts the test early — the cleanup line never gets a chance to execute.
