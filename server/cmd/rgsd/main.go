// Command rgsd is the operator-facing daemon. It wraps the rgs.Manager
// in an HTTP server (rgs.HTTPHandler) and the standard sim/replay/rtp
// stack so an operator (or a demo "MockOperator" client) can drive
// player sessions end-to-end.
//
// This is the demo path for the M9 RGS integration scaffold. A real
// deployment would:
//   - run multiple rgsd instances behind a load balancer
//   - swap MockWallet for the operator's actual wallet client
//   - add auth middleware (signed requests, rate limit, IP allow-lists)
//   - move the replay store to durable storage (S3/GCS) instead of disk
//
// Usage:
//
//	rgsd \
//	  --godot-bin=...          \
//	  --project-path=...       \
//	  --replay-root=tmp/rgsd   \
//	  --addr=:8090             \
//	  --rtp-bps=9500
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/onion-coding/marbles-game2/server/replay"
	"github.com/onion-coding/marbles-game2/server/rgs"
	"github.com/onion-coding/marbles-game2/server/sim"
)

func main() {
	var (
		godotBin    = flag.String("godot-bin", "", "absolute path to Godot executable (required)")
		projectPath = flag.String("project-path", "", "absolute path to game/ project dir (required)")
		replayRoot  = flag.String("replay-root", "", "where to persist per-round audit entries (required)")
		addr        = flag.String("addr", ":8090", "HTTP listen address")
		rtpBps      = flag.Uint("rtp-bps", 9500, "configured return-to-player in basis points")
		buyIn       = flag.Uint64("buy-in", 100, "stake per filled seat (mock; bettor stakes come from the bet endpoint)")
		marbles     = flag.Int("marbles", 20, "marbles per round")
		simTimeout  = flag.Duration("sim-timeout", 60*time.Second, "hard cap per Godot subprocess")
		seedAlice   = flag.Uint64("seed-alice", 0, "if set, seed an in-memory wallet for player 'alice' with this balance for demo clients")
	)
	flag.Parse()

	if *godotBin == "" || *projectPath == "" || *replayRoot == "" {
		flag.Usage()
		log.Fatalf("rgsd: --godot-bin, --project-path, and --replay-root are required")
	}

	store, err := replay.New(*replayRoot)
	if err != nil {
		log.Fatalf("replay.New: %v", err)
	}
	wallet := rgs.NewMockWallet()
	if *seedAlice > 0 {
		wallet.SetBalance("alice", *seedAlice)
		log.Printf("rgsd: seeded MockWallet alice=%d", *seedAlice)
	}

	mgr, err := rgs.NewManager(rgs.ManagerConfig{
		Wallet:      wallet,
		Store:       store,
		Sim:         sim.Run,
		GodotBin:    *godotBin,
		ProjectPath: *projectPath,
		WorkRoot:    filepath.Join(*replayRoot, ".work"),
		BuyIn:       *buyIn,
		RTPBps:      uint32(*rtpBps),
		MaxMarbles:  *marbles,
		SimTimeout:  *simTimeout,
	})
	if err != nil {
		log.Fatalf("NewManager: %v", err)
	}

	mux := rgs.NewHTTPHandler(mgr).Routes()
	log.Printf("rgsd: listening on %s", *addr)
	srv := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintf(os.Stderr, "rgsd: %v\n", err)
		os.Exit(1)
	}
}
