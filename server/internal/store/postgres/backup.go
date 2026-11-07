package postgres

import (
	"context"
	"time"

	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
)

func (s *Store) PutBackup(ctx context.Context, acct ids.ID, key string, size uint64, now time.Time) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO backups(account_id, object_key, size_bytes, created_at) VALUES($1,$2,$3,$4)`, acct, key, int64(size), now)
	return err
}

func (s *Store) Backups(ctx context.Context, acct ids.ID, limit int) ([]store.BackupRow, error) {
	rows, err := s.pool.Query(ctx, `SELECT object_key, size_bytes, created_at FROM backups WHERE account_id=$1 ORDER BY created_at DESC LIMIT $2`, acct, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []store.BackupRow
	for rows.Next() {
		var r store.BackupRow
		var size int64
		var at time.Time
		if err := rows.Scan(&r.ObjectKey, &size, &at); err != nil {
			return nil, err
		}
		r.Size, r.CreatedMs = uint64(size), uint64(at.UnixMilli())
		out = append(out, r)
	}
	return out, rows.Err()
}
