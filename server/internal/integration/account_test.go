package integration_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"sync"
	"testing"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/gen/chat/v1/chatv1connect"
	"byo-chat/server/internal/account"
	"byo-chat/server/internal/ids"
	"connectrpc.com/connect"
)

// otpCapture thay nhà cung cấp SMS: giữ mã OTP gần nhất theo đích.
type otpCapture struct {
	mu    sync.Mutex
	codes map[string]string
}

func (o *otpCapture) Send(_ context.Context, _ chatv1.OtpChannel, dest, code string) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.codes == nil {
		o.codes = map[string]string{}
	}
	o.codes[dest] = code
	return nil
}

func (o *otpCapture) code(dest string) string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.codes[dest]
}

var otpCap = &otpCapture{}

func kpBlob(n byte) []byte {
	b := make([]byte, 40)
	copy(b, []byte{0, 1, 0, 5, 0, 1, 0, 1})
	b[8] = n
	return b
}

// authed gắn Bearer token vào mọi request của client Connect.
func authed(tok string) connect.Option {
	return connect.WithInterceptors(connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
			r.Header().Set("Authorization", "Bearer "+tok)
			return next(ctx, r)
		}
	}))
}

// Đăng nhập OTP -> đăng ký thiết bị -> KeyPackage -> token dùng được ở ConversationService,
// qua HTTP Connect thật, trên Postgres thật (cùng app.New với cmd/gateway).
func TestAuthDeviceKeyOverConnect(t *testing.T) {
	w := newWorld(t)
	a, ts, stop := w.boot(false)
	defer stop()
	ctx := context.Background()
	hc := http.DefaultClient
	authc := chatv1connect.NewAuthServiceClient(hc, ts.URL)
	devc := chatv1connect.NewDeviceServiceClient(hc, ts.URL)

	const phone = "+84901112233"
	rq, err := authc.RequestOtp(ctx, connect.NewRequest(&chatv1.RequestOtpRequest{Channel: chatv1.OtpChannel_OTP_CHANNEL_SMS, Destination: phone}))
	if err != nil {
		t.Fatal(err)
	}
	v, err := authc.VerifyOtp(ctx, connect.NewRequest(&chatv1.VerifyOtpRequest{ChallengeId: rq.Msg.ChallengeId, Code: otpCap.code(phone)}))
	if err != nil || !v.Msg.IsNewAccount {
		t.Fatalf("%v %v", v, err)
	}
	acct, _ := ids.FromBytes(v.Msg.AccountId)

	idPub, idKey, _ := ed25519.GenerateKey(nil)
	devPub, _, _ := ed25519.GenerateKey(nil)
	dev := ids.New()
	reg := &chatv1.RegisterDeviceRequest{
		SessionTicket: v.Msg.SessionTicket, DeviceId: dev.Bytes(), Platform: chatv1.Platform_PLATFORM_ANDROID, DeviceName: "emu",
		DevicePublicKey: devPub, AccountIdentityPublicKey: idPub,
		Credential:  account.SignCredential(idKey, acct, dev, devPub, 1),
		KeyPackages: [][]byte{kpBlob(1), kpBlob(2)}, LastResortKeyPackage: kpBlob(9),
	}
	rd, err := devc.RegisterDevice(ctx, connect.NewRequest(reg))
	if err != nil {
		t.Fatal(err)
	}
	// ticket dùng một lần: gửi lại bị từ chối với mã Connect đúng bảng mục 5
	if _, err := devc.RegisterDevice(ctx, connect.NewRequest(reg)); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatalf("muốn unauthenticated, nhận %v", err)
	}

	keyc := chatv1connect.NewKeyServiceClient(hc, ts.URL, authed(rd.Msg.Tokens.AccessToken))
	cnt, err := keyc.CountKeyPackages(ctx, connect.NewRequest(&chatv1.CountKeyPackagesRequest{}))
	if err != nil || cnt.Msg.Remaining != 2 {
		t.Fatalf("%v %v", cnt, err)
	}
	// không token: bị từ chối
	anon := chatv1connect.NewKeyServiceClient(hc, ts.URL)
	if _, err := anon.CountKeyPackages(ctx, connect.NewRequest(&chatv1.CountKeyPackagesRequest{})); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatalf("muốn unauthenticated, nhận %v", err)
	}
	f, err := keyc.FetchKeyPackages(ctx, connect.NewRequest(&chatv1.FetchKeyPackagesRequest{AccountIds: [][]byte{acct.Bytes()}}))
	if err != nil || len(f.Msg.Accounts) != 1 || len(f.Msg.Accounts[0].Devices) != 1 || f.Msg.Accounts[0].Devices[0].KeyPackage[8] != 1 {
		t.Fatalf("%v %v", f, err)
	}

	// token làm mới được, token mới dùng được ở ConversationService
	np, err := authc.RefreshToken(ctx, connect.NewRequest(&chatv1.RefreshTokenRequest{DeviceId: dev.Bytes(), RefreshToken: rd.Msg.Tokens.RefreshToken}))
	if err != nil {
		t.Fatal(err)
	}
	convc := chatv1connect.NewConversationServiceClient(hc, ts.URL, authed(np.Msg.AccessToken))
	lc, err := convc.ListConversations(ctx, connect.NewRequest(&chatv1.ListConversationsRequest{}))
	if err != nil || len(lc.Msg.Conversations) != 0 {
		t.Fatalf("%v %v", lc, err)
	}
	if _, err := authc.RefreshToken(ctx, connect.NewRequest(&chatv1.RefreshTokenRequest{DeviceId: dev.Bytes(), RefreshToken: rd.Msg.Tokens.RefreshToken})); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatalf("refresh token cũ phải bị từ chối: %v", err)
	}
	// thu hồi thiết bị: access token đang sống cũng bị chặn ngay
	if err := w.meta.RevokeDevice(ctx, dev); err != nil {
		t.Fatal(err)
	}
	if _, err := convc.ListConversations(ctx, connect.NewRequest(&chatv1.ListConversationsRequest{})); connect.CodeOf(err) != connect.CodePermissionDenied {
		t.Fatalf("muốn permission_denied (DEVICE_REVOKED): %v", err)
	}
	_ = a
}
