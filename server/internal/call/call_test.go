package call_test

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/call"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/store"
	"byo-chat/server/internal/store/memory"
	"google.golang.org/protobuf/proto"
)

var cfg = call.Config{URL: "wss://lk.test", APIKey: "key1", APISecret: "secret-secret-secret-secret"}

type env struct {
	meta       *memory.Meta
	bus        *message.MemBus
	svc        *call.Service
	now        time.Time
	alice, bob store.DeviceInfo
	outsider   store.DeviceInfo
	conv       ids.ID
	rung       map[string]*chatv1.IncomingCall
}

func newEnv(t *testing.T, c call.Config) *env {
	t.Helper()
	e := &env{meta: memory.NewMeta(), bus: message.NewMemBus(), now: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC), rung: map[string]*chatv1.IncomingCall{}}
	e.svc = call.New(e.meta, e.bus, c)
	e.svc.Now = func() time.Time { return e.now }
	mk := func() store.DeviceInfo {
		d := store.DeviceInfo{DeviceID: ids.New(), AccountID: ids.New(), Platform: chatv1.Platform_PLATFORM_ANDROID}
		e.meta.AddDevice(d)
		return d
	}
	e.alice, e.bob, e.outsider = mk(), mk(), mk()
	e.conv = ids.New()
	_, _, err := e.meta.CreateConversation(context.Background(), e.conv, chatv1.ConvKind_CONV_KIND_DIRECT, make([]byte, 32), []*chatv1.Member{
		{AccountId: e.alice.AccountID.Bytes(), Role: chatv1.Role_ROLE_OWNER}, {AccountId: e.bob.AccountID.Bytes(), Role: chatv1.Role_ROLE_MEMBER}})
	if err != nil {
		t.Fatal(err)
	}
	_ = e.meta.PutGroupInfo(context.Background(), e.conv, 7, []byte("gi"))
	for _, d := range []store.DeviceInfo{e.alice, e.bob, e.outsider} {
		d := d
		_, _ = e.bus.Subscribe(call.Subject(d.DeviceID.Hex()), func(b []byte) {
			in := &chatv1.IncomingCall{}
			if proto.Unmarshal(b, in) == nil {
				e.rung[d.DeviceID.Hex()] = in
			}
		})
	}
	return e
}

func code(e *message.Error) chatv1.ErrorCode {
	if e == nil {
		return chatv1.ErrorCode_ERROR_CODE_UNSPECIFIED
	}
	return e.Code
}

func TestCallFlow(t *testing.T) {
	e := newEnv(t, cfg)
	ctx := context.Background()
	tk, err := e.svc.StartCall(ctx, e.alice, &chatv1.StartCallRequest{ConvId: e.conv.Bytes(), Kind: chatv1.CallKind_CALL_KIND_AUDIO})
	if err != nil || len(tk.CallId) != 16 || tk.LivekitUrl != cfg.URL || tk.MlsEpoch != 7 || tk.Token == "" {
		t.Fatalf("StartCall: %+v %v", tk, err)
	}
	// Chỉ Bob nhận chuông, người gọi và người ngoài thì không.
	if in := e.rung[e.bob.DeviceID.Hex()]; in == nil || string(in.CallId) != string(tk.CallId) || in.Kind != chatv1.CallKind_CALL_KIND_AUDIO {
		t.Fatalf("Bob phải được đổ chuông: %+v", in)
	}
	if e.rung[e.alice.DeviceID.Hex()] != nil || e.rung[e.outsider.DeviceID.Hex()] != nil {
		t.Fatal("người gọi và người ngoài không được nhận chuông")
	}
	// Token ký đúng, đúng phòng/định danh, hạn 15 phút.
	checkToken(t, tk.Token, e.alice.DeviceID.String(), ids.ID(e.callID(tk)).String(), e.now)

	// Hội thoại chỉ một cuộc gọi cùng lúc.
	if _, err := e.svc.StartCall(ctx, e.bob, &chatv1.StartCallRequest{ConvId: e.conv.Bytes(), Kind: chatv1.CallKind_CALL_KIND_VIDEO}); code(err) != chatv1.ErrorCode_ERROR_CODE_ALREADY_EXISTS {
		t.Fatalf("gọi trùng: %v", err)
	}
	// Bob vào được, người ngoài thấy NOT_FOUND (không lộ cuộc gọi).
	jt, err := e.svc.JoinCall(ctx, e.bob, &chatv1.JoinCallRequest{CallId: tk.CallId})
	if err != nil || jt.MlsEpoch != 7 {
		t.Fatalf("JoinCall: %+v %v", jt, err)
	}
	checkToken(t, jt.Token, e.bob.DeviceID.String(), ids.ID(e.callID(tk)).String(), e.now)
	if _, err := e.svc.JoinCall(ctx, e.outsider, &chatv1.JoinCallRequest{CallId: tk.CallId}); code(err) != chatv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("người ngoài vào: %v", err)
	}
	// Người ngoài không kết thúc được; Bob kết thúc được; sau đó Join NOT_FOUND và EndCall lại vẫn thành công.
	if _, err := e.svc.EndCall(ctx, e.outsider, &chatv1.EndCallRequest{CallId: tk.CallId}); code(err) != chatv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("người ngoài kết thúc: %v", err)
	}
	if _, err := e.svc.EndCall(ctx, e.bob, &chatv1.EndCallRequest{CallId: tk.CallId}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.EndCall(ctx, e.bob, &chatv1.EndCallRequest{CallId: tk.CallId}); err != nil {
		t.Fatalf("EndCall lặp phải idempotent: %v", err)
	}
	if _, err := e.svc.JoinCall(ctx, e.bob, &chatv1.JoinCallRequest{CallId: tk.CallId}); code(err) != chatv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("vào cuộc gọi đã kết thúc: %v", err)
	}
	// Gọi lại được sau khi kết thúc.
	if _, err := e.svc.StartCall(ctx, e.bob, &chatv1.StartCallRequest{ConvId: e.conv.Bytes(), Kind: chatv1.CallKind_CALL_KIND_VIDEO}); err != nil {
		t.Fatalf("gọi lại: %v", err)
	}
}

func TestCallValidationAndExpiry(t *testing.T) {
	e := newEnv(t, cfg)
	ctx := context.Background()
	bad := []struct {
		name string
		dev  store.DeviceInfo
		req  *chatv1.StartCallRequest
		want chatv1.ErrorCode
	}{
		{"conv_id sai", e.alice, &chatv1.StartCallRequest{ConvId: []byte("x"), Kind: chatv1.CallKind_CALL_KIND_AUDIO}, chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT},
		{"kind trống", e.alice, &chatv1.StartCallRequest{ConvId: e.conv.Bytes()}, chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT},
		{"không phải thành viên", e.outsider, &chatv1.StartCallRequest{ConvId: e.conv.Bytes(), Kind: chatv1.CallKind_CALL_KIND_AUDIO}, chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED},
	}
	for _, c := range bad {
		if _, err := e.svc.StartCall(ctx, c.dev, c.req); code(err) != c.want {
			t.Fatalf("%s: muốn %v, nhận %v", c.name, c.want, err)
		}
	}
	if len(e.rung) != 0 {
		t.Fatal("lỗi không được đổ chuông")
	}
	// Cuộc gọi quá hạn tối đa tự hết, hội thoại gọi lại được.
	tk, err := e.svc.StartCall(ctx, e.alice, &chatv1.StartCallRequest{ConvId: e.conv.Bytes(), Kind: chatv1.CallKind_CALL_KIND_AUDIO})
	if err != nil {
		t.Fatal(err)
	}
	e.now = e.now.Add(4*time.Hour + time.Second)
	if _, err := e.svc.JoinCall(ctx, e.bob, &chatv1.JoinCallRequest{CallId: tk.CallId}); code(err) != chatv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("quá hạn: %v", err)
	}
	if _, err := e.svc.StartCall(ctx, e.bob, &chatv1.StartCallRequest{ConvId: e.conv.Bytes(), Kind: chatv1.CallKind_CALL_KIND_AUDIO}); err != nil {
		t.Fatalf("gọi lại sau quá hạn: %v", err)
	}
	// Chưa cấu hình LiveKit.
	e2 := newEnv(t, call.Config{})
	if _, err := e2.svc.StartCall(ctx, e2.alice, &chatv1.StartCallRequest{ConvId: e2.conv.Bytes(), Kind: chatv1.CallKind_CALL_KIND_AUDIO}); code(err) != chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE {
		t.Fatalf("chưa cấu hình: %v", err)
	}
}

func (e *env) callID(tk *chatv1.CallTicket) [16]byte {
	id, _ := ids.FromBytes(tk.CallId)
	return id
}

// checkToken kiểm JWT HS256 của LiveKit: chữ ký, issuer, định danh, phòng, quyền và hạn.
func checkToken(t *testing.T, tok, identity, room string, now time.Time) {
	t.Helper()
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatalf("token không có 3 phần: %q", tok)
	}
	m := hmac.New(sha256.New, []byte(cfg.APISecret))
	m.Write([]byte(parts[0] + "." + parts[1]))
	if want := base64.RawURLEncoding.EncodeToString(m.Sum(nil)); parts[2] != want {
		t.Fatal("chữ ký token sai")
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var c struct {
		Iss, Sub string
		Nbf, Exp int64
		Video    struct {
			Room                               string
			RoomJoin, CanPublish, CanSubscribe bool
		}
	}
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatal(err)
	}
	if c.Iss != cfg.APIKey || c.Sub != identity || c.Video.Room != room || !c.Video.RoomJoin || !c.Video.CanPublish || !c.Video.CanSubscribe ||
		c.Nbf != now.Unix() || c.Exp != now.Add(15*time.Minute).Unix() {
		t.Fatalf("claims sai: %+v", c)
	}
}
