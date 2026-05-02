# ops/

Deployment artefacts for Marbles Game.

```
ops/
├── Dockerfile.rgsd            # Operator-facing daemon (Godot bundled)
├── Dockerfile.replayd         # Read-only archive + WS fan-out
├── docker-compose.yaml        # Local dev stack (rgsd, replayd, postgres, prometheus, grafana)
├── prometheus.yaml            # Prometheus scrape config (used by compose)
├── grafana/                   # Grafana provisioning (datasources, dashboards TBD)
├── helm/                      # Helm chart (stub — see helm/README.md)
└── terraform/                 # IaC examples (stubs — see terraform/README.md)
```

## Quick start (local dev)

```bash
cp .env.example .env
# edit .env — at minimum set RGSD_HMAC_SECRET (openssl rand -hex 32)

make docker-up
# wait ~30s for the rgsd image build the first time

# end-to-end smoke
curl -s http://127.0.0.1:8090/v1/health
# {"status":"ok"}

# Prometheus on http://127.0.0.1:9090
# Grafana    on http://127.0.0.1:3000 (admin / admin)
```

## What's included

| Component  | Image                           | Port | Notes                                   |
| ---------- | ------------------------------- | ---- | --------------------------------------- |
| rgsd       | `marbles-game/rgsd:dev`         | 8090 | Built locally; bundles Godot 4.6.2      |
| replayd    | `marbles-game/replayd:dev`      | 8087 | Distroless static; reads replay volume  |
| postgres   | `postgres:16-alpine`            | 5432 | Provisioned but not yet wired to rgsd   |
| prometheus | `prom/prometheus:v2.55.1`       | 9090 | Scrapes rgsd `/metrics`                 |
| grafana    | `grafana/grafana:11.3.0`        | 3000 | Pre-wired Prometheus datasource         |

## What's NOT included (yet)

- Postgres-backed `Sessions` / `pendingRounds` — phase 1.
- Real wallet client — phase 1; today rgsd uses MockWallet.
- TLS termination — production deployments front rgsd with a reverse
  proxy that handles certs (Caddy, Traefik, or the cloud LB).
- Object-store replay backend — phase 3; today the volume is local.
- Helm chart actual templates — see `helm/README.md`.
- Terraform IaC actual modules — see `terraform/README.md`.

## Production deployment notes

Each component has a different scaling profile:

- **rgsd** is CPU-bound while a Godot subprocess runs (one round = ~5–10s
  of one core). Run N replicas where N covers your peak round
  concurrency; bind each replica to a distinct lobby (the multi-round
  refactor in phase 1 makes this real).
- **replayd** is bandwidth-bound (live WS fan-out). Stateless; scale
  horizontally behind a load balancer with sticky sessions on the WS
  upgrade.
- **postgres** is the durable seat for sessions / bets. Use a managed
  service with PITR enabled.

Health-check paths:

- `rgsd` → `GET /v1/health` (HMAC skip-listed).
- `replayd` → `GET /` returns 200 if `--static-root` is set, otherwise
  `GET /rounds` returns the index. Phase 2 adds a dedicated
  `/health` route.

## Building images outside compose

```bash
docker build -t marbles-game/rgsd:dev    -f ops/Dockerfile.rgsd    .
docker build -t marbles-game/replayd:dev -f ops/Dockerfile.replayd .
```

Both Dockerfiles expect the build context to be the repo root.
