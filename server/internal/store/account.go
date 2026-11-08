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

// DeviceLink là thiết bị mới đang chờ thiết bị cũ duyệt (giao-thuc.md 6.5). Account khác không
// nghĩa là đã được duyệt.
type DeviceLink struct {
	ID         ids.ID
	ShortCode  string
	Platform   chatv1.Platform
	Name       string
	DevicePub  []byte
	Ephemeral  []byte
	Account    ids.ID
	Credential []byte
	Sealed     []byte
	ExpiresAt  time.Time
}

// DeviceRow là một thiết bị của tài khoản kèm thông tin hiển thị (ListDevices).
type DeviceRow struct {
	DeviceID   ids.ID
	Platform   chatv1.Platform
	Name       string
	CreatedMs  uint64
	LastSeenMs uint64
	Revoked    bool
}

// BackupRow là một bản sao lưu đã cấp URL (đối tượng có thể chưa được tải lên).
type BackupRow struct {
	ObjectKey string
	Size      uint64
	CreatedMs uint64
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
	PutLink(ctx context.Context, l DeviceLink) error
	// GetLink: ErrNotFound nếu không có hoặc hết hạn.
	GetLink(ctx context.Context, id ids.ID, now time.Time) (DeviceLink, error)
	// ApproveLink ghi credential + sealed_bundle (nguyên tử, chỉ một lần): ErrNotFound nếu không có/hết hạn,
	// ErrExists nếu đã duyệt.
	ApproveLink(ctx context.Context, id, acct ids.ID, credential, sealed []byte, now time.Time) error
	// TakeApprovedLink lấy và xóa liên kết đã duyệt (nguyên tử); ErrNotFound nếu chưa duyệt/không có/hết hạn.
	TakeApprovedLink(ctx context.Context, id ids.ID, now time.Time) (DeviceLink, error)
	// ListDevices trả mọi thiết bị của tài khoản, kể cả đã thu hồi, theo thứ tự đăng ký.
	ListDevices(ctx context.Context, acct ids.ID) ([]DeviceRow, error)
	// RevokeAccountDevice thu hồi một thiết bị của tài khoản trong một giao dịch: đánh dấu, xóa KeyPackage và refresh
	// token, lưu statement. ErrNotFound nếu thiết bị không thuộc tài khoản; ErrExists nếu đã thu hồi.
	RevokeAccountDevice(ctx context.Context, acct, device ids.ID, statement []byte, now time.Time) error
	PutBackup(ctx context.Context, acct ids.ID, objectKey string, size uint64, now time.Time) error
	// Backups trả các bản sao lưu của tài khoản, mới nhất trước, tối đa limit.
	Backups(ctx context.Context, acct ids.ID, limit int) ([]BackupRow, error)
	// AccountKeys trả khóa danh tính, thiết bị chưa thu hồi (kèm credential) và các bản thu hồi.
	AccountKeys(ctx context.Context, acct ids.ID) (identity []byte, devices []DeviceKeys, revocations [][]byte, err error)
}
