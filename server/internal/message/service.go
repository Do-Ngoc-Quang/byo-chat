package message

import (
	"context"
	"log/slog"
	"time"

	chatv1 "github.com/Do-Ngoc-Quang/byo-chat/server/gen/chat/v1"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/ids"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store"
)

// Giới hạn (giao-thuc.md mục 2). Commit/GroupInfo chặn 128 KiB để mục log kèm
// Pending vẫn dưới 400 KB của DynamoDB.
const (
	MaxCiphertext   = 64 << 10
	MaxCommit       = 128 << 10
	MaxGroupInfo    = 128 << 10
	MaxWelcomes     = 50 // thiết bị mỗi Commit
	MaxWelcomeBytes = 3 << 20
	MaxGroupDevs    = 1000
	MaxFetchLimit   = 200
	DefaultFetch    = 100
	maxMembersCall  = 1000
)

// Service là Message Service.
type Service struct {
	Meta    store.MetaStore
	Mailbox store.MailboxStore
	Queue   Queue
	Bus     Bus
	Now     func() time.Time
	Log     *slog.Logger
}

func New(meta store.MetaStore, mb store.MailboxStore, q Queue, bus Bus) *Service {
	return &Service{Meta: meta, Mailbox: mb, Queue: q, Bus: bus, Now: time.Now, Log: slog.Default()}
}

func (s *Service) nowMs() uint64 { return uint64(s.Now().UnixMilli()) }

func parseID(b []byte, name string) (ids.ID, *Error) {
	id, err := ids.FromBytes(b)
	if err != nil {
		return id, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "%s: %v", name, err)
	}
	return id, nil
}

// member kiểm tra thiết bị gọi thuộc tài khoản đang là thành viên (và không đang rời nhóm khi ghi).
func (s *Service) member(ctx context.Context, dev store.DeviceInfo, conv ids.ID) (store.MemberRow, *Error) {
	row, err := s.Meta.GetMember(ctx, conv, dev.AccountID)
	if err != nil {
		// Không lộ hội thoại tồn tại hay không với người ngoài.
		return row, errf(chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "không phải thành viên")
	}
	return row, nil
}

// recipients: thiết bị còn hiệu lực của mọi thành viên, trừ thiết bị gửi.
func (s *Service) recipients(ctx context.Context, conv, sender ids.ID) ([]ids.ID, *Error) {
	rows, err := s.Meta.Members(ctx, conv)
	if err != nil {
		return nil, toErr(err)
	}
	accts := make([]ids.ID, 0, len(rows))
	for _, r := range rows {
		accts = append(accts, r.AccountID)
	}
	devs, err := s.Meta.DevicesOfAccounts(ctx, accts)
	if err != nil {
		return nil, toErr(err)
	}
	out := make([]ids.ID, 0, len(devs))
	for _, d := range devs {
		if d.DeviceID != sender {
			out = append(out, d.DeviceID)
		}
	}
	return out, nil
}

// SendMessage xử lý tin APPLICATION từ WebSocket (giao-thuc.md mục 3, thiet-ke-chinh mục 8).
func (s *Service) SendMessage(ctx context.Context, dev store.DeviceInfo, req *chatv1.SendMessage) (*chatv1.SendResult, *Error) {
	conv, e := parseID(req.ConvId, "conv_id")
	if e != nil {
		return nil, e
	}
	cmid, e := parseID(req.ClientMsgId, "client_msg_id")
	if e != nil {
		return nil, e
	}
	if len(req.Ciphertext) == 0 {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "ciphertext rỗng")
	}
	if len(req.Ciphertext) > MaxCiphertext {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE, "ciphertext vượt %d byte", MaxCiphertext)
	}
	if _, e := s.member(ctx, dev, conv); e != nil {
		return nil, e
	}
	recips, e := s.recipients(ctx, conv, dev.DeviceID)
	if e != nil {
		return nil, e
	}
	ts := s.nowMs()
	if req.Ephemeral {
		// Không ghi log/hộp thư; chỉ kiểm tra epoch rồi đẩy qua bus cho thiết bị đang online.
		h, err := s.Mailbox.GetHead(ctx, conv)
		if err != nil {
			return nil, toErr(err)
		}
		if req.MlsEpoch != h.Epoch {
			return nil, &Error{Code: chatv1.ErrorCode_ERROR_CODE_EPOCH_MISMATCH, Msg: "epoch không khớp", CurrentEpoch: h.Epoch}
		}
		d := &chatv1.Deliver{ConvId: conv.Bytes(), Kind: chatv1.EntryKind_ENTRY_KIND_APPLICATION,
			SenderDeviceId: dev.DeviceID.Bytes(), MlsEpoch: h.Epoch, Ciphertext: req.Ciphertext, ServerTsMs: ts}
		s.publishDeliver(recips, d)
		return &chatv1.SendResult{ClientMsgId: cmid.Bytes(), ServerTsMs: ts}, nil
	}
	res, err := s.Mailbox.AppendMessage(ctx, store.AppendMsgReq{
		ConvID: conv, ClientMsgID: cmid, Epoch: req.MlsEpoch, Kind: chatv1.EntryKind_ENTRY_KIND_APPLICATION,
		Sender: dev.DeviceID, Ciphertext: req.Ciphertext, TsMs: ts, Recipients: recips,
	})
	if err != nil {
		return nil, toErr(err)
	}
	if !res.Duplicate {
		s.enqueue(ctx, conv, res.Seq)
	}
	return &chatv1.SendResult{ClientMsgId: cmid.Bytes(), MessageId: res.MessageID.Bytes(),
		Seq: res.Seq, ServerTsMs: res.TsMs, Duplicate: res.Duplicate}, nil
}

// SubmitProposal ghi Proposal (vd. xin rời nhóm) như một mục log, kiểm tra epoch như SendMessage.
func (s *Service) SubmitProposal(ctx context.Context, dev store.DeviceInfo, idem string, req *chatv1.SubmitProposalRequest) (*chatv1.SubmitProposalResponse, *Error) {
	conv, e := parseID(req.ConvId, "conv_id")
	if e != nil {
		return nil, e
	}
	if len(req.Proposal) == 0 || len(req.Proposal) > MaxCiphertext {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "proposal rỗng hoặc quá lớn")
	}
	if _, e := s.member(ctx, dev, conv); e != nil {
		return nil, e
	}
	if idem == "" {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "thiếu Idempotency-Key")
	}
	recips, e := s.recipients(ctx, conv, dev.DeviceID)
	if e != nil {
		return nil, e
	}
	// Khử trùng nhờ khóa dedup theo (conv, Idempotency-Key) như client_msg_id.
	cmid := ids.ID{}
	copy(cmid[:], idemHash(idem))
	res, err := s.Mailbox.AppendMessage(ctx, store.AppendMsgReq{
		ConvID: conv, ClientMsgID: cmid, Epoch: req.MlsEpoch, Kind: chatv1.EntryKind_ENTRY_KIND_PROPOSAL,
		Sender: dev.DeviceID, Ciphertext: req.Proposal, TsMs: s.nowMs(), Recipients: recips,
	})
	if err != nil {
		return nil, toErr(err)
	}
	if !res.Duplicate {
		s.enqueue(ctx, conv, res.Seq)
	}
	return &chatv1.SubmitProposalResponse{Seq: res.Seq}, nil
}

// FetchLog trả phần log sau after_seq cho thành viên.
func (s *Service) FetchLog(ctx context.Context, dev store.DeviceInfo, req *chatv1.FetchLogRequest) (*chatv1.FetchLogResponse, *Error) {
	conv, e := parseID(req.ConvId, "conv_id")
	if e != nil {
		return nil, e
	}
	if _, e := s.member(ctx, dev, conv); e != nil {
		return nil, e
	}
	limit := int(req.Limit)
	if limit <= 0 {
		limit = DefaultFetch
	}
	if limit > MaxFetchLimit {
		limit = MaxFetchLimit
	}
	h, err := s.Mailbox.GetHead(ctx, conv)
	if err != nil {
		return nil, toErr(err)
	}
	entries, err := s.Mailbox.GetLog(ctx, conv, req.AfterSeq, limit)
	if err != nil {
		return nil, toErr(err)
	}
	resp := &chatv1.FetchLogResponse{HeadSeq: h.HeadSeq, Epoch: h.Epoch}
	for _, en := range entries {
		resp.Entries = append(resp.Entries, &chatv1.LogEntry{Seq: en.Seq, Kind: en.Kind,
			SenderDeviceId: en.Sender.Bytes(), MlsEpoch: en.Epoch, Ciphertext: en.Ciphertext, ServerTsMs: en.TsMs})
	}
	if n := len(entries); n > 0 {
		resp.More = entries[n-1].Seq < h.HeadSeq
	}
	return resp, nil
}

// GetGroupInfo trả GroupInfo mới nhất cho thành viên (External Commit).
func (s *Service) GetGroupInfo(ctx context.Context, dev store.DeviceInfo, req *chatv1.GetGroupInfoRequest) (*chatv1.GetGroupInfoResponse, *Error) {
	conv, e := parseID(req.ConvId, "conv_id")
	if e != nil {
		return nil, e
	}
	if _, e := s.member(ctx, dev, conv); e != nil {
		return nil, e
	}
	ep, gi, err := s.Meta.GetGroupInfo(ctx, conv)
	if err != nil {
		return nil, toErr(err)
	}
	return &chatv1.GetGroupInfoResponse{GroupInfo: gi, Epoch: ep}, nil
}

// ListConversations liệt kê hội thoại của tài khoản (phân trang để sau).
func (s *Service) ListConversations(ctx context.Context, dev store.DeviceInfo) (*chatv1.ListConversationsResponse, *Error) {
	list, err := s.Meta.ListConversations(ctx, dev.AccountID)
	if err != nil {
		return nil, toErr(err)
	}
	resp := &chatv1.ListConversationsResponse{}
	for _, c := range list {
		h, err := s.Mailbox.GetHead(ctx, c)
		if err != nil {
			continue // metadata có, mailbox chưa (đang tạo dở)
		}
		k, _ := s.Meta.ConversationKind(ctx, c)
		row, _ := s.Meta.GetMember(ctx, c, dev.AccountID)
		resp.Conversations = append(resp.Conversations, &chatv1.ConversationSummary{
			ConvId: c.Bytes(), Kind: k, HeadSeq: h.HeadSeq, Epoch: h.Epoch, Role: row.Role})
	}
	return resp, nil
}
