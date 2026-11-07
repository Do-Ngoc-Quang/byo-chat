package memory_test

import (
	"testing"

	"byo-chat/server/internal/ids"
	"byo-chat/server/internal/store"
	"byo-chat/server/internal/store/memory"
	"byo-chat/server/internal/store/storetest"
)

func TestMetaContract(t *testing.T) {
	storetest.RunMeta(t, func(testing.TB) storetest.MetaHarness {
		m := memory.NewMeta()
		return storetest.MetaHarness{Meta: m, Add: m.AddDevice, Revoke: func(id ids.ID) { m.RevokeDevice(id) }}
	})
}

var _ store.MetaStore = (*memory.Meta)(nil)
