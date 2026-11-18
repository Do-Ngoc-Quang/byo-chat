//! Vòng khóa SFrame cho cuộc gọi (giao-thuc.md 6.9, thiet-ke-chinh.md mục 12). Chỉ logic khóa, không đụng media/LiveKit.
//!
//! - Khóa của epoch `e`: `Exporter(LABEL, call_id, 32)` (lấy từ `Device::sframe_key`).
//! - Chỉ số khóa (SFrame KID) = số epoch (u32). Dẫn xuất từ epoch nên thiết bị vào giữa cuộc gọi tự khớp chỉ số với mọi người,
//!   không cần phối hợp thêm.
//! - Bên nhận: khóa mới nhận được NGAY khi áp dụng Commit; khóa cũ giữ `KEEP_OLD_MS` (10 giây) để giải mã khung đang bay.
//! - Bên gửi: chuyển sang khóa mới sau `SWITCH_DELAY_MS` (~1 giây) kể từ khi áp dụng/gửi xong Commit, để các bên kịp có khóa.
//!   Chuyển khóa gửi chỉ đi tiến: epoch cũ hơn khóa đang gửi bị bỏ qua.
use std::collections::BTreeMap;

/// Nhãn exporter: "call" như PoC đã kiểm chứng, CLAUDE.md và thiet-ke-chinh.md mục 12 (giao-thuc.md 6.9 đã sửa cho khớp).
pub const LABEL: &str = "call";
pub const KEY_LEN: usize = 32;
pub const SWITCH_DELAY_MS: u64 = 1_000;
pub const KEEP_OLD_MS: u64 = 10_000;

pub type Key = [u8; KEY_LEN];

/// Chỉ số khóa SFrame của một epoch.
pub fn key_id(epoch: u64) -> u32 {
    epoch as u32
}

struct Entry {
    key: Key,
    /// Hết hạn nhận (ms) sau khi bị khóa mới thay thế; `None` khi còn là khóa mới nhất.
    retire_at: Option<u64>,
}

/// Vòng khóa của một cuộc gọi trên một thiết bị. Thời gian do bên gọi truyền vào (ms, đơn điệu) nên test không cần ngủ.
pub struct KeyRing {
    keys: BTreeMap<u32, Entry>,
    /// Khóa mới nhất chưa được dùng để gửi: (chỉ số, thời điểm được phép gửi).
    pending_send: Option<(u32, u64)>,
    sending: u32,
}

impl KeyRing {
    /// Vào cuộc gọi ở epoch `epoch` với khóa `key`: vừa gửi vừa nhận được ngay (không có khóa cũ để chờ).
    pub fn new(epoch: u64, key: Key) -> KeyRing {
        let id = key_id(epoch);
        let mut keys = BTreeMap::new();
        keys.insert(id, Entry { key, retire_at: None });
        KeyRing { keys, pending_send: None, sending: id }
    }

    /// Đã áp dụng Commit sang `epoch` mới với khóa `key`. Khóa cũ bị đánh dấu hết hạn sau `KEEP_OLD_MS`, khóa gửi đổi sau `SWITCH_DELAY_MS`.
    /// Trả false nếu epoch không mới hơn khóa mới nhất đang có (bỏ qua, ví dụ áp dụng lặp).
    pub fn on_epoch(&mut self, epoch: u64, key: Key, now_ms: u64) -> bool {
        let id = key_id(epoch);
        if self.keys.keys().next_back().is_some_and(|&newest| id <= newest) {
            return false;
        }
        for e in self.keys.values_mut() {
            if e.retire_at.is_none() {
                e.retire_at = Some(now_ms + KEEP_OLD_MS);
            }
        }
        self.keys.insert(id, Entry { key, retire_at: None });
        self.pending_send = Some((id, now_ms + SWITCH_DELAY_MS));
        true
    }

    /// Khóa dùng để mã hóa khung gửi đi lúc `now_ms` (đồng thời chuyển sang khóa mới nếu đã đến hạn).
    pub fn send_key(&mut self, now_ms: u64) -> (u32, Key) {
        if let Some((id, at)) = self.pending_send {
            if now_ms >= at {
                self.sending = id;
                self.pending_send = None;
            }
        }
        self.expire(now_ms);
        let id = self.sending;
        (id, self.keys[&id].key)
    }

    /// Khóa giải mã khung mang chỉ số `id`; `None` nếu chưa từng có hoặc đã hết hạn (khung bị bỏ).
    pub fn recv_key(&mut self, id: u32, now_ms: u64) -> Option<Key> {
        self.expire(now_ms);
        self.keys.get(&id).map(|e| e.key)
    }

    fn expire(&mut self, now_ms: u64) {
        let sending = self.sending;
        self.keys.retain(|id, e| *id == sending || e.retire_at.is_none_or(|t| now_ms < t));
    }

    /// Số khóa đang giữ (để test).
    pub fn len(&self) -> usize {
        self.keys.len()
    }
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn k(b: u8) -> Key {
        [b; KEY_LEN]
    }

    #[test]
    fn vao_cuoc_goi_gui_va_nhan_ngay() {
        let mut r = KeyRing::new(5, k(1));
        assert_eq!(r.send_key(0), (5, k(1)));
        assert_eq!(r.recv_key(5, 0), Some(k(1)));
        assert_eq!(r.recv_key(4, 0), None);
    }

    #[test]
    fn nhan_khoa_moi_ngay_gui_sau_mot_giay_giu_khoa_cu_muoi_giay() {
        let mut r = KeyRing::new(5, k(1));
        assert!(r.on_epoch(6, k(2), 1_000));
        // Nhận cả hai ngay; gửi vẫn khóa cũ tới khi đủ 1 giây.
        assert_eq!(r.recv_key(6, 1_000), Some(k(2)));
        assert_eq!(r.recv_key(5, 1_000), Some(k(1)));
        assert_eq!(r.send_key(1_999).0, 5);
        assert_eq!(r.send_key(2_000), (6, k(2)));
        // Khóa cũ còn nhận được tới 10 giây sau khi bị thay (mốc 11_000), rồi bị bỏ.
        assert_eq!(r.recv_key(5, 10_999), Some(k(1)));
        assert_eq!(r.recv_key(5, 11_000), None);
        assert_eq!(r.recv_key(6, 11_000), Some(k(2)));
        assert_eq!(r.len(), 1);
    }

    #[test]
    fn khong_mat_tieng_khi_doi_khoa_lien_tiep() {
        let mut r = KeyRing::new(1, k(1));
        r.on_epoch(2, k(2), 100);
        r.on_epoch(3, k(3), 600); // đổi khóa tiếp trước khi kịp chuyển gửi sang khóa 2
        assert_eq!(r.send_key(700).0, 1, "chưa tới hạn chuyển sang khóa 3");
        for id in 1..=3 {
            assert!(r.recv_key(id, 700).is_some(), "khung mang khóa {id} vẫn giải mã được");
        }
        assert_eq!(r.send_key(1_600).0, 3, "nhảy thẳng sang khóa mới nhất");
        // Khóa 1 không còn được gửi nên hết hạn theo hạn của nó; khóa 2 hết hạn sau khi bị khóa 3 thay.
        assert!(r.recv_key(1, 10_100).is_none());
        assert!(r.recv_key(2, 10_599).is_some());
        assert!(r.recv_key(2, 10_600).is_none());
    }

    #[test]
    fn bo_qua_epoch_cu_hoac_lap() {
        let mut r = KeyRing::new(5, k(1));
        assert!(!r.on_epoch(5, k(9), 0));
        assert!(!r.on_epoch(4, k(9), 0));
        assert_eq!(r.recv_key(5, 0), Some(k(1)));
        assert_eq!(r.len(), 1);
    }

    #[test]
    fn khoa_dang_gui_khong_bi_het_han() {
        // Gửi chậm hơn 10 giây sau khi có khóa mới (không gọi send_key): khóa đang gửi không bị xóa.
        let mut r = KeyRing::new(1, k(1));
        r.on_epoch(2, k(2), 0);
        assert!(r.recv_key(1, 60_000).is_some() || r.recv_key(2, 60_000).is_some());
        assert_eq!(r.send_key(60_000).0, 2);
    }
}
