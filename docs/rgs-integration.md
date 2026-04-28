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

### `GET /v1/health`

Liveness check for load balancers. Returns 200 / `{"status":"ok"}`.

## Wallet contract

The [Wallet](../server/rgs/wallet.go) interface is what `rgsd` calls into
the operator. Three methods:

```go
type Wallet interface {
    Debit(playerID string, amount uint64, txID string) error
    Credit(playerID string, amount uint64, txID string) error
    Balance(playerID string) (uint64, error)
}
```

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

Errors classified as transient by Manager (anything not `ErrInsufficient
Funds` or `ErrUnknownPlayer`) cause the bet to stay in `pending` state
so the operator can retry by calling the wallet directly. (Pending-state
recovery is M9.x work — currently the manager surfaces the error and
the bet outcome is lost; deployment-blocker, not MVP-blocker.)

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

## Open items

- **Pending-state recovery.** Wallet errors on credit currently bubble
  up; the bet result is lost. Add a `pending_credits` table in the
  manager so the operator can call `/v1/sessions/{id}/reconcile` to
  retry the credit after the wallet recovers.
- **Concurrent rounds.** MVP runs rounds serially. A real deployment
  needs N rounds in flight (one per "lobby" / table) with isolated
  per-round state. Manager already takes a context.Context for this;
  the next step is a per-round goroutine pool.
- **Auth.** No request signing yet. Add HMAC + timestamp-based replay
  protection before exposing rgsd publicly.
- **WebSocket round events.** Operators want push notifications when a
  round starts / settles instead of polling `/v1/sessions/{id}`. Reuse
  the existing live-stream WS infra in `server/stream/`.
