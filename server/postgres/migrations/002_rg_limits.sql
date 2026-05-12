-- 002_rg_limits.sql — Responsible-gambling player limits store.
-- Applied by postgres.RunMigrations in lexicographic order after 001_initial.sql.
-- Idempotent: uses CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS.
--
-- Schema notes
-- ─────────────
-- rg_limits holds one row per player (upserted by the Postgres-backed
-- RGService impl). All monetary caps are in the operator's reporting currency
-- smallest sub-unit (cents, satoshis, etc.) as BIGINT — 0 means "no limit".
--
-- self_excluded_until / cooling_off_until are NULL when the player is not
-- excluded, and a future timestamp when they are. The application layer
-- (CheckCanBet) compares against NOW() so no scheduled job is needed to
-- "lift" an expired exclusion — it is lifted implicitly on the next check.
--
-- loss_daily / loss_weekly / loss_monthly are running accumulators reset by
-- the application on calendar-window rollover. They are persisted here so
-- they survive an rgsd restart without losing the current window's exposure.

CREATE TABLE IF NOT EXISTS rg_limits (
    player_id             TEXT        NOT NULL PRIMARY KEY,

    -- Deposit caps (0 = no cap).
    deposit_daily_max     BIGINT      NOT NULL DEFAULT 0,
    deposit_weekly_max    BIGINT      NOT NULL DEFAULT 0,
    deposit_monthly_max   BIGINT      NOT NULL DEFAULT 0,

    -- Net-loss caps (0 = no cap).
    loss_daily_max        BIGINT      NOT NULL DEFAULT 0,
    loss_weekly_max       BIGINT      NOT NULL DEFAULT 0,
    loss_monthly_max      BIGINT      NOT NULL DEFAULT 0,

    -- Running loss accumulators (reset by app on window rollover).
    loss_daily_accum      BIGINT      NOT NULL DEFAULT 0,
    loss_weekly_accum     BIGINT      NOT NULL DEFAULT 0,
    loss_monthly_accum    BIGINT      NOT NULL DEFAULT 0,
    last_day_reset        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_week_reset       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_month_reset      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Session / reality-check settings (0 = no limit).
    session_timeout_min   INT         NOT NULL DEFAULT 0,
    reality_check_min     INT         NOT NULL DEFAULT 0,

    -- Exclusion timestamps (NULL = not excluded).
    self_excluded_until   TIMESTAMPTZ,
    cooling_off_until     TIMESTAMPTZ,

    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Fast lookup for enforcement queries ("give me all players currently excluded").
CREATE INDEX IF NOT EXISTS idx_rg_limits_self_excl  ON rg_limits (self_excluded_until) WHERE self_excluded_until IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rg_limits_cooling_off ON rg_limits (cooling_off_until)  WHERE cooling_off_until  IS NOT NULL;
