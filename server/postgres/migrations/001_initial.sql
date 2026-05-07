-- 001_initial.sql  — Postgres session store for rgsd.
-- Applied by postgres.RunMigrations in the order the filenames sort.
-- Idempotent: uses CREATE TABLE IF NOT EXISTS so it is safe to re-run.

CREATE TABLE IF NOT EXISTS sessions (
    id          TEXT        NOT NULL PRIMARY KEY,
    player_id   TEXT        NOT NULL,
    state       TEXT        NOT NULL,
    opened_at   TIMESTAMPTZ NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL,
    bet_data    JSONB                -- NULL when no active bet
);

CREATE INDEX IF NOT EXISTS idx_sessions_player ON sessions (player_id);
CREATE INDEX IF NOT EXISTS idx_sessions_state  ON sessions (state);
