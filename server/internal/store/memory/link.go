package memory

import (
	"context"
	"time"

	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
)

func (m *Meta) PutLink(_ context.Context, l store.DeviceLink) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.acc.links[l.ID]; ok {
		return store.ErrExists
	}
	m.acc.links[l.ID] = &l
	return nil
}

// liveLink: gọi khi đang giữ m.mu.
func (m *Meta) liveLink(id ids.ID, now time.Time) *store.DeviceLink {
	l, ok := m.acc.links[id]
	if !ok || !now.Before(l.ExpiresAt) {
		return nil
	}
	return l
}

func (m *Meta) GetLink(_ context.Context, id ids.ID, now time.Time) (store.DeviceLink, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if l := m.liveLink(id, now); l != nil {
		return *l, nil
	}
	return store.DeviceLink{}, store.ErrNotFound
}

func (m *Meta) ApproveLink(_ context.Context, id, acct ids.ID, cred, sealed []byte, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	l := m.liveLink(id, now)
	if l == nil {
		return store.ErrNotFound
	}
	if !l.Account.IsZero() {
		return store.ErrExists
	}
	l.Account, l.Credential, l.Sealed = acct, cred, sealed
	return nil
}

func (m *Meta) TakeApprovedLink(_ context.Context, id ids.ID, now time.Time) (store.DeviceLink, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	l := m.liveLink(id, now)
	if l == nil || l.Account.IsZero() {
		return store.DeviceLink{}, store.ErrNotFound
	}
	delete(m.acc.links, id)
	return *l, nil
}
