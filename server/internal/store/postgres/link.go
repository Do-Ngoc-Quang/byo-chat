package postgres

import (
	"context"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
)

func (s *Store) PutLink(ctx context.Context, l store.DeviceLink) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO device_links(link_id, short_code, platform, device_name, device_public_key, ephemeral_pubkey, expires_at)
		VALUES($1,$2,$3,$4,$5,$6,$7)`, l.ID, l.ShortCode, int16(l.Platform), l.Name, l.DevicePub, l.Ephemeral, l.ExpiresAt)
	if isUnique(err) {
		return store.ErrExists
	}
	return err
}

func (s *Store) GetLink(ctx context.Context, id ids.ID, now time.Time) (store.DeviceLink, error) {
	l := store.DeviceLink{ID: id}
	var plat int16
	var acct *ids.ID
	err := s.pool.QueryRow(ctx, `SELECT short_code, platform, device_name, device_public_key, ephemeral_pubkey, account_id, credential, sealed_bundle, expires_at
		FROM device_links WHERE link_id=$1 AND expires_at > $2`, id, now).
		Scan(&l.ShortCode, &plat, &l.Name, &l.DevicePub, &l.Ephemeral, &acct, &l.Credential, &l.Sealed, &l.ExpiresAt)
	if err != nil {
		return l, nf(err)
	}
	l.Platform = chatv1.Platform(plat)
	if acct != nil {
		l.Account = *acct
	}
	return l, nil
}

func (s *Store) ApproveLink(ctx context.Context, id, acct ids.ID, cred, sealed []byte, now time.Time) error {
	tag, err := s.pool.Exec(ctx, `UPDATE device_links SET account_id=$2, credential=$3, sealed_bundle=$4
		WHERE link_id=$1 AND expires_at > $5 AND account_id IS NULL`, id, acct, cred, sealed, now)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 1 {
		return nil
	}
	if _, err := s.GetLink(ctx, id, now); err != nil {
		return err // ErrNotFound
	}
	return store.ErrExists
}

func (s *Store) TakeApprovedLink(ctx context.Context, id ids.ID, now time.Time) (store.DeviceLink, error) {
	l := store.DeviceLink{ID: id}
	var plat int16
	err := s.pool.QueryRow(ctx, `DELETE FROM device_links WHERE link_id=$1 AND expires_at > $2 AND account_id IS NOT NULL
		RETURNING short_code, platform, device_name, device_public_key, ephemeral_pubkey, account_id, credential, sealed_bundle, expires_at`, id, now).
		Scan(&l.ShortCode, &plat, &l.Name, &l.DevicePub, &l.Ephemeral, &l.Account, &l.Credential, &l.Sealed, &l.ExpiresAt)
	l.Platform = chatv1.Platform(plat)
	return l, nf(err)
}
