# Commercial readiness — what's done vs what needs business decisions

Snapshot al 2026-05-08. Branch `dev` (HEAD `47ecd0a`).

Questa è la mappa "tecnica vs business" del progetto: **cosa è già pronto a livello codice** vs **cosa è bloccato da decisioni che non si possono delegare a un agente di codifica**.

---

## ✅ TECNICAMENTE PRONTO (ship-ready dal punto di vista codice)

### Core gameplay
- **7 tracce M11/M13** con geometry distintiva + scenografia procedurale (M23)
- **Provably-fair chain** SHA-256 commit/reveal, replay verifier, deterministic kinematic obstacles
- **Replay format v4** cert-ready (manifest porta podium_payouts + pickup_per_marble_tier + finish_order)
- **v2 payout model** (podium 9/4.5/3 + Tier1 2× / Tier2 3× + jackpot 100×) con math model documentato per cert lab
- **Multi-bet types** single / top3 / top5 (string field preservato; settle via ComputeBetPayoff)

### HUD / UX
- **HUD legacy** refactored in 3 moduli (hud.gd 615 LOC + hud_layout.gd 1047 + hud_runtime.gd 892)
- **HUD v2 onion** (game/ui/v2/) come overlay sportbook-style per Plinko
- **Camera system** broadcast director con 3 angoli + auto-cuts + fades (M24)
- **Persistenza session stats** per player_id su user://player_stats.json
- **i18n** scaffold 5 lingue (en/it/es/de/pt)

### Backend RGS
- **HTTPWallet client** generic con HMAC signing + retry + idempotency (M25)
- **MockRemoteWallet** per integration test contract suite (12 test)
- **Postgres session storage** opzionale via `--postgres-dsn` (M26)
- **File-backed snapshot** persistence (--data-dir) per pendingRounds + bets + wallet
- **Multi-currency wallet** EUR/USD/GBP/BTC/ETH/USDT con decimal precision corretta (M28)
- **9 endpoint REST** /v1/* coperti da HMAC auth + audit log strutturato
- **Operator admin panel** server/admin/* con UI HTML 4-tab (Rounds/Wallets/Config/Audit)

### Production scaffolding
- **Phase 0 ops**: LICENSE, NOTICE, CHANGELOG, CONTRIBUTING, COC, Makefile, .env.example, GitHub CI + dependabot
- **Docker**: ops/Dockerfile.rgsd (multi-stage Godot 4.6.2 bundled) + Dockerfile.replayd (distroless)
- **docker-compose** con Postgres + Prometheus + Grafana
- **Stress test harness** (M27) stdlib Go con 3 preset (quick/medium/full)
- **CI RTP regression gate** (M22) verifica empirical RTP non drift
- **8 packages, 135+ test Go tutti verdi**

### Documentation
- README.md, PROGRESS.md, PLAN.md, HANDOFF.md, WORKFLOW.md, TESTING.md
- docs/math-model.md (~370 LOC, cert-ready dossier)
- docs/rgs-integration.md (full API spec)
- docs/deployment.md (ops runbook)
- docs/marbles-on-stream.md (reference)

---

## 🔴 BLOCCATO DA DECISIONI BUSINESS (non delegabili a un agente)

### 1. Certificazione GLI-19 / RNG (€15-30K, 2-4 mesi)
- Serve un cert lab esterno (GLI / iTech / BMM / TST)
- Il dossier matematico è già pronto in `docs/math-model.md`
- Decisione: **quale lab + budget per il cert**

### 2. Aggregator partnership
- HTTPWallet client è generic + ha contract suite. Drop-in pronto.
- Decisione: **quale aggregator per primo** (SoftSwiss / EveryMatrix / Spike / Pragmatic / Relax / GAMP)
- Ogni aggregator richiede ~1 settimana di adapter development per il loro specific protocol
- Negoziazione contrattuale + onboarding ~1-3 mesi
- Senza un partner concreto, non si può testare end-to-end con soldi veri

### 3. Giurisdizione + entità legale
- Tier diverse:
  - Anjouan B2B (lite, ~€10K, 4-6 settimane)
  - Curacao (medio, ~€20-30K, 2-3 mesi)
  - Malta MGA (heavy, ~€50K+, 6-12 mesi audit)
  - UK GamCom (top-tier, ~€100K+, 9-15 mesi)
- Ogni giurisdizione ha responsible-gambling requirements specifici (UK p.es. self-exclusion via GamStop)
- Decisione: **dove iniziare**

### 4. KYC provider integration
- Decisione: **Sumsub / Onfido / IDology / Veriff / Jumio**
- Game riceve `player_id` + `kyc_level` da provider, gate gioco per livello
- ~2 settimane di codice una volta scelto il provider

### 5. Decisione "quanti track"
- Oggi 7 tracce diverse (Forest/Volcano/Ice/Cavern/Sky/Stadium/Spiral)
- Casino vendono **gioco singolo**, non bundle. 7 mappe = 7 cert separati
- Decisione: **quale 1-2 tracce diventano i "lead title"**, le altre vanno in cassetto
- Suggerimento: Plinko (Sky) + Stadium come primi due, gli altri come content drop futuro

### 6. Asset audio commissioned
- SFX procedurali OK come placeholder
- Per "casino tier-2 audio" servono ambient music + impact SFX commissioned (€2-5K) o premium pack (€500/anno Epidemic Sound)
- Decisione: **budget audio**

### 7. Branding finale
- Logo / nome studio / nome game / palette ufficiale
- HUD ha apply_operator_theme() hooks pronti → operator skin senza re-deploy
- Decisione: **identità visuale**

### 8. Tournament / streamer / bonus engine
- Engine tournament + streamer mode + bonus engine NON implementati
- Tutti richiedono game design decisions (regole, prize pool, scheduling)
- Sono "v1.5" feature, non blocker per primo deploy

---

## 📊 Sintesi numerica

| Area | Tecnico (% done) | Business (decisione richiesta) |
|---|---|---|
| Provably-fair core | 95% | — |
| Game gameplay | 85% | quale 1-2 track produrre |
| HUD/UX | 90% | HUD legacy vs v2 |
| Backend RGS | 85% | wallet provider |
| Persistence | 95% | — |
| Multi-currency | 90% | quali currencies attivare |
| Admin panel | 85% | operator skin |
| Production scaffolding | 80% | Postgres prod target |
| Cert readiness | 60% | scelta cert lab + budget |
| Compliance / KYC | 5% | scelta provider |
| Audio | 40% | budget commission |
| Branding | 0% | identità studio |

---

## 🎯 Cosa fare la prossima settimana (per sbloccare)

1. **Sit-down 2 ore** con onion + decidi: jurisdiction + 1° aggregator + scelta lead track (1-2)
2. **Email a 3 aggregator** richiedendo wallet protocol docs + integration timeline (anche solo "prima conversazione")
3. **Email a 2 cert lab** chiedendo quote per certificazione game RNG-based con math model allegato
4. **Decision branding**: nome game + logo (anche stub Fiverr per €100)
5. **Audio**: scegli tra Epidemic Sound subscription (€15/mese) o commissione (€2-5K)

Una volta deciso: io e gli agenti possiamo coprire il 90% del codice rimanente in 4-6 settimane. Il restante 10% sono adapter specifici per provider scelti — diretto da te + onion.

---

## 🚦 Stato finale

**Codice tecnico**: pronto per soft-launch crypto-only su Anjouan B2B in 4-6 settimane di lavoro residuo (asset audio, branding, KYC integration, 1 wallet adapter).

**Tier-1 jurisdictions** (Malta MGA / UK GamCom): 6-12 mesi di cert + compliance, non blocking codice.

**Il vero collo di bottiglia da qui in avanti è il business path, non l'engineering**.
