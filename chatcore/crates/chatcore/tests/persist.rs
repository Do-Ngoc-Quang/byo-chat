//! Lưu bền: snapshot mã hóa, khôi phục, và mọi thứ vẫn chạy sau khi "khởi động lại" (ADR 0008).
use chatcore::api::{pack, unpack, Core};

fn call(c: &mut Core, op: &str, args: &[&[u8]]) -> Vec<Vec<u8>> {
    unpack(&c.call(op, &pack(args)).unwrap()).unwrap()
}

const KEY: [u8; 32] = [7; 32];

fn restart(c: &mut Core) -> Core {
    let sealed = call(c, "snapshot", &[&KEY]).remove(0);
    Core::restore_sealed(&sealed, &KEY).expect("khôi phục")
}

#[test]
fn khoi_dong_lai_van_chat_duoc_va_dung_lai_key_package_cu() {
    let conv = b"g1".as_slice();
    let mut a = Core::new_device(&[1; 16], &[10; 16], None, 1_700_000_000_000).unwrap();
    let mut b = Core::new_device(&[2; 16], &[20; 16], None, 1_700_000_000_000).unwrap();
    // KeyPackage sinh TRƯỚC khi "tắt app": khóa riêng của chúng phải sống sót qua snapshot.
    let kp_b = call(&mut b, "key_packages", &[&2u32.to_le_bytes()]);
    let last_b = call(&mut b, "last_resort_key_package", &[]).remove(0);
    call(&mut a, "create_group", &[conv]);
    let out = call(&mut a, "add_members", &[conv, &kp_b[0]]);

    // Cả hai tắt app rồi mở lại; B mới nhận Welcome sau khi khởi động lại.
    let mut a = restart(&mut a);
    let mut b = restart(&mut b);
    call(&mut b, "join_welcome", &[conv, &out[1]]);

    let ct = call(&mut a, "encrypt", &[conv, b"sau khi khoi dong lai"]).remove(0);
    assert_eq!(call(&mut b, "decrypt", &[conv, &ct])[0], b"sau khi khoi dong lai");
    assert_eq!(call(&mut a, "epoch", &[conv])[0], call(&mut b, "epoch", &[conv])[0]);

    // khởi động lại giữa cuộc trò chuyện: trạng thái ratchet được giữ đúng
    let ct1 = call(&mut b, "encrypt", &[conv, b"m1"]).remove(0);
    let mut b = restart(&mut b);
    let ct2 = call(&mut b, "encrypt", &[conv, b"m2"]).remove(0);
    assert_eq!(call(&mut a, "decrypt", &[conv, &ct1])[0], b"m1");
    assert_eq!(call(&mut a, "decrypt", &[conv, &ct2])[0], b"m2");

    // thiết bị thứ ba vào bằng gói last resort sinh trước khi nó tắt app; A và B áp dụng Commit sau khởi động lại
    let mut c = Core::new_device(&[3; 16], &[30; 16], None, 1).unwrap();
    let last_c = call(&mut c, "last_resort_key_package", &[]).remove(0);
    let mut c = restart(&mut c);
    let out2 = call(&mut a, "add_members", &[conv, &last_c]);
    call(&mut b, "apply_commit", &[conv, &out2[0]]);
    call(&mut c, "join_welcome", &[conv, &out2[1]]);
    let ct = call(&mut c, "encrypt", &[conv, b"ba nguoi"]).remove(0);
    assert_eq!(call(&mut a, "decrypt", &[conv, &ct])[0], b"ba nguoi");
    assert_eq!(call(&mut b, "decrypt", &[conv, &ct])[0], b"ba nguoi");
    let _ = (&kp_b[1], &last_b);
}

#[test]
fn goi_da_sinh_truoc_khi_tat_app_dung_duoc_sau_khi_mo_lai() {
    let conv = b"g2".as_slice();
    let mut a = Core::new_device(&[1; 16], &[10; 16], None, 1).unwrap();
    let mut b = Core::new_device(&[2; 16], &[20; 16], None, 1).unwrap();
    let kp_b = call(&mut b, "key_packages", &[&1u32.to_le_bytes()]).remove(0);
    let mut b = restart(&mut b); // B tắt app NGAY sau khi tải KeyPackage lên server
    call(&mut a, "create_group", &[conv]);
    let out = call(&mut a, "add_members", &[conv, &kp_b]);
    call(&mut b, "join_welcome", &[conv, &out[1]]); // cần khóa init riêng đã lưu bền
    let ct = call(&mut a, "encrypt", &[conv, b"ok"]).remove(0);
    assert_eq!(call(&mut b, "decrypt", &[conv, &ct])[0], b"ok");
}

#[test]
fn credential_va_khoa_danh_tinh_duoc_giu() {
    let mut a = Core::new_device(&[1; 16], &[10; 16], None, 5).unwrap();
    let before = call(&mut a, "credential", &[]);
    let exported = call(&mut a, "identity_export", &[]).remove(0);
    let mut a2 = restart(&mut a);
    assert_eq!(call(&mut a2, "credential", &[]), before, "credential và khóa không đổi");
    assert_eq!(call(&mut a2, "identity_export", &[]).remove(0), exported);

    // thiết bị không giữ khóa danh tính vẫn không có sau khôi phục
    let mut plain = Core::new(b"raw").unwrap();
    let mut plain = restart(&mut plain);
    assert!(plain.call("identity_export", &pack(&[])).is_err());
}

#[test]
fn sai_khoa_hong_du_lieu_va_phien_ban_deu_bi_tu_choi() {
    let mut a = Core::new_device(&[1; 16], &[10; 16], None, 5).unwrap();
    let sealed = call(&mut a, "snapshot", &[&KEY]).remove(0);
    assert!(Core::restore_sealed(&sealed, &[8; 32]).is_err(), "sai khóa");
    for i in [0usize, 5, 13, sealed.len() / 2, sealed.len() - 1] {
        let mut bad = sealed.clone();
        bad[i] ^= 1;
        assert!(Core::restore_sealed(&bad, &KEY).is_err(), "byte {i} bị sửa");
    }
    assert!(Core::restore_sealed(&sealed[..20], &KEY).is_err());
    assert!(Core::restore_sealed(&sealed, &KEY[..31]).is_err(), "khóa sai độ dài");
    assert!(a.call("snapshot", &pack(&[&KEY[..16]])).is_err());
}

#[test]
fn snapshot_khong_chua_plaintext_cua_khoa() {
    let mut a = Core::new_device(&[1; 16], &[10; 16], None, 5).unwrap();
    let id_pub = call(&mut a, "credential", &[]).remove(2);
    let exported = call(&mut a, "identity_export", &[]).remove(0);
    let sealed = call(&mut a, "snapshot", &[&KEY]).remove(0);
    let has = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
    assert!(!has(&sealed, &exported), "khóa danh tính lộ trong snapshot đã mã hóa");
    assert!(!has(&sealed, &id_pub));
    // hai lần snapshot cho kết quả khác nhau (nonce ngẫu nhiên)
    assert_ne!(sealed, call(&mut a, "snapshot", &[&KEY]).remove(0));
}

#[test]
fn nhieu_nhom_va_bridge_open_restore() {
    let mut a = Core::new_device(&[1; 16], &[10; 16], None, 5).unwrap();
    for i in 0..5u8 {
        call(&mut a, "create_group", &[&[b'g', i]]);
    }
    let sealed = call(&mut a, "snapshot", &[&KEY]).remove(0);
    let mut r = Core::open_restore(&pack(&[&sealed, &KEY])).unwrap();
    for i in 0..5u8 {
        assert_eq!(call(&mut r, "epoch", &[&[b'g', i]])[0], 0u64.to_le_bytes());
    }
    assert!(Core::open_restore(&pack(&[&sealed])).is_err());
}
