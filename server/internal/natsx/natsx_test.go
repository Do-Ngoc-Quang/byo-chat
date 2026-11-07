package natsx_test

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/ids"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/message"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/natsx"
	natsserver "github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
)

// Chạy NATS server nhúng có JetStream (thư mục tạm), không cần Docker.
func startNATS(t *testing.T) *nats.Conn {
	t.Helper()
	s, err := natsserver.NewServer(&natsserver.Options{Port: -1, JetStream: true, StoreDir: t.TempDir(), NoLog: true, NoSigs: true})
	if err != nil {
		t.Fatal(err)
	}
	go s.Start()
	if !s.ReadyForConnections(10 * time.Second) {
		t.Fatal("NATS không sẵn sàng")
	}
	t.Cleanup(s.Shutdown)
	nc, err := nats.Connect(s.ClientURL())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(nc.Close)
	return nc
}

func TestBusPubSub(t *testing.T) {
	nc := startNATS(t)
	b := natsx.NewBus(nc)
	got := make(chan string, 1)
	unsub, err := b.Subscribe("dev.abc", func(d []byte) { got <- string(d) })
	if err != nil {
		t.Fatal(err)
	}
	defer unsub()
	nc.Flush()
	b.Publish("dev.abc", []byte("hi"))
	select {
	case v := <-got:
		if v != "hi" {
			t.Fatal(v)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("không nhận được")
	}
}

// Handler lỗi lần đầu thì job được giao lại; job lặp (cùng Msg-Id) bị khử trùng.
func TestQueueRedeliveryAndDedup(t *testing.T) {
	nc := startNATS(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	q, err := natsx.NewQueue(ctx, nc)
	if err != nil {
		t.Fatal(err)
	}
	job := message.Job{ConvID: ids.New(), Seq: 7}
	for i := 0; i < 3; i++ { // gọi Publish ba lần cùng job
		if err := q.Publish(ctx, job); err != nil {
			t.Fatal(err)
		}
	}
	var calls, fails atomic.Int32
	done := make(chan message.Job, 4)
	go q.Consume(ctx, func(_ context.Context, j message.Job) error {
		calls.Add(1)
		if fails.Add(1) == 1 {
			return errors.New("lỗi tạm")
		}
		done <- j
		return nil
	})
	select {
	case j := <-done:
		if j != job {
			t.Fatalf("job %+v", j)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("job không được giao lại")
	}
	time.Sleep(500 * time.Millisecond)
	if calls.Load() != 2 { // 1 lỗi + 1 thành công; hai bản trùng đã bị khử
		t.Fatalf("handler chạy %d lần, muốn 2", calls.Load())
	}
}
