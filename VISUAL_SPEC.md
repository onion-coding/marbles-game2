# Specifiche grafiche complete — marbles-game2

Documento autoportante con tutte le caratteristiche visive, geometriche e di design del progetto. Da passare a un'IA esterna per analisi e proposte di miglioramento grafico/UI/UX, senza richiedere accesso al codice.

Ultimo update: 2026-05-02 (post-M11 track redesign + CLI alias fix).

> ⚠️ **Onestà critica**: dopo M11 le 6 tracce condividono tutte la stessa geometria drop-cascade (V-funnel → 3 ramp → peg forest → 20-lane gate). Cambia solo la palette + lighting + sky + minor variazioni dei pegs. Questo è un debito tecnico riconosciuto: il progetto ha bisogno che le 6 mappe siano **geometricamente uniche** (logs rotanti per Forest, lava geyser per Volcano, banked curves per Ice, stalattiti+stalagmiti per Cavern, jump-gaps per Sky, banked finish straight per Stadium). Quando proponi modifiche, considera che oggi sono 6 cloni colorati, non 6 tracciati distinti.

## Nomi --track accettati (CLI)

| Nome | Alias casino tecnico | track_id | Tema visuale |
|---|---|---|---|
| `forest` | `roulette` | 1 | bosco verde/marrone |
| `volcano` | `craps` | 2 | vulcano rosso/lava |
| `ice` | `poker` | 3 | ghiaccio cyan/cristalli |
| `cavern` | `slots` | 4 | grotta viola/teal |
| `sky` | `plinko` | 5 | cielo dorato/cloud |
| `stadium` | _(none)_ | 6 | stadio crepuscolo |
| `ramp` | _(legacy)_ | 0 | NOT in random pool |

Senza flag = random pick tra i 6 temati. I nomi tematici e gli alias casino tecnici puntano alla stessa identica mappa.

---

## 1. Visione del prodotto

**Genere:** Marble race 3D fisica-based, prima-marble-al-traguardo vince.
**Riferimento estetico dichiarato:** *Marbles On Stream / Jelle's Marble Runs* — colorful, palco grande, fiabesco, broadcast-style sportivo.
**Target commerciale:** B2B casino aggregator (SoftSwiss / Spike / EveryMatrix), licenza Anjouan B2B, distribuzione via aggregator. Crypto-first.
**Round format:** 20 marble per round, race time 27-33s, betting 19× payout (95% RTP).

---

## 2. Architettura grafica (engine + pipeline)

| Aspetto | Valore |
|---|---|
| Engine | Godot 4.6.2-stable |
| Physics | JoltPhysics3D (default Godot 4.4+) |
| Renderer | **Forward+** (anche per Web export) |
| Physics tick | **60 Hz** fisso |
| Wire tick rate | 60 Hz (replay v3) |
| Web bundle (compresso) | ~6.35 MB (era 38 MB → Brotli precompresso) |
| Light shader | `game/visuals/marble_glass.gdshader` (PBR + Voronoi swirl + fresnel rim) |
| Sky shader | `game/visuals/sky_clouds.gdshader` (gradient zenith→horizon + FBM clouds) |

### Post-processing pipeline (environment_builder.gd)

| Effetto | Parametro | Valore |
|---|---|---|
| **Tone mapping** | mode | ACES Filmic |
|  | exposure | 1.0 (overridable per-track) |
|  | white | 6.0 |
| **Bloom (Glow)** | enabled | true |
|  | intensity | 0.6 |
|  | strength | 1.0 |
|  | bloom (input) | 0.10 |
|  | blend mode | Additive |
|  | hdr_threshold | 1.0 |
|  | hdr_scale | 2.0 |
| **SSAO** | enabled | true |
|  | radius | 0.8 m |
|  | intensity | 1.4 |
|  | power | 1.5 |
|  | detail | 0.5 |
| **Fog** | enabled | true |
|  | light_color | Color(0.78, 0.86, 0.94) (default; per-track override) |
|  | light_energy | 0.8 |
|  | density | 0.0015 (default; per-track override) |
|  | sky_affect | 0.0 (fog non tinge sky) |
| **Color adjustment** | brightness | 1.0 |
|  | contrast | 1.05 |
|  | saturation | **1.10** |
| **Sun (DirectionalLight3D)** | rotation | (-55°, -38°, 0°) |
|  | color | Color(1.0, 0.95, 0.85) (default; per-track override) |
|  | energy | 1.2 |
|  | shadows | enabled, blur 1.5 |
|  | shadow mode | PSSM 4 splits, max distance 100 m |
| **Ambient** | source | Sky |
|  | energy | 1.0 |

### Sky shader (sky_clouds.gdshader)

Gradient procedurale zenith → horizon, con clouds via FBM noise (5 ottave, persistenza 0.5).

| Uniform | Default | Range |
|---|---|---|
| `zenith_color` | (0.20, 0.45, 0.85) — blu | source_color |
| `horizon_color` | (0.78, 0.88, 0.96) — bianco-blu | source_color |
| `ground_color` | (0.45, 0.48, 0.46) — grigio | source_color |
| `cloud_color` | (1.0, 1.0, 1.0) — bianco | source_color |
| `cloud_shadow_color` | (0.55, 0.62, 0.72) — grigio-blu | source_color |
| `cloud_coverage` | 0.55 | 0..1 |
| `cloud_softness` | 0.10 | 0.001..0.5 |
| `cloud_scale` | 0.6 | 0.05..8.0 |

I per-track environment_overrides sovrascrivono `zenith_color`, `horizon_color`, `ground_color`, fog, sun.

---

## 3. Le 6 tracce — geometria condivisa

**Filosofia di design:** drop-cascade verticale. Marble cadono attraverso 6 floor stacked. Stesso scheletro per tutte le tracce, identità visiva data da palette + lighting + sky.

### Dimensioni globali (uguali per tutti)

| Asse | Valore | Note |
|---|---|---|
| Field width (X) | **40 m** | larghezza del corridoio |
| Field depth (Z) | **5 m** | profondità (camera-side) |
| Track height (Y) | **~46 m** | da y=-6 (catchment) a y=40 (spawn) |
| Wall thickness | 0.5 m | bordi laterali |
| Floor thickness | 0.5 m | piani delle floor |

### Layout verticale (Y) — uguale per tutti

```
y=42   spawn safety margin
y=40   ←── 24 spawn slots (8 cols × 3 rows)
       ↓
y=38   ←── F1: V-funnel (due slab convergenti, gap centrale 4 m)
       ↓ drop 6 m
y=32   ←── F2: ramp tilt 8° → gap 4 m su +X
       ↓ drop 6 m
y=26   ←── F3: ramp tilt 8° → gap 4 m su -X
       ↓ drop 6 m
y=20   ←── F4: ramp tilt 8° → gap 4 m su +X
       ↓ drop 6 m
y=14   ←── F5 top: peg forest (hex grid, copre tutta larghezza)
       ↓
y=4    ←── F5 bottom
       ↓ drop 4 m
y=0    ←── F6: 20-lane finish gate (dividers 1.5 m alti, 0.15 m spessi)
       ↓
y=-6   ←── catchment floor (safety net)
```

### Spawn rail

24 slot disposti in griglia **8×3** centrata su (x=0, y=40, z=0):
- Spaziatura X: 1.6 m (8 colonne × 1.6 m = 12.8 m larghezza totale)
- Spaziatura Z: 1.0 m (3 righe × 1.0 m = 2 m profondità)
- Y stagger automatico per drop-order (no overlap a t=0)

### F1: V-funnel

Due slab simmetriche, ognuna `((40-4)/2 = 18 m)` larga × 0.5 m × 5 m, tilt **6°** verso il gap centrale (4 m al centro). Gravity rolling porta marble verso il gap.

### F2/F3/F4: Directed ramps

- Una slab da `(40-4 = 36 m)` larga × 0.5 m × 5 m
- Tilt **8°** sull'asse Z, lower edge sul lato del gap
- Gap di 4 m sul lato opposto al lower edge
- Curb (lip) di 0.3 × 0.4 × 5 m sul bordo del gap (dà un piccolo bounce uscendo)
- F2 gap su +X, F3 gap su -X, F4 gap su +X (alterna direzione, allunga il percorso)

### F5: Peg forest (varia per traccia)

Hex grid (rows even/odd offset di mezzo col-spacing) di cilindri orientati lungo Z (asse profondità).

| Track | rows | cols | peg_radius | col_spacing | densità |
|---|---|---|---|---|---|
| Stadium | 6 | 9 | 0.6 m | 4.5 m | media |
| Forest | 7 | 9 | 0.55 m | 4.5 m | media-alta |
| Volcano | 8 | 9 | 0.55 m | 4.5 m | alta (chaos) |
| Ice | 7 | 9 | 0.55 m | 4.5 m | media-alta |
| Cavern | 6 | 7 | **0.85 m** | 5.5 m | sparso (pegs grossi) |
| Sky | 8 | 11 | 0.5 m | 3.6 m | densissima (cloud cover) |

### F6: 20-lane finish gate

- Floor 40 m × 0.5 m × 5 m (copre tutto il field)
- 21 dividers verticali, ognuno 0.15 m × 1.5 m × 5 m
- Lane width: 40/20 = 2 m per corsia
- Finish line area3D: 42 × 5 × 6 m centrata 2.5 m sopra il gate floor (cattura marble in arrivo da sopra)

### Catchment floor

Safety floor a y=-6, copre il field. Cattura marble che bouncing escono dal gate.

### Outer frame (per ogni traccia)

- 2 pareti laterali ai bordi X (full height ~50 m)
- 1 parete posteriore -Z (con mesh visibile come backdrop)
- 1 parete frontale +Z (collision-only, camera vede attraverso)

---

## 4. Le 6 tracce — palette + lighting per tema

Ogni track legge `TrackPalette.theme_for(track_id)` che restituisce un dizionario con 5 colori (floor_a, floor_b, floor_c, floor_d, peg, gate, wall, accent) + dict env (sky_top, sky_horizon, ambient_energy, fog_color, fog_density, sun_color, sun_energy).

### Track 6 — STADIUM RUN (track_id 6, file stadium_track.gd)

**Concept:** Stadio sportivo pomeriggio dorato. Tema "telecronaca F1 in miniatura".

**Palette:**
| Element | Color RGB | Note |
|---|---|---|
| F1 floor | (0.85, 0.72, 0.20) | oro spazzolato |
| F2 floor | (0.75, 0.10, 0.10) | rosso velluto |
| F3 floor | (0.95, 0.95, 0.97) | bianco |
| F4 floor | (0.20, 0.45, 0.85) | blu |
| Pegs (F5) | (0.92, 0.96, 1.00) | cromo |
| Gate (F6) | (0.92, 0.78, 0.18) | oro lucido |
| Wall | (0.10, 0.10, 0.14) | near-black |
| Accent | (1.00, 0.05, 0.85) | magenta neon |

**Sky:** zenith (0.22, 0.40, 0.78) blu, horizon (0.92, 0.72, 0.45) tramonto dorato.
**Sun:** color (1.0, 0.85, 0.60) caldo, energy 1.6.
**Fog:** color (0.85, 0.72, 0.55), density 0.0010 (leggero).
**Ambient:** energy 0.95.

**Lighting setup (in _build_mood_lights):**
- Key: DirectionalLight3D color (1.0, 0.88, 0.65), energy 1.5, rot (-50°, -30°, 0°), shadows on
- Rim: OmniLight3D color (0.55, 0.80, 1.00), energy 1.4, range 50 m, position (0, F4_Y-5, -8) cool back
- Finish spot: OmniLight3D color (1.0, 0.85, 0.55), energy 2.0, range 12 m, sopra gate (0, F6_Y+4, 3)

### Track 1 — FOREST RUN (was Roulette, file roulette_track.gd)

**Concept:** Foresta solare, fiabesco, fogliame.

**Palette:**
| Element | Color | Note |
|---|---|---|
| F1 floor | (0.20, 0.50, 0.18) | moss green |
| F2 floor | (0.45, 0.30, 0.12) | bark brown |
| F3 floor | (0.30, 0.55, 0.22) | leaf green |
| F4 floor | (0.55, 0.42, 0.18) | warm wood |
| Pegs (F5) | (0.58, 0.40, 0.20) | tree-trunk wood |
| Gate (F6) | (0.85, 0.65, 0.18) | warm gold |
| Wall | (0.06, 0.10, 0.06) | forest floor dark |
| Accent | (1.00, 0.80, 0.30) | firefly yellow |

**Sky:** zenith (0.30, 0.55, 0.30) green-blue, horizon (0.78, 0.85, 0.55) yellow-green.
**Sun:** color (0.95, 0.95, 0.65), energy 1.4.
**Fog:** color (0.50, 0.65, 0.45), density 0.0018 (medio — atmosfera bosco).
**Ambient:** energy 0.85.

**Lighting:**
- Key: DirectionalLight3D color (1.0, 0.95, 0.70) warm, energy 1.3, rot (-50°, -30°, 0°)
- Fill: OmniLight3D (0.55, 0.85, 0.45) green-leaf, energy 1.0, range 40 m, position (0, F4_Y-2, -6)
- Gate spot: OmniLight3D (1.0, 0.85, 0.45) gold, energy 1.8, range 12, sopra gate

### Track 2 — VOLCANO RUN (was Craps, file craps_track.gd)

**Concept:** Vulcano drammatico, lava + basalto, contrasto forte.

**Palette:**
| Element | Color | Note |
|---|---|---|
| F1 floor | (0.60, 0.10, 0.05) | lava red — emissive 0.55 |
| F2 floor | (0.20, 0.10, 0.08) | cooled basalt |
| F3 floor | (0.85, 0.30, 0.05) | molten orange |
| F4 floor | (0.30, 0.10, 0.05) | dark red rock |
| Pegs (F5) | (0.15, 0.10, 0.08) | obsidian — emissive 0.20 |
| Gate (F6) | (1.00, 0.45, 0.10) | bright lava — emissive 0.70 |
| Wall | (0.06, 0.04, 0.04) | volcanic black |
| Accent | (1.00, 0.60, 0.10) | ember glow |

Note: floor + peg + gate hanno emission attivata (energy moltiplicatore: F1=0.55, F2-F4=0.30, peg=0.20, gate=0.70, accent=0.85).

**Sky:** zenith (0.20, 0.05, 0.05) deep red night, horizon (0.85, 0.25, 0.08) lava glow.
**Sun:** color (1.00, 0.55, 0.20), energy 2.0.
**Fog:** color (0.40, 0.15, 0.08), density 0.0030 (denso — atmosfera vulcanica).
**Ambient:** energy 0.50 (basso — drammatico).

**Lighting:**
- Key: dim warm (1.0, 0.55, 0.30), energy 1.0
- Lava glow OmniLight: (1.0, 0.40, 0.05), energy 2.5, range 30 m, sopra gate
- Top ember OmniLight: (1.0, 0.65, 0.20), energy 1.6, range 20 m, sopra spawn

### Track 3 — ICE RUN (was Poker, file poker_track.gd)

**Concept:** Ghiaccio, cristalli, freddo, slippery.

**Palette:**
| Element | Color | Note |
|---|---|---|
| F1 floor | (0.80, 0.90, 1.00) | ice white |
| F2 floor | (0.55, 0.78, 0.92) | glacier blue |
| F3 floor | (0.92, 0.95, 1.00) | snow white |
| F4 floor | (0.30, 0.55, 0.78) | deep ice |
| Pegs (F5) | (0.75, 0.92, 1.00) | crystal — emissive 0.25 |
| Gate (F6) | (0.45, 0.85, 1.00) | ice neon — emissive 0.55 |
| Wall | (0.08, 0.12, 0.18) | midnight ice |
| Accent | (0.30, 0.85, 1.00) | cyan accent — emissive 0.75 |

**Sky:** zenith (0.20, 0.32, 0.55) deep blue, horizon (0.65, 0.80, 0.95) pale ice.
**Sun:** color (0.85, 0.92, 1.00), energy 1.3.
**Fog:** color (0.70, 0.85, 0.95), density 0.0014.
**Ambient:** energy 1.10 (alto — ghiaccio riflette molto).

**Lighting:**
- Key: cool blue-white (0.85, 0.92, 1.00), energy 1.6
- Rim: OmniLight (0.40, 0.85, 1.00), energy 1.4, range 50 m, position back (0, F4_Y, -8)
- Gate spot: (0.60, 0.90, 1.00), energy 1.8

### Track 4 — CAVERN RUN (was Slots, file slots_track.gd)

**Concept:** Caverna sotterranea con cristalli bioluminescenti. Buio drammatico.

**Palette:**
| Element | Color | Note |
|---|---|---|
| F1 floor | (0.18, 0.10, 0.30) | deep purple — emissive 0.25 |
| F2 floor | (0.08, 0.20, 0.30) | teal cave |
| F3 floor | (0.25, 0.08, 0.40) | crystal purple |
| F4 floor | (0.10, 0.15, 0.20) | dark stone |
| Pegs (F5) | (0.55, 0.30, 0.85) | crystal stalactites — emissive 0.55 |
| Gate (F6) | (0.85, 0.30, 0.95) | crystal magenta — emissive 0.65 |
| Wall | (0.04, 0.04, 0.08) | cavern black |
| Accent | (0.50, 0.95, 0.90) | bioluminescent teal — emissive 0.85 |

**Sky:** zenith (0.05, 0.04, 0.10) almost-black, horizon (0.20, 0.10, 0.30) purple.
**Sun:** color (0.65, 0.55, 1.00) purple, energy 1.0.
**Fog:** color (0.20, 0.12, 0.30), density **0.0040** (molto denso — atmosfera grotta).
**Ambient:** energy 0.55 (basso).

**Lighting:**
- Key: dim purple (0.65, 0.55, 1.00), energy 0.8
- Bio fill: cyan-teal (0.40, 0.85, 0.85), energy 1.2, range 30 m
- Crystal spot: magenta (0.95, 0.40, 1.00), energy 2.4, range 14 m, sopra gate

**Variazione geometrica:** F5 ha pegs **GROSSI** (radius 0.85 m vs 0.5-0.6 negli altri) e **SPARSI** (cols=7 vs 9, col_spacing 5.5 vs 4.5). Sembra una grotta con stalactiti grossi.

### Track 5 — SKY RUN (was Plinko, file plinko_track.gd)

**Concept:** Cielo dorato a giorno, cloud-pillars, brightest theme.

**Palette:**
| Element | Color | Note |
|---|---|---|
| F1 floor | (0.92, 0.92, 0.98) | cloud white |
| F2 floor | (0.65, 0.85, 1.00) | sky blue |
| F3 floor | (0.95, 0.85, 0.55) | sunny gold |
| F4 floor | (0.55, 0.78, 0.95) | cyan |
| Pegs (F5) | (0.95, 0.95, 1.00) | cloud pillar — emissive 0.20 |
| Gate (F6) | (1.00, 0.85, 0.30) | sun gold — emissive 0.65 |
| Wall | (0.12, 0.18, 0.28) | high-altitude shadow |
| Accent | (1.00, 0.95, 0.55) | sun gold — emissive 0.85 (curb) |

**Sky:** zenith (0.30, 0.55, 0.95) bright blue, horizon (0.95, 0.92, 0.78) dorato giorno.
**Sun:** color (1.00, 0.95, 0.70), energy 1.7 (più alto del default).
**Fog:** color (0.85, 0.90, 1.00), density 0.0008 (molto leggero — cielo sereno).
**Ambient:** energy 1.20 (più alto — daylight scene).

**Lighting:**
- Key: warm bright (1.00, 0.95, 0.70), energy 1.7, rot (-55°, -25°, 0°)
- Fill: sky-tinted (0.85, 0.92, 1.00), energy 1.2, range 50 m
- Sun gold spot: (1.00, 0.85, 0.30), energy 2.2

**Variazione geometrica:** F5 ha pegs **PICCOLI E DENSI** (radius 0.5 m, cols=11, rows=8) — densissima cloud cover.

### Tabella race-time misurati (smoke headless 2026-05-02)

| Track | Winner | Tick | Tempo |
|---|---|---|---|
| Stadium | Marble_16 | 1868 | 31.1 s |
| Forest (Roulette) | Marble_13 | 1920 | 32.0 s |
| Volcano (Craps) | Marble_14 | 1865 | 31.1 s |
| Ice (Poker) | Marble_12 | 1955 | 32.6 s |
| Cavern (Slots) | Marble_13 | 1638 | 27.3 s |
| Sky (Plinko) | Marble_07 | 1895 | 31.6 s |

Tutte con gravità reale 9.8 m/s² (no SLOW_GRAVITY hack), real fairness deterministico (winner cambia con seed).

### Physics tuning (uguale per tutti dopo M11)

| Material | friction | bounce |
|---|---|---|
| Floor (slabs/ramps) | 0.40 | 0.20 |
| Pegs | 0.25 | 0.55 |
| Walls | 0.30 | 0.30 |
| Gate (finish floor) | 0.55 | 0.10 |

Il marble (in physics/materials.gd) ha `marble.physics_material_override` con valori dedicati (vedi sezione Marble sotto).

### Camera pose (default per tutte le tracce)

```
position: (8, mid_y + 6, 55)    # mid_y ≈ 17, quindi camera a (8, 23, 55)
target:   (0, mid_y - 4, 0)     # ≈ (0, 13, 0)
fov:      65°
```

Camera diagonale stadium-overview che inquadra tutto il field da fronte/lato.

---

## 5. Marble — fisica + shader

### Caratteristiche fisiche

| Param | Valore |
|---|---|
| Radius (raggio) | **0.3 m** (= 60 cm di diametro) |
| Mass | 1.0 kg |
| Continuous CD | true (continuous collision detection) |
| Numero per round | 20 marbles |
| Slot count | 24 slot disponibili (4 unused per random spawn) |

### Shader glass (game/visuals/marble_glass.gdshader)

Shader PBR custom che simula una marble di vetro con swirl interno. Sostituisce StandardMaterial3D plastica.

**Render mode:** blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx.

**Uniforms:**
| Uniform | Default | Range | Note |
|---|---|---|---|
| `marble_color` | (0.8, 0.6, 0.2, 1.0) | source_color | dal fairness chain (deterministica) |
| `swirl_seed` | 0.0 | 0..1 | drop_order (0-19) modulato → pattern unico per marble |
| `swirl_scale` | 6.0 | 1..20 | scala del Voronoi noise interno |
| `swirl_intensity` | 0.6 | 0..1 | quanto si vede il swirl |
| `rim_strength` | 1.5 | 0..4 | intensità del fresnel rim |
| `rim_power` | 2.5 | 0.5..8 | curva del fresnel |
| `emission_strength` | 0.8 | 0..4 | bagliore base (boostato a 2.0+ per leader) |
| `core_lightness` | 1.4 | 0..2 | quanto si schiarisce il core |

**Output:** ALBEDO con swirl Voronoi, METALLIC=0.20, ROUGHNESS=0.18, SPECULAR=0.6, EMISSION = base*emission_strength + rim_col*0.5.

### Trail (game/sim/marble_spawner.gd attach_trail)

GPUParticles3D con:
- 32 particelle, lifetime 0.55s
- Local_coords=false (particelle in world space → trail si "ferma" mentre marble avanza)
- Sphere mesh (radius 0.55× marble radius), albedo + emission del marble color
- Curve di scale: 1.0 → 0.0 nella vita
- Gradient alpha: 0.85 → 0 nella vita

### Number label (game/sim/marble_spawner.gd attach_number_label)

Label3D 3D billboard sopra il marble:
- Testo: drop_order (0-19)
- Pixel size 0.002, font size 14
- Outline 4 px, no_depth_test (sempre visibile)
- Position: (0, RADIUS + 0.35, 0)

### Marble color derivazione (fairness chain)

Color è **deterministico dal seed**:
```
hash = SHA256(server_seed || round_id_BE || client_seed || marble_index_BE)
R = hash[4]/255, G = hash[5]/255, B = hash[6]/255, A = 1.0
```
Quindi i 20 marble di un round hanno colori che dipendono unicamente da seed + index. Sfortunatamente questo significa che a volte si possono avere 2 marble con colori molto simili (no separazione perceptual).

---

## 6. HUD (game/ui/hud.gd) — stato attuale

CanvasLayer 2D overlay sopra il viewport 3D. **Stato: layout M9 default Godot Controls — questa è la parte più "non broadcast" del progetto, deve essere ridisegnata in stile ESPN/F1.**

### Componenti

**Top-left — Race info panel**
- Phase label ("WAITING" / "RACING" / "FINISHED")
- Track name label (es. "RouletteTrack")

**Top-right — Balance label**
- Mostra "$1250.00" o equivalente in modalità non-RGS (mock balance)
- In RGS mode polla `/v1/wallets/{player_id}/balance`

**Right sidebar — Standings**
- Lista verticale di marble rows
- Ogni row: numero rank (1-20), color swatch, marble name, badge "leader" sul primo
- Cliccabile → emette `marble_selected(index)` per follow-cam
- Si aggiorna ogni frame in update_standings()
- Layout: VBoxContainer

**Bottom-center — Race timer**
- Format "MM:SS" (es. "00:23")
- Driven da update_tick(tick, tick_rate)

**Bottom-center — Bet placement panel** (visibile solo in RGS mode + WAITING phase)
- Header "BET PLACEMENT" (giallo)
- Marble selector: OptionButton dropdown con tutte le marble
- Bet amount: preset chips 1/5/10/50/100, ±10 buttons, label live
- "PLACE BET" Button
- Bet countdown label "Race starts in: X.Xs" (verde, rosso quando <3s)
- Lista bet piazzati in basso

**Center — Winner modal** (visibile solo in FINISHED phase)
- Modal centrato, fade-in
- Winner name (color del marble)
- Prize/result label
- RGS payout line: "+10.00 (won 10.00 on 5.00 wagered)" verde, o "-5.00 (lost on 5.00 wagered)" rosso
- Next round countdown "Next round in X.Xs..." (RGS auto-restart mode)

**Toast** — temporary error/confirmation feedback (sotto il bet panel)

### Cosa NON ha l'HUD attuale (gap rispetto a "broadcast TV style")

- ❌ Font/typography custom (usa font Godot default)
- ❌ Animazioni di sorpasso nelle standings (le righe si swap-pano istantaneamente, no tween)
- ❌ Race timer in font sportivo grande (es. font monospaziato, 60-80 pt)
- ❌ Scoreboard ESPN-style (banner orizzontale top o bottom con leader top-3, gap times, etc.)
- ❌ Lap counter / progress bar
- ❌ Country flags / brand emblem per marble
- ❌ Slow-motion replay highlight per i sorpassi
- ❌ Podio finale 1°/2°/3° con confetti (c'è solo confetti spawn al winner)
- ❌ Bet slip stile sportbet (titolo evento, odds, stake, payout)
- ❌ Crowd reaction sfx / commentary text
- ❌ Operator branding hooks (logo placeholder, palette config esterno)
- ❌ Mobile/touch responsive layout (anchor preset semplice, non safe-area-aware)
- ❌ i18n / localizzazione (tutto hardcoded in inglese)

---

## 7. Camera

### FreeCamera (game/cameras/free_camera.gd)

Camera principale per modalità interactive + web playback.

**Controlli:**
| Input | Azione |
|---|---|
| Left-drag mouse | Orbita attorno al target |
| Right-drag mouse | Pan (sposta lateralmente) |
| Mouse wheel | Zoom |
| Shift+wheel | Zoom rapido |
| W/A/S/D | Sposta camera avanti/sx/dx/indietro |
| Q/E | Sposta camera giù/su |
| R | Reset alla pose iniziale |

**Zoom range:** 0.05 m – 1000 m (sub-meter close-up fino a stadium-overview).

**Bounds:** limitato dal `track.camera_bounds()` di ogni traccia (AABB).

**Follow mode:** può "agganciarsi" a un marble specifico (selezionato via HUD click). Emette `following_changed(idx)`.

### FixedCamera (game/cameras/fixed_camera.gd)

Per scene headless (sim, verify, playback automatico). Si basa su `track.camera_pose()` o sull'AABB di camera_bounds() per inquadrare automaticamente l'intero track.

### Cosa NON ha la camera (gap broadcast)

- ❌ Multiple cameras pre-impostate (stadium-wide / leader-follow / finish-line low-angle)
- ❌ Cuts cinematici automatici (cambia camera ogni N secondi o sui sorpassi)
- ❌ Slow-motion sull'ultimo metro (playback rate < 1.0 negli ultimi 60 frame)
- ❌ Replay highlights automatici (scene-cut + slow-mo sui momenti chiave)
- ❌ DOF (Depth of Field) per cinematografico

---

## 8. Audio (game/audio/) — solo scaffolding

**Stato:** game/audio/audio_controller.gd esiste, infrastruttura caricamento ambient + winner jingle pronta, **MA i file audio NON ESISTONO**:

```
res://audio/ambient_<track>.ogg   # mancante
res://audio/winner_jingle.ogg     # mancante
```

Quando il player cerca di caricare un asset mancante, l'audio_controller fallisce silenziosamente (silence fallback). Quindi il gioco corre **senza audio**.

### Cosa serve produrre/comprare

- 6 ambient loops (uno per traccia, ~30-60s in loop, themed)
- 2 SFX collisione (marble-on-peg, marble-on-floor)
- 1 winner jingle (3-5s, celebrativo)
- 1 bet placed SFX
- 1 race start countdown beep (3-2-1-go)
- 1 marble overtake whoosh

Licenza: CC0 / royalty-free per il prototipo. Per la produzione serve sound designer freelance (€1-3k stimato).

---

## 9. Web export

| Aspetto | Valore |
|---|---|
| Bundle size (gzipped) | ~6.35 MB (scendeva da 38 MB raw via Brotli precompresso) |
| Compatibility | Forward+ renderer in Web (potrebbe richiedere Mobile fallback per low-end) |
| Templates required | web_release.zip + web_nothreads_release.zip in %APPDATA%\Godot\export_templates\ |
| Routing | launcher.tscn legge URL params per aprire main / live / web mode |
| Scene main | res://main.tscn (interactive con HUD) |
| Scene live | res://live_main.tscn (live WebSocket playback) |
| Scene web | res://web_main.tscn (archive HTTP playback) |

### Cosa manca per web casino-ready

- ❌ PWA manifest (per install mobile)
- ❌ Service worker (offline fallback)
- ❌ Iframe-safe (postMessage bridge per parent operator)
- ❌ Mobile/touch responsive layout
- ❌ Operator-themable (parent passa logo/colori via URL/postMessage)
- ❌ Brotli su CDN (attualmente Brotli pre-compresso ma servito da replayd, non CDN)

---

## 10. Cosa manca per stile "Marbles On Stream / Jelle's Marble Runs"

L'utente ha indicato come reference visivo Marbles On Stream classic. Il gap principale rispetto a quello stile:

### Elementi "vivi" mancanti nei track

- **Tribune con spettatori** — primitive procedurali (capsule + box random colors disposte in array semicircolari ai bordi)
- **Cartelloni / banner pubblicitari** — boxes con texture procedural (ora niente texture, solo colori solidi)
- **Bandiere** — meshes simple che oscillano (vertex shader)
- **Particelle ambient** — foglie cadenti per Forest, neve per Ice, ember per Volcano, fog volumetric per Cavern, polline dorato per Sky
- **Inquadratura "stage"** — la camera sembra inquadrare un set vuoto da laboratorio. Manca il senso di un AMBIENTE intorno
- **Macchina da presa che si muove** — Jelle's Marble Runs ha camere multiple che fanno cuts; il nostro è una sola camera fissa-ish
- **Telecronaca audio** — overlay vocale "and Marble_07 is taking the lead!" — ma questo è audio, fuori scope grafica

### Scenografia di sfondo

I 6 sky shader sono procedurali (gradient + clouds), funzionano ma sono "vuoti". Marbles On Stream ha:
- Montagne in lontananza
- Edifici (stadio, città)
- Foreste
- Skybox texture HDRI vere
- Day/night cycle in alcuni episodi
- Pioggia / neve / nebbia drammatica

Tutto questo nel nostro è **assente** — solo il gradient procedurale del sky_clouds.gdshader.

### Marble personality

Jelle's Marble Runs ha personalità sui marble (nomi, team, fan): la TELEMETRIA emozionale è importante. Nostro:
- ✅ Numero (0-19)
- ✅ Colore deterministic da seed
- ❌ Nome custom (sono "Marble_07")
- ❌ Squadra / fazione (no team)
- ❌ Mascotte / avatar
- ❌ Replay history ("this marble has won 3 of last 10")

---

## 11. Fairness chain & determinismo (info per chi propone modifiche)

**IMPORTANTE per qualsiasi modifica grafica:** il sistema è server-authoritative deterministic. Replay v3 contiene:
- server_seed (32 byte) + hash SHA256
- 20 client_seeds (uno per marble, vuoti in MVP)
- 24 spawn_slots derivati
- Per ogni tick: posizione + rotazione di tutti i 20 marble
- Track ID (1 byte)
- Replay verificabile in qualsiasi momento via `verify_main.tscn`

**Cosa NON si può cambiare senza rompere replay vecchi:**
- track_id ↔ class mapping (1=Roulette, 2=Craps, ecc.)
- Geometria delle tracce (cambia il fisica → cambia il replay)
- Marble radius (0.3 m), mass (1 kg)
- Fairness chain (SHA256 input format, byte order)
- Tick rate (60 Hz)
- Replay format (v3 layout)

**Cosa SI può cambiare senza rompere niente:**
- Tutti i materiali (StandardMaterial3D, ShaderMaterial)
- Tutti i colori (palette, sky, fog)
- Lighting (intensity, color, position, count)
- Post-processing (bloom, SSAO, tonemap, fog)
- Camera pose default
- HUD layout completo
- Audio
- Skybox / shader sky
- Particelle / decorazioni props
- VFX (trail, confetti, bloom particles)

In sintesi: **estetica è libera, fisica è freezed.**

---

## 12. File-system reference (path key files)

```
game/
├── tracks/
│   ├── track.gd                    # base class (API: spawn_points, finish_area, camera_bounds, env_overrides)
│   ├── track_blocks.gd             # primitive geometry library (NEW M11)
│   ├── track_palette.gd            # 6 themes dictionary (NEW M11)
│   ├── track_registry.gd           # track_id ↔ class mapping
│   ├── stadium_track.gd            # NEW M11 (track_id 6)
│   ├── roulette_track.gd           # M11 rebuilt → Forest Run (id 1)
│   ├── craps_track.gd              # M11 rebuilt → Volcano Run (id 2)
│   ├── poker_track.gd              # M11 rebuilt → Ice Run (id 3)
│   ├── slots_track.gd              # M11 rebuilt → Cavern Run (id 4)
│   ├── plinko_track.gd             # M11 rebuilt → Sky Run (id 5)
│   └── ramp_track.gd               # legacy id 0 (out of SELECTABLE)
├── visuals/
│   ├── environment_builder.gd     # tonemap + bloom + SSAO + fog defaults
│   ├── sky_clouds.gdshader         # procedural sky
│   ├── marble_glass.gdshader       # NEW M11 marble PBR shader
│   └── winner_reveal.gd            # confetti spawn + winner glow boost
├── sim/
│   ├── marble_spawner.gd          # spawn marble + glass material + trail + label
│   ├── spawn_rail.gd               # 24 slot positions + Y stagger
│   └── finish_line.gd              # Area3D detection + race_finished signal
├── ui/
│   └── hud.gd                      # 861 LOC, M9 layout — DA RIDISEGNARE
├── cameras/
│   ├── free_camera.gd              # interactive
│   └── fixed_camera.gd             # headless / playback
├── audio/
│   └── audio_controller.gd        # scaffold; audio assets MANCANO
├── playback/
│   ├── playback_player.gd         # visual-only marble replay
│   └── live_stream_client.gd      # WebSocket binary frame decode
├── recorder/
│   ├── tick_recorder.gd
│   └── replay_writer.gd
├── fairness/
│   └── seed.gd                     # SHA256 derivation, slots, colors
└── main.gd                         # interactive scene entry-point
```

---

## 13. Cosa chiedere a un'IA esterna

Suggerimenti di domande per ottenere proposte concrete:

1. **Materiali** — "Vorrei che i marble di vetro avessero un effetto refraction più convincente. Suggerisci modifiche al marble_glass.gdshader senza rompere la performance Web."

2. **Lighting per-track** — "Per Volcano Run voglio un effetto 'lava che pulsa' aggiungendo emission animata sui floor. Come implemento un pulse subtle?"

3. **Sky drammatico** — "Il sky shader procedurale è troppo piatto. Suggerisci come aggiungere stelle (Cavern), aurora boreale (Ice), meteora (Stadium), nuvole volumetriche (Sky)."

4. **Decorazioni procedurali** — "Voglio popolare le tracce con tribune di spettatori procedurali (capsule + box random colors). Genera un TrackBlocks helper `build_audience_stand(parent, x, y, z, width, depth, count)`."

5. **Particelle ambient** — "Per ogni track voglio particelle ambient: foglie (Forest), neve (Ice), ember (Volcano), fog volumetric (Cavern), polline dorato (Sky), confetti pre-race (Stadium). Spec di GPUParticles3D per ognuna."

6. **HUD broadcast** — "Voglio sostituire l'HUD M9 con un layout broadcast TV stile F1: scoreboard top con leader top-3 + gap times, race timer big bottom-center, lap progress bar, animazioni overtake. Genera nuovi nodi UI per hud.gd."

7. **Camera cinematica** — "Voglio 3 camere (stadium-wide / leader-follow / finish-line low-angle) con cuts automatici ogni 5s o sui sorpassi. Genera CinematicCameraController che si attacca a una scena."

8. **Marble personality** — "Voglio dare ai 20 marble una personalità: nome generato deterministicamente da seed, team color, mascotte simbolo (3D billboard sopra). Senza rompere fairness."

9. **Mobile/touch UI** — "Adatta l'HUD per mobile portrait/landscape: bet panel come bottom-sheet, standings come collapsible drawer, race timer floating. Rispetta safe-area iOS."

10. **Operator branding** — "Fai un sistema theme runtime: parent operator passa via URL `?theme=https://operator.cdn/theme.json` con logo, palette, font, e l'HUD applica."

---

## 14. Constraint per le proposte

Quando chiedi modifiche, ricorda:

- **Engine = Godot 4.6.2** (no Unity, no Unreal). API GDScript 4 (typed), shader Godot v4 (`shader_type spatial/sky`, MODEL_MATRIX, EYEDIR, VIEW, NORMAL, ALBEDO, EMISSION).
- **Renderer Forward+** (no MobileRenderer per qualità default).
- **Web export deve girare** — niente shader troppo costosi (Voronoi 3D già pesante), niente compute shader, niente HDRI 4K. Test su Chrome stable.
- **Determinism** — niente Mathf.randf nei loop di build geometry. Solo `_hash_with_tag()` derivato dal seed se serve casualità deterministica.
- **No external assets** — tutto procedurale o file in repo. Se serve un asset (texture/audio/mesh), specificare URL CC0 o budget.
- **Compatibilità con replay v3** — qualsiasi modifica geometrica BREAKS i replay esistenti. Solo modifiche estetiche (materiali/lights/sky/post) sono safe.

---

Fine documento. Ricorda di passare anche `HANDOFF.md` se l'IA esterna deve capire lo stato git/commit del progetto.
