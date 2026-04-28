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

## Open operational items

The MVP gets you to "could be deployed for an internal dogfood / closed
beta". To take real money these still need work:

1. **Durable replay store.** Today: filesystem at `--replay-root`. A
   single-host failure loses round audit data. Replace with object
   storage (S3/GCS/R2) using a write-once + hash-verified envelope; the
   current `replay.Store` API is small enough that a swap is contained.
2. **Real wallet client.** `rgsd` ships with `MockWallet` — an in-process
   map. Real deployments need an HTTP client that talks the operator's
   wallet protocol (typically POST with HMAC); the [Wallet](../server/rgs/wallet.go)
   interface is the seam.
3. **Multi-round concurrency.** `Manager.RunNextRound` is serial. A real
   deployment runs lobbies in parallel — one Goroutine per active
   round_id with isolated state.
4. **Postgres for sessions / bets.** Currently in-memory; a process
   restart loses session state and any pending bets get orphaned.
5. **Round scheduler.** `/v1/rounds/run` is currently the only way to
   advance a round — fine for demos, useless for a 24/7 lobby. Add a
   ticker that runs rounds at a fixed cadence + opens new sessions
   automatically when the prior one ends.
6. **Distributed deployment.** Multiple rgsd nodes need to coordinate on
   `previousTrack` (for the no-back-to-back selector), the round_id
   counter (currently unix-nanos — collision-prone across hosts), and
   replay-store ownership. A small etcd / Redis layer is the natural fit.
7. **Certification readiness.** RNG audit, round-determinism replay
   tests at scale, third-party security review of the HMAC scheme,
   regulator-side auditor portal. None of this is in the repo today.

A reasonable order of attack: 2 (real wallet) → 6 (distributed) → 1
(durable storage) → 5 (scheduler) → 4 (Postgres) → 3 (concurrency) →
7 (certification). Steps 1-5 are infrastructure; step 7 is a
months-long external process in any tier-1 jurisdiction.
