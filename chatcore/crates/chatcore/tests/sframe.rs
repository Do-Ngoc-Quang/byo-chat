//! Khóa SFrame qua nhóm MLS thật: chỉ số khóa khớp giữa mọi thiết bị, vào giữa cuộc gọi, người bị gỡ mất khóa mới.
use chatcore::mls::Device;
use chatcore::sframe::{key_id, KeyRing, KEEP_OLD_MS, SWITCH_DELAY_MS};
use chatcore::sim::*;

const CALL: &[u8] = b"call-1";

fn setup(n: usize) -> (FakeServer, Vec<Client>) {
    let mut cs: Vec<Client> = (0..n).map(|i| Client::new(&format!("acc{i}/dev{i}"))).collect();
    let mut g = cs[0].dev.create_group().unwrap();
    let kps: Vec<_> = cs[1..].iter().map(|c| c.dev.key_package().unwrap()).collect();
    let out = cs[0].dev.add(&mut g, &kps).unwrap();
    cs[0].group = Some(g);
    let srv = FakeServer::create(out.commit, out.group_info, &cs[0].dev.identity);
    cs[0].applied = 1;
    for c in &mut cs[1..] {
        c.group = Some(c.dev.join_welcome(out.welcome.as_ref().unwrap()).unwrap());
        c.applied = 1;
    }
    (srv, cs)
}

fn key(c: &Client) -> [u8; 32] {
    c.dev.sframe_key(c.group.as_ref().unwrap(), CALL).unwrap().try_into().unwrap()
}

fn ring(c: &Client) -> KeyRing {
    KeyRing::new(c.epoch(), key(c))
}

#[test]
fn doi_khoa_khi_co_nguoi_ra_vao_khong_mat_tieng() {
    let (mut srv, mut cs) = setup(3);
    let mut rings: Vec<KeyRing> = cs.iter().map(ring).collect();
    let e0 = cs[0].epoch();
    // Mọi thiết bị cùng chỉ số và cùng khóa khi vào cuộc gọi.
    assert!(rings.iter_mut().all(|r| r.send_key(0) == (key_id(e0), key(&cs[0]))));

    // c0 đổi khóa (Update). Bên nhận áp dụng Commit trước, bên gửi tại t=1000.
    let t = 1_000;
    let (ep, o) = (cs[0].epoch(), cs[0].update().unwrap());
    srv.submit_commit(ep, o.commit, o.group_info, &cs[0].dev.identity).unwrap();
    for c in &mut cs[1..] {
        c.sync(&srv).unwrap();
    }
    for (c, r) in cs.iter().zip(rings.iter_mut()) {
        assert!(r.on_epoch(c.epoch(), key(c), t));
    }
    let new_id = key_id(cs[0].epoch());
    assert_ne!(new_id, key_id(e0));
    // Cả ba thiết bị tính cùng khóa mới.
    assert!(cs.iter().all(|c| key(c) == key(&cs[0])));
    // Khung đang bay mang khóa cũ vẫn giải mã được ở mọi thiết bị trong 10 giây; khung mang khóa mới cũng vậy.
    for r in rings.iter_mut() {
        assert!(r.recv_key(key_id(e0), t + 500).is_some());
        assert!(r.recv_key(new_id, t + 500).is_some());
        assert_eq!(r.send_key(t + SWITCH_DELAY_MS - 1).0, key_id(e0));
        assert_eq!(r.send_key(t + SWITCH_DELAY_MS).0, new_id);
        assert!(r.recv_key(key_id(e0), t + KEEP_OLD_MS).is_none());
    }
}

#[test]
fn nguoi_bi_go_khong_co_khoa_moi() {
    let (mut srv, mut cs) = setup(3);
    let mut r2 = ring(&cs[2]);
    let leaf = Device::leaves_of(cs[0].group.as_ref().unwrap(), b"acc2/dev2");
    let (ep, o) = (cs[0].epoch(), cs[0].remove(&leaf).unwrap());
    srv.submit_commit(ep, o.commit, o.group_info, &cs[0].dev.identity).unwrap();
    cs[1].sync(&srv).unwrap();
    cs[2].sync(&srv).unwrap();
    // c0 và c1 có khóa mới giống nhau; c2 không dẫn xuất được khóa của epoch mới nên vòng khóa của nó không có chỉ số mới.
    assert_eq!(key(&cs[0]), key(&cs[1]));
    assert!(cs[2].dev.sframe_key(cs[2].group.as_ref().unwrap(), CALL).is_err());
    assert!(r2.recv_key(key_id(cs[0].epoch()), 0).is_none());
}

#[test]
fn vao_giua_cuoc_goi_khop_chi_so_voi_nguoi_dang_goi() {
    // c0 và c1 đã trong cuộc gọi, đổi khóa vài lần; c2 (thiết bị mới vào nhóm) tham gia ở epoch hiện tại.
    let (mut srv, mut cs) = setup(2);
    let mut rings: Vec<KeyRing> = cs.iter().map(ring).collect();
    for i in 0..3u64 {
        let (ep, o) = (cs[0].epoch(), cs[0].update().unwrap());
        srv.submit_commit(ep, o.commit, o.group_info, &cs[0].dev.identity).unwrap();
        cs[1].sync(&srv).unwrap();
        for (c, r) in cs.iter().zip(rings.iter_mut()) {
            assert!(r.on_epoch(c.epoch(), key(c), (i + 1) * 2_000));
        }
    }
    let mut c2 = Client::new("acc2/dev2");
    let (g, commit) = c2.dev.external_join(&srv.group_info).unwrap();
    c2.group = Some(g);
    let ep = cs[0].epoch();
    srv.submit_commit(ep, commit, srv.group_info.clone(), &c2.dev.identity).unwrap();
    cs[0].sync(&srv).unwrap();
    cs[1].sync(&srv).unwrap();
    let mut r2 = KeyRing::new(c2.epoch(), key(&c2));
    for (c, r) in cs.iter().zip(rings.iter_mut()) {
        assert!(r.on_epoch(c.epoch(), key(c), 9_000));
    }
    let id = key_id(c2.epoch());
    let t = 9_000 + SWITCH_DELAY_MS;
    assert_eq!(r2.send_key(t), rings[0].send_key(t));
    assert_eq!(r2.send_key(t).0, id);
}
