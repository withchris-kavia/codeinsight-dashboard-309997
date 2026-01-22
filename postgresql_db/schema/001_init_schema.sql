-- Initial PostgreSQL schema for CodeInsight Dashboard
-- Idempotent: uses IF NOT EXISTS where possible.
-- NOTE: This file is meant to be applied via psql using the connection string in db_connection.txt, e.g.:
--   $(cat postgresql_db/db_connection.txt) -f postgresql_db/schema/001_init_schema.sql
--
-- This schema intentionally avoids provider-specific constraints that would require OAuth/Slack/email configuration now.

BEGIN;

-- Extensions (safe / common)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- Orgs
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS orgs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    plan_tier TEXT NOT NULL DEFAULT 'free',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orgs_created_at ON orgs (created_at);

-- ---------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NULL REFERENCES orgs(id) ON DELETE SET NULL,

    email TEXT NULL,
    display_name TEXT NULL,
    avatar_url TEXT NULL,

    -- App-level role; actual authorization enforced in backend
    role TEXT NOT NULL DEFAULT 'member',

    -- Soft delete / status
    status TEXT NOT NULL DEFAULT 'active',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT users_email_unique UNIQUE (email)
);

CREATE INDEX IF NOT EXISTS idx_users_org_id ON users (org_id);
CREATE INDEX IF NOT EXISTS idx_users_created_at ON users (created_at);

-- ---------------------------------------------------------------------
-- OAuth identities (GitHub/GitLab/Bitbucket)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS oauth_identities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    provider TEXT NOT NULL,               -- github | gitlab | bitbucket
    provider_user_id TEXT NOT NULL,       -- provider-side stable id
    username TEXT NULL,
    email TEXT NULL,

    access_token TEXT NULL,               -- stored encrypted/rotated by backend later
    refresh_token TEXT NULL,
    token_expires_at TIMESTAMPTZ NULL,
    scopes TEXT[] NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT oauth_identity_unique UNIQUE (provider, provider_user_id),
    CONSTRAINT oauth_identity_user_provider_unique UNIQUE (user_id, provider)
);

CREATE INDEX IF NOT EXISTS idx_oauth_identities_user_id ON oauth_identities (user_id);
CREATE INDEX IF NOT EXISTS idx_oauth_identities_provider ON oauth_identities (provider);

-- ---------------------------------------------------------------------
-- Repositories
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS repos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,

    provider TEXT NOT NULL,               -- github | gitlab | bitbucket
    external_id TEXT NOT NULL,            -- repo id on provider
    owner TEXT NOT NULL,                  -- org/user namespace on provider
    name TEXT NOT NULL,
    full_name TEXT NOT NULL,              -- owner/name
    default_branch TEXT NULL,

    is_private BOOLEAN NOT NULL DEFAULT TRUE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT repos_provider_external_unique UNIQUE (provider, external_id),
    CONSTRAINT repos_org_fullname_unique UNIQUE (org_id, provider, full_name)
);

CREATE INDEX IF NOT EXISTS idx_repos_org_id ON repos (org_id);
CREATE INDEX IF NOT EXISTS idx_repos_full_name ON repos (full_name);
CREATE INDEX IF NOT EXISTS idx_repos_active ON repos (is_active);

-- ---------------------------------------------------------------------
-- Webhook subscriptions (per-repo, per-provider)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS webhook_subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    repo_id UUID NOT NULL REFERENCES repos(id) ON DELETE CASCADE,

    provider TEXT NOT NULL,
    webhook_url TEXT NULL,                -- where provider sends events (backend-owned)
    secret TEXT NULL,                     -- stored securely later

    external_webhook_id TEXT NULL,        -- provider's webhook id (if created)
    events TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    status TEXT NOT NULL DEFAULT 'active', -- active | paused | disabled

    last_received_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT webhook_sub_repo_provider_unique UNIQUE (repo_id, provider)
);

CREATE INDEX IF NOT EXISTS idx_webhook_subscriptions_repo_id ON webhook_subscriptions (repo_id);
CREATE INDEX IF NOT EXISTS idx_webhook_subscriptions_org_id ON webhook_subscriptions (org_id);

-- ---------------------------------------------------------------------
-- Git events (commits / PRs / merges)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS git_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    repo_id UUID NOT NULL REFERENCES repos(id) ON DELETE CASCADE,

    provider TEXT NOT NULL,
    event_type TEXT NOT NULL,             -- commit | pull_request | merge | issue (future)
    external_event_id TEXT NULL,          -- optional id from provider

    -- Core identity
    actor_provider_user_id TEXT NULL,
    actor_username TEXT NULL,
    actor_email TEXT NULL,

    -- Event time (from provider), plus ingestion time
    event_timestamp TIMESTAMPTZ NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Branch/SHA fields (for commits/merges)
    ref TEXT NULL,
    base_ref TEXT NULL,
    head_ref TEXT NULL,
    commit_sha TEXT NULL,
    merge_commit_sha TEXT NULL,

    -- PR fields
    pr_number INTEGER NULL,
    pr_title TEXT NULL,
    pr_state TEXT NULL,                   -- open | closed | merged
    pr_url TEXT NULL,

    -- Payload storage (raw + normalized)
    raw_payload JSONB NULL,
    metadata JSONB NULL,

    CONSTRAINT git_events_org_repo_ts_type CHECK (event_timestamp IS NOT NULL)
);

-- Uniqueness: allow some nulls; use a partial unique index where external_event_id exists
CREATE UNIQUE INDEX IF NOT EXISTS uq_git_events_provider_external_event
    ON git_events (provider, external_event_id)
    WHERE external_event_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_git_events_org_repo_ts ON git_events (org_id, repo_id, event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_git_events_repo_ts ON git_events (repo_id, event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_git_events_type_ts ON git_events (event_type, event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_git_events_commit_sha ON git_events (commit_sha) WHERE commit_sha IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_git_events_pr_number ON git_events (repo_id, pr_number) WHERE pr_number IS NOT NULL;

-- ---------------------------------------------------------------------
-- AI summaries (generated insights for org/repo/time window)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_summaries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    repo_id UUID NULL REFERENCES repos(id) ON DELETE CASCADE,

    summary_type TEXT NOT NULL,           -- daily_digest | weekly_digest | pr_summary | release_notes | nlq_answer
    window_start TIMESTAMPTZ NULL,
    window_end TIMESTAMPTZ NULL,

    prompt JSONB NULL,
    model TEXT NULL,
    status TEXT NOT NULL DEFAULT 'ready', -- queued | running | ready | failed

    content TEXT NULL,
    content_json JSONB NULL,

    error_message TEXT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_summaries_org_created_at ON ai_summaries (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_summaries_repo_created_at ON ai_summaries (repo_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_summaries_type ON ai_summaries (summary_type);

-- ---------------------------------------------------------------------
-- Notification configs (Slack/email placeholders)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notification_configs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    user_id UUID NULL REFERENCES users(id) ON DELETE SET NULL,

    channel_type TEXT NOT NULL,           -- slack | email | webhook
    destination TEXT NULL,                -- email addr, slack channel id, webhook url
    is_enabled BOOLEAN NOT NULL DEFAULT TRUE,

    -- Delivery preferences
    frequency TEXT NOT NULL DEFAULT 'daily', -- immediate | daily | weekly
    event_types TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[], -- interested event types

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notification_configs_org_id ON notification_configs (org_id);
CREATE INDEX IF NOT EXISTS idx_notification_configs_user_id ON notification_configs (user_id);
CREATE INDEX IF NOT EXISTS idx_notification_configs_enabled ON notification_configs (is_enabled);

-- ---------------------------------------------------------------------
-- Audit logs
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NULL REFERENCES orgs(id) ON DELETE SET NULL,
    user_id UUID NULL REFERENCES users(id) ON DELETE SET NULL,

    action TEXT NOT NULL,
    entity_type TEXT NULL,
    entity_id UUID NULL,

    ip_address INET NULL,
    user_agent TEXT NULL,

    metadata JSONB NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_org_created_at ON audit_logs (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_created_at ON audit_logs (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON audit_logs (action);

-- ---------------------------------------------------------------------
-- Analytics aggregates
-- Tables (can be later replaced by materialized views)
-- ---------------------------------------------------------------------

-- Per-developer daily rollups
CREATE TABLE IF NOT EXISTS analytics_dev_daily (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    repo_id UUID NULL REFERENCES repos(id) ON DELETE CASCADE,

    day DATE NOT NULL,

    actor_provider_user_id TEXT NULL,
    actor_username TEXT NULL,
    actor_email TEXT NULL,

    commits_count INTEGER NOT NULL DEFAULT 0,
    prs_opened_count INTEGER NOT NULL DEFAULT 0,
    prs_merged_count INTEGER NOT NULL DEFAULT 0,
    merges_count INTEGER NOT NULL DEFAULT 0,

    lines_added INTEGER NOT NULL DEFAULT 0,
    lines_deleted INTEGER NOT NULL DEFAULT 0,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT analytics_dev_daily_unique UNIQUE (org_id, repo_id, day, actor_provider_user_id, actor_username, actor_email)
);

CREATE INDEX IF NOT EXISTS idx_analytics_dev_daily_org_day ON analytics_dev_daily (org_id, day DESC);
CREATE INDEX IF NOT EXISTS idx_analytics_dev_daily_repo_day ON analytics_dev_daily (repo_id, day DESC);

-- Per-repo daily rollups
CREATE TABLE IF NOT EXISTS analytics_repo_daily (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    repo_id UUID NOT NULL REFERENCES repos(id) ON DELETE CASCADE,

    day DATE NOT NULL,

    commits_count INTEGER NOT NULL DEFAULT 0,
    prs_opened_count INTEGER NOT NULL DEFAULT 0,
    prs_merged_count INTEGER NOT NULL DEFAULT 0,
    merges_count INTEGER NOT NULL DEFAULT 0,

    active_devs_count INTEGER NOT NULL DEFAULT 0,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT analytics_repo_daily_unique UNIQUE (repo_id, day)
);

CREATE INDEX IF NOT EXISTS idx_analytics_repo_daily_org_day ON analytics_repo_daily (org_id, day DESC);
CREATE INDEX IF NOT EXISTS idx_analytics_repo_daily_repo_day ON analytics_repo_daily (repo_id, day DESC);

-- ---------------------------------------------------------------------
-- Convenience Views (non-materialized)
-- ---------------------------------------------------------------------

-- Latest events per repo (helps dashboards quickly)
CREATE OR REPLACE VIEW v_repo_latest_events AS
SELECT
    r.id AS repo_id,
    r.org_id,
    r.provider,
    r.full_name,
    ge.id AS git_event_id,
    ge.event_type,
    ge.event_timestamp,
    ge.actor_username,
    ge.commit_sha,
    ge.pr_number,
    ge.pr_state
FROM repos r
LEFT JOIN LATERAL (
    SELECT *
    FROM git_events ge2
    WHERE ge2.repo_id = r.id
    ORDER BY ge2.event_timestamp DESC
    LIMIT 1
) ge ON TRUE;

COMMIT;
