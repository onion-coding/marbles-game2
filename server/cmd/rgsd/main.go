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

	"github.com/onion-coding/marbles-game2/server/admin"
	"github.com/onion-coding/marbles-game2/server/metrics"
	"github.com/onion-coding/marbles-game2/server/middleware"
	"github.com/onion-coding/marbles-game2/server/postgres"
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
		walletIdemKeys      = flag.Bool("wallet-idempotency-keys", true, "send Idempotency-Key header on debit/credit requests")
		postgresDSN         = flag.String("postgres-dsn", envOr("RGSD_POSTGRES_DSN", ""), "Postgres DSN for durable session storage; empty = in-memory (env: RGSD_POSTGRES_DSN)")
		postgresMigrate     = flag.Bool("postgres-migrate", false, "run Postgres migrations then exit")
		defaultCurrency     = flag.String("default-currency", envOr("RGSD_DEFAULT_CURRENCY", rgs.DefaultCurrency), "default currency code used when none is specified (env: RGSD_DEFAULT_CURRENCY)")
		supportedCurrencies = flag.String("supported-currencies", envOr("RGSD_SUPPORTED_CURRENCIES", "EUR,USD,GBP,BTC,ETH,USDT"), "comma-separated whitelist of accepted currency codes (env: RGSD_SUPPORTED_CURRENCIES)")
		adminAddr       = flag.String("admin-addr", envOr("RGSD_ADMIN_ADDR", ":8091"), "admin panel listen address (env: RGSD_ADMIN_ADDR); separate from /v1/* so it can be firewalled")
		adminHMAC       = flag.String("admin-hmac-secret-hex", envOr("RGSD_ADMIN_HMAC_SECRET", ""), "hex HMAC key for admin panel auth; empty = no auth (dev only, env: RGSD_ADMIN_HMAC_SECRET)")

		// Scheduler flags — see docs/deployment.md §Round scheduler.
		schedulerEnabled      = flag.Bool("scheduler-enabled", false, "run rounds automatically on a ticker (default false: use POST /v1/rounds/run instead)")
		schedulerBetWindow    = flag.Duration("scheduler-bet-window", 10*time.Second, "bet window duration: how long players have to place bets before the round runs")
		schedulerBetweenRounds = flag.Duration("scheduler-between-rounds", 5*time.Second, "cooldown between end of one round and start of the next bet window")
	)
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	// --postgres-migrate: apply schema migrations then exit. Does not require
	// --godot-bin / --project-path so ops can run it as an init container.
	if *postgresMigrate {
		if *postgresDSN == "" {
			logger.Error("rgsd: --postgres-migrate requires --postgres-dsn")
			os.Exit(2)
		}
		if err := postgres.RunMigrations(context.Background(), *postgresDSN); err != nil {
			logger.Error("rgsd: migrations failed", "err", err)
			os.Exit(1)
		}
		logger.Info("rgsd: migrations applied successfully")
		os.Exit(0)
	}

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

	// Optional Postgres session store. Nil = legacy in-memory behaviour.
	var sessionStore rgs.SessionStorer
	if *postgresDSN != "" {
		pgStore, err := postgres.NewSessionStore(context.Background(), *postgresDSN)
		if err != nil {
			logger.Error("rgsd: postgres session store", "err", err)
			os.Exit(1)
		}
		defer pgStore.Close()
		sessionStore = pgStore
		logger.Info("rgsd: session store = postgres")
	} else {
		logger.Info("rgsd: session store = in-memory (no --postgres-dsn)")
	}

	roundsTotal := metrics.NewCounter("rgsd_rounds_total", "rounds run by this rgsd")
	betsTotal := metrics.NewCounter("rgsd_bets_total", "bets placed and accepted")
	betErrors := metrics.NewCounter("rgsd_bet_errors_total", "bets rejected (any reason)")
	roundDuration := metrics.NewHistogram("rgsd_round_duration_seconds",
		"wall clock from RunNextRound entry to manifest persisted",
		[]float64{1, 2, 5, 10, 20, 30, 60, 120})

	mgr, err := rgs.NewManager(rgs.ManagerConfig{
		Wallet:              &countingWallet{Wallet: walletImpl, accepted: betsTotal, rejected: betErrors},
		Store:               store,
		Sim:                 instrumentedSim(sim.Run, roundsTotal, roundDuration),
		GodotBin:            *godotBin,
		ProjectPath:         *projectPath,
		WorkRoot:            filepath.Join(*replayRoot, ".work"),
		BuyIn:               *buyIn,
		RTPBps:              uint32(*rtpBps),
		MaxMarbles:          *marbles,
		SimTimeout:          *simTimeout,
		SessionStore:        sessionStore,
		DefaultCurrency:     *defaultCurrency,
		SupportedCurrencies: strings.Split(*supportedCurrencies, ","),
	})
	if err != nil {
		logger.Error("NewManager", "err", err)
		os.Exit(1)
	}

	// ── Round scheduler (optional) ───────────────────────────────────────────
	// When --scheduler-enabled the scheduler drives rounds automatically on a
	// ticker; POST /v1/rounds/run still works but is redundant. When disabled
	// (the default) behaviour is identical to before this flag existed.
	var sched *rgs.Scheduler
	if *schedulerEnabled {
		sched = rgs.NewScheduler(rgs.SchedulerConfig{
			Mgr:           mgr,
			BetWindowSec:  *schedulerBetWindow,
			BetweenRounds: *schedulerBetweenRounds,
			Logger:        logger,
			OnRoundStarted: func(roundID uint64, trackID uint8) {
				logger.Info("scheduler: bet window open", "round_id", roundID, "track_id", trackID, "window", *schedulerBetWindow)
			},
			OnRoundFinished: func(_ *replay.Manifest, _ []rgs.SettlementOutcome) {
				// metrics / alerting hook — extend as needed
			},
		})
		logger.Info("rgsd: scheduler enabled",
			"bet_window", *schedulerBetWindow,
			"between_rounds", *schedulerBetweenRounds)
	} else {
		logger.Info("rgsd: scheduler disabled — use POST /v1/rounds/run to advance rounds")
	}

	apiMux := rgs.NewHTTPHandlerWithScheduler(mgr, sched).Routes()
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

	// ── Admin panel — separate listener so it can be firewalled independently.
	var adminAuthFunc admin.AuthFunc
	if *adminHMAC != "" {
		secret, err := hex.DecodeString(*adminHMAC)
		if err != nil {
			logger.Error("invalid admin-hmac-secret-hex", "err", err)
			os.Exit(2)
		}
		adminAuthFunc = admin.HMACAuthFunc(secret)
		logger.Info("rgsd: admin HMAC auth enabled")
	} else {
		logger.Warn("rgsd: admin HMAC auth disabled (no --admin-hmac-secret-hex). Bind to 127.0.0.1 in production.")
	}
	auditDataDir := filepath.Join(*replayRoot, "admin")
	auditLog, err := admin.NewAuditLog(auditDataDir)
	if err != nil {
		logger.Error("admin: audit log init", "err", err)
		os.Exit(1)
	}
	adminHandler, err := admin.NewHandler(admin.Config{
		Manager:  mgr,
		Wallet:   walletImpl,
		Auth:     adminAuthFunc,
		AuditLog: auditLog,
	})
	if err != nil {
		logger.Error("admin: NewHandler", "err", err)
		os.Exit(1)
	}
	adminSrv := &http.Server{
		Addr:              *adminAddr,
		Handler:           adminHandler,
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		logger.Info("rgsd: admin panel listening", "addr", *adminAddr)
		if err := adminSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("rgsd: admin serve", "err", err)
		}
	}()

	// ── Scheduler goroutine (when enabled) ───────────────────────────────────
	// Start() blocks until its context is cancelled, so we run it in a
	// dedicated goroutine. The context is derived from a cancel func that the
	// shutdown handler calls so the scheduler exits cleanly on SIGTERM.
	schedCtx, schedCancel := context.WithCancel(context.Background())
	if sched != nil {
		go func() {
			if err := sched.Start(schedCtx); err != nil {
				logger.Error("rgsd: scheduler exited with error", "err", err)
			}
		}()
	}

	// Graceful shutdown: wait for SIGINT/SIGTERM, then give in-flight
	// requests up to 20s to drain.
	shutdownCh := make(chan os.Signal, 1)
	signal.Notify(shutdownCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-shutdownCh
		logger.Info("rgsd: shutdown signal received, draining")
		// Cancel the scheduler first so it stops minting new rounds; it
		// will finish its current RunNextRound call before exiting.
		schedCancel()
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
		_ = adminSrv.Shutdown(ctx)
		_ = auditLog.Close()
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

func (c *countingWallet) Debit(playerID string, amount uint64, currency, txID string) error {
	if err := c.Wallet.Debit(playerID, amount, currency, txID); err != nil {
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
