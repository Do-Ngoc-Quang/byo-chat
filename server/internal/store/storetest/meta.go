package storetest

import (
	"context"
	"testing"

	chatv1 "github.com/Do-Ngoc-Quang/byo-chat/server/gen/chat/v1"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/ids"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store"
)

// MetaHarness gom MetaStore với hai thao tác chuẩn bị dữ liệu (đăng ký thiết bị chưa có RPC).
type MetaHarness struct {
	Meta   store.MetaStore
	Add    func(store.DeviceInfo)
	Revoke func(ids.ID)
}

func mem(a ids.ID, r chatv1.Role) *chatv1.Member {
	return &chatv1.Member{AccountId: a.Bytes(), Role: r}
}

// RunMeta chạy hợp đồng MetaStore.
func RunMeta(t *testing.T, mk func(testing.TB) MetaHarness) {
	ctx := context.Background()
	alice, bob, carol := ids.New(), ids.New(), ids.New()

	t.Run("DevicesAndRevoke", func(t *testing.T) {
		h := mk(t)
		a1, a2, b1 := store.DeviceInfo{DeviceID: ids.New(), AccountID: alice, Platform: chatv1.Platform_PLATFORM_ANDROID},
			store.DeviceInfo{DeviceID: ids.New(), AccountID: alice, Platform: chatv1.Platform_PLATFORM_WEB},
			store.DeviceInfo{DeviceID: ids.New(), AccountID: bob}
		h.Add(a1)
		h.Add(a2)
		h.Add(b1)
		got, err := h.Meta.GetDevice(ctx, a1.DeviceID)
		if err != nil || got.AccountID != alice || got.Revoked || got.Platform != chatv1.Platform_PLATFORM_ANDROID {
			t.Fatalf("%+v %v", got, err)
		}
		if _, err := h.Meta.GetDevice(ctx, ids.New()); err != store.ErrNotFound {
			t.Fatalf("muốn ErrNotFound, nhận %v", err)
		}
		devs, err := h.Meta.DevicesOfAccounts(ctx, []ids.ID{alice})
		if err != nil || len(devs) != 2 {
			t.Fatalf("%d thiết bị, %v", len(devs), err)
		}
		h.Revoke(a2.DeviceID)
		devs, _ = h.Meta.DevicesOfAccounts(ctx, []ids.ID{alice, bob})
		if len(devs) != 2 { // a1, b1; a2 đã thu hồi
			t.Fatalf("sau thu hồi còn %d thiết bị", len(devs))
		}
		if g, _ := h.Meta.GetDevice(ctx, a2.DeviceID); !g.Revoked {
			t.Fatal("GetDevice phải báo Revoked")
		}
	})

	t.Run("DirectOncePerPair", func(t *testing.T) {
		h := mk(t)
		g1, g2 := make([]byte, 32), make([]byte, 32)
		g1[0], g2[0] = 1, 2
		m := []*chatv1.Member{mem(alice, chatv1.Role_ROLE_MEMBER), mem(bob, chatv1.Role_ROLE_MEMBER)}
		c1 := ids.New()
		got, existed, err := h.Meta.CreateConversation(ctx, c1, chatv1.ConvKind_CONV_KIND_DIRECT, g1, m)
		if err != nil || existed || got != c1 {
			t.Fatalf("%v %v %v", got, existed, err)
		}
		// Cùng group_id gửi lại: trả conv_id đã cấp, không phải "existed".
		got, existed, err = h.Meta.CreateConversation(ctx, ids.New(), chatv1.ConvKind_CONV_KIND_DIRECT, g1, m)
		if err != nil || existed || got != c1 {
			t.Fatalf("gửi lại: %v %v %v", got, existed, err)
		}
		// Nhóm MLS khác, cùng cặp (thứ tự ngược): existed.
		rev := []*chatv1.Member{m[1], m[0]}
		got, existed, err = h.Meta.CreateConversation(ctx, ids.New(), chatv1.ConvKind_CONV_KIND_DIRECT, g2, rev)
		if err != nil || !existed || got != c1 {
			t.Fatalf("cặp trùng: %v %v %v", got, existed, err)
		}
		if k, _ := h.Meta.ConversationKind(ctx, c1); k != chatv1.ConvKind_CONV_KIND_DIRECT {
			t.Fatal(k)
		}
	})

	t.Run("MembershipLifecycle", func(t *testing.T) {
		h := mk(t)
		c := ids.New()
		g := make([]byte, 32)
		g[0] = 9
		_, _, err := h.Meta.CreateConversation(ctx, c, chatv1.ConvKind_CONV_KIND_GROUP, g,
			[]*chatv1.Member{mem(alice, chatv1.Role_ROLE_OWNER), mem(bob, chatv1.Role_ROLE_MEMBER)})
		if err != nil {
			t.Fatal(err)
		}
		if r, err := h.Meta.GetMember(ctx, c, bob); err != nil || r.Role != chatv1.Role_ROLE_MEMBER {
			t.Fatalf("%+v %v", r, err)
		}
		if _, err := h.Meta.GetMember(ctx, c, carol); err != store.ErrNotFound {
			t.Fatal(err)
		}
		// ApplyMembership idempotent.
		for i := 0; i < 2; i++ {
			if err := h.Meta.ApplyMembership(ctx, c, []*chatv1.Member{mem(carol, chatv1.Role_ROLE_MEMBER)}, nil,
				[]*chatv1.Member{mem(bob, chatv1.Role_ROLE_ADMIN)}); err != nil {
				t.Fatal(err)
			}
		}
		ms, _ := h.Meta.Members(ctx, c)
		if len(ms) != 3 {
			t.Fatalf("%d thành viên", len(ms))
		}
		if r, _ := h.Meta.GetMember(ctx, c, bob); r.Role != chatv1.Role_ROLE_ADMIN {
			t.Fatalf("vai trò Bob %v", r.Role)
		}
		if l, _ := h.Meta.ListConversations(ctx, carol); len(l) != 1 || l[0] != c {
			t.Fatalf("danh sách của Carol: %v", l)
		}
		for i := 0; i < 2; i++ {
			if err := h.Meta.ApplyMembership(ctx, c, nil, []ids.ID{carol}, nil); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := h.Meta.GetMember(ctx, c, carol); err != store.ErrNotFound {
			t.Fatal("Carol phải bị gỡ")
		}
		if l, _ := h.Meta.ListConversations(ctx, carol); len(l) != 0 {
			t.Fatalf("danh sách của Carol sau khi gỡ: %v", l)
		}
	})

	t.Run("GroupInfoNeverRegresses", func(t *testing.T) {
		h := mk(t)
		c := ids.New()
		g := make([]byte, 32)
		g[0] = 7
		h.Meta.CreateConversation(ctx, c, chatv1.ConvKind_CONV_KIND_GROUP, g, []*chatv1.Member{mem(alice, chatv1.Role_ROLE_OWNER)})
		if _, _, err := h.Meta.GetGroupInfo(ctx, c); err != store.ErrNotFound {
			t.Fatal(err)
		}
		must := func(err error) {
			t.Helper()
			if err != nil {
				t.Fatal(err)
			}
		}
		must(h.Meta.PutGroupInfo(ctx, c, 1, []byte("e1")))
		must(h.Meta.PutGroupInfo(ctx, c, 3, []byte("e3")))
		must(h.Meta.PutGroupInfo(ctx, c, 2, []byte("e2"))) // job cũ chạy trễ: không ghi đè
		must(h.Meta.PutGroupInfo(ctx, c, 3, []byte("e3")))
		ep, b, err := h.Meta.GetGroupInfo(ctx, c)
		if err != nil || ep != 3 || string(b) != "e3" {
			t.Fatalf("%d %q %v", ep, b, err)
		}
	})
}
