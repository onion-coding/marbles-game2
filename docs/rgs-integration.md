# RGS integration

How an operator (or a casino aggregator) plugs a marble race round into
their own game loop. This document describes the **shape** of the
integration as currently implemented in [`server/rgs/`](../server/rgs/);
it's not yet protocol-aligned with any specific aggregator (SoftSwiss,
Pragmatic, EveryMatrix, …) — every aggregator wraps these same primitives
in their own envelope.

## Architecture

```
┌────────────────┐     /v1/sessions, /v1/sessions/{id}/bet     ┌──────────────────┐
│ Operator front │  ◀───────────────────────────────────────▶  │  rgsd (this repo) │
│   (web, app)   │                                             │                  │
└────────────────┘                                             │  rgs.Manager     │
        │                                                      │   ├ rgs.Wallet   │
        │  Wallet.Debit / Credit                               │   ├ replay.Store │
        ▼                                                      │   ├ rtp.Settle   │
┌────────────────┐                                             │   └ sim.Run      │
│ Operator wallet│  ◀───────────────────────────────────────── │     (Godot)      │
│  (db / RGS api)│                                             └──────────────────┘
└────────────────┘
```

The **operator** holds the player's wallet. The **rgsd** service holds
the round / sim / replay store. They communicate two ways:

- Player bets flow operator → rgsd via the public HTTP API below.
- Wallet debits / credits flow rgsd → operator via the [Wallet](../server/rgs/wallet.go) interface.

In this MVP, `rgsd` ships with `rgs.MockWallet` — an in-process map.
A real deployment swaps this for an HTTP client speaking the operator's
wallet protocol.

## Public HTTP API

All routes return JSON. Errors carry `{"error": "<message>"}`. Status
codes follow the obvious HTTP semantics; bet-specific errors map to:

| Code | Meaning                                            |
| ---- | -------------------------------------------------- |
| 400  | malformed body, generic argument error             |
| 402  | insufficient funds                                 |
| 404  | unknown session / unknown player                   |
| 409  | conflicting state (bet already exists, closed, …)  |
| 500  | internal sim or store error                        |

### `POST /v1/sessions`

Open a session for a player. Doesn't move money.

```json
// Request
{ "player_id": "alice" }

// 201 Created
{
  "session_id": "sess_8e0f...",
  "player_id":  "alice",
  "state":      "OPEN",
  "balance":    1250,
  "opened_at":  "2026-04-28T...",
  "updated_at": "2026-04-28T..."
}
```

### `POST /v1/sessions/{id}/bet`

Debit the player's wallet and queue the session's bet for the **next**
round. Returns the updated session (now `state=BET`, with `bet` populated).

```json
// Request
{ "amount": 100 }

// 200 OK
{
  "session_id": "sess_8e0f...",
  "state":      "BET",
  "balance":    1150,
  "bet": {
    "bet_id":       "bet_7c19...",
    "amount":       100,
    "placed_at":    "2026-04-28T...",
    "marble_index": -1
  }
}
```

`bet_id` is also the wallet `txID` — operator can look it up in their
ledger. `marble_index = -1` until the round actually starts; once the
race begins, the index is locked at the bettor's queue position.

### `POST /v1/rounds/{round_id}/bets`

Place a bet directly on a pre-minted round (one returned by
`POST /v1/rounds/start`). The player's wallet is debited immediately;
the credit is applied after `POST /v1/rounds/run` resolves the winner.

Payout multiplier: **19.0× the stake** (`PayoutMultiplier` constant in
`server/rgs/manager.go`). With 20 equi-probable marbles this gives
RTP = 20 × (1/20) × 19.0 = **95%**, analogous to English roulette 35:1.

```json
// Request
{
  "player_id":  "alice",
  "marble_idx": 3,
  "amount":     10.0
}

// 200 OK
{
  "bet_id":                "rbet_4a7f...",
  "round_id":              17773701234567,
  "marble_idx":            3,
  "amount":                10.0,
  "balance_after":         40.0,
  "expected_payout_if_win": 190.0
}
```

Error codes:

| Code | Condition                                            |
| ---- | ---------------------------------------------------- |
| 404  | `round_id` never minted by `/v1/rounds/start`        |
| 409  | round already completed (consumed by `/v1/rounds/run`) |
| 400  | `marble_idx` outside `[0, MaxMarbles)` or `amount ≤ 0` |
| 402  | insufficient wallet funds                            |

**Currency note.** `amount` is a decimal float (e.g. `10.0` = 10 currency
units). Internally the wallet stores cents/units × 100 as an integer;
the conversion is transparent to the caller.

### `GET /v1/rounds/{round_id}/bets[?player_id=<id>]`

List bets placed on a round. Optional `player_id` query param filters
to a single player (useful for UI reconnect / history reload).

```json
// 200 OK — array (may be empty)
[
  {
    "bet_id":     "rbet_4a7f...",
    "player_id":  "alice",
    "round_id":   17773701234567,
    "marble_idx": 3,
    "amount":     10.0,
    "placed_at":  "2026-04-29T..."
  }
]
```

Returns 404 if `round_id` was never minted by `/v1/rounds/start`.

### `POST /v1/rounds/start`

Mint a server-authoritative round spec for a Godot client that wants to
run the physics locally (the `--rgs=<url>` client flow). No session,
wallet, or sim involvement — this is a pure spec-generation call.

The response is the JSON the Godot client uses directly: `server_seed_hex`
fixes the fairness chain on the server; `round_id` is the unix-nanosecond
timestamp generated server-side; `track_id` follows the same no-back-to-back
rotation as `POST /v1/rounds/run`; `client_seeds` is an array of empty
strings (one per marble, MVP — per-player seed mixing is M9.x work).

```json
// POST body: empty ({} or omit)

// 200 OK
{
  "round_id":       17773701234567,
  "server_seed_hex": "a3f1...64 hex chars...",
  "track_id":       3,
  "client_seeds":   ["", "", "...20 entries total..."]
}
```

The Godot client is launched with `--rgs=http://localhost:8080`. When that
flag is present (and `--round-spec` is absent), `main.gd` POSTs to this
endpoint, waits for the response via `HTTPRequest.request_completed`, and
passes the received JSON directly to `_start_race()`. The race physics run
locally; only the seed and track choice are server-authoritative.

### `POST /v1/rounds/run[?wait=true]`

Trigger the next round. Without `wait`, returns 202 immediately and the
round runs in a background goroutine; clients poll `/v1/sessions/{id}`
for the SETTLED state. With `wait=true`, blocks until the round completes
and returns the manifest + per-bet outcomes.

```json
// 200 OK (sync mode)
{
  "round_id":  17773701234567,
  "track_id":  3,
  "winner":    { "marble_index": 0, "finish_tick": 412 },
  "outcomes": [
    {
      "bet_id":       "bet_7c19...",
      "won":          true,
      "amount":       100,
      "prize_amount": 1900,
      "winner_index": 0,
      "credit_tx_id": "bet_7c19...:credit",
      "settled_at":   "2026-04-28T..."
    }
  ]
}
```

Production deployments don't expose `/v1/rounds/run` to operators — a
scheduler runs rounds at a fixed cadence (e.g. every 60 s). It's exposed
here for demos and end-to-end tests.

### `GET /v1/sessions/{id}`

Read current session state. After a round settles, `state=SETTLED` and
`last_result` carries the outcome; the session can place a new bet for
the round after that.

### `POST /v1/sessions/{id}/close`

Close the session. Must be in `OPEN` or `SETTLED` (no orphaned bets).

### `GET /v1/wallets/{player_id}/balance`

Return the current balance for a player. Useful for UI display and
reconnect flows without requiring an open session.

```json
// 200 OK
{
  "player_id": "alice",
  "balance":   12.40
}
```

`balance` is expressed in the same decimal-currency units used by
`POST /v1/rounds/{round_id}/bets` (i.e. wallet integer units ÷ 100).
Returns 404 if `player_id` is not known to the wallet.

| Code | Condition                           |
| ---- | ----------------------------------- |
| 200  | player found, balance returned      |
| 404  | player_id unknown to wallet         |

### `GET /v1/health`

Liveness check for load balancers. Returns 200 / `{"status":"ok"}`.

## Client flow (Godot `--rgs=<url>` mode)

The Godot client launched with `--rgs=http://localhost:8080` runs the
public end-to-end loop wired to the endpoints above. One iteration:

1. **Boot.** `POST /v1/rounds/start` → receive `{round_id, server_seed_hex, track_id, client_seeds[]}`.
   The server-side `pendingRounds` queue locks the seed at this point so it
   can't be retargeted per-bet; `RunNextRound` consumes the head of the queue
   in FIFO order.
2. **Bet window (10 s).** HUD shows the bet placement panel. Each bet hits
   `POST /v1/rounds/{round_id}/bets`; the wallet is debited immediately and
   `balance_after` is shown back to the player. `GET /v1/wallets/{player_id}/balance`
   refreshes the display whenever the player would otherwise see stale data
   (session open, after each bet, at the start of every auto-restart round).
3. **Race.** Bet window expires → client posts `POST /v1/rounds/run?wait=true`
   *and* starts the local visual race in parallel. Both follow the same
   server-supplied seed, so the local winner agrees with the server outcome
   (cross-checked in `_on_round_completed`; mismatch → `push_error` +
   server result wins).
4. **Settlement.** Server response carries `outcomes[]` with per-bet
   `won/lost`, `prize_amount`, `credit_tx_id`. HUD overlays the result on
   the winner modal. Bets that won are credited via the wallet by then.
5. **Auto-restart.** After a 15 s display window (constant
   `RGS_BETWEEN_ROUNDS_SEC` in [game/main.gd](../game/main.gd)), the client
   tears down per-round nodes (track, marbles, recorder, finish line,
   streamer, free-cam) via `_cleanup_round()` and loops back to step 1. HUD
   and `RgsClient` survive the cleanup; signal connections from the
   `RgsClient` to the HUD are wired only on the first round to avoid
   double-firing.

The player ID is a UUID v4 persisted to `user://player_id.txt` on first
run and reused across sessions, so the same wallet balance follows the
player across restarts and auto-restart loops alike.

## Wallet integration

### Multi-currency support (M28)

The wallet now handles multiple currencies per operator configuration:
EUR, USD, GBP, BTC, ETH, USDT. Amount is stored as `float64` (decimal
currency units, e.g. 10.50 EUR) and converted to wallet integer units
(cents/satoshis/etc) internally × 100 for atomic operations.

### Go interface

The [Wallet](../server/rgs/wallet.go) interface is what `rgsd` calls into
the operator. Three methods:

```go
type Wallet interface {
    Debit(playerID string, amount uint64, txID string) error
    Credit(playerID string, amount uint64, txID string) error
    Balance(playerID string) (uint64, error)
}
```

(Amount is opaque integer money — cents, satoshis, USDC-6, whatever the
operator configured. No conversion in `rgsd`; operator labels units in UI.)

### Generic REST protocol (M25)

`HTTPWallet` (`server/rgs/wallet_http.go`) implements the interface by
speaking a simple REST protocol. Any operator wallet service that exposes
these three endpoints is a drop-in replacement:

| Method | Path              | Request body                          | Success body        |
|--------|-------------------|---------------------------------------|---------------------|
| POST   | `/wallet/balance` | `{"player_id":"<id>"}`                | `{"balance":<uint>}`|
| POST   | `/wallet/debit`   | `{"player_id":"<id>","amount":<uint>,"tx_id":"<id>"}` | `{"balance":<uint>}`|
| POST   | `/wallet/credit`  | `{"player_id":"<id>","amount":<uint>,"tx_id":"<id>"}` | `{"balance":<uint>}`|

Error responses must be JSON `{"error":"<message>"}` with the appropriate
HTTP status:

| Status | Meaning                                    |
|--------|--------------------------------------------|
| 200    | Success                                    |
| 402    | Insufficient funds (maps to `ErrInsufficientFunds`) |
| 404    | Unknown player (maps to `ErrUnknownPlayer`) |
| 409    | Idempotent replay acknowledged — treated as success |
| 5xx    | Transient error — retried with exponential backoff |

### HMAC request signing

When `--wallet-hmac-secret-hex` is provided, every outbound request
carries two headers:

```
X-Timestamp: <unix seconds, decimal>
X-Signature: hex(HMAC-SHA256(method + "\n" + path + "\n" + timestamp + "\n" + body))
```

This is identical to the server-side middleware in `server/middleware/`
so operator services that already verify incoming rgsd requests can reuse
the same verification logic for wallet callbacks without any adaptor code.

### Idempotency contract

`tx_id` is provided by `rgs.Manager` for every Debit and Credit call.
Wallet implementations must:

- On a duplicate `tx_id` carrying the **same amount and direction**:
  return 200 or 409 without modifying the balance.
- On a duplicate `tx_id` with a **different amount or direction**: return
  4xx — this signals a programming error, not a retry.

When `--wallet-idempotency-keys` is enabled (default true), `HTTPWallet`
also sends `Idempotency-Key: <tx_id>` so HTTP-layer deduplication at the
operator's load balancer fires before the wallet logic is even reached.

### Retry policy

`HTTPWallet` retries on 5xx and network errors with exponential backoff:
100 ms, 200 ms, 400 ms, … up to `--wallet-retries` additional attempts
(default 3, so 4 total). 4xx errors are never retried — they signal a
client-side mistake that won't resolve on retry.

### Configuring rgsd for a real wallet (M25)

```sh
rgsd \
  --wallet-mode=http \
  --wallet-url=https://wallet.operator.example.com \
  --wallet-hmac-secret-hex=<64 hex chars> \
  --wallet-retries=3 \
  --wallet-idempotency-keys=true \
  --currency=EUR \
  ...
```

Environment variable equivalents: `RGSD_WALLET_MODE`, `RGSD_WALLET_URL`,
`RGSD_WALLET_HMAC_SECRET`, `RGSD_WALLET_RETRIES`, `RGSD_CURRENCY`.

All requests in `HTTPWallet` carry HMAC-SHA256 signing headers identical
to the server-side middleware so operator services already verifying rgsd
requests can reuse the same logic for wallet callbacks without adaptor
code.

### How to integrate with operator X (template)

Replace the fields below with provider-specific values once the
operator's wallet spec is confirmed:

**SoftSwiss / BGaming**
- Wallet base URL: provided by SoftSwiss technical integration docs.
- Auth: SoftSwiss uses MD5-based request signing — implement a custom
  `Wallet` struct rather than using `HTTPWallet` directly; the generic
  REST shape above may not match their envelope. Use `runWalletContractSuite`
  from `wallet_http_test.go` to validate your implementation.

**EveryMatrix / CasinoEngine**
- Wallet base URL: per-operator subdomain from EveryMatrix integration guide.
- Auth: HMAC-SHA256 with a shared secret — compatible with `HTTPWallet`'s
  HMAC mode if the message format aligns; verify with their sandbox.

**Spike Aggregator / GAMP**
- Integration is aggregator-mediated; the aggregator exposes a normalised
  wallet API. Confirm endpoint shape with the aggregator's technical team,
  then verify with `runWalletContractSuite`.

In all cases the contract test suite in `server/rgs/wallet_http_test.go` (M25)
provides the definitive conformance checklist — any Wallet implementation
that passes `runWalletContractSuite` is drop-in compatible with
`rgs.Manager`. The suite validates idempotency, error codes (402 / 404 / 409),
insufficient-funds rejection, and concurrent Debit/Credit safety.

### Wallet contract (behaviour guarantees)

Key behaviour:

- **Idempotency.** `txID` is provided by `rgs.Manager` so the operator
  can dedupe retries. The same bet placed twice (e.g. transient network
  hiccup) sees the same `txID` and the second `Debit` is a no-op.
- **Non-negative balances.** `Debit` returns `ErrInsufficientFunds` if
  the post-debit balance would be negative. `Manager.PlaceBet` surfaces
  this as 402 Payment Required.
- **Currency-agnostic.** `amount` is opaque integer money — cents,
  satoshis, USDC-6, whatever the operator picked. No conversion in our
  code; the operator labels the units in their own UI.
- **Concurrency.** Implementations must be safe for concurrent calls
  (Manager may settle N bets in parallel after a round completes).
- **Credit auto-creates.** `Credit` on an unknown player creates the
  account implicitly (balance = credited amount). This mirrors standard
  operator wallet behaviour and is required by the contract suite.

Errors classified as transient by Manager (anything not `ErrInsufficientFunds`
or `ErrUnknownPlayer`) cause the bet to stay in `pending` state so the
operator can retry by calling the wallet directly. (Pending-state recovery
is M9.x work — currently the manager surfaces the error and the bet
outcome is lost; deployment-blocker, not MVP-blocker.)

## Round-vs-bet semantics

The system runs rounds with a fixed marble count (`--marbles`, typically
20). Bettors fill marble slots in placement order; any seats the bettors
don't claim are filled with synthetic `filler_NN` participants.

- A round always has 20 marbles, so the spawn-slot derivation is symmetric
  across rounds regardless of how many real bettors showed up.
- The total stake for RTP math is `marbles * buy_in` (where `buy_in` is
  the configured stake-per-seat). This means:
  - When all 20 seats are bettors paying 100 each → stake = 2000, prize
    @ 95% RTP = 1900, house keeps 100. Standard case.
  - When only 3 of 20 are bettors → stake counted at 2000 (assuming
    `buy_in=100`); the 1900 prize still pays out, but if the winning
    marble is a filler, **the prize stays with the house as additional
    rake**. This is the operator-facing tradeoff: empty seats earn
    house edge.

This is a deliberate design: filler seats keep the fairness derivation
shape constant; the "house keeps prizes won by fillers" rule means
there's no perverse incentive to flood rounds with synthetic players.

## Audit trail

Every round writes a `manifest.json` to the replay store with:

- `round_id`, `protocol_version`, `tick_rate_hz`, `track_id`
- `server_seed_hash_hex` (commit) + `server_seed_hex` (reveal)
- `participants[]` — every marble's `marble_index`, `name`, `client_seed`
- `winner.marble_index` and `winner.finish_tick`
- `replay_sha256_hex` for tamper detection

The audit entry alone is enough to replay the round (via `verify_main`)
and confirm the operator's wallet movements:

- For each `participant` whose `name` matches a real player_id, the
  manifest implies `Debit(player_id, buy_in)` happened.
- If `winner.marble_index == participant.marble_index` for that player,
  the manifest implies `Credit(player_id, prize)` happened, where
  `prize = stake * rtp_bps / 10000` (integer math, see
  [server/rtp/rtp.go](../server/rtp/rtp.go)).

A regulator's auditor doesn't need anything else from the operator's
side to verify a round's wallet flow against the audit trail.

## Admin panel (M28)

Operator-facing UI at `GET /admin` (requires HMAC auth if enabled).
Embedded HTML + inline CSS, served from [server/admin/](../server/admin/).
No external assets, no separate frontend build.

**Four tabs:**

1. **Sessions** — list of all active player sessions with:
   - player_id, balance, state (OPEN / BET / SETTLED), open time, last update.
   - Click to drill down: bets placed in that session, session history.

2. **Rounds** — pending + completed rounds with:
   - round_id, track_id, status, participant count, winner, payout total.
   - Live rounds show marble progress and live bet counts.

3. **Configuration** — live hotfixes without restart:
   - RTP adjustment slider (e.g. 95% ↔ 98%).
   - Pause/Resume toggle (queues new rounds but doesn't interrupt in-flight).
   - Currency picker (EUR / USD / GBP / BTC / ETH / USDT).

4. **Wallet** — diagnostic + recovery:
   - Test debit/credit operations against the live wallet.
   - Pending credits table (if any failed Wallet.Credit calls are queued).
   - Manual recovery button: re-attempt pending credits.

**No database dependency** — all reads stream from `Manager` in-process +
optional Postgres session table. Config changes (RTP, pause) are in-memory
only; they don't persist a restart (intentional — operator re-applies on deploy).

**Security:** Requires the same HMAC auth as `/v1/*` endpoints. If `--hmac-secret-hex`
is unset (dev mode), `/admin` is wide open.

## Open items

- **Real wallet client (done — M25).** `HTTPWallet` in
  `server/rgs/wallet_http.go` provides the generic REST client.
  Provider-specific envelope adapters (SoftSwiss, EveryMatrix) are still
  needed; see "How to integrate with operator X" above.
- **Pending-state recovery.** Wallet errors on credit currently bubble
  up; the bet result is lost. Add a `pending_credits` table in the
  manager so the operator can call `/v1/sessions/{id}/reconcile` to
  retry the credit after the wallet recovers.
- **Concurrent rounds.** MVP runs rounds serially. A real deployment
  needs N rounds in flight (one per "lobby" / table) with isolated
  per-round state. Manager already takes a context.Context for this;
  the next step is a per-round goroutine pool.
- **WebSocket round events.** Operators want push notifications when a
  round starts / settles instead of polling `/v1/sessions/{id}`. Reuse
  the existing live-stream WS infra in `server/stream/`.
- **Session persistence (done — M24).** `Manager.sessions` is now
  backed by `server/postgres` when `--postgres-dsn` is set.
  `OpenSession` / `PlaceBet` / `CloseSession` write through to Postgres;
  `Session()` falls back to a DB read on cache-miss so sessions survive
  restarts. See `docs/deployment.md` §"Postgres setup" for the DSN flag
  and migration instructions.
- **Round-bet persistence.** `pendingRounds` and `roundBets` in
  `Manager` are in-memory only. A server restart loses all queued bets
  and round-id registrations. Needs a Postgres-backed store (M9.x).
- **Round-bet amount precision.** `amount` is stored as `float64` and
  converted to wallet integer units by multiplying × 100 (2 decimal
  places). This is adequate for cent-denominated currencies but will
  lose precision for USDC-6 or satoshi units. Switch to a
  `decimal.Decimal` or operator-supplied integer + exponent pair.
- **Duplicate marble_idx bets.** The MVP allows a single player to
  place multiple bets on the same marble in the same round. Add an
  optional uniqueness constraint if the game rules require it.
