package memory

import (
	"bytes"
	"context"
	"crypto/sha256"
	"time"

	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
)

var _ store.AccountStore = (*Meta)(nil)

type ticket struct {
	acct    ids.ID
	isNew   bool
	expires time.Time
	used    bool
}

type refresh struct {
	device  ids.ID
	expires time.Time
}

type kpRow struct {
	store.KeyPackage
}

// accState là phần trạng thái của AccountStore, dùng chung mutex của Meta.
type accState struct {
	byContact map[[32]byte]ids.ID
	identity  map[ids.ID][]byte
	otps      map[ids.ID]store.OTPChallenge
	tickets   map[[32]byte]*ticket
	refresh   map[[32]byte]refresh
	creds     map[ids.ID][]byte   // device -> credential
	order     map[ids.ID][]ids.ID // account -> thiết bị theo thứ tự đăng ký
	kps       map[ids.ID][]kpRow
	revs      map[ids.ID][][]byte
}

func newAccState() accState {
	return accState{
		byContact: map[[32]byte]ids.ID{}, identity: map[ids.ID][]byte{}, otps: map[ids.ID]store.OTPChallenge{},
		tickets: map[[32]byte]*ticket{}, refresh: map[[32]byte]refresh{}, creds: map[ids.ID][]byte{},
		order: map[ids.ID][]ids.ID{}, kps: map[ids.ID][]kpRow{}, revs: map[ids.ID][][]byte{},
	}
}

func key(b []byte) [32]byte { return sha256.Sum256(b) }

func (m *Meta) UpsertAccount(_ context.Context, contactHash []byte, newID ids.ID) (ids.ID, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if id, ok := m.acc.byContact[key(contactHash)]; ok {
		return id, false, nil
	}
	m.acc.byContact[key(contactHash)] = newID
	return newID, true, nil
}

func (m *Meta) AccountByContact(_ context.Context, contactHash []byte) (ids.ID, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if id, ok := m.acc.byContact[key(contactHash)]; ok {
		return id, nil
	}
	return ids.ID{}, store.ErrNotFound
}

func (m *Meta) IdentityKey(_ context.Context, acct ids.ID) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, id := range m.acc.byContact {
		if id == acct {
			return m.acc.identity[acct], nil
		}
	}
	return nil, store.ErrNotFound
}

func (m *Meta) PutOTP(_ context.Context, c store.OTPChallenge) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.acc.otps[c.ID] = c
	return nil
}

func (m *Meta) LatestOTP(_ context.Context, contactHash []byte) (store.OTPChallenge, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var best store.OTPChallenge
	found := false
	for _, c := range m.acc.otps {
		if bytes.Equal(c.ContactHash, contactHash) && (!found || c.CreatedAt.After(best.CreatedAt)) {
			best, found = c, true
		}
	}
	if !found {
		return best, store.ErrNotFound
	}
	return best, nil
}

func (m *Meta) GetOTP(_ context.Context, id ids.ID) (store.OTPChallenge, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.acc.otps[id]
	if !ok {
		return c, store.ErrNotFound
	}
	return c, nil
}

func (m *Meta) IncOTPAttempts(_ context.Context, id ids.ID) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.acc.otps[id]
	if !ok {
		return 0, store.ErrNotFound
	}
	c.Attempts++
	m.acc.otps[id] = c
	return c.Attempts, nil
}

func (m *Meta) DeleteOTP(_ context.Context, id ids.ID) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.acc.otps, id)
	return nil
}

func (m *Meta) PutTicket(_ context.Context, hash []byte, acct ids.ID, isNew bool, expires time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.acc.tickets[key(hash)] = &ticket{acct: acct, isNew: isNew, expires: expires}
	return nil
}

func (m *Meta) TicketAccount(_ context.Context, hash []byte, now time.Time) (ids.ID, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.acc.tickets[key(hash)]
	if !ok || t.used || !now.Before(t.expires) {
		return ids.ID{}, false, store.ErrTicketInvalid
	}
	return t.acct, t.isNew, nil
}

func (m *Meta) RegisterDevice(_ context.Context, r store.RegisterDeviceReq) (ids.ID, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.acc.tickets[key(r.TicketHash)]
	if !ok || t.used || !r.Now.Before(t.expires) {
		return ids.ID{}, store.ErrTicketInvalid
	}
	// Kiểm hết mọi điều kiện trước khi đổi trạng thái (thay cho rollback của giao dịch).
	if !bytes.Equal(m.acc.identity[t.acct], r.ExpectIdentity) {
		return t.acct, store.ErrIdentityMismatch
	}
	if _, dup := m.devices[r.Device]; dup {
		return t.acct, store.ErrExists
	}
	t.used = true
	if len(r.NewIdentity) > 0 {
		m.acc.identity[t.acct] = append([]byte(nil), r.NewIdentity...)
	}
	m.devices[r.Device] = store.DeviceInfo{DeviceID: r.Device, AccountID: t.acct, Platform: r.Platform}
	m.acc.creds[r.Device] = append([]byte(nil), r.Credential...)
	m.acc.order[t.acct] = append(m.acc.order[t.acct], r.Device)
	for _, k := range r.KeyPackages {
		m.acc.kps[r.Device] = append(m.acc.kps[r.Device], kpRow{k})
	}
	m.acc.refresh[key(r.RefreshHash)] = refresh{r.Device, r.RefreshExpires}
	return t.acct, nil
}

func (m *Meta) RotateRefresh(_ context.Context, device ids.ID, oldHash, newHash []byte, newExpires, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	old, ok := m.acc.refresh[key(oldHash)]
	if !ok || old.device != device || !now.Before(old.expires) {
		return store.ErrNotFound
	}
	delete(m.acc.refresh, key(oldHash))
	m.acc.refresh[key(newHash)] = refresh{device, newExpires}
	return nil
}

func (m *Meta) PutKeyPackages(_ context.Context, device ids.ID, kps []store.KeyPackage) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, k := range kps {
		m.acc.kps[device] = append(m.acc.kps[device], kpRow{k})
	}
	return nil
}

func (m *Meta) CountKeyPackages(_ context.Context, device ids.ID, now time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, k := range m.acc.kps[device] {
		if !k.LastResort && now.Before(k.ExpiresAt) {
			n++
		}
	}
	return n, nil
}

func (m *Meta) TakeKeyPackage(_ context.Context, device ids.ID, now time.Time) ([]byte, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	rows := m.acc.kps[device]
	best := -1
	for i, k := range rows {
		if !k.LastResort && now.Before(k.ExpiresAt) && (best < 0 || k.ExpiresAt.Before(rows[best].ExpiresAt)) {
			best = i
		}
	}
	if best >= 0 {
		blob := rows[best].Blob
		m.acc.kps[device] = append(rows[:best:best], rows[best+1:]...)
		return blob, false, nil
	}
	for _, k := range rows {
		if k.LastResort && now.Before(k.ExpiresAt) {
			return k.Blob, true, nil
		}
	}
	return nil, false, store.ErrNotFound
}

func (m *Meta) AccountKeys(_ context.Context, acct ids.ID) ([]byte, []store.DeviceKeys, [][]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	known := false
	for _, id := range m.acc.byContact {
		known = known || id == acct
	}
	if !known {
		return nil, nil, nil, store.ErrNotFound
	}
	var devs []store.DeviceKeys
	for _, d := range m.acc.order[acct] {
		if !m.devices[d].Revoked {
			devs = append(devs, store.DeviceKeys{DeviceID: d, Credential: m.acc.creds[d]})
		}
	}
	return m.acc.identity[acct], devs, m.acc.revs[acct], nil
}
