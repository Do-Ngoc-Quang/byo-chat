//! Bất biến 1-5 của spec mục 8, chạy với server giả và nhiều thiết bị.
use chatcore::mls::Device;
use chatcore::sim::*;

/// Nhóm n thiết bị: c0 tạo, thêm các thiết bị còn lại bằng một Commit.
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

fn sync_all(srv: &FakeServer, cs: &mut [Client]) {
    for c in cs.iter_mut().filter(|c| c.group.is_some()) {
        c.sync(srv).unwrap();
    }
}

/// Bất biến 1: cùng epoch và cùng exporter secret.
fn assert_inv1(cs: &[Client]) {
    let live: Vec<_> = cs.iter().filter(|c| c.group.is_some()).collect();
    let k0 = live[0].dev.sframe_key(live[0].group.as_ref().unwrap(), b"call-1").unwrap();
    for c in &live {
        assert_eq!(c.epoch(), live[0].epoch());
        assert_eq!(c.dev.sframe_key(c.group.as_ref().unwrap(), b"call-1").unwrap(), k0);
    }
}

#[test]
fn inv1_same_epoch_and_exporter_after_mixed_commits() {
    let (mut srv, mut cs) = setup(5);
    // update, add thiết bị mới, update bởi người khác, remove
    let out = cs[1].update().unwrap();
    srv.submit_commit(cs[1].epoch() - 1, out.commit, out.group_info, &cs[1].dev.identity).unwrap();
    sync_all(&srv, &mut cs);
    assert_inv1(&cs);

    let mut newc = Client::new("acc9/dev9");
    let kp = newc.dev.key_package().unwrap();
    let ep = cs[2].epoch();
    let out = cs[2].add(&[kp]).unwrap();
    srv.submit_commit(ep, out.commit, out.group_info, &cs[2].dev.identity).unwrap();
    newc.group = Some(newc.dev.join_welcome(&out.welcome.unwrap()).unwrap());
    newc.applied = srv.log.len() as u64;
    cs.push(newc);
    sync_all(&srv, &mut cs);
    assert_inv1(&cs);

    let leaf = Device::leaves_of(cs[0].group.as_ref().unwrap(), &cs[3].dev.identity);
    let ep = cs[0].epoch();
    let out = cs[0].remove(&leaf).unwrap();
    srv.submit_commit(ep, out.commit, out.group_info, &cs[0].dev.identity).unwrap();
    let removed = cs.remove(3);
    sync_all(&srv, &mut cs);
    assert_inv1(&cs);
    drop(removed);
}

#[test]
fn inv2_concurrent_commits_only_one_wins() {
    let (mut srv, mut cs) = setup(3);
    let ep = cs[0].epoch();
    let o0 = cs[0].update().unwrap();
    let o1 = cs[1].update().unwrap();
    assert!(srv.submit_commit(ep, o0.commit, o0.group_info, &cs[0].dev.identity).is_ok());
    let err = srv.submit_commit(ep, o1.commit, o1.group_info, &cs[1].dev.identity).unwrap_err();
    assert_eq!(err, ServerErr::EpochMismatch { current: ep + 1 });
    // seq liên tục, mỗi seq một mục
    for (i, e) in srv.log.iter().enumerate() {
        assert_eq!(e.seq, i as u64 + 1);
    }
    assert_eq!(srv.log.iter().filter(|e| e.epoch == ep && e.kind == chatcore::pb::EntryKind::Commit).count(), 1);
}

#[test]
fn inv3_every_logged_message_decrypts_with_its_epoch_key() {
    let (mut srv, mut cs) = setup(4);
    let mut sent = vec![];
    for round in 0..3u8 {
        for s in 0..2 {
            let ep = cs[s].epoch();
            let pt = vec![round, s as u8];
            let ct = cs[s].encrypt(&pt).unwrap();
            srv.send(&[round, s as u8], ep, ct, &cs[s].dev.identity).unwrap();
            sent.push(pt);
        }
        // đổi epoch giữa các vòng: mọi người đọc hết epoch này rồi mới Commit
        sync_all(&srv, &mut cs);
        let ep = cs[2].epoch();
        let o = cs[2].update().unwrap();
        srv.submit_commit(ep, o.commit, o.group_info, &cs[2].dev.identity).unwrap();
        sync_all(&srv, &mut cs);
    }
    // thiết bị 3 chưa từng nhận gì ngoài sync: phải nhận đủ 6 tin, đúng thứ tự
    assert_eq!(cs[3].inbox, sent);
    assert_inv1(&cs);
}

#[test]
fn send_with_stale_epoch_is_rejected() {
    let (mut srv, mut cs) = setup(2);
    let ep = cs[0].epoch();
    let o = cs[0].update().unwrap();
    srv.submit_commit(ep, o.commit, o.group_info, &cs[0].dev.identity).unwrap();
    let ct = vec![1, 2, 3];
    assert_eq!(srv.send(b"m1", ep, ct, b"x").unwrap_err(), ServerErr::EpochMismatch { current: ep + 1 });
    assert_eq!(srv.log.len(), 2);
}

#[test]
fn inv4_removed_device_cannot_read_later_epochs() {
    let (mut srv, mut cs) = setup(3);
    let leaf = Device::leaves_of(cs[0].group.as_ref().unwrap(), &cs[2].dev.identity);
    let ep = cs[0].epoch();
    let o = cs[0].remove(&leaf).unwrap();
    srv.submit_commit(ep, o.commit.clone(), o.group_info, &cs[0].dev.identity).unwrap();
    cs[1].sync(&srv).unwrap();
    // thiết bị bị gỡ nhận Commit gỡ chính nó (tin cuối), rồi không giải mã được tin sau đó
    let mut victim = cs.remove(2);
    victim.sync(&srv).unwrap();
    assert!(!victim.group.as_ref().unwrap().is_active());
    let ct = cs[0].encrypt(b"secret").unwrap();
    assert!(victim.decrypt(&ct).is_err());
    assert_eq!(cs[1].decrypt(&ct).unwrap(), b"secret");
}

#[test]
fn inv5_retry_with_same_client_msg_id_adds_no_entry() {
    let (mut srv, mut cs) = setup(2);
    let ep = cs[0].epoch();
    let ct = cs[0].encrypt(b"hello").unwrap();
    let (seq, dup) = srv.send(b"id-1", ep, ct.clone(), &cs[0].dev.identity).unwrap();
    assert!(!dup);
    let n = srv.log.len();
    // gửi lại sau khi epoch đã đổi vẫn trả kết quả cũ, không thêm mục
    let o = cs[1].update().unwrap();
    srv.submit_commit(ep, o.commit, o.group_info, &cs[1].dev.identity).unwrap();
    let n = n + 1;
    assert_eq!(srv.send(b"id-1", ep, ct, &cs[0].dev.identity).unwrap(), (seq, true));
    assert_eq!(srv.log.len(), n);
}
