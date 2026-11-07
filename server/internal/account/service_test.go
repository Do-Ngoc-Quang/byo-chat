package account_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/account"
	"byo-chat/server/internal/auth"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
	"byo-chat/server/internal/store/memory"
)

type capture struct{ code, dest string }

func (c *capture) Send(_ context.Context, _ chatv1.OtpChannel, dest, code string) error {
	c.code, c.dest = code, dest
	return nil
}

type env struct {
	t    *testing.T
	svc  *account.Service
	sms  *capture
	now  time.Time
	meta *memory.Meta
}

func newEnv(t *testing.T) *env {
	m := memory.NewMeta()
	tok, _ := auth.NewHMAC([]byte("0123456789abcdef0123456789abcdef"))
	e := &env{t: t, sms: &capture{}, now: time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC), meta: m}
	e.svc = account.New(m, m, tok, e.sms, []byte("contact-key-contact-key-contact-key"))
	e.svc.Now = func() time.Time { return e.now }
	return e
}

func code(e *chatv1.Error) chatv1.ErrorCode { return e.Code }

const phone = "+84901234567"

// login chạy RequestOtp + VerifyOtp và trả (account, ticket).
func (e *env) login(dest string) (ids.ID, []byte, bool) {
	e.t.Helper()
	rq, err := e.svc.RequestOtp(context.Background(), &chatv1.RequestOtpRequest{Channel: chatv1.OtpChannel_OTP_CHANNEL_SMS, Destination: dest})
	if err != nil {
		e.t.Fatalf("RequestOtp: %v", err)
	}
	v, err := e.svc.VerifyOtp(context.Background(), &chatv1.VerifyOtpRequest{ChallengeId: rq.ChallengeId, Code: e.sms.code})
	if err != nil {
		e.t.Fatalf("VerifyOtp: %v", err)
	}
	acct, _ := ids.FromBytes(v.AccountId)
	return acct, v.SessionTicket, v.IsNewAccount
}

// kp tạo gói giả có tiêu đề MLSMessage hợp lệ (nội dung MLS thật do chatcore kiểm ở test đầu-cuối).
func kp() []byte {
	b := make([]byte, 64)
	rand.Read(b)
	copy(b, []byte{0, 1, 0, 5, 0, 1, 0, 1})
	return b
}

type dev struct {
	id   ids.ID
	pub  ed25519.PublicKey
	priv ed25519.PrivateKey
}

func newDev() dev {
	p, s, _ := ed25519.GenerateKey(nil)
	return dev{ids.New(), p, s}
}

func (e *env) reg(acct ids.ID, ticket []byte, d dev, idKey ed25519.PrivateKey, sendKey bool) (*chatv1.RegisterDeviceResponse, *errT) {
	r := &chatv1.RegisterDeviceRequest{
		SessionTicket: ticket, DeviceId: d.id.Bytes(), Platform: chatv1.Platform_PLATFORM_ANDROID, DeviceName: "máy thử",
		DevicePublicKey: d.pub, Credential: account.SignCredential(idKey, acct, d.id, d.pub, uint64(e.now.UnixMilli())),
		KeyPackages: [][]byte{kp(), kp(), kp()}, LastResortKeyPackage: kp(),
	}
	if sendKey {
		r.AccountIdentityPublicKey = idKey.Public().(ed25519.PublicKey)
	}
	return e.regReq(r)
}

type errT = struct{ Code chatv1.ErrorCode }

func (e *env) regReq(r *chatv1.RegisterDeviceRequest) (*chatv1.RegisterDeviceResponse, *errT) {
	resp, err := e.svc.RegisterDevice(context.Background(), r)
	if err != nil {
		return nil, &errT{err.Code}
	}
	return resp, nil
}

func wantCode(t *testing.T, got *errT, want chatv1.ErrorCode) {
	t.Helper()
	if got == nil || got.Code != want {
		t.Fatalf("muốn %v, nhận %v", want, got)
	}
}

func TestOTPFlow(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, _, isNew := e.login(phone)
	if !isNew {
		t.Fatal("tài khoản đầu tiên phải is_new")
	}
	e.now = e.now.Add(time.Minute)
	acct2, _, isNew2 := e.login("+84 90-123-4567") // cùng số, khác cách viết
	if isNew2 {
		t.Fatal("cùng số điện thoại phải ra cùng tài khoản")
	}
	_ = acct2

	// quá nhanh: hai yêu cầu liên tiếp mà chưa nhập mã (sau khi nhập đúng, challenge bị xóa nên không còn chặn)
	e.now = e.now.Add(time.Minute)
	if _, err := e.svc.RequestOtp(ctx, &chatv1.RequestOtpRequest{Channel: chatv1.OtpChannel_OTP_CHANNEL_SMS, Destination: phone}); err != nil {
		t.Fatal(err)
	}
	_, err := e.svc.RequestOtp(ctx, &chatv1.RequestOtpRequest{Channel: chatv1.OtpChannel_OTP_CHANNEL_SMS, Destination: phone})
	if err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED || err.RetryAfterMs == 0 {
		t.Fatalf("muốn RATE_LIMITED kèm retry_after: %v", err)
	}
	// đích sai
	for _, d := range []string{"0901234567", "+0123", "abc", ""} {
		if _, err := e.svc.RequestOtp(ctx, &chatv1.RequestOtpRequest{Channel: chatv1.OtpChannel_OTP_CHANNEL_SMS, Destination: d}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
			t.Fatalf("%q: %v", d, err)
		}
	}
	if _, err := e.svc.RequestOtp(ctx, &chatv1.RequestOtpRequest{Channel: chatv1.OtpChannel_OTP_CHANNEL_EMAIL, Destination: "  A@B.vn "}); err != nil || e.sms.dest != "a@b.vn" {
		t.Fatalf("email phải chuẩn hóa: %v %q", err, e.sms.dest)
	}
}

func TestOTPWrongAndExpired(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	rq, _ := e.svc.RequestOtp(ctx, &chatv1.RequestOtpRequest{Channel: chatv1.OtpChannel_OTP_CHANNEL_SMS, Destination: phone})
	right := e.sms.code
	wrong := "000000"
	if right == wrong {
		wrong = "111111"
	}
	for i := 0; i < account.OTPMaxAttempts; i++ {
		if _, err := e.svc.VerifyOtp(ctx, &chatv1.VerifyOtpRequest{ChallengeId: rq.ChallengeId, Code: wrong}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
			t.Fatalf("lần %d: %v", i, err)
		}
	}
	// vượt số lần: mã ĐÚNG cũng bị từ chối, và thử nữa thì mất challenge
	if _, err := e.svc.VerifyOtp(ctx, &chatv1.VerifyOtpRequest{ChallengeId: rq.ChallengeId, Code: right}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED {
		t.Fatalf("muốn RATE_LIMITED: %v", err)
	}
	if _, err := e.svc.VerifyOtp(ctx, &chatv1.VerifyOtpRequest{ChallengeId: rq.ChallengeId, Code: right}); err == nil {
		t.Fatal("challenge phải bị hủy")
	}

	// hết hạn
	e.now = e.now.Add(time.Minute)
	rq, _ = e.svc.RequestOtp(ctx, &chatv1.RequestOtpRequest{Channel: chatv1.OtpChannel_OTP_CHANNEL_SMS, Destination: phone})
	e.now = e.now.Add(account.OTPTTL + time.Second)
	if _, err := e.svc.VerifyOtp(ctx, &chatv1.VerifyOtpRequest{ChallengeId: rq.ChallengeId, Code: e.sms.code}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
		t.Fatalf("hết hạn: %v", err)
	}
	// dùng một lần
	e.now = e.now.Add(time.Minute)
	rq, _ = e.svc.RequestOtp(ctx, &chatv1.RequestOtpRequest{Channel: chatv1.OtpChannel_OTP_CHANNEL_SMS, Destination: phone})
	if _, err := e.svc.VerifyOtp(ctx, &chatv1.VerifyOtpRequest{ChallengeId: rq.ChallengeId, Code: e.sms.code}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.VerifyOtp(ctx, &chatv1.VerifyOtpRequest{ChallengeId: rq.ChallengeId, Code: e.sms.code}); err == nil {
		t.Fatal("mã đã dùng không được dùng lại")
	}
}

func TestRegisterDeviceHappyAndRefresh(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	acct, ticket, _ := e.login(phone)
	_, idKey, _ := ed25519.GenerateKey(nil)
	d := newDev()
	resp, bad := e.reg(acct, ticket, d, idKey, true)
	if bad != nil {
		t.Fatalf("%v", bad)
	}
	// token truy cập dùng được với Verifier chung của gateway
	cl, err := e.svc.Tokens.Verify(resp.Tokens.AccessToken, e.now)
	if err != nil || cl.Account != acct || cl.Device != d.id {
		t.Fatalf("%+v %v", cl, err)
	}
	if got, err := e.meta.GetDevice(ctx, d.id); err != nil || got.AccountID != acct {
		t.Fatalf("%+v %v", got, err)
	}
	// ticket dùng một lần
	_, bad = e.reg(acct, ticket, newDev(), idKey, true)
	wantCode(t, bad, chatv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED)

	// refresh xoay vòng
	e.now = e.now.Add(time.Hour)
	p2, rerr := e.svc.RefreshToken(ctx, &chatv1.RefreshTokenRequest{DeviceId: d.id.Bytes(), RefreshToken: resp.Tokens.RefreshToken})
	if rerr != nil || p2.RefreshToken == resp.Tokens.RefreshToken {
		t.Fatalf("%v", rerr)
	}
	if _, rerr := e.svc.RefreshToken(ctx, &chatv1.RefreshTokenRequest{DeviceId: d.id.Bytes(), RefreshToken: resp.Tokens.RefreshToken}); rerr == nil || rerr.Code != chatv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED {
		t.Fatalf("token cũ phải hết hiệu lực: %v", rerr)
	}
	// thiết bị khác không dùng được token của thiết bị này
	if _, rerr := e.svc.RefreshToken(ctx, &chatv1.RefreshTokenRequest{DeviceId: ids.New().Bytes(), RefreshToken: p2.RefreshToken}); rerr == nil {
		t.Fatal("sai thiết bị phải bị từ chối")
	}
	// thu hồi thì không làm mới được
	e.meta.RevokeDevice(d.id)
	if _, rerr := e.svc.RefreshToken(ctx, &chatv1.RefreshTokenRequest{DeviceId: d.id.Bytes(), RefreshToken: p2.RefreshToken}); rerr == nil || rerr.Code != chatv1.ErrorCode_ERROR_CODE_DEVICE_REVOKED {
		t.Fatalf("muốn DEVICE_REVOKED: %v", rerr)
	}
}

func TestRegisterDeviceRejections(t *testing.T) {
	e := newEnv(t)
	acct, ticket, _ := e.login(phone)
	_, idKey, _ := ed25519.GenerateKey(nil)
	_, otherKey, _ := ed25519.GenerateKey(nil)
	d := newDev()
	base := func() *chatv1.RegisterDeviceRequest {
		return &chatv1.RegisterDeviceRequest{
			SessionTicket: ticket, DeviceId: d.id.Bytes(), DevicePublicKey: d.pub,
			Credential:               account.SignCredential(idKey, acct, d.id, d.pub, 1),
			AccountIdentityPublicKey: idKey.Public().(ed25519.PublicKey),
			KeyPackages:              [][]byte{kp()}, LastResortKeyPackage: kp(),
		}
	}
	cases := map[string]func(r *chatv1.RegisterDeviceRequest){
		"credential ký bằng khóa khác khóa gửi lên": func(r *chatv1.RegisterDeviceRequest) {
			r.Credential = account.SignCredential(otherKey, acct, d.id, d.pub, 1)
		},
		"credential của tài khoản khác": func(r *chatv1.RegisterDeviceRequest) {
			r.Credential = account.SignCredential(idKey, ids.New(), d.id, d.pub, 1)
		},
		"credential của thiết bị khác": func(r *chatv1.RegisterDeviceRequest) {
			r.Credential = account.SignCredential(idKey, acct, ids.New(), d.pub, 1)
		},
		"khóa thiết bị khác credential": func(r *chatv1.RegisterDeviceRequest) { r.DevicePublicKey = newDev().pub },
		"credential cắt cụt":            func(r *chatv1.RegisterDeviceRequest) { r.Credential = r.Credential[:100] },
		"thiếu khóa danh tính":          func(r *chatv1.RegisterDeviceRequest) { r.AccountIdentityPublicKey = nil },
		"thiếu last resort":             func(r *chatv1.RegisterDeviceRequest) { r.LastResortKeyPackage = nil },
		"KeyPackage sai tiêu đề":        func(r *chatv1.RegisterDeviceRequest) { r.KeyPackages = [][]byte{[]byte("rac rac rac rac")} },
		"KeyPackage quá lớn":            func(r *chatv1.RegisterDeviceRequest) { r.KeyPackages = [][]byte{append(kp(), make([]byte, 5000)...)} },
		"quá 200 KeyPackage": func(r *chatv1.RegisterDeviceRequest) {
			r.KeyPackages = nil
			for i := 0; i < 201; i++ {
				r.KeyPackages = append(r.KeyPackages, kp())
			}
		},
		"device_id sai độ dài": func(r *chatv1.RegisterDeviceRequest) { r.DeviceId = []byte{1, 2} },
	}
	for name, mut := range cases {
		r := base()
		mut(r)
		if _, bad := e.regReq(r); bad == nil {
			t.Errorf("%s: phải bị từ chối", name)
		}
	}
	// không case nào làm cháy ticket
	if _, bad := e.regReq(base()); bad != nil {
		t.Fatalf("ticket phải còn dùng được: %v", bad)
	}
	// device_id trùng
	_, t2, _ := e.login("+84907654321")
	acct2, _ := ids.FromBytes(mustAcct(e, "+84907654321"))
	_ = acct2
	r := base()
	r.SessionTicket = t2
	_, bad := e.regReq(r)
	if bad == nil {
		t.Fatal("credential của tài khoản 1 không được dùng với ticket của tài khoản 2")
	}
}

func mustAcct(e *env, dest string) []byte {
	e.now = e.now.Add(time.Minute)
	acct, _, _ := e.login(dest)
	return acct.Bytes()
}

func TestSecondDeviceAndReset(t *testing.T) {
	e := newEnv(t)
	acct, ticket, _ := e.login(phone)
	_, idKey, _ := ed25519.GenerateKey(nil)
	if _, bad := e.reg(acct, ticket, newDev(), idKey, true); bad != nil {
		t.Fatal(bad)
	}
	// thiết bị thứ hai có khóa đúng (ví dụ khôi phục từ sao lưu), không gửi khóa công khai
	e.now = e.now.Add(time.Minute)
	_, t2, isNew := e.login(phone)
	if isNew {
		t.Fatal("không phải tài khoản mới")
	}
	if _, bad := e.reg(acct, t2, newDev(), idKey, false); bad != nil {
		t.Fatalf("thiết bị thứ hai: %v", bad)
	}
	// thiết bị thứ ba ký bằng khóa lạ, không có reset_identity: từ chối
	e.now = e.now.Add(time.Minute)
	_, t3, _ := e.login(phone)
	_, stranger, _ := ed25519.GenerateKey(nil)
	_, bad := e.reg(acct, t3, newDev(), stranger, false)
	wantCode(t, bad, chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)
	_, bad = e.reg(acct, t3, newDev(), stranger, true) // gửi khóa khác khóa đã đăng ký mà không reset
	wantCode(t, bad, chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)

	// reset_identity (6.14): khóa mới được ghi nhận
	d := newDev()
	r := &chatv1.RegisterDeviceRequest{
		SessionTicket: t3, DeviceId: d.id.Bytes(), DevicePublicKey: d.pub, ResetIdentity: true,
		Credential:               account.SignCredential(stranger, acct, d.id, d.pub, 1),
		AccountIdentityPublicKey: stranger.Public().(ed25519.PublicKey),
		KeyPackages:              [][]byte{kp()}, LastResortKeyPackage: kp(),
	}
	if _, bad := e.regReq(r); bad != nil {
		t.Fatalf("reset: %v", bad)
	}
	got, _ := e.svc.Store.IdentityKey(context.Background(), acct)
	if string(got) != string(stranger.Public().(ed25519.PublicKey)) {
		t.Fatal("khóa danh tính phải đổi sau reset")
	}
}

func TestKeyPackageService(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	acct, ticket, _ := e.login(phone)
	_, idKey, _ := ed25519.GenerateKey(nil)
	d := newDev()
	if _, bad := e.reg(acct, ticket, d, idKey, true); bad != nil { // 3 gói một lần + 1 last resort
		t.Fatal(bad)
	}
	di := store.DeviceInfo{DeviceID: d.id, AccountID: acct}
	if c, err := e.svc.CountKeyPackages(ctx, di); err != nil || c.Remaining != 3 {
		t.Fatalf("%v %v", c, err)
	}
	if c, err := e.svc.UploadKeyPackages(ctx, di, &chatv1.UploadKeyPackagesRequest{KeyPackages: [][]byte{kp(), kp()}}); err != nil || c.Remaining != 5 {
		t.Fatalf("%v %v", c, err)
	}
	if _, err := e.svc.UploadKeyPackages(ctx, di, &chatv1.UploadKeyPackagesRequest{KeyPackages: [][]byte{[]byte("rac rac rac rac")}}); err == nil {
		t.Fatal("gói rác phải bị từ chối")
	}

	// Fetch: tiêu thụ 1 gói, trả credential, khóa danh tính
	for i := 0; i < 5; i++ {
		f, err := e.svc.FetchKeyPackages(ctx, &chatv1.FetchKeyPackagesRequest{AccountIds: [][]byte{acct.Bytes(), acct.Bytes(), ids.New().Bytes()}})
		if err != nil || len(f.Accounts) != 1 { // trùng bị gộp, tài khoản lạ bị bỏ qua
			t.Fatalf("%v %v", f, err)
		}
		a := f.Accounts[0]
		if len(a.Devices) != 1 || a.Devices[0].LastResort || string(a.AccountIdentityPublicKey) != string(idKey.Public().(ed25519.PublicKey)) || len(a.Devices[0].Credential) != account.CredentialLen {
			t.Fatalf("%+v", a)
		}
	}
	f, _ := e.svc.FetchKeyPackages(ctx, &chatv1.FetchKeyPackagesRequest{AccountIds: [][]byte{acct.Bytes()}})
	if !f.Accounts[0].Devices[0].LastResort {
		t.Fatal("hết gói một lần phải trả last resort")
	}
	if c, _ := e.svc.CountKeyPackages(ctx, di); c.Remaining != 0 {
		t.Fatalf("còn %d", c.Remaining)
	}
	// giới hạn
	if _, err := e.svc.FetchKeyPackages(ctx, &chatv1.FetchKeyPackagesRequest{}); err == nil {
		t.Fatal("rỗng phải bị từ chối")
	}
	many := make([][]byte, account.MaxFetchAccounts+1)
	for i := range many {
		many[i] = ids.New().Bytes()
	}
	if _, err := e.svc.FetchKeyPackages(ctx, &chatv1.FetchKeyPackagesRequest{AccountIds: many}); err == nil {
		t.Fatal("quá 50 tài khoản phải bị từ chối")
	}
	// thu hồi thiết bị: không còn xuất hiện
	e.meta.RevokeDevice(d.id)
	f, _ = e.svc.FetchKeyPackages(ctx, &chatv1.FetchKeyPackagesRequest{AccountIds: [][]byte{acct.Bytes()}})
	if len(f.Accounts) != 1 || len(f.Accounts[0].Devices) != 0 {
		t.Fatalf("%+v", f)
	}
}

func TestCredentialRoundTrip(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(nil)
	a, d := ids.New(), ids.New()
	pub, _, _ := ed25519.GenerateKey(nil)
	b := account.SignCredential(priv, a, d, pub, 12345)
	c, err := account.ParseCredential(b)
	if err != nil || c.Account != a || c.Device != d || c.CreatedMs != 12345 || !c.Verify(priv.Public().(ed25519.PublicKey)) {
		t.Fatalf("%+v %v", c, err)
	}
	b[70] ^= 1 // sửa created_ms
	c, _ = account.ParseCredential(b)
	if c.Verify(priv.Public().(ed25519.PublicKey)) {
		t.Fatal("chữ ký phải hỏng khi sửa dữ liệu")
	}
	if _, err := account.ParseCredential(b[:135]); err == nil {
		t.Fatal("độ dài sai phải lỗi")
	}
}

func TestLookupAccount(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	target, _, _ := e.login("+84907776655")
	me, ticket, _ := e.login(phone)
	_, idKey, _ := ed25519.GenerateKey(nil)
	d := newDev()
	if _, bad := e.reg(me, ticket, d, idKey, true); bad != nil {
		t.Fatal(bad)
	}
	di := store.DeviceInfo{DeviceID: d.id, AccountID: me}
	sms := chatv1.OtpChannel_OTP_CHANNEL_SMS

	got, err := e.svc.LookupAccount(ctx, di, &chatv1.LookupAccountRequest{Channel: sms, Destination: "+84 907-776-655"})
	if err != nil || string(got.Profile.AccountId) != string(target.Bytes()) {
		t.Fatalf("%v %v", got, err)
	}
	if _, err := e.svc.LookupAccount(ctx, di, &chatv1.LookupAccountRequest{Channel: sms, Destination: "+84900000000"}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("muốn NOT_FOUND: %v", err)
	}
	if _, err := e.svc.LookupAccount(ctx, di, &chatv1.LookupAccountRequest{Channel: sms, Destination: "rac"}); err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT {
		t.Fatalf("muốn INVALID_ARGUMENT: %v", err)
	}
	// giới hạn 30 lần/giờ (đã dùng 2: lần đúng và lần NOT_FOUND; INVALID_ARGUMENT không tính), kể cả lần NOT_FOUND
	for i := 0; i < account.LookupLimit-2; i++ {
		if _, err := e.svc.LookupAccount(ctx, di, &chatv1.LookupAccountRequest{Channel: sms, Destination: "+84900000000"}); err == nil || err.Code == chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED {
			t.Fatalf("lần %d: %v", i, err)
		}
	}
	_, err = e.svc.LookupAccount(ctx, di, &chatv1.LookupAccountRequest{Channel: sms, Destination: "+84907776655"})
	if err == nil || err.Code != chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED || err.RetryAfterMs == 0 {
		t.Fatalf("muốn RATE_LIMITED kèm retry_after: %v", err)
	}
	e.now = e.now.Add(account.LookupWindow + time.Second) // hết cửa sổ thì tra lại được
	if _, err := e.svc.LookupAccount(ctx, di, &chatv1.LookupAccountRequest{Channel: sms, Destination: "+84907776655"}); err != nil {
		t.Fatal(err)
	}
}
