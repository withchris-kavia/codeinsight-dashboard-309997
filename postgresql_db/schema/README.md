# PostgreSQL schema (bootstrap)

This folder contains the initial schema for the CodeInsight Dashboard PostgreSQL container.

## How to apply

Per container rules, **do not assume credentials**. Use the provided connection command in:

- `../db_connection.txt` (contains `psql postgresql://...`)

From the repo root:

```bash
# Apply schema
$(cat codeinsight-dashboard-309997/postgresql_db/db_connection.txt) \
  -f codeinsight-dashboard-309997/postgresql_db/schema/001_init_schema.sql
```

## Notes

- The schema is **idempotent** (uses `IF NOT EXISTS` where possible).
- Tables included:
  - `orgs`, `users`
  - `oauth_identities`
  - `repos`
  - `webhook_subscriptions`
  - `git_events`
  - `analytics_dev_daily`, `analytics_repo_daily`
  - `ai_summaries`
  - `notification_configs`
  - `audit_logs`
- A convenience view `v_repo_latest_events` is provided for dashboards.
- Backfill / aggregation jobs are expected to be done by the backend later.
