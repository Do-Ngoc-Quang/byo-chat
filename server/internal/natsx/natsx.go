// Package natsx: Bus (NATS core) và Queue (JetStream) cho Message Service.
package natsx

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"time"

	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/ids"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/message"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// Bus cài message.Bus bằng NATS core (subject dev.<device_id>).
type Bus struct{ nc *nats.Conn }

func NewBus(nc *nats.Conn) *Bus { return &Bus{nc: nc} }

func (b *Bus) Publish(subject string, data []byte) error { return b.nc.Publish(subject, data) }

func (b *Bus) Subscribe(subject string, fn func([]byte)) (func(), error) {
	sub, err := b.nc.Subscribe(subject, func(m *nats.Msg) { fn(m.Data) })
	if err != nil {
		return nil, err
	}
	return func() { _ = sub.Unsubscribe() }, nil
}

const (
	streamName = "FANOUT"
	subject    = "fanout.job"
	consumer   = "fanout-worker"
)

// Queue cài message.Queue bằng JetStream: job bền, giao at-least-once, giao lại khi handler lỗi.
type Queue struct {
	js jetstream.JetStream
}

// NewQueue tạo stream và consumer bền nếu chưa có.
func NewQueue(ctx context.Context, nc *nats.Conn) (*Queue, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, err
	}
	if _, err := js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
		Name: streamName, Subjects: []string{subject},
		Retention: jetstream.WorkQueuePolicy, Storage: jetstream.FileStorage,
		Duplicates: 2 * time.Minute, // khử trùng theo Nats-Msg-Id
	}); err != nil {
		return nil, err
	}
	return &Queue{js: js}, nil
}

type jobWire struct {
	Conv string `json:"c"`
	Seq  uint64 `json:"s"`
}

func (q *Queue) Publish(ctx context.Context, j message.Job) error {
	b, _ := json.Marshal(jobWire{j.ConvID.Hex(), j.Seq})
	// Nats-Msg-Id = (conv, seq): job trùng trong cửa sổ Duplicates bị bỏ, và dù trùng cũng idempotent.
	_, err := q.js.Publish(ctx, subject, b, jetstream.WithMsgID(j.ConvID.Hex()+"/"+itoa(j.Seq)))
	return err
}

func itoa(n uint64) string { return strconv.FormatUint(n, 10) }

func (q *Queue) Consume(ctx context.Context, h func(context.Context, message.Job) error) error {
	c, err := q.js.CreateOrUpdateConsumer(ctx, streamName, jetstream.ConsumerConfig{
		Durable: consumer, AckPolicy: jetstream.AckExplicitPolicy, AckWait: 30 * time.Second, MaxAckPending: 256,
	})
	if err != nil {
		return err
	}
	cc, err := c.Consume(func(m jetstream.Msg) {
		var w jobWire
		if err := json.Unmarshal(m.Data(), &w); err != nil {
			_ = m.Term() // job hỏng: bỏ; Repair vẫn tìm lại từ kho
			return
		}
		raw, err := hexID(w.Conv)
		if err != nil {
			_ = m.Term()
			return
		}
		if err := h(ctx, message.Job{ConvID: raw, Seq: w.Seq}); err != nil {
			_ = m.NakWithDelay(time.Second) // giao lại sau
			return
		}
		_ = m.Ack()
	})
	if err != nil {
		return err
	}
	<-ctx.Done()
	cc.Stop()
	return nil
}

func hexID(s string) (ids.ID, error) {
	var id ids.ID
	if len(s) != 32 {
		return id, errors.New("conv hex sai độ dài")
	}
	for i := 0; i < 16; i++ {
		hi, lo := unhex(s[2*i]), unhex(s[2*i+1])
		if hi > 15 || lo > 15 {
			return id, errors.New("conv hex sai ký tự")
		}
		id[i] = hi<<4 | lo
	}
	return id, nil
}

func unhex(c byte) byte {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	}
	return 255
}
