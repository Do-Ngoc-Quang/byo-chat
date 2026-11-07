package api

import (
	"testing"
	"time"
)

func TestIPLimiter(t *testing.T) {
	var l ipLimiter
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	for i := 0; i < 3; i++ {
		if ok, _ := l.allow("1.2.3.4:5000", 3, time.Minute, now.Add(time.Duration(i)*time.Second)); !ok {
			t.Fatalf("lần %d phải được", i)
		}
	}
	ok, wait := l.allow("1.2.3.4:6000", 3, time.Minute, now.Add(10*time.Second)) // cùng IP, khác cổng
	if ok || wait != 50*time.Second {
		t.Fatalf("lần 4 phải bị chặn, chờ 50 giây: ok=%v wait=%v", ok, wait)
	}
	if ok, _ := l.allow("5.6.7.8:1", 3, time.Minute, now.Add(10*time.Second)); !ok {
		t.Fatal("IP khác không bị ảnh hưởng")
	}
	if ok, _ := l.allow("1.2.3.4:1", 3, time.Minute, now.Add(61*time.Second)); !ok {
		t.Fatal("hết cửa sổ thì được lại")
	}
}
