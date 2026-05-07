---
tags: [architecture, client-server, hud, fairness]
status: living
---

# Architecture

> [!info] What's in this file
> The high-level boundaries between the Godot client and the (eventual) RGS
> server. Read this before adding any feature that touches money, spawn
> seeds, multipliers, or settlement.

---

## Why the split exists

Right now the Godot client owns:

- the visual race (Jolt physics over a server-supplied seed),
- the HUD (balance, bet card, timer, position card, settlement banner),
- the **payout math** (`game/main.gd::V2_PAYOUT_*`, `HudV2.begin_resolve()`),
- per-marble multiplier collection (`PickupZone` → `_aggregate_pickups`),
- the local mock balance for HUD v2 interactive mode.

This is fine for development and for replays. It is **not okay** for any
build that handles real money. The client must become a *display* of an
authoritative server's decisions, not the source of truth for them.

---

## Client / server separation — target shape

| Concern | Today | Target |
|---|---|---|
| **Round seed** | client generates in interactive mode; server-supplied in RGS | server-supplied always |
| **Balance** | client-side `HudV2._balance` mock | server holds the wallet; client only renders cached snapshots from `RgsClient.balance_loaded` |
| **Bet acceptance** | client emits `bet_placed`, no validation | server `POST /v1/bets` returns ok / error; client locks the bet card optimistically and rolls back on rejection |
| **Multiplier resolution** | client tallies `PickupZone._collected` and computes the manifest | server resolves on top of the replay; client receives `round_bet_outcomes` and shows them |
| **Position payouts** | hard-coded `V2_PAYOUT_1ST/2ND/3RD` in `main.gd` | server-side payout table, fetched alongside the round spec |
| **Force start** | debug button in `HudV2._build_debug_panel` | dev-only flag; gated server-side in production |
| **Replay record** | client writes `user://replays/<round_id>.bin` | client uploads to server; server is the canonical store |
| **Math model** | `docs/math-model.md`, `docs/plinko-spec.md` (informational on client) | same docs, but the server is the implementation |

The **boundary** is the round-spec request and the round-bet-outcomes
response (see `docs/rgs-integration.md`). Everything inside Godot can move
freely; everything that crosses that wire must be shaped by the server.

### Replay determinism is the contract

The single non-negotiable: given the same `(server_seed, round_id, client_seeds)`,
client and server must produce identical marble paths, slot pickups, and
finish order. That is what makes the client untrusted-but-verifiable: the
server can re-run the same Jolt physics and check the client's manifest
matches. See `docs/fairness.md` for the protocol.

---

## HUD v2 — what's client-only on purpose

`game/ui/v2/` (introduced 2026-05) is purely visual. It owns:

- card layout and animations (spec: `HUD Style Spec.md`),
- the IDLE → LIVE → RESOLVE state machine **as seen by the player**,
- a *local mirror* of the server's authoritative state.

The HUD never decides whether a bet is valid, what a multiplier was worth,
or whether the player won. It receives those decisions and animates them.
When the server is wired in, the client paths look like:

```
IDLE   bet_card → bet_placed → RgsClient.place_bet(amount, marble_idx)
                                  ↓
                      server returns ok+balance OR error
                                  ↓
                  HudV2.set_balance(new_balance) / show_error_toast()

LIVE   round timer hits 0 → request next spec → run race
                                  ↓
                  HudV2 animates standings from local sim (server-deterministic)

RESOLVE  finish_line crossing → wait for round_bet_outcomes from server
                                  ↓
                       HudV2.begin_resolve(...) using server payouts
```

The interactive mode in `main.gd` short-circuits all three steps with
local logic for solo play / development. That short-circuit is the file's
biggest tech debt — it should be possible to flip a flag and have the same
HudV2 drive a real server round without changing any UI code.

---

## Where each concern lives today

```
game/
├── main.gd                      ← interactive state machine + (today) payout math
├── ui/v2/                       ← HudV2 spec implementation (purely visual)
├── ui/hud.gd  + hud_layout.gd   ← legacy HUD (RGS / playback / live modes)
├── recorder/                    ← replay writer (deterministic; client- AND server-safe)
├── fairness/seed.gd             ← provably-fair derivations (mirrored on the server)
└── sim/pickup_zone.gd           ← per-marble multiplier collection (replay-stable)

server/                          ← RGS scaffold; will eventually own payout math
docs/
├── architecture.md              ← THIS FILE
├── fairness.md                  ← provably-fair protocol (client + server)
├── math-model.md                ← payout/RTP derivations
├── plinko-spec.md               ← per-track spec
├── rgs-integration.md           ← how the client talks to the server
└── tick-schema.md               ← replay byte format
```

---

## Open work (sorted by priority)

- [ ] **Move payout table off the client.** `V2_PAYOUT_1ST/2ND/3RD` in
      `main.gd` is a development convenience. Production should fetch the
      payout table per round.
- [ ] **Migrate RGS / playback / live modes to HudV2.** Legacy `HUD` class
      handles all three — not blocked by anything, just hours of API work.
- [ ] **Server-validated bet placement.** `HudV2._on_bet_pressed` accepts
      any amount up to local balance; should round-trip through the RGS
      first.
- [ ] **Multiplier-zone payout integration.** Position card should be
      able to display the player's accumulated multiplier (server-pushed)
      live during LIVE state. The hook is in place
      (`HudV2.update_player_multiplier`), but no caller drives it yet in
      interactive mode.
- [ ] **Spectator mode.** Client without a wallet should still be able to
      watch — HudV2 should accept a "no bet" mode that hides the bet card
      and the balance flash.

---

## Related

- [[Fairness Protocol]] — `docs/fairness.md`
- [[Tick Schema]] — `docs/tick-schema.md`
- [[Math Model]] — `docs/math-model.md`
- [[RGS Integration]] — `docs/rgs-integration.md`
- [[HUD Style Spec]] — root-level `HUD Style Spec.md`
