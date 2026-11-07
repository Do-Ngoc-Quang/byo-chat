package api

import (
	"context"
	"net/http"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/gen/chat/v1/chatv1connect"
	"byo-chat/server/internal/account"
	"byo-chat/server/internal/auth"
	"byo-chat/server/internal/store"
	"connectrpc.com/connect"
)

// Auth: AuthService. Chỉ OTP và RefreshToken; passkey còn Unimplemented (ADR 0007).
type Auth struct {
	chatv1connect.UnimplementedAuthServiceHandler
	Svc *account.Service
}

func (a *Auth) Handler() (string, http.Handler) { return chatv1connect.NewAuthServiceHandler(a) }

func (a *Auth) RequestOtp(ctx context.Context, r *connect.Request[chatv1.RequestOtpRequest]) (*connect.Response[chatv1.RequestOtpResponse], error) {
	resp, e := a.Svc.RequestOtp(ctx, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (a *Auth) VerifyOtp(ctx context.Context, r *connect.Request[chatv1.VerifyOtpRequest]) (*connect.Response[chatv1.VerifyOtpResponse], error) {
	resp, e := a.Svc.VerifyOtp(ctx, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (a *Auth) RefreshToken(ctx context.Context, r *connect.Request[chatv1.RefreshTokenRequest]) (*connect.Response[chatv1.TokenPair], error) {
	resp, e := a.Svc.RefreshToken(ctx, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

// Device: DeviceService. Chỉ RegisterDevice (chưa đăng nhập, dùng session_ticket); liên kết, liệt kê,
// thu hồi làm ở giai đoạn 4.
type Device struct {
	chatv1connect.UnimplementedDeviceServiceHandler
	Svc      *account.Service
	Verifier auth.Verifier // cho ApproveLink (cần access token)

	startLimit ipLimiter
}

func (d *Device) Handler() (string, http.Handler) { return chatv1connect.NewDeviceServiceHandler(d) }

func (d *Device) RegisterDevice(ctx context.Context, r *connect.Request[chatv1.RegisterDeviceRequest]) (*connect.Response[chatv1.RegisterDeviceResponse], error) {
	resp, e := d.Svc.RegisterDevice(ctx, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

// Key: KeyService, cần access token.
type Key struct {
	chatv1connect.UnimplementedKeyServiceHandler
	Svc      *account.Service
	Verifier auth.Verifier
}

func (k *Key) Handler() (string, http.Handler) { return chatv1connect.NewKeyServiceHandler(k) }

func (k *Key) device(ctx context.Context, h http.Header) (store.DeviceInfo, error) {
	dev, e := authDevice(ctx, h, k.Verifier, k.Svc.Meta, k.Svc.Now())
	if e != nil {
		return dev, toConnect(e)
	}
	return dev, nil
}

func (k *Key) UploadKeyPackages(ctx context.Context, r *connect.Request[chatv1.UploadKeyPackagesRequest]) (*connect.Response[chatv1.KeyPackageCount], error) {
	dev, err := k.device(ctx, r.Header())
	if err != nil {
		return nil, err
	}
	resp, e := k.Svc.UploadKeyPackages(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (k *Key) CountKeyPackages(ctx context.Context, r *connect.Request[chatv1.CountKeyPackagesRequest]) (*connect.Response[chatv1.KeyPackageCount], error) {
	dev, err := k.device(ctx, r.Header())
	if err != nil {
		return nil, err
	}
	resp, e := k.Svc.CountKeyPackages(ctx, dev)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

func (k *Key) FetchKeyPackages(ctx context.Context, r *connect.Request[chatv1.FetchKeyPackagesRequest]) (*connect.Response[chatv1.FetchKeyPackagesResponse], error) {
	if _, err := k.device(ctx, r.Header()); err != nil {
		return nil, err
	}
	resp, e := k.Svc.FetchKeyPackages(ctx, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}

// Profile: ProfileService. Mới có LookupAccount (cần access token); hồ sơ và cập nhật làm sau.
type Profile struct {
	chatv1connect.UnimplementedProfileServiceHandler
	Svc      *account.Service
	Verifier auth.Verifier
}

func (p *Profile) Handler() (string, http.Handler) { return chatv1connect.NewProfileServiceHandler(p) }

func (p *Profile) LookupAccount(ctx context.Context, r *connect.Request[chatv1.LookupAccountRequest]) (*connect.Response[chatv1.LookupAccountResponse], error) {
	dev, e := authDevice(ctx, r.Header(), p.Verifier, p.Svc.Meta, p.Svc.Now())
	if e != nil {
		return nil, toConnect(e)
	}
	resp, e := p.Svc.LookupAccount(ctx, dev, r.Msg)
	if e != nil {
		return nil, toConnect(e)
	}
	return connect.NewResponse(resp), nil
}
