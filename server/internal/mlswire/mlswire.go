// Package mlswire đọc đúng một thứ từ MLS wire format: credential và khóa ký của lá mới trong External Commit
// (giao-thuc.md 6.5 bước 6). External Commit là PublicMessage nên server đọc được mà không cần khóa nhóm.
// Không phải bộ phân tích MLS đầy đủ: mọi thứ khác được bỏ qua theo độ dài, lệch bố cục thì báo lỗi.
package mlswire

import (
	"encoding/binary"
	"errors"
)

var ErrMalformed = errors.New("mlswire: Commit không đúng bố cục External Commit")

const (
	wireFormatPublicMessage = 1
	senderNewMemberCommit   = 4 // enum Sender RFC 9420: member=1, external=2, new_member_proposal=3, new_member_commit=4
	contentTypeCommit       = 3
	credentialTypeBasic     = 1
)

type reader struct {
	b   []byte
	err error
}

func (r *reader) take(n int) []byte {
	if r.err != nil || n < 0 || n > len(r.b) {
		r.err = ErrMalformed
		return nil
	}
	out := r.b[:n]
	r.b = r.b[n:]
	return out
}

func (r *reader) u8() byte {
	if v := r.take(1); v != nil {
		return v[0]
	}
	return 0
}

func (r *reader) u16() uint16 {
	if v := r.take(2); v != nil {
		return binary.BigEndian.Uint16(v)
	}
	return 0
}

// vec đọc một vector có tiền tố độ dài biến thiên của MLS (RFC 9420 mục 2.1.2: 2 bit đầu cho biết 1, 2 hay 4 byte).
func (r *reader) vec() []byte {
	first := r.take(1)
	if first == nil {
		return nil
	}
	n := int(first[0] & 0x3f)
	switch first[0] >> 6 {
	case 1:
		n = n<<8 | int(r.u8())
	case 2:
		rest := r.take(3)
		if rest == nil {
			return nil
		}
		n = n<<24 | int(rest[0])<<16 | int(rest[1])<<8 | int(rest[2])
	case 3:
		r.err = ErrMalformed
		return nil
	}
	return r.take(n)
}

// ExternalLeaf là phần của lá mới trong UpdatePath của External Commit.
type ExternalLeaf struct {
	SignatureKey []byte // khóa ký công khai của lá (32 byte Ed25519)
	Identity     []byte // nội dung BasicCredential (credential 136 byte của chúng ta)
}

// ParseExternalCommit đọc MLSMessage(PublicMessage(Commit)) do thiết bị tự vào nhóm gửi. Lỗi nếu không phải
// PublicMessage, người gửi không phải new_member_commit, không phải Commit, thiếu UpdatePath hoặc credential không phải Basic.
func ParseExternalCommit(msg []byte) (ExternalLeaf, error) {
	r := &reader{b: msg}
	if r.u16() != 1 || r.u16() != wireFormatPublicMessage { // version mls10, wire_format
		return ExternalLeaf{}, ErrMalformed
	}
	r.vec()   // group_id
	r.take(8) // epoch
	if r.u8() != senderNewMemberCommit {
		return ExternalLeaf{}, ErrMalformed
	}
	r.vec() // authenticated_data
	if r.u8() != contentTypeCommit {
		return ExternalLeaf{}, ErrMalformed
	}
	r.vec()          // proposals (ExternalInit, Remove...)
	if r.u8() != 1 { // path: optional, External Commit bắt buộc có
		return ExternalLeaf{}, ErrMalformed
	}
	r.vec() // leaf_node.encryption_key
	sig := r.vec()
	if r.u16() != credentialTypeBasic {
		return ExternalLeaf{}, ErrMalformed
	}
	id := r.vec()
	if r.err != nil {
		return ExternalLeaf{}, r.err
	}
	return ExternalLeaf{SignatureKey: sig, Identity: id}, nil
}
