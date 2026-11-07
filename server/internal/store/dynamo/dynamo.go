// Package dynamo: MailboxStore trên DynamoDB (thiet-ke-chinh.md mục 13).
//
// Bảng:
//
//	conv_head     PK pk(S)=conv       head_seq, epoch
//	conv_log      PK pk(S)=conv#bucket, SK seq(N); pending(B) chỉ có khi còn việc dở
//	device_inbox  PK pk(B)=device, SK sk(B)=inbox_id
//	dedup         PK pk(S)=conv#client_msg_id (TTL 24 giờ)
//	idem          PK pk(S)=conv#idempotency-key (TTL 24 giờ)
//
// Mọi thao tác ghi là giao dịch có điều kiện hoặc ghi đè khóa xác định (idempotent).
package dynamo

import (
	"context"
	"encoding/json"
	"errors"
	"math/rand/v2"
	"strconv"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

const (
	bucketSize   = 1024
	logTTL       = 30 * 24 * time.Hour // ciphertext TTL 30 ngày (CLAUDE.md)
	dedupTTL     = 24 * time.Hour
	maxTxRetries = 64
)

type Mailbox struct {
	db     *dynamodb.Client
	prefix string
	now    func() time.Time
}

// New dùng client đã cấu hình (endpoint local hoặc AWS). prefix ngăn va chạm tên bảng giữa môi trường/test.
func New(db *dynamodb.Client, prefix string) *Mailbox {
	return &Mailbox{db: db, prefix: prefix, now: time.Now}
}

func (m *Mailbox) t(n string) *string { return aws.String(m.prefix + n) }

// EnsureTables tạo bảng nếu chưa có (dev/test; môi trường thật dùng Terraform).
func (m *Mailbox) EnsureTables(ctx context.Context) error {
	s, b, n := types.ScalarAttributeTypeS, types.ScalarAttributeTypeB, types.ScalarAttributeTypeN
	defs := []struct {
		name         string
		pk, sk       string
		pkT, skT     types.ScalarAttributeType
		hasSK, hasTT bool
	}{
		{"conv_head", "pk", "", s, s, false, false},
		{"conv_log", "pk", "seq", s, n, true, true},
		{"device_inbox", "pk", "sk", b, b, true, true},
		{"dedup", "pk", "", s, s, false, true},
		{"idem", "pk", "", s, s, false, true},
	}
	for _, d := range defs {
		attrs := []types.AttributeDefinition{{AttributeName: aws.String(d.pk), AttributeType: d.pkT}}
		keys := []types.KeySchemaElement{{AttributeName: aws.String(d.pk), KeyType: types.KeyTypeHash}}
		if d.hasSK {
			attrs = append(attrs, types.AttributeDefinition{AttributeName: aws.String(d.sk), AttributeType: d.skT})
			keys = append(keys, types.KeySchemaElement{AttributeName: aws.String(d.sk), KeyType: types.KeyTypeRange})
		}
		_, err := m.db.CreateTable(ctx, &dynamodb.CreateTableInput{
			TableName: m.t(d.name), AttributeDefinitions: attrs, KeySchema: keys, BillingMode: types.BillingModePayPerRequest,
		})
		var inUse *types.ResourceInUseException
		if err != nil && !errors.As(err, &inUse) {
			return err
		}
		if d.name != "conv_head" {
			_, err = m.db.UpdateTimeToLive(ctx, &dynamodb.UpdateTimeToLiveInput{
				TableName:               m.t(d.name),
				TimeToLiveSpecification: &types.TimeToLiveSpecification{AttributeName: aws.String("ttl"), Enabled: aws.Bool(true)},
			})
			if err != nil && !isTTLAlready(err) {
				return err
			}
		}
	}
	return nil
}

// backoff nghỉ ngẫu nhiên tăng dần (tối đa ~64 ms) để các lần cấp seq tranh chấp không đồng bộ nhau.
func backoff(ctx context.Context, try int) error {
	d := time.Duration(rand.Int64N(int64(time.Millisecond) << min(try, 6)))
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(d):
		return nil
	}
}

func isTTLAlready(err error) bool {
	var ve interface{ ErrorCode() string }
	return errors.As(err, &ve) && ve.ErrorCode() == "ValidationException"
}

// ---- helpers thuộc tính ----

func sv(s string) types.AttributeValue { return &types.AttributeValueMemberS{Value: s} }
func bv(b []byte) types.AttributeValue { return &types.AttributeValueMemberB{Value: b} }
func nv(n uint64) types.AttributeValue {
	return &types.AttributeValueMemberN{Value: strconv.FormatUint(n, 10)}
}

func getN(it map[string]types.AttributeValue, k string) uint64 {
	if v, ok := it[k].(*types.AttributeValueMemberN); ok {
		n, _ := strconv.ParseUint(v.Value, 10, 64)
		return n
	}
	return 0
}
func getB(it map[string]types.AttributeValue, k string) []byte {
	if v, ok := it[k].(*types.AttributeValueMemberB); ok {
		return v.Value
	}
	return nil
}
func getID(it map[string]types.AttributeValue, k string) ids.ID {
	id, _ := ids.FromBytes(getB(it, k))
	return id
}

func logKey(conv ids.ID, seq uint64) map[string]types.AttributeValue {
	return map[string]types.AttributeValue{
		"pk": sv(conv.Hex() + "#" + strconv.FormatUint(seq/bucketSize, 10)), "seq": nv(seq)}
}

func (m *Mailbox) ttl(d time.Duration) types.AttributeValue {
	return nv(uint64(m.now().Add(d).Unix()))
}

// ---- Fanout <-> JSON ----

type memberRec struct {
	Account []byte `json:"a"`
	Role    int32  `json:"r"`
}
type fanoutRec struct {
	Recipients [][]byte    `json:"rc,omitempty"`
	WelcomeTo  [][]byte    `json:"wt,omitempty"`
	GroupInfo  []byte      `json:"gi,omitempty"`
	NewEpoch   uint64      `json:"ne,omitempty"`
	Added      []memberRec `json:"ad,omitempty"`
	Removed    [][]byte    `json:"rm,omitempty"`
	Roles      []memberRec `json:"ro,omitempty"`
}

func idsToBytes(in []ids.ID) [][]byte {
	out := make([][]byte, len(in))
	for i := range in {
		out[i] = in[i].Bytes()
	}
	return out
}
func bytesToIDs(in [][]byte) []ids.ID {
	out := make([]ids.ID, 0, len(in))
	for _, b := range in {
		if id, err := ids.FromBytes(b); err == nil {
			out = append(out, id)
		}
	}
	return out
}
func toRecs(ms []*chatv1.Member) []memberRec {
	var out []memberRec
	for _, m := range ms {
		out = append(out, memberRec{m.AccountId, int32(m.Role)})
	}
	return out
}
func fromRecs(rs []memberRec) []*chatv1.Member {
	var out []*chatv1.Member
	for _, r := range rs {
		out = append(out, &chatv1.Member{AccountId: r.Account, Role: chatv1.Role(r.Role)})
	}
	return out
}

func encodeFanout(f store.Fanout) []byte {
	b, _ := json.Marshal(fanoutRec{
		Recipients: idsToBytes(f.Recipients), WelcomeTo: idsToBytes(f.WelcomeTo), GroupInfo: f.GroupInfo, NewEpoch: f.NewEpoch,
		Added: toRecs(f.Added), Removed: idsToBytes(f.RemovedAcct), Roles: toRecs(f.RoleChanges),
	})
	return b
}
func decodeFanout(b []byte) (*store.Fanout, error) {
	var r fanoutRec
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, err
	}
	return &store.Fanout{Recipients: bytesToIDs(r.Recipients), WelcomeTo: bytesToIDs(r.WelcomeTo), GroupInfo: r.GroupInfo,
		NewEpoch: r.NewEpoch, Added: fromRecs(r.Added), RemovedAcct: bytesToIDs(r.Removed), RoleChanges: fromRecs(r.Roles)}, nil
}

// ---- mục log ----

func logItem(e store.Entry) map[string]types.AttributeValue {
	it := logKey(e.ConvID, e.Seq)
	it["conv"] = bv(e.ConvID.Bytes())
	it["kind"] = nv(uint64(e.Kind))
	it["sender"] = bv(e.Sender.Bytes())
	it["epoch"] = nv(e.Epoch)
	it["ct"] = bv(e.Ciphertext)
	it["ts"] = nv(e.TsMs)
	it["msg_id"] = bv(e.MessageID.Bytes())
	if e.Pending != nil {
		it["pending"] = bv(encodeFanout(*e.Pending))
	}
	return it
}

func (m *Mailbox) withTTL(it map[string]types.AttributeValue) map[string]types.AttributeValue {
	it["ttl"] = m.ttl(logTTL)
	return it
}

func parseEntry(it map[string]types.AttributeValue) (store.Entry, error) {
	e := store.Entry{
		ConvID: getID(it, "conv"), Seq: getN(it, "seq"), Kind: chatv1.EntryKind(getN(it, "kind")),
		Sender: getID(it, "sender"), Epoch: getN(it, "epoch"), Ciphertext: getB(it, "ct"),
		TsMs: getN(it, "ts"), MessageID: getID(it, "msg_id"),
	}
	if p := getB(it, "pending"); p != nil {
		f, err := decodeFanout(p)
		if err != nil {
			return e, err
		}
		e.Pending = f
	}
	return e, nil
}

func inboxItem(device ids.ID, inbox ids.ID, conv ids.ID, seq uint64, kind chatv1.EntryKind, sender ids.ID, epoch uint64, ct []byte, ts uint64) map[string]types.AttributeValue {
	it := map[string]types.AttributeValue{
		"pk": bv(device.Bytes()), "sk": bv(inbox.Bytes()), "conv": bv(conv.Bytes()), "seq": nv(seq),
		"kind": nv(uint64(kind)), "sender": bv(sender.Bytes()), "epoch": nv(epoch), "ts": nv(ts),
	}
	if len(ct) > 0 {
		it["ct"] = bv(ct)
	}
	return it
}

func parseInbox(it map[string]types.AttributeValue) store.InboxItem {
	return store.InboxItem{
		Device: getID(it, "pk"), InboxID: getID(it, "sk"), ConvID: getID(it, "conv"), Seq: getN(it, "seq"),
		Kind: chatv1.EntryKind(getN(it, "kind")), Sender: getID(it, "sender"), Epoch: getN(it, "epoch"),
		Ciphertext: getB(it, "ct"), TsMs: getN(it, "ts"),
	}
}

func (m *Mailbox) welcomePuts(e store.Entry, ws []store.Welcome) []types.TransactWriteItem {
	out := make([]types.TransactWriteItem, 0, len(ws))
	for _, w := range ws {
		it := inboxItem(w.Device, ids.InboxID(e.TsMs, e.ConvID, e.Seq), e.ConvID, e.Seq,
			chatv1.EntryKind_ENTRY_KIND_WELCOME, e.Sender, e.Epoch+1, w.Ciphertext, e.TsMs)
		it["ttl"] = m.ttl(logTTL)
		out = append(out, types.TransactWriteItem{Put: &types.Put{TableName: m.t("device_inbox"), Item: it}})
	}
	return out
}

// ---- cancellation helper ----

func cancelReasons(err error) ([]types.CancellationReason, bool) {
	var tce *types.TransactionCanceledException
	if errors.As(err, &tce) {
		return tce.CancellationReasons, true
	}
	return nil, false
}
func condFailed(rs []types.CancellationReason, i int) bool {
	return i < len(rs) && rs[i].Code != nil && *rs[i].Code == "ConditionalCheckFailed"
}

// ---- MailboxStore ----

func (m *Mailbox) CreateConv(ctx context.Context, conv ids.ID, r store.CommitReq) (store.CommitResult, error) {
	fo := r.Fanout
	fo.NewEpoch = 1
	e := store.Entry{ConvID: conv, Seq: 1, Kind: chatv1.EntryKind_ENTRY_KIND_COMMIT, Sender: r.Sender,
		Epoch: 0, Ciphertext: r.Ciphertext, TsMs: r.TsMs, MessageID: ids.New(), Pending: &fo}
	items := []types.TransactWriteItem{
		{Put: &types.Put{TableName: m.t("conv_head"),
			Item:                map[string]types.AttributeValue{"pk": sv(conv.Hex()), "head_seq": nv(1), "epoch": nv(1)},
			ConditionExpression: aws.String("attribute_not_exists(pk)")}},
		{Put: &types.Put{TableName: m.t("conv_log"), Item: m.withTTL(logItem(e))}},
	}
	items = append(items, m.welcomePuts(e, r.Welcomes)...)
	if _, err := m.db.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{TransactItems: items}); err != nil {
		if rs, ok := cancelReasons(err); ok && condFailed(rs, 0) {
			return store.CommitResult{}, store.ErrExists
		}
		return store.CommitResult{}, err
	}
	return store.CommitResult{Seq: 1, NewEpoch: 1}, nil
}

func (m *Mailbox) GetHead(ctx context.Context, conv ids.ID) (store.Head, error) {
	out, err := m.db.GetItem(ctx, &dynamodb.GetItemInput{TableName: m.t("conv_head"), ConsistentRead: aws.Bool(true),
		Key: map[string]types.AttributeValue{"pk": sv(conv.Hex())}})
	if err != nil {
		return store.Head{}, err
	}
	if out.Item == nil {
		return store.Head{}, store.ErrNotFound
	}
	return store.Head{HeadSeq: getN(out.Item, "head_seq"), Epoch: getN(out.Item, "epoch")}, nil
}

func (m *Mailbox) AppendMessage(ctx context.Context, r store.AppendMsgReq) (store.AppendResult, error) {
	dk := r.ConvID.Hex() + "#" + r.ClientMsgID.Hex()
	for try := 0; try < maxTxRetries; try++ {
		if d, err := m.db.GetItem(ctx, &dynamodb.GetItemInput{TableName: m.t("dedup"), ConsistentRead: aws.Bool(true),
			Key: map[string]types.AttributeValue{"pk": sv(dk)}}); err != nil {
			return store.AppendResult{}, err
		} else if d.Item != nil {
			return store.AppendResult{MessageID: getID(d.Item, "msg_id"), Seq: getN(d.Item, "seq"), TsMs: getN(d.Item, "ts"), Duplicate: true}, nil
		}
		h, err := m.GetHead(ctx, r.ConvID)
		if err != nil {
			return store.AppendResult{}, err
		}
		if r.Epoch != h.Epoch {
			return store.AppendResult{}, &store.EpochError{Current: h.Epoch}
		}
		seq := h.HeadSeq + 1
		e := store.Entry{ConvID: r.ConvID, Seq: seq, Kind: r.Kind, Sender: r.Sender, Epoch: r.Epoch,
			Ciphertext: r.Ciphertext, TsMs: r.TsMs, MessageID: ids.New(), Pending: &store.Fanout{Recipients: r.Recipients}}
		_, err = m.db.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{TransactItems: []types.TransactWriteItem{
			{Update: &types.Update{TableName: m.t("conv_head"), Key: map[string]types.AttributeValue{"pk": sv(r.ConvID.Hex())},
				UpdateExpression:    aws.String("SET head_seq = :n"),
				ConditionExpression: aws.String("head_seq = :h AND epoch = :e"),
				ExpressionAttributeValues: map[string]types.AttributeValue{
					":n": nv(seq), ":h": nv(h.HeadSeq), ":e": nv(h.Epoch)}}},
			{Put: &types.Put{TableName: m.t("conv_log"), Item: m.withTTL(logItem(e)),
				ConditionExpression: aws.String("attribute_not_exists(pk)")}},
			{Put: &types.Put{TableName: m.t("dedup"), ConditionExpression: aws.String("attribute_not_exists(pk)"),
				Item: map[string]types.AttributeValue{"pk": sv(dk), "seq": nv(seq), "ts": nv(r.TsMs),
					"msg_id": bv(e.MessageID.Bytes()), "ttl": m.ttl(dedupTTL)}}},
		}})
		if err == nil {
			return store.AppendResult{MessageID: e.MessageID, Seq: seq, TsMs: r.TsMs}, nil
		}
		if _, ok := cancelReasons(err); !ok {
			return store.AppendResult{}, err
		}
		// Tranh chấp head_seq/epoch hoặc dedup: nghỉ ngẫu nhiên rồi đọc lại.
		if err := backoff(ctx, try); err != nil {
			return store.AppendResult{}, err
		}
	}
	return store.AppendResult{}, errors.New("dynamo: quá số lần thử cấp seq")
}

func (m *Mailbox) AppendCommit(ctx context.Context, r store.CommitReq) (store.CommitResult, error) {
	ik := r.ConvID.Hex() + "#" + r.IdemKey
	for try := 0; try < maxTxRetries; try++ {
		if r.IdemKey != "" {
			d, err := m.db.GetItem(ctx, &dynamodb.GetItemInput{TableName: m.t("idem"), ConsistentRead: aws.Bool(true),
				Key: map[string]types.AttributeValue{"pk": sv(ik)}})
			if err != nil {
				return store.CommitResult{}, err
			}
			if d.Item != nil {
				return store.CommitResult{Seq: getN(d.Item, "seq"), NewEpoch: getN(d.Item, "epoch"), Duplicate: true}, nil
			}
		}
		h, err := m.GetHead(ctx, r.ConvID)
		if err != nil {
			return store.CommitResult{}, err
		}
		if r.ExpectedEpoch != h.Epoch {
			return store.CommitResult{}, &store.EpochError{Current: h.Epoch}
		}
		seq, newEp := h.HeadSeq+1, h.Epoch+1
		fo := r.Fanout
		fo.NewEpoch = newEp
		e := store.Entry{ConvID: r.ConvID, Seq: seq, Kind: chatv1.EntryKind_ENTRY_KIND_COMMIT, Sender: r.Sender,
			Epoch: h.Epoch, Ciphertext: r.Ciphertext, TsMs: r.TsMs, MessageID: ids.New(), Pending: &fo}
		items := []types.TransactWriteItem{
			{Update: &types.Update{TableName: m.t("conv_head"), Key: map[string]types.AttributeValue{"pk": sv(r.ConvID.Hex())},
				UpdateExpression:    aws.String("SET head_seq = :n, epoch = :ne"),
				ConditionExpression: aws.String("head_seq = :h AND epoch = :e"),
				ExpressionAttributeValues: map[string]types.AttributeValue{
					":n": nv(seq), ":ne": nv(newEp), ":h": nv(h.HeadSeq), ":e": nv(h.Epoch)}}},
			{Put: &types.Put{TableName: m.t("conv_log"), Item: m.withTTL(logItem(e)),
				ConditionExpression: aws.String("attribute_not_exists(pk)")}},
		}
		if r.IdemKey != "" {
			items = append(items, types.TransactWriteItem{Put: &types.Put{TableName: m.t("idem"),
				ConditionExpression: aws.String("attribute_not_exists(pk)"),
				Item:                map[string]types.AttributeValue{"pk": sv(ik), "seq": nv(seq), "epoch": nv(newEp), "ttl": m.ttl(dedupTTL)}}})
		}
		items = append(items, m.welcomePuts(e, r.Welcomes)...)
		if _, err = m.db.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{TransactItems: items}); err == nil {
			return store.CommitResult{Seq: seq, NewEpoch: newEp}, nil
		}
		if _, ok := cancelReasons(err); !ok {
			return store.CommitResult{}, err
		}
		if err := backoff(ctx, try); err != nil {
			return store.CommitResult{}, err
		}
	}
	return store.CommitResult{}, errors.New("dynamo: quá số lần thử Commit")
}

func (m *Mailbox) GetEntry(ctx context.Context, conv ids.ID, seq uint64) (store.Entry, error) {
	out, err := m.db.GetItem(ctx, &dynamodb.GetItemInput{TableName: m.t("conv_log"), ConsistentRead: aws.Bool(true), Key: logKey(conv, seq)})
	if err != nil {
		return store.Entry{}, err
	}
	if out.Item == nil {
		return store.Entry{}, store.ErrNotFound
	}
	return parseEntry(out.Item)
}

func (m *Mailbox) GetLog(ctx context.Context, conv ids.ID, after uint64, limit int) ([]store.Entry, error) {
	h, err := m.GetHead(ctx, conv)
	if err != nil {
		return nil, err
	}
	var out []store.Entry
	for b := (after + 1) / bucketSize; b <= h.HeadSeq/bucketSize && len(out) < limit; b++ {
		qo, err := m.db.Query(ctx, &dynamodb.QueryInput{TableName: m.t("conv_log"), ConsistentRead: aws.Bool(true),
			KeyConditionExpression: aws.String("pk = :p AND seq > :a"), Limit: aws.Int32(int32(limit - len(out))),
			ExpressionAttributeValues: map[string]types.AttributeValue{
				":p": sv(conv.Hex() + "#" + strconv.FormatUint(b, 10)), ":a": nv(after)}})
		if err != nil {
			return nil, err
		}
		for _, it := range qo.Items {
			e, err := parseEntry(it)
			if err != nil {
				return nil, err
			}
			out = append(out, e)
		}
	}
	return out, nil
}

func (m *Mailbox) PutPointers(ctx context.Context, e store.Entry, devices []ids.ID) error {
	id := ids.InboxID(e.TsMs, e.ConvID, e.Seq)
	reqs := make([]types.WriteRequest, 0, len(devices))
	for _, d := range devices {
		it := inboxItem(d, id, e.ConvID, e.Seq, e.Kind, e.Sender, e.Epoch, nil, e.TsMs)
		it["ttl"] = m.ttl(logTTL)
		reqs = append(reqs, types.WriteRequest{PutRequest: &types.PutRequest{Item: it}})
	}
	return m.batchWrite(ctx, reqs)
}

func (m *Mailbox) batchWrite(ctx context.Context, reqs []types.WriteRequest) error {
	for len(reqs) > 0 {
		n := min(25, len(reqs))
		pending := map[string][]types.WriteRequest{*m.t("device_inbox"): reqs[:n]}
		reqs = reqs[n:]
		for attempt := 0; len(pending) > 0; attempt++ {
			if attempt > 8 {
				return errors.New("dynamo: BatchWriteItem còn mục chưa ghi")
			}
			out, err := m.db.BatchWriteItem(ctx, &dynamodb.BatchWriteItemInput{RequestItems: pending})
			if err != nil {
				return err
			}
			pending = out.UnprocessedItems
			if len(pending) > 0 {
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(time.Duration(10<<attempt) * time.Millisecond):
				}
			}
		}
	}
	return nil
}

func (m *Mailbox) CompleteFanout(ctx context.Context, conv ids.ID, seq uint64) error {
	_, err := m.db.UpdateItem(ctx, &dynamodb.UpdateItemInput{TableName: m.t("conv_log"), Key: logKey(conv, seq),
		UpdateExpression: aws.String("REMOVE pending"), ConditionExpression: aws.String("attribute_exists(pk)")})
	var cc *types.ConditionalCheckFailedException
	if errors.As(err, &cc) { // log đã hết TTL: không còn gì để hoàn tất
		return nil
	}
	return err
}

// PendingFanouts quét conv_log tìm mục còn pending. Đủ cho giai đoạn tối thiểu;
// khi lớn lên thêm GSI thưa (chỉ có item pending) để thay Scan.
func (m *Mailbox) PendingFanouts(ctx context.Context, limit int) ([]store.Entry, error) {
	var out []store.Entry
	var start map[string]types.AttributeValue
	for len(out) < limit {
		so, err := m.db.Scan(ctx, &dynamodb.ScanInput{TableName: m.t("conv_log"), ExclusiveStartKey: start,
			FilterExpression: aws.String("attribute_exists(pending)"), ConsistentRead: aws.Bool(true)})
		if err != nil {
			return nil, err
		}
		for _, it := range so.Items {
			e, err := parseEntry(it)
			if err != nil {
				return nil, err
			}
			if out = append(out, e); len(out) == limit {
				break
			}
		}
		if so.LastEvaluatedKey == nil {
			break
		}
		start = so.LastEvaluatedKey
	}
	return out, nil
}

func (m *Mailbox) GetInboxItem(ctx context.Context, d, id ids.ID) (store.InboxItem, error) {
	out, err := m.db.GetItem(ctx, &dynamodb.GetItemInput{TableName: m.t("device_inbox"), ConsistentRead: aws.Bool(true),
		Key: map[string]types.AttributeValue{"pk": bv(d.Bytes()), "sk": bv(id.Bytes())}})
	if err != nil {
		return store.InboxItem{}, err
	}
	if out.Item == nil {
		return store.InboxItem{}, store.ErrNotFound
	}
	return parseInbox(out.Item), nil
}

func (m *Mailbox) ListInbox(ctx context.Context, d, after ids.ID, limit int) ([]store.InboxItem, error) {
	qo, err := m.db.Query(ctx, &dynamodb.QueryInput{TableName: m.t("device_inbox"), ConsistentRead: aws.Bool(true),
		KeyConditionExpression: aws.String("pk = :p AND sk > :a"), Limit: aws.Int32(int32(limit)),
		ExpressionAttributeValues: map[string]types.AttributeValue{":p": bv(d.Bytes()), ":a": bv(after.Bytes())}})
	if err != nil {
		return nil, err
	}
	out := make([]store.InboxItem, 0, len(qo.Items))
	for _, it := range qo.Items {
		out = append(out, parseInbox(it))
	}
	return out, nil
}

func (m *Mailbox) DeleteInbox(ctx context.Context, d ids.ID, inboxIDs []ids.ID) error {
	reqs := make([]types.WriteRequest, 0, len(inboxIDs))
	for _, id := range inboxIDs {
		reqs = append(reqs, types.WriteRequest{DeleteRequest: &types.DeleteRequest{
			Key: map[string]types.AttributeValue{"pk": bv(d.Bytes()), "sk": bv(id.Bytes())}}})
	}
	return m.batchWrite(ctx, reqs)
}
