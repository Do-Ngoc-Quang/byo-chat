package dynamo_test

import (
	"testing"

	"byo-chat/server/internal/store/storetest"
)

// Cần DynamoDB Local: TEST_DYNAMO_ENDPOINT=http://localhost:8000 go test ./internal/store/dynamo/
func TestMailboxContract(t *testing.T) {
	storetest.RunMailbox(t, storetest.NewDynamo)
}
