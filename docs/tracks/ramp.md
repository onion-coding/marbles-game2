# Track 0 — Ramp (Legacy)

Part of the M6 track library. See [m6-tracks.md](../m6-tracks.md) for context.

## Concept

The original S-curve ramp from M1–M4 development. A 5-segment tilted course (14° tilt, ±18° yaw snakes per segment, 60m total length) with static geometry (no kinematic obstacles). Marbles spawn at the uphill end and race downhill.

Left in the rotation pool for historical continuity (`track_id=0`); not tuned for the 40-50s casino-track window.

## Race time

**13.8s** (intentionally untuned). Default gravity 9.8 m/s², no slow-motion Area3D. Used as a smoke test baseline for track selection and protocol changes.

## Fairness-relevant interface

- `spawn_points()` — 24 positions from `SpawnRail` (3 rings × 8 around ramp width).
- `finish_area_transform()`, `finish_area_size()` — downhill finish slab.
- `camera_bounds()` — AABB framing the course from fixed perspective.
- `configure(round_id, server_seed)` — no-op (fully static).

## Post-build notes (2026-04-29)

**Race time: 13.8s** (not tuned). No SLOW_GRAVITY_ACCEL.

The S-curve layout is hardcoded in [game/tracks/ramp_track.gd](../../game/tracks/ramp_track.gd) as 5 segments with pitch/yaw per segment; geometry is the legacy ground truth for fairness-protocol testing. Verifier uses this track for round-trip checks because its static determinism is the simplest case.

This track can be retired or kept as a "tutorial/default" per operator preference. Interactive mode excludes it from the random-track pool by default (SELECTABLE omits `RAMP`).

Layout fields (mostly for documentation, not tuning): `LENGTH`, `ANGLE_DEG`, `SEGMENTS`, `SEGMENT_*`.
