// Command replayd serves the replay store over HTTP. This is the archive
// side of M5 — clients can browse completed rounds, fetch manifests, and
// download replay.bin over ordinary GETs. Live tick streaming (WebSocket)
// will be a separate binary / endpoint set once the sim can emit ticks
// in real-time.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"github.com/onion-coding/marbles-game2/server/api"
	"github.com/onion-coding/marbles-game2/server/replay"
	"github.com/onion-coding/marbles-game2/server/stream"
)

func main() {
	var (
		addr       = flag.String("listen", ":8080", "HTTP listen address (archive + live WS)")
		streamTCP  = flag.String("stream-tcp", "", "optional: TCP address for sim stream ingress (e.g. :8088)")
		replayRoot = flag.String("replay-root", "", "replay store root (required)")
		staticRoot = flag.String("static-root", "", "optional: directory served at / (e.g. Godot Web export dir)")
	)
	flag.Parse()

	if *replayRoot == "" {
		log.Fatal("--replay-root is required")
	}
	store, err := replay.New(*replayRoot)
	if err != nil {
		log.Fatalf("replay.New: %v", err)
	}

	hub := stream.NewHub()
	var streamLn *stream.Listener
	if *streamTCP != "" {
		streamLn, err = stream.Listen(hub, *streamTCP)
		if err != nil {
			log.Fatalf("stream listen: %v", err)
		}
		log.Printf("stream TCP ingress on %s", streamLn.Addr())
	}

	// Compose: archive API at /rounds, live WS at /live/{id}, static files at /.
	// Same origin = no CORS juggling for the web client.
	mux := http.NewServeMux()
	apiHandler := api.New(store).Handler()
	mux.Handle("/rounds", apiHandler)
	mux.Handle("/rounds/", apiHandler)
	mux.Handle("/live", hub.ActiveListHandler())
	mux.Handle("/live/{id}", hub.WSHandler())
	if *staticRoot != "" {
		// Dev-friendly: no-store on static files so the browser always fetches
		// the latest game bundle after a re-export. Revisit when this starts
		// running behind a CDN.
		staticHandler := http.FileServer(http.Dir(*staticRoot))
		mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-store")
			staticHandler.ServeHTTP(w, r)
		}))
	}

	srv := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("replayd listening on %s (replay-root=%s)", *addr, *replayRoot)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server: %v", err)
		}
	}()

	<-ctx.Done()
	log.Print("shutting down…")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
	if streamLn != nil {
		_ = streamLn.Close()
	}
}
