# Stress Test Harness for rgsd

A pure Go stress testing tool for validating that the rgsd (Round Game Server Daemon) can handle realistic player load without degradation.

## Overview

This harness simulates N concurrent virtual players, each placing bets on marble races in a continuous loop. It measures:

- **Latency percentiles** (p50/p95/p99) for each endpoint
- **Error rates** (failed requests vs total)
- **Throughput** (rounds/second)
- **HTTP status code distribution**

No external dependencies—pure Go stdlib (`net/http`, `crypto/hmac`).

## Setup

### Prerequisites

- Go 1.18+
- A running rgsd instance with HMAC endpoint protection

### Running rgsd Locally

Start rgsd with HMAC enabled and a known secret:

```bash
rgsd \
  --http=127.0.0.1:8080 \
  --hmac-secret=dev-secret \
  --data-dir=/tmp/rgsd-stress-test
```

Or with Docker:

```bash
docker run -d \
  -p 127.0.0.1:8080:8080 \
  -e RGSD_HMAC_SECRET=dev-secret \
  rgsd:latest
```

## Running Tests

### PowerShell (Windows)

```powershell
# Quick smoke test
.\scripts\stress\runner.ps1 quick

# CI-friendly test
.\scripts\stress\runner.ps1 medium

# Release gate (long-running)
.\scripts\stress\runner.ps1 full

# Custom parameters
.\scripts\stress\runner.ps1 -Concurrency 50 -Duration 2m -BetsPerRound 10
```

### Bash (Unix/Linux/macOS)

```bash
# Quick smoke test
bash scripts/stress/runner.sh quick

# CI-friendly test
bash scripts/stress/runner.sh medium

# Release gate
bash scripts/stress/runner.sh full

# Custom via environment
CONCURRENCY=50 DURATION=2m ./scripts/stress/runner.sh
```

### Direct Go Invocation

```bash
go run scripts/stress/main.go \
  -url=http://localhost:8080 \
  -hmac-secret=dev-secret \
  -concurrency=100 \
  -duration=5m \
  -bets-per-round=20 \
  -think-time=2s
```

## Preset Configurations

### `quick` — Smoke Test
- **Concurrency**: 10 players
- **Duration**: 30 seconds
- **Purpose**: Fast validation in CI (sub-minute)
- **When to use**: Before merging, pre-release sanity check

### `medium` — CI-Friendly
- **Concurrency**: 100 players
- **Duration**: 5 minutes
- **Purpose**: Sustained load test, CI gate
- **When to use**: Every commit, automated gate

### `full` — Release Gate
- **Concurrency**: 1000 players
- **Duration**: 30 minutes
- **Purpose**: Production-grade validation
- **When to use**: Before production deployment

## Interpreting the Report

The test prints a markdown-formatted report at the end:

```
======================================================================
STRESS TEST REPORT
======================================================================

Test Configuration:
  Target URL:        http://localhost:8080
  Concurrency:       100 virtual players
  Duration:          5m0s
  Bets per round:    20
  Think time:        1s
  Deterministic:     false

Results:
  Elapsed time:      300.12 seconds
  Bets placed:       150000
  Bets failed:       450
  Error rate:        0.30%
  Rounds completed:  7500
  Throughput:        25.00 rounds/sec

Latency (ms) - startRound:
  p50:  8.45
  p95:  42.10
  p99:  156.23

Latency (ms) - placeBet:
  p50:  2.34
  p95:  8.90
  p99:  45.67

Latency (ms) - runRound:
  p50:  112.45
  p95:  523.89
  p99:  1245.67

Errors by HTTP status:
  429: 200
  500: 250

Acceptance gates:
  p99 placeBet < 100ms:        true (actual: 45.67ms)
  error rate < 1%:             true (actual: 0.30%)
  throughput >= 50 rounds/min: true (actual: 1500.00 rounds/min)

Result: PASS
======================================================================
```

### Key Metrics Explained

**Latency**: p50/p95/p99 tell you the distribution—aim for p99 to be <100ms on placeBet.

- **p50** = median response time
- **p95** = 95% of requests finish in this time (catches most of the tail)
- **p99** = tail latency; this is what users notice at scale

**Error Rate**: Percentage of failed requests (4xx, 5xx, network errors).
- < 0.5% is excellent
- 0.5–1% is acceptable under sustained load
- > 1% indicates trouble (retry backoff, resource exhaustion, bugs)

**Throughput**: Rounds completed per second.
- Multiply by 60 to get rounds/minute
- 25 rounds/sec = 1500 rounds/min (well above the 50 rounds/min gate)

**HTTP Status Codes**:
- **429** = Too Many Requests (rate-limit hit)
- **500** = Internal Server Error (service issue)
- **503** = Service Unavailable (overload)

## Acceptance Gates

The test automatically evaluates three gates (printed at the end):

| Gate | Target | Rationale |
|------|--------|-----------|
| p99 placeBet latency < 100ms | p99 < 100ms | Single bet must respond quickly |
| error rate < 1% | < 1% failed | Max 1 failure per 100 sustained requests |
| throughput >= 50 rounds/min | >= 50 r/m | Minimum operational viability |

**Test passes** if all three gates are green; otherwise, it **fails**.

## Example: Full Run (Quick Preset)

### Terminal Session

```bash
$ bash scripts/stress/runner.sh quick
Stress Test Runner
==================
Preset:      quick (Smoke test: 10 players, 30 seconds)
URL:         http://localhost:8080
Concurrency: 10
Duration:    30s
Bets/round:  5

Building stress test binary...
Starting test...

[30 seconds of network traffic]

======================================================================
STRESS TEST REPORT
======================================================================

Test Configuration:
  Target URL:        http://localhost:8080
  Concurrency:       10 virtual players
  Duration:          30s
  Bets per round:    5
  Think time:        1s
  Deterministic:     false

Results:
  Elapsed time:      30.45 seconds
  Bets placed:       1500
  Bets failed:       8
  Error rate:        0.53%
  Rounds completed:  300
  Throughput:        9.85 rounds/sec

Latency (ms) - startRound:
  p50:  6.23
  p95:  18.90
  p99:  52.45

Latency (ms) - placeBet:
  p50:  1.89
  p95:  5.67
  p99:  18.34

Latency (ms) - runRound:
  p50:  85.32
  p95:  234.56
  p99:  789.01

Errors by HTTP status:
  500: 8

Acceptance gates:
  p99 placeBet < 100ms:        true (actual: 18.34ms)
  error rate < 1%:             true (actual: 0.53%)
  throughput >= 50 rounds/min: true (actual: 591.00 rounds/min)

Result: PASS
======================================================================
```

### Analysis

- ✅ **Latency**: p99 is 18.34ms—excellent, well under the 100ms gate.
- ✅ **Error rate**: 0.53%—within tolerance.
- ✅ **Throughput**: 591 rounds/min—10x the minimum gate.
- ✅ **HTTP 500s**: Only 8 in 30 seconds under light load; probably transient.

**Verdict**: rgsd is healthy.

---

## Debugging Failed Tests

### High Error Rate (> 1%)

1. Check rgsd logs: Are there panics, out-of-memory, or connection pool exhaustion?
2. Verify HMAC secret matches: `-hmac-secret` flag must match rgsd config.
3. Check server capacity: ulimit on open files, max goroutines, disk I/O.
4. Lower concurrency and retry: `runner.ps1 -Concurrency 50 -Duration 30s`

### High p99 Latency (> 100ms on placeBet)

1. Network latency: Is rgsd colocated? Run from the same machine.
2. Database slowness: Monitor rgsd's DB (if it persists state).
3. CPU saturation: Check `top` or Task Manager on the rgsd host.
4. Connection pool: Increase rgsd's max connections or worker threads.

### Low Throughput (< 50 rounds/min)

1. Client-side bottleneck: Are the test harness goroutines blocked?
2. Rate-limiting: rgsd may have a global QPS cap—check config.
3. DNS resolution: Use `--url=127.0.0.1:8080` instead of `localhost`.

### Transient 429 or 503

- **429**: Backoff and retry later (feature works as designed).
- **503**: rgsd may be restarting or under maintenance; retry after 30s.

## CI Integration

Add this to your CI/CD pipeline (GitHub Actions example):

```yaml
- name: Stress Test — Quick
  run: |
    # Start rgsd in background
    rgsd --http=127.0.0.1:8080 --hmac-secret=ci-secret &
    RGSD_PID=$!
    sleep 2
    
    # Run quick preset
    bash scripts/stress/runner.sh quick
    TEST_RESULT=$?
    
    # Cleanup
    kill $RGSD_PID 2>/dev/null || true
    exit $TEST_RESULT
```

For `medium` or `full`, increase the CI timeout accordingly.

## Flags Reference

```
-url string
    rgsd target URL (default "http://localhost:8080")
-hmac-secret string
    HMAC secret for /v1/* endpoints (default "dev-secret")
-concurrency int
    number of concurrent players (default 10)
-duration duration
    test duration, e.g. 30s, 5m (default 30s)
-bets-per-round int
    bets each player places per round (default 5)
-think-time duration
    delay between rounds (default 2s)
-deterministic
    disable random jitter in timing (for reproducible CI runs)
```

## Notes

- **Deterministic mode** (`-deterministic` flag): Removes random jitter from think times, making results reproducible in CI.
- **Virtual players loop continuously**: Each player starts a round, places N bets, runs it, waits, and repeats.
- **HMAC signing**: Every request is signed with `X-HMAC-SHA256` header using SHA256(body).
- **Errors are non-fatal**: A failed bet doesn't stop the player; they continue to the next round.

---

## Troubleshooting

**"Error: Go is not installed"**
- Install Go 1.18+: https://golang.org/doc/install

**"error: start round failed: 401"**
- HMAC secret mismatch. Verify `-hmac-secret` matches rgsd's config.

**"error: start round failed: 503"**
- rgsd is down or overloaded. Check if it's running: `curl http://localhost:8080/health`

**"timeout waiting for response"**
- Network is slow or rgsd is wedged. Try with lower concurrency.

---

**Author**: Marbles Game Dev Team  
**Last Updated**: 2026-05-08  
**Version**: 1.0
