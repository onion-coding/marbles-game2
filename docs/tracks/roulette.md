# Track 1 — Roulette

Part of the M6 track library. See [m6-tracks.md](../m6-tracks.md) for the master plan.

## Concept (v3 — 2026-04-25)

A [Marbles on Stream](https://store.steampowered.com/app/1170970/Marbles_on_Stream/)–style **modular marble course threaded through a giant roulette casino set**. Each section is a standard MoS piece category (start-chute, downhill-turn, loop, split, moguls, funnel, narrower, jump-landing, downhill-turn, finish), themed as a real piece of roulette equipment. The course flows **continuously downward** from spawn to finish; every section curves, spins, or drops — no flat tilted planes.

The big roulette wheel sits in the **middle of the map as decoration**. Marbles travel around it (section 2) and past it but never ride on it. The wheel is a visible landmark, not a gameplay surface — that was v1/v2's mistake.

**Target race time:** ~50s, split across ten short sections. Variance comes from the **split + moguls** (which lane a marble picks and how it weaves through the chip-stack pegs); everything else is roughly uniform in traversal time.

## Global frame

- Vertical drop: **spawn at Y = +30 → finish at Y = 0**, total 30m descent.
- Horizontal footprint: roughly **35m (X) × 20m (Z)** — fits a fixed-camera pulled-back shot.
- Camera: frames the whole tower from slightly-above-horizon. Wheel décor is roughly centered.
- Marbles spawn inside the bingo tumbler (section 1); tumbler sits on a podium off to the −X side of the roulette wheel décor.

## Sections

### 1 — Start: Bingo tumbler (2-3s)

**MoS piece type:** Start chute (custom: rotating drum variant).

**Mechanic:** All 20 marbles spawn stationary inside a closed horizontal drum (radius 1.5m, length 2m, axis along world +Z). The drum begins with a hatch in the curved surface facing **up** (closed: marbles can't escape). At race start, the drum rotates 180° around its Z axis over ~1.5s; during rotation marbles tumble against the drum walls. At the end of rotation the hatch faces **down**, and the 20 marbles cascade out through the hatch into a wooden chute below. Chute funnels them into the entry of section 2.

**Why this and not a rake or a cage drop:** rotating drum is a single prefab kinematic piece (one animated transform), aesthetically consistent with MoS's "standardised mechanical pieces" vibe. It fairness-preserves the marbles' slot-determined starting positions while physically randomizing their exit order — same property as a real bingo cage. Dealer's-chip-pour would bunch marbles too tightly; a full bingo cage is visually cool but over-complicated for a 2s start; the croupier's rake was a bespoke custom animation that doesn't fit MoS's prefab vocabulary.

**Dimensions:**
- Drum outer shell: cylinder, inner radius 1.5m, wall thickness 0.2m, length 2m. Axis along world +Z.
- Hatch: a cutout in the curved surface, 1.2m wide (arc) × 1.6m long (axial). Starts at the top (local +Y) of the drum.
- Podium under drum: wooden pedestal 4m tall, drum axis at Y = +31.
- Exit chute: wooden slide from under-drum (Y ≈ +29) down to section-2 entry (Y ≈ +28).

**Materials:** drum outer surface brushed brass (metallic, slight sheen); drum interior dark wood; podium dark mahogany; exit chute mahogany with brass trim.

**Spawn points (24 total, per fairness protocol):** 3 rings of 8 inside the drum, each ring at radius 0.8m from the drum axis; rings at Z = −0.6, 0.0, +0.6. Marbles at unused fairness slots are simply not spawned. This is what `RouletteTrack.spawn_points()` returns — 24 absolute world positions inside the drum's interior.

**Determinism:** drum rotation is kinematic with fixed angular velocity, driven by `_physics_process`. Marble initial positions are fully determined by fairness slot. Tumbling chaos is deterministic given 60 Hz physics.

**Exit world position:** ≈ (−12, +28, 0). Feeds section 2.

### 2 — Helical downhill-turn: The wheel's orbit (12-15s)

**MoS piece type:** Downhill + Turn (helical).

**Mechanic:** A wooden trough (open-topped U-channel) coils 1.5 turns around the outside of the large decorative roulette wheel, descending from the top of the wheel to the bottom. Banking is outward (centrifugal-style), so marbles don't fly out. The decorative wheel **does not collide** with marbles — it's a background prop, slowly rotating for visual interest but invisible to physics.

**Dimensions:**
- Roulette wheel décor: diameter 14m, centered at world (0, +20, 0). Spins slowly for visuals, collision-disabled.
- Trough: inner radius ~7.5m (just outside the wheel's outer edge), outer radius ~8.5m; U-channel 1m wide, 0.8m deep.
- Entry at trough top: world (−8.5, +28, 0) — connects from section 1 chute.
- Exit at trough bottom: world (+8.5, +13, 0) — feeds section 3.
- 1.5 turns over 15m drop → 3.5° banking, gentle enough for marbles to slide fast but not fall off the inner wall.

**Materials:** mahogany trough floor, brass inner rail (closer to wheel), mahogany outer wall. Wheel décor mahogany + brass + green-felt pocket labels (non-colliding decals).

**Exit:** world (+8.5, +13, 0), feeds section 3 entry.

### 3 — Loop: The upper ball track (4-5s)

**MoS piece type:** Loop (full 360°, tubed).

**Mechanic:** A transparent tinted-glass tube loops 360° vertically. Marbles need enough speed from section 2 to clear the top of the loop. Pure MoS staple. Themed as "the ball spinning in the upper ball track" visually — the loop is labeled/painted as a roulette-wheel cross-section.

**Dimensions:**
- Loop radius: 3m. Entry at (+8.5, +13, 0). Exit at (+14, +13, 0) on the +X side.
- Tube inner diameter: 1.2m.

**Materials:** tinted blue-green glass (transparent), brass rings at tube junctions.

**Determinism check:** marble needs minimum entry speed of ~7 m/s to clear the top of the loop. Section 2's 15m drop through a banked trough provides ~10 m/s at the exit — safe margin.

### 4 — Split: Four pockets (1-2s)

**MoS piece type:** Split (4-way).

**Mechanic:** After the loop, track widens and splits into 4 parallel narrow lanes. Each lane is labeled with roulette numbers (red 3 / black 14 / red 27 / black 36 — doesn't matter which, just needs to read as "numbered pockets"). Marbles distribute across lanes based on their approach angle from the loop exit. Sharp dividers force commitment to one lane.

**Dimensions:**
- Split point at world (+14, +12, 0).
- Four lanes at Z offsets −3, −1, +1, +3, each lane 1m wide, 0.5m deep.
- Lane length: 2m before moguls start.

**Materials:** green felt lane floors, brass divider walls between lanes, red/black/gold painted lane-entry labels.

### 5 — Moguls: Chip-stack gauntlet (8-10s)

**MoS piece type:** Moguls (bumps + downhill).

**Mechanic:** Each of the 4 lanes is a descending felt slope (−X to +X direction) with **chip-stack pegs** planted in it like pachinko pins. Marbles deflect off pegs. Pegs are staggered per-lane so each lane has slightly different rhythm. Felt friction is grippy (0.7) so marbles slow to ~2-3 m/s before exit.

**Dimensions:**
- Four lane slopes: each 10m long, 1.8m wide, tilted 8° downhill.
- Entry at world X = +15, Y = +12, four Z offsets.
- Exit at world X = +25, Y ≈ +10.5 (lane drops ~1.5m over its length).
- Chip stacks: cylinders, radius 0.5m, height 1.2m, 6 per lane in staggered positions.

**Materials:** green felt slopes, gold chip-stack pegs.

### 6 — Funnel: Lane merge (2-3s)

**MoS piece type:** Funnel.

**Mechanic:** 4 lanes converge into a single wide outflow chute. Standard cone-funnel shape. All marbles forced into single stream.

**Dimensions:**
- Entry rectangle: 8m × 1m at (+25, +10.5, 0).
- Exit circle: diameter 1.5m at (+27, +9.5, 0).
- Funnel wall angle ~30°.

**Materials:** brass rim, polished wood funnel walls.

### 7 — Narrower: Croupier's shoot (2s)

**MoS piece type:** Narrower.

**Mechanic:** Narrowing tube, 1.5m → 0.8m diameter over 3m length. Forces single-file, builds momentum for the jump. Tinted glass so viewers see marbles queue.

**Dimensions:** entry diameter 1.5m at (+27, +9.5, 0); exit 0.8m at (+30, +9, 0).

**Materials:** tinted green-glass tube (Monte Carlo green), brass bands.

### 8 — Jump + landing: The croupier's spin (2-3s)

**MoS piece type:** Jump + Landing.

**Mechanic:** Narrower exits into the air. Marbles fly over a 3m gap. Land on a curved landing pad shaped like a roulette-wheel cross-section slice (a small decorative wheel segment). Pad funnels them into section 9.

**Dimensions:**
- Launch point: (+30, +9, 0) pointing +X.
- Gap: 3m horizontal × ~2m drop.
- Landing pad: curved wood ramp, entry at (+33.5, +7, 0).

**Materials:** brass launch ring, mahogany landing pad with painted pocket-ring decals.

### 9 — Betting grid: Zigzag descent (8-10s)

**MoS piece type:** Downhill + Turn + Turn + Turn (zigzag).

**Mechanic:** Descending zigzag ramp through what reads as the **roulette betting layout** — a grid of painted numbers 1–36 plus red/black colored cells. Four alternating switchbacks, each ~3m long, total drop ~6m. Each switchback's end-wall has a banked turn redirecting marbles 180°. Low friction (back to default 0.4) so marbles flow rather than grip.

**Dimensions:**
- Zigzag spans world X = +34 to +37, Z = −4 to +4.
- Four legs, each 3m long, connected by 180° banked turns (outside radius 1.5m).
- Net descent from Y = +7 to Y = +1.

**Materials:** green felt floors painted with betting grid (stenciled 1–36, red/black squares, dozen-splits), wooden side rails, brass corner bumpers.

### 10 — Finish: Dealer's chip rack (1-2s)

**MoS piece type:** Finish.

**Mechanic:** Zigzag ends by dropping marbles into the dealer's chip rack — a wooden box with numbered brass slots. FinishLine Area3D spans the rack entry. First marble in wins.

**Dimensions:** rack entry at world (+37, +1, 0), 4m wide × 1m tall × 0.6m deep.

**Materials:** mahogany rack, brass slot dividers, velvet lining.

## Decorative / non-collision elements

These exist purely for visual reading; they have no collision and don't affect physics:

- **Big roulette wheel décor** in the middle of the map at (0, +20, 0), diameter 14m, slowly rotating (0.3 rad/s). Visible behind the section-2 spiral. Mahogany + brass, numbered pockets.
- **Chip stacks on nearby podiums** around the base of the tower (decorative clutter).
- **Dealer figure silhouette** behind the tumbler (a simple low-poly human shape).
- **Casino skybox** — warm interior lighting, gold-tinted sky texture, no outdoor scene.

## Spawn points (fairness-protocol-mandated)

`RouletteTrack.spawn_points()` returns 24 world positions inside the bingo tumbler interior:

- 3 rings of 8 at ring radius 0.8m from the drum axis
- Rings at local Z = −0.6m, 0.0m, +0.6m (drum axis along world +Z, so these are offsets along the axis)
- Drum axis origin at world (−12, +31, 0)

Absolute world coords: ring points at `(−12 + cos(θ)·0.8, +31 + sin(θ)·0.8, z)` for θ ∈ 8 evenly-spaced angles × 3 Z offsets. That's 24 positions. `SpawnRail` applies the standard world-Y drop-order stagger on top.

## Determinism / fairness

- Drum rotation: deterministic kinematic animation (`_physics_process` advances a tracked angle at fixed angular velocity).
- Décor wheel rotation: collision-disabled, visual-only. Doesn't affect marble physics.
- All other geometry is static.
- Marble collision chaos inside the drum + inside the mogul lanes is physics-deterministic at 60 Hz given fixed initial conditions.
- Fairness vectors (`test_vectors_main`) unchanged — no change to fairness hash derivation.

## Physics materials (v3)

- **Wood surfaces** (trough, chute, zigzag rails): friction 0.4, bounce 0.25 (current `PhysicsMaterials.track()` default).
- **Felt surfaces** (mogul lanes): friction 0.7, bounce 0.15 (local override per section).
- **Glass tubes** (loop, narrower): friction 0.25, bounce 0.4 (slippery + bouncy — makes loop clear easier and narrower flow fast).
- **Brass fittings** (rims, bumpers, funnel walls): friction 0.3, bounce 0.5 (marbles bounce off with snap).
- Per-track `physics_materials()` API is still M6.7 work; for now these are inlined `PhysicsMaterial.new()` instances in roulette_track.gd.

## Build order (pass 1: skeletal MVP)

Not all sections need to be polished before first smoke. Build the **entry → exit plumbing** of all 10 sections as simple boxes/cylinders, verify a race runs start-to-finish, then iterate on each section's geometry and materials.

1. Bingo tumbler (section 1) + start chute.
2. Helical trough (section 2) — the structural centerpiece.
3. Funnel (6) + narrower (7) — middle plumbing.
4. Landing + zigzag + finish (8, 9, 10) — back half.
5. Loop (3) + split (4) + moguls (5) — front half (insert between 2 and 6).
6. All décor (wheel, skybox, chip stacks).

After smoke passes, iterate on timing per section.

## Acceptance criteria (M6.1 v3)

- [ ] Race runs start-to-finish with 20 marbles, 40-60s.
- [ ] Every section visibly curves or descends; no flat tilted planes.
- [ ] Reads as "roulette" (wheel décor + betting grid + chip stacks + dealer's rack).
- [ ] Reads as "Marbles-on-Stream" (modular sections, tubes, prefab energy).
- [ ] Verifier passes against a recorded replay.
- [ ] Wheel rotation (décor) and drum rotation (section 1) don't de-sync between sim and playback.

## Post-build notes (v1/v2 — archived 2026-04-25)

v1 (2026-04-24) and v2 (2026-04-25 morning) were both flat-tilted-plane layouts: a tilted spinning cylinder for the wheel + a tilted green felt rectangle with chip stacks. v2 hit the 50s target (57s at seed 0042) but was visually "a tilted cylinder next to a tilted rectangle" — no curves, no marble-run vocabulary. Scrapped in favor of v3 above.

Useful takeaways kept:
- **Nested-PhysicsBody3D hang** (v2) — still a hazard; v3's sections must flatten collision shapes to siblings within the same body. See [bugfixes.md](../bugfixes.md).
- **`transform.basis = ...` is a value-copy trap.** Use `node.basis = ...` to go through the setter.
- **Server-side `selectableTrackIDs` must stay in sync with Godot's `SELECTABLE`.** Warning comment already in [server/cmd/roundd/main.go](../../server/cmd/roundd/main.go).
- **Friction combine:** Jolt defaults to max-of-two, so a marble (friction 0.3) on felt (friction 0.7) effectively uses 0.7. Reliable.
