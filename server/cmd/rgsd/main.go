// Command rgsd is the operator-facing daemon. It wraps the rgs.Manager
// in an HTTP server (rgs.HTTPHandler) and the standard sim/replay/rtp
// stack so an operator (or a demo "MockOperator" client) can drive
// player sessions end-to-end.
//
// M9 introduced the rgs surface; M10 layered the production-grade
// scaffolding on top:
//
//   - request id middleware so every log line / panic has a correlatable id
//   - structured slog access log on every request
//   - panic recovery → 500 with the request_id
//   - HMAC-SHA256 signed requests (skip /v1/health and /metrics for probes)
//   - Prometheus-format /metrics endpoint with rounds_total / bets_total /
//     bet_errors_total / round_duration_seconds
//   - graceful shutdown on SIGINT/SIGTERM
//
// Production deploys still need durable storage and an actual operator
// wallet; see docs/deployment.md for the open items.
package main

import (
	"context"
	"encoding/hex"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/onion-coding/marbles-game2/server/metrics"
	"github.com/onion-coding/marbles-game2/server/middleware"
	"github.com/onion-coding/marbles-game2/server/replay"
	"github.com/onion-coding/marbles-game2/server/rgs"
	"github.com/onion-coding/marbles-game2/server/sim"
)

func main() {
	var (
		godotBin       = flag.String("godot-bin", envOr("RGSD_GODOT_BIN", ""), "absolute path to Godot executable (env: RGSD_GODOT_BIN)")
		projectPath    = flag.String("project-path", envOr("RGSD_PROJECT_PATH", ""), "absolute path to game/ project dir (env: RGSD_PROJECT_PATH)")
		replayRoot     = flag.String("replay-root", envOr("RGSD_REPLAY_ROOT", ""), "where to persist per-round audit entries (env: RGSD_REPLAY_ROOT)")
		addr           = flag.String("addr", envOr("RGSD_ADDR", ":8090"), "HTTP listen address (env: RGSD_ADDR)")
		rtpBps         = flag.Uint("rtp-bps", uint(envIntOr("RGSD_RTP_BPS", 9500)), "configured return-to-player in basis points")
		buyIn          = flag.Uint64("buy-in", uint64(envIntOr("RGSD_BUY_IN", 100)), "stake per filled seat")
		marbles        = flag.Int("marbles", envIntOr("RGSD_MARBLES", 30), "marbles per round")
		simTimeout     = flag.Duration("sim-timeout", 60*time.Second, "hard cap per Godot subprocess")
		seedAlice      = flag.Uint64("seed-alice", 0, "if set, seed an in-memory wallet for player 'alice' for demo runs")
		hmacSecret     = flag.String("hmac-secret-hex", envOr("RGSD_HMAC_SECRET", ""), "hex-encoded HMAC key for /v1/* request signing; empty = auth disabled (dev only)")
		walletMode     = flag.String("wallet-mode", envOr("RGSD_WALLET_MODE", "mock"), "wallet backend: mock (default) or http (env: RGSD_WALLET_MODE)")
		walletURL      = flag.String("wallet-url", envOr("RGSD_WALLET_URL", ""), "base URL for HTTP wallet, required when --wallet-mode=http (env: RGSD_WALLET_URL)")
		walletHMAC     = flag.String("wallet-hmac-secret-hex", envOr("RGSD_WALLET_HMAC_SECRET", ""), "hex HMAC key for outbound wallet requests; empty = unsigned (env: RGSD_WALLET_HMAC_SECRET)")
		walletRetries  = flag.Int("wallet-retries", envIntOr("RGSD_WALLET_RETRIES", 3), "max retries on transient wallet errors (env: RGSD_WALLET_RETRIES)")
		walletIdemKeys = flag.Bool("wallet-idempotency-keys", true, "send Idempotency-Key header on debit/credit requests")
	)
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	if *godotBin == "" || *projectPath == "" || *replayRoot == "" {
		logger.Error("rgsd: required flags missing", "godot-bin", *godotBin, "project-path", *projectPath, "replay-root", *replayRoot)
		os.Exit(2)
	}

	store, err := replay.New(*replayRoot)
	if err != nil {
		logger.Error("replay.New", "err", err)
		os.Exit(1)
	}
	// Build the wallet client. Default is the in-process MockWallet (demo /
	// dev). Pass --wallet-mode=http + --wallet-url=<base> for a real operator
	// wallet that speaks the generic REST protocol (see docs/rgs-integration.md
	// §Wallet integration).
	var walletImpl rgs.Wallet
	switch *walletMode {
	case "http":
		if *walletURL == "" {
			logger.Error("rgsd: --wallet-url is required when --wallet-mode=http")
			os.Exit(2)
		}
		var hmacKey []byte
		if *walletHMAC != "" {
			var err error
			hmacKey, err = hex.DecodeString(*walletHMAC)
			if err != nil {
				logger.Error("rgsd: invalid --wallet-hmac-secret-hex", "err", err)
				os.Exit(2)
			}
		}
		walletImpl = rgs.NewHTTPWallet(rgs.HTTPWalletConfig{
			BaseURL:         *walletURL,
			HMACSecret:      hmacKey,
			MaxRetries:      *walletRetries,
			IdempotencyKeys: *walletIdemKeys,
		})
		logger.Info("rgsd: wallet mode http", "url", *walletURL,
			"retries", *walletRetries, "idempotency_keys", *walletIdemKeys)
	default: // "mock"
		mock := rgs.NewMockWallet()
		if *seedAlice > 0 {
			mock.SetBalance("alice", *seedAlice)
			logger.Info("rgsd: seeded MockWallet", "player", "alice", "balance", *seedAlice)
		}
		walletImpl = mock
	}

	roundsTotal := metrics.NewCounter("rgsd_rounds_total", "rounds run by this rgsd")
	betsTotal := metrics.NewCounter("rgsd_bets_total", "bets placed and accepted")
	betErrors := metrics.NewCounter("rgsd_bet_errors_total", "bets rejected (any reason)")
	roundDuration := metrics.NewHistogram("rgsd_round_duration_seconds",
		"wall clock from RunNextRound entry to manifest persisted",
		[]float64{1, 2, 5, 10, 20, 30, 60, 120})

	mgr, err := rgs.NewManager(rgs.ManagerConfig{
		Wallet:      &countingWallet{Wallet: walletImpl, accepted: betsTotal, rejected: betErrors},
		Store:       store,
		Sim:         instrumentedSim(sim.Run, roundsTotal, roundDuration),
		GodotBin:    *godotBin,
		ProjectPath: *projectPath,
		WorkRoot:    filepath.Join(*replayRoot, ".work"),
		BuyIn:       *buyIn,
		RTPBps:      uint32(*rtpBps),
		MaxMarbles:  *marbles,
		SimTimeout:  *simTimeout,
	})
	if err != nil {
		logger.Error("NewManager", "err", err)
		os.Exit(1)
	}

	apiMux := rgs.NewHTTPHandler(mgr).Routes()
	rootMux := http.NewServeMux()
	// /v1/* goes through the full middleware chain; /metrics is unauth so
	// scrapers don't need keys.
	chain := func(h http.Handler) http.Handler {
		// Inner-to-outer: HMAC → handler. Request ID, recovery, and
		// logging wrap the whole thing so they capture HMAC failures too.
		if *hmacSecret != "" {
			secret, err := hex.DecodeString(*hmacSecret)
			if err != nil {
				logger.Error("invalid hmac-secret-hex", "err", err)
				os.Exit(2)
			}
			h = middleware.HMAC(middleware.HMACConfig{
				Secret:    secret,
				SkipPaths: []string{"/v1/health"},
			})(h)
		} else {
			logger.Warn("rgsd: HMAC auth disabled (no --hmac-secret-hex). DO NOT run this in production.")
		}
		h = middleware.RequestID(h)
		h = middleware.Recovery(logger)(h)
		h = middleware.Logging(logger)(h)
		return h
	}
	rootMux.Handle("/v1/", chain(apiMux))
	rootMux.Handle("/metrics", metrics.Handler())

	srv := &http.Server{
		Addr:              *addr,
		Handler:           rootMux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Graceful shutdown: wait for SIGINT/SIGTERM, then give in-flight
	// requests up to 20s to drain.
	shutdownCh := make(chan os.Signal, 1)
	signal.Notify(shutdownCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-shutdownCh
		logger.Info("rgsd: shutdown signal received, draining")
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()

	logger.Info("rgsd: listening", "addr", *addr, "auth", *hmacSecret != "")
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("rgsd: serve", "err", err)
		os.Exit(1)
	}
}

// countingWallet wraps a Wallet to bump bet counters. Inc on success
// (Debit); Inc-error on failure. Credit isn't counted separately —
// successful credits map 1:1 with successful debit-bets that won.
type countingWallet struct {
	rgs.Wallet
	accepted *metrics.Counter
	rejected *metrics.Counter
}

func (c *countingWallet) Debit(playerID string, amount uint64, txID string) error {
	if err := c.Wallet.Debit(playerID, amount, txID); err != nil {
		c.rejected.Inc()
		return err
	}
	c.accepted.Inc()
	return nil
}

// instrumentedSim wraps the SimRunner to record duration + count.
func instrumentedSim(inner rgs.SimRunner, rounds *metrics.Counter, dur *metrics.Histogram) rgs.SimRunner {
	return func(ctx context.Context, req sim.Request) (sim.Result, error) {
		start := time.Now()
		res, err := inner(ctx, req)
		if err == nil {
			rounds.Inc()
			dur.Observe(time.Since(start).Seconds())
		}
		return res, err
	}
}

// envOr returns os.Getenv(key) if non-empty, otherwise dflt.
func envOr(key, dflt string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return dflt
}

// envIntOr parses an int env var with a default fallback.
func envIntOr(key string, dflt int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return dflt
	}
	var n int
	if _, err := parseIntStrict(v, &n); err != nil {
		return dflt
	}
	return n
}

// parseIntStrict is strconv.Atoi but returns the error verbatim. Wrapping
// instead of using strconv.Atoi directly to keep the env-fallback flow
// linear (and no ParseInt import needed at top level).
func parseIntStrict(s string, out *int) (int, error) {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			if !(i == 0 && s[i] == '-') {
				return 0, errors.New("not an integer")
			}
		}
	}
	n := 0
	sign := 1
	for i, c := range s {
		if i == 0 && c == '-' {
			sign = -1
			continue
		}
		n = n*10 + int(c-'0')
	}
	*out = n * sign
	return *out, nil
}
