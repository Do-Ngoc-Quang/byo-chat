//! Kịch bản kiểm thử dùng chung cho native (`tests/`) và WASM (`chatcore/wasm/tests/`).
//! Chỉ để test; mỗi hàm `pub fn` là một kịch bản, panic nếu vi phạm.

/// Đồng hồ mili giây: native dùng Instant, WASM dùng performance.now() (Instant không chạy trên wasm32).
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

pub fn now_ms() -> f64 {
    #[cfg(target_arch = "wasm32")]
    {
        js_sys::Reflect::get(&js_sys::global(), &"performance".into()).ok()
            .and_then(|p| js_sys::Reflect::get(&p, &"now".into()).ok())
            .and_then(|f| f.dyn_into::<js_sys::Function>().ok())
            .and_then(|f| f.call0(&js_sys::global().dyn_into::<js_sys::Object>().unwrap().into()).ok())
            .and_then(|v| v.as_f64()).unwrap_or(0.0)
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        use std::sync::OnceLock;
        static START: OnceLock<std::time::Instant> = OnceLock::new();
        START.get_or_init(std::time::Instant::now).elapsed().as_secs_f64() * 1000.0
    }
}
pub mod invariants {
    use crate::mls::Device;
    use crate::sim::*;

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

    pub fn inv1_same_epoch_and_exporter_after_mixed_commits() {
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

    pub fn inv2_concurrent_commits_only_one_wins() {
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
        assert_eq!(srv.log.iter().filter(|e| e.epoch == ep && e.kind == crate::pb::EntryKind::Commit).count(), 1);
    }

    pub fn inv3_every_logged_message_decrypts_with_its_epoch_key() {
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

    pub fn send_with_stale_epoch_is_rejected() {
        let (mut srv, mut cs) = setup(2);
        let ep = cs[0].epoch();
        let o = cs[0].update().unwrap();
        srv.submit_commit(ep, o.commit, o.group_info, &cs[0].dev.identity).unwrap();
        let ct = vec![1, 2, 3];
        assert_eq!(srv.send(b"m1", ep, ct, b"x").unwrap_err(), ServerErr::EpochMismatch { current: ep + 1 });
        assert_eq!(srv.log.len(), 2);
    }

    pub fn inv4_removed_device_cannot_read_later_epochs() {
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

    pub fn inv5_retry_with_same_client_msg_id_adds_no_entry() {
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
}

pub mod recovery {
    use crate::mls::Device;
    use crate::sim::*;

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

    pub fn recovery_with_new_signing_key_keeps_old_leaf_until_lowest_index_removes_it() {
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

    pub fn resync_with_same_signing_key_removes_old_leaf_by_itself() {
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

    pub fn exporter_rules_for_sframe_key() {
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
}

pub mod scale {
    use crate::mls::*;
    use super::now_ms;

    /// Tiện ích in log (stdout native; WASM bỏ qua).
    fn log(s: &str) { #[cfg(not(target_arch = "wasm32"))] println!("{s}"); let _ = s; }

    pub fn group_of_1000_devices() {
        let creator = Device::new(b"acc0/dev0").unwrap();
        let mut g = creator.create_group().unwrap();
        let devs: Vec<Device> = (1..MAX_DEVICES_PER_GROUP).map(|i| Device::new(format!("acc{i}/dev{i}").as_bytes()).unwrap()).collect();
        let mut kps: Vec<_> = devs.iter().map(|d| d.key_package().unwrap()).collect();

        // Thiết bị đầu tiên được thêm làm "bên nhận": áp dụng mọi Commit về sau.
        let first = kps.drain(..MAX_DEVICES_PER_COMMIT).collect::<Vec<_>>();
        let out = creator.add(&mut g, &first).unwrap();
        let mut recv = devs[0].join_welcome(out.welcome.as_ref().unwrap()).unwrap();

        let (mut last_create, mut last_recv, mut last_size) = (0, 0, 0);
        while !kps.is_empty() {
            let batch: Vec<_> = kps.drain(..MAX_DEVICES_PER_COMMIT.min(kps.len())).collect();
            let t = now_ms();
            let out = creator.add(&mut g, &batch).unwrap();
            last_create = (now_ms() - t) as u128;
            let t = now_ms();
            devs[0].apply_commit(&mut recv, &out.commit).unwrap();
            last_recv = (now_ms() - t) as u128;
            last_size = out.commit.len();
        }
        assert_eq!(g.members().count(), MAX_DEVICES_PER_GROUP);
        assert_eq!(creator.sframe_key(&g, b"c").unwrap(), devs[0].sframe_key(&recv, b"c").unwrap());
        log(&format!("commit cuối: {} KB, tạo {last_create} ms, nhận {last_recv} ms", last_size / 1024));
        if !cfg!(debug_assertions) {
            let k = if cfg!(target_arch = "wasm32") { 3 } else if cfg!(target_os = "android") { 3 } else { 1 }; // CLAUDE.md: WASM ~5 lần, emulator Android ~3 lần so với Windows (runner CI dùng chung còn nhiễu: đo 422 ms một lần khi mốc 33 ms)
            assert!(last_size < 120 * 1024, "Commit {last_size} B (mốc 92 KB)");
            assert!(last_create < 170 * k, "tạo {last_create} ms (mốc 33 ms)");
            assert!(last_recv < 60 * k, "nhận {last_recv} ms (mốc 11 ms)");
        }
    }

    pub fn limits_are_enforced() {
        let a = Device::new(b"a").unwrap();
        let mut g = a.create_group().unwrap();
        let kps: Vec<_> = (0..=MAX_DEVICES_PER_COMMIT).map(|i| Device::new(format!("d{i}").as_bytes()).unwrap().key_package().unwrap()).collect();
        assert!(a.add(&mut g, &kps).is_err()); // 51 > 50
        assert!(a.add(&mut g, &kps[..MAX_DEVICES_PER_COMMIT]).is_ok());
    }
}
