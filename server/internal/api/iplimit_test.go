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

// Khóa theo thiết bị (UUID, không có cổng): mỗi thiết bị có hạn mức riêng cho FetchKeyPackages.
func TestFetchKeyPackagesLimitPerDevice(t *testing.T) {
	var l ipLimiter
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	a, b := "0b1f6a52-0000-4000-8000-000000000001", "0b1f6a52-0000-4000-8000-000000000002"
	for i := 0; i < FetchKeyPackagesPerMinute; i++ {
		if ok, _ := l.allow(a, FetchKeyPackagesPerMinute, time.Minute, now); !ok {
			t.Fatalf("lần %d phải được", i)
		}
	}
	if ok, wait := l.allow(a, FetchKeyPackagesPerMinute, time.Minute, now.Add(time.Second)); ok || wait <= 0 {
		t.Fatalf("vượt hạn mức phải bị chặn: ok=%v wait=%v", ok, wait)
	}
	if ok, _ := l.allow(b, FetchKeyPackagesPerMinute, time.Minute, now.Add(time.Second)); !ok {
		t.Fatal("thiết bị khác không bị ảnh hưởng")
	}
}
