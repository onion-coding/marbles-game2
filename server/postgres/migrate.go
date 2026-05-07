package postgres

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// RunMigrations applies every .sql file under the embedded migrations/
// directory in lexicographic order. It is idempotent — each file begins
// with CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS so re-running
// on an already-migrated database is a no-op.
//
// Call this before NewSessionStore in your startup path:
//
//	if err := postgres.RunMigrations(ctx, dsn); err != nil { ... }
func RunMigrations(ctx context.Context, dsn string) error {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return fmt.Errorf("postgres: migrations: connect: %w", err)
	}
	defer conn.Close(ctx)

	entries, err := fs.ReadDir(migrationsFS, "migrations")
	if err != nil {
		return fmt.Errorf("postgres: migrations: readdir: %w", err)
	}

	// Sort filenames so 001 < 002 < … is guaranteed even if embed.FS
	// returns them in a different order.
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	for _, name := range names {
		data, err := migrationsFS.ReadFile("migrations/" + name)
		if err != nil {
			return fmt.Errorf("postgres: migrations: read %s: %w", name, err)
		}
		if _, err := conn.Exec(ctx, string(data)); err != nil {
			return fmt.Errorf("postgres: migrations: exec %s: %w", name, err)
		}
	}
	return nil
}
