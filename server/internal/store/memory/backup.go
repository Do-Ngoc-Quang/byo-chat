package memory

import (
	"context"
	"time"

	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
)

func (m *Meta) PutBackup(_ context.Context, acct ids.ID, key string, size uint64, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.acc.backups[acct] = append(m.acc.backups[acct], store.BackupRow{ObjectKey: key, Size: size, CreatedMs: uint64(now.UnixMilli())})
	return nil
}

func (m *Meta) Backups(_ context.Context, acct ids.ID, limit int) ([]store.BackupRow, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	all := m.acc.backups[acct]
	var out []store.BackupRow
	for i := len(all) - 1; i >= 0 && len(out) < limit; i-- {
		out = append(out, all[i])
	}
	return out, nil
}
