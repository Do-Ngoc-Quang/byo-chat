package message

import (
	"context"
	"crypto/sha256"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/mlswire"
	"byo-chat/server/internal/store"
)

func idemHash(k string) []byte { h := sha256.Sum256([]byte(k)); return h[:16] }

func isAdmin(r chatv1.Role) bool { return r == chatv1.Role_ROLE_ADMIN || r == chatv1.Role_ROLE_OWNER }

func toIDs(bs [][]byte, name string) ([]ids.ID, *Error) {
	out := make([]ids.ID, 0, len(bs))
	for _, b := range bs {
		id, e := parseID(b, name)
		if e != nil {
			return nil, e
		}
		out = append(out, id)
	}
	return out, nil
}

// welcomes kiểm tra Welcome chỉ đi tới thiết bị còn hiệu lực của tài khoản trong `accounts`.
func (s *Service) welcomes(ctx context.Context, in []*chatv1.WelcomeEnvelope, accounts []ids.ID, sender ids.ID) ([]store.Welcome, *Error) {
	if len(in) > MaxWelcomes {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "tối đa %d thiết bị mỗi Commit", MaxWelcomes)
	}
	if len(in) == 0 {
		return nil, nil
	}
	devs, err := s.Meta.DevicesOfAccounts(ctx, accounts)
	if err != nil {
		return nil, toErr(err)
	}
	ok := map[ids.ID]bool{}
	for _, d := range devs {
		ok[d.DeviceID] = true
	}
	out := make([]store.Welcome, 0, len(in))
	seen := map[ids.ID]bool{}
	total := 0
	for _, w := range in {
		d, e := parseID(w.RecipientDeviceId, "recipient_device_id")
		if e != nil {
			return nil, e
		}
		if d == sender || !ok[d] || seen[d] {
			return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "Welcome tới thiết bị không hợp lệ")
		}
		if len(w.Welcome) == 0 || len(w.Welcome) > MaxCommit {
			return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "Welcome rỗng hoặc quá lớn")
		}
		// Giao dịch DynamoDB giới hạn 4 MB; Welcome nằm trong cùng giao dịch với Commit.
		if total += len(w.Welcome); total > MaxWelcomeBytes {
			return nil, errf(chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE, "tổng Welcome vượt %d byte; chia thành nhiều Commit", MaxWelcomeBytes)
		}
		seen[d] = true
		out = append(out, store.Welcome{Device: d, Ciphertext: w.Welcome})
	}
	return out, nil
}

func memberAccounts(ms []*chatv1.Member) ([]ids.ID, *Error) {
	out := make([]ids.ID, 0, len(ms))
	for _, m := range ms {
		a, e := parseID(m.AccountId, "account_id")
		if e != nil {
			return nil, e
		}
		if m.Role == chatv1.Role_ROLE_UNSPECIFIED {
			return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "thiếu vai trò")
		}
		out = append(out, a)
	}
	return out, nil
}

// CreateConversation: giao-thuc.md mục 6.2. idem là Idempotency-Key của RPC.
func (s *Service) CreateConversation(ctx context.Context, dev store.DeviceInfo, req *chatv1.CreateConversationRequest) (*chatv1.CreateConversationResponse, *Error) {
	if req.Kind != chatv1.ConvKind_CONV_KIND_DIRECT && req.Kind != chatv1.ConvKind_CONV_KIND_GROUP {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "kind không hợp lệ")
	}
	if len(req.GroupId) != 32 {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "group_id phải 32 byte")
	}
	if len(req.Commit) == 0 || len(req.Commit) > MaxCommit || len(req.GroupInfo) == 0 || len(req.GroupInfo) > MaxGroupInfo {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "commit hoặc group_info rỗng/quá lớn")
	}
	accts, e := memberAccounts(req.Members)
	if e != nil {
		return nil, e
	}
	if len(accts) == 0 || len(accts) > maxMembersCall {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "số thành viên không hợp lệ")
	}
	seenAcct := map[ids.ID]bool{}
	self := false
	owners := 0
	for i, a := range accts {
		if seenAcct[a] {
			return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "thành viên trùng")
		}
		seenAcct[a] = true
		self = self || a == dev.AccountID
		if req.Members[i].Role == chatv1.Role_ROLE_OWNER {
			owners++
		}
	}
	if !self {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "người tạo phải nằm trong members")
	}
	if req.Kind == chatv1.ConvKind_CONV_KIND_DIRECT {
		if len(accts) != 2 || owners != 0 {
			return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "1-1 cần đúng hai thành viên vai trò MEMBER")
		}
	} else if owners != 1 || !isOwnerOf(req.Members, dev.AccountID) {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "nhóm cần đúng một OWNER là người tạo")
	}
	ws, e := s.welcomes(ctx, req.Welcomes, accts, dev.DeviceID)
	if e != nil {
		return nil, e
	}
	candidate := ids.New()
	conv, existed, err := s.Meta.CreateConversation(ctx, candidate, req.Kind, req.GroupId, req.Members)
	if err != nil {
		return nil, toErr(err)
	}
	if existed {
		return &chatv1.CreateConversationResponse{ConvId: conv.Bytes(), Existed: true}, nil
	}
	// Commit đầu không giao cho ai bằng con trỏ: người nhận có Welcome, người tạo đã có trạng thái.
	res, err := s.Mailbox.CreateConv(ctx, conv, store.CommitReq{
		ConvID: conv, Sender: dev.DeviceID, Ciphertext: req.Commit, TsMs: s.nowMs(), Welcomes: ws,
		Fanout: store.Fanout{GroupInfo: req.GroupInfo, WelcomeTo: welcomeDevs(ws)},
	})
	if err == store.ErrExists { // gửi lại sau khi đã ghi: cùng group_id cho cùng conv_id
		res, err = store.CommitResult{Seq: 1, NewEpoch: 1}, nil
	}
	if err != nil {
		return nil, toErr(err)
	}
	s.enqueue(ctx, conv, res.Seq)
	return &chatv1.CreateConversationResponse{ConvId: conv.Bytes(), Seq: res.Seq, Epoch: res.NewEpoch}, nil
}

func isOwnerOf(ms []*chatv1.Member, a ids.ID) bool {
	for _, m := range ms {
		if string(m.AccountId) == string(a[:]) {
			return m.Role == chatv1.Role_ROLE_OWNER
		}
	}
	return false
}

// SubmitCommit: giao-thuc.md mục 6.3-6.5. idem là Idempotency-Key.
func (s *Service) SubmitCommit(ctx context.Context, dev store.DeviceInfo, idem string, req *chatv1.SubmitCommitRequest) (*chatv1.SubmitCommitResponse, *Error) {
	conv, e := parseID(req.ConvId, "conv_id")
	if e != nil {
		return nil, e
	}
	if idem == "" {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "thiếu Idempotency-Key")
	}
	if len(req.Commit) == 0 || len(req.Commit) > MaxCommit || len(req.GroupInfo) == 0 || len(req.GroupInfo) > MaxGroupInfo {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "commit hoặc group_info rỗng/quá lớn")
	}
	row, e := s.member(ctx, dev, conv)
	if e != nil {
		return nil, e
	}
	kind, err := s.Meta.ConversationKind(ctx, conv)
	if err != nil {
		return nil, toErr(err)
	}
	// Làm nốt việc dở của mục cuối (thành viên/vai trò) trước khi dựa vào chúng để phân quyền.
	s.settleHead(ctx, conv)
	if row, err = s.Meta.GetMember(ctx, conv, dev.AccountID); err != nil {
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "không phải thành viên")
	}

	fo := store.Fanout{GroupInfo: req.GroupInfo, RoleChanges: req.RoleChanges}
	var addedAccts []ids.ID
	if req.External {
		// External Commit: thiết bị của tài khoản đã là thành viên tự vào (6.5), không đổi thành viên/vai trò.
		if len(req.Added)+len(req.RemovedAccountIds)+len(req.RemovedDeviceIds)+len(req.RoleChanges)+len(req.Welcomes) > 0 {
			return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "External Commit không đổi thành viên/vai trò")
		}
		fo.RoleChanges = nil
		if s.CheckExternal != nil {
			leaf, err := mlswire.ParseExternalCommit(req.Commit)
			if err != nil {
				return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "%v", err)
			}
			if err := s.CheckExternal(ctx, dev, leaf); err != nil {
				return nil, errf(chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "%v", err)
			}
		}
	} else {
		// Thêm/gỡ thành viên và đổi vai trò cần ADMIN/OWNER. Commit chỉ có path update (xoay khóa, 6.8)
		// và gỡ thiết bị của chính tài khoản mình (thu hồi, 6.6) thì thành viên nào cũng gửi được.
		needAdmin := len(req.Added)+len(req.RemovedAccountIds)+len(req.RoleChanges) > 0
		if !needAdmin {
			rd, e := toIDs(req.RemovedDeviceIds, "removed_device_ids")
			if e != nil {
				return nil, e
			}
			for _, d := range rd {
				di, err := s.Meta.GetDevice(ctx, d)
				if err != nil || di.AccountID != dev.AccountID {
					needAdmin = true
					break
				}
			}
		}
		if needAdmin && !isAdmin(row.Role) && !s.onlyLeavers(ctx, conv, req) {
			return nil, errf(chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "cần vai trò ADMIN hoặc OWNER")
		}
		if kind == chatv1.ConvKind_CONV_KIND_DIRECT && (len(req.Added)+len(req.RemovedAccountIds)+len(req.RoleChanges) > 0) {
			return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "hội thoại 1-1 không đổi thành viên")
		}
		var e *Error
		if addedAccts, e = memberAccounts(req.Added); e != nil {
			return nil, e
		}
		for _, a := range addedAccts {
			if _, err := s.Meta.GetMember(ctx, conv, a); err == nil {
				return nil, errf(chatv1.ErrorCode_ERROR_CODE_ALREADY_EXISTS, "đã là thành viên")
			}
		}
		removed, e := toIDs(req.RemovedAccountIds, "removed_account_ids")
		if e != nil {
			return nil, e
		}
		for _, a := range removed {
			r, err := s.Meta.GetMember(ctx, conv, a)
			if err != nil {
				return nil, errf(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "gỡ người không phải thành viên")
			}
			if r.Role == chatv1.Role_ROLE_OWNER {
				return nil, errf(chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "không gỡ OWNER (chuyển quyền trước)")
			}
		}
		if _, e := memberAccounts(req.RoleChanges); e != nil {
			return nil, e
		}
		for _, rc := range append(append([]*chatv1.Member{}, req.RoleChanges...), req.Added...) {
			if rc.Role == chatv1.Role_ROLE_OWNER && row.Role != chatv1.Role_ROLE_OWNER {
				return nil, errf(chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "chỉ OWNER trao vai trò OWNER")
			}
		}
		fo.Added, fo.RemovedAcct = req.Added, removed
	}
	ws, e := s.welcomes(ctx, req.Welcomes, addedAccts, dev.DeviceID)
	if e != nil {
		return nil, e
	}
	// Người nhận Commit: thiết bị của thành viên TRƯỚC thay đổi (gồm người bị gỡ: tin cuối).
	recips, e := s.recipients(ctx, conv, dev.DeviceID)
	if e != nil {
		return nil, e
	}
	if len(recips)+1+len(ws) > MaxGroupDevs { // +1: thiết bị gửi (recips không gồm nó)
		return nil, errf(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "vượt %d thiết bị mỗi nhóm", MaxGroupDevs)
	}
	fo.Recipients = recips
	for _, w := range ws {
		fo.WelcomeTo = append(fo.WelcomeTo, w.Device)
	}

	res, err := s.Mailbox.AppendCommit(ctx, store.CommitReq{
		ConvID: conv, ExpectedEpoch: req.ExpectedEpoch, Sender: dev.DeviceID, Ciphertext: req.Commit,
		TsMs: s.nowMs(), Welcomes: ws, Fanout: fo, IdemKey: idem,
	})
	if err != nil {
		return nil, toErr(err)
	}
	if !res.Duplicate {
		s.enqueue(ctx, conv, res.Seq)
	}
	return &chatv1.SubmitCommitResponse{Seq: res.Seq, NewEpoch: res.NewEpoch}, nil
}

// onlyLeavers: Commit dự phòng của thành viên thường (6.4, ADR 0015) chỉ gỡ tài khoản đang xin rời, không đổi gì khác.
func (s *Service) onlyLeavers(ctx context.Context, conv ids.ID, req *chatv1.SubmitCommitRequest) bool {
	if len(req.RemovedAccountIds) == 0 || len(req.Added)+len(req.RoleChanges)+len(req.RemovedDeviceIds) > 0 {
		return false
	}
	for _, b := range req.RemovedAccountIds {
		a, e := parseID(b, "removed_account_ids")
		if e != nil {
			return false
		}
		if r, err := s.Meta.GetMember(ctx, conv, a); err != nil || !r.Leaving {
			return false
		}
	}
	return true
}

func welcomeDevs(ws []store.Welcome) []ids.ID {
	out := make([]ids.ID, 0, len(ws))
	for _, w := range ws {
		out = append(out, w.Device)
	}
	return out
}
