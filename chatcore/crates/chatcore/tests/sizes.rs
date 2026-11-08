//! Đo kích thước Welcome và Commit khi thêm 1 thiết bị vào nhóm cỡ khác nhau (CLAUDE.md: "chưa kiểm chứng").
//! In số đo (chạy `cargo test --release --test sizes -- --nocapture`) và khẳng định nằm trong giới hạn của server
//! (`server/internal/message/service.go`: MaxCommit/MaxGroupInfo 128 KiB mỗi Welcome, MaxWelcomeBytes 3 MiB).
use chatcore::mls::{Device, MAX_DEVICES_PER_COMMIT, MAX_DEVICES_PER_GROUP};

const SERVER_MAX_ONE: usize = 128 << 10;
const SERVER_MAX_WELCOMES_TOTAL: usize = 3 << 20;

#[test]
fn kich_thuoc_welcome_va_commit_them_mot_thiet_bi() {
    let creator = Device::new(b"acc0/dev0").unwrap();
    let mut g = creator.create_group().unwrap();
    let mut size = 1;
    let mut worst = (0, 0, 0);
    for target in [2usize, 50, 100, 200, MAX_DEVICES_PER_GROUP - 1] {
        // Lớn dần tới `target` thành viên bằng các Commit tối đa 50 thiết bị.
        while size < target {
            let n = MAX_DEVICES_PER_COMMIT.min(target - size);
            let kps: Vec<_> = (0..n).map(|i| Device::new(format!("acc{}/dev{}", size + i, size + i).as_bytes()).unwrap().key_package().unwrap()).collect();
            creator.add(&mut g, &kps).unwrap();
            size += n;
        }
        // Thêm đúng 1 thiết bị: Welcome (kèm cây công khai) + Commit + GroupInfo.
        let newbie = Device::new(format!("acc{size}/dev{size}").as_bytes()).unwrap();
        let out = creator.add(&mut g, &[newbie.key_package().unwrap()]).unwrap();
        size += 1;
        let w = out.welcome.as_ref().unwrap().len();
        println!("nhóm {size:>4} thiết bị: Welcome {:>6} B, Commit {:>6} B, GroupInfo {:>6} B", w, out.commit.len(), out.group_info.len());
        // ADR 0011: giới hạn 256 thiết bị mỗi nhóm để Welcome/GroupInfo luôn vừa 128 KiB và 50 phong bì vừa 3 MiB.
        assert!(w < SERVER_MAX_ONE && out.group_info.len() < SERVER_MAX_ONE, "nhóm {size}: Welcome {w} B / GroupInfo {} B vượt 128 KiB", out.group_info.len());
        assert!(out.commit.len() < SERVER_MAX_ONE);
        worst = worst.max((w, out.commit.len(), out.group_info.len()));
    }
    // Một Commit 50 thiết bị lặp cùng một Welcome cho mỗi thiết bị (server nhân bản theo phong bì): phải vừa 3 MiB
    // ngay ở nhóm đầy, nếu không nhóm 256 thiết bị không thêm nổi 50 người cùng lúc.
    println!("Welcome lớn nhất {} B; 50 phong bì = {} B (ngân sách {SERVER_MAX_WELCOMES_TOTAL} B)", worst.0, worst.0 * MAX_DEVICES_PER_COMMIT);
    assert!(worst.0 * MAX_DEVICES_PER_COMMIT < SERVER_MAX_WELCOMES_TOTAL, "50 phong bì Welcome vượt ngân sách 3 MiB");
}
