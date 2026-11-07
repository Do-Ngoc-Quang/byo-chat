// Package gateway: WebSocket gateway (giao-thuc.md mục 3). Gateway chỉ xác thực, chuyển khung
// và giữ kết nối; nghiệp vụ nằm ở message.Service.
package gateway

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"sync"
	"time"

	chatv1 "github.com/Do-Ngoc-Quang/byo-chat/server/gen/chat/v1"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/auth"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/ids"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/message"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store"
	"github.com/coder/websocket"
	"golang.org/x/time/rate"
	"google.golang.org/protobuf/proto"
)

// Mã đóng kết nối (giao-thuc.md mục 3).
const (
	CloseProtocol     websocket.StatusCode = 4000
	CloseUnauth       websocket.StatusCode = 4001
	CloseTokenExpired websocket.StatusCode = 4002
	CloseRevoked      websocket.StatusCode = 4003
	CloseVersion      websocket.StatusCode = 4004
	CloseRate         websocket.StatusCode = 4008
	CloseDrain        websocket.StatusCode = 4009
	CloseReplaced     websocket.StatusCode = 4010
)

const (
	Subprotocol    = "chat.v1"
	ProtoVersion   = 1
	MaxFrameBytes  = 256 << 10
	backlogPage    = 200
	sendQueueDepth = 64
)

// Config chỉnh được cho test; Default dùng giá trị khởi điểm của spec.
type Config struct {
	HelloTimeout time.Duration // 5 giây
	Heartbeat    time.Duration // 25 giây
	Window       int           // 256
	SendRate     rate.Limit    // 10 tin/giây
	SendBurst    int           // 30
}

func DefaultConfig() Config {
	return Config{HelloTimeout: 5 * time.Second, Heartbeat: 25 * time.Second, Window: 256, SendRate: 10, SendBurst: 30}
}

type Server struct {
	Svc      *message.Service
	Verifier auth.Verifier
	Cfg      Config
	Log      *slog.Logger
	Now      func() time.Time

	mu       sync.Mutex
	conns    map[ids.ID]*conn
	draining bool
}

func New(svc *message.Service, v auth.Verifier, cfg Config) *Server {
	return &Server{Svc: svc, Verifier: v, Cfg: cfg, Log: slog.Default(), Now: time.Now, conns: map[ids.ID]*conn{}}
}

// Drain đóng mọi kết nối bằng mã 4009 (client kết nối lại sau 0-30 giây ngẫu nhiên) và từ chối kết nối mới.
func (s *Server) Drain() {
	s.mu.Lock()
	s.draining = true
	cs := make([]*conn, 0, len(s.conns))
	for _, c := range s.conns {
		cs = append(cs, c)
	}
	s.mu.Unlock()
	for _, c := range cs {
		go c.close(CloseDrain, "drain")
	}
}

// ConnCount cho test và số đo.
func (s *Server) ConnCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.conns)
}

type conn struct {
	srv    *Server
	ws     *websocket.Conn
	dev    store.DeviceInfo
	sess   ids.ID
	cancel context.CancelFunc
	wmu    sync.Mutex
	limit  *rate.Limiter
	// window: mỗi Deliver có inbox_id chiếm một chỗ tới khi được Ack.
	window   chan struct{}
	imu      sync.Mutex
	inflight map[ids.ID]struct{}
	closed   sync.Once
}

func (c *conn) close(code websocket.StatusCode, reason string) {
	c.closed.Do(func() {
		_ = c.ws.Close(code, reason)
		c.cancel()
	})
}

func (c *conn) write(ctx context.Context, f *chatv1.ServerFrame) error {
	b, err := proto.Marshal(f)
	if err != nil {
		return err
	}
	c.wmu.Lock()
	defer c.wmu.Unlock()
	wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return c.ws.Write(wctx, websocket.MessageBinary, b)
}

func (c *conn) writeErr(ctx context.Context, req uint64, e *message.Error) {
	_ = c.write(ctx, &chatv1.ServerFrame{ReqId: req, Body: &chatv1.ServerFrame_Error{Error: e.Proto()}})
}

// ServeHTTP xử lý GET /v1/connect.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	dr := s.draining
	s.mu.Unlock()
	if dr {
		http.Error(w, "draining", http.StatusServiceUnavailable)
		return
	}
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{Subprotocol}})
	if err != nil {
		return
	}
	if ws.Subprotocol() != Subprotocol {
		_ = ws.Close(CloseProtocol, "cần subprotocol chat.v1")
		return
	}
	ws.SetReadLimit(MaxFrameBytes)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	c := &conn{srv: s, ws: ws, cancel: cancel, sess: ids.New(), limit: rate.NewLimiter(s.Cfg.SendRate, s.Cfg.SendBurst),
		window: make(chan struct{}, s.Cfg.Window), inflight: map[ids.ID]struct{}{}}
	defer c.close(websocket.StatusNormalClosure, "")
	if !c.handshake(ctx) {
		return
	}
	c.run(ctx)
}

func (c *conn) read(ctx context.Context) (*chatv1.ClientFrame, error) {
	_, b, err := c.ws.Read(ctx)
	if err != nil {
		return nil, err
	}
	var f chatv1.ClientFrame
	if err := proto.Unmarshal(b, &f); err != nil {
		return nil, err
	}
	return &f, nil
}

// handshake: Hello trong 5 giây, xác thực, kiểm tra thiết bị, thay kết nối cũ, Welcome.
func (c *conn) handshake(ctx context.Context) bool {
	s := c.srv
	timer := time.AfterFunc(s.Cfg.HelloTimeout, func() { c.close(CloseUnauth, "quá hạn Hello") })
	f, err := c.read(ctx)
	if !timer.Stop() || err != nil {
		// Timer đã bắn (đã đóng với 4001) hoặc lỗi đọc/giải mã khung.
		c.close(CloseProtocol, "Hello")
		return false
	}
	hello := f.GetHello()
	if hello == nil {
		c.close(CloseUnauth, "khung đầu phải là Hello")
		return false
	}
	if hello.ProtoVersion != ProtoVersion {
		c.close(CloseVersion, "phiên bản giao thức không hỗ trợ")
		return false
	}
	claims, err := s.Verifier.Verify(hello.AccessToken, s.Now())
	switch {
	case errors.Is(err, auth.ErrExpired):
		c.close(CloseTokenExpired, "token hết hạn")
		return false
	case err != nil:
		c.close(CloseUnauth, "token không hợp lệ")
		return false
	}
	devID, derr := ids.FromBytes(hello.DeviceId)
	if derr != nil || devID != claims.Device {
		c.close(CloseUnauth, "device_id không khớp token")
		return false
	}
	dev, err := s.Svc.Meta.GetDevice(ctx, devID)
	if err != nil || dev.AccountID != claims.Account {
		c.close(CloseUnauth, "thiết bị không tồn tại")
		return false
	}
	if dev.Revoked {
		c.close(CloseRevoked, "thiết bị đã bị thu hồi")
		return false
	}
	c.dev = dev
	cursor, _ := ids.FromBytes(hello.InboxCursor) // rỗng = từ đầu (ID zero)

	// Đăng ký trước khi Welcome để không lỡ tin xảy ra trong lúc đồng bộ tồn đọng.
	live := make(chan *chatv1.Deliver, 1024)
	unsub, err := s.Svc.Bus.Subscribe(message.DevSubject(devID.Hex()), func(b []byte) {
		d := &chatv1.Deliver{}
		if proto.Unmarshal(b, d) == nil {
			select {
			case live <- d:
			default: // đầy: bỏ; thiết bị lấy lại từ hộp thư ở lần kết nối sau
				s.Log.Warn("hàng chờ live đầy", "device", devID.String())
			}
		}
	})
	if err != nil {
		c.close(CloseDrain, "bus")
		return false
	}
	if !s.register(c) {
		unsub()
		c.close(CloseDrain, "drain")
		return false
	}
	// Dọn khi kết thúc: xóa khỏi bảng (nếu vẫn là kết nối hiện tại) và hủy đăng ký bus.
	go func() {
		<-ctx.Done()
		unsub()
		s.unregister(c)
	}()

	if err := c.write(ctx, &chatv1.ServerFrame{Body: &chatv1.ServerFrame_Welcome{Welcome: &chatv1.Welcome{
		NegotiatedVersion: ProtoVersion, SessionId: c.sess.Bytes(), HeartbeatMs: uint32(s.Cfg.Heartbeat.Milliseconds()),
		Window: uint32(s.Cfg.Window), MaxFrameBytes: MaxFrameBytes, ServerTimeMs: uint64(s.Now().UnixMilli()),
	}}}); err != nil {
		return false
	}
	go c.sync(ctx, cursor, live)
	return true
}

// register thay kết nối cũ của cùng thiết bị (đóng với mã 4010).
func (s *Server) register(c *conn) bool {
	s.mu.Lock()
	if s.draining {
		s.mu.Unlock()
		return false
	}
	old := s.conns[c.dev.DeviceID]
	s.conns[c.dev.DeviceID] = c
	s.mu.Unlock()
	if old != nil {
		go old.close(CloseReplaced, "bị thay bởi kết nối mới") // Close chờ bắt tay đóng; không để client chậm chặn kết nối mới
	}
	return true
}

func (s *Server) unregister(c *conn) {
	s.mu.Lock()
	if s.conns[c.dev.DeviceID] == c {
		delete(s.conns, c.dev.DeviceID)
	}
	s.mu.Unlock()
}

// sync gửi tồn đọng sau cursor, SyncDone, rồi chuyển sang đẩy tin live.
func (c *conn) sync(ctx context.Context, cursor ids.ID, live <-chan *chatv1.Deliver) {
	s := c.srv
	last := cursor
	for {
		page, err := s.Svc.Backlog(ctx, c.dev.DeviceID, last, backlogPage)
		if err != nil {
			s.Log.Warn("backlog", "err", err)
			c.close(CloseDrain, "backlog")
			return
		}
		if len(page) == 0 {
			break
		}
		for _, d := range page {
			if !c.sendDeliver(ctx, d) {
				return
			}
			last, _ = ids.FromBytes(d.InboxId)
		}
		if len(page) < backlogPage {
			break
		}
	}
	if err := c.write(ctx, &chatv1.ServerFrame{Body: &chatv1.ServerFrame_SyncDone{SyncDone: &chatv1.SyncDone{LastInboxId: last.Bytes()}}}); err != nil {
		return
	}
	for {
		select {
		case <-ctx.Done():
			return
		case d := <-live:
			// Tin live có thể trùng phần tồn đọng vừa gửi: bỏ nếu inbox_id không lớn hơn mốc.
			if len(d.InboxId) == 16 {
				if id, _ := ids.FromBytes(d.InboxId); string(id[:]) <= string(last[:]) {
					continue
				}
				last, _ = ids.FromBytes(d.InboxId)
			}
			if !c.sendDeliver(ctx, d) {
				return
			}
		}
	}
}

// sendDeliver tôn trọng cửa sổ: Deliver có inbox_id chiếm một chỗ tới khi Ack.
func (c *conn) sendDeliver(ctx context.Context, d *chatv1.Deliver) bool {
	if len(d.InboxId) > 0 {
		select {
		case c.window <- struct{}{}:
		case <-ctx.Done():
			return false
		}
		id, _ := ids.FromBytes(d.InboxId)
		c.imu.Lock()
		c.inflight[id] = struct{}{}
		c.imu.Unlock()
	}
	return c.write(ctx, &chatv1.ServerFrame{Body: &chatv1.ServerFrame_Deliver{Deliver: d}}) == nil
}

// run đọc khung tới khi đóng. Mọi khung nhận được đều là tín hiệu sống (hạn đọc 2 chu kỳ heartbeat).
func (c *conn) run(ctx context.Context) {
	s := c.srv
	sends := make(chan *chatv1.ClientFrame, sendQueueDepth)
	go func() { // gửi tin tuần tự theo thứ tự nhận để giữ thứ tự của một thiết bị
		for {
			select {
			case <-ctx.Done():
				return
			case f := <-sends:
				c.handleSend(ctx, f)
			}
		}
	}()
	// Quá hai chu kỳ heartbeat không có khung nào: đóng (mọi khung nhận được đều tính là tín hiệu sống).
	idle := time.AfterFunc(2*s.Cfg.Heartbeat, func() { c.close(websocket.StatusGoingAway, "heartbeat") })
	defer idle.Stop()
	for {
		f, err := c.read(ctx)
		if err != nil {
			if ctx.Err() == nil {
				c.close(CloseProtocol, "đọc khung")
			}
			return
		}
		idle.Reset(2 * s.Cfg.Heartbeat)
		switch b := f.Body.(type) {
		case *chatv1.ClientFrame_Ping:
			_ = c.write(ctx, &chatv1.ServerFrame{ReqId: f.ReqId, Body: &chatv1.ServerFrame_Pong{Pong: &chatv1.Pong{Nonce: b.Ping.Nonce}}})
		case *chatv1.ClientFrame_Ack:
			c.handleAck(ctx, b.Ack)
		case *chatv1.ClientFrame_Send:
			select {
			case sends <- f:
			default:
				e := &message.Error{Code: chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED, Msg: "hàng chờ gửi đầy", RetryAfterMs: 500}
				c.writeErr(ctx, f.ReqId, e)
			}
		case *chatv1.ClientFrame_PresenceSub, *chatv1.ClientFrame_Hello:
			// Presence làm sau; Hello lần hai là lỗi giao thức.
			if _, ok := f.Body.(*chatv1.ClientFrame_Hello); ok {
				c.close(CloseProtocol, "Hello lặp")
				return
			}
		default:
			c.close(CloseProtocol, "khung không nhận dạng được")
			return
		}
	}
}

func (c *conn) handleSend(ctx context.Context, f *chatv1.ClientFrame) {
	if !c.limit.Allow() {
		c.writeErr(ctx, f.ReqId, &message.Error{Code: chatv1.ErrorCode_ERROR_CODE_RATE_LIMITED, Msg: "vượt tốc độ gửi", RetryAfterMs: 100})
		return
	}
	// Thiết bị bị thu hồi giữa chừng: kiểm tra lại mỗi lần ghi (tra Postgres; sau này cache Valkey).
	dev, err := c.srv.Svc.Meta.GetDevice(ctx, c.dev.DeviceID)
	if err == nil && dev.Revoked {
		c.close(CloseRevoked, "thiết bị đã bị thu hồi")
		return
	}
	res, e := c.srv.Svc.SendMessage(ctx, c.dev, f.GetSend())
	if e != nil {
		c.writeErr(ctx, f.ReqId, e)
		return
	}
	_ = c.write(ctx, &chatv1.ServerFrame{ReqId: f.ReqId, Body: &chatv1.ServerFrame_SendResult{SendResult: res}})
}

// handleAck xóa con trỏ đã nhận và trả chỗ trong cửa sổ.
func (c *conn) handleAck(ctx context.Context, a *chatv1.Ack) {
	var in []ids.ID
	for _, b := range a.InboxIds {
		if id, err := ids.FromBytes(b); err == nil {
			in = append(in, id)
		}
	}
	if len(in) == 0 {
		return
	}
	if err := c.srv.Svc.Mailbox.DeleteInbox(ctx, c.dev.DeviceID, in); err != nil {
		c.srv.Log.Warn("ack", "err", err) // không trả chỗ: lần Ack sau/kết nối sau sẽ thử lại
		return
	}
	for _, id := range in {
		c.imu.Lock()
		_, held := c.inflight[id]
		delete(c.inflight, id)
		c.imu.Unlock()
		if held {
			<-c.window
		}
	}
}
