//! Nhóm 1.000 thiết bị, mỗi Commit thêm 50 (mốc Windows native: Commit cuối 92 KB, tạo 33 ms, nhận 11 ms).
//! Ngưỡng = mốc x ~5 để CI Linux không chập chờn nhưng vẫn bắt được suy giảm lớn. Chỉ kiểm ở --release.
use chatcore::mls::*;
use std::time::Instant;

#[test]
fn group_of_1000_devices() {
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
        let t = Instant::now();
        let out = creator.add(&mut g, &batch).unwrap();
        last_create = t.elapsed().as_millis();
        let t = Instant::now();
        devs[0].apply_commit(&mut recv, &out.commit).unwrap();
        last_recv = t.elapsed().as_millis();
        last_size = out.commit.len();
    }
    assert_eq!(g.members().count(), MAX_DEVICES_PER_GROUP);
    assert_eq!(creator.sframe_key(&g, b"c").unwrap(), devs[0].sframe_key(&recv, b"c").unwrap());
    println!("commit cuối: {} KB, tạo {last_create} ms, nhận {last_recv} ms", last_size / 1024);
    if !cfg!(debug_assertions) {
        assert!(last_size < 120 * 1024, "Commit {last_size} B (mốc 92 KB)");
        assert!(last_create < 170, "tạo {last_create} ms (mốc 33 ms)");
        assert!(last_recv < 60, "nhận {last_recv} ms (mốc 11 ms)");
    }
}

#[test]
fn limits_are_enforced() {
    let a = Device::new(b"a").unwrap();
    let mut g = a.create_group().unwrap();
    let kps: Vec<_> = (0..=MAX_DEVICES_PER_COMMIT).map(|i| Device::new(format!("d{i}").as_bytes()).unwrap().key_package().unwrap()).collect();
    assert!(a.add(&mut g, &kps).is_err()); // 51 > 50
    assert!(a.add(&mut g, &kps[..MAX_DEVICES_PER_COMMIT]).is_ok());
}
