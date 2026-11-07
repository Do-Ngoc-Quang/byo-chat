package memory_test

import (
	"testing"

	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/ids"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store/memory"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store/storetest"
)

func TestMetaContract(t *testing.T) {
	storetest.RunMeta(t, func(testing.TB) storetest.MetaHarness {
		m := memory.NewMeta()
		return storetest.MetaHarness{Meta: m, Add: m.AddDevice, Revoke: func(id ids.ID) { m.RevokeDevice(id) }}
	})
}

var _ store.MetaStore = (*memory.Meta)(nil)
