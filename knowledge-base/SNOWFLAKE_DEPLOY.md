# Deploying Snowflake Notebooks via CLI

## The critical thing to know

`--replace` **clears stage package imports and external access integrations**. There is no way around this. You must restore them with `ALTER NOTEBOOK` after every deploy, or the notebook will fail at runtime (`ModuleNotFoundError` for missing imports, silent empty results for missing API access).

## snowflake.yml setup

Every notebook directory needs a `snowflake.yml`. Use `definition_version: 2` (V1 is rejected by CLI 3.x).

```yaml
definition_version: 2
entities:
  my_notebook:                    # internal key, no spaces or special chars
    type: notebook
    identifier: 'DATABASE.SCHEMA."Notebook Name"'
    query_warehouse: WAREHOUSE_NAME
    notebook_file: "Local_ filename.ipynb"
    stage_path: '@DATABASE.SCHEMA."Notebook Name"'
    artifacts:
      - "Local_ filename.ipynb"
```

Key details:
- **`identifier`** — fully-qualified Snowflake object name. Names with special characters (colons, spaces) need inner double quotes: `'NOTEBOOKS.SALESFORCE_SYNC."Sync: My Notebook"'`
- **`stage_path`** — must match the notebook's database/schema. Without this, the CLI deploys to your connection's default schema and you get `Insufficient privileges`
- **`notebook_file`** and **`artifacts`** — must match the local `.ipynb` filename exactly

## Deploy commands

### First-time deployment

```bash
snow notebook deploy <entity_key> --role <ROLE>
```

No `--replace` since the notebook doesn't exist yet. Then run the post-deploy steps below.

### Updating an existing notebook

```bash
# 1. Deploy
snow notebook deploy <entity_key> --replace --role <ROLE>

# 2. Upload stage packages (only when .py files change)
snow stage copy my_module.py @DATABASE.SCHEMA.STAGE_NAME --role <ROLE>

# 3. Restore stage package imports
snow sql --role <ROLE> -q "
ALTER NOTEBOOK DATABASE.SCHEMA.\"Notebook Name\" SET IMPORTS = (
  '@\"DATABASE\".\"SCHEMA\".\"STAGE_NAME\"/module_a.py',
  '@\"DATABASE\".\"SCHEMA\".\"STAGE_NAME\"/module_b.py'
)"

# 4. Restore external access integrations
snow sql --role <ROLE> -q "
ALTER NOTEBOOK DATABASE.SCHEMA.\"Notebook Name\"
SET EXTERNAL_ACCESS_INTEGRATIONS = (
  MY_EXTERNAL_ACCESS_INTEGRATION
)"

# 5. Verify
snow sql --role <ROLE> -q "DESCRIBE NOTEBOOK DATABASE.SCHEMA.\"Notebook Name\"" --format JSON
```

Check that `import_urls` lists all `.py` files and `external_access_integrations` is populated.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ModuleNotFoundError` at runtime | Imports cleared by `--replace` | Re-run `ALTER NOTEBOOK ... SET IMPORTS` |
| API calls return empty/wrong results | External access integrations cleared | Re-run `ALTER NOTEBOOK ... SET EXTERNAL_ACCESS_INTEGRATIONS` |
| `Insufficient privileges` on deploy | `stage_path` missing or wrong schema | Set `stage_path` in YAML to match notebook's database/schema |
| `Extra inputs are not permitted... 'objects'` | Using deprecated V1 YAML format | Switch to `definition_version: 2` with `entities` |
| `name not valid` | Special characters in identifier | Wrap name in double quotes inside single quotes: `'DB.SCHEMA."Name: here"'` |
