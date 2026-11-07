package memory_test

import (
	"testing"

	"byo-chat/server/internal/store"
	"byo-chat/server/internal/store/memory"
	"byo-chat/server/internal/store/storetest"
)

func TestMailboxContract(t *testing.T) {
	storetest.RunMailbox(t, func(testing.TB) store.MailboxStore { return memory.NewMailbox() })
}
