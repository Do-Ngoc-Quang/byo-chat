package message

import (
	"strings"
	"sync"
)

// Bus chuyển khung đã mã hóa tới gateway giữ kết nối của thiết bị (NATS subject
// `dev.<device_id>`). Mất tin trên bus không mất dữ liệu: hộp thư vẫn còn con trỏ.
type Bus interface {
	Publish(subject string, data []byte) error
	// Subscribe trả hàm hủy đăng ký.
	Subscribe(subject string, fn func(data []byte)) (func(), error)
}

// DevSubject là subject của một thiết bị.
func DevSubject(deviceHex string) string { return "dev." + deviceHex }

// MemBus là Bus trong tiến trình (test và chạy một node).
type MemBus struct {
	mu   sync.Mutex
	subs map[string]map[int]func([]byte)
	next int
}

func NewMemBus() *MemBus { return &MemBus{subs: map[string]map[int]func([]byte){}} }

func (b *MemBus) Publish(subject string, data []byte) error {
	b.mu.Lock()
	var fns []func([]byte)
	for _, f := range b.subs[subject] {
		fns = append(fns, f)
	}
	b.mu.Unlock()
	for _, f := range fns {
		f(append([]byte(nil), data...))
	}
	return nil
}

func (b *MemBus) Subscribe(subject string, fn func([]byte)) (func(), error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if strings.TrimSpace(subject) == "" {
		return nil, errEmptySubject
	}
	m := b.subs[subject]
	if m == nil {
		m = map[int]func([]byte){}
		b.subs[subject] = m
	}
	b.next++
	id := b.next
	m[id] = fn
	return func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		delete(m, id)
	}, nil
}
