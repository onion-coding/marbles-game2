# Marbles on Stream — physics & map reference

Reference doc compiled 2026-04-26 from public sources (Steam page, official Steam Community track-building guide, PixelByPixel wiki, Steam forum threads, gameplay walkthroughs). Goal: replicate the *feel* and *map vocabulary* of Marbles on Stream (MoS) for our casino-game tracks, even though our use case (20 marbles, 1 winner per round, casino-themed) is narrower than MoS (up to 1000 marbles, racing/royale/etc., generic streamer tracks).

**Sources cited inline; most authoritative is the [official track-building guide on Steam Community](https://steamcommunity.com/sharedfiles/filedetails/?id=1910444994).**

## 1. Game overview

- **Developer:** Pipeworks Studios (originally), now PixelByPixel maintains it.
- **Engine:** **Unreal Engine 4**. Confirmed by community crash reports referencing UE4 modules.
- **Platform:** Windows 64-bit (also a separate mobile port). Min spec: i5 + GTX 1060.
- **Core concept:** Twitch viewers type `!play` in chat, each viewer gets a marble in the next race, marbles physics-race to the finish, viewer interaction limited to a few channel-point abilities.
- **Marble count:** **Hard cap 1000 per race**, justified by performance. Default in editor "test to upload" mode: **100 marbles**. Most active streams run 50–500.
- **Map source:** Official maps + a Steam Workshop community library (uploaded `.map` files).

Comparison to our project:
- Our marble count: **20** (configurable). MoS has 50–1000.
- Our race format: 1 winner takes pot; MoS is more varied (race, royale, grand prix, lap-based).
- Implication: MoS tracks are designed to handle **mass bottlenecks** (hundreds of marbles funneling through narrows). Our tracks need to be **readable** with 20 — opposite tuning, but the same piece vocabulary works.

## 2. Physics baseline

Hard MoS-specific physics values are not publicly documented. What's known + what we infer:

**Confirmed (from forum / guide):**
- Physics is UE4's built-in (PhysX, Chaos in newer UE versions).
- Tick rate: not stated, but UE4 defaults to a 60 Hz physics sub-step under most configurations. This matches our 60 Hz fixed tick.
- **Glitch behavior:** "Physics engine won't keep up properly with very high speeds" — marbles glitch through track at extreme velocity. Builders are warned to clamp boost values.
- **Tunneling avoidance:** Loops require *multiple low-magnitude boost pads* rather than one strong boost, because high-speed marbles tunnel through track collision.
- **Open edges trap marbles:** unsealed surfaces between adjacent pieces cause marbles to stick. Pieces are designed to mate cleanly.
- **Drop-test mode** (used during build): not all physics activate — destructible cubes and wiggly sticks behave as solid boxes during test, only "live" in actual races.

**Inferred (generic marble physics — see Sources for marble-physics references):**
- Marble is a uniform sphere; collision modeled as sphere-vs-mesh with Continuous Collision Detection.
- Friction coefficient: low — marbles roll significantly more than they slide. Visually consistent with ~0.2–0.3 friction.
- Bounce / coefficient of restitution: medium — visible bounces on hard surfaces but most energy preserved on rolling. Roughly 0.3–0.5 (lower than physical glass-on-glass at 0.9).
- Marble radius: not stated, but pieces are scaled in 5/10/45-unit grid increments and channels look ~3–5 marble-widths wide. Our project uses **0.3m radius** which is consistent if we assume MoS units ≈ centimeters (a 100-unit straight piece would be 1m; channels of 3–5 widths = 0.9–1.5m, marble radius ~0.15–0.25m).

**Open question:** UE4 vs Jolt parity. Our engine is Godot + Jolt; MoS is UE4 + PhysX. Sphere-on-mesh-collision behavior differs subtly between physics backends, so the *exact same* piece geometry won't produce the same race in our engine. We should re-tune piece dimensions and physics materials by playtest, not by translation.

## 3. Race format

**Lifecycle:**
1. Streamer opens a race window (the `BUY_IN` equivalent).
2. Viewers type `!play` in Twitch chat → marble enters the race with their name + chosen color.
3. Streamer starts the race → marbles spawn at the start piece and drop in.
4. Race proceeds physics-only; marbles bounce/roll through pieces.
5. First marble across the finish wins (race mode) or last alive (royale).

**Spawn behavior:**
- All marbles spawn at the **start piece**. No fairness derivation — random within the spawn volume.
- For 100+ marbles, the start piece is a bowl/funnel that gathers them and drops into a chute. Initial bunching is intentional and visually part of the start.
- For our 20-marble case the same pattern works at smaller scale: a wide spawn pad / bowl above the first track section, marbles drop in, swirl, then thread through.

**Finish detection:**
- A finish line piece registers crossings. First to cross wins. Subsequent crossers are ranked for podium (top 3 in lap mode get points).
- We already have the equivalent (`FinishLine` Area3D triggering on enter); behavior matches.

## 4. Track piece library (reference)

From the official Steam track-building guide. **Bold = "must have."** Italic = "MoS variant we'd implement differently."

### 4.1 Required pieces
| Piece | Role |
| --- | --- |
| **Start piece** | One per track. Defines the spawn volume. A bowl or funnel at the top of the track. |
| **Finish piece** | One per track. Defines the trigger volume that ends the race. |

### 4.2 Middle pieces (the bulk of the library)
| Piece | Function | Notes for our project |
| --- | --- | --- |
| **Straight** | Flat or tilted slab. Multiple lengths. | Direct translation. Multiple length variants (short/med/long). |
| **Turn** | 45° or 90° turn (left & right variants). | Banked inward to keep marbles on-track at speed. |
| **Downhill** | Steeper-than-straight slab; primary "cause descent" piece. | Direct. |
| **Split** | One channel → two channels (Y-split). | Variance source. Critical for race interest. |
| **Transition** | Adapter pieces between channel widths or piece-types (e.g. straight → loop). | We can probably collapse most transitions into "the receiving piece does the adapting." |
| **Elevator** | Lifts marbles up (defies gravity). | Probably unused for our casino MVP. |
| **Jumps & landings** | Ramp + landing pad with a gap in between. | Direct. The gap creates "did they make it?" tension. |
| **Funnel** (multiple variants) | Many channels → one (merge). | Companion to Split. |
| **Mogul** (multiple variants) | Bumpy / rolling-hill section. | Variance source. |
| **Narrower** (4 variants) | Channel narrows to bottleneck. | Critical at scale; creates pile-ups. For 20 marbles, less dramatic but still useful. |
| **Loops** (multiple types) | Vertical loop-de-loop. Requires distributed boost pads. | Spectacle piece. Casino fit unclear. |
| **Large pieces** | Big spectacle pieces (the guide doesn't enumerate). | Likely flagship / themed pieces. |

### 4.3 Obstacles (parented to a track piece, move with it)

| Obstacle | Behavior | Our equivalent |
| --- | --- | --- |
| **Pin** | Up/down piston; configurable `TimeBetweenMove`, `MoveDownSpeed`, `MoveUpSpeed`. Stationary mode (`IsStationaryPin`). All pins with same config move *synchronized*. | Kinematic body driven by a clock. |
| **Speed-boost pad** | Directional velocity boost. Rotatable for aerial launches. | Apply impulse on Area3D enter. |
| **Destructible cube** | Physics debris; stacking creates explosive interactions. | Skip for MVP — replay determinism complications. |
| **Hammer** | Spinning bar; only the head has collision. | RigidBody on hinge. |
| **Wiggly stick** ("Bamboo") | Flexible obstacle (some kind of soft constraint or hinge). | Hinge joint with spring. |
| **Rotating post** ("Dojo") | Spinning column. | Rotating kinematic body. |
| **Bongo pad** | Bouncy pad with sound. Properties: `SoundSetting` (12 options), `SoundPitch`, `BounceForce`, `Volume`. | Physics material with high restitution + audio trigger. |

**Important:** all obstacles are *parented* to a track piece, so they translate/rotate with the piece. This means the editor doesn't have to manage independent placement — placing a piece auto-places its attached obstacles.

### 4.4 Materials

Three slots per piece, color-customizable:
- **Base** — track surface
- **Obstacle** — obstacles' coloring
- **Glass** — translucent overlay (caps over pieces). Translucent NOT allowed on base "due to performance issues."

We'd map this to: per-piece `StandardMaterial3D` instances on the surface meshes, swappable per casino theme.

## 5. Snap & grid system

**Snap points** (the most important detail for piece-based level design):
- Every piece exposes **named ports**: a "blue ball" port (start of channel) and a "pink ball" port (end of channel).
- Snap rule: blue connects only to pink — directional.
- Implication: ports are *tagged*, not just geometric. Two output ports can't snap to each other; only output → input.

**Grid snapping:**
- 5 / 10 / 45 unit increments, or free placement.
- 45-unit increments are clearly designed for matching turn-piece angles (45° / 90°).

**Coordinate frames:**
- Global vs local toggle. "Local" means deltas are relative to the piece's own orientation — useful when placing a piece on a 45°-rotated turn.
- Manual X/Y/Z entry available for fine adjustment.

## 6. Map file

**Save location:** `%LOCALAPPDATA%\MarblesOnStream\Saved\CustomMaps\MyCustomMaps\`. (The `%appdata%` shortcut goes to `Roaming`; users are told to navigate up one level to `Local`.)

**File format:** **Not publicly documented.** Almost certainly a UE4 binary asset (`.umap` or a custom serialized format). The community track repos (e.g. `github.com/robocoonie/mos-tracks`) ship the raw files for re-import, but no parser exists publicly. **Implication for us:** we can't directly read MoS map files. We'd build our own format (JSON or Godot resource) and rebuild the piece vocabulary ourselves.

**Quotas:**
- Free version: 200 track pieces, 50 obstacles, 1 upload slot.
- Season pass: 300 track pieces, 100 obstacles, 25 upload slots.
- Tells us: a "full" MoS track is ~200 pieces + ~50 obstacles. That's a lot — most of which is straight + turn segments threading the path.

## 7. Editor UI affordances

From the official guide (paraphrased):
- **Multi-select:** shift-click for individual, shift-drag for window-select.
- **Object list panel:** see all placed pieces, jump to / select.
- **Coordinate tool:** show + edit XYZ of selection.
- **World lighting:** intensity slider + rotation.
- **Skybox:** preset selection — affects lighting and brightness.
- **Drop marble test:** lets builder release one marble during edit to see the path. Some obstacles inactive in test (destructibles, wigglies).

For our project, the editor is **not in scope** (decided 2026-04-26 — see PROGRESS.md). We're hand-coding tracks. But this section catalogues what an editor *would* need to expose, in case we revisit M7.

## 8. Physics & gameplay rules of thumb (from MoS community guidance)

These are the unwritten rules MoS builders learn from the guide and community:

1. **Channel width ≥ 3 marble diameters.** Bottlenecks happen on purpose at narrowers, not by accident.
2. **No open edges between pieces.** Always seal joints — open seams trap marbles.
3. **Distribute boosts.** Use 3 boost pads at 0.3× strength rather than 1 at 1.0× for loops.
4. **Banked turns.** Curves at speed need inward bank (~20–30°) so marbles don't fly out.
5. **Pre-finish merge.** If track has splits, merge them back into a single channel before the finish so the camera frame is readable.
6. **First-half determines podium.** With 100+ marbles, the lead pack is set in the first ~30% of the track. Late-track variance changes the podium order, not the winner pool. (For our 20-marble case this is less true — small-pack races have higher late-game variance.)

## 9. What we copy, what we change for the casino MVP

**Copy directly:**
- Piece-based mental model: tracks are sequences of typed pieces with snap-ports.
- Required-pieces rule: exactly one start, exactly one finish.
- Obstacle-parents-to-piece: obstacles travel with their host piece.
- 60 Hz physics tick (already done).
- Three-material-slot system (base / obstacle / glass).
- "Sealed joints" invariant.

**Change / drop:**
- Marble count: 20 not 1000. Channels can be narrower (still ≥ 3 diameters but no need for 6+).
- No `!play` chat integration — our buy-in is on-chain / casino-side, not Twitch.
- No royale / grand-prix modes — casino is single-winner pots only.
- No destructible cubes or wiggly sticks for M6 — replay-determinism risk (RigidBody2RigidBody collisions are sensitive to floating-point order). Add post-MVP if we want.
- No procedural / tilted modes.
- Theming is **casino-specific**, not generic. Roulette/Craps/Poker/Slots/Plinko maps re-skin standard pieces with casino props rather than free-form decoration.

**Adopt as guidance for the M6 casino tracks:**
- Spawn = bowl or funnel above the first track section; marbles drop into it; swirl; exit through a chute. (Currently our Roulette spawns 24-grid into a void.)
- Use the snap-port mental model even for hand-coded tracks: each section has a defined entry transform and exit transform, computed once, used to place the next section. Avoids the "chip-vs-wall trap" we hit in M6.1 — sections compose by construction.
- Per-piece physics material override (already supported on Track) — tune per casino theme (felt = grippy, marble floor = slick).

## 10. Open questions

- **Banked turn angle.** We don't have it from MoS; need playtest. Start at 25°.
- **Boost pad strength scale.** Inferred from "use multiple low values" but no absolute number. Suggest: per-pad delta-V of ≤2 m/s, distributed across 3+ pads for a loop.
- **Pin movement defaults.** `TimeBetweenMove`, `MoveDownSpeed`, `MoveUpSpeed` aren't documented numerically; all we know is they sync across pins with identical settings. Suggest: 1.5s period, 0.3m travel, 1 m/s speed.
- **Marble radius vs piece scale.** Our 0.3m radius is a guess. If a Roulette pocket should look believable, the marble should be a few cm — but at 60 Hz tick, sub-cm marbles tunnel. Stick with 0.3m for now; reconsider only if scale reads wrong on stream.

## Sources

- [Marbles on Stream on Steam (official store page)](https://store.steampowered.com/app/1170970/Marbles_on_Stream/)
- [Official "Marbles on Stream Track Building Guide" (Steam Community)](https://steamcommunity.com/sharedfiles/filedetails/?id=1910444994) — the most authoritative source for piece library, obstacle properties, and snap rules
- [PixelByPixel Studio wiki — Racing](https://wiki.pixelbypixel.studio/racing) — current developer's official docs
- [Steam forum: map save location](https://steamcommunity.com/app/1170970/discussions/0/1737761954043482331/)
- [Steam forum: 1000-marble cap discussion](https://steamcommunity.com/app/1170970/discussions/0/4085282327479048626/)
- [Steam forum: UE4 crash reports (engine confirmation)](https://steamcommunity.com/app/1170970/discussions/0/3110278728382955793/)
- [robocoonie/mos-tracks (GitHub) — community map repo](https://github.com/robocoonie/mos-tracks) — file format opaque, install path documented
- [Williams blog: Marbles on Stream walkthrough](https://williams-blogger.blogspot.com/2025/05/marbles-on-stream-walkthrough.html) — gameplay color, not technical
- Generic marble-run physics (for inferred coefficients): [Marble Magic — Physics of Marble Runs](https://marblemagic.com/physics-of-marble-runs)
