//! Kiểm bề mặt byte của `api::Core`: 1-1 qua Welcome, thiết bị thứ ba vào bằng External Commit.
use chatcore::api::{pack, unpack, Core};

fn call(c: &mut Core, op: &str, args: &[&[u8]]) -> Vec<Vec<u8>> {
    unpack(&c.call(op, &pack(args)).unwrap()).unwrap()
}

#[test]
fn chat_qua_api_byte() {
    let conv = b"group-1".as_slice();
    let mut a = Core::new(b"alice-1").unwrap();
    let mut b = Core::new(b"bob-1").unwrap();
    let mut c = Core::new(b"carol-1").unwrap();

    call(&mut a, "create_group", &[conv]);
    let kp_b = call(&mut b, "key_package", &[]).remove(0);
    // Hợp đồng với server Go (`hasKeyPackageHeader`): MLSMessage v1 + key_package, rồi KeyPackage v1 + cipher suite 1.
    assert_eq!(&kp_b[..8], &[0, 1, 0, 5, 0, 1, 0, 1]);
    assert!(kp_b.len() <= 4096, "KeyPackage {} byte vượt giới hạn 4 KiB", kp_b.len());
    let out = call(&mut a, "add_members", &[conv, &kp_b]);
    call(&mut b, "join_welcome", &[conv, &out[1]]);
    assert_eq!(call(&mut a, "epoch", &[conv])[0], call(&mut b, "epoch", &[conv])[0]);

    let ct = call(&mut a, "encrypt", &[conv, b"xin chao"]).remove(0);
    assert_eq!(call(&mut b, "decrypt", &[conv, &ct])[0], b"xin chao");
    let ct = call(&mut b, "encrypt", &[conv, b"chao lai"]).remove(0);
    assert_eq!(call(&mut a, "decrypt", &[conv, &ct])[0], b"chao lai");

    // Thiết bị thứ ba tự vào bằng External Commit; A và B áp dụng Commit.
    let gi = call(&mut a, "group_info", &[conv]).remove(0);
    let commit = call(&mut c, "external_join", &[conv, &gi]).remove(0);
    call(&mut a, "apply_commit", &[conv, &commit]);
    call(&mut b, "apply_commit", &[conv, &commit]);
    let ct = call(&mut c, "encrypt", &[conv, b"ba nguoi"]).remove(0);
    assert_eq!(call(&mut a, "decrypt", &[conv, &ct])[0], b"ba nguoi");
    assert_eq!(call(&mut b, "decrypt", &[conv, &ct])[0], b"ba nguoi");
    let k_a = call(&mut a, "sframe_key", &[conv, b"call-1"]).remove(0);
    let k_c = call(&mut c, "sframe_key", &[conv, b"call-1"]).remove(0);
    assert_eq!(k_a, k_c);
    assert_eq!(k_a.len(), 32);
}

#[test]
fn loi_duoc_bao_thay_vi_panic() {
    let mut a = Core::new(b"alice-1").unwrap();
    assert!(a.call("khong-co", &pack(&[])).is_err());
    assert!(a.call("epoch", &pack(&[b"x"])).is_err()); // nhóm chưa có
    assert!(a.call("encrypt", &pack(&[b"x"])).is_err()); // thiếu đối số
    assert!(a.call("epoch", &[1, 0]).is_err()); // gói cắt cụt
    call(&mut a, "create_group", &[b"g"]);
    assert!(a.call("add_members", &pack(&[b"g", b"rac"])).is_err()); // KeyPackage rác
    assert!(a.call("create_group", &pack(&[b"g"])).is_err()); // trùng
}

#[test]
fn pack_unpack_round_trip() {
    let items: [&[u8]; 3] = [b"", b"abc", &[0u8; 300]];
    let got = unpack(&pack(&items)).unwrap();
    assert_eq!(got, items.iter().map(|i| i.to_vec()).collect::<Vec<_>>());
}
