# Project Context: Snowflake

Claude has no direct access to this project's Snowflake account and never
will. Never request credentials, and never attempt a connection via
`snow`, `snowsql`, or any connector.

Validate SQL locally by parsing rather than executing it, and build and
test against fixture data standing in for real tables and results.

For a Snowpark procedure or UDF deploy, the `snowpark-deploy` skill
prepares a complete deploy package for the user to run on their own
machine when a deploy is requested.
