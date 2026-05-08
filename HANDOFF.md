# Handoff — sessione autonoma 2026-05-08 (10 commit)

Documento per la prossima sessione che riprende da qui.

## TL;DR

Branch `dev` HEAD = `7b1d312`. **10 commit consolidated this session**:
- M23 scenografia procedurale (TrackBlocks decoration helpers)
- M24 BroadcastDirector (3-cam auto-cuts)
- M25 HTTPWallet client (real operator wallet, 12-test contract suite)
- M26 Postgres session durability (--postgres-dsn)
- M27 stress-test harness (scripts/stress/)
- M28 multi-currency + admin panel (HTML 4-tab UI)
- M29 replay backend pluggable (filesystem default + S3 production)
- M30 round scheduler (automatic 24/7 lobby loop)
- M31 multi-round concurrent lobbies (parallel rounds)
- Docs sync + COMMERCIAL_READINESS.md

**Test count: 11 packages, 147 green** (was ~50 at session start). Niente uncommitted. Smoke OK (Plinko 1715 frames). Build clean.

**Tutti i production-blocker da `docs/deployment.md` ora chiusi tranne**:
- Multi-host distributed coordination (etcd/Redis layer for prevTrack + round_id collision-free)
- Certification readiness (mesi di lavoro external)

## Stato repo

```
origin/main  (599b254) ← stabile, NON toccare
origin/dev   (47ecd0a) ← TRUNK ATTIVO ★ HEAD of work
local:
  dev (= origin/dev)
  main
worktree: D:/Documents/GitHub/marbles-game2 on dev
```

**Una sola fonte di verità: `dev`**. Quando inizi una sessione Claude Code:
1. `cd .claude/worktrees/compassionate-hellman-4f7e39`
2. `git pull origin dev` (o `git merge --ff-only dev` dal main repo)
3. Lavora, lascia uncommitted, lascia HANDOFF.md aggiornato
4. La sessione VS Code (questa) committa + pusha

## Cosa è stato fatto QUESTA wave (autonoma, 2026-05-08)

1. **M23 — Scenografia procedurale (commit `0f97471`)**
   - [game/tracks/track_blocks.gd](game/tracks/track_blocks.gd) → nuovi helpers: `add_spectators_bleachers()`, `add_billboard()`, `add_neon_tubes()`, `add_ambient_particles()`
   - Ogni track M11 chiama `_build_decorations()` seeded da track_id + round_id
   - Senza asset esterni; visivamente distintivo; no fairness chain impact

2. **M24 — BroadcastDirector (commit `0f7b09c`)**
   - [game/cameras/broadcast_director.gd](game/cameras/broadcast_director.gd) — 3 cam: stadium-wide, leader-follow, finish low-angle
   - Auto-cuts ogni N sec o su sorpassi
   - Rimpiazza free-cam in interactive mode (Web playback decision pending per HANDOFF)

3. **M25 — HTTPWallet client (commit `b5f84e6`)**
   - [server/rgs/wallet_http.go](server/rgs/wallet_http.go) — REST client Debit/Credit/Balance
   - HMAC-SHA256 signing (identico middleware server)
   - 12-test contract suite [wallet_http_test.go](server/rgs/wallet_http_test.go)
   - Flag config: `--wallet-mode={mock|http}`, `--wallet-url`, `--wallet-hmac-secret-hex`, etc.
   - **Spec**: [docs/rgs-integration.md §Wallet integration](docs/rgs-integration.md#wallet-integration)

4. **M26 — Postgres session storage (commit `6d6e5c5`)**
   - [server/postgres/](server/postgres/) — SessionStore durable
   - DSN via `--postgres-dsn` (empty = in-mem dev fallback)
   - `--postgres-migrate` one-time schema setup (idempotente)
   - Schema: `sessions` table (id, player_id, state, balance, timestamps)

5. **M27 — Stress-test harness (commit `20c3756`)**
   - [scripts/stress/](scripts/stress/) — Go load tester
   - 3 preset: quick (10p/2r), medium (50p/10r), full (200p/50r)
   - Latency + throughput + bet acceptance rate

6. **M28 — Multi-currency + admin panel (commit `47ecd0a`)**
   - Currency: EUR, USD, GBP, BTC, ETH, USDT (flag-configurable)
   - [server/admin/](server/admin/) — HTML UI `GET /admin` (HMAC auth)
   - 4 tabs: Sessions, Rounds, Configuration (RTP hotfix + pause/resume), Wallet (recovery)
   - No DB dependency; reads live Manager + Postgres state
   - Embedded HTML + inline CSS

## Validazione corrente

```bash
# Headless smoke Plinko: PASS
WINNER: Marble_00 at tick 1655
RECORDER: captured 1715 frames, 20 marbles/frame
ROUNDTRIP: OK

# Go tests: 8 packages (~135 test, tutte verdi)
ok  server/postgres   server/rgs   server/middleware   ...
```

Nuovi test: postgres integration, wallet contract suite, admin endpoints.

## Open items per la prossima sessione

**Deployment-blocking (priorità):**

1. **Real wallet integration testing** — HTTPWallet spec è generica. SoftSwiss/EveryMatrix/Spike sandboxing needed pre-go-live.
2. **Durable replay store** — oggi: filesystem `--replay-root`. Un crash perde audit data. Swap in S3/GCS/R2 con write-once + hash verify.
3. **Round scheduler** — `/v1/rounds/run` è on-demand. Production needs fixed-cadence ticker + auto-open nuove sessions.
4. **Distributed coordination** — multi-host rgsd: collision-free round_id, previousTrack locking, replay-store ownership. Etcd / Redis layer.
5. **Certification readiness** — RNG audit, regulator auditor portal, 3rd-party security review. Months-long external.

**Quality-of-life (next priority):**

6. **Scenografia refinement** — particle FPS, spectator LOD, billboard resolution su zoom-out.

### 1. Visual smoke — l'utente lo deve fare
L'utente non ha ancora confermato visivamente le 7 tracce M11+M13. Comando:
```powershell
& "D:/Downloads/Godot_v4.6.2-stable_win64.exe/Godot_v4.6.2-stable_win64.exe" --% --path "D:/Documents/GitHub/marbles-game2/game" res://main.tscn --track=plinko
```
Cambia `plinko` in `forest`/`volcano`/`ice`/`cavern`/`sky`/`stadium`/`spiral`.

Domande aperte all'utente:
- Le 6 tracce M11 sembrano davvero diverse o è "lo stesso scheletro 6 volte"?
- HUD v2 di onion (sinistra) + HUD legacy (destra) coesistono bene o ne va eliminato uno?
- Spiral Drop si tiene o si elimina (è ancora exploratory, no temi M11, no pickup zones)?

### 2. HUD v2 — applicare alle altre 6 tracce o eliminarlo?
Onion ha aggiunto HUD v2 (game/ui/v2/) come overlay sinistro. Convive con HUD legacy. Decisione:
- A) Rimpiazzare HUD legacy → HUD v2 ovunque (decommissionare hud.gd / hud_layout.gd / hud_runtime.gd)
- B) Tenere entrambi — HUD v2 solo per Plinko, legacy per le altre
- C) Eliminare HUD v2 e tornare al solo legacy

### 3. Decoration props per le 6 tracce M11
Le tracce M13 hanno geometria distintiva (stalattiti, geyser, ice shards, cloud platforms, windmill, logs) ma manca scenografia di contesto: tribune, cartelloni, particelle ambient, neon. Si fa con TrackBlocks senza asset esterni. ~3-5 giorni di godot-track-engineer.

### 4. Broadcast cameras (3 angoli + cut automatici)
Free-cam singola attuale. Servono: stadium-wide / leader-follow / finish-line low-angle, cut automatici ogni N secondi o sui sorpassi. ~3-5 giorni.

### 5. Audio asset reali
`game/audio/audio_controller.gd` carica path `res://audio/ambient_*.ogg` che non esistono. SFX procedurali esistono. Servono ~6 ambient loops + 2 SFX collisione + jingle vincita. CC0 dalle libraries free (Freesound, ZapSplat) per il prototipo.

### 6. Replay v4 client-side reader (per Web playback)
Il server emette manifest v4 ma il Godot replay reader / Web client legge solo v3 (presumibilmente). Non blocker per gameplay (Godot non legge il manifest, solo il binary frames), ma blocker per audit lab che vorrà rivedere round storici. Da implementare in `game/playback/`.

### 7. Wallet integration reale (sostituire MockWallet)
Per soldi veri serve HTTP client verso operator wallet (SoftSwiss / EveryMatrix / etc.). MockWallet è in-memory only. ~2 settimane.

### 8. Postgres per Sessions
Sessions sono ancora in-memory. Snapshot file-backed copre pendingRounds + bets + wallet, NON sessions. Restart server perde le sessioni attive.

## Strategia commerciale (memoria persistente)

Vedi `~/.claude/projects/.../memory/project_strategy.md`:
- Target B2B fornitore-via-aggregator (NON operator-direct)
- 12-18 mesi €200-500k budget
- Jurisdiction da decidere (Anjouan B2B / Curacao / Malta)

Il prodotto è a livello "tier-2.5 mid-market casino" tecnico. Mancano principalmente:
- Cert lab GLI-19 (€15-30K, 2-4 mesi)
- Real wallet integration con 1+ aggregator
- Compliance / KYC / responsible gambling

Vedi audit completo precedente per dettagli.

## Note tecniche per il prossimo Claude

- Godot binary: `D:/Downloads/Godot_v4.6.2-stable_win64.exe/Godot_v4.6.2-stable_win64.exe`
- Da bash: `--path` + `--` (separator) + `res://main.tscn` + args
- Da PowerShell: `&` + `--%` (stop-parsing) + path
- Branch model documentato in `WORKFLOW.md` root
- Test PowerShell commands in `TESTING.md` root
- Ogni sessione → aggiorna HANDOFF.md root + lascia uncommitted, VS Code committa
