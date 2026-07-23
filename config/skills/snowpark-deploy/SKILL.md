---
name: snowpark-deploy
description: >-
  Prepare a complete, ready-to-run deploy package for a Python stored
  procedure / function on Snowflake (Snowflake CLI `snow`,
  definition_version 2) — for the USER to deploy. Claude never has Snowflake
  access and never runs `snow`: it writes the four project files plus the
  exact commands, and the user executes them on their own machine
  (typically into SNOWFLAKE_INTELLIGENCE.TOOLS via their RESOLVER02
  connection). Encodes the exact config that works so the user's deploy
  doesn't fail on warehouse/role/package errors.
---

# Preparing Snowpark deploy packages (user deploys, never Claude)

**Division of labor is fixed: Claude writes everything; the user deploys.**
Claude has no Snowflake connection and never will — do not run `snow`
commands, do not ask for credentials, and do not file tasks that assume you
can deploy or verify against the account. The deliverable is a package the
user can run as-is, plus the exact commands and expected output, handed off
in chat. (See the Snowflake project context rules — this skill is the
deploy-shaped case of the same constraint.)

This setup was distilled from a painful trial-and-error session. Package it
exactly like this and the user's deploy works first try. The CLI is the
**Snowflake CLI** (`snow`), project format `definition_version: 2`.

## The four files Claude writes (all required)

```
snowflake.yml        # project definition (NO packages field here)
requirements.txt     # where Anaconda packages go
src/<handler>.py     # def run(session, ...) -> ...
deploy.sh            # build THEN deploy — the user runs this
```

### snowflake.yml
```yaml
definition_version: 2
entities:
  hello_world:
    type: procedure
    identifier:
      database: SNOWFLAKE_INTELLIGENCE
      schema: TOOLS
      name: HELLO_WORLD
    handler: hello.run
    returns: string
    signature: []
    runtime: "3.11"
    stage: SNOWFLAKE_INTELLIGENCE.TOOLS.DEPLOY
    artifacts:
      - src/
```

### requirements.txt
```
snowflake-snowpark-python
```

### src/hello.py
```python
def run(session) -> str:
    return "Hello, world!"
```

### deploy.sh
```bash
#!/usr/bin/env bash
set -euo pipefail

snow snowpark build          # MUST run first — creates src.zip

snow snowpark deploy \
  --connection RESOLVER02 \
  --replace
```

## The handoff (how Claude delivers this)

1. Write the four files into the repo and make `deploy.sh` executable.
2. Tell the user in chat, concretely:
   - the one-time `config.toml` requirement (pitfall 3 below) and the
     `snow connection test --connection RESOLVER02` pre-check;
   - to run `./deploy.sh` from the project root on their machine;
   - the verification SQL to run afterward, with expected output.
3. Ask the user to paste the deploy/verify output back. That paste is the
   only verification available — an environment limitation, not delegable
   work; keep the task claimed by Claude and blocked on their reply.

What Claude CAN check locally before handoff: YAML is valid
(`python3 -c 'import yaml,sys; yaml.safe_load(open("snowflake.yml"))'`),
handler file parses (`python3 -m py_compile src/<handler>.py`), the handler
name in `snowflake.yml` matches `<module>.<function>`, and every import in
the handler has a matching line in `requirements.txt`. Do all of these —
they are the failure modes that don't need an account to catch.

## The pitfalls the user's deploy will hit without this config (in order once hit)

1. **`deploy` alone fails: "Artifact …/src.zip … does not exist."**
   `definition_version: 2` does NOT build implicitly. `snow snowpark build`
   must run first to produce `src.zip`. Always two steps — which is why
   `deploy.sh` encodes both.

2. **"Insufficient privileges … CREATE STAGE on SCHEMA …TOOLS".**
   The default role (`DWH_BI_SERVICE`) can't create the deploy stage.
   Deploying into `SNOWFLAKE_INTELLIGENCE.TOOLS` needs role
   `SNOWFLAKE_INTELLIGENCE_ADMIN`. The deploy auto-creates the stage
   `SNOWFLAKE_INTELLIGENCE.TOOLS.DEPLOY` — the user shouldn't pre-create it.

3. **"The command requires warehouse. No warehouse found in current connection."**
   Do NOT try to fix this with flags. None of these worked:
   - `--warehouse EXPLORATION`  (ignored)
   - `SNOWFLAKE_CONNECTIONS_RESOLVER02_WAREHOUSE=…` env var  (ignored)
   - `--role …` flag — this is what *caused* the warehouse to drop out of
     the connection context in the first place.

   **Fix: the user bakes role AND warehouse into the connection in
   `~/.snowflake/config.toml` (on their machine), and `deploy.sh` passes NO
   `--role`/`--warehouse` flags.**
   ```toml
   [connections.RESOLVER02]
   # ...existing account/user/auth...
   role = "SNOWFLAKE_INTELLIGENCE_ADMIN"
   warehouse = "EXPLORATION"
   ```
   Pre-check the user runs before deploying:
   ```bash
   snow connection test --connection RESOLVER02
   # Role must show SNOWFLAKE_INTELLIGENCE_ADMIN, Warehouse must be non-empty
   ```
   Rule of thumb: **identity (role/warehouse/db) lives in config.toml, not on
   the command line.** Flag overrides are unreliable in this CLI version and
   interact badly with each other.

4. **`packages:` under the entity in snowflake.yml → "You specified packages …
   without setting artifact_repository."**
   In `definition_version: 2`, an entity-level `packages:` list means *private
   artifact-repository* packages and demands an `artifact_repository`. It is
   NOT the place for Anaconda packages. Put Anaconda deps in **`requirements.txt`**;
   `snow snowpark build` resolves them against the Snowflake Anaconda channel and
   folds them into the procedure's `PACKAGES` clause.

5. **Runtime `ModuleNotFoundError: No module named 'snowflake'`.**
   Every Python stored procedure gets a Snowpark `Session` injected as its first
   argument, so the runtime requires `snowflake-snowpark-python` in `PACKAGES`
   **even if your code doesn't import it.** Always list it in `requirements.txt`.
   (Removing `from snowflake.snowpark import Session` from the handler does NOT
   fix this — it was a red herring. The import is fine to keep for type hints
   *once the package is declared*.)

## Verification SQL to hand the user
```sql
CALL SNOWFLAKE_INTELLIGENCE.TOOLS.HELLO_WORLD();
```
State the expected result alongside it, and ask for the output back.

## Quick checklist before handing off a new proc
- [ ] Handler in `src/`, signature `def run(session, ...)`
- [ ] `snowflake-snowpark-python` (+ any other Anaconda deps) in `requirements.txt`
- [ ] No `packages:` key in `snowflake.yml`
- [ ] Local checks run: YAML parses, handler compiles, handler path matches, deps covered
- [ ] `deploy.sh` runs `snow snowpark build` before `snow snowpark deploy --replace`
- [ ] Handoff message includes: config.toml role/warehouse note, `snow connection test`
      pre-check, `./deploy.sh`, verification SQL + expected output
