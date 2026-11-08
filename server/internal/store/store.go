// Package store: interface lưu trữ (MetaStore, MailboxStore) theo thiet-ke-chinh.md mục 5 và 13.
// Server chỉ làm việc với ciphertext; không kho nào chứa plaintext.
package store

import (
	"context"
	"errors"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
)

var (
	ErrNotFound      = errors.New("store: không tồn tại")
	ErrEpochMismatch = errors.New("store: epoch không khớp")
	ErrExists        = errors.New("store: đã tồn tại")
)

// EpochError mang epoch hiện tại để trả cho client.
type EpochError struct{ Current uint64 }

func (e *EpochError) Error() string { return ErrEpochMismatch.Error() }
func (e *EpochError) Unwrap() error { return ErrEpochMismatch }

// Entry là một mục trong conv_log.
type Entry struct {
	ConvID     ids.ID
	Seq        uint64
	Kind       chatv1.EntryKind
	Sender     ids.ID // device_id gửi
	Epoch      uint64 // epoch mà mục này thuộc về
	Ciphertext []byte
	TsMs       uint64
	MessageID  ids.ID
	// Fanout còn việc dở (con trỏ hộp thư, GroupInfo, thành viên). Rỗng khi đã xong.
	Pending *Fanout
}

// Fanout là việc phải hoàn tất sau giao dịch ghi log. Lưu cùng mục log để sau
// khi sập, bộ sửa chữa làm tiếp được; mọi bước idempotent.
type Fanout struct {
	Recipients []ids.ID // thiết bị nhận con trỏ (đã chốt lúc ghi)
	WelcomeTo  []ids.ID // thiết bị có Welcome trong hộp thư (để báo cho thiết bị đang online)
	// Chỉ có với Commit:
	GroupInfo   []byte
	NewEpoch    uint64
	Added       []*chatv1.Member
	RemovedAcct []ids.ID
	RoleChanges []*chatv1.Member
}

// Head là conv_head.
type Head struct {
	HeadSeq uint64
	Epoch   uint64
}

// InboxItem là con trỏ hộp thư. Welcome mang ciphertext trực tiếp.
type InboxItem struct {
	Device     ids.ID
	InboxID    ids.ID
	ConvID     ids.ID
	Seq        uint64
	Kind       chatv1.EntryKind
	Sender     ids.ID
	Epoch      uint64
	Ciphertext []byte // chỉ Welcome
	TsMs       uint64
}

// Welcome gửi tới một thiết bị trong cùng giao dịch với Commit.
type Welcome struct {
	Device     ids.ID
	Ciphertext []byte
}

// AppendMsgReq: tin APPLICATION hoặc PROPOSAL.
type AppendMsgReq struct {
	ConvID      ids.ID
	ClientMsgID ids.ID
	Epoch       uint64
	Kind        chatv1.EntryKind
	Sender      ids.ID
	Ciphertext  []byte
	TsMs        uint64
	Recipients  []ids.ID
}
type AppendResult struct {
	MessageID ids.ID
	Seq       uint64
	TsMs      uint64
	Duplicate bool
}

// CommitReq: ghi Commit nguyên tử, điều kiện epoch.
type CommitReq struct {
	ConvID        ids.ID
	ExpectedEpoch uint64
	Sender        ids.ID
	Ciphertext    []byte
	TsMs          uint64
	Welcomes      []Welcome
	Fanout        Fanout // Recipients đã tính trước thay đổi thành viên
	// IdemKey (Idempotency-Key của RPC) được ghi trong cùng giao dịch: gửi lại sau
	// khi mất kết nối nhận lại đúng kết quả cũ thay vì EPOCH_MISMATCH.
	IdemKey string
}
type CommitResult struct {
	Seq       uint64
	NewEpoch  uint64
	Duplicate bool
}

// MailboxStore: đường nóng (DynamoDB). Mọi thao tác ghi idempotent hoặc có điều kiện.
type MailboxStore interface {
	// CreateConv ghi conv_head (epoch 1, head_seq 1) và mục log seq=1 là Commit đầu,
	// cùng Welcome, trong một giao dịch. ErrExists nếu conv_id đã có.
	CreateConv(ctx context.Context, convID ids.ID, first CommitReq) (CommitResult, error)
	AppendMessage(ctx context.Context, r AppendMsgReq) (AppendResult, error)
	AppendCommit(ctx context.Context, r CommitReq) (CommitResult, error)
	GetHead(ctx context.Context, convID ids.ID) (Head, error)
	// GetLog trả các mục có seq > after, tối đa limit.
	GetLog(ctx context.Context, convID ids.ID, after uint64, limit int) ([]Entry, error)
	GetEntry(ctx context.Context, convID ids.ID, seq uint64) (Entry, error)

	// PutPointers ghi con trỏ hộp thư cho (conv, seq); ghi lại nhiều lần an toàn.
	PutPointers(ctx context.Context, e Entry, devices []ids.ID) error
	// CompleteFanout xóa Pending của mục log khi mọi bước đã xong.
	CompleteFanout(ctx context.Context, convID ids.ID, seq uint64) error
	// PendingFanouts liệt kê mục còn việc dở (cho bộ sửa chữa).
	PendingFanouts(ctx context.Context, limit int) ([]Entry, error)

	GetInboxItem(ctx context.Context, device, inboxID ids.ID) (InboxItem, error)
	ListInbox(ctx context.Context, device ids.ID, after ids.ID, limit int) ([]InboxItem, error)
	DeleteInbox(ctx context.Context, device ids.ID, inboxIDs []ids.ID) error
}

// DeviceInfo là một dòng devices.
type DeviceInfo struct {
	DeviceID  ids.ID
	AccountID ids.ID
	Platform  chatv1.Platform
	Revoked   bool
}

// MemberRow là một dòng members_by_conv.
type MemberRow struct {
	AccountID ids.ID
	Role      chatv1.Role
	Leaving   bool
}

// MetaStore: metadata quan hệ (PostgreSQL).
type MetaStore interface {
	GetDevice(ctx context.Context, device ids.ID) (DeviceInfo, error)
	// DevicesOfAccounts trả thiết bị chưa bị thu hồi của các tài khoản.
	DevicesOfAccounts(ctx context.Context, accounts []ids.ID) ([]DeviceInfo, error)

	// CreateConversation tạo hội thoại và thành viên. Gửi lại cùng groupID trả conv_id đã
	// cấp (existed=false). Với 1-1, nếu cặp tài khoản đã có hội thoại khác thì trả
	// (convID cũ, existed=true) và không ghi gì.
	CreateConversation(ctx context.Context, convID ids.ID, kind chatv1.ConvKind, groupID []byte, members []*chatv1.Member) (ids.ID, bool, error)
	GetMember(ctx context.Context, convID, account ids.ID) (MemberRow, error)
	Members(ctx context.Context, convID ids.ID) ([]MemberRow, error)
	// SetLeaving đánh dấu tài khoản đang xin rời (6.4); idempotent, ErrNotFound nếu không phải thành viên.
	SetLeaving(ctx context.Context, convID, account ids.ID) error
	// ApplyMembership áp dụng thay đổi thành viên của một Commit. Idempotent.
	ApplyMembership(ctx context.Context, convID ids.ID, added []*chatv1.Member, removed []ids.ID, roles []*chatv1.Member) error
	PutGroupInfo(ctx context.Context, convID ids.ID, epoch uint64, groupInfo []byte) error
	GetGroupInfo(ctx context.Context, convID ids.ID) (epoch uint64, groupInfo []byte, err error)
	ConversationKind(ctx context.Context, convID ids.ID) (chatv1.ConvKind, error)
	ListConversations(ctx context.Context, account ids.ID) ([]ids.ID, error)
}
