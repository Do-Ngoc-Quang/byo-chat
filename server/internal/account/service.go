package account

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"sync"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/auth"
	"byo-chat/server/internal/blob"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/store"
)

// Tham số (giao-thuc.md mục 2 và 6.1).
const (
	OTPTTL            = 5 * time.Minute
	OTPMaxAttempts    = 5
	OTPMinInterval    = 30 * time.Second
	TicketTTL         = 10 * time.Minute
	AccessTTL         = 15 * time.Minute
	RefreshTTL        = 30 * 24 * time.Hour
	LookupLimit       = 30 // lần tra mỗi cửa sổ (giao-thuc.md 6.12)
	LookupWindow      = time.Hour
	OneTimeKPTTL      = 30 * 24 * time.Hour
	LastResortKPTTL   = 90 * 24 * time.Hour
	MaxKeyPackage     = 4 << 10
	MaxKPUpload       = 200
	MaxKPStored       = 500 // gói một lần tối đa mỗi thiết bị
	MaxFetchAccounts  = 50
	MaxDeviceNameLen  = 64
	otpCodeDigits     = 6
	ed25519PublicSize = 32
)

// OTPSender gửi mã OTP tới người dùng. Chưa có nhà cung cấp SMS/email thật (ADR 0007).
type OTPSender interface {
	Send(ctx context.Context, channel chatv1.OtpChannel, destination, code string) error
}

// LogSender chỉ dùng khi phát triển: ghi mã OTP vào log. KHÔNG bật ở môi trường thật.
type LogSender struct{ Log *slog.Logger }

func (l LogSender) Send(_ context.Context, ch chatv1.OtpChannel, dest, code string) error {
	l.Log.Warn("DEV OTP (chỉ dùng khi phát triển)", "channel", ch.String(), "destination", dest, "code", code)
	return nil
}

type Service struct {
	Store  store.AccountStore
	Meta   store.MetaStore
	Tokens *auth.HMAC
	// OnRevoke chạy sau khi một thiết bị bị thu hồi (đóng kết nối đang mở). Có thể nil.
	OnRevoke   func(device ids.ID)
	Blobs      blob.Signer // kho sao lưu (nil: BackupService báo UNAVAILABLE)
	Sender     OTPSender
	ContactKey []byte // khóa HMAC để băm đích liên hệ và mã OTP
	// DevFixedCode khác rỗng thì mọi OTP dùng mã này (CHỈ cho dev/e2e, bật qua CHAT_DEV_OTP_CODE).
	DevFixedCode string

	lookupMu sync.Mutex
	lookups  map[ids.ID][]time.Time // lần tra gần đây theo tài khoản (cửa sổ trượt)
	Now      func() time.Time
	Log      *slog.Logger
}

func New(st store.AccountStore, meta store.MetaStore, tokens *auth.HMAC, sender OTPSender, contactKey []byte) *Service {
	return &Service{Store: st, Meta: meta, Tokens: tokens, Sender: sender, ContactKey: contactKey, Now: time.Now, Log: slog.Default()}
}

func perr(c chatv1.ErrorCode, f string, a ...any) *message.Error {
	return &message.Error{Code: c, Msg: fmt.Sprintf(f, a...)}
}

func internal(s *Service, op string, err error) *message.Error {
	s.Log.Error("lỗi nội bộ", "op", op, "err", err)
	return perr(chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "lỗi nội bộ")
}

var (
	phoneRe = regexp.MustCompile(`^\+[1-9][0-9]{7,14}$`)
	emailRe = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)
)

// normalizeContact chuẩn hóa đích trước khi băm (giao-thuc.md 6.1).
func normalizeContact(ch chatv1.OtpChannel, dest string) (string, bool) {
	switch ch {
	case chatv1.OtpChannel_OTP_CHANNEL_EMAIL:
		d := strings.ToLower(strings.TrimSpace(dest))
		return d, len(d) <= 254 && emailRe.MatchString(d)
	case chatv1.OtpChannel_OTP_CHANNEL_SMS:
		d := strings.NewReplacer(" ", "", "-", "").Replace(dest)
		return d, phoneRe.MatchString(d)
	}
	return "", false
}

func (s *Service) mac(domain string, parts ...[]byte) []byte {
	m := hmac.New(sha256.New, s.ContactKey)
	m.Write([]byte(domain))
	for _, p := range parts {
		m.Write(p)
	}
	return m.Sum(nil)
}

func randBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err) // hết entropy
	}
	return b
}

func sha(b []byte) []byte { h := sha256.Sum256(b); return h[:] }

// otpCode sinh mã 6 chữ số đều (loại bỏ thiên lệch bằng rand.Int).
func otpCode() string {
	var n uint32
	for {
		b := randBytes(4)
		n = uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
		if n < 4294000000 { // bội số của 10^6 gần 2^32: bỏ phần dư
			break
		}
	}
	return fmt.Sprintf("%0*d", otpCodeDigits, n%1_000_000)
}

func (s *Service) RequestOtp(ctx context.Context, r *chatv1.RequestOtpRequest) (*chatv1.RequestOtpResponse, *message.Error) {
	dest, ok := normalizeContact(r.Channel, r.Destination)
	if !ok {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "kênh hoặc đích không hợp lệ")
	}
	now := s.Now()
	ch := s.mac("contact", []byte(dest))
	if last, err := s.Store.LatestOTP(ctx, ch); err == nil {
		if wait := last.CreatedAt.Add(OTPMinInterval).Sub(now); wait > 0 {
			return nil, &message.Error{Code: chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED, Msg: "yêu cầu OTP quá nhanh", RetryAfterMs: uint32(wait.Milliseconds()) + 1}
		}
	} else if !errors.Is(err, store.ErrNotFound) {
		return nil, internal(s, "LatestOTP", err)
	}
	id, code := ids.New(), otpCode()
	if s.DevFixedCode != "" {
		code = s.DevFixedCode
	}
	c := store.OTPChallenge{ID: id, ContactHash: ch, CodeHash: s.mac("otp", id[:], []byte(code)), CreatedAt: now, ExpiresAt: now.Add(OTPTTL)}
	if err := s.Store.PutOTP(ctx, c); err != nil {
		return nil, internal(s, "PutOTP", err)
	}
	if err := s.Sender.Send(ctx, r.Channel, dest, code); err != nil {
		_ = s.Store.DeleteOTP(ctx, id)
		return nil, internal(s, "Send", err)
	}
	// Cùng một phản hồi dù tài khoản có tồn tại hay không (không lộ số đã đăng ký).
	return &chatv1.RequestOtpResponse{ChallengeId: id.Bytes(), RetryAfterMs: uint32(OTPMinInterval.Milliseconds())}, nil
}

func (s *Service) VerifyOtp(ctx context.Context, r *chatv1.VerifyOtpRequest) (*chatv1.VerifyOtpResponse, *message.Error) {
	bad := perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "mã không đúng hoặc đã hết hạn")
	id, err := ids.FromBytes(r.ChallengeId)
	if err != nil {
		return nil, bad
	}
	now := s.Now()
	c, err := s.Store.GetOTP(ctx, id)
	if errors.Is(err, store.ErrNotFound) {
		return nil, bad
	} else if err != nil {
		return nil, internal(s, "GetOTP", err)
	}
	if !now.Before(c.ExpiresAt) {
		_ = s.Store.DeleteOTP(ctx, id)
		return nil, bad
	}
	n, err := s.Store.IncOTPAttempts(ctx, id) // đếm TRƯỚC khi so sánh để đoán đồng thời cũng bị chặn
	if errors.Is(err, store.ErrNotFound) {
		return nil, bad
	} else if err != nil {
		return nil, internal(s, "IncOTPAttempts", err)
	}
	if n > OTPMaxAttempts {
		_ = s.Store.DeleteOTP(ctx, id)
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED, "nhập sai quá số lần cho phép, hãy yêu cầu mã mới")
	}
	want := s.mac("otp", id[:], []byte(r.Code))
	if subtle.ConstantTimeCompare(want, c.CodeHash) != 1 {
		return nil, bad
	}
	if err := s.Store.DeleteOTP(ctx, id); err != nil {
		return nil, internal(s, "DeleteOTP", err)
	}
	acct, isNew, err := s.Store.UpsertAccount(ctx, c.ContactHash, ids.New())
	if err != nil {
		return nil, internal(s, "UpsertAccount", err)
	}
	ticket := randBytes(32)
	if err := s.Store.PutTicket(ctx, sha(ticket), acct, isNew, now.Add(TicketTTL)); err != nil {
		return nil, internal(s, "PutTicket", err)
	}
	return &chatv1.VerifyOtpResponse{AccountId: acct.Bytes(), IsNewAccount: isNew, SessionTicket: ticket}, nil
}

func (s *Service) pair(acct, dev ids.ID, now time.Time) (*chatv1.TokenPair, []byte, time.Time) {
	exp := now.Add(AccessTTL)
	refresh := randBytes(32)
	return &chatv1.TokenPair{
		AccessToken:     s.Tokens.Issue(auth.Claims{Account: acct, Device: dev, Expires: exp}),
		RefreshToken:    encodeRefresh(refresh),
		AccessExpiresMs: uint64(exp.UnixMilli()),
	}, sha(refresh), now.Add(RefreshTTL)
}

func (s *Service) RefreshToken(ctx context.Context, r *chatv1.RefreshTokenRequest) (*chatv1.TokenPair, *message.Error) {
	unauth := perr(chatv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, "refresh token không hợp lệ")
	dev, err := ids.FromBytes(r.DeviceId)
	if err != nil {
		return nil, unauth
	}
	old, ok := decodeRefresh(r.RefreshToken)
	if !ok {
		return nil, unauth
	}
	d, err := s.Meta.GetDevice(ctx, dev)
	if err != nil {
		return nil, unauth
	}
	if d.Revoked {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_DEVICE_REVOKED, "thiết bị đã bị thu hồi")
	}
	now := s.Now()
	p, hash, exp := s.pair(d.AccountID, dev, now)
	if err := s.Store.RotateRefresh(ctx, dev, sha(old), hash, exp, now); errors.Is(err, store.ErrNotFound) {
		return nil, unauth
	} else if err != nil {
		return nil, internal(s, "RotateRefresh", err)
	}
	return p, nil
}

func (s *Service) RegisterDevice(ctx context.Context, r *chatv1.RegisterDeviceRequest) (*chatv1.RegisterDeviceResponse, *message.Error) {
	inv := func(f string, a ...any) *message.Error {
		return perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, f, a...)
	}
	now := s.Now()
	dev, err := ids.FromBytes(r.DeviceId)
	if err != nil || dev.IsZero() {
		return nil, inv("device_id không hợp lệ")
	}
	if len(r.DeviceName) > MaxDeviceNameLen {
		return nil, inv("device_name quá dài")
	}
	if len(r.DevicePublicKey) != ed25519PublicSize {
		return nil, inv("device_public_key phải 32 byte")
	}
	th := sha(r.SessionTicket)
	acct, _, err := s.Store.TicketAccount(ctx, th, now)
	if errors.Is(err, store.ErrTicketInvalid) {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, "session_ticket không hợp lệ hoặc hết hạn")
	} else if err != nil {
		return nil, internal(s, "TicketAccount", err)
	}
	cred, err := ParseCredential(r.Credential)
	if err != nil {
		return nil, inv("credential sai bố cục")
	}
	if cred.Account != acct || cred.Device != dev || string(cred.DevicePub) != string(r.DevicePublicKey) {
		return nil, inv("credential không khớp tài khoản, thiết bị hoặc khóa thiết bị")
	}

	// Chọn khóa danh tính dùng để kiểm chữ ký (giao-thuc.md 6.1 bước 5 và 6.14).
	stored, err := s.Store.IdentityKey(ctx, acct)
	if err != nil {
		return nil, internal(s, "IdentityKey", err)
	}
	var candidate, newIdentity []byte
	switch {
	case len(stored) == 0 || r.ResetIdentity:
		if len(r.AccountIdentityPublicKey) != ed25519PublicSize {
			return nil, inv("thiết bị đầu tiên (hoặc reset_identity) phải gửi account_identity_public_key 32 byte")
		}
		candidate, newIdentity = r.AccountIdentityPublicKey, r.AccountIdentityPublicKey
	default:
		if len(r.AccountIdentityPublicKey) != 0 && string(r.AccountIdentityPublicKey) != string(stored) {
			return nil, inv("account_identity_public_key khác khóa đã đăng ký (dùng reset_identity nếu khôi phục không có sao lưu)")
		}
		candidate = stored
	}
	if !cred.Verify(candidate) {
		return nil, inv("chữ ký credential sai")
	}

	kps, e := s.checkKeyPackages(now, r.KeyPackages, r.LastResortKeyPackage)
	if e != nil {
		return nil, e
	}
	if len(r.LastResortKeyPackage) == 0 {
		return nil, inv("thiếu last_resort_key_package")
	}
	tokens, rh, rexp := s.pair(acct, dev, now)
	_, err = s.Store.RegisterDevice(ctx, store.RegisterDeviceReq{
		TicketHash: th, Device: dev, Platform: r.Platform, Name: r.DeviceName,
		PublicKey: r.DevicePublicKey, Credential: r.Credential,
		ExpectIdentity: stored, NewIdentity: newIdentity,
		KeyPackages: kps, RefreshHash: rh, RefreshExpires: rexp, Now: now,
	})
	switch {
	case errors.Is(err, store.ErrTicketInvalid):
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, "session_ticket không hợp lệ hoặc hết hạn")
	case errors.Is(err, store.ErrExists):
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_ALREADY_EXISTS, "device_id đã được dùng")
	case errors.Is(err, store.ErrIdentityMismatch):
		return nil, inv("khóa danh tính tài khoản vừa thay đổi, hãy thử lại")
	case err != nil:
		return nil, internal(s, "RegisterDevice", err)
	}
	return &chatv1.RegisterDeviceResponse{Tokens: tokens}, nil
}

// checkKeyPackages kiểm kích thước, số lượng và tiêu đề MLSMessage; gán hạn dùng phía server.
// Chưa phân tích sâu nội dung MLS (xem ADR 0007).
func (s *Service) checkKeyPackages(now time.Time, oneTime [][]byte, lastResort []byte) ([]store.KeyPackage, *message.Error) {
	if len(oneTime) > MaxKPUpload {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE, "tối đa %d KeyPackage mỗi lần", MaxKPUpload)
	}
	out := make([]store.KeyPackage, 0, len(oneTime)+1)
	check := func(b []byte) *message.Error {
		if len(b) == 0 || len(b) > MaxKeyPackage {
			return perr(chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE, "KeyPackage phải từ 1 tới %d byte", MaxKeyPackage)
		}
		if !hasKeyPackageHeader(b) {
			return perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "KeyPackage không phải MLSMessage của cipher suite đã chốt")
		}
		return nil
	}
	for _, b := range oneTime {
		if e := check(b); e != nil {
			return nil, e
		}
		out = append(out, store.KeyPackage{Blob: b, ExpiresAt: now.Add(OneTimeKPTTL)})
	}
	if len(lastResort) > 0 {
		if e := check(lastResort); e != nil {
			return nil, e
		}
		out = append(out, store.KeyPackage{Blob: lastResort, LastResort: true, ExpiresAt: now.Add(LastResortKPTTL)})
	}
	return out, nil
}

// hasKeyPackageHeader: MLSMessage { version=mls10 (1), wire_format=key_package (5) } rồi KeyPackage
// { version=mls10 (1), cipher_suite=MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519 (1) }, mỗi trường u16 big-endian.
func hasKeyPackageHeader(b []byte) bool {
	return len(b) >= 8 && b[0] == 0 && b[1] == 1 && b[2] == 0 && b[3] == 5 && b[4] == 0 && b[5] == 1 && b[6] == 0 && b[7] == 1
}

func (s *Service) UploadKeyPackages(ctx context.Context, dev store.DeviceInfo, r *chatv1.UploadKeyPackagesRequest) (*chatv1.KeyPackageCount, *message.Error) {
	now := s.Now()
	kps, e := s.checkKeyPackages(now, r.KeyPackages, nil)
	if e != nil {
		return nil, e
	}
	have, err := s.Store.CountKeyPackages(ctx, dev.DeviceID, now)
	if err != nil {
		return nil, internal(s, "CountKeyPackages", err)
	}
	if have+len(kps) > MaxKPStored {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE, "tối đa %d KeyPackage một lần mỗi thiết bị", MaxKPStored)
	}
	if err := s.Store.PutKeyPackages(ctx, dev.DeviceID, kps); err != nil {
		return nil, internal(s, "PutKeyPackages", err)
	}
	return &chatv1.KeyPackageCount{Remaining: uint32(have + len(kps))}, nil
}

func (s *Service) CountKeyPackages(ctx context.Context, dev store.DeviceInfo) (*chatv1.KeyPackageCount, *message.Error) {
	n, err := s.Store.CountKeyPackages(ctx, dev.DeviceID, s.Now())
	if err != nil {
		return nil, internal(s, "CountKeyPackages", err)
	}
	return &chatv1.KeyPackageCount{Remaining: uint32(n)}, nil
}

// FetchKeyPackages trả mỗi thiết bị còn hiệu lực một gói, tiêu thụ gói một lần (giao-thuc.md 6.2).
// Tài khoản không tồn tại bị bỏ qua. Chưa có giới hạn tốc độ riêng (ADR 0007, hệ quả).
func (s *Service) FetchKeyPackages(ctx context.Context, r *chatv1.FetchKeyPackagesRequest) (*chatv1.FetchKeyPackagesResponse, *message.Error) {
	if len(r.AccountIds) == 0 || len(r.AccountIds) > MaxFetchAccounts {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "account_ids phải từ 1 tới %d", MaxFetchAccounts)
	}
	now := s.Now()
	resp := &chatv1.FetchKeyPackagesResponse{}
	seen := map[ids.ID]bool{}
	for _, raw := range r.AccountIds {
		acct, err := ids.FromBytes(raw)
		if err != nil {
			return nil, perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "account_id: %v", err)
		}
		if seen[acct] {
			continue
		}
		seen[acct] = true
		ident, devs, revs, err := s.Store.AccountKeys(ctx, acct)
		if errors.Is(err, store.ErrNotFound) {
			continue
		} else if err != nil {
			return nil, internal(s, "AccountKeys", err)
		}
		ak := &chatv1.AccountKeys{AccountId: acct.Bytes(), AccountIdentityPublicKey: ident, RevocationStatements: revs}
		for _, d := range devs {
			blob, last, err := s.Store.TakeKeyPackage(ctx, d.DeviceID, now)
			if errors.Is(err, store.ErrNotFound) {
				continue // thiết bị hết gói: bỏ qua, client thấy thiếu thiết bị
			} else if err != nil {
				return nil, internal(s, "TakeKeyPackage", err)
			}
			ak.Devices = append(ak.Devices, &chatv1.DeviceKeyPackage{DeviceId: d.DeviceID.Bytes(), KeyPackage: blob, LastResort: last, Credential: d.Credential})
		}
		resp.Accounts = append(resp.Accounts, ak)
	}
	return resp, nil
}

// LookupAccount tra tài khoản theo số điện thoại/email nhập chính xác (giao-thuc.md 6.12). Có giới hạn
// tốc độ theo tài khoản gọi để chống dò số; không có thì NOT_FOUND (không phân biệt lý do khác).
func (s *Service) LookupAccount(ctx context.Context, dev store.DeviceInfo, r *chatv1.LookupAccountRequest) (*chatv1.LookupAccountResponse, *message.Error) {
	dest, ok := normalizeContact(r.Channel, r.Destination)
	if !ok {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "kênh hoặc đích không hợp lệ")
	}
	now := s.Now()
	s.lookupMu.Lock()
	if s.lookups == nil {
		s.lookups = map[ids.ID][]time.Time{}
	}
	recent := s.lookups[dev.AccountID][:0:0]
	for _, t := range s.lookups[dev.AccountID] {
		if now.Sub(t) < LookupWindow {
			recent = append(recent, t)
		}
	}
	if len(recent) >= LookupLimit {
		wait := recent[0].Add(LookupWindow).Sub(now)
		s.lookups[dev.AccountID] = recent
		s.lookupMu.Unlock()
		return nil, &message.Error{Code: chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED, Msg: "tra cứu quá nhiều", RetryAfterMs: uint32(wait.Milliseconds()) + 1}
	}
	s.lookups[dev.AccountID] = append(recent, now)
	s.lookupMu.Unlock()

	id, err := s.Store.AccountByContact(ctx, s.mac("contact", []byte(dest)))
	if errors.Is(err, store.ErrNotFound) {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "không tìm thấy tài khoản")
	} else if err != nil {
		return nil, internal(s, "AccountByContact", err)
	}
	return &chatv1.LookupAccountResponse{Profile: &chatv1.Profile{AccountId: id.Bytes()}}, nil
}
