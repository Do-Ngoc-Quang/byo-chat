package api

import (
	"context"
	"net/http"
	"time"

	"connectrpc.com/connect"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/gen/chat/v1/chatv1connect"
	"byo-chat/server/internal/account"
	"byo-chat/server/internal/auth"
	"byo-chat/server/internal/call"
	"byo-chat/server/internal/message"
	"byo-chat/server/internal/store"
)

// Liên kết thiết bị (giao-thuc.md 6.5): StartLink/CompleteLink chưa đăng nhập, ApproveLink cần access token.

// StartLinkPerMinute: số lần StartLink tối đa mỗi phút mỗi IP (chống tạo liên kết hàng loạt).
const StartLinkPerMinute = 10

func (d *Device) StartLink(ctx context.Context, r *connect.Request[chatv1.StartLinkRequest]) (*connect.Response[chatv1.StartLinkResponse], error) {
	if ok, wait := d.startLimit.allow(r.Peer().Addr, StartLinkPerMinute, time.Minute, d.Svc.Now()); !ok {
		return nil, toConnect(&message.Error{Code: chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED, Msg: "quá nhiều yêu cầu liên kết", RetryAfterMs: uint32(wait.Milliseconds())})
	}
	resp, e := d.Svc.StartLink(ctx, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (d *Device) ApproveLink(ctx context.Context, r *connect.Request[chatv1.ApproveLinkRequest]) (*connect.Response[chatv1.ApproveLinkResponse], error) {
	dev, e := authDevice(ctx, r.Header(), d.Verifier, d.Svc.Meta, d.Svc.Now())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := d.Svc.ApproveLink(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

// Danh sách và thu hồi thiết bị (giao-thuc.md 6.6): cần access token.

func (d *Device) ListDevices(ctx context.Context, r *connect.Request[chatv1.ListDevicesRequest]) (*connect.Response[chatv1.ListDevicesResponse], error) {
	dev, e := authDevice(ctx, r.Header(), d.Verifier, d.Svc.Meta, d.Svc.Now())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := d.Svc.ListDevices(ctx, dev)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (d *Device) RevokeDevice(ctx context.Context, r *connect.Request[chatv1.RevokeDeviceRequest]) (*connect.Response[chatv1.RevokeDeviceResponse], error) {
	dev, e := authDevice(ctx, r.Header(), d.Verifier, d.Svc.Meta, d.Svc.Now())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := d.Svc.RevokeDevice(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (d *Device) CompleteLink(ctx context.Context, r *connect.Request[chatv1.CompleteLinkRequest]) (*connect.Response[chatv1.CompleteLinkResponse], error) {
	resp, e := d.Svc.CompleteLink(ctx, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

// Backup: BackupService. CreateBackupUpload cần access token; GetLatestBackup dùng session_ticket (6.14).
type Backup struct {
	chatv1connect.UnimplementedBackupServiceHandler
	Svc      *account.Service
	Verifier auth.Verifier
}

func (b *Backup) Handler() (string, http.Handler) { return chatv1connect.NewBackupServiceHandler(b) }

func (b *Backup) CreateBackupUpload(ctx context.Context, r *connect.Request[chatv1.CreateBackupUploadRequest]) (*connect.Response[chatv1.CreateBackupUploadResponse], error) {
	dev, e := authDevice(ctx, r.Header(), b.Verifier, b.Svc.Meta, b.Svc.Now())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := b.Svc.CreateBackupUpload(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (b *Backup) GetLatestBackup(ctx context.Context, r *connect.Request[chatv1.GetLatestBackupRequest]) (*connect.Response[chatv1.GetLatestBackupResponse], error) {
	resp, e := b.Svc.GetLatestBackup(ctx, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

// Call: CallService (giao-thuc.md 6.9). Mọi RPC cần access token của thiết bị còn hiệu lực.
type Call struct {
	chatv1connect.UnimplementedCallServiceHandler
	Svc      *call.Service
	Meta     store.MetaStore
	Verifier auth.Verifier
}

func (c *Call) Handler() (string, http.Handler) { return chatv1connect.NewCallServiceHandler(c) }

func (c *Call) StartCall(ctx context.Context, r *connect.Request[chatv1.StartCallRequest]) (*connect.Response[chatv1.CallTicket], error) {
	dev, e := authDevice(ctx, r.Header(), c.Verifier, c.Meta, c.Svc.Now())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := c.Svc.StartCall(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (c *Call) JoinCall(ctx context.Context, r *connect.Request[chatv1.JoinCallRequest]) (*connect.Response[chatv1.CallTicket], error) {
	dev, e := authDevice(ctx, r.Header(), c.Verifier, c.Meta, c.Svc.Now())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := c.Svc.JoinCall(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (c *Call) EndCall(ctx context.Context, r *connect.Request[chatv1.EndCallRequest]) (*connect.Response[chatv1.EndCallResponse], error) {
	dev, e := authDevice(ctx, r.Header(), c.Verifier, c.Meta, c.Svc.Now())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := c.Svc.EndCall(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

// Media: MediaService. Mọi RPC cần access token của thiết bị còn hiệu lực.
type Media struct {
	chatv1connect.UnimplementedMediaServiceHandler
	Svc      *account.Service
	Verifier auth.Verifier
}

func (m *Media) Handler() (string, http.Handler) { return chatv1connect.NewMediaServiceHandler(m) }

func (m *Media) CreateUpload(ctx context.Context, r *connect.Request[chatv1.CreateUploadRequest]) (*connect.Response[chatv1.CreateUploadResponse], error) {
	dev, e := authDevice(ctx, r.Header(), m.Verifier, m.Svc.Meta, m.Svc.Now())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := m.Svc.CreateUpload(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (m *Media) CompleteUpload(ctx context.Context, r *connect.Request[chatv1.CompleteUploadRequest]) (*connect.Response[chatv1.CompleteUploadResponse], error) {
	dev, e := authDevice(ctx, r.Header(), m.Verifier, m.Svc.Meta, m.Svc.Now())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := m.Svc.CompleteUpload(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (m *Media) GetDownloadUrl(ctx context.Context, r *connect.Request[chatv1.GetDownloadUrlRequest]) (*connect.Response[chatv1.GetDownloadUrlResponse], error) {
	dev, e := authDevice(ctx, r.Header(), m.Verifier, m.Svc.Meta, m.Svc.Now())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := m.Svc.GetDownloadUrl(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}
