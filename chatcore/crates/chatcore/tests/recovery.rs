//! Ca khôi phục / resync / exporter (spec 6.5, 6.7, 6.14; CLAUDE.md "quy tắc bất biến").
use chatcore::mls::Device;
use chatcore::sim::*;

fn setup(n: usize) -> (FakeServer, Vec<Client>) {
    let mut cs: Vec<Client> = (0..n).map(|i| Client::new(&format!("acc{i}/dev{i}"))).collect();
    let kps: Vec<_> = cs[1..].iter().map(|c| c.dev.key_package().unwrap()).collect();
    cs[0].group = Some(cs[0].dev.create_group().unwrap());
    let out = cs[0].add(&kps).unwrap();
    let srv = FakeServer::create(out.commit, out.group_info, &cs[0].dev.identity);
    cs[0].applied = 1;
    for c in &mut cs[1..] {
        c.group = Some(c.dev.join_welcome(out.welcome.as_ref().unwrap()).unwrap());
        c.applied = 1;
    }
    (srv, cs)
}

fn submit_external(srv: &mut FakeServer, c: &Client, commit: Vec<u8>) {
    // Server luôn cần GroupInfo mới; client mới vào xuất GroupInfo của epoch sau Commit.
    let gi = c.dev.group_info(c.group.as_ref().unwrap()).unwrap();
    srv.submit_commit(srv.epoch, commit, gi, &c.dev.identity).unwrap();
}

#[test]
fn recovery_with_new_signing_key_keeps_old_leaf_until_lowest_index_removes_it() {
    let (mut srv, mut cs) = setup(3);
    // acc2 mất máy: thiết bị mới cùng account, khóa ký mới (identity khác device_id nhưng cùng account)
    let mut fresh = Client::new("acc2/dev2");
    let (g, commit) = fresh.dev.external_join(&srv.group_info).unwrap();
    fresh.group = Some(g);
    submit_external(&mut srv, &fresh, commit);
    fresh.applied = srv.log.len() as u64;
    for c in &mut cs[..2] {
        c.sync(&srv).unwrap();
    }
    // leaf cũ KHÔNG tự bị gỡ: acc2 có 2 lá
    assert_eq!(Device::leaves_of(cs[0].group.as_ref().unwrap(), b"acc2/dev2").len(), 2);

    // Thành viên online có leaf index nhỏ nhất (cs[0]) gửi Remove cho lá cũ (lá có index nhỏ hơn của acc2).
    let mut leaves = Device::leaves_of(cs[0].group.as_ref().unwrap(), b"acc2/dev2");
    leaves.sort_by_key(|l| l.u32());
    let old = leaves[0];
    let ep = cs[0].epoch();
    let o = cs[0].remove(&[old]).unwrap();
    srv.submit_commit(ep, o.commit, o.group_info, &cs[0].dev.identity).unwrap();
    cs[1].sync(&srv).unwrap();
    fresh.sync(&srv).unwrap();
    assert_eq!(Device::leaves_of(cs[1].group.as_ref().unwrap(), b"acc2/dev2").len(), 1);
    assert_eq!(cs[0].epoch(), fresh.epoch());
    let k = cs[0].dev.sframe_key(cs[0].group.as_ref().unwrap(), b"c").unwrap();
    assert_eq!(k, fresh.dev.sframe_key(fresh.group.as_ref().unwrap(), b"c").unwrap());
}

#[test]
fn resync_with_same_signing_key_removes_old_leaf_by_itself() {
    let (mut srv, mut cs) = setup(3);
    // acc2 mất trạng thái nhóm nhưng giữ khóa ký: vào lại bằng External Commit cùng thiết bị.
    let mut c2 = cs.remove(2);
    let (g, commit) = c2.dev.external_join(&srv.group_info).unwrap();
    c2.group = Some(g);
    submit_external(&mut srv, &c2, commit);
    for c in &mut cs {
        c.sync(&srv).unwrap();
    }
    assert_eq!(Device::leaves_of(cs[0].group.as_ref().unwrap(), b"acc2/dev2").len(), 1);
    assert_eq!(cs[0].epoch(), c2.epoch());
}

#[test]
fn exporter_rules_for_sframe_key() {
    let (mut srv, mut cs) = setup(3);
    let k = |c: &Client, id: &[u8]| c.dev.sframe_key(c.group.as_ref().unwrap(), id).unwrap();
    // cùng epoch: giống nhau; khác call_id: khác; độ dài 32
    assert_eq!(k(&cs[0], b"call-a"), k(&cs[1], b"call-a"));
    assert_ne!(k(&cs[0], b"call-a"), k(&cs[0], b"call-b"));
    assert_eq!(k(&cs[0], b"call-a").len(), 32);
    // đổi epoch: khóa đổi
    let before = k(&cs[0], b"call-a");
    let (ep, o) = (cs[0].epoch(), cs[0].update().unwrap());
    srv.submit_commit(ep, o.commit, o.group_info, &cs[0].dev.identity).unwrap();
    cs[1].sync(&srv).unwrap();
    cs[2].sync(&srv).unwrap();
    assert_ne!(before, k(&cs[0], b"call-a"));
    assert_eq!(k(&cs[0], b"call-a"), k(&cs[2], b"call-a"));
    // người bị gỡ không có khóa mới
    let leaf = Device::leaves_of(cs[0].group.as_ref().unwrap(), b"acc2/dev2");
    let (ep, o) = (cs[0].epoch(), cs[0].remove(&leaf).unwrap());
    srv.submit_commit(ep, o.commit, o.group_info, &cs[0].dev.identity).unwrap();
    cs[1].sync(&srv).unwrap();
    cs[2].sync(&srv).unwrap(); // nhận Commit gỡ chính mình
    assert_eq!(k(&cs[0], b"call-a"), k(&cs[1], b"call-a"));
    assert!(cs[2].dev.sframe_key(cs[2].group.as_ref().unwrap(), b"call-a").is_err());
}
