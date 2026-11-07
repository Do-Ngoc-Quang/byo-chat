// Package postgres: MetaStore trên PostgreSQL (pgx). Schema ở server/migrations.
package postgres

import (
	"bytes"
	"context"
	"embed"
	"errors"
	"fmt"
	"sort"
	"strings"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Migrations là các file SQL nhúng sẵn, áp dụng theo thứ tự tên.
//
//go:embed migrations/*.sql
var migrationFS embed.FS

type Store struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Store { return &Store{pool: pool} }

// Migrate áp dụng các file chưa chạy, mỗi file một giao dịch, ghi vào schema_migrations.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	if _, err := pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return err
	}
	ents, err := migrationFS.ReadDir("migrations")
	if err != nil {
		return err
	}
	names := make([]string, 0, len(ents))
	for _, e := range ents {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, n := range names {
		var done bool
		if err := pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE name=$1)`, n).Scan(&done); err != nil {
			return err
		}
		if done {
			continue
		}
		sql, _ := migrationFS.ReadFile("migrations/" + n)
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		// Khóa tư vấn: nhiều node khởi động cùng lúc chỉ một node chạy migration.
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(727274)`); err != nil {
			tx.Rollback(ctx)
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE name=$1)`, n).Scan(&done); err != nil {
			tx.Rollback(ctx)
			return err
		}
		if !done {
			if _, err := tx.Exec(ctx, string(sql)); err != nil {
				tx.Rollback(ctx)
				return fmt.Errorf("migration %s: %w", n, err)
			}
			if _, err := tx.Exec(ctx, `INSERT INTO schema_migrations(name) VALUES($1)`, n); err != nil {
				tx.Rollback(ctx)
				return err
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
	}
	return nil
}

func nf(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return store.ErrNotFound
	}
	return err
}

// AddDevice đăng ký thiết bị tối thiểu (dùng bởi test và công cụ dev; RegisterDevice thật ở giai đoạn 3).
func (s *Store) AddDevice(ctx context.Context, d store.DeviceInfo) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `INSERT INTO accounts(account_id, contact_hash) VALUES($1,$2) ON CONFLICT DO NOTHING`,
		d.AccountID, d.AccountID.Bytes()); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO devices(account_id, device_id, platform, public_key) VALUES($1,$2,$3,'\x00')
		ON CONFLICT (device_id) DO NOTHING`, d.AccountID, d.DeviceID, int16(d.Platform)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Store) RevokeDevice(ctx context.Context, id ids.ID) error {
	_, err := s.pool.Exec(ctx, `UPDATE devices SET revoked_at = now() WHERE device_id=$1 AND revoked_at IS NULL`, id)
	return err
}

func (s *Store) GetDevice(ctx context.Context, id ids.ID) (store.DeviceInfo, error) {
	var d store.DeviceInfo
	var plat int16
	var revoked bool
	err := s.pool.QueryRow(ctx, `SELECT device_id, account_id, platform, revoked_at IS NOT NULL FROM devices WHERE device_id=$1`, id).
		Scan(&d.DeviceID, &d.AccountID, &plat, &revoked)
	d.Platform, d.Revoked = chatv1.Platform(plat), revoked
	return d, nf(err)
}

func (s *Store) DevicesOfAccounts(ctx context.Context, accts []ids.ID) ([]store.DeviceInfo, error) {
	rows, err := s.pool.Query(ctx, `SELECT device_id, account_id, platform FROM devices WHERE account_id = ANY($1) AND revoked_at IS NULL`, accts)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []store.DeviceInfo
	for rows.Next() {
		var d store.DeviceInfo
		var plat int16
		if err := rows.Scan(&d.DeviceID, &d.AccountID, &plat); err != nil {
			return nil, err
		}
		d.Platform = chatv1.Platform(plat)
		out = append(out, d)
	}
	return out, rows.Err()
}

func pair(a, b ids.ID) (lo, hi ids.ID) {
	if bytes.Compare(a[:], b[:]) > 0 {
		a, b = b, a
	}
	return a, b
}

func (s *Store) CreateConversation(ctx context.Context, id ids.ID, kind chatv1.ConvKind, groupID []byte, members []*chatv1.Member) (ids.ID, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return ids.ID{}, false, err
	}
	defer tx.Rollback(ctx)

	// Gửi lại cùng group_id: trả conv_id đã cấp.
	var old ids.ID
	if err := tx.QueryRow(ctx, `SELECT conv_id FROM conversations WHERE mls_group_id=$1`, groupID).Scan(&old); err == nil {
		return old, false, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return ids.ID{}, false, err
	}
	accts := make([]ids.ID, len(members))
	for i, m := range members {
		if accts[i], err = ids.FromBytes(m.AccountId); err != nil {
			return ids.ID{}, false, err
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO conversations(conv_id, kind, mls_group_id) VALUES($1,$2,$3)`, id, int16(kind), groupID); err != nil {
		return ids.ID{}, false, err
	}
	if kind == chatv1.ConvKind_CONV_KIND_DIRECT {
		if len(accts) != 2 {
			return ids.ID{}, false, errors.New("1-1 cần hai thành viên")
		}
		lo, hi := pair(accts[0], accts[1])
		// Cặp đã có hội thoại: cạnh tranh an toàn nhờ khóa chính; thua thì trả hội thoại cũ.
		tag, err := tx.Exec(ctx, `INSERT INTO direct_pairs VALUES($1,$2,$3) ON CONFLICT DO NOTHING`, lo, hi, id)
		if err != nil {
			return ids.ID{}, false, err
		}
		if tag.RowsAffected() == 0 {
			var existing ids.ID
			if err := tx.QueryRow(ctx, `SELECT conv_id FROM direct_pairs WHERE account_lo=$1 AND account_hi=$2`, lo, hi).Scan(&existing); err != nil {
				return ids.ID{}, false, err
			}
			return existing, true, nil // rollback: không ghi gì
		}
	}
	for i, m := range members {
		if _, err := tx.Exec(ctx, `INSERT INTO members_by_conv(conv_id, account_id, role) VALUES($1,$2,$3)`, id, accts[i], int16(m.Role)); err != nil {
			return ids.ID{}, false, err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO convs_by_account(account_id, conv_id) VALUES($1,$2)`, accts[i], id); err != nil {
			return ids.ID{}, false, err
		}
	}
	return id, false, tx.Commit(ctx)
}

func (s *Store) GetMember(ctx context.Context, conv, acct ids.ID) (store.MemberRow, error) {
	r := store.MemberRow{AccountID: acct}
	var role int16
	err := s.pool.QueryRow(ctx, `SELECT role, leaving FROM members_by_conv WHERE conv_id=$1 AND account_id=$2`, conv, acct).Scan(&role, &r.Leaving)
	r.Role = chatv1.Role(role)
	return r, nf(err)
}

func (s *Store) Members(ctx context.Context, conv ids.ID) ([]store.MemberRow, error) {
	rows, err := s.pool.Query(ctx, `SELECT account_id, role, leaving FROM members_by_conv WHERE conv_id=$1`, conv)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []store.MemberRow
	for rows.Next() {
		var r store.MemberRow
		var role int16
		if err := rows.Scan(&r.AccountID, &role, &r.Leaving); err != nil {
			return nil, err
		}
		r.Role = chatv1.Role(role)
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) ApplyMembership(ctx context.Context, conv ids.ID, added []*chatv1.Member, removed []ids.ID, roles []*chatv1.Member) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for _, m := range added {
		a, err := ids.FromBytes(m.AccountId)
		if err != nil {
			return err
		}
		// Idempotent: thêm lại giữ nguyên vai trò đã có.
		if _, err := tx.Exec(ctx, `INSERT INTO members_by_conv(conv_id, account_id, role) VALUES($1,$2,$3) ON CONFLICT DO NOTHING`, conv, a, int16(m.Role)); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO convs_by_account(account_id, conv_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, a, conv); err != nil {
			return err
		}
	}
	for _, a := range removed {
		if _, err := tx.Exec(ctx, `DELETE FROM members_by_conv WHERE conv_id=$1 AND account_id=$2`, conv, a); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM convs_by_account WHERE account_id=$1 AND conv_id=$2`, a, conv); err != nil {
			return err
		}
	}
	for _, m := range roles {
		a, err := ids.FromBytes(m.AccountId)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE members_by_conv SET role=$3 WHERE conv_id=$1 AND account_id=$2`, conv, a, int16(m.Role)); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func (s *Store) PutGroupInfo(ctx context.Context, conv ids.ID, epoch uint64, gi []byte) error {
	// Không lùi epoch: job cũ chạy lại sau job mới không ghi đè.
	_, err := s.pool.Exec(ctx, `INSERT INTO group_info(conv_id, epoch, blob) VALUES($1,$2,$3)
		ON CONFLICT (conv_id) DO UPDATE SET epoch=EXCLUDED.epoch, blob=EXCLUDED.blob WHERE group_info.epoch < EXCLUDED.epoch`,
		conv, int64(epoch), gi)
	return err
}

func (s *Store) GetGroupInfo(ctx context.Context, conv ids.ID) (uint64, []byte, error) {
	var ep int64
	var b []byte
	err := s.pool.QueryRow(ctx, `SELECT epoch, blob FROM group_info WHERE conv_id=$1`, conv).Scan(&ep, &b)
	return uint64(ep), b, nf(err)
}

func (s *Store) ConversationKind(ctx context.Context, conv ids.ID) (chatv1.ConvKind, error) {
	var k int16
	err := s.pool.QueryRow(ctx, `SELECT kind FROM conversations WHERE conv_id=$1`, conv).Scan(&k)
	return chatv1.ConvKind(k), nf(err)
}

func (s *Store) ListConversations(ctx context.Context, acct ids.ID) ([]ids.ID, error) {
	rows, err := s.pool.Query(ctx, `SELECT conv_id FROM convs_by_account WHERE account_id=$1 ORDER BY last_activity DESC`, acct)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ids.ID
	for rows.Next() {
		var c ids.ID
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

var _ = strings.TrimSpace
