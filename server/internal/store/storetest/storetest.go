// Package storetest: hợp đồng chung cho mọi MailboxStore, và hàm dựng kho cho test.
package storetest

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"testing"

	chatv1 "github.com/Do-Ngoc-Quang/byo-chat/server/gen/chat/v1"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/ids"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store/dynamo"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store/memory"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
)

var seqTables atomic.Int64

// DynamoEndpoint là TEST_DYNAMO_ENDPOINT (vd. http://localhost:8000); rỗng thì không chạy test DynamoDB.
func DynamoEndpoint() string { return os.Getenv("TEST_DYNAMO_ENDPOINT") }

// NewDynamo dựng Mailbox DynamoDB với tiền tố bảng riêng cho từng test.
func NewDynamo(t testing.TB) store.MailboxStore {
	t.Helper()
	ep := DynamoEndpoint()
	if ep == "" {
		t.Skip("đặt TEST_DYNAMO_ENDPOINT để chạy test DynamoDB")
	}
	db := dynamodb.New(dynamodb.Options{
		Region: "us-east-1", BaseEndpoint: aws.String(ep),
		Credentials: credentials.NewStaticCredentialsProvider("local", "local", ""),
	})
	prefix := fmt.Sprintf("t%d_%d_", os.Getpid(), seqTables.Add(1))
	mb := dynamo.New(db, prefix)
	if err := mb.EnsureTables(context.Background()); err != nil {
		t.Fatal(err)
	}
	return mb
}

// New trả kho dùng cho test dịch vụ: DynamoDB nếu có TEST_DYNAMO_ENDPOINT, ngược lại bộ nhớ.
func New(t testing.TB) store.MailboxStore {
	if DynamoEndpoint() != "" {
		return NewDynamo(t)
	}
	return memory.NewMailbox()
}

func sc(c ids.ID, seq uint64) store.Entry { return store.Entry{ConvID: c, Seq: seq} }

// RunMailbox chạy hợp đồng MailboxStore.
func RunMailbox(t *testing.T, mk func(testing.TB) store.MailboxStore) {
	ctx := context.Background()
	sender, d1, d2, d3 := ids.New(), ids.New(), ids.New(), ids.New()
	newConv := func(t *testing.T, ws ...store.Welcome) (store.MailboxStore, ids.ID) {
		mb := mk(t)
		c := ids.New()
		r, err := mb.CreateConv(ctx, c, store.CommitReq{ConvID: c, Sender: sender, Ciphertext: []byte("c0"), TsMs: 1000, Welcomes: ws})
		if err != nil || r.Seq != 1 || r.NewEpoch != 1 {
			t.Fatalf("CreateConv: %+v %v", r, err)
		}
		return mb, c
	}
	msg := func(c ids.ID, epoch uint64) store.AppendMsgReq {
		return store.AppendMsgReq{ConvID: c, ClientMsgID: ids.New(), Epoch: epoch, Kind: chatv1.EntryKind_ENTRY_KIND_APPLICATION,
			Sender: sender, Ciphertext: []byte("m"), TsMs: 2000, Recipients: []ids.ID{d1, d2}}
	}

	t.Run("CreateConvOnce", func(t *testing.T) {
		mb, c := newConv(t, store.Welcome{Device: d1, Ciphertext: []byte("w")})
		if _, err := mb.CreateConv(ctx, c, store.CommitReq{ConvID: c, Sender: sender, Ciphertext: []byte("again"), TsMs: 1}); err != store.ErrExists {
			t.Fatalf("muốn ErrExists, nhận %v", err)
		}
		h, err := mb.GetHead(ctx, c)
		if err != nil || h.HeadSeq != 1 || h.Epoch != 1 {
			t.Fatalf("%+v %v", h, err)
		}
		it, err := mb.ListInbox(ctx, d1, ids.ID{}, 10)
		if err != nil || len(it) != 1 || it[0].Kind != chatv1.EntryKind_ENTRY_KIND_WELCOME || string(it[0].Ciphertext) != "w" || it[0].Epoch != 1 {
			t.Fatalf("welcome: %+v %v", it, err)
		}
		if _, err := mb.GetHead(ctx, ids.New()); err != store.ErrNotFound {
			t.Fatalf("muốn ErrNotFound, nhận %v", err)
		}
	})

	t.Run("AppendEpochAndDedup", func(t *testing.T) {
		mb, c := newConv(t)
		if _, err := mb.AppendMessage(ctx, msg(c, 0)); !isEpoch(err, 1) {
			t.Fatalf("muốn EpochError{1}, nhận %v", err)
		}
		r := msg(c, 1)
		a, err := mb.AppendMessage(ctx, r)
		if err != nil || a.Seq != 2 || a.Duplicate {
			t.Fatalf("%+v %v", a, err)
		}
		b, err := mb.AppendMessage(ctx, r)
		if err != nil || !b.Duplicate || b.Seq != 2 || b.MessageID != a.MessageID {
			t.Fatalf("gửi lại: %+v %v", b, err)
		}
		log, err := mb.GetLog(ctx, c, 0, 10)
		if err != nil || len(log) != 2 || log[1].Seq != 2 || string(log[1].Ciphertext) != "m" || log[1].Pending == nil || len(log[1].Pending.Recipients) != 2 {
			t.Fatalf("log: %+v %v", log, err)
		}
		if _, err := mb.AppendMessage(ctx, msg(ids.New(), 1)); err != store.ErrNotFound {
			t.Fatalf("hội thoại lạ: %v", err)
		}
	})

	t.Run("ConcurrentAppendContiguous", func(t *testing.T) {
		mb, c := newConv(t)
		const n = 40
		var wg sync.WaitGroup
		got := make(chan uint64, n)
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				r, err := mb.AppendMessage(ctx, msg(c, 1))
				if err != nil {
					t.Error(err)
					return
				}
				got <- r.Seq
			}()
		}
		wg.Wait()
		close(got)
		seen := map[uint64]bool{}
		for s := range got {
			if seen[s] {
				t.Fatalf("seq %d trùng", s)
			}
			seen[s] = true
		}
		for s := uint64(2); s <= n+1; s++ {
			if !seen[s] {
				t.Fatalf("thiếu seq %d", s)
			}
		}
		log, _ := mb.GetLog(ctx, c, 0, 1000)
		if len(log) != n+1 {
			t.Fatalf("log %d mục, muốn %d", len(log), n+1)
		}
	})

	t.Run("CommitEpochRaceOneWinner", func(t *testing.T) {
		mb, c := newConv(t)
		var wg sync.WaitGroup
		var wins, losses atomic.Int32
		for i := 0; i < 6; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				_, err := mb.AppendCommit(ctx, store.CommitReq{ConvID: c, ExpectedEpoch: 1, Sender: sender,
					Ciphertext: []byte("x"), TsMs: 3000, IdemKey: ids.New().String()})
				switch {
				case err == nil:
					wins.Add(1)
				case isEpoch(err, 2):
					losses.Add(1)
				default:
					t.Error(err)
				}
			}()
		}
		wg.Wait()
		if wins.Load() != 1 || losses.Load() != 5 {
			t.Fatalf("thắng %d thua %d", wins.Load(), losses.Load())
		}
		h, _ := mb.GetHead(ctx, c)
		if h.Epoch != 2 || h.HeadSeq != 2 {
			t.Fatalf("%+v", h)
		}
	})

	t.Run("CommitIdempotencyAndWelcomeAtomic", func(t *testing.T) {
		mb, c := newConv(t)
		req := store.CommitReq{ConvID: c, ExpectedEpoch: 1, Sender: sender, Ciphertext: []byte("c1"), TsMs: 3000, IdemKey: "k1",
			Welcomes: []store.Welcome{{Device: d3, Ciphertext: []byte("w3")}}}
		a, err := mb.AppendCommit(ctx, req)
		if err != nil || a.Seq != 2 || a.NewEpoch != 2 || a.Duplicate {
			t.Fatalf("%+v %v", a, err)
		}
		b, err := mb.AppendCommit(ctx, req) // phản hồi bị mất, gửi lại
		if err != nil || !b.Duplicate || b.Seq != 2 || b.NewEpoch != 2 {
			t.Fatalf("gửi lại: %+v %v", b, err)
		}
		it, _ := mb.ListInbox(ctx, d3, ids.ID{}, 10)
		if len(it) != 1 || it[0].Epoch != 2 || it[0].Seq != 2 {
			t.Fatalf("welcome: %+v", it)
		}
		log, _ := mb.GetLog(ctx, c, 0, 10)
		if len(log) != 2 {
			t.Fatalf("log %d mục", len(log))
		}
	})

	t.Run("GetLogAcrossBuckets", func(t *testing.T) {
		if testing.Short() {
			t.Skip()
		}
		mb, c := newConv(t)
		const total = 1100 // vượt một bucket (1024 seq)
		for i := 0; i < total; i++ {
			if _, err := mb.AppendMessage(ctx, msg(c, 1)); err != nil {
				t.Fatal(err)
			}
		}
		var after uint64
		var count int
		for {
			es, err := mb.GetLog(ctx, c, after, 200)
			if err != nil {
				t.Fatal(err)
			}
			if len(es) == 0 {
				break
			}
			for _, e := range es {
				if e.Seq != after+1 {
					t.Fatalf("seq nhảy: %d sau %d", e.Seq, after)
				}
				after = e.Seq
				count++
			}
		}
		if count != total+1 {
			t.Fatalf("đọc %d mục, muốn %d", count, total+1)
		}
	})

	t.Run("PointersIdempotentAndOrdered", func(t *testing.T) {
		mb, c := newConv(t)
		var entries []store.Entry
		for i := 0; i < 3; i++ {
			r, _ := mb.AppendMessage(ctx, msg(c, 1))
			e, err := mb.GetEntry(ctx, c, r.Seq)
			if err != nil {
				t.Fatal(err)
			}
			entries = append(entries, e)
		}
		for rep := 0; rep < 3; rep++ {
			for _, e := range entries {
				if err := mb.PutPointers(ctx, e, []ids.ID{d1, d2}); err != nil {
					t.Fatal(err)
				}
			}
		}
		for _, d := range []ids.ID{d1, d2} {
			it, err := mb.ListInbox(ctx, d, ids.ID{}, 100)
			if err != nil || len(it) != 3 {
				t.Fatalf("%d con trỏ, muốn 3 (%v)", len(it), err)
			}
			for i := range it {
				if it[i].Seq != entries[i].Seq || (i > 0 && bytes.Compare(it[i-1].InboxID[:], it[i].InboxID[:]) >= 0) {
					t.Fatalf("sai thứ tự: %+v", it)
				}
			}
			rest, _ := mb.ListInbox(ctx, d, it[0].InboxID, 100)
			if len(rest) != 2 {
				t.Fatalf("sau cursor còn %d", len(rest))
			}
			if err := mb.DeleteInbox(ctx, d, []ids.ID{it[0].InboxID, it[1].InboxID}); err != nil {
				t.Fatal(err)
			}
			if left, _ := mb.ListInbox(ctx, d, ids.ID{}, 100); len(left) != 1 {
				t.Fatalf("sau xóa còn %d", len(left))
			}
		}
	})

	t.Run("PendingLifecycle", func(t *testing.T) {
		mb, c := newConv(t)
		r, _ := mb.AppendMessage(ctx, msg(c, 1))
		p, err := mb.PendingFanouts(ctx, 100)
		if err != nil {
			t.Fatal(err)
		}
		found := 0
		for _, e := range p {
			if e.ConvID == c {
				found++
			}
		}
		if found != 2 { // Commit đầu và tin vừa gửi
			t.Fatalf("mục dở của conv: %d, muốn 2", found)
		}
		for _, s := range []uint64{1, r.Seq} {
			if err := mb.CompleteFanout(ctx, c, s); err != nil {
				t.Fatal(err)
			}
			if err := mb.CompleteFanout(ctx, c, s); err != nil { // idempotent
				t.Fatal(err)
			}
		}
		p, _ = mb.PendingFanouts(ctx, 100)
		for _, e := range p {
			if e.ConvID == c {
				t.Fatal("còn mục dở sau CompleteFanout")
			}
		}
		e, _ := mb.GetEntry(ctx, c, r.Seq)
		if e.Pending != nil || string(e.Ciphertext) != "m" {
			t.Fatalf("%+v", e)
		}
	})
	_ = sc
}

func isEpoch(err error, cur uint64) bool {
	ee, ok := err.(*store.EpochError)
	return ok && ee.Current == cur
}
