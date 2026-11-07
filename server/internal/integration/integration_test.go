// Test tích hợp: Postgres + DynamoDB Local + NATS JetStream thật, ghép bằng app.New như cmd/gateway.
// Cần: TEST_POSTGRES_DSN và TEST_DYNAMO_ENDPOINT (NATS chạy nhúng). Không có thì bỏ qua.
package integration_test

import (
	"context"
	"fmt"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/app"
	"byo-chat/server/internal/auth"
	"byo-chat/server/internal/gateway"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/store"
	"byo-chat/server/internal/store/postgres"
	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgxpool"
	natsserver "github.com/nats-io/nats-server/v2/server"
	"google.golang.org/protobuf/proto"
)

func natsURL(t *testing.T) string {
	s, err := natsserver.NewServer(&natsserver.Options{Port: -1, JetStream: true, StoreDir: t.TempDir(), NoLog: true, NoSigs: true})
	if err != nil {
		t.Fatal(err)
	}
	go s.Start()
	if !s.ReadyForConnections(10 * time.Second) {
		t.Fatal("NATS")
	}
	t.Cleanup(s.Shutdown)
	return s.ClientURL()
}

// build dựng một "tiến trình" mới trên cùng kho. Mỗi test dùng schema Postgres và tiền tố bảng riêng.
type world struct {
	t      *testing.T
	dsn    string
	prefix string
	nats   string
	meta   *postgres.Store
}

func newWorld(t *testing.T) *world {
	dsn, ep := os.Getenv("TEST_POSTGRES_DSN"), os.Getenv("TEST_DYNAMO_ENDPOINT")
	if dsn == "" || ep == "" {
		t.Skip("đặt TEST_POSTGRES_DSN và TEST_DYNAMO_ENDPOINT")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("it%d_%d", os.Getpid(), time.Now().UnixNano()%1e9)
	admin.Exec(ctx, "CREATE SCHEMA "+schema)
	t.Cleanup(func() { admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE"); admin.Close() })
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	w := &world{t: t, dsn: dsn + sep + "search_path=" + schema, prefix: schema + "_", nats: natsURL(t)}
	// pool riêng để chuẩn bị dữ liệu thiết bị
	pool, err := pgxpool.New(ctx, w.dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if err := postgres.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	w.meta = postgres.New(pool)
	return w
}

func (w *world) boot(drop bool) (*app.App, *httptest.Server, context.CancelFunc) {
	ctx, cancel := context.WithCancel(context.Background())
	cfg := gateway.DefaultConfig()
	a, err := app.New(ctx, app.Config{
		PostgresDSN: w.dsn, DynamoEndpoint: os.Getenv("TEST_DYNAMO_ENDPOINT"), DynamoPrefix: w.prefix,
		NATSURL: w.nats, TokenKey: []byte(strings.Repeat("k", 32)), EnsureTables: true, Gateway: cfg,
		RepairEvery: time.Hour, // sửa chữa gọi tay trong test
	})
	if err != nil {
		w.t.Fatal(err)
	}
	ts := httptest.NewServer(a.Mux)
	if drop {
		// Mô phỏng sập trước khi job vào JetStream: bỏ qua Publish.
		a.Svc.Queue = dropQueue{a.Svc.Queue}
	} else {
		go a.Run(ctx)
	}
	return a, ts, func() { cancel(); ts.Close(); a.Close() }
}

// dropQueue nuốt Publish (như tiến trình chết ngay sau giao dịch ghi) nhưng vẫn cho Consume chạy.
type dropQueue struct{ message.Queue }

func (dropQueue) Publish(context.Context, message.Job) error { return nil }

type wsc struct {
	t  *testing.T
	ws *websocket.Conn
}

func dial(t *testing.T, ts *httptest.Server, a *app.App, d store.DeviceInfo, cursor []byte) (*wsc, []*chatv1.Deliver) {
	ws, _, err := websocket.Dial(context.Background(), "ws"+strings.TrimPrefix(ts.URL, "http")+"/v1/connect",
		&websocket.DialOptions{Subprotocols: []string{"chat.v1"}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.CloseNow() })
	c := &wsc{t, ws}
	tok := a.Tokens.Issue(auth.Claims{Account: d.AccountID, Device: d.DeviceID, Expires: time.Now().Add(time.Hour)})
	c.send(&chatv1.ClientFrame{Body: &chatv1.ClientFrame_Hello{Hello: &chatv1.Hello{ProtoVersion: 1, DeviceId: d.DeviceID.Bytes(), AccessToken: tok, InboxCursor: cursor}}})
	if c.recv().GetWelcome() == nil {
		t.Fatal("muốn Welcome")
	}
	var backlog []*chatv1.Deliver
	for {
		f := c.recv()
		if f.GetSyncDone() != nil {
			return c, backlog
		}
		backlog = append(backlog, f.GetDeliver())
	}
}

func (c *wsc) send(f *chatv1.ClientFrame) {
	b, _ := proto.Marshal(f)
	if err := c.ws.Write(context.Background(), websocket.MessageBinary, b); err != nil {
		c.t.Fatal(err)
	}
}
func (c *wsc) recv() *chatv1.ServerFrame {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, b, err := c.ws.Read(ctx)
	if err != nil {
		c.t.Fatalf("đọc: %v", err)
	}
	f := &chatv1.ServerFrame{}
	if err := proto.Unmarshal(b, f); err != nil {
		c.t.Fatal(err)
	}
	return f
}

func (w *world) dev(acct ids.ID) store.DeviceInfo {
	d := store.DeviceInfo{DeviceID: ids.New(), AccountID: acct, Platform: chatv1.Platform_PLATFORM_WEB}
	if err := w.meta.AddDevice(context.Background(), d); err != nil {
		w.t.Fatal(err)
	}
	return d
}

func TestFullStackChatAndCrashRecovery(t *testing.T) {
	w := newWorld(t)
	alice, bob := ids.New(), ids.New()
	a1, b1 := w.dev(alice), w.dev(bob)
	ctx := context.Background()

	a, ts, stop := w.boot(false)
	// 1-1: A1 tạo, B1 nhận Welcome qua WebSocket (live, hoặc tồn đọng nếu vào sau).
	cb, _ := dial(t, ts, a, b1, nil)
	gid := make([]byte, 32)
	copy(gid, ids.New().Bytes())
	cr, e := a.Svc.CreateConversation(ctx, a1, &chatv1.CreateConversationRequest{
		Kind: chatv1.ConvKind_CONV_KIND_DIRECT, GroupId: gid, Commit: []byte("c0"), GroupInfo: []byte("gi1"),
		Members:  []*chatv1.Member{{AccountId: alice.Bytes(), Role: chatv1.Role_ROLE_MEMBER}, {AccountId: bob.Bytes(), Role: chatv1.Role_ROLE_MEMBER}},
		Welcomes: []*chatv1.WelcomeEnvelope{{RecipientDeviceId: b1.DeviceID.Bytes(), Welcome: []byte("w")}}})
	if e != nil {
		t.Fatal(e)
	}
	conv, _ := ids.FromBytes(cr.ConvId)
	if d := cb.recv().GetDeliver(); d == nil || d.Kind != chatv1.EntryKind_ENTRY_KIND_WELCOME {
		t.Fatalf("B1 muốn Welcome live, nhận %v", d)
	}
	// A1 gửi qua WebSocket, B1 nhận live qua JetStream→bus NATS.
	ca, _ := dial(t, ts, a, a1, nil)
	cm := ids.New()
	ca.send(&chatv1.ClientFrame{ReqId: 1, Body: &chatv1.ClientFrame_Send{Send: &chatv1.SendMessage{ConvId: conv.Bytes(), ClientMsgId: cm.Bytes(), MlsEpoch: 1, Ciphertext: []byte("hi")}}})
	if r := ca.recv().GetSendResult(); r == nil || r.Seq != 2 {
		t.Fatalf("SendResult %v", r)
	}
	if d := cb.recv().GetDeliver(); d == nil || string(d.Ciphertext) != "hi" || d.Seq != 2 {
		t.Fatalf("Deliver %v", d)
	}
	stop()

	// Tiến trình mới (tạo lại từ kho): Commit thành công nhưng "sập" trước khi job vào JetStream.
	a, ts, stop = w.boot(true)
	r, e := a.Svc.SubmitCommit(ctx, a1, "idem-1", &chatv1.SubmitCommitRequest{
		ConvId: conv.Bytes(), ExpectedEpoch: 1, Commit: []byte("c1"), GroupInfo: []byte("gi2")})
	if e != nil {
		t.Fatal(e)
	}
	if ep, _, _ := w.meta.GetGroupInfo(ctx, conv); ep != 1 {
		t.Fatalf("group_info epoch %d trước sửa chữa, muốn 1 (chưa chạy fanout)", ep)
	}
	stop() // tiến trình "chết"

	// Khởi động lại: Repair hoàn tất việc dở, rồi B1 (cursor cũ) nhận Commit trong tồn đọng.
	a, ts, stop = w.boot(false)
	defer stop()
	a.Svc.Settle(ctx)
	if ep, gi, _ := w.meta.GetGroupInfo(ctx, conv); ep != 2 || string(gi) != "gi2" {
		t.Fatalf("group_info sau sửa chữa: %d %q", ep, gi)
	}
	_, backlog := dial(t, ts, a, b1, nil)
	var sawCommit bool
	for _, d := range backlog {
		if d.Kind == chatv1.EntryKind_ENTRY_KIND_COMMIT && d.Seq == r.Seq && string(d.Ciphertext) == "c1" {
			sawCommit = true
		}
	}
	if !sawCommit {
		t.Fatalf("B1 không thấy Commit seq %d trong tồn đọng: %+v", r.Seq, backlog)
	}
	// Gửi lại SubmitCommit với cùng Idempotency-Key sau khi "mất phản hồi": cùng kết quả, không thêm mục log.
	r2, e := a.Svc.SubmitCommit(ctx, a1, "idem-1", &chatv1.SubmitCommitRequest{
		ConvId: conv.Bytes(), ExpectedEpoch: 1, Commit: []byte("c1"), GroupInfo: []byte("gi2")})
	if e != nil || r2.Seq != r.Seq || r2.NewEpoch != 2 {
		t.Fatalf("gửi lại: %v %v", r2, e)
	}
	fl, e := a.Svc.FetchLog(ctx, a1, &chatv1.FetchLogRequest{ConvId: conv.Bytes()})
	if e != nil || len(fl.Entries) != 3 || fl.HeadSeq != 3 {
		t.Fatalf("log: %v %v", fl, e)
	}
}
