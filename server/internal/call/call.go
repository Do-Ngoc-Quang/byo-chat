// Package call: CallService (giao-thuc.md 6.9, 6.10). Server chỉ cấp phòng và token LiveKit rồi báo cuộc gọi đến;
// khóa SFrame do client dẫn xuất từ MLS nên server không bao giờ thấy.
package call

import (
	"context"
	"sync"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/store"
	"google.golang.org/protobuf/proto"
)

// Subject của khung IncomingCall tới một thiết bị (khác `dev.<id>` vì không đi qua hộp thư, không cần Ack).
func Subject(deviceHex string) string { return "call." + deviceHex }

type state struct {
	conv    ids.ID
	kind    chatv1.CallKind
	caller  ids.ID // account
	started time.Time
}

// Service giữ các cuộc gọi đang diễn ra trong bộ nhớ một node. Nhiều node cần kho chung (Valkey): việc hoãn.
type Service struct {
	Meta store.MetaStore
	Bus  message.Bus
	Now  func() time.Time
	Cfg  Config

	mu    sync.Mutex
	calls map[ids.ID]*state
}

func New(meta store.MetaStore, bus message.Bus, cfg Config) *Service {
	return &Service{Meta: meta, Bus: bus, Now: time.Now, Cfg: cfg, calls: map[ids.ID]*state{}}
}

func perr(c chatv1.ErrorCode, msg string) *message.Error { return &message.Error{Code: c, Msg: msg} }

func (s *Service) maxCall() time.Duration {
	if s.Cfg.MaxCall > 0 {
		return s.Cfg.MaxCall
	}
	return 4 * time.Hour
}

func (s *Service) ttl() time.Duration {
	if s.Cfg.TokenTTL > 0 {
		return s.Cfg.TokenTTL
	}
	return 15 * time.Minute
}

// active trả cuộc gọi chưa kết thúc và chưa quá hạn; cuộc gọi quá hạn bị dọn.
func (s *Service) active(id ids.ID) *state {
	st := s.calls[id]
	if st != nil && s.Now().Sub(st.started) > s.maxCall() {
		delete(s.calls, id)
		return nil
	}
	return st
}

func (s *Service) member(ctx context.Context, dev store.DeviceInfo, conv ids.ID) *message.Error {
	if _, err := s.Meta.GetMember(ctx, conv, dev.AccountID); err != nil {
		return perr(chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "không phải thành viên")
	}
	return nil
}

func (s *Service) ticket(ctx context.Context, dev store.DeviceInfo, id ids.ID, conv ids.ID) (*chatv1.CallTicket, *message.Error) {
	epoch, _, err := s.Meta.GetGroupInfo(ctx, conv)
	if err != nil {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "chưa có epoch của hội thoại")
	}
	return &chatv1.CallTicket{
		CallId: id.Bytes(), LivekitUrl: s.Cfg.URL, MlsEpoch: epoch,
		Token: accessToken(s.Cfg, id.String(), dev.DeviceID.String(), s.Now(), s.ttl()),
	}, nil
}

// StartCall: thành viên bắt đầu cuộc gọi; mỗi hội thoại một cuộc gọi đang diễn ra.
func (s *Service) StartCall(ctx context.Context, dev store.DeviceInfo, r *chatv1.StartCallRequest) (*chatv1.CallTicket, *message.Error) {
	if !s.Cfg.ok() {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "chưa cấu hình LiveKit")
	}
	conv, err := ids.FromBytes(r.ConvId)
	if err != nil {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "conv_id phải 16 byte")
	}
	if r.Kind != chatv1.CallKind_CALL_KIND_AUDIO && r.Kind != chatv1.CallKind_CALL_KIND_VIDEO {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "kind phải là AUDIO hoặc VIDEO")
	}
	if e := s.member(ctx, dev, conv); e != nil {
		return nil, e
	}
	s.mu.Lock()
	for id, st := range s.calls {
		if st.conv == conv && s.active(id) != nil {
			s.mu.Unlock()
			return nil, perr(chatv1.ErrorCode_ERROR_CODE_ALREADY_EXISTS, "hội thoại đang có cuộc gọi")
		}
	}
	id := ids.New()
	st := &state{conv: conv, kind: r.Kind, caller: dev.AccountID, started: s.Now()}
	s.calls[id] = st
	s.mu.Unlock()

	tk, e := s.ticket(ctx, dev, id, conv)
	if e != nil {
		s.mu.Lock()
		delete(s.calls, id)
		s.mu.Unlock()
		return nil, e
	}
	s.ring(ctx, dev, id, st)
	return tk, nil
}

// ring đẩy IncomingCall tới mọi thiết bị của các thành viên khác (giao-thuc.md 6.10). Thiết bị không có kết nối
// WebSocket nhận push (FCM/VoIP): chưa làm, cần dịch vụ push thật.
func (s *Service) ring(ctx context.Context, caller store.DeviceInfo, id ids.ID, st *state) {
	rows, err := s.Meta.Members(ctx, st.conv)
	if err != nil {
		return
	}
	var accts []ids.ID
	for _, m := range rows {
		if m.AccountID != caller.AccountID {
			accts = append(accts, m.AccountID)
		}
	}
	devs, err := s.Meta.DevicesOfAccounts(ctx, accts)
	if err != nil {
		return
	}
	b, _ := proto.Marshal(&chatv1.IncomingCall{CallId: id.Bytes(), ConvId: st.conv.Bytes(), Kind: st.kind,
		CallerAccountId: st.caller.Bytes(), StartedMs: uint64(st.started.UnixMilli())})
	for _, d := range devs {
		_ = s.Bus.Publish(Subject(d.DeviceID.Hex()), b)
	}
}

// JoinCall: thành viên vào cuộc gọi đang diễn ra và nhận token LiveKit; client chỉ vào khi epoch cục bộ khớp `mls_epoch`.
func (s *Service) JoinCall(ctx context.Context, dev store.DeviceInfo, r *chatv1.JoinCallRequest) (*chatv1.CallTicket, *message.Error) {
	id, err := ids.FromBytes(r.CallId)
	if err != nil {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "call_id phải 16 byte")
	}
	s.mu.Lock()
	st := s.active(id)
	s.mu.Unlock()
	if st == nil {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "cuộc gọi không tồn tại hoặc đã kết thúc")
	}
	if e := s.member(ctx, dev, st.conv); e != nil {
		// Không lộ cuộc gọi cho người ngoài hội thoại.
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "cuộc gọi không tồn tại hoặc đã kết thúc")
	}
	return s.ticket(ctx, dev, id, st.conv)
}

// EndCall: thành viên của hội thoại kết thúc cuộc gọi (idempotent: cuộc gọi đã hết thì trả thành công).
// Tin điều khiển CallEvent do client gửi vào hội thoại (6.9 bước 5), server không thấy.
func (s *Service) EndCall(ctx context.Context, dev store.DeviceInfo, r *chatv1.EndCallRequest) (*chatv1.EndCallResponse, *message.Error) {
	id, err := ids.FromBytes(r.CallId)
	if err != nil {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "call_id phải 16 byte")
	}
	s.mu.Lock()
	st := s.active(id)
	s.mu.Unlock()
	if st == nil {
		return &chatv1.EndCallResponse{}, nil
	}
	if e := s.member(ctx, dev, st.conv); e != nil {
		return nil, perr(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "cuộc gọi không tồn tại hoặc đã kết thúc")
	}
	s.mu.Lock()
	delete(s.calls, id)
	s.mu.Unlock()
	return &chatv1.EndCallResponse{}, nil
}
