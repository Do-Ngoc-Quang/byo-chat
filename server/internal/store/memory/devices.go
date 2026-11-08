package memory

import (
	"context"
	"time"

	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
)

func (m *Meta) ListDevices(_ context.Context, acct ids.ID) ([]store.DeviceRow, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []store.DeviceRow
	for _, id := range m.acc.order[acct] {
		d := m.devices[id]
		out = append(out, store.DeviceRow{
			DeviceID: id, Platform: d.Platform, Name: m.acc.names[id],
			CreatedMs: uint64(m.acc.created[id].UnixMilli()), Revoked: d.Revoked,
		})
	}
	return out, nil
}

func (m *Meta) RevokeAccountDevice(_ context.Context, acct, device ids.ID, statement []byte, _ time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[device]
	if !ok || d.AccountID != acct {
		return store.ErrNotFound
	}
	if d.Revoked {
		return store.ErrExists
	}
	d.Revoked = true
	m.devices[device] = d
	delete(m.acc.kps, device)
	for k, r := range m.acc.refresh {
		if r.device == device {
			delete(m.acc.refresh, k)
		}
	}
	m.acc.revs[acct] = append(m.acc.revs[acct], append([]byte(nil), statement...))
	return nil
}
