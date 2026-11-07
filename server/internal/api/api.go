// Package api: ConversationService qua Connect RPC (giao-thuc.md mục 4.2). Mỏng: xác thực token,
// đọc Idempotency-Key, gọi message.Service và đổi lỗi sang mã Connect kèm chi tiết chat.v1.Error.
package api

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"connectrpc.com/connect"
	chatv1 "github.com/Do-Ngoc-Quang/byo-chat/server/gen/chat/v1"
	"github.com/Do-Ngoc-Quang/byo-chat/server/gen/chat/v1/chatv1connect"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/auth"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/message"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store"
)

type Conversation struct {
	chatv1connect.UnimplementedConversationServiceHandler
	Svc      *message.Service
	Verifier auth.Verifier
}

// Handler trả đường dẫn và http.Handler để gắn vào mux.
func (c *Conversation) Handler() (string, http.Handler) {
	return chatv1connect.NewConversationServiceHandler(c)
}

// Ánh xạ bảng ở giao-thuc.md mục 5.
var codeMap = map[chatv1.ErrorCode]connect.Code{
	chatv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED:     connect.CodeUnauthenticated,
	chatv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED:   connect.CodePermissionDenied,
	chatv1.ErrorCode_ERROR_CODE_NOT_FOUND:           connect.CodeNotFound,
	chatv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT:    connect.CodeInvalidArgument,
	chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED:        connect.CodeResourceExhausted,
	chatv1.ErrorCode_ERROR_CODE_EPOCH_MISMATCH:      connect.CodeFailedPrecondition,
	chatv1.ErrorCode_ERROR_CODE_ALREADY_EXISTS:      connect.CodeAlreadyExists,
	chatv1.ErrorCode_ERROR_CODE_DEVICE_REVOKED:      connect.CodePermissionDenied,
	chatv1.ErrorCode_ERROR_CODE_VERSION_UNSUPPORTED: connect.CodeFailedPrecondition,
	chatv1.ErrorCode_ERROR_CODE_PAYLOAD_TOO_LARGE:   connect.CodeInvalidArgument,
	chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE:         connect.CodeUnavailable,
}

func toConnect(e *message.Error) error {
	code, ok := codeMap[e.Code]
	if !ok {
		code = connect.CodeInternal
	}
	ce := connect.NewError(code, errors.New(e.Msg))
	if d, err := connect.NewErrorDetail(e.Proto()); err == nil {
		ce.AddDetail(d)
	}
	return ce
}

// device xác thực Bearer token và trả thiết bị đang hoạt động.
func (c *Conversation) device(ctx context.Context, h http.Header) (store.DeviceInfo, *message.Error) {
	tok, ok := strings.CutPrefix(h.Get("Authorization"), "Bearer ")
	if !ok {
		return store.DeviceInfo{}, &message.Error{Code: chatv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, Msg: "thiếu token"}
	}
	cl, err := c.Verifier.Verify(tok, c.Svc.Now())
	if err != nil {
		return store.DeviceInfo{}, &message.Error{Code: chatv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, Msg: "token không hợp lệ hoặc hết hạn"}
	}
	dev, err := c.Svc.Meta.GetDevice(ctx, cl.Device)
	if err != nil || dev.AccountID != cl.Account {
		return store.DeviceInfo{}, &message.Error{Code: chatv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, Msg: "thiết bị không tồn tại"}
	}
	if dev.Revoked {
		return dev, &message.Error{Code: chatv1.ErrorCode_ERROR_CODE_DEVICE_REVOKED, Msg: "thiết bị đã bị thu hồi"}
	}
	return dev, nil
}

func (c *Conversation) CreateConversation(ctx context.Context, r *connect.Request[chatv1.CreateConversationRequest]) (*connect.Response[chatv1.CreateConversationResponse], error) {
	dev, e := c.device(ctx, r.Header())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := c.Svc.CreateConversation(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (c *Conversation) SubmitCommit(ctx context.Context, r *connect.Request[chatv1.SubmitCommitRequest]) (*connect.Response[chatv1.SubmitCommitResponse], error) {
	dev, e := c.device(ctx, r.Header())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := c.Svc.SubmitCommit(ctx, dev, r.Header().Get("Idempotency-Key"), r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (c *Conversation) SubmitProposal(ctx context.Context, r *connect.Request[chatv1.SubmitProposalRequest]) (*connect.Response[chatv1.SubmitProposalResponse], error) {
	dev, e := c.device(ctx, r.Header())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := c.Svc.SubmitProposal(ctx, dev, r.Header().Get("Idempotency-Key"), r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (c *Conversation) FetchLog(ctx context.Context, r *connect.Request[chatv1.FetchLogRequest]) (*connect.Response[chatv1.FetchLogResponse], error) {
	dev, e := c.device(ctx, r.Header())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := c.Svc.FetchLog(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (c *Conversation) GetGroupInfo(ctx context.Context, r *connect.Request[chatv1.GetGroupInfoRequest]) (*connect.Response[chatv1.GetGroupInfoResponse], error) {
	dev, e := c.device(ctx, r.Header())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := c.Svc.GetGroupInfo(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (c *Conversation) ListConversations(ctx context.Context, r *connect.Request[chatv1.ListConversationsRequest]) (*connect.Response[chatv1.ListConversationsResponse], error) {
	dev, e := c.device(ctx, r.Header())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := c.Svc.ListConversations(ctx, dev)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}
