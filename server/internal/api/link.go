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
	"byo-chat/server/internal/message"
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
