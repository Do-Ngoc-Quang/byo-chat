//! Liên kết thiết bị mới (giao-thuc.md 6.5, ADR 0010): sealed_bundle HPKE, credential, rồi vào nhóm bằng External Commit.
use chatcore::api::{pack, unpack, Core};
use chatcore::credential::Credential;

fn call(c: &mut Core, op: &str, args: &[&[u8]]) -> Vec<Vec<u8>> {
    unpack(&c.call(op, &pack(args)).unwrap()).unwrap()
}

fn open_pending(device_id: &[u8; 16]) -> Core {
    // account_id rỗng = thiết bị mới chờ liên kết
    Core::open_device(&pack(&[&[], device_id, &[], &1u64.to_le_bytes()])).unwrap()
}

#[test]
fn lien_ket_thiet_bi_roi_vao_nhom_bang_external_commit() {
    let mut a1 = Core::new_device(&[1; 16], &[10; 16], None, 1).unwrap();
    let mut b1 = Core::new_device(&[2; 16], &[20; 16], None, 1).unwrap();
    let kp = call(&mut b1, "key_packages", &[&1u32.to_le_bytes()]).remove(0);
    call(&mut a1, "create_group", &[b"g"]);
    let out = call(&mut a1, "add_members", &[b"g", &kp]);
    call(&mut b1, "join_welcome", &[b"g", &out[1]]);

    // A3: thiết bị mới, chưa có tài khoản; chưa làm được gì cần credential.
    let mut a3 = open_pending(&[30; 16]);
    assert!(a3.call("credential", &pack(&[])).is_err());
    let start = call(&mut a3, "link_start", &[]);
    let link_id = [7u8; 16];

    // A1 duyệt: credential cho A3 + sealed_bundle.
    let ap = call(&mut a1, "link_approve", &[&link_id, &[30; 16], &start[0], &start[1], &5u64.to_le_bytes()]);
    let c = Credential::parse(&ap[0]).unwrap();
    assert_eq!((c.account_id, c.device_id), ([1; 16], [30; 16]));

    // link_id sai (aad) hoặc thiết bị khác không mở được gói.
    assert!(a3.call("link_finish", &pack(&[&[8u8; 16], &ap[0], &ap[1]])).is_err());
    let mut other = open_pending(&[30; 16]);
    call(&mut other, "link_start", &[]);
    assert!(other.call("link_finish", &pack(&[&link_id, &ap[0], &ap[1]])).is_err());

    // credential cho thiết bị khác bị từ chối ngay cả khi gói mở được.
    let wrong = call(&mut a1, "link_approve", &[&link_id, &[31; 16], &start[0], &start[1], &5u64.to_le_bytes()]);
    assert!(a3.call("link_finish", &pack(&[&link_id, &wrong[0], &ap[1]])).is_err());

    call(&mut a3, "link_finish", &[&link_id, &ap[0], &ap[1]]);
    // Sau khi liên kết: cùng khóa danh tính, credential đúng, chạy lại link_finish không còn ý nghĩa.
    let cred = call(&mut a3, "credential", &[]);
    assert_eq!(cred[0], ap[0]);
    assert_eq!(cred[2], call(&mut a1, "credential", &[])[2], "cùng khóa danh tính tài khoản");
    assert!(a3.call("link_finish", &pack(&[&link_id, &ap[0], &ap[1]])).is_err());

    // A3 tự vào nhóm bằng External Commit; A1, B1 áp dụng; A3 và B1 nói chuyện được.
    let gi = call(&mut a1, "group_info", &[b"g"]).remove(0);
    let ext = call(&mut a3, "external_join", &[b"g", &gi]).remove(0);
    call(&mut a1, "apply_commit", &[b"g", &ext]);
    call(&mut b1, "apply_commit", &[b"g", &ext]);
    let ct = call(&mut b1, "encrypt", &[b"g", b"xin chao A3"]).remove(0);
    assert_eq!(call(&mut a3, "decrypt", &[b"g", &ct])[0], b"xin chao A3");

    // KeyPackage của A3 qua kiểm tra như thiết bị thường (credential do khóa danh tính ký).
    let kp3 = call(&mut a3, "key_packages", &[&1u32.to_le_bytes()]).remove(0);
    call(&mut b1, "verify_key_package", &[&kp3, &cred[0], &cred[2], &[1; 16]]);
}

#[test]
fn thu_hoi_thiet_bi_go_la_khoi_nhom_va_ky_statement() {
    let mut a1 = Core::new_device(&[1; 16], &[10; 16], None, 1).unwrap();
    let mut b1 = Core::new_device(&[2; 16], &[20; 16], None, 1).unwrap();
    // A3 liên kết vào tài khoản của A1 rồi cả hai cùng ở trong nhóm với B1.
    let mut a3 = open_pending(&[30; 16]);
    let st = call(&mut a3, "link_start", &[]);
    let ap = call(&mut a1, "link_approve", &[&[7u8; 16], &[30; 16], &st[0], &st[1], &5u64.to_le_bytes()]);
    call(&mut a3, "link_finish", &[&[7u8; 16], &ap[0], &ap[1]]);
    let kp3 = call(&mut a3, "key_packages", &[&1u32.to_le_bytes()]).remove(0);
    let kpb = call(&mut b1, "key_packages", &[&1u32.to_le_bytes()]).remove(0);
    call(&mut a1, "create_group", &[b"g"]);
    let out = call(&mut a1, "add_members", &[b"g", &kp3, &kpb]);
    call(&mut a3, "join_welcome", &[b"g", &out[1]]);
    call(&mut b1, "join_welcome", &[b"g", &out[1]]);

    // Statement ký đúng bố cục 88 byte; thiết bị không giữ khóa danh tính thì không ký được.
    let s = call(&mut a1, "revocation_sign", &[&[30; 16], &9u64.to_le_bytes()]).remove(0);
    assert_eq!(s.len(), 88);
    assert_eq!(&s[..16], &[30u8; 16]);
    assert!(b1.call("revocation_sign", &pack(&[&[30; 16], &9u64.to_le_bytes()])).is_ok(), "B1 giữ khóa danh tính của chính tài khoản B");
    assert!(a1.call("stage_remove_devices", &pack(&[b"g", &[99; 16]])).is_err(), "thiết bị không có trong nhóm");

    // A1 gỡ riêng A3 (thiết bị 30): A1 còn, B1 áp dụng được, A3 bị loại khỏi epoch mới.
    let rm = call(&mut a1, "stage_remove_devices", &[b"g", &[30; 16]]);
    call(&mut a1, "merge_commit", &[b"g"]);
    // Spec 6.6 bước 4: B1 chưa có statement thì không tin Commit gỡ một phần thiết bị của Alice (nhóm giữ nguyên epoch).
    let e0 = call(&mut b1, "epoch", &[b"g"]);
    let err = b1.call("apply_commit", &pack(&[b"g", &rm[0]])).unwrap_err().to_string();
    assert!(err.contains("NEED_REVOCATION:") && err.contains(&"1e".repeat(16)), "{err}");
    assert_eq!(call(&mut b1, "epoch", &[b"g"]), e0);
    // Statement ký bằng khóa khác (Bob giả mạo) bị từ chối; statement đúng của Alice thì được, rồi áp dụng được.
    let alice_pub = call(&mut a1, "credential", &[]).remove(2);
    let forged = call(&mut b1, "revocation_sign", &[&[30; 16], &9u64.to_le_bytes()]).remove(0);
    assert!(b1.call("add_revocation", &pack(&[&alice_pub, &forged])).is_err());
    assert!(b1.call("add_revocation", &pack(&[&alice_pub, &s[..87]])).is_err());
    call(&mut b1, "add_revocation", &[&alice_pub, &s]);
    call(&mut b1, "apply_commit", &[b"g", &rm[0]]);
    call(&mut a3, "apply_commit", &[b"g", &rm[0]]); // thiết bị bị gỡ không cần statement
    assert_eq!(call(&mut a3, "is_active", &[b"g"])[0], [0]);
    assert_eq!(call(&mut a1, "group_members", &[b"g"]).len(), 2);
    let ct = call(&mut a1, "encrypt", &[b"g", b"sau thu hoi"]).remove(0);
    assert_eq!(call(&mut b1, "decrypt", &[b"g", &ct])[0], b"sau thu hoi");
    assert!(a3.call("decrypt", &pack(&[b"g", &ct])).is_err());
}

#[test]
fn reset_identity_lien_ket_lai_vao_nhom_va_go_la_cu_khong_can_statement() {
    let mut a1 = Core::new_device(&[1; 16], &[10; 16], None, 1).unwrap();
    let mut b = Core::new_device(&[2; 16], &[20; 16], None, 1).unwrap();
    let kb = call(&mut b, "key_packages", &[&1u32.to_le_bytes()]).remove(0);
    call(&mut a1, "create_group", &[b"g"]);
    let out = call(&mut a1, "add_members", &[b"g", &kb]);
    call(&mut b, "join_welcome", &[b"g", &out[1]]);
    let old_pub = call(&mut a1, "credential", &[]).remove(2);

    // Alice mất hết thiết bị và không có sao lưu: máy mới sinh khóa danh tính MỚI (cùng account_id) rồi External Commit.
    let mut a9 = Core::new_device(&[1; 16], &[90; 16], None, 2).unwrap();
    let new_pub = call(&mut a9, "credential", &[]).remove(2);
    assert_ne!(old_pub, new_pub);
    let gi = call(&mut a1, "group_info", &[b"g"]).remove(0);
    let ext = call(&mut a9, "external_join", &[b"g", &gi]).remove(0);
    call(&mut b, "apply_commit", &[b"g", &ext]);
    // a1 (máy cũ đã mất) không áp dụng nữa; a9 phải thấy lá cũ của chính tài khoản mình là lá cũ.
    let stale = call(&mut a9, "stale_devices", &[b"g"]);
    assert_eq!(stale, vec![vec![10u8; 16]], "chỉ lá cũ (device 10) là lá cũ, không phải chính a9");

    // a9 gỡ lá cũ. Bob chưa tin khóa mới nên chặn (cần statement); sau khi biết khóa danh tính mới thì chấp nhận.
    let rm = call(&mut a9, "stage_remove_devices", &[b"g", &[10; 16]]);
    call(&mut a9, "merge_commit", &[b"g"]);
    let err = b.call("apply_commit", &pack(&[b"g", &rm[0]])).unwrap_err().to_string();
    assert!(err.contains("NEED_REVOCATION:"), "{err}");
    let n = call(&mut b, "trust_identity", &[&[1u8; 16], &new_pub]).remove(0);
    assert_eq!(n, 1u32.to_le_bytes(), "đánh dấu đúng một lá cũ");
    call(&mut b, "apply_commit", &[b"g", &rm[0]]);
    // Khóa danh tính cũ không làm lá cũ thành "cũ": lá của a9 khớp khóa mới nên không bị đánh dấu.
    assert_eq!(call(&mut b, "trust_identity", &[&[1u8; 16], &new_pub]).remove(0), 0u32.to_le_bytes());
    let ct = call(&mut a9, "encrypt", &[b"g", b"sau reset"]).remove(0);
    assert_eq!(call(&mut b, "decrypt", &[b"g", &ct])[0], b"sau reset");
    assert!(call(&mut a9, "stale_devices", &[b"g"]).is_empty());
}
