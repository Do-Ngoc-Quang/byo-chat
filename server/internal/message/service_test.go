package message_test

import (
	"context"
	"sync"
	"testing"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/store"
	"byo-chat/server/internal/store/memory"
	"byo-chat/server/internal/store/storetest"
)

// Env: Alice (A1, A2), Bob (B1), Carol (C1).
type env struct {
	t              *testing.T
	svc            *message.Service
	meta           *memory.Meta
	mb             store.MailboxStore
	q              *message.MemQueue
	A1, A2, B1, C1 store.DeviceInfo
	alice, bob     ids.ID
	carol          ids.ID
}

func newEnv(t *testing.T) *env {
	meta, mb, q := memory.NewMeta(), storetest.New(t), message.NewMemQueue()
	e := &env{t: t, meta: meta, mb: mb, alice: ids.New(), bob: ids.New(), carol: ids.New()}
	mk := func(acct ids.ID) store.DeviceInfo {
		d := store.DeviceInfo{DeviceID: ids.New(), AccountID: acct, Platform: chatv1.Platform_PLATFORM_ANDROID}
		meta.AddDevice(d)
		return d
	}
	e.A1, e.A2, e.B1, e.C1 = mk(e.alice), mk(e.alice), mk(e.bob), mk(e.carol)
	e.svc = message.New(meta, mb, q, message.NewMemBus())
	return e
}

func (e *env) mustOK(err *message.Error) {
	e.t.Helper()
	if err != nil {
		e.t.Fatalf("lỗi bất ngờ: %v", err)
	}
}

func wantCode(t *testing.T, err *message.Error, c chatv1.ErrorCode) *message.Error {
	t.Helper()
	if err == nil || err.Code != c {
		t.Fatalf("muốn %v, nhận %v", c, err)
	}
	return err
}

func member(a ids.ID, r chatv1.Role) *chatv1.Member {
	return &chatv1.Member{AccountId: a.Bytes(), Role: r}
}

func welcome(d store.DeviceInfo) *chatv1.WelcomeEnvelope {
	return &chatv1.WelcomeEnvelope{RecipientDeviceId: d.DeviceID.Bytes(), Welcome: []byte("welcome")}
}

// group tạo nhóm Alice (OWNER) + Bob (MEMBER), thêm A2 và B1 qua Welcome.
func (e *env) group() ids.ID {
	gid := make([]byte, 32)
	copy(gid, ids.New().Bytes())
	copy(gid[16:], ids.New().Bytes())
	resp, err := e.svc.CreateConversation(context.Background(), e.A1, &chatv1.CreateConversationRequest{
		Kind: chatv1.ConvKind_CONV_KIND_GROUP, GroupId: gid,
		Members:   []*chatv1.Member{member(e.alice, chatv1.Role_ROLE_OWNER), member(e.bob, chatv1.Role_ROLE_MEMBER)},
		Commit:    []byte("commit0"),
		Welcomes:  []*chatv1.WelcomeEnvelope{welcome(e.A2), welcome(e.B1)},
		GroupInfo: []byte("gi1"),
	})
	e.mustOK(err)
	conv, _ := ids.FromBytes(resp.ConvId)
	e.drain()
	return conv
}

// drain chạy hết fanout đang chờ (thay cho worker).
func (e *env) drain() {
	e.t.Helper()
	if _, err := e.svc.Repair(context.Background(), 1000); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) send(d store.DeviceInfo, conv ids.ID, epoch uint64, cmid ids.ID) (*chatv1.SendResult, *message.Error) {
	return e.svc.SendMessage(context.Background(), d, &chatv1.SendMessage{
		ConvId: conv.Bytes(), ClientMsgId: cmid.Bytes(), MlsEpoch: epoch, Ciphertext: []byte("ct")})
}

func TestCreateDirectAndExisted(t *testing.T) {
	e := newEnv(t)
	mk := func(w store.DeviceInfo) *chatv1.CreateConversationRequest {
		gid := make([]byte, 32)
		copy(gid, ids.New().Bytes())
		return &chatv1.CreateConversationRequest{
			Kind: chatv1.ConvKind_CONV_KIND_DIRECT, GroupId: gid,
			Members: []*chatv1.Member{member(e.alice, chatv1.Role_ROLE_MEMBER), member(e.bob, chatv1.Role_ROLE_MEMBER)},
			Commit:  []byte("c"), GroupInfo: []byte("g"), Welcomes: []*chatv1.WelcomeEnvelope{welcome(w)},
		}
	}
	r1, err := e.svc.CreateConversation(context.Background(), e.A1, mk(e.B1))
	e.mustOK(err)
	if r1.Seq != 1 || r1.Epoch != 1 || r1.Existed {
		t.Fatalf("resp %+v", r1)
	}
	r2, err := e.svc.CreateConversation(context.Background(), e.B1, mk(e.A1)) // nhóm MLS khác, cùng cặp
	e.mustOK(err)
	if !r2.Existed || string(r2.ConvId) != string(r1.ConvId) {
		t.Fatalf("muốn existed với conv cũ, nhận %+v", r2)
	}
}

func TestSendMessageEpochAndDedup(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	cm := ids.New()

	_, err := e.send(e.A1, conv, 0, cm) // epoch cũ
	got := wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_EPOCH_MISMATCH)
	if got.CurrentEpoch != 1 {
		t.Fatalf("current_epoch = %d", got.CurrentEpoch)
	}
	r1, err := e.send(e.A1, conv, 1, cm)
	e.mustOK(err)
	if r1.Seq != 2 || r1.Duplicate {
		t.Fatalf("r1 %+v", r1)
	}
	// Bất biến 5: gửi lại cùng client_msg_id không tạo mục mới.
	r2, err := e.send(e.A1, conv, 1, cm)
	e.mustOK(err)
	if !r2.Duplicate || r2.Seq != 2 || string(r2.MessageId) != string(r1.MessageId) {
		t.Fatalf("r2 %+v", r2)
	}
	log, _ := e.mb.GetLog(context.Background(), conv, 0, 100)
	if len(log) != 2 {
		t.Fatalf("log có %d mục, muốn 2", len(log))
	}
	// Người ngoài không gửi được.
	_, err = e.send(e.C1, conv, 1, ids.New())
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
	// Quá lớn.
	_, err = e.svc.SendMessage(context.Background(), e.A1, &chatv1.SendMessage{ConvId: conv.Bytes(),
		ClientMsgId: ids.New().Bytes(), MlsEpoch: 1, Ciphertext: make([]byte, message.MaxCiphertext+1)})
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE)
}

func TestConcurrentSendsContiguousSeq(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	const n = 100
	var wg sync.WaitGroup
	seqs := make(chan uint64, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, err := e.send(e.A1, conv, 1, ids.New())
			if err != nil {
				t.Error(err)
				return
			}
			seqs <- r.Seq
		}()
	}
	wg.Wait()
	close(seqs)
	seen := map[uint64]bool{}
	for s := range seqs {
		if seen[s] {
			t.Fatalf("seq %d trùng", s)
		}
		seen[s] = true
	}
	for s := uint64(2); s < n+2; s++ {
		if !seen[s] {
			t.Fatalf("thiếu seq %d", s)
		}
	}
}

func commitReq(conv ids.ID, epoch uint64) *chatv1.SubmitCommitRequest {
	return &chatv1.SubmitCommitRequest{ConvId: conv.Bytes(), ExpectedEpoch: epoch, Commit: []byte("commit"), GroupInfo: []byte("gi")}
}

func TestTwoAdminsRace(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	// Bob lên ADMIN (qua ApplyMembership trực tiếp, vai trò do Commit trước đó đặt).
	if err := e.meta.ApplyMembership(context.Background(), conv, nil, nil, []*chatv1.Member{member(e.bob, chatv1.Role_ROLE_ADMIN)}); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	res := make([]*message.Error, 2)
	devs := []store.DeviceInfo{e.A1, e.B1}
	for i := range devs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, res[i] = e.svc.SubmitCommit(context.Background(), devs[i], ids.New().String(), commitReq(conv, 1))
		}()
	}
	wg.Wait()
	wins := 0
	for _, r := range res {
		if r == nil {
			wins++
		} else if r.Code != chatv1.ErrorCode_ERROR_CODE_EPOCH_MISMATCH || r.CurrentEpoch != 2 {
			t.Fatalf("bên thua nhận %v", r)
		}
	}
	if wins != 1 {
		t.Fatalf("%d bên thắng, muốn 1 (bất biến 2)", wins)
	}
	h, _ := e.mb.GetHead(context.Background(), conv)
	if h.Epoch != 2 {
		t.Fatalf("epoch = %d", h.Epoch)
	}
}

// Mất kết nối giữa lúc gửi SubmitCommit và lúc nhận phản hồi: gửi lại cùng Idempotency-Key.
func TestSubmitCommitRetrySameIdempotencyKey(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	key := ids.New().String()
	r1, err := e.svc.SubmitCommit(context.Background(), e.A1, key, commitReq(conv, 1))
	e.mustOK(err)
	r2, err := e.svc.SubmitCommit(context.Background(), e.A1, key, commitReq(conv, 1))
	e.mustOK(err)
	if r1.Seq != r2.Seq || r1.NewEpoch != r2.NewEpoch {
		t.Fatalf("gửi lại phải trả kết quả cũ: %+v vs %+v", r1, r2)
	}
	log, _ := e.mb.GetLog(context.Background(), conv, 0, 100)
	if len(log) != 2 {
		t.Fatalf("log có %d mục, muốn 2", len(log))
	}
	// Khóa khác với epoch cũ thì phải bị từ chối.
	_, err = e.svc.SubmitCommit(context.Background(), e.A1, ids.New().String(), commitReq(conv, 1))
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_EPOCH_MISMATCH)
}

func TestCommitPermissions(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	ctx := context.Background()
	// Bob chỉ MEMBER: không thêm người được.
	add := commitReq(conv, 1)
	add.Added = []*chatv1.Member{member(e.carol, chatv1.Role_ROLE_MEMBER)}
	add.Welcomes = []*chatv1.WelcomeEnvelope{welcome(e.C1)}
	_, err := e.svc.SubmitCommit(ctx, e.B1, ids.New().String(), add)
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
	// Welcome tới thiết bị ngoài `added` bị từ chối.
	bad := commitReq(conv, 1)
	bad.Added = []*chatv1.Member{member(e.carol, chatv1.Role_ROLE_MEMBER)}
	bad.Welcomes = []*chatv1.WelcomeEnvelope{welcome(e.B1)}
	_, err = e.svc.SubmitCommit(ctx, e.A1, ids.New().String(), bad)
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)
	// Alice (OWNER) thêm Carol: thành công, sau fanout Carol là thành viên và C1 có Welcome.
	r, err := e.svc.SubmitCommit(ctx, e.A1, ids.New().String(), add2(conv, e))
	e.mustOK(err)
	e.drain()
	if _, mErr := e.meta.GetMember(ctx, conv, e.carol); mErr != nil {
		t.Fatalf("Carol chưa là thành viên: %v", mErr)
	}
	items, _ := e.mb.ListInbox(ctx, e.C1.DeviceID, ids.ID{}, 10)
	if len(items) != 1 || items[0].Kind != chatv1.EntryKind_ENTRY_KIND_WELCOME || items[0].Epoch != r.NewEpoch {
		t.Fatalf("hộp thư C1: %+v", items)
	}
	ep, gi, _ := e.meta.GetGroupInfo(ctx, conv)
	if ep != 2 || string(gi) != "gi" {
		t.Fatalf("group_info epoch %d %q", ep, gi)
	}
	// Carol (mới vào) gửi tin ở epoch 2.
	_, err = e.send(e.C1, conv, 2, ids.New())
	e.mustOK(err)
	// Gỡ Carol: C1 nhận Commit làm tin cuối, rồi không nhận tin sau đó.
	rm := commitReq(conv, 2)
	rm.RemovedAccountIds = [][]byte{e.carol.Bytes()}
	rr, err := e.svc.SubmitCommit(ctx, e.A1, ids.New().String(), rm)
	e.mustOK(err)
	e.drain()
	_, err = e.send(e.A1, conv, rr.NewEpoch, ids.New())
	e.mustOK(err)
	e.drain()
	items, _ = e.mb.ListInbox(ctx, e.C1.DeviceID, ids.ID{}, 100)
	last := items[len(items)-1]
	if last.Kind != chatv1.EntryKind_ENTRY_KIND_COMMIT || last.Seq != rr.Seq {
		t.Fatalf("tin cuối của C1 phải là Commit gỡ (seq %d): %+v", rr.Seq, last)
	}
	_, err = e.send(e.C1, conv, rr.NewEpoch, ids.New())
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
}

// Xoay khóa (chỉ path update) và gỡ thiết bị của chính mình: thành viên thường được; gỡ thiết bị người khác thì không.
func TestMemberCommitRules(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	ctx := context.Background()
	rot := commitReq(conv, 1)
	r, err := e.svc.SubmitCommit(ctx, e.B1, ids.New().String(), rot) // Bob chỉ là MEMBER
	e.mustOK(err)
	own := commitReq(conv, r.NewEpoch)
	own.RemovedDeviceIds = [][]byte{e.B1.DeviceID.Bytes()}
	r, err = e.svc.SubmitCommit(ctx, e.B1, ids.New().String(), own)
	e.mustOK(err)
	other := commitReq(conv, r.NewEpoch)
	other.RemovedDeviceIds = [][]byte{e.A2.DeviceID.Bytes()}
	_, err = e.svc.SubmitCommit(ctx, e.B1, ids.New().String(), other)
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
}

// Rời nhóm khi không admin online (ADR 0015): proposal đánh dấu `leaving`; khi đó thành viên thường gỡ được đúng người
// đang rời, không ai khác.
func TestLeaveFallbackByMember(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	ctx := context.Background()
	_, err := e.svc.SubmitCommit(ctx, e.A1, ids.New().String(), add2(conv, e))
	e.mustOK(err)
	e.drain()
	rm := func(a ids.ID) *chatv1.SubmitCommitRequest {
		r := commitReq(conv, 2)
		r.RemovedAccountIds = [][]byte{a.Bytes()}
		return r
	}
	_, err = e.svc.SubmitCommit(ctx, e.C1, ids.New().String(), rm(e.bob)) // Bob chưa xin rời
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
	_, err = e.svc.SubmitProposal(ctx, e.B1, ids.New().String(), &chatv1.SubmitProposalRequest{ConvId: conv.Bytes(), Proposal: []byte("p"), MlsEpoch: 2})
	e.mustOK(err)
	_, err = e.svc.SubmitCommit(ctx, e.C1, ids.New().String(), rm(e.alice)) // Alice không rời
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
	both := rm(e.bob)
	both.RemovedAccountIds = append(both.RemovedAccountIds, e.carol.Bytes()) // kèm người không rời
	_, err = e.svc.SubmitCommit(ctx, e.C1, ids.New().String(), both)
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
	_, err = e.svc.SubmitCommit(ctx, e.C1, ids.New().String(), rm(e.bob))
	e.mustOK(err)
	e.drain()
	if _, mErr := e.meta.GetMember(ctx, conv, e.bob); mErr != store.ErrNotFound {
		t.Fatalf("Bob phải bị gỡ: %v", mErr)
	}
}

func add2(conv ids.ID, e *env) *chatv1.SubmitCommitRequest {
	r := commitReq(conv, 1)
	r.Added = []*chatv1.Member{member(e.carol, chatv1.Role_ROLE_MEMBER)}
	r.Welcomes = []*chatv1.WelcomeEnvelope{welcome(e.C1)}
	return r
}

func TestExternalCommit(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	ctx := context.Background()
	// Thiết bị mới A3 của Alice (không phải admin cũng được): External Commit.
	a3 := store.DeviceInfo{DeviceID: ids.New(), AccountID: e.alice}
	e.meta.AddDevice(a3)
	ext := commitReq(conv, 1)
	ext.External = true
	r, err := e.svc.SubmitCommit(ctx, a3, ids.New().String(), ext)
	e.mustOK(err)
	if r.NewEpoch != 2 {
		t.Fatal(r)
	}
	// Bob (MEMBER) cũng tự thêm thiết bị mới được, nhưng không kèm đổi thành viên.
	b2 := store.DeviceInfo{DeviceID: ids.New(), AccountID: e.bob}
	e.meta.AddDevice(b2)
	bad := commitReq(conv, 2)
	bad.External = true
	bad.Added = []*chatv1.Member{member(e.carol, chatv1.Role_ROLE_MEMBER)}
	_, err = e.svc.SubmitCommit(ctx, b2, ids.New().String(), bad)
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)
	// Người ngoài nhóm không External Commit được.
	ext2 := commitReq(conv, 2)
	ext2.External = true
	_, err = e.svc.SubmitCommit(ctx, e.C1, ids.New().String(), ext2)
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
}

// Con trỏ hộp thư idempotent theo (conv_id, seq): chạy fanout nhiều lần không nhân bản.
func TestPointersIdempotent(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	ctx := context.Background()
	r, err := e.send(e.A1, conv, 1, ids.New())
	e.mustOK(err)
	for i := 0; i < 3; i++ {
		if err := e.svc.RunFanout(ctx, message.Job{ConvID: conv, Seq: r.Seq}); err != nil {
			t.Fatal(err)
		}
	}
	// Ghi thẳng lại con trỏ (mô phỏng giao job hai lần, kể cả sau CompleteFanout).
	ent, _ := e.mb.GetEntry(ctx, conv, r.Seq)
	for i := 0; i < 3; i++ {
		if err := e.mb.PutPointers(ctx, ent, []ids.ID{e.A2.DeviceID, e.B1.DeviceID}); err != nil {
			t.Fatal(err)
		}
	}
	for _, d := range []store.DeviceInfo{e.A2, e.B1} {
		items, _ := e.mb.ListInbox(ctx, d.DeviceID, ids.ID{}, 100)
		n := 0
		for _, it := range items {
			if it.Seq == r.Seq {
				n++
			}
		}
		if n != 1 {
			t.Fatalf("thiết bị %s có %d con trỏ cho seq %d, muốn 1", d.DeviceID, n, r.Seq)
		}
	}
	// Người gửi không nhận con trỏ của chính mình.
	items, _ := e.mb.ListInbox(ctx, e.A1.DeviceID, ids.ID{}, 100)
	for _, it := range items {
		if it.Seq == r.Seq {
			t.Fatal("người gửi không được có con trỏ của tin mình gửi")
		}
	}
}

// Sập giữa ghi Commit và ghi con trỏ: hàng đợi mất job; Repair phải hoàn tất.
func TestCrashBetweenCommitAndPointers(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	ctx := context.Background()
	q := message.NewMemQueue()
	q.Drop = true // mô phỏng sập trước khi job vào JetStream
	e.svc.Queue = q

	r, err := e.svc.SubmitCommit(ctx, e.A1, ids.New().String(), add2(conv, e))
	e.mustOK(err) // client đã nhận thành công; việc dở vẫn nằm trong kho

	if _, mErr := e.meta.GetMember(ctx, conv, e.carol); mErr == nil {
		t.Fatal("trước sửa chữa Carol chưa được là thành viên (mô phỏng sập)")
	}
	items, _ := e.mb.ListInbox(ctx, e.B1.DeviceID, ids.ID{}, 100)
	for _, it := range items {
		if it.Seq == r.Seq {
			t.Fatal("con trỏ lẽ ra chưa được ghi")
		}
	}
	pend, _ := e.mb.PendingFanouts(ctx, 10)
	if len(pend) != 1 || pend[0].Seq != r.Seq {
		t.Fatalf("muốn đúng 1 mục dở, nhận %d", len(pend))
	}

	n, err2 := e.svc.Repair(ctx, 10)
	if err2 != nil || n != 1 {
		t.Fatalf("repair n=%d err=%v", n, err2)
	}
	for _, d := range []store.DeviceInfo{e.A2, e.B1} {
		it, gErr := e.mb.GetInboxItem(ctx, d.DeviceID, ids.InboxID(pend[0].TsMs, conv, r.Seq))
		if gErr != nil || it.Seq != r.Seq {
			t.Fatalf("thiết bị %s thiếu con trỏ sau sửa chữa: %v", d.DeviceID, gErr)
		}
	}
	if _, mErr := e.meta.GetMember(ctx, conv, e.carol); mErr != nil {
		t.Fatal("Carol phải là thành viên sau sửa chữa")
	}
	if ep, _, _ := e.meta.GetGroupInfo(ctx, conv); ep != 2 {
		t.Fatalf("group_info epoch %d, muốn 2", ep)
	}
	if left, _ := e.mb.PendingFanouts(ctx, 10); len(left) != 0 {
		t.Fatal("còn mục dở sau sửa chữa")
	}
	// Chạy lại không đổi gì.
	if n, _ := e.svc.Repair(ctx, 10); n != 0 {
		t.Fatalf("repair lần hai xử lý %d mục", n)
	}
}

func TestBacklogOrderAndWelcome(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	ctx := context.Background()
	for i := 0; i < 3; i++ {
		_, err := e.send(e.A1, conv, 1, ids.New())
		e.mustOK(err)
	}
	e.drain()
	got, err := e.svc.Backlog(ctx, e.B1.DeviceID, ids.ID{}, 100)
	if err != nil {
		t.Fatal(err)
	}
	// Welcome (seq 1) rồi 3 tin (seq 2..4), inbox_id tăng dần.
	if len(got) != 4 || got[0].Kind != chatv1.EntryKind_ENTRY_KIND_WELCOME || string(got[0].Ciphertext) != "welcome" {
		t.Fatalf("backlog %+v", got)
	}
	for i := 1; i < len(got); i++ {
		if got[i].Seq != uint64(i)+1 || string(got[i].Ciphertext) != "ct" || string(got[i].InboxId) <= string(got[i-1].InboxId) {
			t.Fatalf("mục %d sai: %+v", i, got[i])
		}
	}
	// Sau cursor chỉ còn phần sau.
	cur, _ := ids.FromBytes(got[1].InboxId)
	rest, _ := e.svc.Backlog(ctx, e.B1.DeviceID, cur, 100)
	if len(rest) != 2 {
		t.Fatalf("sau cursor còn %d, muốn 2", len(rest))
	}
}

func TestFetchLogAndGroupInfo(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	ctx := context.Background()
	for i := 0; i < 5; i++ {
		_, err := e.send(e.A1, conv, 1, ids.New())
		e.mustOK(err)
	}
	r, err := e.svc.FetchLog(ctx, e.B1, &chatv1.FetchLogRequest{ConvId: conv.Bytes(), AfterSeq: 1, Limit: 2})
	e.mustOK(err)
	if len(r.Entries) != 2 || r.Entries[0].Seq != 2 || !r.More || r.HeadSeq != 6 || r.Epoch != 1 {
		t.Fatalf("%+v", r)
	}
	_, err = e.svc.FetchLog(ctx, e.C1, &chatv1.FetchLogRequest{ConvId: conv.Bytes()})
	wantCode(t, err, chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
	g, err := e.svc.GetGroupInfo(ctx, e.B1, &chatv1.GetGroupInfoRequest{ConvId: conv.Bytes()})
	e.mustOK(err)
	if string(g.GroupInfo) != "gi1" || g.Epoch != 1 {
		t.Fatalf("%+v", g)
	}
}

// Giới hạn kích thước (giao-thuc.md mục 2): tối đa 50 Welcome mỗi Commit, mỗi Welcome <= 128 KiB, tổng <= 3 MiB.
func TestCommitWelcomeLimits(t *testing.T) {
	e := newEnv(t)
	conv := e.group()
	ctx := context.Background()
	var devs []store.DeviceInfo
	for i := 0; i < 51; i++ {
		d := store.DeviceInfo{DeviceID: ids.New(), AccountID: e.carol, Platform: chatv1.Platform_PLATFORM_ANDROID}
		e.meta.AddDevice(d)
		devs = append(devs, d)
	}
	try := func(n, size int) *message.Error {
		req := commitReq(conv, 1)
		req.Added = []*chatv1.Member{member(e.carol, chatv1.Role_ROLE_MEMBER)}
		for _, d := range devs[:n] {
			req.Welcomes = append(req.Welcomes, &chatv1.WelcomeEnvelope{RecipientDeviceId: d.DeviceID.Bytes(), Welcome: make([]byte, size)})
		}
		_, err := e.svc.SubmitCommit(ctx, e.A1, ids.New().String(), req)
		return err
	}
	wantCode(t, try(51, 10), chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)                 // 51 > 50 thiết bị
	wantCode(t, try(1, message.MaxCommit+1), chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT) // một Welcome quá lớn
	wantCode(t, try(25, message.MaxCommit), chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE) // 25 x 128 KiB > 3 MiB
	if err := try(50, 10); err != nil {                                                    // đúng 50: được
		t.Fatalf("50 Welcome nhỏ phải được: %v", err)
	}
}

// Nhóm tối đa MaxGroupDevs (256) thiết bị (ADR 0011): thêm bằng các Commit 50 Welcome cho tới khi đầy, thiết bị thứ 257 bị từ chối.
func TestGroupDeviceLimit(t *testing.T) {
	e := newEnv(t)
	conv := e.group() // A1, A2, B1 = 3 thiết bị
	ctx := context.Background()
	epoch := uint64(1)
	devices := 3
	add := func(n int) *message.Error {
		req := commitReq(conv, epoch)
		acct := ids.New() // mỗi lần thêm một tài khoản mới (Welcome chỉ tới thiết bị của tài khoản trong added)
		req.Added = []*chatv1.Member{member(acct, chatv1.Role_ROLE_MEMBER)}
		for i := 0; i < n; i++ {
			d := store.DeviceInfo{DeviceID: ids.New(), AccountID: acct, Platform: chatv1.Platform_PLATFORM_ANDROID}
			e.meta.AddDevice(d)
			req.Welcomes = append(req.Welcomes, welcome(d))
		}
		r, err := e.svc.SubmitCommit(ctx, e.A1, ids.New().String(), req)
		if err == nil {
			epoch = r.NewEpoch
			devices += n
			e.drain()
		}
		return err
	}
	for devices+50 <= message.MaxGroupDevs {
		e.mustOK(add(50))
	}
	e.mustOK(add(message.MaxGroupDevs - devices)) // đúng đầy
	if devices != message.MaxGroupDevs {
		t.Fatalf("đã có %d thiết bị, muốn %d", devices, message.MaxGroupDevs)
	}
	wantCode(t, add(1), chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)
}
