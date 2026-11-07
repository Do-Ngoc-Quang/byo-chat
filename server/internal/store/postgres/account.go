package postgres

import (
	"bytes"
	"context"
	"errors"
	"time"

	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

var _ store.AccountStore = (*Store)(nil)

func (s *Store) UpsertAccount(ctx context.Context, contactHash []byte, newID ids.ID) (ids.ID, bool, error) {
	tag, err := s.pool.Exec(ctx, `INSERT INTO accounts(account_id, contact_hash) VALUES($1,$2) ON CONFLICT (contact_hash) DO NOTHING`, newID, contactHash)
	if err != nil {
		return ids.ID{}, false, err
	}
	var id ids.ID
	err = s.pool.QueryRow(ctx, `SELECT account_id FROM accounts WHERE contact_hash=$1`, contactHash).Scan(&id)
	return id, tag.RowsAffected() == 1, err
}

func (s *Store) AccountByContact(ctx context.Context, contactHash []byte) (ids.ID, error) {
	var id ids.ID
	err := s.pool.QueryRow(ctx, `SELECT account_id FROM accounts WHERE contact_hash=$1`, contactHash).Scan(&id)
	return id, nf(err)
}

func (s *Store) IdentityKey(ctx context.Context, acct ids.ID) ([]byte, error) {
	var k []byte
	err := s.pool.QueryRow(ctx, `SELECT identity_key FROM accounts WHERE account_id=$1`, acct).Scan(&k)
	return k, nf(err)
}

func (s *Store) PutOTP(ctx context.Context, c store.OTPChallenge) error {
	// Dọn mục hết hạn từ lâu cùng lúc ghi (rẻ nhờ chỉ mục expires_at).
	if _, err := s.pool.Exec(ctx, `DELETE FROM otp_challenges WHERE expires_at < $1`, c.CreatedAt.Add(-time.Hour)); err != nil {
		return err
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO otp_challenges(challenge_id, contact_hash, code_hash, attempts, created_at, expires_at) VALUES($1,$2,$3,$4,$5,$6)`,
		c.ID, c.ContactHash, c.CodeHash, c.Attempts, c.CreatedAt, c.ExpiresAt)
	return err
}

const otpCols = `challenge_id, contact_hash, code_hash, attempts, created_at, expires_at`

func scanOTP(row pgx.Row) (store.OTPChallenge, error) {
	var c store.OTPChallenge
	err := row.Scan(&c.ID, &c.ContactHash, &c.CodeHash, &c.Attempts, &c.CreatedAt, &c.ExpiresAt)
	return c, nf(err)
}

func (s *Store) LatestOTP(ctx context.Context, contactHash []byte) (store.OTPChallenge, error) {
	return scanOTP(s.pool.QueryRow(ctx, `SELECT `+otpCols+` FROM otp_challenges WHERE contact_hash=$1 ORDER BY created_at DESC LIMIT 1`, contactHash))
}

func (s *Store) GetOTP(ctx context.Context, id ids.ID) (store.OTPChallenge, error) {
	return scanOTP(s.pool.QueryRow(ctx, `SELECT `+otpCols+` FROM otp_challenges WHERE challenge_id=$1`, id))
}

func (s *Store) IncOTPAttempts(ctx context.Context, id ids.ID) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `UPDATE otp_challenges SET attempts = attempts + 1 WHERE challenge_id=$1 RETURNING attempts`, id).Scan(&n)
	return n, nf(err)
}

func (s *Store) DeleteOTP(ctx context.Context, id ids.ID) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM otp_challenges WHERE challenge_id=$1`, id)
	return err
}

func (s *Store) PutTicket(ctx context.Context, hash []byte, acct ids.ID, isNew bool, expires time.Time) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO session_tickets(ticket_hash, account_id, is_new, expires_at) VALUES($1,$2,$3,$4)`, hash, acct, isNew, expires)
	return err
}

func (s *Store) TicketAccount(ctx context.Context, hash []byte, now time.Time) (ids.ID, bool, error) {
	var a ids.ID
	var isNew bool
	err := s.pool.QueryRow(ctx, `SELECT account_id, is_new FROM session_tickets WHERE ticket_hash=$1 AND used_at IS NULL AND expires_at > $2`, hash, now).Scan(&a, &isNew)
	if errors.Is(err, pgx.ErrNoRows) {
		return a, false, store.ErrTicketInvalid
	}
	return a, isNew, err
}

func isUnique(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "23505"
}

func (s *Store) RegisterDevice(ctx context.Context, r store.RegisterDeviceReq) (ids.ID, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return ids.ID{}, err
	}
	defer tx.Rollback(ctx)
	var acct ids.ID
	err = tx.QueryRow(ctx, `UPDATE session_tickets SET used_at=$2 WHERE ticket_hash=$1 AND used_at IS NULL AND expires_at > $2 RETURNING account_id`, r.TicketHash, r.Now).Scan(&acct)
	if errors.Is(err, pgx.ErrNoRows) {
		return acct, store.ErrTicketInvalid
	} else if err != nil {
		return acct, err
	}
	var cur []byte
	if err := tx.QueryRow(ctx, `SELECT identity_key FROM accounts WHERE account_id=$1 FOR UPDATE`, acct).Scan(&cur); err != nil {
		return acct, nf(err)
	}
	if !bytes.Equal(cur, r.ExpectIdentity) {
		return acct, store.ErrIdentityMismatch
	}
	if len(r.NewIdentity) > 0 {
		if _, err := tx.Exec(ctx, `UPDATE accounts SET identity_key=$2 WHERE account_id=$1`, acct, r.NewIdentity); err != nil {
			return acct, err
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO devices(account_id, device_id, platform, device_name, public_key, credential) VALUES($1,$2,$3,$4,$5,$6)`,
		acct, r.Device, int16(r.Platform), r.Name, r.PublicKey, r.Credential); err != nil {
		if isUnique(err) {
			return acct, store.ErrExists
		}
		return acct, err
	}
	if err := putKPs(ctx, tx, r.Device, r.KeyPackages); err != nil {
		return acct, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO refresh_tokens(token_hash, device_id, expires_at) VALUES($1,$2,$3)`, r.RefreshHash, r.Device, r.RefreshExpires); err != nil {
		return acct, err
	}
	return acct, tx.Commit(ctx)
}

func (s *Store) RotateRefresh(ctx context.Context, device ids.ID, oldHash, newHash []byte, newExpires, now time.Time) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `DELETE FROM refresh_tokens WHERE token_hash=$1 AND device_id=$2 AND expires_at > $3`, oldHash, device, now)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return store.ErrNotFound
	}
	if _, err := tx.Exec(ctx, `INSERT INTO refresh_tokens(token_hash, device_id, expires_at) VALUES($1,$2,$3)`, newHash, device, newExpires); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func putKPs(ctx context.Context, e execer, device ids.ID, kps []store.KeyPackage) error {
	for _, k := range kps {
		if _, err := e.Exec(ctx, `INSERT INTO key_packages(device_id, kp_id, blob, last_resort, expires_at) VALUES($1,$2,$3,$4,$5)`,
			device, ids.New(), k.Blob, k.LastResort, k.ExpiresAt); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) PutKeyPackages(ctx context.Context, device ids.ID, kps []store.KeyPackage) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := putKPs(ctx, tx, device, kps); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Store) CountKeyPackages(ctx context.Context, device ids.ID, now time.Time) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `SELECT count(*) FROM key_packages WHERE device_id=$1 AND NOT last_resort AND expires_at > $2`, device, now).Scan(&n)
	return n, err
}

func (s *Store) TakeKeyPackage(ctx context.Context, device ids.ID, now time.Time) ([]byte, bool, error) {
	var blob []byte
	// SKIP LOCKED: hai người lấy cùng lúc không bao giờ nhận cùng một gói.
	err := s.pool.QueryRow(ctx, `DELETE FROM key_packages WHERE (device_id, kp_id) = (
		SELECT device_id, kp_id FROM key_packages WHERE device_id=$1 AND NOT last_resort AND expires_at > $2
		ORDER BY expires_at LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING blob`, device, now).Scan(&blob)
	if err == nil {
		return blob, false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, false, err
	}
	err = s.pool.QueryRow(ctx, `SELECT blob FROM key_packages WHERE device_id=$1 AND last_resort AND expires_at > $2 LIMIT 1`, device, now).Scan(&blob)
	return blob, true, nf(err)
}

func (s *Store) AccountKeys(ctx context.Context, acct ids.ID) ([]byte, []store.DeviceKeys, [][]byte, error) {
	var ident []byte
	if err := s.pool.QueryRow(ctx, `SELECT identity_key FROM accounts WHERE account_id=$1`, acct).Scan(&ident); err != nil {
		return nil, nil, nil, nf(err)
	}
	rows, err := s.pool.Query(ctx, `SELECT device_id, credential FROM devices WHERE account_id=$1 AND revoked_at IS NULL AND credential IS NOT NULL ORDER BY created_at`, acct)
	if err != nil {
		return nil, nil, nil, err
	}
	var devs []store.DeviceKeys
	for rows.Next() {
		var d store.DeviceKeys
		if err := rows.Scan(&d.DeviceID, &d.Credential); err != nil {
			rows.Close()
			return nil, nil, nil, err
		}
		devs = append(devs, d)
	}
	rows.Close()
	if rows.Err() != nil {
		return nil, nil, nil, rows.Err()
	}
	rr, err := s.pool.Query(ctx, `SELECT statement FROM revocations WHERE account_id=$1 ORDER BY revoked_at`, acct)
	if err != nil {
		return nil, nil, nil, err
	}
	defer rr.Close()
	var revs [][]byte
	for rr.Next() {
		var b []byte
		if err := rr.Scan(&b); err != nil {
			return nil, nil, nil, err
		}
		revs = append(revs, b)
	}
	return ident, devs, revs, rr.Err()
}
