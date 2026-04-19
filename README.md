# Marbles Game

3D physics marble race game, designed for online casino integration (crypto-first). First-to-finish wins the pot.

See [PLAN.md](PLAN.md) for the full development plan, [PROGRESS.md](PROGRESS.md) for what's done. Current status: **M5 done** — archive HTTP API serves completed rounds, `web_main.tscn` (Godot Web export) fetches and renders them, live WebSocket streaming is wired end-to-end (sim → TCP → hub → WS subscribers), and `live_main.tscn` is the Godot live client that subscribes to `/live/{id}` and renders tick-by-tick. Next candidates: M6 polish (boot-splash branding, cinematic camera, juice) or M2.5 tick quantization.

## Repo layout

```
marbles-game/
├── PLAN.md           # Development plan (scope, architecture, milestones)
├── game/             # Godot 4 project (both sim and client targets)
├── server/           # Backend glue (not started)
├── ops/              # Dockerfiles, CI (not started)
└── docs/             # Design docs
    ├── fairness.md       # Provably-fair commit/reveal protocol
    └── tick-schema.md    # Replay wire format
```

## Dev setup

### Godot

- **Version:** 4.6.2-stable (latest as of 2026-04). Jolt is the default 3D physics backend from 4.4+.
- **Install path on this machine:** `C:\Users\sergi\Godot\Godot_v4.6.2-stable_win64.exe`
- If reinstalling, grab the win64 zip from <https://godotengine.org/download/> or the GitHub releases page. No Hub, no account required.

### Opening the project

```bash
# Launch editor on the project
"C:\Users\sergi\Godot\Godot_v4.6.2-stable_win64.exe" --editor --path "game"
```

Or just open Godot → Import → point at [game/project.godot](game/project.godot).

### Running the current prototype

Three end-to-end scenes, all runnable headlessly:

| Scene | What it does |
|---|---|
| `res://main.tscn` | Generate `server_seed`, publish hash, run seeded race, write replay to `user://replays/<round>.bin`, reveal seed |
| `res://playback_main.tscn` | Load latest replay, render visual-only marbles driven by interpolated tick frames |
| `res://verify_main.tscn` | Headless verifier: re-derive spawn slots from the revealed seed and confirm they match the recording |
| `res://test_vectors_main.tscn` | Regression test: load [docs/fairness-vectors.json](docs/fairness-vectors.json) and confirm `FairSeed` matches the independent Python reference byte-for-byte |
| `res://web_main.tscn` | Network-sourced playback: fetches the latest round from `replayd` over HTTP and renders it. Runs on desktop today; same scene is intended for Web export once the HTML5 templates are installed. Pass `++ --api-base=http://host:port` to point at a non-default replayd. |
| `res://live_main.tscn` | Live playback: polls `replayd /live`, WebSocket-subscribes to the newest active round, decodes the streaming protocol, and renders frame-by-frame. Launcher routes here when `++ --live` (desktop) or `?live=1` (web URL) is set. Same `--api-base` override applies. |

In the editor: press **F5** and pick the scene. Headless:

```bash
"C:\Users\sergi\Godot\Godot_v4.6.2-stable_win64.exe" --headless --path game --quit-after 3000             # record
"C:\Users\sergi\Godot\Godot_v4.6.2-stable_win64.exe" --headless --path game res://playback_main.tscn      # play back latest
"C:\Users\sergi\Godot\Godot_v4.6.2-stable_win64.exe" --headless --path game res://verify_main.tscn        # verify latest
"C:\Users\sergi\Godot\Godot_v4.6.2-stable_win64.exe" --headless --path game res://test_vectors_main.tscn  # fairness regression vectors
```

### Regenerating fairness test vectors

If the fairness protocol changes, regenerate [docs/fairness-vectors.json](docs/fairness-vectors.json) from the Python reference, then re-run the Godot regression:

```bash
python scripts/gen_fairness_vectors.py
"C:\Users\sergi\Godot\Godot_v4.6.2-stable_win64.exe" --headless --path game res://test_vectors_main.tscn
```

### Server (M4, in progress)

Go module at [server/](server/). Requires Go 1.26+.

```bash
cd server
go test ./...       # unit tests (state machine, invoker arg validation)
go vet ./...
```

The Go → Godot integration test is gated on env vars so it doesn't run in the fast path:

```bash
cd server
MARBLES_GODOT_BIN="C:/Users/sergi/Godot/Godot_v4.6.2-stable_win64.exe" \
MARBLES_PROJECT_PATH="C:/Users/sergi/projects/marbles-game/game" \
go test ./sim/... -v -run TestRunEndToEnd
```

### Running rounds end-to-end (M4 bar)

The `roundd` coordinator runs N full rounds — fresh seed, mock buy-in, Godot sim, payout, per-round audit entry:

```bash
cd server
go build -o ../tmp/roundd.exe ./cmd/roundd
../tmp/roundd.exe \
  --godot-bin="C:/Users/sergi/Godot/Godot_v4.6.2-stable_win64.exe" \
  --project-path="C:/Users/sergi/projects/marbles-game/game" \
  --replay-root="C:/Users/sergi/projects/marbles-game/tmp/replays" \
  --rounds=3 --marbles=20 --rtp-bps=9500 --buy-in=100
```

Each round leaves `tmp/replays/<round_id>/{manifest.json, replay.bin}` — a self-contained audit entry (commit, reveal, participants, winner, replay SHA-256, payout computable from the manifest).

### Serving the archive over HTTP (M5.0)

The `replayd` binary wraps the replay store in a small HTTP API:

```bash
cd server
go build -o ../tmp/replayd.exe ./cmd/replayd
../tmp/replayd.exe --listen=:8080 --replay-root=../tmp/replays
```

Endpoints:

```
GET /rounds                    → {"round_ids": [...]} (strings, ascending)
GET /rounds/{id}               → manifest.json
GET /rounds/{id}/replay.bin    → raw replay bytes (ETag, Range, immutable cache)
```

### Serving the web client (M5.1)

Export the HTML5 build once (Web export templates must be installed — see "Godot Web export templates" below), then run `replayd` with `--static-root` pointing at the export:

```bash
cd game
"C:\Users\sergi\Godot\Godot_v4.6.2-stable_win64.exe" --headless --path . --export-release "Web" ../tmp/web_export/index.html

cd ../server
go build -o ../tmp/replayd.exe ./cmd/replayd
../tmp/replayd.exe \
  --listen=:8087 \
  --replay-root=../tmp/replays \
  --static-root=../tmp/web_export
```

Then open `http://127.0.0.1:8087/` in a browser. The game bundle (~38 MB) and the archive API are served from the same origin, so no CORS dance. On desktop the same `web_main.tscn` runs against `http://127.0.0.1:8080` by default; override with `++ --api-base=http://host:port`.

### Live streaming (M5.2)

`replayd` also accepts sim connections over TCP and fans them out to WebSocket subscribers. Start with `--stream-tcp`:

```bash
../tmp/replayd.exe \
  --listen=:8087 \
  --stream-tcp=:8088 \
  --replay-root=../tmp/replays

# in another terminal — sim connects back to :8088 live
../tmp/roundd.exe \
  --godot-bin="C:/Users/sergi/Godot/Godot_v4.6.2-stable_win64.exe" \
  --project-path="C:/Users/sergi/projects/marbles-game/game" \
  --replay-root="../tmp/replays" \
  --live-stream-addr=127.0.0.1:8088 \
  --rounds=1
```

Endpoints:

```
GET /live                    → {"round_ids": ["<id>", ...]} (currently live)
GET /live/{id}  (WebSocket)  → binary frames: type(u8)+len(u32)+payload
```

Dev smoke client: `../tmp/streamtest.exe --api-base=http://127.0.0.1:8087` polls `/live`, subscribes to the first active round, and prints a message tally until DONE.

### Live Godot client (M5.3)

`live_main.tscn` is the Godot-side counterpart to `streamtest` — it polls `/live`, subscribes to the newest active round over WebSocket, and renders tick-by-tick via `PlaybackPlayer`.

```bash
# desktop: pass --live via the launcher, point at the replayd above
"C:\Users\sergi\Godot\Godot_v4.6.2-stable_win64.exe" --path game ++ --live --api-base=http://127.0.0.1:8087

# or skip the launcher and run the scene directly
"C:\Users\sergi\Godot\Godot_v4.6.2-stable_win64.exe" --path game res://live_main.tscn ++ --api-base=http://127.0.0.1:8087
```

On Web, append `?live=1` to the URL served by `replayd`. The launcher reads `window.location.search` and routes to `live_main.tscn`; `--api-base` defaults to the current origin so no override is needed.

### Godot Web export templates

Needed once per Godot version. Either install via the editor (*Editor → Manage Export Templates → Download and Install*) or drop the four web zips (`web_release.zip`, `web_debug.zip`, `web_nothreads_release.zip`, `web_nothreads_debug.zip`) plus `version.txt` into `%APPDATA%\Godot\export_templates\<version>\`. The full `.tpz` (~1.2 GB) only bundles per-platform zips — only the web ones are required for this project.

### Headless smoke-test

Useful to catch script errors without opening the editor:

```bash
"C:\Users\sergi\Godot\Godot_v4.6.2-stable_win64_console.exe" --headless --path game --import
```

## Project settings locked in

- Physics tick rate: **60 Hz**, also the wire tick rate for v2 replays (revisit when bandwidth becomes a concern in M5 — see [PLAN.md open questions](PLAN.md#L161)).
- Physics engine: **JoltPhysics3D** (set explicitly in [game/project.godot](game/project.godot)).
- Renderer: **Forward+** (may switch to Mobile or Compatibility for Web export in M5 if bundle size blows up).
