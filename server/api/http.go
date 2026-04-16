// Package api serves the replay store over HTTP so clients (web or native)
// can browse and download completed rounds. This is the archive side of M5;
// live tick streaming will be added as a WebSocket endpoint later.
//
// Route layout is deliberately shallow and cache-friendly:
//
//	GET /rounds                  → JSON {"round_ids": [...]} (ascending)
//	GET /rounds/{id}             → manifest.json for one round
//	GET /rounds/{id}/replay.bin  → raw replay bytes (application/octet-stream)
//
// The manifest includes the commit hash, revealed seed, participants, and
// replay SHA-256, so a client can verify integrity before rendering.
package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"

	"github.com/onion-coding/marbles-game2/server/replay"
)

type Server struct {
	store *replay.Store
}

func New(store *replay.Store) *Server {
	return &Server{store: store}
}

// Handler returns a ServeMux wired to the archive endpoints. The caller owns
// the http.Server — pick the listen address, timeouts, and TLS there.
// CORS is permissive (`*`): the archive is public, read-only, and intended
// to be fetched from any frontend origin (Godot Web exports, mobile wrappers,
// verifier tools). Tighten if a future endpoint ever mutates state.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /rounds", s.listRounds)
	mux.HandleFunc("GET /rounds/{id}", s.getManifest)
	mux.HandleFunc("GET /rounds/{id}/replay.bin", s.getReplay)
	return corsMiddleware(mux)
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Range, If-None-Match")
		w.Header().Set("Access-Control-Expose-Headers", "ETag, Content-Length, Content-Range, Accept-Ranges")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) listRounds(w http.ResponseWriter, _ *http.Request) {
	ids, err := s.store.List()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "list_failed", err.Error())
		return
	}
	// Round IDs are unix-nanoseconds (~19 digits) which overflow JSON's number
	// precision for any consumer parsing them as float64 (Godot's JSON.parse,
	// JavaScript's Number, etc). Serialize as strings so every client sees the
	// exact ID.
	strIDs := make([]string, len(ids))
	for i, id := range ids {
		strIDs[i] = strconv.FormatUint(id, 10)
	}
	writeJSON(w, http.StatusOK, map[string]any{"round_ids": strIDs})
}

func (s *Server) getManifest(w http.ResponseWriter, r *http.Request) {
	id, err := parseRoundID(r.PathValue("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "bad_round_id", err.Error())
		return
	}
	m, _, err := s.store.Load(id)
	if err != nil {
		if errors.Is(err, replay.ErrRoundMissing) {
			writeJSONError(w, http.StatusNotFound, "round_missing", err.Error())
			return
		}
		writeJSONError(w, http.StatusInternalServerError, "load_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, m)
}

func (s *Server) getReplay(w http.ResponseWriter, r *http.Request) {
	id, err := parseRoundID(r.PathValue("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "bad_round_id", err.Error())
		return
	}
	m, path, err := s.store.Load(id)
	if err != nil {
		if errors.Is(err, replay.ErrRoundMissing) {
			writeJSONError(w, http.StatusNotFound, "round_missing", err.Error())
			return
		}
		writeJSONError(w, http.StatusInternalServerError, "load_failed", err.Error())
		return
	}
	f, err := os.Open(path)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "replay_open_failed", err.Error())
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "replay_stat_failed", err.Error())
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
	// Clients that trust this server can skip re-downloading unchanged replays.
	// Manifest SHA acts as an ETag; archives are immutable so Cache-Control is long-lived.
	w.Header().Set("ETag", `"`+m.ReplaySHA256Hex+`"`)
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	// ServeContent handles Range requests cleanly — lets clients resume or skip.
	http.ServeContent(w, r, "replay.bin", info.ModTime(), f)
}

func parseRoundID(s string) (uint64, error) {
	if s == "" {
		return 0, errors.New("round id is empty")
	}
	id, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("round id %q is not a uint64: %w", s, err)
	}
	return id, nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func writeJSONError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"error": code, "message": msg})
}
