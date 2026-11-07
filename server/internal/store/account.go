package store

import (
	"context"
	"errors"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
)

var (
	ErrTicketInvalid    = errors.New("store: session_ticket không hợp lệ, đã dùng hoặc hết hạn")
	ErrIdentityMismatch = errors.New("store: khóa danh tính tài khoản đã đổi hoặc không khớp")
)

// OTPChallenge là một lần yêu cầu OTP. Chỉ lưu băm của mã.
type OTPChallenge struct {
	ID          ids.ID
	ContactHash []byte
	CodeHash    []byte
	Attempts    int
	CreatedAt   time.Time
	ExpiresAt   time.Time
}

// KeyPackage là một gói lưu cho thiết bị (blob là MLSMessage nguyên văn).
type KeyPackage struct {
	Blob       []byte
	LastResort bool
	ExpiresAt  time.Time
}

// RegisterDeviceReq: mọi thứ RegisterDevice ghi trong MỘT giao dịch (giao-thuc.md 6.1).
type RegisterDeviceReq struct {
	TicketHash []byte
	Device     ids.ID
	Platform   chatv1.Platform
	Name       string
	PublicKey  []byte
	Credential []byte
	// ExpectIdentity là khóa danh tính service đã thấy khi kiểm chữ ký (nil: tài khoản chưa có).
	// NewIdentity khác nil: ghi khóa này (thiết bị đầu tiên hoặc reset_identity). Giao dịch chỉ
	// thành công nếu khóa hiện tại vẫn bằng ExpectIdentity (so-và-đặt, chống hai thiết bị tranh nhau).
	ExpectIdentity []byte
	NewIdentity    []byte
	KeyPackages    []KeyPackage
	RefreshHash    []byte
	RefreshExpires time.Time
	Now            time.Time
}

// DeviceKeys là thông tin khóa công khai của một thiết bị còn hiệu lực.
type DeviceKeys struct {
	DeviceID   ids.ID
	Credential []byte
}

// AccountStore: tài khoản, OTP, ticket, token làm mới, thiết bị và KeyPackage (PostgreSQL).
type AccountStore interface {
	// UpsertAccount tìm tài khoản theo băm liên hệ, chưa có thì tạo với id mới.
	UpsertAccount(ctx context.Context, contactHash []byte, newID ids.ID) (acct ids.ID, isNew bool, err error)
	// AccountByContact tìm tài khoản theo băm liên hệ; ErrNotFound nếu không có.
	AccountByContact(ctx context.Context, contactHash []byte) (ids.ID, error)
	// IdentityKey trả khóa danh tính hiện tại (nil nếu chưa có); ErrNotFound nếu không có tài khoản.
	IdentityKey(ctx context.Context, acct ids.ID) ([]byte, error)

	PutOTP(ctx context.Context, c OTPChallenge) error
	// LatestOTP trả lần yêu cầu gần nhất tới liên hệ này; ErrNotFound nếu chưa có.
	LatestOTP(ctx context.Context, contactHash []byte) (OTPChallenge, error)
	GetOTP(ctx context.Context, id ids.ID) (OTPChallenge, error)
	// IncOTPAttempts tăng số lần nhập và trả giá trị mới (nguyên tử).
	IncOTPAttempts(ctx context.Context, id ids.ID) (int, error)
	DeleteOTP(ctx context.Context, id ids.ID) error

	PutTicket(ctx context.Context, hash []byte, acct ids.ID, isNew bool, expires time.Time) error
	// TicketAccount đọc ticket còn hiệu lực mà không tiêu thụ; ErrTicketInvalid nếu không hợp lệ.
	TicketAccount(ctx context.Context, hash []byte, now time.Time) (acct ids.ID, isNew bool, err error)

	// RegisterDevice: xem RegisterDeviceReq. ErrTicketInvalid, ErrIdentityMismatch, ErrExists.
	RegisterDevice(ctx context.Context, r RegisterDeviceReq) (acct ids.ID, err error)
	// RotateRefresh đổi refresh token cũ lấy token mới (nguyên tử). ErrNotFound nếu token cũ
	// không có, hết hạn hoặc không thuộc thiết bị.
	RotateRefresh(ctx context.Context, device ids.ID, oldHash, newHash []byte, newExpires, now time.Time) error

	PutKeyPackages(ctx context.Context, device ids.ID, kps []KeyPackage) error
	// CountKeyPackages đếm gói một lần còn hạn (không tính last resort).
	CountKeyPackages(ctx context.Context, device ids.ID, now time.Time) (int, error)
	// TakeKeyPackage lấy và xóa một gói một lần còn hạn; hết thì trả last resort (không xóa,
	// lastResort=true). ErrNotFound nếu thiết bị không còn gói nào.
	TakeKeyPackage(ctx context.Context, device ids.ID, now time.Time) (blob []byte, lastResort bool, err error)
	// AccountKeys trả khóa danh tính, thiết bị chưa thu hồi (kèm credential) và các bản thu hồi.
	AccountKeys(ctx context.Context, acct ids.ID) (identity []byte, devices []DeviceKeys, revocations [][]byte, err error)
}
