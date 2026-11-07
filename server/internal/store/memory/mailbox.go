// Package memory: kho trong bộ nhớ cho test và chạy cục bộ không cần hạ tầng.
// Hành vi (ghi có điều kiện, giao dịch) khớp hợp đồng trong storetest.
package memory

import (
	"bytes"
	"context"
	"sort"
	"sync"

	chatv1 "github.com/Do-Ngoc-Quang/byo-chat/server/gen/chat/v1"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/ids"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store"
)

type dedupVal struct {
	seq, ts uint64
	msgID   ids.ID
}

// Mailbox cài store.MailboxStore.
type Mailbox struct {
	mu    sync.Mutex
	heads map[ids.ID]store.Head
	logs  map[ids.ID]map[uint64]store.Entry
	dedup map[string]dedupVal
	idem  map[string]store.CommitResult
	inbox map[ids.ID]map[ids.ID]store.InboxItem
}

func NewMailbox() *Mailbox {
	return &Mailbox{
		heads: map[ids.ID]store.Head{},
		logs:  map[ids.ID]map[uint64]store.Entry{},
		dedup: map[string]dedupVal{},
		idem:  map[string]store.CommitResult{},
		inbox: map[ids.ID]map[ids.ID]store.InboxItem{},
	}
}

func idemKey(c ids.ID, k string) string { return c.Hex() + "#" + k }

func (m *Mailbox) putWelcomes(e store.Entry, ws []store.Welcome) {
	for _, w := range ws {
		id := ids.InboxID(e.TsMs, e.ConvID, e.Seq)
		m.putInbox(store.InboxItem{
			Device: w.Device, InboxID: id, ConvID: e.ConvID, Seq: e.Seq,
			Kind: chatv1.EntryKind_ENTRY_KIND_WELCOME, Sender: e.Sender, Epoch: e.Epoch + 1,
			Ciphertext: w.Ciphertext, TsMs: e.TsMs,
		})
	}
}

func (m *Mailbox) putInbox(it store.InboxItem) {
	d := m.inbox[it.Device]
	if d == nil {
		d = map[ids.ID]store.InboxItem{}
		m.inbox[it.Device] = d
	}
	d[it.InboxID] = it
}

func (m *Mailbox) CreateConv(_ context.Context, convID ids.ID, r store.CommitReq) (store.CommitResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.heads[convID]; ok {
		return store.CommitResult{}, store.ErrExists
	}
	fo := r.Fanout
	fo.NewEpoch = 1
	e := store.Entry{ConvID: convID, Seq: 1, Kind: chatv1.EntryKind_ENTRY_KIND_COMMIT, Sender: r.Sender,
		Epoch: 0, Ciphertext: r.Ciphertext, TsMs: r.TsMs, MessageID: ids.New(), Pending: &fo}
	m.heads[convID] = store.Head{HeadSeq: 1, Epoch: 1}
	m.logs[convID] = map[uint64]store.Entry{1: e}
	m.putWelcomes(e, r.Welcomes)
	return store.CommitResult{Seq: 1, NewEpoch: 1}, nil
}

func (m *Mailbox) AppendMessage(_ context.Context, r store.AppendMsgReq) (store.AppendResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	h, ok := m.heads[r.ConvID]
	if !ok {
		return store.AppendResult{}, store.ErrNotFound
	}
	dk := r.ConvID.Hex() + "#" + r.ClientMsgID.Hex()
	if d, ok := m.dedup[dk]; ok {
		return store.AppendResult{MessageID: d.msgID, Seq: d.seq, TsMs: d.ts, Duplicate: true}, nil
	}
	if r.Epoch != h.Epoch {
		return store.AppendResult{}, &store.EpochError{Current: h.Epoch}
	}
	seq := h.HeadSeq + 1
	e := store.Entry{ConvID: r.ConvID, Seq: seq, Kind: r.Kind, Sender: r.Sender, Epoch: r.Epoch,
		Ciphertext: r.Ciphertext, TsMs: r.TsMs, MessageID: ids.New(),
		Pending: &store.Fanout{Recipients: r.Recipients}}
	h.HeadSeq = seq
	m.heads[r.ConvID] = h
	m.logs[r.ConvID][seq] = e
	m.dedup[dk] = dedupVal{seq: seq, ts: r.TsMs, msgID: e.MessageID}
	return store.AppendResult{MessageID: e.MessageID, Seq: seq, TsMs: r.TsMs}, nil
}

func (m *Mailbox) AppendCommit(_ context.Context, r store.CommitReq) (store.CommitResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if r.IdemKey != "" {
		if res, ok := m.idem[idemKey(r.ConvID, r.IdemKey)]; ok {
			res.Duplicate = true
			return res, nil
		}
	}
	h, ok := m.heads[r.ConvID]
	if !ok {
		return store.CommitResult{}, store.ErrNotFound
	}
	if r.ExpectedEpoch != h.Epoch {
		return store.CommitResult{}, &store.EpochError{Current: h.Epoch}
	}
	fo := r.Fanout
	fo.NewEpoch = h.Epoch + 1
	seq := h.HeadSeq + 1
	e := store.Entry{ConvID: r.ConvID, Seq: seq, Kind: chatv1.EntryKind_ENTRY_KIND_COMMIT, Sender: r.Sender,
		Epoch: h.Epoch, Ciphertext: r.Ciphertext, TsMs: r.TsMs, MessageID: ids.New(), Pending: &fo}
	h.HeadSeq, h.Epoch = seq, h.Epoch+1
	m.heads[r.ConvID] = h
	m.logs[r.ConvID][seq] = e
	m.putWelcomes(e, r.Welcomes)
	res := store.CommitResult{Seq: seq, NewEpoch: h.Epoch}
	if r.IdemKey != "" {
		m.idem[idemKey(r.ConvID, r.IdemKey)] = res
	}
	return res, nil
}

func (m *Mailbox) GetHead(_ context.Context, c ids.ID) (store.Head, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	h, ok := m.heads[c]
	if !ok {
		return h, store.ErrNotFound
	}
	return h, nil
}

func (m *Mailbox) GetLog(_ context.Context, c ids.ID, after uint64, limit int) ([]store.Entry, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	h, ok := m.heads[c]
	if !ok {
		return nil, store.ErrNotFound
	}
	var out []store.Entry
	for s := after + 1; s <= h.HeadSeq && len(out) < limit; s++ {
		out = append(out, m.logs[c][s])
	}
	return out, nil
}

func (m *Mailbox) GetEntry(_ context.Context, c ids.ID, seq uint64) (store.Entry, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	e, ok := m.logs[c][seq]
	if !ok {
		return e, store.ErrNotFound
	}
	return e, nil
}

func (m *Mailbox) PutPointers(_ context.Context, e store.Entry, devices []ids.ID) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	id := ids.InboxID(e.TsMs, e.ConvID, e.Seq)
	for _, d := range devices {
		m.putInbox(store.InboxItem{Device: d, InboxID: id, ConvID: e.ConvID, Seq: e.Seq,
			Kind: e.Kind, Sender: e.Sender, Epoch: e.Epoch, TsMs: e.TsMs})
	}
	return nil
}

func (m *Mailbox) CompleteFanout(_ context.Context, c ids.ID, seq uint64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if e, ok := m.logs[c][seq]; ok {
		e.Pending = nil
		m.logs[c][seq] = e
	}
	return nil
}

func (m *Mailbox) PendingFanouts(_ context.Context, limit int) ([]store.Entry, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []store.Entry
	for _, l := range m.logs {
		for _, e := range l {
			if e.Pending != nil {
				out = append(out, e)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if c := bytes.Compare(out[i].ConvID[:], out[j].ConvID[:]); c != 0 {
			return c < 0
		}
		return out[i].Seq < out[j].Seq
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *Mailbox) ListInbox(_ context.Context, d, after ids.ID, limit int) ([]store.InboxItem, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []store.InboxItem
	for id, it := range m.inbox[d] {
		if bytes.Compare(id[:], after[:]) > 0 {
			out = append(out, it)
		}
	}
	sort.Slice(out, func(i, j int) bool { return bytes.Compare(out[i].InboxID[:], out[j].InboxID[:]) < 0 })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *Mailbox) DeleteInbox(_ context.Context, d ids.ID, inboxIDs []ids.ID) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, id := range inboxIDs {
		delete(m.inbox[d], id)
	}
	return nil
}

func (m *Mailbox) GetInboxItem(_ context.Context, d, id ids.ID) (store.InboxItem, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	it, ok := m.inbox[d][id]
	if !ok {
		return it, store.ErrNotFound
	}
	return it, nil
}
