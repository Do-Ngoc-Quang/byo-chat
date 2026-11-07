// Package message: Message Service (SendMessage, SubmitCommit, CreateConversation, FetchLog...)
// và bộ làm nốt việc sau giao dịch (fanout). Logic nghiệp vụ nằm ở đây, gateway chỉ chuyển khung.
package message

import (
	"errors"
	"fmt"

	chatv1 "github.com/Do-Ngoc-Quang/byo-chat/server/gen/chat/v1"
	"github.com/Do-Ngoc-Quang/byo-chat/server/internal/store"
)

// Error là lỗi giao thức (giao-thuc.md mục 5), dùng chung cho WebSocket và Connect.
type Error struct {
	Code         chatv1.ErrorCode
	Msg          string
	RetryAfterMs uint32
	CurrentEpoch uint64
}

func (e *Error) Error() string { return fmt.Sprintf("%s: %s", e.Code, e.Msg) }

// Proto chuyển sang message Error để gửi cho client.
func (e *Error) Proto() *chatv1.Error {
	return &chatv1.Error{Code: e.Code, Message: e.Msg, RetryAfterMs: e.RetryAfterMs, CurrentEpoch: e.CurrentEpoch}
}

func errf(c chatv1.ErrorCode, f string, a ...any) *Error {
	return &Error{Code: c, Msg: fmt.Sprintf(f, a...)}
}

// toErr đổi lỗi kho sang lỗi giao thức; lỗi lạ thành UNAVAILABLE (không lộ chi tiết).
func toErr(err error) *Error {
	var pe *Error
	if errors.As(err, &pe) {
		return pe
	}
	var ee *store.EpochError
	if errors.As(err, &ee) {
		return &Error{Code: chatv1.ErrorCode_ERROR_CODE_EPOCH_MISMATCH, Msg: "epoch không khớp", CurrentEpoch: ee.Current}
	}
	if errors.Is(err, store.ErrNotFound) {
		return errf(chatv1.ErrorCode_ERROR_CODE_NOT_FOUND, "không tồn tại")
	}
	return errf(chatv1.ErrorCode_ERROR_CODE_UNAVAILABLE, "lỗi nội bộ")
}
