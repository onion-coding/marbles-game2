# Math model — Marbles race payout

Documento canonico per il modello matematico di pagamento di marbles-game2. Scritto per essere passato a un certification lab (iTech / GLI / BMM) e usato come specifica unica cross-map.

Ultimo aggiornamento: 2026-05-02 — payout v2 (30 marble + podium top-3 + pickup multipliers + jackpot).

---

## 1. Contesto e bet model

**Round structure.** 30 marble per round. Il giocatore piazza una bet su una specifica marble (marble_index in [0, 29]). Una sola bet per round per marble (un marble può ricevere bet multipli da player diversi).

**Outcome categories.** Ogni marble è in uno e uno solo di questi 8 stati a fine round:

| Stato | Descrizione | Probabilità (uniforme) | Payoff (× stake) |
|---|---|---|---|
| `1ST_PLAIN` | 1° classificato, nessun pickup | base × P(no pickup) | 9× |
| `2ND_PLAIN` | 2° classificato, nessun pickup | base × P(no pickup) | 4.5× |
| `3RD_PLAIN` | 3° classificato, nessun pickup | base × P(no pickup) | 3× |
| `1ST_PICKUP` | 1° + pickup multiplier | base × P(pickup) | 9× × pickup |
| `2ND_PICKUP` | 2° + pickup multiplier | base × P(pickup) | 4.5× × pickup |
| `3RD_PICKUP` | 3° + pickup multiplier | base × P(pickup) | 3× × pickup |
| `MID_PICKUP` | non-podium + pickup | non-podium × P(pickup) | pickup |
| `MID_NO_PICKUP` | non-podium + no pickup | non-podium × P(no pickup) | 0 |

**Probabilità di ranking.** Assunzione di uniformità basata sul fairness chain (commit/reveal SHA-256 + slot derivation deterministica): ogni marble ha probabilità identica 1/30 di finire 1°, 2°, 3°, e 27/30 di finire 4°-30°.

Nota: l'assunzione di uniformità è verificabile a posteriori via il replay store. RTP smoke harness in [scripts/rtp_smoke.sh](../scripts/rtp_smoke.sh) e l'analyzer in [scripts/analyze_replays.py](../scripts/analyze_replays.py) misurano lo scarto empirico dalla distribuzione uniforme con un test χ².

---

## 2. Pickup multipliers — modello geometrico

Le **pickup zones** sono trigger statici nella geometria della mappa (Area3D in Godot). Un marble che attraversa una zona collezionerà il moltiplicatore associato. Le zone sono **geometriche, deterministiche-by-physics**: la fisica del marble è già deterministica dal seed, quindi anche il pickup è deterministico — replay-stable per costruzione.

### 2.1 Tier system

| Tier | Multiplier | Max marbles per round | Vincolo geometrico |
|---|---|---|---|
| **Tier 0** | 1× (no pickup) | — | Default state |
| **Tier 1** | 2× | **4** (hard cap, da brief) | 4 zone "comuni" disposte in posizioni ad alta probabilità di traffico |
| **Tier 2** | 3× | **1** (raro) | 1 zona "centrale" più stretta, probabilità ~70% di essere attraversata |
| **Tier 3** | _jackpot_ | **0 o 1** (super raro) | Combo trigger — vedi §4 |

**Regola di stack**: un marble può attraversare al massimo UNA pickup zone per tier. Se un marble attraversa multipli (es. Tier 1 + Tier 2), prende il **MAX** dei multiplier collezionati, non il prodotto. Quindi il valore pickup di una marble è in {1, 2, 3}.

**Stack con podium**: il payoff finale è `base_podium × pickup` (moltiplicativo), come da brief.

### 2.2 Implementazione geometrica per garantire i cap

Vincolo "max N marble per tier" è realizzato dalla geometria: le pickup zones sono Area3D fisicamente strette tanto che, dato il flow tipico della mappa, attesa di marbles passing through ≈ N.

**Cross-map consistency** — algoritmo che ogni mappa deve rispettare:

```
Per ogni mappa M:
  - Posiziona 4 zone Tier 1 (2×) lungo il flow principale, in punti dove il narrowing
    geometrico forza max ~1 marble a passare per zona (zone width ≈ 1.0m,
    marble diameter 0.6m).
  - Posiziona 1 zona Tier 2 (3×) in posizione "premium" (es. centro perfetto del
    funnel finale, o slot speciale del wheel di roulette finish).
  - Tier 3 jackpot è un sub-event della mappa specifica (es. Roulette: slot
    "verde 0", probabilità geometrica ~3.7% di passaggio).

Smoke test: simula 100 round con seed diversi, conta marbles che attraversano
ogni tier. Vincolo:
  - Tier 1 average passes ≤ 4 marbles per round (deviazione ≤ 1)
  - Tier 2 average passes ≤ 1.0 marble per round (deviazione ≤ 0.3)
  - Tier 3 jackpot trigger ≤ 1 per 1000 round (target: 1 ogni ~10000 round)
```

Se una mappa non rispetta il cap (es. 6 marble passano per le zone 2×), si **stringe** la geometria delle zone (riducendo la width o spostandole verso pareti). Lo smoke test è gating: niente map ships in production senza passare il cap audit.

---

## 3. RTP calculation — modello payout v2

### 3.1 Variabili e notazione

- N = 30 (marble totali)
- a = 9× (1°), b = 4.5× (2°), c = 3× (3°)
- n₁ = numero marble con pickup 1× (no pickup)
- n₂ = numero marble con pickup 2× (max 4 per brief)
- n₃ = numero marble con pickup 3× (max 1)
- Vincolo: n₁ + n₂ + n₃ = 30

Probabilità marginali (uniformi):
- P(rank=1°) = P(rank=2°) = P(rank=3°) = 1/30
- P(rank=4°-30°) = 27/30
- P(pickup=p) = nₚ / 30

### 3.2 EV per marble (condizionato sul suo pickup)

Sia `p ∈ {1, 2, 3}` il pickup tier del marble. EV[payoff | pickup=p]:

$$
\text{EV}[p] = \frac{1}{30} (a \cdot p + b \cdot p + c \cdot p) + \frac{27}{30} \cdot (p \text{ if } p > 1 \text{ else } 0)
$$

Con a=9, b=4.5, c=3 (sum 16.5):

| p | EV[p] (calcolo) | EV[p] |
|---|---|---|
| 1 (no pickup) | (9 + 4.5 + 3) / 30 + 0 = 16.5/30 | **0.55** |
| 2 (Tier 1) | (18 + 9 + 6) / 30 + (27/30) × 2 = 33/30 + 54/30 | **2.90** |
| 3 (Tier 2, no jackpot) | (27 + 13.5 + 9) / 30 + (27/30) × 3 = 49.5/30 + 81/30 | **4.35** |
| 3 (Tier 2, **with jackpot B2**) | (100 + 13.5 + 9) / 30 + (27/30) × 3 = 122.5/30 + 81/30 | **6.78** |

**IMPORTANTE — jackpot B2 modifica EV[3×]:** quando il marble vincitore (1°) ha un pickup Tier 2, il jackpot rule B2 sostituisce il payoff podium normale (9 × 3 = 27×) con il jackpot fisso 100×. Quindi EV[3× pickup] è 6.78, non 4.35, quando il jackpot è in vigore.

Useremo EV[3×] = **6.78** per tutto il dimensioning RTP qui di seguito.

### 3.3 RTP totale

Total expected payoff per unit stake (su un marble random):

$$
\text{RTP} = \frac{1}{30} \left( n_1 \cdot 0.55 + n_2 \cdot 2.90 + n_3 \cdot 4.35 \right) + \text{jackpot\_contrib}
$$

### 3.4 Tabella scenari (con jackpot B2 incluso, EV[3×]=6.78)

| Scenario | n₁ | n₂ | n₃ | RTP totale | Note |
|---|---|---|---|---|---|
| **A** No pickup | 30 | 0 | 0 | 55.00% | Solo podium (sotto soglia operatore) |
| **B** Solo Tier 1 max | 26 | 4 | 0 | **86.33%** | n₂=4 user spec, no Tier 2 |
| **C** Tier 1 max + Tier 2 always | 25 | 4 | 1 | **108.6%** | troppo alto, casino in perdita |
| **D** Tier 1 max + Tier 2 prob **41.7%** | 25.6 (avg) | 4 | 0.417 (avg) | **95.0%** | sweet spot ✓ |
| **E** Operator high-house-edge | 26 | 4 | 0.27 (avg) | 92.0% | RTP=0.92 → p=0.273 |
| **F** Operator premium | 25 | 4 | 0.61 (avg) | 99.0% | RTP=0.99 → p=0.610 |

**Raccomandazione tecnica**: scenario **D** — n₂ sempre 4, n₃ presente con probabilità **41.7%** (deterministica dal round seed → replay-stable).

**Algebra inversa** per RTP target arbitrario:

$$
\text{RTP} = \frac{(26 - p) \cdot 0.55 + 4 \cdot 2.90 + p \cdot 6.78}{30} = \frac{25.90 + 6.23p}{30}
$$

$$
p = \frac{\text{RTP} \cdot 30 - 25.90}{6.23}
$$

Implementato in `Tier2ProbForRTP()` server-side. Operatore configura `RGSD_RTP_BPS` (es. 9500 = 95%), il server scala `p` di conseguenza.

### 3.5 Jackpot Tier 3 (rule B2)

**Trigger del jackpot 100×** (rule B2, semplificata rispetto al brief originale):

> "Marble vince 1° posto **AND** ha collezionato pickup Tier 2 (3×)"

Decisione utente (2026-05-02): rule B2 è preferita a B1 (che avrebbe richiesto anche un evento map-specific) perché B2 dà al jackpot una frequenza "session-level" (~1 ogni 1000-2000 round) invece che leggendaria (~1/9000). I giocatori vedono il jackpot abbastanza spesso da percepirlo come reale.

In pratica, jackpot è un **AND a 2 condizioni**:
1. Marble è 1° classificato (probabilità 1/30)
2. Marble ha pickup Tier 2 (probabilità 1/30 condizionata a n₃=1)

Probabilità composta sotto scenario D (n₃=1 con prob 0.417):
- P(marble X = 1° E ha pickup Tier 2) = (1/30) × 0.417 × (1/30) = 0.000463
- Su tutti i marble: P(qualche marble triggera jackpot) = 30 × 0.000463 = 0.0139 ≈ **1 ogni 72 round**

(In una sessione tipica di 30-60 round/ora, ci si aspetta 0.5-1 jackpot trigger. Frequenza "operator-friendly".)

Se attivato, payoff finale = **100×** (sostituisce il podium × pickup = 9 × 3 = 27× che il marble avrebbe ricevuto).

Il bonus jackpot (= 100 - 27 = 73 per evento) è **già conteggiato** in EV[3×]=6.78. Quindi non c'è un "+1.1%" separato — è dentro il modello.

### 3.6 RTP target finale (con scenario D)

| Componente | Contributo |
|---|---|
| Podium senza pickup (n₁=25.6) | 25.6/30 × 0.55 = 0.469 |
| Pickup Tier 1 (n₂=4) | 4/30 × 2.90 = 0.387 |
| Pickup Tier 2 + jackpot (n₃ avg = 0.417) | 0.417/30 × 6.78 = 0.094 |
| **RTP totale** | **0.950 (95.0%)** |

**Tunabile via `RGSD_RTP_BPS` env var**: il server scala `Tier2ActivationProbability` via `Tier2ProbForRTP(rtp)` per rispettare il target esatto richiesto dall'operatore (92-96%).

Esempi:
- `RGSD_RTP_BPS=9200` (92%) → p=0.273 → ~27% dei round hanno Tier 2 attivo
- `RGSD_RTP_BPS=9500` (95%) → p=0.417 → canonical
- `RGSD_RTP_BPS=9700` (97%) → p=0.498 → ~50% dei round hanno Tier 2 attivo
- `RGSD_RTP_BPS=9900` (99%) → p=0.610 → 61% dei round, casino margine basso

---

## 4. Algoritmo cross-map (per consistency)

Ogni nuova mappa che entri nel pool deve passare un **audit di payout consistency** prima di andare in production. Algoritmo:

### 4.1 Audit pipeline

```
INPUT: Track class (es. ForestRunTrack)
PROCEDURE:

1. SMOKE: 1000 round con seed random (no fairness compromise — uso seeds dummy
   solo per audit pre-deploy). Ogni round produce un replay.

2. PARSE: per ogni replay, estrai:
   - winner_marble_index (1°)
   - 2°, 3° classificati
   - Per ogni marble: pickup_zones_traversed (list of zone IDs)

3. AGGREGATE: calcola statistiche su 1000 round:
   a. Distribuzione 1°: ogni marble appare 1/30 ± delta. Reject se delta > 5%.
   b. Distribuzione pickup: media n₂ = 4 ± 1 marble. Reject se fuori range.
   c. Distribuzione pickup: media n₃ = (target) ± 0.2. Reject se fuori range.
   d. Jackpot trigger frequency: ≤ 1/1000 round. Reject se più frequente.

4. RTP CHECK: simula 100k round, calcola payoff aggregato sotto bet uniforme
   (1 unit per round su marble random). RTP atteso entro target ± 0.5%.

5. MAP-SPECIFIC OVERRIDES: per mappe con pickup geometry diversa (Roulette
   finish con multiple slot multipliers, Plinko finish con bins multipliers),
   il modello generico viene esteso con la lookup table specifica della mappa.
   Documentato in §5.

OUTPUT: PASS/FAIL + report. Solo PASS → mappa entra in SELECTABLE.
```

### 4.2 Implementazione del trigger (server)

```go
// server/rgs/multiplier.go
type RoundOutcome struct {
    PodiumWinners  [3]int            // marble_index del 1°, 2°, 3°
    PickupCollected map[int]float64  // marble_index → max pickup multiplier
    JackpotTriggered bool
    JackpotMarbleIdx int             // -1 se non triggered
}

func ComputeBetPayoff(bet Bet, outcome RoundOutcome) (payoff float64) {
    if outcome.JackpotTriggered && outcome.JackpotMarbleIdx == bet.MarbleIdx {
        return bet.Stake * 100.0
    }
    var basePayoff float64 = 0.0
    for rank, idx := range outcome.PodiumWinners {
        if idx == bet.MarbleIdx {
            switch rank {
            case 0: basePayoff = 9.0
            case 1: basePayoff = 4.5
            case 2: basePayoff = 3.0
            }
            break
        }
    }
    pickup, hasPickup := outcome.PickupCollected[bet.MarbleIdx]
    if !hasPickup {
        pickup = 1.0
    }
    if basePayoff > 0 {
        return bet.Stake * basePayoff * pickup
    }
    if hasPickup && pickup > 1.0 {
        return bet.Stake * pickup
    }
    return 0.0
}
```

### 4.3 Replay format extension v4

Nuovi campi nel `manifest.json` (additivi, retrocompatibili):

```json
{
  "protocol_version": 4,
  "marble_count": 30,
  "podium_payouts": [9.0, 4.5, 3.0],
  "pickup_per_marble": [1.0, 1.0, 2.0, 1.0, 3.0, 1.0, ...],
  "jackpot_triggered": false,
  "jackpot_marble_index": -1,
  // ... existing v3 fields below ...
}
```

Replay v3 vecchi (track 0-6) rimangono decode-able: `marble_count` defaulta a 20, `pickup_per_marble` defaulta a array di 1.0, `jackpot_triggered` a false.

---

## 5. Per-map payout structure

Ogni mappa eredita il **modello base** (§3) MA può specializzare la **geometria di payout finish** in modo distintivo. Lista delle implementazioni proposte per le 6 mappe next-gen:

### 5.1 Stadium Sprint
- **Tier 1** (2×): 4 zone laterali sulle banked turns dove i marble veloci ride high
- **Tier 2** (3×): 1 zona sulla chicane apex
- **Tier 3** jackpot: marble vince 1° AND attraversa la zona 3× AND è il PRIMO marble a entrare nel finish straight
- Geometria: tutte le zone Tier 1 sono linee orizzontali sulle pareti banked, Tier 2 è cinta nera sul punto più stretto della chicane

### 5.2 Spiral Skies
- **Tier 1** (2×): 4 zone sulla parete esterna della spirale, 1 per giro
- **Tier 2** (3×): 1 zona "tornado eye" al centro della spirale (raro perché marble centrifugate)
- **Tier 3** jackpot: marble vince 1° AND attraversa il "tornado eye" (probabilità geometrica < 1%)

### 5.3 Volcano Chaos
- **Tier 1** (2×): 4 "lava bombs" — zone proximali ai geyser, marble che sopravvive al geyser pickup 2×
- **Tier 2** (3×): 1 "magma core" — zona centrale Arena 2 dove pochi marble passano
- **Tier 3** jackpot: marble vince 1° AND attraversa il "magma core" AND uno dei pendoli swept

### 5.4 Forest Maze
- **Tier 1** (2×): 4 zone, una per path (3 path + 1 alla junction 2)
- **Tier 2** (3×): 1 zona nella "secret grove" — un percorso D nascosto che si attiva solo se un marble passa entro 2s su path B (rare)
- **Tier 3** jackpot: marble vince 1° AND ha attraversato la "secret grove"

### 5.5 Ice Slide
- **Tier 1** (2×): 4 "speed strips" — zone su parti banked dove i marble fast carry hanno pickup
- **Tier 2** (3×): 1 "luge medal" — zona alla seconda banking, lato esterno, raro perché marble devono ride high
- **Tier 3** jackpot: marble vince 1° AND attraversa "luge medal" AND record-time (top 10% di velocità)

### 5.6 Cavern Drop
- **Tier 1** (2×): 4 zone nei choke points (1 per choke)
- **Tier 2** (3×): 1 zona nel final chamber su un path zigzag stretto
- **Tier 3** jackpot: marble vince 1° AND attraversa la zona Tier 2 AND è l'unico marble a passare il Choke 3 in <X secondi

### 5.7 Variazioni "casino-game finish" (mappe legacy alternativa, opzionale)

Per integrazione con casino theming:

- **Roulette finish**: invece dei finish 20-lane gate, marble cadono in un wheel rotante con 37 numeri. Multiplier per slot:
  - 35 numeri ordinari: 1× (no pickup)
  - 1 slot "ROSSO 7" rare: 5×
  - 1 slot "VERDE 0" jackpot: 100× (jackpot diretto)
  - Combinato con podium: il VERDE 0 prevale se attivato
- **Plinko finish**: marble cadono in 13 bin con multiplier table standard:
  - Edge bins: [50×, 10×, 3×, 2×, 1.5×, 1×, **0.5×**, 1×, 1.5×, 2×, 3×, 10×, 50×]
  - Center bins più frequenti, payoff basso (anche < 1× = parziale loss); edge bin rari, payoff alto
- **Darts finish**: marble si "attaccano" al target board come freccette. Target zones con multiplier:
  - Bullseye centrale: 50×
  - Inner ring: 10×
  - Outer ring: 3×
  - Off-board (miss): 0×

Queste mappe casino-themed avrebbero il loro proprio sistema di payout (lookup table) che SOSTITUISCE il modello podium-based standard. Documentato come `MapPayoutModel` per-mappa nel server.

---

## 6. Decisioni di design rimaste (per il user/owner)

Il modello è coerente, ma 3 decisioni richiedono input umano prima di production:

### 6.1 Scenario di tuning RTP

| Opzione | RTP target | Pro | Contro |
|---|---|---|---|
| **A** Sempre n₃=1 | ~99% | Maggior valore percepito player; più vincite frequenti | RTP troppo alto, casino in perdita o rieduca podium |
| **B** n₃=1 con prob 68.5% | ~95% | Sweet spot operatore | Asymmetria tra round (alcuni "hot", alcuni "cold") |
| **C** n₂ sempre 4, no n₃ | 86% | Predicibile e semplice | RTP basso, player non perceive value |
| **D** Reduce podium a 8/4/2.5 + n₃=1 always | 91% | Predicibile, n₃ sempre attivo | Podium meno spettacolare |

**Raccomandazione**: Opzione **B** per la sua flessibilità RTP-tunable. Il `RGSD_RTP_BPS` env var del server scala la probabilità n₃ dinamicamente.

### 6.2 Jackpot trigger frequency

Trigger D combinato (1° + Tier 2 + map-specific event) dà ~1/9000 round.
Operatori spesso vogliono jackpot "visibile" più frequente:
- **B1** Mantieni rule rigida → ~1/9000 (rare, gestione promo difficile)
- **B2** Allenta rule (1° + Tier 2 only) → ~1/900 (più frequente, RTP +0.1%)
- **B3** Indipendente (random 1/1000 da seed) → predictable, no map-specific

**Raccomandazione**: B2 — abbassa la frequenza ma rende il jackpot un "evento di sessione" gestibile.

### 6.3 Pickup vs no-podium edge case

Il brief dice: "se uno prende un 2x a caso, vince comunque. non deve arrivare sul podio". Questo è già nel modello.

Edge case: **marble vince podium AND non ha pickup** — paga al base × 1, ovvero base. Niente di strano.

Altro edge case: **2 player bettano sullo stesso marble** che vince 1° + pickup 2× — entrambi ricevono 18× sulla loro stake individuale. Niente conflitto, perché è marble-bet non slot-bet.

---

## 7. RTP regression test (per CI/audit)

```bash
# scripts/rtp_smoke_v2.sh — esegue 1000 round, calcola RTP empirico
# e confronta con il modello teorico §3.6.

#!/usr/bin/env bash
ROUNDS=1000
TARGET_RTP=0.95
TOLERANCE=0.005

# Simula ROUNDS round con tutti i seed da 0 a ROUNDS-1.
# Per ogni round: bet 1 unit su marble_index = round_id mod 30.
# Conta payoff aggregato.

empirical_rtp=$(go run ./scripts/rtp_simulate.go --rounds $ROUNDS)

if [[ $(awk "BEGIN { print ($empirical_rtp - $TARGET_RTP > $TOLERANCE) || ($TARGET_RTP - $empirical_rtp > $TOLERANCE) }") -eq 1 ]]; then
    echo "FAIL: RTP empirico $empirical_rtp deviates >$TOLERANCE from $TARGET_RTP"
    exit 1
fi
echo "PASS: RTP empirico $empirical_rtp (target $TARGET_RTP ±$TOLERANCE)"
```

In CI ([.github/workflows/ci.yaml](../.github/workflows/ci.yaml)) gating: questo test deve passare prima di un release.

---

## 8. Storico delle versioni del modello

| Versione | Data | Modello | RTP | Note |
|---|---|---|---|---|
| v1 | 2026-04-29 | 20 marble, 1 vince, 19× single multiplier | 95% | M9 RGS scaffolding |
| v2 | 2026-05-02 | 30 marble, podium 9/4.5/3, pickup 2×/3× tiered, jackpot 100× | ~95% (tunable) | Brief utente — questo documento |

---

## Note di compliance

- **Determinismo**: tutto il modello è deterministico dal `server_seed` per round. Le pickup zones sono geometriche (deterministic-by-physics). Il jackpot trigger è derivato dal seed via `_hash_with_tag("jackpot")`. Nessun RNG runtime fuori dal fairness chain.
- **Replay-stability**: il modello v2 richiede replay format v4 (vedi §4.3). Replay v3 (track 0-6) restano decodificabili come marble_count=20 + pickup uniforme 1×.
- **GLI-19 compliance hooks**: ogni componente del modello è auditabile via il replay store + lo smoke harness §4.1. La chi-square dell'analyzer in [scripts/analyze_replays.py](../scripts/analyze_replays.py) verifica empiricamente che la distribuzione 1°-30° sia uniforme entro tolleranza.
- **Player-side fairness**: il giocatore può verificare il payoff calcolato sul replay revealed: stesso input → stesso output → posizione marble → applicare modello §3 → ottenere payoff atteso. Il replay viewer della Web build mostra il calcolo step-by-step (TBD M16).
