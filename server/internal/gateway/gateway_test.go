package gateway_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/gen/chat/v1/chatv1connect"
	"byo-chat/server/internal/api"
	"byo-chat/server/internal/auth"
	"byo-chat/server/internal/gateway"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/store"
	"byo-chat/server/internal/store/memory"
	"byo-chat/server/internal/store/storetest"
	"connectrpc.com/connect"
	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"
)

type stack struct {
	t      *testing.T
	svc    *message.Service
	meta   *memory.Meta
	mb     store.MailboxStore
	q      *message.MemQueue
	gw     *gateway.Server
	ts     *httptest.Server
	tok    *auth.HMAC
	cancel context.CancelFunc
}

func newStack(t *testing.T, cfg gateway.Config) *stack {
	t.Helper()
	meta, mb, q := memory.NewMeta(), storetest.New(t), message.NewMemQueue()
	svc := message.New(meta, mb, q, message.NewMemBus())
	tok, _ := auth.NewHMAC([]byte(strings.Repeat("s", 32)))
	gw := gateway.New(svc, tok, cfg)
	mux := http.NewServeMux()
	mux.Handle("/v1/connect", gw)
	p, h := (&api.Conversation{Svc: svc, Verifier: tok}).Handler()
	mux.Handle(p, h)
	ts := httptest.NewServer(mux)
	ctx, cancel := context.WithCancel(context.Background())
	go svc.Worker(ctx)
	t.Cleanup(func() { cancel(); ts.Close() })
	return &stack{t: t, svc: svc, meta: meta, mb: mb, q: q, gw: gw, ts: ts, tok: tok, cancel: cancel}
}

func fastCfg() gateway.Config {
	c := gateway.DefaultConfig()
	c.HelloTimeout = 300 * time.Millisecond
	return c
}

func (s *stack) device(acct ids.ID) store.DeviceInfo {
	d := store.DeviceInfo{DeviceID: ids.New(), AccountID: acct, Platform: chatv1.Platform_PLATFORM_ANDROID}
	s.meta.AddDevice(d)
	return d
}

func (s *stack) token(d store.DeviceInfo, ttl time.Duration) string {
	return s.tok.Issue(auth.Claims{Account: d.AccountID, Device: d.DeviceID, Expires: time.Now().Add(ttl)})
}

// client là một WebSocket thô để quan sát khung và mã đóng.
type client struct {
	t  *testing.T
	ws *websocket.Conn
}

func (s *stack) dial(t *testing.T) *client {
	ws, _, err := websocket.Dial(context.Background(), "ws"+strings.TrimPrefix(s.ts.URL, "http")+"/v1/connect",
		&websocket.DialOptions{Subprotocols: []string{gateway.Subprotocol}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.CloseNow() })
	return &client{t: t, ws: ws}
}

func (c *client) send(f *chatv1.ClientFrame) {
	b, _ := proto.Marshal(f)
	if err := c.ws.Write(context.Background(), websocket.MessageBinary, b); err != nil {
		c.t.Fatal(err)
	}
}

func (c *client) recv() *chatv1.ServerFrame {
	c.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, b, err := c.ws.Read(ctx)
	if err != nil {
		c.t.Fatalf("đọc khung: %v", err)
	}
	f := &chatv1.ServerFrame{}
	if err := proto.Unmarshal(b, f); err != nil {
		c.t.Fatal(err)
	}
	return f
}

func (c *client) wantClose(code websocket.StatusCode) {
	c.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		if _, _, err := c.ws.Read(ctx); err != nil {
			if got := websocket.CloseStatus(err); got != code {
				c.t.Fatalf("mã đóng %d, muốn %d (%v)", got, code, err)
			}
			return
		}
	}
}

// waitInbox đợi hộp thư của thiết bị còn đúng n mục (Ack xử lý bất đồng bộ).
func (s *stack) waitInbox(d store.DeviceInfo, n int) {
	s.t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		items, _ := s.mb.ListInbox(context.Background(), d.DeviceID, ids.ID{}, 100)
		if len(items) == n {
			return
		}
		if time.Now().After(deadline) {
			s.t.Fatalf("hộp thư còn %d mục, muốn %d", len(items), n)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func hello(d store.DeviceInfo, tok string, cursor []byte) *chatv1.ClientFrame {
	return &chatv1.ClientFrame{Body: &chatv1.ClientFrame_Hello{Hello: &chatv1.Hello{
		ProtoVersion: 1, DeviceId: d.DeviceID.Bytes(), AccessToken: tok, InboxCursor: cursor}}}
}

// connect: Hello, Welcome, tồn đọng, SyncDone. Trả client và các Deliver tồn đọng.
func (s *stack) connect(d store.DeviceInfo, cursor []byte) (*client, []*chatv1.Deliver) {
	c := s.dial(s.t)
	c.send(hello(d, s.token(d, time.Hour), cursor))
	if f := c.recv(); f.GetWelcome() == nil || f.GetWelcome().HeartbeatMs != 25000 || f.GetWelcome().Window != 256 || f.GetWelcome().MaxFrameBytes != 256<<10 {
		s.t.Fatalf("muốn Welcome, nhận %v", f)
	}
	var backlog []*chatv1.Deliver
	for {
		f := c.recv()
		if f.GetSyncDone() != nil {
			return c, backlog
		}
		if f.GetDeliver() == nil {
			s.t.Fatalf("giữa tồn đọng nhận %v", f)
		}
		backlog = append(backlog, f.GetDeliver())
	}
}

func (c *client) sendMsg(req uint64, conv ids.ID, epoch uint64, cmid ids.ID, ct string) *chatv1.ServerFrame {
	c.send(&chatv1.ClientFrame{ReqId: req, Body: &chatv1.ClientFrame_Send{Send: &chatv1.SendMessage{
		ConvId: conv.Bytes(), ClientMsgId: cmid.Bytes(), MlsEpoch: epoch, Ciphertext: []byte(ct)}}})
	return c.recv()
}

// twoParty: Alice (A1, A2) và Bob (B1), nhóm đã tạo xong qua service.
func (s *stack) twoParty() (a1, a2, b1 store.DeviceInfo, conv ids.ID) {
	alice, bob := ids.New(), ids.New()
	a1, a2, b1 = s.device(alice), s.device(alice), s.device(bob)
	gid := make([]byte, 32)
	copy(gid, ids.New().Bytes())
	w := func(d store.DeviceInfo) *chatv1.WelcomeEnvelope {
		return &chatv1.WelcomeEnvelope{RecipientDeviceId: d.DeviceID.Bytes(), Welcome: []byte("w")}
	}
	resp, e := s.svc.CreateConversation(context.Background(), a1, &chatv1.CreateConversationRequest{
		Kind: chatv1.ConvKind_CONV_KIND_GROUP, GroupId: gid, Commit: []byte("c0"), GroupInfo: []byte("gi"),
		Members:  []*chatv1.Member{{AccountId: alice.Bytes(), Role: chatv1.Role_ROLE_OWNER}, {AccountId: bob.Bytes(), Role: chatv1.Role_ROLE_MEMBER}},
		Welcomes: []*chatv1.WelcomeEnvelope{w(a2), w(b1)}})
	if e != nil {
		s.t.Fatal(e)
	}
	conv, _ = ids.FromBytes(resp.ConvId)
	return
}

func TestHandshakeSendDeliverAckResume(t *testing.T) {
	s := newStack(t, fastCfg())
	a1, _, b1, conv := s.twoParty()

	// B1 vào, nhận Welcome trong tồn đọng.
	cb, backlog := s.connect(b1, nil)
	if len(backlog) != 1 || backlog[0].Kind != chatv1.EntryKind_ENTRY_KIND_WELCOME || string(backlog[0].Ciphertext) != "w" {
		t.Fatalf("tồn đọng của B1: %+v", backlog)
	}
	cb.send(&chatv1.ClientFrame{Body: &chatv1.ClientFrame_Ack{Ack: &chatv1.Ack{InboxIds: [][]byte{backlog[0].InboxId}}}})

	ca, _ := s.connect(a1, nil)
	// Sai epoch → EPOCH_MISMATCH có current_epoch.
	cm := ids.New()
	f := ca.sendMsg(1, conv, 0, cm, "x")
	if e := f.GetError(); f.ReqId != 1 || e == nil || e.Code != chatv1.ErrorCode_ERROR_CODE_EPOCH_MISMATCH || e.CurrentEpoch != 1 {
		t.Fatalf("muốn EPOCH_MISMATCH, nhận %v", f)
	}
	f = ca.sendMsg(2, conv, 1, cm, "hello")
	r := f.GetSendResult()
	if f.ReqId != 2 || r == nil || r.Seq != 2 || r.Duplicate {
		t.Fatalf("SendResult %v", f)
	}
	// Gửi lại cùng client_msg_id (mất kết nối trước phản hồi): duplicate, cùng seq.
	if r2 := ca.sendMsg(3, conv, 1, cm, "hello").GetSendResult(); r2 == nil || !r2.Duplicate || r2.Seq != 2 {
		t.Fatalf("gửi lại: %v", r2)
	}
	// B1 nhận Deliver live.
	d := cb.recv().GetDeliver()
	if d == nil || d.Seq != 2 || string(d.Ciphertext) != "hello" || len(d.InboxId) != 16 || d.MlsEpoch != 1 {
		t.Fatalf("Deliver %v", d)
	}
	// B1 không ack, rớt mạng; kết nối lại với cursor cũ nhận lại (at-least-once).
	cb.ws.CloseNow()
	cb2, again := s.connect(b1, backlog[0].InboxId)
	if len(again) != 1 || again[0].Seq != 2 || string(again[0].InboxId) != string(d.InboxId) {
		t.Fatalf("tồn đọng sau nối lại: %+v", again)
	}
	cb2.send(&chatv1.ClientFrame{Body: &chatv1.ClientFrame_Ack{Ack: &chatv1.Ack{InboxIds: [][]byte{d.InboxId}}}})
	s.waitInbox(b1, 0) // Ack xong: con trỏ biến mất
	// Ping/Pong.
	cb2.send(&chatv1.ClientFrame{ReqId: 9, Body: &chatv1.ClientFrame_Ping{Ping: &chatv1.Ping{Nonce: 42}}})
	if p := cb2.recv(); p.GetPong().GetNonce() != 42 || p.ReqId != 9 {
		t.Fatalf("Pong %v", p)
	}
}

func TestCloseCodes(t *testing.T) {
	s := newStack(t, fastCfg())
	d := s.device(ids.New())

	t.Run("4001 quá hạn Hello", func(t *testing.T) { s.dial(t).wantClose(4001) })
	t.Run("4001 khung đầu không phải Hello", func(t *testing.T) {
		c := s.dial(t)
		c.send(&chatv1.ClientFrame{Body: &chatv1.ClientFrame_Ping{Ping: &chatv1.Ping{}}})
		c.wantClose(4001)
	})
	t.Run("4001 token sai", func(t *testing.T) {
		c := s.dial(t)
		c.send(hello(d, "rác", nil))
		c.wantClose(4001)
	})
	t.Run("4002 token hết hạn", func(t *testing.T) {
		c := s.dial(t)
		c.send(hello(d, s.token(d, -time.Minute), nil))
		c.wantClose(4002)
	})
	t.Run("4004 phiên bản", func(t *testing.T) {
		c := s.dial(t)
		h := hello(d, s.token(d, time.Hour), nil)
		h.GetHello().ProtoVersion = 99
		c.send(h)
		c.wantClose(4004)
	})
	t.Run("4003 thiết bị đã thu hồi", func(t *testing.T) {
		r := s.device(ids.New())
		s.meta.RevokeDevice(r.DeviceID)
		c := s.dial(t)
		c.send(hello(r, s.token(r, time.Hour), nil))
		c.wantClose(4003)
	})
	t.Run("4003 thu hồi khi kết nối đang mở", func(t *testing.T) {
		r := s.device(ids.New())
		c, _ := s.connect(r, nil)
		s.meta.RevokeDevice(r.DeviceID)
		s.gw.CloseDevice(r.DeviceID)
		c.wantClose(4003)
		s.gw.CloseDevice(ids.New()) // thiết bị không có kết nối: không làm gì
	})
	t.Run("4010 bị thay bởi kết nối mới", func(t *testing.T) {
		old, _ := s.connect(d, nil)
		s.connect(d, nil)
		old.wantClose(4010)
		if n := s.gw.ConnCount(); n != 1 {
			t.Fatalf("còn %d kết nối", n)
		}
	})
	t.Run("hai chu kỳ không có khung thì đóng", func(t *testing.T) {
		cfg := fastCfg()
		cfg.Heartbeat = 100 * time.Millisecond
		s3 := newStack(t, cfg)
		d3 := s3.device(ids.New())
		c := s3.dial(t)
		c.send(hello(d3, s3.token(d3, time.Hour), nil))
		if c.recv().GetWelcome() == nil { // rồi im lặng, không Ping
			t.Fatal("muốn Welcome")
		}
		c.wantClose(websocket.StatusGoingAway)
	})
	t.Run("4009 drain", func(t *testing.T) {
		s2 := newStack(t, fastCfg())
		d2 := s2.device(ids.New())
		c, _ := s2.connect(d2, nil)
		s2.gw.Drain()
		c.wantClose(4009)
	})
}

func TestRateLimit(t *testing.T) {
	cfg := fastCfg()
	cfg.SendBurst, cfg.SendRate = 3, 1
	s := newStack(t, cfg)
	a1, _, _, conv := s.twoParty()
	c, _ := s.connect(a1, nil)
	limited := 0
	for i := 0; i < 8; i++ {
		f := c.sendMsg(uint64(i+1), conv, 1, ids.New(), "m")
		if e := f.GetError(); e != nil {
			if e.Code != chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED || e.RetryAfterMs == 0 {
				t.Fatalf("%v", e)
			}
			limited++
		}
	}
	if limited == 0 {
		t.Fatal("không bị giới hạn tốc độ")
	}
}

// Chèn lỗi: sập giữa ghi Commit và ghi con trỏ — job mất, gateway vẫn giao được sau khi Repair.
func TestCrashAfterCommitThenRepairDeliversLive(t *testing.T) {
	s := newStack(t, fastCfg())
	a1, _, b1, conv := s.twoParty()
	cb, backlog := s.connect(b1, nil)
	cb.send(&chatv1.ClientFrame{Body: &chatv1.ClientFrame_Ack{Ack: &chatv1.Ack{InboxIds: [][]byte{backlog[0].InboxId}}}})

	s.waitInbox(b1, 0)
	s.q.Drop = true // job fanout không bao giờ vào hàng đợi (mô phỏng sập)
	r, e := s.svc.SubmitCommit(context.Background(), a1, "k", &chatv1.SubmitCommitRequest{
		ConvId: conv.Bytes(), ExpectedEpoch: 1, Commit: []byte("c1"), GroupInfo: []byte("gi2")})
	if e != nil {
		t.Fatal(e)
	}
	// Trước sửa chữa chưa có con trỏ nào cho B1 (job đã mất), nên chưa gì được giao.
	if items, _ := s.mb.ListInbox(context.Background(), b1.DeviceID, ids.ID{}, 10); len(items) != 0 {
		t.Fatalf("B1 đã có %d con trỏ trước sửa chữa", len(items))
	}
	if n, err := s.svc.Repair(context.Background(), 10); err != nil || n == 0 {
		t.Fatalf("repair n=%d err=%v", n, err)
	}
	d := cb.recv().GetDeliver()
	if d == nil || d.Kind != chatv1.EntryKind_ENTRY_KIND_COMMIT || d.Seq != r.Seq || string(d.Ciphertext) != "c1" {
		t.Fatalf("Deliver sau sửa chữa: %v", d)
	}
}

// Connect RPC: Bearer, Idempotency-Key và mã lỗi.
func TestConnectRPC(t *testing.T) {
	s := newStack(t, fastCfg())
	a1, _, b1, conv := s.twoParty()
	s.svc.Settle(context.Background())
	cl := chatv1connect.NewConversationServiceClient(http.DefaultClient, s.ts.URL)
	call := func(d store.DeviceInfo, key string, req *chatv1.SubmitCommitRequest) (*chatv1.SubmitCommitResponse, error) {
		r := connect.NewRequest(req)
		r.Header().Set("Authorization", "Bearer "+s.token(d, time.Hour))
		if key != "" {
			r.Header().Set("Idempotency-Key", key)
		}
		resp, err := cl.SubmitCommit(context.Background(), r)
		if err != nil {
			return nil, err
		}
		return resp.Msg, nil
	}
	req := func(epoch uint64) *chatv1.SubmitCommitRequest {
		return &chatv1.SubmitCommitRequest{ConvId: conv.Bytes(), ExpectedEpoch: epoch, Commit: []byte("c"), GroupInfo: []byte("g")}
	}
	// Không token.
	r0 := connect.NewRequest(req(1))
	if _, err := cl.SubmitCommit(context.Background(), r0); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatalf("muốn unauthenticated, nhận %v", err)
	}
	// Bob (MEMBER) không được thêm người.
	add := req(1)
	add.Added = []*chatv1.Member{{AccountId: ids.New().Bytes(), Role: chatv1.Role_ROLE_MEMBER}}
	if _, err := call(b1, "k0", add); connect.CodeOf(err) != connect.CodePermissionDenied {
		t.Fatalf("muốn permission_denied, nhận %v", err)
	}
	// Alice thành công; gửi lại cùng khóa trả cùng kết quả; epoch cũ khóa mới → failed_precondition + chi tiết.
	r1, err := call(a1, "k1", req(1))
	if err != nil || r1.NewEpoch != 2 {
		t.Fatalf("%v %v", r1, err)
	}
	if r2, err := call(a1, "k1", req(1)); err != nil || r2.Seq != r1.Seq {
		t.Fatalf("gửi lại: %v %v", r2, err)
	}
	_, err = call(a1, "k2", req(1))
	var ce *connect.Error
	if connect.CodeOf(err) != connect.CodeFailedPrecondition || !asConnect(err, &ce) {
		t.Fatalf("muốn failed_precondition, nhận %v", err)
	}
	found := false
	for _, d := range ce.Details() {
		if v, e := d.Value(); e == nil {
			if pe, ok := v.(*chatv1.Error); ok && pe.Code == chatv1.ErrorCode_ERROR_CODE_EPOCH_MISMATCH && pe.CurrentEpoch == 2 {
				found = true
			}
		}
	}
	if !found {
		t.Fatal("thiếu chi tiết Error{EPOCH_MISMATCH, current_epoch=2}")
	}
	// Thiếu Idempotency-Key → invalid_argument.
	if _, err := call(a1, "", req(2)); connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("muốn invalid_argument, nhận %v", err)
	}
	// FetchLog và GetGroupInfo.
	fr := connect.NewRequest(&chatv1.FetchLogRequest{ConvId: conv.Bytes(), AfterSeq: 0})
	fr.Header().Set("Authorization", "Bearer "+s.token(b1, time.Hour))
	lr, err := cl.FetchLog(context.Background(), fr)
	if err != nil || len(lr.Msg.Entries) != 2 || lr.Msg.HeadSeq != 2 || lr.Msg.Epoch != 2 {
		t.Fatalf("%v %v", lr, err)
	}
}

func asConnect(err error, out **connect.Error) bool {
	if ce, ok := err.(*connect.Error); ok {
		*out = ce
		return true
	}
	return false
}

var _ sync.Locker = (*sync.Mutex)(nil)

// Trình duyệt gửi Origin: khác origin với server thì bị từ chối (chống CSWSH) trừ khi host nằm trong OriginPatterns.
func TestWebSocketOrigin(t *testing.T) {
	cfg := fastCfg()
	cfg.OriginPatterns = []string{"app.example.test:8142"}
	s := newStack(t, cfg)
	dial := func(origin string) error {
		ws, _, err := websocket.Dial(context.Background(), "ws"+strings.TrimPrefix(s.ts.URL, "http")+"/v1/connect",
			&websocket.DialOptions{Subprotocols: []string{"chat.v1"}, HTTPHeader: http.Header{"Origin": {origin}}})
		if err == nil {
			ws.CloseNow()
		}
		return err
	}
	if err := dial("http://app.example.test:8142"); err != nil {
		t.Fatalf("origin được phép phải kết nối được: %v", err)
	}
	if err := dial("http://evil.example:9"); err == nil {
		t.Fatal("origin lạ phải bị từ chối")
	}
	// không có Origin (app native) luôn được
	if err := dial(""); err != nil {
		t.Fatalf("không có Origin phải kết nối được: %v", err)
	}
}
