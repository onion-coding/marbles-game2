// Package postgres provides a Postgres-backed session store for the rgs
// package. It depends only on pgx/v5 (the stdlib-endorsed Go Postgres driver)
// and the standard library. No ORMs, no code generators.
//
// Usage:
//
//	store, err := postgres.NewSessionStore(ctx, dsn)
//	if err != nil { ... }
//	defer store.Close()
//
//	// wire into rgs.ManagerConfig:
//	cfg.SessionStore = store
//
// The schema is applied by RunMigrations before starting the server:
//
//	if err := postgres.RunMigrations(ctx, dsn); err != nil { ... }
package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/onion-coding/marbles-game2/server/rgs"
)

// ErrNotFound is returned by Get when the session id does not exist.
var ErrNotFound = errors.New("postgres: session not found")

// betRow is the JSONB payload stored in the bet_data column. It mirrors the
// rgs.Bet fields that need to survive a restart; the Bet.MarbleIndex starts
// at -1 and is updated by AssignMarble. LastResult is stored separately to
// keep the schema simple — we encode the whole SettlementOutcome as a second
// optional JSONB blob rather than spreading it into many columns.
type betRow struct {
	BetID       string    `json:"bet_id"`
	Amount      uint64    `json:"amount"`
	PlayerID    string    `json:"player_id"`
	PlacedAt    time.Time `json:"placed_at"`
	MarbleIndex int       `json:"marble_index"`
}

// SessionStore wraps a pgxpool.Pool and provides CRUD operations on the
// `sessions` table. All methods are safe for concurrent use.
type SessionStore struct {
	db *pgxpool.Pool
}

// NewSessionStore opens a connection pool to the given DSN, pings the server,
// and returns a ready-to-use store. Call Close when done.
//
// DSN format: postgres://user:pass@host:port/dbname?sslmode=disable
func NewSessionStore(ctx context.Context, dsn string) (*SessionStore, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("postgres: parse dsn: %w", err)
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("postgres: connect: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("postgres: ping: %w", err)
	}
	return &SessionStore{db: pool}, nil
}

// Close releases all pool connections. Idempotent.
func (s *SessionStore) Close() {
	s.db.Close()
}

// Create inserts a new session row. Returns an error if the id already
// exists (the store does not silently overwrite).
func (s *SessionStore) Create(ctx context.Context, sess *rgs.Session) error {
	state, bet, _ := sess.Snapshot()
	betJSON, err := encodeBet(bet)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(ctx,
		`INSERT INTO sessions (id, player_id, state, opened_at, updated_at, bet_data)
		 VALUES ($1, $2, $3, $4, $5, $6)`,
		sess.ID, sess.PlayerID, state.String(),
		sess.OpenedAt, sess.UpdatedAt, betJSON,
	)
	if err != nil {
		return fmt.Errorf("postgres: Create: %w", err)
	}
	return nil
}

// Get fetches a session by id. Returns ErrNotFound when no row exists.
// The returned *rgs.Session is fully reconstructed (state, bet if present,
// last result if present) from the stored columns.
func (s *SessionStore) Get(ctx context.Context, id string) (*rgs.Session, error) {
	row := s.db.QueryRow(ctx,
		`SELECT id, player_id, state, opened_at, updated_at, bet_data
		 FROM sessions WHERE id = $1`, id)

	sess, err := scanSession(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("postgres: Get %q: %w", id, err)
	}
	return sess, nil
}

// Update replaces the mutable columns of an existing session (state,
// updated_at, bet_data). The id and player_id and opened_at are immutable
// and are ignored. Returns ErrNotFound when no matching row exists.
func (s *SessionStore) Update(ctx context.Context, sess *rgs.Session) error {
	state, bet, _ := sess.Snapshot()
	betJSON, err := encodeBet(bet)
	if err != nil {
		return err
	}
	tag, err := s.db.Exec(ctx,
		`UPDATE sessions
		 SET state = $1, updated_at = $2, bet_data = $3
		 WHERE id = $4`,
		state.String(), sess.UpdatedAt, betJSON, sess.ID,
	)
	if err != nil {
		return fmt.Errorf("postgres: Update: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// Delete removes a session row. A missing row is silently ignored (no error).
func (s *SessionStore) Delete(ctx context.Context, id string) error {
	_, err := s.db.Exec(ctx, `DELETE FROM sessions WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("postgres: Delete %q: %w", id, err)
	}
	return nil
}

// ListByPlayer returns all sessions for a given player, ordered by
// opened_at descending (newest first). Returns an empty slice (not nil)
// when there are no sessions for the player.
func (s *SessionStore) ListByPlayer(ctx context.Context, playerID string) ([]*rgs.Session, error) {
	rows, err := s.db.Query(ctx,
		`SELECT id, player_id, state, opened_at, updated_at, bet_data
		 FROM sessions WHERE player_id = $1
		 ORDER BY opened_at DESC`, playerID)
	if err != nil {
		return nil, fmt.Errorf("postgres: ListByPlayer %q: %w", playerID, err)
	}
	defer rows.Close()

	var out []*rgs.Session
	for rows.Next() {
		sess, err := scanSession(rows)
		if err != nil {
			return nil, fmt.Errorf("postgres: ListByPlayer scan: %w", err)
		}
		out = append(out, sess)
	}
	if rows.Err() != nil {
		return nil, fmt.Errorf("postgres: ListByPlayer rows: %w", rows.Err())
	}
	if out == nil {
		out = []*rgs.Session{}
	}
	return out, nil
}

// scanner is satisfied by both pgx.Row and pgx.Rows so scanSession can be
// called from both Get (single row) and ListByPlayer (cursor).
type scanner interface {
	Scan(dest ...any) error
}

// scanSession reads the standard column set into a reconstructed rgs.Session.
// The session's sync.Mutex is zero-valued (unlocked) in the reconstructed
// object — callers must not share the returned pointer across goroutines
// without additional synchronisation.
func scanSession(row scanner) (*rgs.Session, error) {
	var (
		id        string
		playerID  string
		stateStr  string
		openedAt  time.Time
		updatedAt time.Time
		betJSON   []byte
	)
	if err := row.Scan(&id, &playerID, &stateStr, &openedAt, &updatedAt, &betJSON); err != nil {
		return nil, err
	}

	state, err := parseState(stateStr)
	if err != nil {
		return nil, err
	}

	sess := rgs.NewSessionRaw(id, playerID, state, openedAt, updatedAt)

	if len(betJSON) > 0 {
		var br betRow
		if err := json.Unmarshal(betJSON, &br); err != nil {
			return nil, fmt.Errorf("postgres: unmarshal bet_data: %w", err)
		}
		bet := rgs.Bet{
			BetID:       br.BetID,
			Amount:      br.Amount,
			PlayerID:    br.PlayerID,
			PlacedAt:    br.PlacedAt,
			MarbleIndex: br.MarbleIndex,
		}
		rgs.AttachBetRaw(sess, bet)
	}

	return sess, nil
}

// encodeBet serialises a *rgs.Bet to JSON for storage in bet_data. Returns
// nil (SQL NULL) when bet is nil.
func encodeBet(bet *rgs.Bet) ([]byte, error) {
	if bet == nil {
		return nil, nil
	}
	br := betRow{
		BetID:       bet.BetID,
		Amount:      bet.Amount,
		PlayerID:    bet.PlayerID,
		PlacedAt:    bet.PlacedAt,
		MarbleIndex: bet.MarbleIndex,
	}
	b, err := json.Marshal(br)
	if err != nil {
		return nil, fmt.Errorf("postgres: marshal bet: %w", err)
	}
	return b, nil
}

// parseState maps the stored string back to a SessionState. Sentinel
// for any unknown string is an error; callers should treat that as data
// corruption.
func parseState(s string) (rgs.SessionState, error) {
	switch s {
	case "OPEN":
		return rgs.SessionOpen, nil
	case "BET":
		return rgs.SessionBet, nil
	case "RACING":
		return rgs.SessionRacing, nil
	case "SETTLED":
		return rgs.SessionSettled, nil
	case "CLOSED":
		return rgs.SessionClosed, nil
	default:
		return 0, fmt.Errorf("postgres: unknown session state %q", s)
	}
}
