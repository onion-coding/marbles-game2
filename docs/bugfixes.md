# Bugfix log

Running log of bugs found and how they were fixed. One entry per bug. Purpose: searchable history of weird root causes and gotchas so we don't re-debug the same thing six months from now.

**When to add an entry:** a bug that took more than a trivial amount of time to track down, OR that had a non-obvious root cause, OR that touches an area likely to regress.

**When NOT to add:** one-line typo fixes, obvious compile errors, work-in-progress iteration. Git log already covers those.

## Entry format

```
## <short title> — YYYY-MM-DD
**Symptom:** what the user / developer saw.
**Root cause:** what was actually wrong.
**Fix:** what changed. Link to commit SHA or PR.
**Lesson:** (optional) what to remember for next time.
```

## Entries

## Marbles spawning at the downhill end of the ramp — 2026-04-14
**Symptom:** During M1 playtest, the 20 marbles appeared to spawn near "the end of the platform" and barely moved — hard to judge physics feel because there was no sustained rolling.
**Root cause:** The ramp is tilted `-20°` around X in [game/main.gd](game/main.gd). Under that rotation, world **Z=+15 is the uphill end and Z=-15 is the downhill end** — the opposite of what the naive "negative Z = back = top" intuition suggests. The spawn block placed marbles at Z ∈ [-15, -13] — i.e. the *bottom* of the ramp — so they just fell onto the downhill end and settled.
**Fix:** Flipped spawn Z to `RAMP_LENGTH*0.5 - rng.randf_range(0, 2.0)` (uphill end) and lowered `SPAWN_HEIGHT` from 12.0 to 5.8 (~1 unit above the tilted ramp surface at that Z) in [game/main.gd](game/main.gd). No physics-material changes needed.
**Lesson:** When a body is rotated around X by a negative angle in Godot, the +Z local axis tilts *up* in world space, not down. Always sanity-check spawn coordinates against the actual rotated ramp geometry (`y_world ≈ z_local * sin(angle)`) rather than trusting axis sign intuition.

