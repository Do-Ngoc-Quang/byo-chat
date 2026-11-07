package memory

import (
	"bytes"
	"context"
	"sync"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
)

type giVal struct {
	epoch uint64
	data  []byte
}

// Meta cài store.MetaStore.
type Meta struct {
	mu      sync.Mutex
	devices map[ids.ID]store.DeviceInfo
	kinds   map[ids.ID]chatv1.ConvKind
	members map[ids.ID]map[ids.ID]store.MemberRow
	direct  map[[32]byte]ids.ID
	gi      map[ids.ID]giVal
	groups  map[string]ids.ID
}

func NewMeta() *Meta {
	return &Meta{
		devices: map[ids.ID]store.DeviceInfo{},
		kinds:   map[ids.ID]chatv1.ConvKind{},
		members: map[ids.ID]map[ids.ID]store.MemberRow{},
		direct:  map[[32]byte]ids.ID{},
		gi:      map[ids.ID]giVal{},
		groups:  map[string]ids.ID{},
	}
}

// AddDevice, RevokeDevice: chỗ đăng ký thiết bị cho test (KeyService làm ở giai đoạn sau).
func (m *Meta) AddDevice(d store.DeviceInfo) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.devices[d.DeviceID] = d
}
func (m *Meta) RevokeDevice(id ids.ID) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d := m.devices[id]
	d.Revoked = true
	m.devices[id] = d
}

func (m *Meta) GetDevice(_ context.Context, id ids.ID) (store.DeviceInfo, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[id]
	if !ok {
		return d, store.ErrNotFound
	}
	return d, nil
}

func (m *Meta) DevicesOfAccounts(_ context.Context, accts []ids.ID) ([]store.DeviceInfo, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	set := map[ids.ID]bool{}
	for _, a := range accts {
		set[a] = true
	}
	var out []store.DeviceInfo
	for _, d := range m.devices {
		if set[d.AccountID] && !d.Revoked {
			out = append(out, d)
		}
	}
	return out, nil
}

func pairKey(a, b ids.ID) [32]byte {
	if bytes.Compare(a[:], b[:]) > 0 {
		a, b = b, a
	}
	var k [32]byte
	copy(k[:16], a[:])
	copy(k[16:], b[:])
	return k
}

func (m *Meta) CreateConversation(_ context.Context, id ids.ID, kind chatv1.ConvKind, groupID []byte, mem []*chatv1.Member) (ids.ID, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if old, ok := m.groups[string(groupID)]; ok {
		return old, false, nil // gửi lại cùng group_id: trả conv_id đã cấp
	}
	var pk [32]byte
	if kind == chatv1.ConvKind_CONV_KIND_DIRECT {
		if len(mem) != 2 {
			return ids.ID{}, false, store.ErrExists
		}
		a, _ := ids.FromBytes(mem[0].AccountId)
		b, _ := ids.FromBytes(mem[1].AccountId)
		pk = pairKey(a, b)
		if old, ok := m.direct[pk]; ok {
			return old, true, nil
		}
		m.direct[pk] = id
	}
	m.groups[string(groupID)] = id
	m.kinds[id] = kind
	rows := map[ids.ID]store.MemberRow{}
	for _, mb := range mem {
		a, _ := ids.FromBytes(mb.AccountId)
		rows[a] = store.MemberRow{AccountID: a, Role: mb.Role}
	}
	m.members[id] = rows
	return id, false, nil
}

func (m *Meta) GetMember(_ context.Context, c, a ids.ID) (store.MemberRow, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.members[c][a]
	if !ok {
		return r, store.ErrNotFound
	}
	return r, nil
}

func (m *Meta) Members(_ context.Context, c ids.ID) ([]store.MemberRow, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []store.MemberRow
	for _, r := range m.members[c] {
		out = append(out, r)
	}
	return out, nil
}

func (m *Meta) ApplyMembership(_ context.Context, c ids.ID, added []*chatv1.Member, removed []ids.ID, roles []*chatv1.Member) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	rows := m.members[c]
	if rows == nil {
		return store.ErrNotFound
	}
	for _, mb := range added {
		a, _ := ids.FromBytes(mb.AccountId)
		rows[a] = store.MemberRow{AccountID: a, Role: mb.Role}
	}
	for _, a := range removed {
		delete(rows, a)
	}
	for _, mb := range roles {
		a, _ := ids.FromBytes(mb.AccountId)
		if r, ok := rows[a]; ok {
			r.Role = mb.Role
			rows[a] = r
		}
	}
	return nil
}

func (m *Meta) PutGroupInfo(_ context.Context, c ids.ID, epoch uint64, gi []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if cur, ok := m.gi[c]; ok && cur.epoch >= epoch {
		return nil // không lùi epoch
	}
	m.gi[c] = giVal{epoch, append([]byte(nil), gi...)}
	return nil
}

func (m *Meta) GetGroupInfo(_ context.Context, c ids.ID) (uint64, []byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.gi[c]
	if !ok {
		return 0, nil, store.ErrNotFound
	}
	return v.epoch, v.data, nil
}

func (m *Meta) ConversationKind(_ context.Context, c ids.ID) (chatv1.ConvKind, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	k, ok := m.kinds[c]
	if !ok {
		return 0, store.ErrNotFound
	}
	return k, nil
}

func (m *Meta) ListConversations(_ context.Context, a ids.ID) ([]ids.ID, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []ids.ID
	for c, rows := range m.members {
		if _, ok := rows[a]; ok {
			out = append(out, c)
		}
	}
	return out, nil
}
