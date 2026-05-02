# Marbles Game — top-level Makefile
#
# Cross-platform (bash on Windows works fine — git-bash, msys, or WSL).
# Targets are organised by what they touch: server/ (Go), game/ (Godot),
# ops/ (Docker), and meta (lint, ci, clean).
#
# All commands run from the repo root unless noted.

# ---- Configuration -----------------------------------------------------

# Override these on the command line or in a local .env loaded by your
# shell. They're not loaded automatically — `make GODOT_BIN=... godot-verify`.

GODOT_BIN     ?= $(RGSD_GODOT_BIN)
PROJECT_PATH  ?= $(CURDIR)/game
REPLAY_ROOT   ?= $(CURDIR)/tmp/replays
TMP           ?= $(CURDIR)/tmp

GO            ?= go
GOFLAGS       ?=

# Binaries we build under tmp/.
BIN_RGSD      := $(TMP)/rgsd$(if $(filter Windows_NT,$(OS)),.exe,)
BIN_REPLAYD   := $(TMP)/replayd$(if $(filter Windows_NT,$(OS)),.exe,)
BIN_ROUNDD    := $(TMP)/roundd$(if $(filter Windows_NT,$(OS)),.exe,)
BIN_STREAMTEST:= $(TMP)/streamtest$(if $(filter Windows_NT,$(OS)),.exe,)

# ---- Phony declarations ------------------------------------------------

.PHONY: help \
        build build-rgsd build-replayd build-roundd build-streamtest \
        test test-go test-race \
        lint lint-go lint-staticcheck lint-gosec lint-vuln \
        godot-import godot-verify godot-vectors \
        smoke smoke-rtp \
        docker-build docker-up docker-down docker-logs \
        ci clean

# ---- Help (default target) --------------------------------------------

help: ## Show this help (default).
	@printf "Marbles Game — Makefile targets\n\n"
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---- Server (Go) ------------------------------------------------------

build: build-rgsd build-replayd build-roundd build-streamtest ## Build all Go binaries into tmp/.

build-rgsd: ## Build the rgsd operator daemon.
	@mkdir -p $(TMP)
	cd server && $(GO) build $(GOFLAGS) -o $(BIN_RGSD) ./cmd/rgsd

build-replayd: ## Build the replayd archive HTTP/WS server.
	@mkdir -p $(TMP)
	cd server && $(GO) build $(GOFLAGS) -o $(BIN_REPLAYD) ./cmd/replayd

build-roundd: ## Build the roundd round-loop coordinator.
	@mkdir -p $(TMP)
	cd server && $(GO) build $(GOFLAGS) -o $(BIN_ROUNDD) ./cmd/roundd

build-streamtest: ## Build the streamtest live-stream smoke client.
	@mkdir -p $(TMP)
	cd server && $(GO) build $(GOFLAGS) -o $(BIN_STREAMTEST) ./cmd/streamtest

test: test-go ## Run all tests.

test-go: ## go test ./... + go vet ./...
	cd server && $(GO) vet ./...
	cd server && $(GO) test ./...

test-race: ## go test -race ./...
	cd server && $(GO) test -race ./...

# ---- Lint -------------------------------------------------------------

lint: lint-go lint-staticcheck lint-gosec lint-vuln ## All lints.

lint-go: ## go vet only (fast).
	cd server && $(GO) vet ./...

lint-staticcheck: ## staticcheck (install: go install honnef.co/go/tools/cmd/staticcheck@latest).
	cd server && staticcheck ./...

lint-gosec: ## gosec (install: go install github.com/securego/gosec/v2/cmd/gosec@latest).
	cd server && gosec -quiet -severity medium ./...

lint-vuln: ## govulncheck (install: go install golang.org/x/vuln/cmd/govulncheck@latest).
	cd server && govulncheck ./...

# ---- Godot ------------------------------------------------------------

godot-import: ## Headless --import to catch GDScript errors.
	@if [ -z "$(GODOT_BIN)" ]; then echo "GODOT_BIN unset (or RGSD_GODOT_BIN). aborting."; exit 2; fi
	"$(GODOT_BIN)" --headless --path $(PROJECT_PATH) --import

godot-verify: ## Run verify_main on the latest replay (re-derives slots from revealed seed).
	@if [ -z "$(GODOT_BIN)" ]; then echo "GODOT_BIN unset. aborting."; exit 2; fi
	"$(GODOT_BIN)" --headless --path $(PROJECT_PATH) res://verify_main.tscn

godot-vectors: ## Run test_vectors_main against docs/fairness-vectors.json.
	@if [ -z "$(GODOT_BIN)" ]; then echo "GODOT_BIN unset. aborting."; exit 2; fi
	"$(GODOT_BIN)" --headless --path $(PROJECT_PATH) res://test_vectors_main.tscn

# ---- Smoke / RTP ------------------------------------------------------

smoke: build ## Quick end-to-end: 1 round via roundd against tmp/replays.
	@mkdir -p $(REPLAY_ROOT)
	@if [ -z "$(GODOT_BIN)" ]; then echo "GODOT_BIN unset. aborting."; exit 2; fi
	$(BIN_ROUNDD) \
	  --godot-bin="$(GODOT_BIN)" \
	  --project-path="$(PROJECT_PATH)" \
	  --replay-root="$(REPLAY_ROOT)" \
	  --rounds=1 --marbles=20 --rtp-bps=9500 --buy-in=100

smoke-rtp: build ## RTP harness: 100 rounds + chi-square report (~20 min).
	@mkdir -p $(REPLAY_ROOT)
	@if [ -z "$(GODOT_BIN)" ]; then echo "GODOT_BIN unset. aborting."; exit 2; fi
	GODOT_BIN="$(GODOT_BIN)" PROJECT_PATH="$(PROJECT_PATH)" REPLAY_ROOT="$(REPLAY_ROOT)" \
	  bash scripts/rtp_smoke.sh 100

# ---- Docker ----------------------------------------------------------

docker-build: ## Build container images via docker-compose.
	docker compose -f ops/docker-compose.yaml build

docker-up: ## Start rgsd + Postgres + Prometheus + Grafana locally.
	docker compose -f ops/docker-compose.yaml up -d

docker-down: ## Stop and remove the local stack.
	docker compose -f ops/docker-compose.yaml down -v

docker-logs: ## Follow logs from the local stack.
	docker compose -f ops/docker-compose.yaml logs -f --tail=100

# ---- Composite -------------------------------------------------------

ci: test-go lint-go ## Minimal CI gate (fast, deps-free).

clean: ## Remove build artefacts.
	rm -rf $(TMP)
	rm -rf game/.godot
