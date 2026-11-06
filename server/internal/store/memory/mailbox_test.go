package memory_test

import (
	"testing"

	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store/memory"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store/storetest"
)

func TestMailboxContract(t *testing.T) {
	storetest.RunMailbox(t, func(testing.TB) store.MailboxStore { return memory.NewMailbox() })
}
