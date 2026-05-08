# Deployment

How to run `rgsd` in something resembling production. The MVP scaffolding
is in place (auth, structured logs, metrics, graceful shutdown); the
operational gaps that still need filling before going live with real
money are listed at the bottom.

## Binary surface

`rgsd` exposes two HTTP namespaces on a single listen address:

| Path        | Auth     | Purpose                                            |
| ----------- | -------- | -------------------------------------------------- |
| `/v1/*`     | HMAC     | operator-facing API (see [rgs-integration.md](rgs-integration.md)) |
| `/v1/health`| **none** | liveness probe (skip-listed in HMAC config)        |
| `/metrics`  | **none** | Prometheus-format scrape endpoint                  |

`/metrics` and `/v1/health` deliberately bypass the HMAC middleware so
load balancers, kube probes, and Prometheus scrapers don't need shared
keys. If your network topology requires auth on those (e.g. metrics
exposed publicly), front rgsd with a reverse proxy that adds it.

## Configuration

All flags accept an environment variable equivalent so 12-factor configs
work without a flag soup at startup:

| Flag                | Env var               | Default | Notes                                               |
| ------------------- | --------------------- | ------- | --------------------------------------------------- |
| `--addr`            | `RGSD_ADDR`           | `:8090` | listen address                                      |
| `--godot-bin`       | `RGSD_GODOT_BIN`      | —       | absolute path to Godot 4.6.2 binary (required)      |
| `--project-path`    | `RGSD_PROJECT_PATH`   | —       | absolute path to `game/` (required)                 |
| `--replay-root`     | `RGSD_REPLAY_ROOT`    | —       | per-round audit destination (required)              |
| `--rtp-bps`         | `RGSD_RTP_BPS`        | `9500`  | configured RTP in basis points                      |
| `--buy-in`          | `RGSD_BUY_IN`         | `100`   | per-seat stake                                      |
| `--marbles`         | `RGSD_MARBLES`        | `20`    | marbles per round                                   |
| `--sim-timeout`     | —                     | `60s`   | hard cap per Godot subprocess                       |
| `--hmac-secret-hex` | `RGSD_HMAC_SECRET`    | —       | hex-encoded HMAC key; **empty = auth off (dev)**    |
| `--seed-alice`      | —                     | `0`     | seed MockWallet's `alice` for demo runs             |
| `--postgres-dsn`    | `RGSD_POSTGRES_DSN`   | —       | Postgres DSN for durable session storage; empty = in-memory |
| `--postgres-migrate`| —                     | `false` | apply DB migrations then exit (run before first start) |

A startup with auth disabled emits a `WARN` log line every boot — that's
intentional, so a broken deploy doesn't quietly run with no auth.

## Authenticating a request

`/v1/*` requests must carry two headers:

```
X-Timestamp: <unix-seconds>
X-Signature: <lower-hex SHA256 hmac>
```

Where the signature is over the canonical string

```
{METHOD}\n{PATH}\n{TIMESTAMP}\n{BODY-BYTES}
```

`X-Timestamp` must be within 5 minutes of server time (replay protection).
The Go reference implementation lives at [server/middleware/middleware.go]
(`SignRequest`); a shell-friendly version using `openssl` is:

```bash
TS=$(date +%s)
BODY='{"player_id":"alice"}'
SIG=$(printf "POST\n/v1/sessions\n%s\n%s" "$TS" "$BODY" | \
       openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}')

curl -X POST "$RGSD/v1/sessions" \
  -H "Content-Type: application/json" \
  -H "X-Timestamp: $TS" -H "X-Signature: $SIG" \
  -d "$BODY"
```

## Observability

Every HTTP request emits a single structured log line:

```
time=...  level=INFO msg=http method=POST path=/v1/sessions/sess_.../bet \
status=200 bytes=234 duration=12.3ms request_id=req_a1b2c3d4
```

Panics in handlers are recovered, logged with `level=ERROR msg=panic` and
the stack, and surfaced as 500 to the caller with the `request_id` in
the body so triage can grep both sides.

`/metrics` exposes Prometheus exposition format:

```
# HELP rgsd_rounds_total rounds run by this rgsd
# TYPE rgsd_rounds_total counter
rgsd_rounds_total 142
# HELP rgsd_bets_total bets placed and accepted
# TYPE rgsd_bets_total counter
rgsd_bets_total 318
# HELP rgsd_bet_errors_total bets rejected (any reason)
# TYPE rgsd_bet_errors_total counter
rgsd_bet_errors_total 4
# HELP rgsd_round_duration_seconds wall clock from RunNextRound entry to manifest persisted
# TYPE rgsd_round_duration_seconds histogram
rgsd_round_duration_seconds_bucket{le="1"} 0
rgsd_round_duration_seconds_bucket{le="2"} 0
rgsd_round_duration_seconds_bucket{le="5"} 18
rgsd_round_duration_seconds_bucket{le="10"} 142
...
rgsd_round_duration_seconds_sum 891.4
rgsd_round_duration_seconds_count 142
```

Reasonable alerting thresholds for a soft launch:

- `rgsd_bet_errors_total / rgsd_bets_total` > 5% over 5 minutes — wallet
  upstream is degrading.
- `rgsd_round_duration_seconds` p99 > 30s — Godot subprocess is hanging
  more than expected; check sim logs.
- `up{job="rgsd"} == 0` — process down.

## Lifecycle

`rgsd` traps `SIGINT` / `SIGTERM` and shuts the HTTP server down with a
20-second drain window. In-flight HTTP requests get to finish; new
requests during shutdown fail at the listener level.

**It does NOT yet drain in-flight rounds.** A round that the manager
started before SIGTERM but hasn't persisted yet will lose its replay file
when the process exits — the bets are already debited but never
credited. M10.x work to fix:

- Persist a "running" marker per round_id so a fresh process can detect
  + retry the round on startup.
- Move replay storage off the filesystem (see below).

## Postgres setup

Session state is persisted to Postgres when `--postgres-dsn` (or
`RGSD_POSTGRES_DSN`) is set. Without it `rgsd` falls back to the
legacy in-memory map — identical behaviour to before, suitable for
demos and CI runs that don't have a DB available.

### Schema

The schema lives in `server/postgres/migrations/` and is embedded in
the binary. Apply it once before (or on) first startup:

```bash
# Option A: dedicated migrate-and-exit run
rgsd --postgres-dsn "$DSN" --postgres-migrate

# Option B: docker-compose init container or entrypoint script
docker run --rm marbles-game/rgsd:dev \
  --postgres-dsn "postgres://rgsd:rgsd@postgres/rgsd?sslmode=disable" \
  --postgres-migrate
```

`RunMigrations` is idempotent — every statement uses `CREATE … IF NOT
EXISTS` — so re-running on an already-migrated database is a no-op.

### Local development

```bash
# 1. Start Postgres (use the compose stack or a one-liner):
docker run --rm -p 5432:5432 \
  -e POSTGRES_USER=rgsd -e POSTGRES_PASSWORD=rgsd -e POSTGRES_DB=rgsd \
  postgres:16-alpine

# 2. Apply migrations:
cd server
go run ./cmd/rgsd \
  --postgres-dsn "postgres://rgsd:rgsd@localhost:5432/rgsd?sslmode=disable" \
  --postgres-migrate

# 3. Start rgsd with Postgres session storage:
go run ./cmd/rgsd \
  --postgres-dsn "postgres://rgsd:rgsd@localhost:5432/rgsd?sslmode=disable" \
  --godot-bin /path/to/godot --project-path /path/to/game \
  --replay-root /tmp/replays
```

### Running the Postgres integration tests

```bash
export POSTGRES_TEST_DSN="postgres://rgsd:rgsd@localhost:5432/rgsd?sslmode=disable"
go test ./server/postgres/... -v -race
```

If `POSTGRES_TEST_DSN` is not set the tests skip automatically so
`go test ./...` stays green in CI without a database.

### docker-compose

The `postgres:16-alpine` service is already present in
`ops/docker-compose.yaml`. The `rgsd` service now receives
`RGSD_POSTGRES_DSN` automatically. The default credentials are
`rgsd / rgsd / rgsd` (user / password / database); override via
`POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` env vars in a
`.env` file at the repo root.

## Open operational items

The MVP gets you to "could be deployed for an internal dogfood / closed
beta". To take real money these still need work:

### DONE (M23–M28)
- ✅ **Real wallet client** — [HTTPWallet](../server/rgs/wallet_http.go) in place. 12-test contract suite. Provider adapters (SoftSwiss, EveryMatrix) still needed; see [rgs-integration.md §How to integrate with operator X](../docs/rgs-integration.md#how-to-integrate-with-operator-x-template).
- ✅ **Postgres for sessions** — `--postgres-dsn` wires a durable `SessionStore`; sessions survive restarts. [server/postgres/](../server/postgres/) package with idempotent migration.
- ✅ **Round scheduler** — `--scheduler-enabled` launches a goroutine that runs rounds automatically at a fixed cadence. `--scheduler-bet-window` (default 10s) and `--scheduler-between-rounds` (default 5s) are tunable. `GET /v1/scheduler/status` reports live phase / round_id / next_round_at. See [server/rgs/scheduler.go](../server/rgs/scheduler.go).
- ✅ **Multi-round concurrency** — `Manager.RunRound(ctx, round_id)` executes rounds concurrently up to `--max-concurrent-rounds` (default 4). Each round has isolated state (`roundExecution`) so sim, manifest, and settle steps never share locks with other rounds. The Scheduler supports `--scheduler-overlap-rounds` (default 0 = serial) to keep N rounds in flight simultaneously. Idempotency guaranteed: duplicate `RunRound` calls on the same `round_id` return the cached outcome; a call while the round is still executing returns `ErrRoundInFlight`. See [server/rgs/manager.go](../server/rgs/manager.go).

### Scheduler configuration

When `--scheduler-enabled` is set, `rgsd` drives rounds autonomously:

| Flag                          | Env var                        | Default | Notes                                                        |
| ----------------------------- | ------------------------------ | ------- | ------------------------------------------------------------ |
| `--scheduler-enabled`         | —                              | `false` | Enable the round ticker. When false, use POST /v1/rounds/run |
| `--scheduler-bet-window`      | —                              | `10s`   | How long the bet window stays open before RunNextRound fires |
| `--scheduler-between-rounds`  | —                              | `5s`    | Cooldown between a settled round and the next bet window     |
| `--max-concurrent-rounds`     | `RGSD_MAX_CONCURRENT_ROUNDS`   | `4`     | Max rounds executing simultaneously inside Manager           |
| `--scheduler-overlap-rounds`  | —                              | `0`     | Scheduler overlap: rounds in flight at once (0 = serial)     |

Lifecycle per round:

```
GenerateRoundSpec          (mints round_id + seed, publishes to /v1/rounds/{id})
   → sleep BetWindowSec    (players POST /v1/rounds/{id}/bets during this window)
   → RunNextRound          (sim + settle + audit persist)
   → sleep BetweenRounds   (cooldown)
   → repeat
```

The scheduler respects `Manager.Pause()` / `Manager.Resume()`: when the
manager is paused the loop spins on a 200 ms poll until resumed; the
goroutine stays alive and no bets are lost. POST /v1/rounds/run remains
operational when the scheduler is enabled — useful for manual recovery.

Graceful shutdown: `SIGTERM` cancels the scheduler context; if a
`RunNextRound` call is in progress it completes before the goroutine
exits so no in-flight bets are lost.

Status endpoint (no HMAC required when using the skip-list — add
`/v1/scheduler/status` alongside `/v1/health` if desired):

```
GET /v1/scheduler/status
{
  "enabled": true,
  "paused": false,
  "current_phase": "bet_window",
  "current_round_id": 1778197270610631100,
  "next_round_at": "2026-05-08T01:41:10.932Z"
}
```

Phases: `idle` → `bet_window` → `running` → `cooldown` → `bet_window` → …
When the scheduler is disabled the endpoint returns 404.

### Tuning rationale

- **BetWindowSec default 10s**: gives players on a 4G connection (~200 ms
  RTT) ample time to receive the spec, decide, and POST a bet; keeps
  lobby cadence at roughly one round per 15–20 s including sim time.
- **BetweenRounds default 5s**: long enough for the HUD to display final
  results and animate the podium before the next spec is minted; short
  enough that the 24/7 lobby feels live.

Both values are operator-tunable at startup — a high-frequency demo can
use `--scheduler-bet-window=3s --scheduler-between-rounds=2s`.

### REMAINING
1. **Durable replay store.** Today: filesystem at `--replay-root`. A
   single-host failure loses round audit data. Replace with object
   storage (S3/GCS/R2) using a write-once + hash-verified envelope; the
   current `replay.Store` API is small enough that a swap is contained.
   (S3Backend stub is in [server/replay/backend_s3.go](../server/replay/backend_s3.go) — needs wiring in rgsd.)
2. **Round-bet persistence.** `pendingRounds` / `roundBets` in Manager
   are in-memory. Restart loses queued bets. Postgres-backed store needed (M9.x work).
3. **Distributed deployment.** Multiple rgsd nodes need to coordinate on
   `previousTrack` (for the no-back-to-back selector), the round_id
   counter (currently unix-nanos — collision-prone across hosts), and
   replay-store ownership. A small etcd / Redis layer is the natural fit.
   Note: single-host multi-round concurrency (per-round isolation) is
   now done; this item covers the multi-host coordination layer only.
4. **Certification readiness.** RNG audit, round-determinism replay
   tests at scale, third-party security review of the HMAC scheme,
   regulator-side auditor portal. None of this is in the repo today.

A reasonable order of attack: 3 (distributed) → 1 (durable storage) → 2
(round-bet persistence) → 4 (certification). Steps 1-3 are infrastructure;
step 4 is a months-long external process in any tier-1 jurisdiction.
