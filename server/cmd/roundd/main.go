// Command roundd runs N marble-race rounds end-to-end: generates a server seed,
// synthesizes mock participants, spawns the Godot sim (headless), computes
// payout, and persists a complete audit entry per round into the replay store.
//
// This is the "server runs rounds on a loop, each round leaves a complete
// audit trail" bar for M4. No network, no real players yet — M5 layers a
// WebSocket API on top and M5/M6 replace the mock buy-in with real bets.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/onion-coding/marbles-game2/server/replay"
	"github.com/onion-coding/marbles-game2/server/round"
	"github.com/onion-coding/marbles-game2/server/rtp"
	"github.com/onion-coding/marbles-game2/server/sim"
)

func main() {
	var (
		godotBin    = flag.String("godot-bin", "", "absolute path to the Godot executable (required)")
		projectPath = flag.String("project-path", "", "absolute path to the game/ directory (required)")
		replayRoot  = flag.String("replay-root", "", "where to store per-round audit entries (required)")
		workRoot    = flag.String("work-root", "", "scratch dir for sim specs/statuses; defaults to <replay-root>/.work")
		rounds      = flag.Int("rounds", 1, "number of rounds to run")
		marbles     = flag.Int("marbles", 20, "mock participants per round")
		rtpBps      = flag.Uint("rtp-bps", 9500, "return-to-player in basis points (9500 = 95%)")
		buyIn       = flag.Uint64("buy-in", 100, "mock buy-in per marble (arbitrary units)")
		timeout     = flag.Duration("sim-timeout", 60*time.Second, "hard cap per Godot subprocess")
		streamAddr  = flag.String("live-stream-addr", "", "optional: host:port of a replayd instance's TCP ingress; sim will stream live ticks there")
	)
	flag.Parse()

	if *godotBin == "" || *projectPath == "" || *replayRoot == "" {
		log.Fatalf("usage: roundd --godot-bin=... --project-path=... --replay-root=...\n%s", flagDefaults())
	}
	if *workRoot == "" {
		*workRoot = filepath.Join(*replayRoot, ".work")
	}

	store, err := replay.New(*replayRoot)
	if err != nil {
		log.Fatalf("replay.New: %v", err)
	}

	for i := 0; i < *rounds; i++ {
		if err := runOneRound(context.Background(), roundConfig{
			godotBin:       *godotBin,
			projectPath:    *projectPath,
			workRoot:       *workRoot,
			marbles:        *marbles,
			rtpBps:         uint32(*rtpBps),
			buyIn:          *buyIn,
			timeout:        *timeout,
			liveStreamAddr: *streamAddr,
			store:          store,
		}); err != nil {
			log.Printf("round %d failed: %v", i, err)
		}
	}
}

type roundConfig struct {
	godotBin       string
	projectPath    string
	workRoot       string
	marbles        int
	rtpBps         uint32
	buyIn          uint64
	timeout        time.Duration
	liveStreamAddr string
	store          *replay.Store
}

func runOneRound(ctx context.Context, cfg roundConfig) error {
	// 1. Fresh seed + round. Round ID is unix-nano to avoid collisions across runs.
	var seed [32]byte
	if _, err := rand.Read(seed[:]); err != nil {
		return fmt.Errorf("generate seed: %w", err)
	}
	roundID := uint64(time.Now().UnixNano())
	now := time.Now()
	r := round.New(roundID, seed, cfg.marbles, now)

	// 2. Buy-in — synthesize mock participants. A real implementation replaces
	//    this with whatever receives player registrations during the BUY_IN window.
	if err := r.OpenBuyIn(now); err != nil {
		return fmt.Errorf("OpenBuyIn: %w", err)
	}
	for i := 0; i < cfg.marbles; i++ {
		if err := r.AddParticipant(round.Participant{Name: fmt.Sprintf("player_%02d", i)}); err != nil {
			return fmt.Errorf("AddParticipant %d: %w", i, err)
		}
	}

	// 3. Start the race.
	if err := r.StartRace(time.Now()); err != nil {
		return fmt.Errorf("StartRace: %w", err)
	}

	// 4. Run the sim.
	participants := r.Participants()
	clientSeeds := make([]string, len(participants))
	for i, p := range participants {
		clientSeeds[i] = p.ClientSeed
	}
	workDir := filepath.Join(cfg.workRoot, fmt.Sprintf("round-%d", roundID))
	simRes, err := sim.Run(ctx, sim.Request{
		GodotBin:       cfg.godotBin,
		ProjectPath:    cfg.projectPath,
		WorkDir:        workDir,
		RoundID:        roundID,
		ServerSeed:     seed,
		ClientSeeds:    clientSeeds,
		Timeout:        cfg.timeout,
		Stderr:         os.Stderr,
		LiveStreamAddr: cfg.liveStreamAddr,
	})
	if err != nil {
		return fmt.Errorf("sim.Run: %w", err)
	}

	// 5. Close the round.
	finish := time.Now()
	if err := r.FinishRace(round.Result{WinnerIndex: simRes.WinnerMarbleIndex, FinishedAt: finish}, finish); err != nil {
		return fmt.Errorf("FinishRace: %w", err)
	}
	revealed, ok := r.RevealedSeed()
	if !ok {
		return fmt.Errorf("seed unexpectedly not revealed in SETTLE")
	}

	// 6. Compute payout.
	buyIns := make([]uint64, len(participants))
	for i := range buyIns {
		buyIns[i] = cfg.buyIn
	}
	prize, houseCut, err := rtp.Settle(rtp.Config{RTPBasisPoints: cfg.rtpBps}, buyIns, simRes.WinnerMarbleIndex)
	if err != nil {
		return fmt.Errorf("rtp.Settle: %w", err)
	}

	// 7. Persist the audit entry.
	replayFile, err := os.Open(simRes.ReplayPath)
	if err != nil {
		return fmt.Errorf("open replay: %w", err)
	}
	defer replayFile.Close()

	storeParts := make([]replay.Participant, len(participants))
	for i, p := range participants {
		storeParts[i] = replay.Participant{MarbleIndex: p.MarbleIndex, Name: p.Name, ClientSeed: p.ClientSeed}
	}
	commit := r.CommitHash()
	manifest := &replay.Manifest{
		RoundID:           roundID,
		ProtocolVersion:   2,
		TickRateHz:        simRes.TickRateHz,
		ServerSeedHashHex: hex.EncodeToString(commit[:]),
		ServerSeedHex:     hex.EncodeToString(revealed[:]),
		Participants:      storeParts,
		Winner:            replay.Winner{MarbleIndex: simRes.WinnerMarbleIndex, FinishTick: simRes.FinishTick},
	}
	if err := cfg.store.Save(manifest, replayFile); err != nil {
		return fmt.Errorf("store.Save: %w", err)
	}

	fmt.Printf("ROUND %d: winner=marble_%02d tick=%d prize=%d house=%d commit=%s\n",
		roundID, simRes.WinnerMarbleIndex, simRes.FinishTick, prize, houseCut, manifest.ServerSeedHashHex)
	return nil
}

func flagDefaults() string {
	sb := ""
	flag.VisitAll(func(f *flag.Flag) {
		sb += fmt.Sprintf("  --%s  %s (default %q)\n", f.Name, f.Usage, f.DefValue)
	})
	return sb
}
