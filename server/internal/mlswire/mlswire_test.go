package mlswire

import (
	"bytes"
	"testing"
)

func vec(b []byte) []byte {
	if len(b) < 64 {
		return append([]byte{byte(len(b))}, b...)
	}
	return append([]byte{0x40 | byte(len(b)>>8), byte(len(b))}, b...)
}

// build dựng MLSMessage(PublicMessage(Commit)) tối giản đúng bố cục RFC 9420.
func build(sender, content byte, path byte, credType byte, id []byte) []byte {
	m := []byte{0, 1, 0, 1}
	m = append(m, vec(bytes.Repeat([]byte{9}, 32))...) // group_id
	m = append(m, make([]byte, 8)...)                  // epoch
	m = append(m, sender)
	m = append(m, vec(nil)...) // authenticated_data
	m = append(m, content)
	m = append(m, vec([]byte{1, 2, 3})...) // proposals (bỏ qua)
	m = append(m, path)
	m = append(m, vec(bytes.Repeat([]byte{7}, 32))...) // encryption_key
	m = append(m, vec(bytes.Repeat([]byte{8}, 32))...) // signature_key
	m = append(m, 0, credType)
	m = append(m, vec(id)...)
	return append(m, 0xff, 0xff) // phần còn lại bị bỏ qua
}

func TestParseExternalCommit(t *testing.T) {
	id := bytes.Repeat([]byte{5}, 136) // dài hơn 63 byte: đi đường tiền tố 2 byte
	l, err := ParseExternalCommit(build(4, 3, 1, 1, id))
	if err != nil || !bytes.Equal(l.Identity, id) || !bytes.Equal(l.SignatureKey, bytes.Repeat([]byte{8}, 32)) {
		t.Fatalf("hợp lệ phải đọc được: %v", err)
	}
	for name, m := range map[string][]byte{
		"người gửi là thành viên": build(1, 3, 1, 1, id),
		"không phải Commit":       build(4, 1, 1, 1, id),
		"thiếu UpdatePath":        build(4, 3, 0, 1, id),
		"credential không Basic":  build(4, 3, 1, 2, id),
		"cụt":                     build(4, 3, 1, 1, id)[:40],
		"rỗng":                    nil,
	} {
		if _, err := ParseExternalCommit(m); err == nil {
			t.Errorf("%s: phải bị từ chối", name)
		}
	}
}
