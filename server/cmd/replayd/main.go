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
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
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
		//
		// Precompressed-file serving: Godot's Web export is dominated by
		// index.wasm (~37 MB raw). If an adjacent index.wasm.br / .wasm.gz
		// exists, serve that with Content-Encoding set; brotli gets the bundle
		// to ~6.5 MB, gzip to ~9.5 MB — both comfortably under the <20 MB
		// casino-iframe budget from PLAN.md §7.
		staticHandler := http.FileServer(http.Dir(*staticRoot))
		mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-store")
			if servePrecompressed(w, r, *staticRoot) {
				return
			}
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

// servePrecompressed checks for an adjacent .br / .gz file next to the
// requested path and, if present and the client accepts that encoding, serves
// it with the correct Content-Type + Content-Encoding. Returns true when the
// response has been handled (so the caller skips the plain FileServer).
//
// Range requests are intentionally not advertised on compressed responses:
// clients request byte ranges of the *uncompressed* resource, which a
// precompressed file can't satisfy. Browsers don't use Range on .wasm anyway,
// so this is fine.
func servePrecompressed(w http.ResponseWriter, r *http.Request, root string) bool {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return false
	}
	// Only compress the two big offenders. index.pck is already tiny;
	// audio worklets / icons are noise. Keeping the set explicit means a
	// surprise file type never gets wrongly encoded.
	ext := filepath.Ext(r.URL.Path)
	if ext != ".wasm" && ext != ".js" {
		return false
	}
	accept := r.Header.Get("Accept-Encoding")
	// Prefer brotli — better ratio on WASM — then gzip.
	for _, enc := range []struct {
		suffix   string
		encoding string
	}{
		{".br", "br"},
		{".gz", "gzip"},
	} {
		if !acceptEncodingAllows(accept, enc.encoding) {
			continue
		}
		// Join the on-disk path safely: Go's filepath.Join drops the leading
		// slash but does NOT cleanly reject traversal, so a separate guard
		// rejects any request whose cleaned path escapes root.
		cleaned := filepath.Clean(r.URL.Path)
		if strings.Contains(cleaned, "..") {
			return false
		}
		diskPath := filepath.Join(root, cleaned+enc.suffix)
		info, err := os.Stat(diskPath)
		if err != nil || info.IsDir() {
			continue
		}
		f, err := os.Open(diskPath)
		if err != nil {
			continue
		}
		defer f.Close()
		// Set Content-Type from the *uncompressed* extension so browsers
		// interpret the decoded bytes correctly (.wasm → application/wasm).
		if ext == ".wasm" {
			w.Header().Set("Content-Type", "application/wasm")
		} else {
			w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		}
		w.Header().Set("Content-Encoding", enc.encoding)
		w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
		w.Header().Set("Vary", "Accept-Encoding")
		if r.Method == http.MethodHead {
			return true
		}
		_, _ = io.Copy(w, f)
		return true
	}
	return false
}

// acceptEncodingAllows reports whether the Accept-Encoding header permits the
// named coding. It's not a full RFC 7231 §5.3.1 q-value parser — good enough
// for browsers, which either list an encoding or don't.
func acceptEncodingAllows(header, enc string) bool {
	for _, part := range strings.Split(header, ",") {
		token := strings.TrimSpace(part)
		if i := strings.Index(token, ";"); i >= 0 {
			// If a q=0 is explicitly set, the encoding is disallowed. We'd miss
			// the edge case of "br;q=0.0001" being effectively banned but the
			// browser practice is "br;q=0" for disable — which this catches.
			if strings.Contains(token[i:], "q=0") && !strings.Contains(token[i:], "q=0.") {
				continue
			}
			token = strings.TrimSpace(token[:i])
		}
		if strings.EqualFold(token, enc) {
			return true
		}
	}
	return false
}
