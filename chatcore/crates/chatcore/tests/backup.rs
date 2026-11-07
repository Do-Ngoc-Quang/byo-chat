//! Sao lưu/khôi phục (giao-thuc.md 6.14, ADR 0012): khóa danh tính + lịch sử, mã hóa bằng recovery key.
use chatcore::api::{pack, unpack, Core};

fn call(c: &mut Core, op: &str, args: &[&[u8]]) -> Vec<Vec<u8>> {
    unpack(&c.call(op, &pack(args)).unwrap()).unwrap()
}

#[test]
fn sao_luu_roi_khoi_phuc_tren_thiet_bi_moi() {
    let mut a1 = Core::new_device(&[1; 16], &[10; 16], None, 1).unwrap();
    call(&mut a1, "app_state_set", &[b"lich su chat"]);
    let rk = call(&mut a1, "backup_key_new", &[]).remove(0);
    assert_eq!(rk.len(), 32);
    assert_ne!(rk, call(&mut a1, "backup_key_new", &[])[0], "mỗi lần một khóa khác");
    let blob = call(&mut a1, "backup_seal", &[&rk]).remove(0);
    assert!(!blob.windows(12).any(|w| w == b"lich su chat"), "bản sao lưu không chứa bản rõ");
    assert_ne!(blob, call(&mut a1, "backup_seal", &[&rk])[0], "nonce khác nhau mỗi lần");

    // Máy mới (thiết bị khác, khóa ký mới) mở bản sao lưu bằng recovery key và dựng lại thiết bị với cùng khóa danh tính.
    let mut tmp = Core::new_device(&[9; 16], &[9; 16], None, 1).unwrap();
    let opened = call(&mut tmp, "backup_open", &[&rk, &blob]);
    assert_eq!(opened[1], b"lich su chat");
    let mut a2 = Core::new_device(&[1; 16], &[11; 16], Some(&opened[0]), 2).unwrap();
    assert_eq!(call(&mut a2, "credential", &[])[2], call(&mut a1, "credential", &[])[2], "cùng khóa danh tính tài khoản");

    // Sai khóa, dữ liệu sửa, cắt cụt, sai phiên bản đều bị từ chối.
    let bad_key = call(&mut a1, "backup_key_new", &[]).remove(0);
    assert!(tmp.call("backup_open", &pack(&[&bad_key, &blob])).is_err());
    let mut flipped = blob.clone();
    *flipped.last_mut().unwrap() ^= 1;
    assert!(tmp.call("backup_open", &pack(&[&rk, &flipped])).is_err());
    assert!(tmp.call("backup_open", &pack(&[&rk, &blob[..20]])).is_err());
    let mut v = blob.clone();
    v[0] = 9;
    assert!(tmp.call("backup_open", &pack(&[&rk, &v])).is_err());
    assert!(tmp.call("backup_open", &pack(&[&rk[..16], &blob])).is_err(), "recovery key sai độ dài");

    // Thiết bị không giữ khóa danh tính không sao lưu được.
    let mut pending = Core::open_device(&pack(&[&[], &[5; 16], &[], &1u64.to_le_bytes()])).unwrap();
    assert!(pending.call("backup_seal", &pack(&[&rk])).is_err());
}
