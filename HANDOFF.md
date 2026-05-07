# Handoff — sessione 2026-05-08 (VS Code → Claude Code)

Documento per la prossima sessione Claude Code che riprende da qui.

## TL;DR

Il branch `dev` su origin ora contiene **tutto** il lavoro: M9-M22, Spiral Drop, leaderboard transplant onion, refactor HUD, replay v4 cert-ready, HUD v2 nuovo + Plinko 4-tube di onion. Worktree allineato a dev. Niente uncommitted. Smoke + 105 test Go verdi.

## Stato repo

```
origin/main  (599b254) ← stabile, NON usare per dev work
origin/dev   (df46472) ← TRUNK ATTIVO ★ — riparti da qui
local:
  dev (= origin/dev)
  main
  claude/compassionate-hellman-4f7e39 (worktree, allineato a dev)
worktree:
  D:/Documents/GitHub/marbles-game2 (main repo on dev)
  .claude/worktrees/compassionate-hellman-4f7e39 (claude branch = dev tip)
```

**Una sola fonte di verità: `dev`**. Quando inizi una sessione Claude Code:
1. `cd .claude/worktrees/compassionate-hellman-4f7e39`
2. `git pull origin dev` (o `git merge --ff-only dev` dal main repo)
3. Lavora, lascia uncommitted, lascia HANDOFF.md aggiornato
4. La sessione VS Code (questa) committa + pusha

## Cosa è stato fatto questa sessione (VS Code, 2026-05-08)

1. **Cleanup repo completo**:
   - Phase A: 4 branch stale eliminati locale (operator-mode, player-stats-history, rgs-auto-restart, claude/exciting-jemison-f60a90), stash droppato, rgsd.exe rimosso
   - Phase B: 4 branch eliminati origin (operator-mode, player-stats-history, rgs-auto-restart, feature/m12-broadcast)
   - Phase C: consolidamento — tutto M11-M22 + Spiral + leaderboard onion fuso in dev (force-push autorizzato)

2. **Step 5 — Replay format v4** (commit `febb8bc`):
   - Manifest porta marble_count + podium_payouts + pickup_per_marble_tier + finish_order
   - ProtocolVersion4 + ValidateJackpotConsistency() helper
   - 100 → 105 test Go
   - Backward-compat con v3 (omitempty)
   - **Spec source**: `docs/math-model.md §4.3`

3. **Step 4 — HUD refactor** (commit `7901282`):
   - hud.gd 1971 LOC → 615 LOC (-69%)
   - Split in `hud_layout.gd` (1047) + `hud_runtime.gd` (892) + esistenti `hud_theme.gd` (433) + `hud_i18n.gd` (298)
   - Pattern: HudLayout = static helpers, HudRuntime = Object con back-ref
   - **Persistenza session stats ripristinata** (era stata droppata in v1 del refactor — fixata)
   - API pubblica preservata 100%

4. **Onion ha aggiunto** (mentre la sessione era a metà — ora tutto in dev):
   - `de64d16` Plinko Casino Drop rebuild
   - `fe1bcf7` HUD post-finish settle window 15s + FinishersList top-right panel
   - `df46472` HUD v2 (game/ui/v2/) con balance/round-timer/bet/position cards + Plinko 4-tube intrecciati

## Validazione corrente

```bash
# Headless smoke Plinko: PASS
WINNER: Marble_00 at tick 1655
RECORDER: captured 1715 frames, 20 marbles/frame
ROUNDTRIP: OK

# Go tests: 8 packages tutti verdi (~105 test)
ok  server/replay   server/rgs   server/middleware   ...
```

## Open items per la prossima sessione

In ordine di priorità (mio audit precedente):

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
