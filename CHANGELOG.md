# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

API stability: the operator-facing HTTP API under `/v1/*` follows
semver. Breaking changes to `/v1/*` will only ship behind a `/v2/*`
namespace; `/v1/*` will remain supported for at least **12 months**
after `/v2/*` GA.

## [Unreleased]

### Added
- `LICENSE` (proprietary), `NOTICE`, `CHANGELOG.md`, `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, `Makefile`, `.env.example`.
- Phase 0 ops scaffolding: Dockerfile + docker-compose for local dev.
- GitHub Actions CI: `go vet`, `go test`, `staticcheck`, `gosec`,
  `govulncheck`, plus Godot headless `verify_main` + `test_vectors_main`.
- Dependabot config for Go modules and GitHub Actions.

## [0.10.0] — 2026-04-29 — M9 + M10

### Added
- M9 RGS betting end-to-end (`POST /v1/rounds/{id}/bets`,
  `GET /v1/wallets/{id}/balance`, settlement overlay, 19× payout for
  95% RTP).
- M10 production scaffolding: `server/middleware` (request id, slog
  logging, panic recovery, HMAC-SHA256), `server/metrics`
  (Prometheus-format `/metrics`), graceful shutdown, 12-factor flags +
  env vars on `rgsd`.
- HUD interactive mode: clickable standings, zoom 0.05–1000m, marble
  selector keys, bet placement panel, countdown timers, balance
  refresh.
- `docs/deployment.md`, `docs/rgs-integration.md`.

### Fixed
- Seed-alignment bug: `Manager.RunNextRound` now consumes the head of
  `pendingRounds` (FIFO) instead of minting a fresh seed, so the seed
  locked at `/v1/rounds/start` is the seed used to run the round.

## [0.9.0] — Earlier milestones

See [PROGRESS.md](PROGRESS.md) for the per-milestone change log
(M1 through M8). This file becomes the canonical changelog from the
Unreleased section forward.
