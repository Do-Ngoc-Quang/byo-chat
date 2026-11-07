//! Credential 136 byte, khóa danh tính, KeyPackage hàng loạt và kiểm KeyPackage (spec 6.1, 6.2).
use chatcore::api::{pack, unpack, Core};
use chatcore::credential::{Credential, CREDENTIAL_LEN};

fn call(c: &mut Core, op: &str, args: &[&[u8]]) -> Vec<Vec<u8>> {
    unpack(&c.call(op, &pack(args)).unwrap()).unwrap()
}

const ACCT: [u8; 16] = [1; 16];

fn device(acct: &[u8], dev_byte: u8, identity: Option<&[u8]>) -> Core {
    Core::new_device(acct, &[dev_byte; 16], identity, 1_700_000_000_000).unwrap()
}

#[test]
fn credential_ky_dung_va_tach_duoc() {
    let mut a = device(&ACCT, 7, None);
    let r = call(&mut a, "credential", &[]);
    let (cred, dev_pub, id_pub) = (&r[0], &r[1], &r[2]);
    assert_eq!(cred.len(), CREDENTIAL_LEN);
    let c = Credential::parse(cred).unwrap();
    assert_eq!(c.account_id, ACCT);
    assert_eq!(c.device_id, [7; 16]);
    assert_eq!(c.device_public_key.as_slice(), dev_pub.as_slice());
    assert_eq!(c.created_ms, 1_700_000_000_000);
    c.verify(id_pub).unwrap();

    // sửa bất kỳ byte nào trong 72 byte đầu thì chữ ký hỏng; khóa danh tính khác cũng hỏng
    for i in [0, 20, 40, 71] {
        let mut bad = cred.clone();
        bad[i] ^= 1;
        assert!(Credential::parse(&bad).unwrap().verify(id_pub).is_err(), "byte {i}");
    }
    let other = device(&ACCT, 8, None);
    let mut other = other;
    let other_pub = call(&mut other, "credential", &[]).remove(2);
    assert!(c.verify(&other_pub).is_err());
    assert!(Credential::parse(&cred[..135]).is_err());
}

#[test]
fn thiet_bi_khoi_phuc_dung_chung_khoa_danh_tinh() {
    let mut a = device(&ACCT, 1, None);
    let exported = call(&mut a, "identity_export", &[]).remove(0);
    let id_pub = call(&mut a, "credential", &[]).remove(2);

    let mut b = device(&ACCT, 2, Some(&exported));
    let rb = call(&mut b, "credential", &[]);
    assert_eq!(rb[2], id_pub, "cùng khóa danh tính công khai");
    assert_ne!(rb[1], call(&mut a, "credential", &[])[1], "khóa thiết bị phải khác nhau");
    Credential::parse(&rb[0]).unwrap().verify(&id_pub).unwrap();

    assert!(Core::new_device(&ACCT, &[3; 16], Some(&exported[..10]), 1).is_err(), "khóa cắt cụt");
    assert!(Core::new_device(&[1; 15], &[3; 16], None, 1).is_err(), "account_id sai độ dài");
}

#[test]
fn key_packages_hang_loat_va_last_resort() {
    let mut a = device(&ACCT, 1, None);
    let kps = call(&mut a, "key_packages", &[&100u32.to_le_bytes()]);
    assert_eq!(kps.len(), 100);
    for k in &kps {
        assert_eq!(&k[..8], &[0, 1, 0, 5, 0, 1, 0, 1]); // khớp server (hasKeyPackageHeader)
        assert!(k.len() <= 4096, "KeyPackage {} byte", k.len());
    }
    let unique: std::collections::HashSet<_> = kps.iter().collect();
    assert_eq!(unique.len(), 100, "mỗi gói phải khác nhau (khóa init riêng)");
    let last = call(&mut a, "last_resort_key_package", &[]).remove(0);
    assert_eq!(&last[..8], &[0, 1, 0, 5, 0, 1, 0, 1]);
    assert!(last.len() <= 4096);
    assert!(a.call("key_packages", &pack(&[&201u32.to_le_bytes()])).is_err());
    assert!(a.call("key_packages", &pack(&[b"xy"])).is_err());
}

#[test]
fn kiem_key_package_nhan_tu_server() {
    let mut a = device(&ACCT, 1, None);
    let ra = call(&mut a, "credential", &[]);
    let kp = call(&mut a, "key_packages", &[&1u32.to_le_bytes()]).remove(0);
    let mut verifier = device(&[9; 16], 5, None);

    // đúng
    call(&mut verifier, "verify_key_package", &[&kp, &ra[0], &ra[2], &ACCT]);
    let bad = |v: &mut Core, kp: &[u8], cred: &[u8], idp: &[u8], acct: &[u8]| v.call("verify_key_package", &pack(&[kp, cred, idp, acct])).is_err();
    assert!(bad(&mut verifier, &kp, &ra[0], &ra[2], &[2; 16]), "sai tài khoản mong đợi");
    let mut tampered = ra[0].clone();
    tampered[40] ^= 1;
    assert!(bad(&mut verifier, &kp, &tampered, &ra[2], &ACCT), "credential bị sửa");
    let mut other = device(&ACCT, 2, None); // khác khóa danh tính
    let ro = call(&mut other, "credential", &[]);
    assert!(bad(&mut verifier, &kp, &ra[0], &ro[2], &ACCT), "khóa danh tính lạ");
    // credential hợp lệ của thiết bị khác nhưng KeyPackage của thiết bị này
    assert!(bad(&mut verifier, &kp, &ro[0], &ro[2], &ACCT), "credential không phải của KeyPackage");
    let mut garbled = kp.clone();
    let n = garbled.len();
    garbled[n - 3] ^= 0xff; // phá chữ ký gói
    assert!(bad(&mut verifier, &garbled, &ra[0], &ra[2], &ACCT), "chữ ký gói hỏng");
}

#[test]
fn nhom_mls_chay_voi_credential_that() {
    let conv = b"g1".as_slice();
    let (acct_a, acct_b) = ([1u8; 16], [2u8; 16]);
    let mut a = device(&acct_a, 1, None);
    let mut b = device(&acct_b, 2, None);
    let kp_b = call(&mut b, "key_packages", &[&1u32.to_le_bytes()]).remove(0);
    call(&mut a, "create_group", &[conv]);
    let out = call(&mut a, "add_members", &[conv, &kp_b]);
    call(&mut b, "join_welcome", &[conv, &out[1]]);
    let ct = call(&mut a, "encrypt", &[conv, b"chao"]).remove(0);
    assert_eq!(call(&mut b, "decrypt", &[conv, &ct])[0], b"chao");
    // gói last resort cũng dùng được để thêm thiết bị
    let mut c = device(&[3; 16], 3, None);
    let last = call(&mut c, "last_resort_key_package", &[]).remove(0);
    let out = call(&mut a, "add_members", &[conv, &last]);
    call(&mut b, "apply_commit", &[conv, &out[0]]);
    call(&mut c, "join_welcome", &[conv, &out[1]]);
    let ct = call(&mut c, "encrypt", &[conv, b"ba"]).remove(0);
    assert_eq!(call(&mut a, "decrypt", &[conv, &ct])[0], b"ba");
}

/// Vector chung với server Go (`server/internal/account/credential_vector_test.go`): cả hai phía
/// phải chấp nhận đúng cùng một credential. Sinh lại bằng `VECTOR=1 cargo test --test credential -- --nocapture vector`.
const VECTOR_CRED: &str = include_str!("credential_vector.txt");

#[test]
fn vector_lien_ngon_ngu() {
    if std::env::var("VECTOR").is_ok() {
        let mut a = Core::new_device(&[0x11; 16], &[0x22; 16], None, 1_700_000_000_000).unwrap();
        let r = call(&mut a, "credential", &[]);
        println!("cred={}\nidentity={}", hex(&r[0]), hex(&r[2]));
        return;
    }
    let (cred, ident) = VECTOR_CRED.trim().split_once('\n').map(|(c, i)| (c.trim_start_matches("cred="), i.trim_start_matches("identity="))).unwrap();
    let (cred, ident) = (unhex(cred), unhex(ident));
    let c = Credential::parse(&cred).unwrap();
    assert_eq!(c.account_id, [0x11; 16]);
    assert_eq!(c.device_id, [0x22; 16]);
    assert_eq!(c.created_ms, 1_700_000_000_000);
    c.verify(&ident).expect("vector credential phải hợp lệ");
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}
