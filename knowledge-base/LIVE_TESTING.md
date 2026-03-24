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

# Use Playwright MCP for interactive testing
# (navigate, click buttons, fill forms, verify state changes)
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
