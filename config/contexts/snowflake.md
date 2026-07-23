# Project Context: Snowflake

This project involves Snowflake, but **Claude has no direct access to the
user's Snowflake account and never will.** No connection is available to
query, inspect, or modify the database from this container.

- **Never plan or file tasks that require querying the user's Snowflake** —
  no beads like "query X to check Y", no plan steps that assume you can run
  SQL against their account, no "verify by selecting from the table".
- **Never attempt a connection** via `snow`, `snowsql`, Python connectors,
  JDBC/ODBC, or anything else — and never ask the user for credentials.
- When a step genuinely needs data, schema, or query results from Snowflake,
  write the **exact, complete SQL** and ask the user in chat to run it and
  paste the output. That is an environment limitation, not delegable work —
  keep the task claimed by you and blocked on their reply.
- Design and verify around the limitation: build against sample/fixture data
  the user provides, and validate SQL locally where possible (syntax, dry
  parsing) rather than by execution.
- Exception: if the user **explicitly directs** a deploy through a configured
  `snow` CLI connection (see the `snowpark-deploy` skill), follow that
  direction — it is user-sanctioned and scoped to deployment, not ad-hoc
  querying.
