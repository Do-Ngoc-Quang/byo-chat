package postgres

import (
	"context"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
)

func (s *Store) ListDevices(ctx context.Context, acct ids.ID) ([]store.DeviceRow, error) {
	rows, err := s.pool.Query(ctx, `SELECT device_id, platform, device_name, created_at, last_seen_at, revoked_at IS NOT NULL
		FROM devices WHERE account_id=$1 ORDER BY created_at`, acct)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []store.DeviceRow
	for rows.Next() {
		var r store.DeviceRow
		var plat int16
		var created time.Time
		var seen *time.Time
		if err := rows.Scan(&r.DeviceID, &plat, &r.Name, &created, &seen, &r.Revoked); err != nil {
			return nil, err
		}
		r.Platform, r.CreatedMs = chatv1.Platform(plat), uint64(created.UnixMilli())
		if seen != nil {
			r.LastSeenMs = uint64(seen.UnixMilli())
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) RevokeAccountDevice(ctx context.Context, acct, device ids.ID, statement []byte, now time.Time) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `UPDATE devices SET revoked_at=$3 WHERE account_id=$1 AND device_id=$2 AND revoked_at IS NULL`, acct, device, now)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		var revoked bool
		if err := tx.QueryRow(ctx, `SELECT revoked_at IS NOT NULL FROM devices WHERE account_id=$1 AND device_id=$2`, acct, device).Scan(&revoked); err != nil {
			return nf(err)
		}
		return store.ErrExists
	}
	for _, q := range []string{
		`DELETE FROM key_packages WHERE device_id=$1`,
		`DELETE FROM refresh_tokens WHERE device_id=$1`,
	} {
		if _, err := tx.Exec(ctx, q, device); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO revocations(account_id, device_id, statement, revoked_at) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`,
		acct, device, statement, now); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
