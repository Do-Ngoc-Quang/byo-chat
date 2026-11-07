//! Hỗ trợ chat: đệm 256 byte, thành viên nhóm, đổi tên/bỏ nhóm, app_state đi cùng snapshot.
use chatcore::api::{pack, unpack, Core};
use chatcore::credential::Credential;

fn call(c: &mut Core, op: &str, args: &[&[u8]]) -> Vec<Vec<u8>> {
    unpack(&c.call(op, &pack(args)).unwrap()).unwrap()
}

fn pair() -> (Core, Core) {
    let mut a = Core::new_device(&[1; 16], &[10; 16], None, 1).unwrap();
    let mut b = Core::new_device(&[2; 16], &[20; 16], None, 1).unwrap();
    let kp = call(&mut b, "key_packages", &[&1u32.to_le_bytes()]).remove(0);
    call(&mut a, "create_group", &[b"g"]);
    let out = call(&mut a, "add_members", &[b"g", &kp]);
    call(&mut b, "join_welcome", &[b"g", &out[1]]);
    (a, b)
}

#[test]
fn ciphertext_duoc_dem_theo_boi_so_256() {
    let (mut a, _b) = pair();
    let len = |c: &mut Core, pt: &[u8]| call(c, "encrypt", &[b"g", pt]).remove(0).len();
    // MLS đệm cả phần khung và chữ ký (khoảng 70 byte) vào bội số của 256, nên bậc đầu chứa nội dung tới ~180 byte.
    let (l1, l2, l3) = (len(&mut a, b"a"), len(&mut a, &[b'x'; 100]), len(&mut a, &[b'y'; 150]));
    assert_eq!(l1, l2, "tin ngắn và tin 100 byte phải cùng kích thước sau khi đệm");
    assert_eq!(l1, l3);
    let l4 = len(&mut a, &[b'z'; 400]);
    assert_eq!(l4 - l1, 256, "vượt một bậc thì tăng đúng 256 byte");
}

#[test]
fn group_members_tra_credential_tung_la() {
    let (mut a, _b) = pair();
    let members = call(&mut a, "group_members", &[b"g"]);
    assert_eq!(members.len(), 2);
    let mut accts: Vec<[u8; 16]> = members.iter().map(|m| Credential::parse(m).unwrap().account_id).collect();
    accts.sort();
    assert_eq!(accts, vec![[1; 16], [2; 16]]);
    assert!(a.call("group_members", &pack(&[b"khong"])).is_err());
}

#[test]
fn doi_ten_va_bo_nhom() {
    let (mut a, mut b) = pair();
    call(&mut a, "rename_group", &[b"g", b"conv-1"]);
    assert!(a.call("epoch", &pack(&[b"g"])).is_err());
    let ct = call(&mut a, "encrypt", &[b"conv-1", b"hi"]).remove(0);
    call(&mut b, "rename_group", &[b"g", b"conv-1"]);
    assert_eq!(call(&mut b, "decrypt", &[b"conv-1", &ct])[0], b"hi");
    assert!(a.call("rename_group", &pack(&[b"conv-1", b"conv-1"])).is_err(), "đích trùng");
    assert!(a.call("rename_group", &pack(&[b"khong", b"x"])).is_err());

    call(&mut a, "drop_group", &[b"conv-1"]);
    assert!(a.call("epoch", &pack(&[b"conv-1"])).is_err());
    assert!(a.call("drop_group", &pack(&[b"conv-1"])).is_err());
    // bỏ nhóm rồi tạo lại cùng khóa được, và khôi phục snapshot không mang nhóm đã bỏ
    call(&mut a, "create_group", &[b"conv-1"]);
    let sealed = call(&mut a, "snapshot", &[&[7u8; 32]]).remove(0);
    let mut r = Core::restore_sealed(&sealed, &[7u8; 32]).unwrap();
    assert_eq!(call(&mut r, "epoch", &[b"conv-1"])[0], 0u64.to_le_bytes());
}

#[test]
fn app_state_di_cung_snapshot() {
    let (mut a, _b) = pair();
    assert_eq!(call(&mut a, "app_state_get", &[]).remove(0), Vec::<u8>::new());
    let doc = vec![9u8; 5000];
    call(&mut a, "app_state_set", &[&doc]);
    let sealed = call(&mut a, "snapshot", &[&[7u8; 32]]).remove(0);
    let mut r = Core::restore_sealed(&sealed, &[7u8; 32]).unwrap();
    assert_eq!(call(&mut r, "app_state_get", &[]).remove(0), doc);
    // trạng thái MLS và app_state cùng một lần ghi: nhóm vẫn đó
    assert_eq!(call(&mut r, "epoch", &[b"g"])[0], call(&mut a, "epoch", &[b"g"])[0]);
}

#[test]
fn nhom_3_nguoi_them_va_go_tai_khoan() {
    let (mut a, mut b) = pair();
    // Carol có hai thiết bị cùng tài khoản; Alice thêm cả hai bằng một Commit.
    let mut c1 = Core::new_device(&[3; 16], &[30; 16], None, 1).unwrap();
    let mut c2 = Core::new_device(&[3; 16], &[31; 16], Some(&call(&mut c1, "identity_export", &[])[0]), 1).unwrap();
    let kp1 = call(&mut c1, "key_packages", &[&1u32.to_le_bytes()]).remove(0);
    let kp2 = call(&mut c2, "key_packages", &[&1u32.to_le_bytes()]).remove(0);
    call(&mut a, "stage_add", &[b"g", &kp1, &kp2]);
    // Bị từ chối thì hủy: nhóm giữ nguyên epoch, rồi dựng lại và được nhận.
    call(&mut a, "clear_commit", &[b"g"]);
    assert_eq!(call(&mut a, "group_members", &[b"g"]).len(), 2);
    let add = call(&mut a, "stage_add", &[b"g", &kp1, &kp2]);
    call(&mut a, "merge_commit", &[b"g"]);
    call(&mut b, "apply_commit", &[b"g", &add[0]]);
    call(&mut c1, "join_welcome", &[b"g", &add[1]]);
    call(&mut c2, "join_welcome", &[b"g", &add[1]]);
    assert_eq!(call(&mut a, "group_members", &[b"g"]).len(), 4);

    // Alice gỡ Carol: cả hai thiết bị của Carol biến mất; Bob áp dụng được; Carol không đọc được tin mới.
    let rm = call(&mut a, "stage_remove", &[b"g", &[3u8; 16]]);
    call(&mut a, "merge_commit", &[b"g"]);
    call(&mut b, "apply_commit", &[b"g", &rm[0]]);
    assert_eq!(call(&mut a, "group_members", &[b"g"]).len(), 2);
    let ct = call(&mut a, "encrypt", &[b"g", b"sau khi go"]).remove(0);
    assert_eq!(call(&mut b, "decrypt", &[b"g", &ct])[0], b"sau khi go");
    call(&mut c1, "apply_commit", &[b"g", &rm[0]]);
    assert_eq!(call(&mut c1, "is_active", &[b"g"])[0], [0]);
    assert_eq!(call(&mut b, "is_active", &[b"g"])[0], [1]);
    assert!(c1.call("decrypt", &pack(&[b"g", &ct])).is_err());
    assert!(c2.call("decrypt", &pack(&[b"g", &ct])).is_err());

    // Gỡ tài khoản không có trong nhóm, hoặc account_id sai độ dài: lỗi.
    assert!(a.call("stage_remove", &pack(&[b"g", &[9u8; 16]])).is_err());
    assert!(a.call("stage_remove", &pack(&[b"g", b"ngan"])).is_err());
}
