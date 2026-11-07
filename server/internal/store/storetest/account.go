package storetest

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	chatv1 "byo-chat/server/gen/chat/v1"
	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
)

// RunAccount chạy hợp đồng AccountStore. `meta` cùng kho với AccountStore để kiểm GetDevice.
func RunAccount(t *testing.T, mk func(testing.TB) (store.AccountStore, store.MetaStore)) {
	ctx := context.Background()
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	kp := func(b string, last bool, ttl time.Duration) store.KeyPackage {
		return store.KeyPackage{Blob: []byte(b), LastResort: last, ExpiresAt: now.Add(ttl)}
	}
	// ticket tạo tài khoản mới + ticket hợp lệ
	newAcct := func(t *testing.T, a store.AccountStore, tag string) (ids.ID, []byte) {
		acct, isNew, err := a.UpsertAccount(ctx, []byte("contact-"+tag), ids.New())
		if err != nil || !isNew {
			t.Fatalf("UpsertAccount: %v new=%v", err, isNew)
		}
		th := []byte("ticket-" + tag)
		if err := a.PutTicket(ctx, th, acct, true, now.Add(10*time.Minute)); err != nil {
			t.Fatal(err)
		}
		return acct, th
	}
	req := func(th []byte, dev ids.ID) store.RegisterDeviceReq {
		return store.RegisterDeviceReq{
			TicketHash: th, Device: dev, Platform: chatv1.Platform_PLATFORM_ANDROID, Name: "máy 1",
			PublicKey: []byte("pk"), Credential: []byte("cred-" + dev.Hex()),
			NewIdentity: []byte("identity-1"),
			KeyPackages: []store.KeyPackage{kp("a", false, time.Hour), kp("b", false, 2*time.Hour), kp("last", true, 24*time.Hour)},
			RefreshHash: []byte("r1-" + dev.Hex()), RefreshExpires: now.Add(30 * 24 * time.Hour), Now: now,
		}
	}

	t.Run("UpsertAccountIdempotent", func(t *testing.T) {
		a, _ := mk(t)
		id1, new1, _ := a.UpsertAccount(ctx, []byte("c"), ids.New())
		id2, new2, _ := a.UpsertAccount(ctx, []byte("c"), ids.New())
		if !new1 || new2 || id1 != id2 {
			t.Fatalf("%v %v %v %v", id1, new1, id2, new2)
		}
		if k, err := a.IdentityKey(ctx, id1); err != nil || len(k) != 0 {
			t.Fatalf("%q %v", k, err)
		}
		if _, err := a.IdentityKey(ctx, ids.New()); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("muốn ErrNotFound: %v", err)
		}
	})

	t.Run("AccountByContact", func(t *testing.T) {
		a, _ := mk(t)
		id, _, _ := a.UpsertAccount(ctx, []byte("c-lookup"), ids.New())
		if got, err := a.AccountByContact(ctx, []byte("c-lookup")); err != nil || got != id {
			t.Fatalf("%v %v", got, err)
		}
		if _, err := a.AccountByContact(ctx, []byte("khong-co")); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("muốn ErrNotFound: %v", err)
		}
	})

	t.Run("OTP", func(t *testing.T) {
		a, _ := mk(t)
		c1 := store.OTPChallenge{ID: ids.New(), ContactHash: []byte("h"), CodeHash: []byte("x"), CreatedAt: now, ExpiresAt: now.Add(5 * time.Minute)}
		c2 := c1
		c2.ID, c2.CreatedAt = ids.New(), now.Add(time.Minute)
		_ = a.PutOTP(ctx, c1)
		_ = a.PutOTP(ctx, c2)
		if l, err := a.LatestOTP(ctx, []byte("h")); err != nil || l.ID != c2.ID {
			t.Fatalf("latest: %+v %v", l, err)
		}
		if _, err := a.LatestOTP(ctx, []byte("khác")); !errors.Is(err, store.ErrNotFound) {
			t.Fatal(err)
		}
		// tăng đồng thời: đúng 20 lần
		var wg sync.WaitGroup
		for i := 0; i < 20; i++ {
			wg.Add(1)
			go func() { defer wg.Done(); a.IncOTPAttempts(ctx, c1.ID) }()
		}
		wg.Wait()
		if g, _ := a.GetOTP(ctx, c1.ID); g.Attempts != 20 {
			t.Fatalf("attempts=%d", g.Attempts)
		}
		_ = a.DeleteOTP(ctx, c1.ID)
		if _, err := a.GetOTP(ctx, c1.ID); !errors.Is(err, store.ErrNotFound) {
			t.Fatal(err)
		}
	})

	t.Run("RegisterDeviceOnceAndTicketSingleUse", func(t *testing.T) {
		a, m := mk(t)
		acct, th := newAcct(t, a, "1")
		dev := ids.New()
		got, err := a.RegisterDevice(ctx, req(th, dev))
		if err != nil || got != acct {
			t.Fatalf("%v %v", got, err)
		}
		d, err := m.GetDevice(ctx, dev)
		if err != nil || d.AccountID != acct || d.Revoked {
			t.Fatalf("%+v %v", d, err)
		}
		if k, _ := a.IdentityKey(ctx, acct); string(k) != "identity-1" {
			t.Fatalf("identity=%q", k)
		}
		// ticket đã dùng
		if _, err := a.RegisterDevice(ctx, req(th, ids.New())); !errors.Is(err, store.ErrTicketInvalid) {
			t.Fatalf("muốn ErrTicketInvalid: %v", err)
		}
		if _, _, err := a.TicketAccount(ctx, th, now); !errors.Is(err, store.ErrTicketInvalid) {
			t.Fatal(err)
		}
		if n, _ := a.CountKeyPackages(ctx, dev, now); n != 2 {
			t.Fatalf("còn %d gói một lần, muốn 2 (last resort không tính)", n)
		}
	})

	t.Run("TicketExpiredAndDuplicateDevice", func(t *testing.T) {
		a, _ := mk(t)
		_, th := newAcct(t, a, "2")
		r := req(th, ids.New())
		r.Now = now.Add(11 * time.Minute)
		if _, err := a.RegisterDevice(ctx, r); !errors.Is(err, store.ErrTicketInvalid) {
			t.Fatalf("hết hạn: %v", err)
		}
		// thiết bị trùng không làm cháy ticket
		dev := ids.New()
		if _, err := a.RegisterDevice(ctx, req(th, dev)); err != nil {
			t.Fatal(err)
		}
		acct2, th2 := newAcct(t, a, "3")
		_ = acct2
		if _, err := a.RegisterDevice(ctx, req(th2, dev)); !errors.Is(err, store.ErrExists) {
			t.Fatalf("muốn ErrExists: %v", err)
		}
		if _, _, err := a.TicketAccount(ctx, th2, now); err != nil {
			t.Fatalf("ticket phải còn dùng được sau khi thất bại: %v", err)
		}
	})

	t.Run("IdentityCompareAndSet", func(t *testing.T) {
		a, _ := mk(t)
		acct, th := newAcct(t, a, "4")
		if _, err := a.RegisterDevice(ctx, req(th, ids.New())); err != nil {
			t.Fatal(err)
		}
		// thiết bị thứ hai nhìn thấy khóa cũ -> được; nhìn thấy khóa khác -> từ chối
		th2 := []byte("t4b")
		_ = a.PutTicket(ctx, th2, acct, false, now.Add(time.Minute))
		bad := req(th2, ids.New())
		bad.NewIdentity, bad.ExpectIdentity = nil, []byte("sai")
		if _, err := a.RegisterDevice(ctx, bad); !errors.Is(err, store.ErrIdentityMismatch) {
			t.Fatalf("muốn ErrIdentityMismatch: %v", err)
		}
		if _, _, err := a.TicketAccount(ctx, th2, now); err != nil {
			t.Fatalf("ticket phải còn dùng được: %v", err)
		}
		ok := req(th2, ids.New())
		ok.NewIdentity, ok.ExpectIdentity = nil, []byte("identity-1")
		if _, err := a.RegisterDevice(ctx, ok); err != nil {
			t.Fatal(err)
		}
		// reset_identity: đặt khóa mới khi khóa hiện tại đúng như đã thấy
		th3 := []byte("t4c")
		_ = a.PutTicket(ctx, th3, acct, false, now.Add(time.Minute))
		rs := req(th3, ids.New())
		rs.ExpectIdentity, rs.NewIdentity = []byte("identity-1"), []byte("identity-2")
		if _, err := a.RegisterDevice(ctx, rs); err != nil {
			t.Fatal(err)
		}
		if k, _ := a.IdentityKey(ctx, acct); string(k) != "identity-2" {
			t.Fatalf("identity=%q", k)
		}
	})

	t.Run("FirstDeviceRace", func(t *testing.T) {
		a, _ := mk(t)
		acct, _ := newAcct(t, a, "5")
		var wg sync.WaitGroup
		var mu sync.Mutex
		okN := 0
		for i := 0; i < 6; i++ {
			th := []byte{'r', byte(i)}
			_ = a.PutTicket(ctx, th, acct, true, now.Add(time.Minute))
			r := req(th, ids.New())
			r.NewIdentity = []byte{'k', byte(i)} // mỗi thiết bị đòi một khóa khác nhau
			wg.Add(1)
			go func() {
				defer wg.Done()
				if _, err := a.RegisterDevice(ctx, r); err == nil {
					mu.Lock()
					okN++
					mu.Unlock()
				}
			}()
		}
		wg.Wait()
		if okN != 1 {
			t.Fatalf("%d thiết bị đầu tiên thắng, muốn đúng 1", okN)
		}
	})

	t.Run("RefreshRotation", func(t *testing.T) {
		a, _ := mk(t)
		_, th := newAcct(t, a, "6")
		dev := ids.New()
		r := req(th, dev)
		_, _ = a.RegisterDevice(ctx, r)
		exp := now.Add(time.Hour)
		if err := a.RotateRefresh(ctx, ids.New(), r.RefreshHash, []byte("n1"), exp, now); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("sai thiết bị: %v", err)
		}
		if err := a.RotateRefresh(ctx, dev, r.RefreshHash, []byte("n1"), exp, now); err != nil {
			t.Fatal(err)
		}
		if err := a.RotateRefresh(ctx, dev, r.RefreshHash, []byte("n2"), exp, now); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("token cũ phải mất hiệu lực: %v", err)
		}
		if err := a.RotateRefresh(ctx, dev, []byte("n1"), []byte("n2"), exp, exp.Add(time.Second)); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("hết hạn: %v", err)
		}
	})

	t.Run("KeyPackagesTake", func(t *testing.T) {
		a, m := mk(t)
		acct, th := newAcct(t, a, "7")
		dev := ids.New()
		_, _ = a.RegisterDevice(ctx, req(th, dev))
		// gói sắp hết hạn trước; mỗi gói một lần chỉ giao một lần
		b1, last, err := a.TakeKeyPackage(ctx, dev, now)
		if err != nil || last || string(b1) != "a" {
			t.Fatalf("%q %v %v", b1, last, err)
		}
		b2, _, _ := a.TakeKeyPackage(ctx, dev, now)
		if string(b2) != "b" {
			t.Fatalf("%q", b2)
		}
		for i := 0; i < 3; i++ { // hết gói một lần: last resort, dùng lại được
			b, last, err := a.TakeKeyPackage(ctx, dev, now)
			if err != nil || !last || string(b) != "last" {
				t.Fatalf("%q %v %v", b, last, err)
			}
		}
		if _, _, err := a.TakeKeyPackage(ctx, dev, now.Add(48*time.Hour)); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("hết hạn hết: %v", err)
		}
		_ = a.PutKeyPackages(ctx, dev, []store.KeyPackage{kp("c", false, time.Hour)})
		if n, _ := a.CountKeyPackages(ctx, dev, now); n != 1 {
			t.Fatalf("n=%d", n)
		}
		// AccountKeys
		ident, devs, revs, err := a.AccountKeys(ctx, acct)
		if err != nil || string(ident) != "identity-1" || len(devs) != 1 || devs[0].DeviceID != dev || len(revs) != 0 {
			t.Fatalf("%q %+v %v %v", ident, devs, revs, err)
		}
		if mr, ok := m.(interface{ RevokeDevice(ids.ID) }); ok {
			mr.RevokeDevice(dev)
			if _, devs, _, _ := a.AccountKeys(ctx, acct); len(devs) != 0 {
				t.Fatalf("thiết bị đã thu hồi vẫn hiện: %+v", devs)
			}
		}
		if _, _, _, err := a.AccountKeys(ctx, ids.New()); !errors.Is(err, store.ErrNotFound) {
			t.Fatal(err)
		}
	})

	t.Run("TakeConcurrentNoDuplicate", func(t *testing.T) {
		a, _ := mk(t)
		_, th := newAcct(t, a, "8")
		dev := ids.New()
		r := req(th, dev)
		r.KeyPackages = nil
		_, _ = a.RegisterDevice(ctx, r)
		var kps []store.KeyPackage
		for i := 0; i < 30; i++ {
			kps = append(kps, kp(string(rune('A'+i)), false, time.Hour))
		}
		_ = a.PutKeyPackages(ctx, dev, kps)
		var wg sync.WaitGroup
		var mu sync.Mutex
		seen := map[string]int{}
		for i := 0; i < 30; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				b, _, err := a.TakeKeyPackage(ctx, dev, now)
				if err == nil {
					mu.Lock()
					seen[string(b)]++
					mu.Unlock()
				}
			}()
		}
		wg.Wait()
		for k, n := range seen {
			if n != 1 {
				t.Fatalf("gói %s giao %d lần", k, n)
			}
		}
		if len(seen) != 30 {
			t.Fatalf("giao %d/30 gói", len(seen))
		}
	})
}
