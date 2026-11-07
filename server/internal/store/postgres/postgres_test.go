package postgres_test

import (
	"context"
	"fmt"
	"os"
	"sync/atomic"
	"testing"

	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
	"byo-chat/server/internal/store/postgres"
	"byo-chat/server/internal/store/storetest"
	"github.com/jackc/pgx/v5/pgxpool"
)

var n atomic.Int64

// Cần PostgreSQL: TEST_POSTGRES_DSN='postgres://postgres@localhost:5432/chat_test?sslmode=disable'
// Mỗi test dùng một schema riêng nên chạy song song được.
func newStore(t testing.TB) (*postgres.Store, *pgxpool.Pool) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("đặt TEST_POSTGRES_DSN để chạy test PostgreSQL")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("t%d_%d", os.Getpid(), n.Add(1))
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	cfg, _ := pgxpool.ParseConfig(dsn)
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		pool.Close()
		admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE")
		admin.Close()
	})
	if err := postgres.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	return postgres.New(pool), pool
}

func TestMetaContract(t *testing.T) {
	storetest.RunMeta(t, func(tb testing.TB) storetest.MetaHarness {
		s, _ := newStore(tb)
		ctx := context.Background()
		return storetest.MetaHarness{Meta: s,
			Add:    func(d store.DeviceInfo) { must(tb, s.AddDevice(ctx, d)) },
			Revoke: func(id ids.ID) { must(tb, s.RevokeDevice(ctx, id)) }}
	})
}

func must(t testing.TB, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestMigrateIdempotent(t *testing.T) {
	_, pool := newStore(t)
	ctx := context.Background()
	if err := postgres.Migrate(ctx, pool); err != nil { // lần hai không làm gì
		t.Fatal(err)
	}
	for _, tbl := range []string{"device_links", "revocations", "members_by_conv", "group_info", "key_packages"} {
		var ok bool
		if err := pool.QueryRow(ctx, `SELECT to_regclass($1) IS NOT NULL`, tbl).Scan(&ok); err != nil || !ok {
			t.Fatalf("thiếu bảng %s (%v)", tbl, err)
		}
	}
}

func TestAccountContract(t *testing.T) {
	storetest.RunAccount(t, func(tb testing.TB) (store.AccountStore, store.MetaStore) {
		s, _ := newStore(tb)
		return s, s
	})
}
