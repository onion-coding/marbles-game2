# Audio assets

`AudioController` (game/audio/audio_controller.gd) loads samples lazily by
path and is a no-op if the file isn't present, so the game ships fine
without any audio. Drop `.ogg` files into this directory — Godot picks
them up at next `--import`.

## Slots

| Path                                    | Trigger                               |
| --------------------------------------- | ------------------------------------- |
| `res://audio/ambient_default.ogg`       | Fallback ambient, used if no per-track |
| `res://audio/ambient_ramp.ogg`          | Track 0 (Ramp) ambient loop           |
| `res://audio/ambient_roulette.ogg`      | Track 1 (Roulette) ambient loop       |
| `res://audio/ambient_craps.ogg`         | Track 2 (Craps) ambient loop          |
| `res://audio/ambient_poker.ogg`         | Track 3 (Poker) ambient loop          |
| `res://audio/ambient_slots.ogg`         | Track 4 (Slots) ambient loop          |
| `res://audio/ambient_plinko.ogg`        | Track 5 (Plinko) ambient loop         |
| `res://audio/winner_jingle.ogg`         | One-shot fired when finish is crossed |

## Format guidelines

- **Container:** `.ogg` (Vorbis) — small, native to Godot, gapless looping.
- **Ambient loops:** ~60-90 s, designed to loop seamlessly. Music should sit
  in the background of the stream — instrument layer no louder than -14 LUFS,
  no abrupt transients that spike against the SFX bus.
- **Winner jingle:** 1.5-3 s one-shot, peak around -6 dB, ends decisively
  (no fade-out; the modal closes ~3 s after the jingle starts).
- **Sample rate:** 44.1 kHz stereo for music, 22.05 kHz mono OK for SFX.

## Per-track override

A track can supply a custom ambient path via `Track.audio_overrides()`:

```gdscript
func audio_overrides() -> Dictionary:
    return {"ambient": "res://audio/my_custom_track.ogg"}
```

Wins over the path mapping in `AudioController.AMBIENT_PER_TRACK`.

## Buses

For now everything goes through Godot's default `Master` bus. A future
pass will split into `Music` / `SFX` / `UI` with a settings overlay
exposing per-bus volume sliders.
