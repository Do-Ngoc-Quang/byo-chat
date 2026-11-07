package message

import (
	"context"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
	"google.golang.org/protobuf/proto"
)

// enqueue đẩy job làm nốt. Lỗi hàng đợi chỉ ghi log: dữ liệu đã bền trong kho
// (Entry.Pending) nên Repair sẽ tìm lại; không được làm hỏng phản hồi đã thành công.
func (s *Service) enqueue(ctx context.Context, conv ids.ID, seq uint64) {
	if err := s.Queue.Publish(ctx, Job{ConvID: conv, Seq: seq}); err != nil {
		s.Log.Warn("không đẩy được job fanout; chờ sửa chữa", "conv", conv.String(), "seq", seq, "err", err)
	}
}

// settleHead làm nốt fanout của mục cuối nếu còn dở (idempotent).
func (s *Service) settleHead(ctx context.Context, conv ids.ID) {
	h, err := s.Mailbox.GetHead(ctx, conv)
	if err != nil {
		return
	}
	if err := s.RunFanout(ctx, Job{ConvID: conv, Seq: h.HeadSeq}); err != nil {
		s.Log.Warn("settleHead", "err", err)
	}
}

// RunFanout làm nốt mọi việc sau giao dịch cho (conv, seq). Mọi bước idempotent
// nên chạy lại sau sập, giao job hai lần, hay chạy song song với sửa chữa đều an toàn:
//  1. cập nhật thành viên/vai trò và GroupInfo (Postgres)
//  2. ghi con trỏ hộp thư cho thiết bị nhận
//  3. xóa Pending, rồi đẩy Deliver qua bus
func (s *Service) RunFanout(ctx context.Context, j Job) error {
	e, err := s.Mailbox.GetEntry(ctx, j.ConvID, j.Seq)
	if err != nil {
		if err == store.ErrNotFound {
			return nil
		}
		return err
	}
	if e.Pending == nil {
		return nil
	}
	p := e.Pending
	if e.Kind == chatv1.EntryKind_ENTRY_KIND_COMMIT {
		if len(p.Added)+len(p.RemovedAcct)+len(p.RoleChanges) > 0 {
			if err := s.Meta.ApplyMembership(ctx, e.ConvID, p.Added, p.RemovedAcct, p.RoleChanges); err != nil {
				return err
			}
		}
		if len(p.GroupInfo) > 0 {
			if err := s.Meta.PutGroupInfo(ctx, e.ConvID, p.NewEpoch, p.GroupInfo); err != nil {
				return err
			}
		}
	}
	if len(p.Recipients) > 0 {
		if err := s.Mailbox.PutPointers(ctx, e, p.Recipients); err != nil {
			return err
		}
	}
	if err := s.Mailbox.CompleteFanout(ctx, e.ConvID, e.Seq); err != nil {
		return err
	}
	s.publishDeliver(p.Recipients, s.deliverFor(e))
	// Welcome: đẩy cho thiết bị mới đang online; thiết bị offline lấy từ hộp thư khi kết nối.
	for _, dv := range p.WelcomeTo {
		it, err := s.Mailbox.GetInboxItem(ctx, dv, ids.InboxID(e.TsMs, e.ConvID, e.Seq))
		if err != nil {
			continue
		}
		s.publishDeliver([]ids.ID{dv}, &chatv1.Deliver{InboxId: it.InboxID.Bytes(), ConvId: e.ConvID.Bytes(), Seq: e.Seq,
			Kind: chatv1.EntryKind_ENTRY_KIND_WELCOME, SenderDeviceId: e.Sender.Bytes(), MlsEpoch: it.Epoch,
			Ciphertext: it.Ciphertext, ServerTsMs: e.TsMs})
	}
	return nil
}

func (s *Service) deliverFor(e store.Entry) *chatv1.Deliver {
	return &chatv1.Deliver{
		InboxId: ids.InboxID(e.TsMs, e.ConvID, e.Seq).Bytes(), ConvId: e.ConvID.Bytes(), Seq: e.Seq,
		Kind: e.Kind, SenderDeviceId: e.Sender.Bytes(), MlsEpoch: e.Epoch, Ciphertext: e.Ciphertext, ServerTsMs: e.TsMs,
	}
}

func (s *Service) publishDeliver(devs []ids.ID, d *chatv1.Deliver) {
	b, err := proto.Marshal(d)
	if err != nil {
		return
	}
	for _, dv := range devs {
		if err := s.Bus.Publish(DevSubject(dv.Hex()), b); err != nil {
			s.Log.Warn("publish bus", "err", err)
		}
	}
}

// Worker tiêu thụ hàng đợi fanout tới khi ctx hủy.
func (s *Service) Worker(ctx context.Context) error {
	return s.Queue.Consume(ctx, s.RunFanout)
}

// Repair quét các mục còn Pending và làm nốt: bù cho job bị mất khi sập giữa giao dịch
// và lúc đẩy hàng đợi. Chạy định kỳ; trả số mục đã xử lý.
func (s *Service) Repair(ctx context.Context, limit int) (int, error) {
	list, err := s.Mailbox.PendingFanouts(ctx, limit)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, e := range list {
		if err := s.RunFanout(ctx, Job{ConvID: e.ConvID, Seq: e.Seq}); err != nil {
			return n, err
		}
		n++
	}
	return n, nil
}

// RepairLoop chạy Repair mỗi interval.
func (s *Service) RepairLoop(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if _, err := s.Repair(ctx, 100); err != nil {
				s.Log.Warn("repair", "err", err)
			}
		}
	}
}

// Backlog trả tồn đọng của thiết bị sau cursor (Hello.inbox_cursor), theo inbox_id tăng dần.
func (s *Service) Backlog(ctx context.Context, device ids.ID, cursor ids.ID, limit int) ([]*chatv1.Deliver, error) {
	items, err := s.Mailbox.ListInbox(ctx, device, cursor, limit)
	if err != nil {
		return nil, err
	}
	out := make([]*chatv1.Deliver, 0, len(items))
	for _, it := range items {
		d := &chatv1.Deliver{InboxId: it.InboxID.Bytes(), ConvId: it.ConvID.Bytes(), Seq: it.Seq, Kind: it.Kind,
			SenderDeviceId: it.Sender.Bytes(), MlsEpoch: it.Epoch, ServerTsMs: it.TsMs}
		if it.Kind == chatv1.EntryKind_ENTRY_KIND_WELCOME {
			d.Ciphertext = it.Ciphertext
		} else {
			e, err := s.Mailbox.GetEntry(ctx, it.ConvID, it.Seq)
			if err == store.ErrNotFound {
				// Log đã hết TTL: bỏ con trỏ mồ côi.
				_ = s.Mailbox.DeleteInbox(ctx, device, []ids.ID{it.InboxID})
				continue
			}
			if err != nil {
				return nil, err
			}
			d.Ciphertext = e.Ciphertext
		}
		out = append(out, d)
	}
	return out, nil
}

// Settle chạy Repair cho tới khi hết việc dở (dùng trong test và khi tắt máy êm).
func (s *Service) Settle(ctx context.Context) {
	for {
		n, err := s.Repair(ctx, 100)
		if err != nil || n == 0 {
			return
		}
	}
}
