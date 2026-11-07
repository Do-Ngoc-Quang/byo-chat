package message

import (
	"context"
	"errors"
	"sync"
	"time"

	"byo-chat/server/internal/ids"
)

var errEmptySubject = errors.New("subject rỗng")

// Job là việc làm nốt cho (conv, seq). Trạng thái cần làm nằm ở Entry.Pending,
// nên job chỉ cần định danh: mất job thì bộ sửa chữa tìm lại từ kho.
type Job struct {
	ConvID ids.ID
	Seq    uint64
}

// Queue là hàng đợi bền (JetStream). Handler trả lỗi thì job được giao lại.
type Queue interface {
	Publish(ctx context.Context, j Job) error
	// Consume chạy tới khi ctx hủy.
	Consume(ctx context.Context, handler func(context.Context, Job) error) error
}

// MemQueue: hàng đợi trong tiến trình cho test; Drop = true mô phỏng mất job.
type MemQueue struct {
	mu   sync.Mutex
	jobs []Job
	ch   chan struct{}
	Drop bool
}

func NewMemQueue() *MemQueue { return &MemQueue{ch: make(chan struct{}, 1)} }

func (q *MemQueue) Publish(_ context.Context, j Job) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.Drop {
		return nil
	}
	q.jobs = append(q.jobs, j)
	select {
	case q.ch <- struct{}{}:
	default:
	}
	return nil
}

func (q *MemQueue) Consume(ctx context.Context, h func(context.Context, Job) error) error {
	for {
		q.mu.Lock()
		var j Job
		ok := len(q.jobs) > 0
		if ok {
			j, q.jobs = q.jobs[0], q.jobs[1:]
		}
		q.mu.Unlock()
		if ok {
			if err := h(ctx, j); err != nil {
				q.mu.Lock()
				q.jobs = append(q.jobs, j)
				q.mu.Unlock()
				time.Sleep(10 * time.Millisecond)
			}
			continue
		}
		select {
		case <-ctx.Done():
			return nil
		case <-q.ch:
		}
	}
}
