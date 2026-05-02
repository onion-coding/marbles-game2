# Contributing to Marbles Game

This is a proprietary product (see `LICENSE`); external contributions
are accepted only under a signed CLA. Internal contributors and
contractors of Onion Coding can follow the workflow below.

## Repository layout

| Path        | Purpose                                                  |
| ----------- | -------------------------------------------------------- |
| `game/`     | Godot 4 project (sim + client + replay). GDScript.       |
| `server/`   | Go backend: round state machine, RGS, replay store, sim invoker. Go 1.26+. |
| `docs/`     | Design + integration docs. Treat as source of truth.     |
| `scripts/`  | Repro helpers (RTP smoke, fairness vectors, web bundle). |
| `ops/`      | Dockerfiles, docker-compose, IaC stubs.                  |
| `.github/`  | CI / dependabot.                                         |

## Branch policy

- `main` is always green: CI must pass, `verify_main` + `test_vectors_main`
  must pass headless on Godot 4.6.2.
- Feature branches: `feat/<short-name>`. Bugfixes: `fix/<short-name>`.
- Don't push to `main` directly except for trivial doc fixes.

## Dev loop

```bash
# Go
make test         # go vet + go test ./... in server/
make lint         # staticcheck + gosec + govulncheck
make build        # builds rgsd, replayd, roundd, streamtest under tmp/

# Godot
make godot-import       # headless --import (catches script errors)
make godot-verify       # runs verify_main on the latest replay
make godot-vectors      # runs test_vectors_main against fairness-vectors.json

# Local stack
make docker-up    # rgsd + Postgres + Prometheus + Grafana on docker-compose
make docker-down
```

Or copy `.env.example` to `.env`, edit `RGSD_GODOT_BIN` to your local
Godot path, then `docker compose -f ops/docker-compose.yaml --env-file .env up`.

## Coding style

### Go
- `go fmt ./...` on save (every editor).
- Errors are values; wrap with `fmt.Errorf("layer: %w", err)`.
- `slog` for structured logs — no `fmt.Println` outside `cmd/*`.
- Tests live next to the file under test, `*_test.go`.
- No external deps without discussion. Stdlib first.

### GDScript
- `class_name` only when the type is reused outside its containing scene.
- Static typing on signatures (`func foo(x: int) -> bool`); local
  variables can stay inferred.
- One scene per file; one autoload per concern.

## Commit conventions

We follow a simplified Conventional Commits style:

- `Feat: ...` — user-visible feature.
- `Fix: ...` — bug fix.
- `Docs: ...` — documentation only.
- `Refactor: ...` — internal cleanup, no behaviour change.
- `Tests: ...` — only test changes.
- `Chore: ...` — repo plumbing (CI, deps, etc.).

The body should explain *why*, not *what* — the diff already covers
the *what*.

## Review checklist

Before opening a PR:

- [ ] `make test lint` passes.
- [ ] `make godot-import godot-verify godot-vectors` passes (if you
      touched `game/` or fairness code).
- [ ] No new external Go dependency without prior discussion.
- [ ] `CHANGELOG.md` updated under `[Unreleased]` if user-visible.
- [ ] `docs/` updated if you changed an HTTP endpoint or replay format.
- [ ] No PII / secrets in tests, logs, or fixtures.

## Security

Found something? Email `security@onion-coding.example` (set this up
before first external integration) — don't open a public issue.
Coordinated disclosure window: 90 days.
