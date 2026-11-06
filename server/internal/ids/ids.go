// Package ids: định danh 16 byte (UUIDv7 / ULID) theo giao-thuc.md mục 2.
package ids

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"

	"github.com/google/uuid"
)

// ID là định danh 16 byte nhị phân (conv_id, device_id, account_id...).
type ID [16]byte

// New sinh UUIDv7 mới.
func New() ID {
	u, err := uuid.NewV7()
	if err != nil {
		panic(err) // chỉ lỗi khi hết entropy
	}
	return ID(u)
}

// FromBytes kiểm tra độ dài đúng 16 byte.
func FromBytes(b []byte) (ID, error) {
	var id ID
	if len(b) != 16 {
		return id, fmt.Errorf("id phải 16 byte, nhận %d", len(b))
	}
	copy(id[:], b)
	return id, nil
}

func (i ID) Bytes() []byte { return i[:] }
func (i ID) IsZero() bool  { return i == ID{} }
func (i ID) String() string {
	return uuid.UUID(i).String()
}

// Hex dùng làm khóa chuỗi trong kho.
func (i ID) Hex() string { return hex.EncodeToString(i[:]) }

// InboxID dựng inbox_id (ULID 16 byte) xác định theo (ts, conv, seq): ghi lại
// con trỏ nhiều lần ra cùng một khóa (idempotent), và sắp theo thời gian của
// log. Trong cùng một mili giây, cùng hội thoại sắp theo seq.
// Bố cục: ts(48 bit) | băm conv(32) | seq thấp(32) | 16 bit 0.
func InboxID(tsMs uint64, conv ID, seq uint64) ID {
	var o ID
	o[0], o[1], o[2] = byte(tsMs>>40), byte(tsMs>>32), byte(tsMs>>24)
	o[3], o[4], o[5] = byte(tsMs>>16), byte(tsMs>>8), byte(tsMs)
	binary.BigEndian.PutUint32(o[6:10], binary.BigEndian.Uint32(conv[12:16])^binary.BigEndian.Uint32(conv[8:12]))
	binary.BigEndian.PutUint32(o[10:14], uint32(seq))
	return o
}
