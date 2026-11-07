package api

import (
	"net"
	"sync"
	"time"
)

// ipLimiter: cửa sổ trượt theo địa chỉ IP, trong bộ nhớ tiến trình. Dùng cho RPC chưa đăng nhập (StartLink).
// Giới hạn: chạy sau proxy thì mọi yêu cầu cùng một IP (cần đọc X-Forwarded-For có kiểm soát); nhiều node thì mỗi node
// đếm riêng (cần Valkey). Zero value dùng được.
type ipLimiter struct {
	mu   sync.Mutex
	hits map[string][]time.Time
}

// allow ghi một lần gọi và trả true nếu còn trong hạn mức n lần mỗi window; false kèm thời gian chờ nếu vượt.
func (l *ipLimiter) allow(addr string, n int, window time.Duration, now time.Time) (bool, time.Duration) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.hits == nil {
		l.hits = map[string][]time.Time{}
	}
	h := l.hits[host][:0]
	for _, t := range l.hits[host] {
		if now.Sub(t) < window {
			h = append(h, t)
		}
	}
	if len(h) >= n {
		l.hits[host] = h
		return false, window - now.Sub(h[0])
	}
	l.hits[host] = append(h, now)
	if len(l.hits) > 10000 { // dọn các IP đã hết hạn để bản đồ không phình mãi
		for k, v := range l.hits {
			if len(v) == 0 || now.Sub(v[len(v)-1]) >= window {
				delete(l.hits, k)
			}
		}
	}
	return true, 0
}
