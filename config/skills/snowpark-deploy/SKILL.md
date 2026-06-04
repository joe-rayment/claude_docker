---
name: snowpark-deploy
description: >-
  Deploy a Python stored procedure / function to Snowflake with the `snow` CLI
  (Snowflake CLI, definition_version 2). Use whenever the user wants to create,
  deploy, or update a Snowpark proc/UDF in this repo — especially into
  SNOWFLAKE_INTELLIGENCE.TOOLS via the RESOLVER02 connection. Encodes the exact
  config that works here so deploys don't fail on warehouse/role/package errors.
---

# Deploying Snowpark procedures with the `snow` CLI

This skill captures the working setup for this repo, distilled from a painful
trial-and-error session. Follow it and the deploy works first try. The CLI is
the **Snowflake CLI** (`snow`), project format `definition_version: 2`.

## The four files (all required)

```
snowflake.yml        # project definition (NO packages field here)
requirements.txt     # where Anaconda packages go
src/<handler>.py     # def run(session, ...) -> ...
deploy.sh            # build THEN deploy
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

## The pitfalls that cost us the session (in order hit)

1. **`deploy` alone fails: "Artifact …/src.zip … does not exist."**
   `definition_version: 2` does NOT build implicitly. You must run
   `snow snowpark build` first to produce `src.zip`. Always two steps.

2. **"Insufficient privileges … CREATE STAGE on SCHEMA …TOOLS".**
   The default role (`DWH_BI_SERVICE`) can't create the deploy stage.
   Deploying into `SNOWFLAKE_INTELLIGENCE.TOOLS` needs role
   `SNOWFLAKE_INTELLIGENCE_ADMIN`. The deploy auto-creates the stage
   `SNOWFLAKE_INTELLIGENCE.TOOLS.DEPLOY` — don't pre-create it.

3. **"The command requires warehouse. No warehouse found in current connection."**
   Do NOT try to fix this with flags. None of these worked:
   - `--warehouse EXPLORATION`  (ignored)
   - `SNOWFLAKE_CONNECTIONS_RESOLVER02_WAREHOUSE=…` env var  (ignored)
   - `--role …` flag — this is what *caused* the warehouse to drop out of
     the connection context in the first place.

   **Fix: bake role AND warehouse into the connection in
   `~/.snowflake/config.toml`, and pass NO `--role`/`--warehouse` flags.**
   ```toml
   [connections.RESOLVER02]
   # ...existing account/user/auth...
   role = "SNOWFLAKE_INTELLIGENCE_ADMIN"
   warehouse = "EXPLORATION"
   ```
   Verify before deploying:
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

## Verify after deploy
```sql
CALL SNOWFLAKE_INTELLIGENCE.TOOLS.HELLO_WORLD();
```

## Quick checklist for a new proc
- [ ] Handler in `src/`, signature `def run(session, ...)`
- [ ] `snowflake-snowpark-python` (+ any other Anaconda deps) in `requirements.txt`
- [ ] No `packages:` key in `snowflake.yml`
- [ ] `role` + `warehouse` set in the `config.toml` connection, not via flags
- [ ] `deploy.sh` runs `snow snowpark build` before `snow snowpark deploy --replace`
- [ ] `snow connection test` shows the right role/warehouse first
