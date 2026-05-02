# helm/ — Kubernetes deployment (stub)

This directory will hold the Helm chart for `rgsd` + `replayd`. The
chart is **not yet written**; this README documents the shape it
should take so the work in phase 1 can land cleanly.

## Why a chart and not raw manifests

Operators we'll sell to typically run a managed Kubernetes (EKS / GKE /
AKS). They'll plug Marbles Game into their existing Helmfile or
ArgoCD ApplicationSet. Shipping a chart skips a "translate manifests
to our format" round-trip in their integration sprint.

## Required values (proposed `values.yaml` shape)

```yaml
image:
  rgsd:
    repository: ghcr.io/onion-coding/marbles-game/rgsd
    tag: ""              # default: chart appVersion
    pullPolicy: IfNotPresent
  replayd:
    repository: ghcr.io/onion-coding/marbles-game/replayd
    tag: ""

rgsd:
  replicas: 1            # phase 1 scales this with multi-round support
  rtpBps: 9500
  buyIn: 100
  marbles: 20
  hmacSecretRef:
    name: rgsd-hmac     # k8s Secret with key `secret`
    key: secret
  walletUrl: ""          # phase 1
  resources:
    requests: { cpu: 500m, memory: 512Mi }
    limits:   { cpu: 2,    memory: 1Gi   }

replayd:
  replicas: 2
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits:   { cpu: 500m, memory: 512Mi }

replayStore:
  type: pvc              # pvc | s3 (phase 3)
  pvc:
    size: 50Gi
    storageClass: ""
  s3:
    bucket: ""
    region: ""
    credentialsSecretRef: ""

postgres:
  enabled: true          # phase 1 enables this by default
  external:
    host: ""
    port: 5432
    database: marbles
    credentialsSecretRef: ""

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: rgs.example.com
      service: rgsd
  tls:
    enabled: true
    secretName: rgs-tls
```

## Templates the chart will need

- `deployment-rgsd.yaml`, `deployment-replayd.yaml`
- `service-rgsd.yaml`, `service-replayd.yaml`
- `ingress.yaml`
- `secret-hmac.yaml` (only if not externally managed)
- `persistentvolumeclaim-replays.yaml` (when `replayStore.type=pvc`)
- `configmap-prometheus.yaml` (optional, for the in-cluster scraper)
- `servicemonitor.yaml` (Prometheus Operator integration)
- `networkpolicy.yaml` (lock down rgsd↔postgres↔wallet)
- `poddisruptionbudget.yaml` (one each for rgsd / replayd)

## TODO before phase-1 release

1. Write the chart skeleton with `helm create rgsd-chart` and split
   into the file list above.
2. Hook `RGSD_HMAC_SECRET` to a `Secret` with rotation hooks (annotation
   that bumps the deployment when the secret changes).
3. Push images to a registry the operator can pull from (GHCR for
   private; Docker Hub later if we open up).
4. Sign images with cosign (Sigstore); reference the public key in
   chart docs.
5. Add a `values-aws.yaml`, `values-gcp.yaml`, `values-azure.yaml`
   with cloud-specific tweaks (storage class names, IAM role
   annotations).
